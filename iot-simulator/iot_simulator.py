#!/usr/bin/env python3
"""
iot_simulator.py - AWS IoT simulator with Prometheus metrics

Features:
 - Publishes JSON payloads to AWS IoT (MQTT over TLS 8883) using X.509 certs
 - Validates certificates strongly (format, readability, expiration, cert/key match)
 - Exposes Prometheus metrics on :9100 (gauges, counters, histogram)
 - Per-device visibility for metrics (labels include `device` where it makes sense)
 - Multi-device simulation via threads
 - Structured JSON logging for easy ingestion

  Gauges:
    machine_temperature_c{device}
    machine_vibration_ms2{device}
    machine_rpm{device}
    machine_power_kw{device}
    machine_heartbeat{device}

  Counters:
    events_total{device}
    anomaly_type_total{device,type}
    anomaly_severity_total{device,level}

  Histogram:
    temperature_spike_c_bucket{device,le}

Environment variables:
 - AWS_ENDPOINT         : AWS IoT endpoint (required)
 - SIMULATOR_COUNT      : number of virtual devices (default: 2)
 - IOT_TOPIC            : base MQTT topic (default: factory/plant1/line1)
 - CERT_DIR             : directory containing:
                            - device-certificate.pem.crt
                            - private.pem.key
                            - AmazonRootCA1.pem
"""

import json
import logging
import os
import random
import signal
import sys
import threading
import time
from datetime import datetime, timezone

import paho.mqtt.client as mqtt
from OpenSSL import crypto
from prometheus_client import Counter, Gauge, Histogram, start_http_server

# -------------------------
# Configuration & logging
# -------------------------

AWS_ENDPOINT = os.getenv("AWS_ENDPOINT")
SIMULATOR_COUNT = int(os.getenv("SIMULATOR_COUNT", "2"))
IOT_TOPIC = os.getenv("IOT_TOPIC", "factory/plant1/line1")
CERT_DIR = os.getenv("CERT_DIR", "/app/certs")

CA_PATH = os.path.join(CERT_DIR, "AmazonRootCA1.pem")
CERT_PATH = os.path.join(CERT_DIR, "device-certificate.pem.crt")
KEY_PATH = os.path.join(CERT_DIR, "private.pem.key")

PUBLISH_INTERVAL = 1.0  # seconds

os.makedirs("/var/log/iot-simulator", exist_ok=True)
LOG_FILE = "/var/log/iot-simulator/simulator.log"

logging.basicConfig(
    level=logging.INFO,
    format="%(message)s",
    handlers=[
        logging.StreamHandler(sys.stdout),
        logging.FileHandler(LOG_FILE),
    ],
)


def log_struct(level: str, msg: str, **fields):
    payload = {
        "ts": datetime.now(timezone.utc).isoformat(),
        "level": level,
        "msg": msg,
    }
    payload.update(fields)
    logging.log(getattr(logging, level.upper(), logging.INFO), json.dumps(payload))


# -------------------------
# Prometheus metrics
# -------------------------

# Per-device machine state
temp_gauge = Gauge("machine_temperature_c", "Temperature (C)", ["device"])
vib_gauge = Gauge("machine_vibration_ms2", "Vibration (m/s2)", ["device"])
rpm_gauge = Gauge("machine_rpm", "Motor RPM", ["device"])
power_gauge = Gauge("machine_power_kw", "Power (kW)", ["device"])

# Per-device event counts
events_total = Counter(
    "events_total",
    "Total events published",
    ["device"],
)

# Anomalies by device and type (spike/drift/noise/freeze/combined/none)
anomaly_type_total = Counter(
    "anomaly_type_total",
    "Anomalies by device and type",
    ["device", "type"],
)

# Anomalies by severity (info/warning/critical) and device
anomaly_severity = Counter(
    "anomaly_severity_total",
    "Anomalies by severity and device",
    ["device", "level"],
)

# Temperature spike distribution, per device
temp_spike_hist = Histogram(
    "temperature_spike_c",
    "Temperature spike distribution (C)",
    ["device"],
    buckets=[5, 10, 15, 20, 25, 30, 35],
)

# Simple liveness metric per device
heartbeat_gauge = Gauge("machine_heartbeat", "Heartbeat (1=alive)", ["device"])


# -------------------------
# Strong certificate validation
# -------------------------

def validate_certificates(raise_on_error: bool = True):
    """
    Validate that CA, certificate and private key:
     - files exist and are readable
     - are valid PEM
     - certificate not expired
     - certificate public key matches private key
    """
    missing = []
    for name, path in (
        ("Root CA", CA_PATH),
        ("Device Cert", CERT_PATH),
        ("Private Key", KEY_PATH),
    ):
        if not os.path.isfile(path):
            missing.append((name, path))
        elif not os.access(path, os.R_OK):
            missing.append((f"{name} not readable", path))

    if missing:
        msg = f"Certificate files missing/not readable: {missing}"
        if raise_on_error:
            raise FileNotFoundError(msg)
        else:
            log_struct("error", "cert_validation_failed", details=msg)
            return {"ok": False, "error": msg}

    try:
        with open(CERT_PATH, "rb") as f:
            cert_pem = f.read()
        cert = crypto.load_certificate(crypto.FILETYPE_PEM, cert_pem)

        with open(KEY_PATH, "rb") as f:
            key_pem = f.read()
        pkey = crypto.load_privatekey(crypto.FILETYPE_PEM, key_pem)

        not_after = datetime.strptime(
            cert.get_notAfter().decode("ascii"), "%Y%m%d%H%M%SZ"
        ).replace(tzinfo=timezone.utc)
        if not_after < datetime.now(timezone.utc):
            msg = f"Device certificate expired at {not_after.isoformat()}"
            if raise_on_error:
                raise ValueError(msg)
            else:
                log_struct("error", "cert_expired", expiry=not_after.isoformat())
                return {"ok": False, "error": msg}

        cert_pub = cert.get_pubkey().to_cryptography_key().public_numbers()
        key_pub = pkey.to_cryptography_key().public_key().public_numbers()
        if cert_pub != key_pub:
            msg = "Certificate public key does not match private key"
            if raise_on_error:
                raise ValueError(msg)
            else:
                log_struct("error", "cert_key_mismatch")
                return {"ok": False, "error": msg}

        fp = cert.digest("sha256").decode("ascii")
        log_struct(
            "info",
            "cert_validation_ok",
            fingerprint_sha256=fp,
            not_after=not_after.isoformat(),
        )
        return {"ok": True, "fingerprint_sha256": fp, "not_after": not_after.isoformat()}
    except Exception as e:
        if raise_on_error:
            raise
        log_struct("error", "cert_validation_exception", error=str(e))
        return {"ok": False, "error": str(e)}


