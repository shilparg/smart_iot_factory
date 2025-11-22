#!/bin/bash
set -e

SIMULATOR_COUNT=${simulator_count}
REGION="${region}"
CERT_BUCKET="${cert_s3_bucket}"

yum update -y
amazon-linux-extras install docker -y
systemctl start docker
systemctl enable docker

curl -L "https://github.com/docker/compose/releases/download/1.29.2/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

mkdir -p /opt/iot-simulator
cd /opt/iot-simulator

# Download certs from S3
aws s3 cp s3://${CERT_BUCKET}/AmazonRootCA1.pem ./AmazonRootCA1.pem --region $REGION
aws s3 cp s3://${CERT_BUCKET}/device-certificate.pem.crt ./device-certificate.pem.crt --region $REGION
aws s3 cp s3://${CERT_BUCKET}/private.pem.key ./private.pem.key --region $REGION

# Docker files
cat > Dockerfile <<'EOF'
FROM python:3.10-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
CMD ["python3", "iot_simulator.py"]
EOF

cat > requirements.txt <<'EOF'
paho-mqtt
prometheus_client
EOF

cat > iot_simulator.py <<'EOF'
# (full Python simulator code goes here, same as your anomaly injection + Prometheus metrics)
import os, time, json, random, threading
from datetime import datetime, timezone
import paho.mqtt.client as mqtt
from prometheus_client import start_http_server, Gauge

AWS_ENDPOINT = os.getenv('AWS_ENDPOINT','')
SIMULATOR_COUNT = int(os.getenv('SIMULATOR_COUNT','2'))

temp_gauge = Gauge('machine_temperature','Temperature', ['device'])
vib_gauge = Gauge('machine_vibration','Vibration', ['device'])
rpm_gauge = Gauge('machine_rpm','RPM', ['device'])

def inject_anomaly(data):
    anomaly_type = random.choices(["none","spike","drift","noise","freeze","combined"],[0.7,0.1,0.05,0.1,0.03,0.02])[0]
    if anomaly_type == "spike":
        data['temperature_c'] += random.uniform(15,35)
        data['vibration_ms2'] += random.uniform(0.5,1.0)
    elif anomaly_type == "drift":
        data['temperature_c'] += random.uniform(0.1,0.5)
    elif anomaly_type == "noise":
        data['rpm'] += int(random.gauss(0,50))
        data['power_kw'] += random.gauss(0,1.5)
    elif anomaly_type == "freeze":
        pass
    elif anomaly_type == "combined":
        data['temperature_c'] += random.uniform(5,15)
        data['vibration_ms2'] += random.uniform(0.5,1.5)
        data['rpm'] -= random.randint(100,300)
    return data, anomaly_type

def make_payload(device_id):
    base_temp = 60 + (hash(device_id)%5)
    data = {
        "device_id": device_id,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "temperature_c": round(base_temp + random.gauss(0,2),2),
        "vibration_ms2": round(random.uniform(0.1,0.5),3),
        "rpm": int(1400 + random.gauss(0,30)),
        "power_kw": round(10 + random.gauss(0,1),2)
    }
    data, anomaly = inject_anomaly(data)
    data['anomaly_type'] = anomaly
    return data

def publisher(device_id):
    client = mqtt.Client()
    ca, cert, key = 'AmazonRootCA1.pem','device-certificate.pem.crt','private.pem.key'
    if os.path.exists(ca) and os.path.exists(cert) and os.path.exists(key):
        client.tls_set(ca_certs=ca, certfile=cert, keyfile=key)
    client.connect(AWS_ENDPOINT,8883)
    client.loop_start()
    topic = f'factory/plant1/line1/{device_id}'
    while True:
        p = make_payload(device_id)
        client.publish(topic,json.dumps(p),qos=1)
        temp_gauge.labels(device=device_id).set(p['temperature_c'])
        vib_gauge.labels(device=device_id).set(p['vibration_ms2'])
        rpm_gauge.labels(device=device_id).set(p['rpm'])
        time.sleep(1)

if __name__ == '__main__':
    start_http_server(9100)
    for i in range(1,SIMULATOR_COUNT+1):
        device_id = f'M{i:03d}'
        threading.Thread(target=publisher,args=(device_id,),daemon=True).start()
    while True:
        time.sleep(1)
EOF

# docker-compose.yml
cat > docker-compose.yml <<'EOF'
version: '3.8'
services:
  iot-simulator:
    build: .
    environment:
      - AWS_ENDPOINT=<YOUR_IOT_ENDPOINT>
      - SIMULATOR_COUNT=${SIMULATOR_COUNT}
    restart: always

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
EOF

# Prometheus config
cat > prometheus.yml <<'EOF'
global:
  scrape_interval: 5s
scrape_configs:
  - job_name: 'iot-sim'
    static_configs:
      - targets: ['localhost:9100']
EOF

# Start Docker
docker-compose up -d
