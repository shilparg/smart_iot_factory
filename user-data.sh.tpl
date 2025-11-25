#!/bin/bash
set -e
exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

##########################################
# Variables from Terraform
##########################################
SIMULATOR_COUNT=${simulator_count}
CERT_BUCKET=${cert_s3_bucket}
REGION=${region}
AWS_ENDPOINT=${aws_endpoint}
IOT_TOPIC=${iot_topic} #"factory/plant1/line1"
ALERT_EMAIL_RECIPIENTS="${alert_email_recipients}"

echo "=== Starting IoT Simulator bootstrap ==="
echo "Simulator count: $SIMULATOR_COUNT"
echo "Bucket: $CERT_BUCKET"
echo "Region: $REGION"
echo "AWS IoT endpoint: $AWS_ENDPOINT"

##########################################
# Install system packages
##########################################
yum update -y
amazon-linux-extras install docker -y || dnf install docker -y
systemctl enable docker
systemctl start docker
usermod -aG docker ec2-user

##########################################
# Install Docker Compose v2
##########################################
curl -SL "https://github.com/docker/compose/releases/download/v2.24.6/docker-compose-$(uname -s)-$(uname -m)" \
  -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

##########################################
# Prepare directory structure
##########################################
mkdir -p /opt/iot-simulator/certs
cd /opt/iot-simulator

##########################################
# Download AWS IoT Certificates from S3
##########################################
aws s3 cp s3://${cert_s3_bucket}/AmazonRootCA1.pem /opt/iot-simulator/certs/AmazonRootCA1.pem --region $REGION
aws s3 cp s3://${cert_s3_bucket}/device-certificate.pem.crt /opt/iot-simulator/certs/device-certificate.pem.crt --region $REGION
aws s3 cp s3://${cert_s3_bucket}/private.pem.key /opt/iot-simulator/certs/private.pem.key --region $REGION