# -------------------------
# Anomaly injection & payload
# -------------------------

def inject_anomaly(device_id: str, data: dict):
    anomaly_type = random.choices(
        ["none", "spike", "drift", "noise", "freeze", "combined"],
        weights=[0.7, 0.10, 0.05, 0.10, 0.03, 0.02],
        k=1,
    )[0]

    severity = "info"

    if anomaly_type == "spike":
        spike = random.uniform(15, 35)
        data["temperature_c"] += spike
        temp_spike_hist.labels(device=device_id).observe(spike)
        severity = "critical"
    elif anomaly_type == "drift":
        data["temperature_c"] += random.uniform(0.1, 0.5)
        severity = "warning"
    elif anomaly_type == "noise":
        data["rpm"] += int(random.gauss(0, 50))
        data["power_kw"] += random.gauss(0, 1.5)
        severity = "info"
    elif anomaly_type == "freeze":
        # could simulate freeze by holding values, but here we just tag it
        severity = "warning"
    elif anomaly_type == "combined":
        data["temperature_c"] += random.uniform(5, 15)
        data["vibration_ms2"] += random.uniform(0.5, 1.5)
        data["rpm"] -= random.randint(100, 300)
        severity = "critical"

    # per-device anomaly counts
    anomaly_type_total.labels(device=device_id, type=anomaly_type).inc()
    anomaly_severity.labels(device=device_id, level=severity).inc()

    return data, anomaly_type, severity


def make_payload(device_id: str):
    base_temp = 60 + (hash(device_id) % 5)
    data = {
        "device_id": device_id,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "temperature_c": round(base_temp + random.gauss(0, 2), 2),
        "vibration_ms2": round(random.uniform(0.1, 0.5), 3),
        "rpm": int(1400 + random.gauss(0, 30)),
        "power_kw": round(10 + random.gauss(0, 1), 2),
    }
    return inject_anomaly(device_id, data)


# -------------------------
# MQTT publisher thread
# -------------------------

def publisher(device_id: str):
    topic = f"{IOT_TOPIC}/{device_id}"
    client = mqtt.Client()

    try:
        client.tls_set(ca_certs=CA_PATH, certfile=CERT_PATH, keyfile=KEY_PATH)
    except Exception as e:
        log_struct("error", "tls_setup_failed", device=device_id, error=str(e))
        return

    client.reconnect_delay_set(min_delay=1, max_delay=32)

    while True:
        try:
            client.connect(AWS_ENDPOINT, 8883)
            client.loop_start()
            log_struct(
                "info",
                "mqtt_connected",
                device=device_id,
                endpoint=AWS_ENDPOINT,
                topic=topic,
            )
            break
        except Exception as e:
            log_struct("warning", "mqtt_connect_failed", device=device_id, error=str(e))
            time.sleep(3)

    while True:
        payload, atype, severity = make_payload(device_id)
        try:
            client.publish(topic, json.dumps(payload), qos=1)

            # per-device metrics
            events_total.labels(device=device_id).inc()
            temp_gauge.labels(device=device_id).set(payload["temperature_c"])
            vib_gauge.labels(device=device_id).set(payload["vibration_ms2"])
            rpm_gauge.labels(device=device_id).set(payload["rpm"])
            power_gauge.labels(device=device_id).set(payload["power_kw"])
            heartbeat_gauge.labels(device=device_id).set(1)

            log_struct(
                "info",
                "published",
                device=device_id,
                topic=topic,
                anomaly=atype,
                severity=severity,
            )
        except Exception as e:
            log_struct("error", "publish_failed", device=device_id, error=str(e))

        time.sleep(PUBLISH_INTERVAL)


# -------------------------
# Entrypoint
# -------------------------

def main():
    start_http_server(9100)
    log_struct(
        "info",
        "starting_simulator",
        endpoint=AWS_ENDPOINT,
        simulators=SIMULATOR_COUNT,
        topic_base=IOT_TOPIC,
    )

    if not AWS_ENDPOINT:
        log_struct("critical", "missing_endpoint", env="AWS_ENDPOINT")
        sys.exit(1)

    validate_certificates(raise_on_error=True)

    def handle_signal(signum, frame):
        log_struct("warning", "shutdown_signal", signum=signum)
        sys.exit(0)

    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)

    for idx in range(SIMULATOR_COUNT):
        device_id = f"M{idx+1:03d}"
        t = threading.Thread(target=publisher, args=(device_id,), daemon=True)
        t.start()
        log_struct("info", "device_thread_started", device=device_id)

    while True:
        time.sleep(5)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        log_struct("critical", "simulator_fatal", error=str(exc))
        raise