chmod 600 /opt/iot-simulator/certs/*
chown -R ec2-user:ec2-user /opt/iot-simulator

##########################################
#    Validate certificates 
##########################################
echo "Validating certificates..."

for file in AmazonRootCA1.pem device-certificate.pem.crt private.pem.key; do
  if [ ! -f "/opt/iot-simulator/certs/$file" ]; then
    echo "❌ ERROR: Missing /opt/iot-simulator/certs/$file"
    exit 1
  else
    echo "✅ Found $file"
  fi
done

##########################################
# (Optional) Install Python IoT SDK
##########################################
yum install -y python3 pip
pip3 install AWSIoTPythonSDK

##########################################
# Write requirements.txt
##########################################
cat > /opt/iot-simulator/requirements.txt << 'REQ'
paho-mqtt
prometheus_client
pyOpenSSL
AWSIoTPythonSDK==1.5.0
requests==2.31.0
REQ

##########################################
# Write iot_simulator.py (FULL EMBEDDED)
##########################################
cat > /opt/iot-simulator/iot_simulator.py << 'PYCODE'
#!/usr/bin/env python3
"""
iot_simulator.py - Production-ready AWS IoT simulator

Features:
 - Publishes JSON payloads to AWS IoT (MQTT over TLS 8883) using X.509 certs
 - Validates certificates strongly (format, readability, expiration, cert/key match)
 - Exposes Prometheus metrics on :9100 (gauges, counters, histogram)
 - Structured JSON logging to file + stdout for CloudWatch friendliness
 - Multi-device simulation via threads
 - Graceful reconnect and telemetry updates

Environment variables (with sensible defaults):
 - AWS_ENDPOINT         : AWS IoT endpoint (required)
 - SIMULATOR_COUNT      : number of virtual devices (default: 2)
 - IOT_TOPIC            : base MQTT topic (default: factory/plant1/line1)
 - CERT_DIR             : directory inside container where certs are mounted (default: /app/certs)
 - PUBLISH_INTERVAL     : seconds between publishes per device (default: 1.0)
 - SIM_LOG_PATH         : path for simulator JSON logs (default: /var/log/iot-simulator.log)
"""

import os
import sys
import json
import time
import random
import logging
import threading
import ssl
import hashlib
from datetime import datetime, timezone

import paho.mqtt.client as mqtt
from prometheus_client import start_http_server, Gauge, Counter, Histogram

# pyOpenSSL for certificate parsing/validation
try:
    from OpenSSL import crypto
except Exception as e:
    raise RuntimeError("pyOpenSSL is required. Please install with `pip install pyOpenSSL`") from e

# -------------------------
# Configuration (env)
# -------------------------
AWS_ENDPOINT = os.getenv("AWS_ENDPOINT", "").strip()
SIMULATOR_COUNT = int(os.getenv("SIMULATOR_COUNT", "2"))
IOT_TOPIC = os.getenv("IOT_TOPIC", "factory/plant1/line1")
CERT_DIR = os.getenv("CERT_DIR", "/app/certs")
PUBLISH_INTERVAL = float(os.getenv("PUBLISH_INTERVAL", "1.0"))
SIM_LOG_PATH = os.getenv("SIM_LOG_PATH", "/var/log/iot-simulator.log")

CERT_PATH = os.path.join(CERT_DIR, "device-certificate.pem.crt")
KEY_PATH = os.path.join(CERT_DIR, "private.pem.key")
CA_PATH = os.path.join(CERT_DIR, "AmazonRootCA1.pem")

# -------------------------
# Logging (structured)
# -------------------------
logger = logging.getLogger("iot_sim")
logger.setLevel(logging.INFO)
# File handler (structured JSON lines)
fh = logging.FileHandler(SIM_LOG_PATH)
fh.setFormatter(logging.Formatter("%(message)s"))
logger.addHandler(fh)
# Console handler
ch = logging.StreamHandler(sys.stdout)
ch.setFormatter(logging.Formatter("%(message)s"))
logger.addHandler(ch)

def log_struct(level: str, msg: str, **fields):
    rec = {
        "ts": datetime.utcnow().isoformat(),
        "level": level,
        "msg": msg
    }
    rec.update(fields)
    logger.info(json.dumps(rec))

# -------------------------
# Prometheus metrics
# -------------------------
temp_gauge = Gauge("machine_temperature_c", "Temperature (C)", ["device"])
vib_gauge = Gauge("machine_vibration_ms2", "Vibration (m/s2)", ["device"])
rpm_gauge = Gauge("machine_rpm", "Motor RPM", ["device"])
power_gauge = Gauge("machine_power_kw", "Power (kW)", ["device"])

event_counter = Counter("events_total", "Total events published")
anomaly_counter = Counter("anomaly_total", "Anomalies by type", ["type"])
anomaly_severity = Counter("anomaly_severity_total", "Anomalies by severity", ["level"])
temp_spike_hist = Histogram("temperature_spike_c", "Temperature spike distribution (C)", buckets=[5,10,15,20,25,30,35])
heartbeat_gauge = Gauge("machine_heartbeat", "Heartbeat (1=alive)", ["device"])

# -------------------------
# Strong certificate validation
# -------------------------
def validate_certificates(raise_on_error=True):
    """
    Validate that CA, certificate and private key:
     - files exist and are readable
     - are valid PEM
     - certificate not expired
     - certificate public key matches private key
     - log sha256 fingerprint and expiry
    Returns: dict with metadata on success
    Raises on failure if raise_on_error True
    """
    missing = []
    for name, path in (("Root CA", CA_PATH), ("Device Cert", CERT_PATH), ("Private Key", KEY_PATH)):
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

    # Load device cert and private key via pyOpenSSL
    try:
        with open(CERT_PATH, "rb") as f:
            cert_pem = f.read()
        cert = crypto.load_certificate(crypto.FILETYPE_PEM, cert_pem)
    except Exception as e:
        msg = f"Invalid device certificate PEM: {e}"
        if raise_on_error:
            raise RuntimeError(msg)
        else:
            log_struct("error", "cert_load_failed", error=str(e))
            return {"ok": False, "error": msg}

    try:
        with open(KEY_PATH, "rb") as f:
            key_pem = f.read()
        pkey = crypto.load_privatekey(crypto.FILETYPE_PEM, key_pem)
    except Exception as e:
        msg = f"Invalid private key PEM: {e}"
        if raise_on_error:
            raise RuntimeError(msg)
        else:
            log_struct("error", "key_load_failed", error=str(e))
            return {"ok": False, "error": msg}

    # Check certificate expiration
    try:
        not_after = cert.get_notAfter().decode("ascii")
        expiry_dt = datetime.strptime(not_after, "%Y%m%d%H%M%SZ").replace(tzinfo=timezone.utc)
    except Exception as e:
        expiry_dt = None

    if expiry_dt and expiry_dt < datetime.now(timezone.utc):
        msg = f"Certificate expired on {expiry_dt.isoformat()}"
        if raise_on_error:
            raise RuntimeError(msg)
        else:
            log_struct("error", "cert_expired", expiry=expiry_dt.isoformat())
            return {"ok": False, "error": msg}

    # Check certificate public key matches private key
    try:
        cert_pub = crypto.dump_publickey(crypto.FILETYPE_PEM, cert.get_pubkey())
        key_pub = crypto.dump_publickey(crypto.FILETYPE_PEM, crypto.load_privatekey(crypto.FILETYPE_PEM, key_pem))
        if cert_pub != key_pub:
            # Attempt fallback using openssl compare (some key variations possible)
            msg = "Device certificate public key does NOT match private key"
            if raise_on_error:
                raise RuntimeError(msg)
            else:
                log_struct("error", "cert_key_mismatch", error=msg)
                return {"ok": False, "error": msg}
    except Exception as e:
        msg = f"Failed to compare cert/public key: {e}"
        if raise_on_error:
            raise RuntimeError(msg)
        else:
            log_struct("error", "cert_key_compare_error", error=str(e))
            return {"ok": False, "error": msg}

    # sha256 fingerprint
    try:
        fingerprint = cert.digest("sha256").decode("ascii")
    except Exception:
        fingerprint = None

    meta = {
        "ok": True,
        "expires": expiry_dt.isoformat() if expiry_dt else None,
        "fingerprint_sha256": fingerprint
    }
    log_struct("info", "certificate_validation_passed", **meta)
    return meta

# -------------------------
# Anomaly injection & payload
# -------------------------
def inject_anomaly(data):
    anomaly_type = random.choices(
        ["none", "spike", "drift", "noise", "freeze", "combined"],
        weights=[0.7, 0.10, 0.05, 0.10, 0.03, 0.02],
        k=1
    )[0]

    severity = "info"
    if anomaly_type == "spike":
        spike = random.uniform(15, 35)
        data["temperature_c"] += spike
        temp_spike_hist.observe(spike)
        severity = "critical"
    elif anomaly_type == "drift":
        data["temperature_c"] += random.uniform(0.1, 0.5)
        severity = "warning"
    elif anomaly_type == "noise":
        data["rpm"] += int(random.gauss(0, 50))
        data["power_kw"] += random.gauss(0, 1.5)
        severity = "info"
    elif anomaly_type == "freeze":
        # simulate freeze by not changing values for a while (effect managed elsewhere if needed)
        severity = "warning"
    elif anomaly_type == "combined":
        data["temperature_c"] += random.uniform(5, 15)
        data["vibration_ms2"] += random.uniform(0.5, 1.5)
        data["rpm"] -= random.randint(100, 300)
        severity = "critical"

    anomaly_counter.labels(type=anomaly_type).inc()
    anomaly_severity.labels(level=severity).inc()
    return data, anomaly_type, severity

def make_payload(device_id):
    base_temp = 60 + (hash(device_id) % 5)
    data = {
        "device_id": device_id,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "temperature_c": round(base_temp + random.gauss(0, 2), 2),
        "vibration_ms2": round(random.uniform(0.1, 0.5), 3),
        "rpm": int(1400 + random.gauss(0, 30)),
        "power_kw": round(10 + random.gauss(0, 1), 2)
    }
    return inject_anomaly(data)

# -------------------------
# MQTT publisher thread
# -------------------------
def publisher(device_id):
    topic = f"{IOT_TOPIC}/{device_id}"
    client = mqtt.Client()
    try:
        client.tls_set(ca_certs=CA_PATH, certfile=CERT_PATH, keyfile=KEY_PATH)
    except Exception as e:
        log_struct("error", "tls_setup_failed", device=device_id, error=str(e))
        return

    client.reconnect_delay_set(min_delay=1, max_delay=32)

    # Connect with retries
    while True:
        try:
            client.connect(AWS_ENDPOINT, 8883)
            client.loop_start()
            log_struct("info", "mqtt_connected", device=device_id, endpoint=AWS_ENDPOINT, topic=topic)
            break
        except Exception as e:
            log_struct("warning", "mqtt_connect_failed", device=device_id, error=str(e))
            time.sleep(3)

    # Publish loop
    while True:
        payload, atype, severity = make_payload(device_id)
        try:
            client.publish(topic, json.dumps(payload), qos=1)
            event_counter.inc()
            temp_gauge.labels(device=device_id).set(payload["temperature_c"])
            vib_gauge.labels(device=device_id).set(payload["vibration_ms2"])
            rpm_gauge.labels(device=device_id).set(payload["rpm"])
            power_gauge.labels(device=device_id).set(payload["power_kw"])
            heartbeat_gauge.labels(device=device_id).set(1)
            log_struct("info", "published", device=device_id, topic=topic, anomaly=atype, severity=severity)
        except Exception as e:
            log_struct("error", "publish_failed", device=device_id, error=str(e))
        time.sleep(PUBLISH_INTERVAL)

# -------------------------
# Entrypoint
# -------------------------
def main():
    # Start prometheus exporter
    start_http_server(9100)
    log_struct("info", "starting_simulator", simulators=SIMULATOR_COUNT)

    # Validate certs before starting threads
    try:
        validate_certificates(raise_on_error=True)
    except Exception as e:
        log_struct("critical", "certificate_validation_error", error=str(e))
        # fail fast: logs will show why the instance failed
        raise

    # Basic sanity check for AWS endpoint
    if not AWS_ENDPOINT:
        raise RuntimeError("AWS_ENDPOINT environment variable is required and must be set to your IoT endpoint")

    # Launch simulator threads
    for i in range(1, SIMULATOR_COUNT + 1):
        device_id = f"M{i:03d}"
        t = threading.Thread(target=publisher, args=(device_id,), daemon=True)
        t.start()
        log_struct("info", "device_thread_started", device=device_id)

    # Keep main alive
    while True:
        time.sleep(5)

if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        log_struct("critical", "simulator_fatal", error=str(exc))
        raise

PYCODE

##########################################
# Prometheus configuration
##########################################
cat > /opt/iot-simulator/prometheus.yml <<PROM
global:
  scrape_interval: 5s
scrape_configs:
  - job_name: 'node'
    static_configs:
      - targets: ['node-exporter:9100']
  - job_name: 'iot-simulator'
    static_configs:
      - targets: ['iot-simulator:8000']
PROM

# --- Grafana provisioning directories ---
mkdir -p /opt/iot-simulator/grafana/provisioning/dashboards
mkdir -p /opt/iot-simulator/grafana/provisioning/alerting
mkdir -p /opt/iot-simulator/grafana/provisioning/notifiers

#####################################################
# --- Grafana dashboard for anomalies ---
#####################################################
cat > /opt/iot-simulator/grafana/provisioning/dashboards/anomalies.json <<'DASH'
{
  "dashboard": {
    "title": "IoT Simulator Anomalies",
    "schemaVersion": 36,
    "version": 1,
    "refresh": "10s",
    "panels": [
      {
        "type": "graph",
        "title": "Anomaly Frequency by Type",
        "datasource": "Prometheus",
        "targets": [
          { "expr": "rate(anomaly_type_total[5m])", "legendFormat": "{{type}}" }
        ]
      },
      {
        "type": "graph",
        "title": "Anomaly Ratio (%)",
        "datasource": "Prometheus",
        "targets": [
          { "expr": "(rate(anomaly_type_total[5m]) / rate(events_total[5m])) * 100", "legendFormat": "Anomaly Ratio" }
        ]
      },
      {
        "type": "bargauge",
        "title": "Anomaly Severity Breakdown",
        "datasource": "Prometheus",
        "targets": [
          { "expr": "anomaly_severity_total", "legendFormat": "{{level}}" }
        ]
      },
      {
        "type": "graph",
        "title": "Temperature Spike Distribution",
        "datasource": "Prometheus",
        "targets": [
          { "expr": "histogram_quantile(0.95, rate(temperature_spike_c_bucket[5m]))", "legendFormat": "95th percentile spike" }
        ]
      },
      {
        "type": "alertlist",
        "title": "Active Alerts",
        "datasource": "Prometheus",
        "options": { "show": "current", "stateFilter": ["alerting","pending"] }
      }
    ]
  },
  "overwrite": true
}
DASH

#####################################################
# --- Grafana alerting rules ---
#####################################################
cat > /opt/iot-simulator/grafana/provisioning/alerting/anomaly-alerts.yml <<'ALERTS'
apiVersion: 1
groups:
  - name: anomaly-alerts
    interval: 30s
    rules:
      - uid: anomaly-ratio-high
        title: "High Anomaly Ratio"
        condition: C
        data:
          - refId: A
            datasourceUid: prometheus
            model:
              expr: (rate(anomaly_type_total[5m]) / rate(events_total[5m])) * 100
        for: 2m
        annotations:
          summary: "Anomaly ratio exceeded 20%"
        labels:
          severity: warning
        notification_settings:
          contactPoint: email-notifier

      - uid: spike-severity-critical
        title: "Critical Temperature Spike"
        condition: C
        data:
          - refId: A
            datasourceUid: prometheus
            model:
              expr: histogram_quantile(0.95, rate(temperature_spike_c_bucket[5m]))
        for: 1m
        annotations:
          summary: "95th percentile spike > 25°C"
        labels:
          severity: critical
        notification_settings:
          contactPoint: email-notifier
ALERTS

#####################################################
# --- Grafana notifier scaffold (email optional) ---
#####################################################
cat > /opt/iot-simulator/grafana/provisioning/notifiers/email.yml <<'EMAIL'
notifiers:
  - name: Email Alerts
    type: email
    uid: email-notifier
    org_id: 1
    is_default: true
    settings:
      addresses: ${alert_email_recipients}
EMAIL

##########################################
# Write Dockerfile
##########################################
cat > /opt/iot-simulator/Dockerfile << 'DF'
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
ENV CERT_DIR=/app/certs
EXPOSE 9100
CMD ["python3", "iot_simulator.py"]
DF

##########################################
# Write docker-compose.yml
##########################################
cat > /opt/iot-simulator/docker-compose.yml << 'COMPOSE'
version: "3.8"
services:
  iot-simulator:
    build: .
    environment:
      - AWS_ENDPOINT=${aws_endpoint}
      - SIMULATOR_COUNT=${simulator_count}
      - CERT_DIR=/app/certs
      - IOT_TOPIC=factory/plant1/line1
    volumes:
      - ./certs:/app/certs:ro
    restart: always

  node-exporter:
    image: prom/node-exporter:latest
    ports:
      - "9100:9100"

  prometheus:
    image: prom/prometheus:latest
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml:ro
    ports:
      - "9090:9090"

  grafana:
    image: grafana/grafana:latest
    ports:
      - "3000:3000"
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=admin
      # --- Email alerting variables (optional, can be enabled later) ---
      # GF_SMTP_ENABLED=true
      # GF_SMTP_HOST=smtp.example.com:587
      # GF_SMTP_USER= $${smtp_user}
      # GF_SMTP_PASSWORD= $${smtp_password}
      # GF_SMTP_SKIP_VERIFY=true
      # GF_SMTP_FROM_ADDRESS=alerts@example.com
      # GF_SMTP_FROM_NAME=IoT Simulator Alerts
      # GF_SMTP_STARTTLS_POLICY=OpportunisticStartTLS
      # alert_email_recipients=you@example.com,team@example.com
    volumes:
      - ./grafana/provisioning:/etc/grafana/provisioning
COMPOSE

##########################################
# Start stack
##########################################
echo "Starting Docker containers..."
cd /opt/iot-simulator
docker-compose up -d

# --- Health checks and audit logging ---
echo "Validating container health..."
docker-compose ps

echo "Checking Docker service status..."
systemctl status docker --no-pager || echo "⚠️ Docker service not healthy"

echo "Checking AWS CLI version..."
aws --version || echo "⚠️ AWS CLI not found"

echo "Checking Python version..."
python3 --version || echo "⚠️ Python3 not found"

echo "Listing simulator logs..."
docker logs iot-simulator --tail 20 || echo "⚠️ Simulator logs unavailable"

echo "Listing Prometheus targets..."
curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets' || echo "⚠️ Prometheus targets check failed"

echo "=== IoT Simulator bootstrap complete ==="