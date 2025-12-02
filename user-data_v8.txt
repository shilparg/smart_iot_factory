#!/bin/bash
set -euo pipefail
exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

##########################################
# Variables from Terraform
##########################################
SIMULATOR_COUNT="${simulator_count}"
CERT_BUCKET="${cert_s3_bucket}"
CONFIG_BUCKET="${config_s3_bucket}"
REGION="${region}"
AWS_ENDPOINT="${aws_endpoint}"
IOT_TOPIC="${iot_topic}"
ALERT_EMAIL_RECIPIENTS="${alert_email_recipients}"

echo "=== Starting IoT Simulator bootstrap ==="
echo "Simulator count: $SIMULATOR_COUNT"
echo "Certificate bucket: $CERT_BUCKET"
echo "Config bucket: $CONFIG_BUCKET"
echo "Region: $REGION"
echo "AWS IoT endpoint: $AWS_ENDPOINT"

##########################################
# Create directory structure
##########################################
echo "Creating directory structure..."
mkdir -p /opt/iot-simulator/app
mkdir -p /opt/iot-simulator/certs
mkdir -p /opt/iot-simulator/config
mkdir -p /opt/iot-simulator/config/dashboards
mkdir -p /opt/iot-simulator/config/dashboards/anomalies
mkdir -p /opt/iot-simulator/config/dashboards/iot-sim
mkdir -p /opt/iot-simulator/config/dashboards/latency
mkdir -p /opt/iot-simulator/config/dashboards/system-health
mkdir -p /opt/iot-simulator/config/alerting
mkdir -p /opt/iot-simulator/config/notifiers
cd /opt/iot-simulator
echo "Directory structure created:"
ls -R /opt/iot-simulator

##########################################
# Install system packages
##########################################
yum update -y
amazon-linux-extras install docker -y || dnf install docker -y
yum install -y python3 python3-pip jq curl

# Enable and start Docker
systemctl enable docker
systemctl start docker

# Add ec2-user to Docker group for non-sudo access
usermod -aG docker ec2-user
newgrp docker <<'EOT'
echo "Docker group applied for ec2-user"
EOT

##########################################
# Install Docker Compose v2
##########################################
echo "=== Installing Docker Compose ==="

# Hardcoded Docker Compose version
DOCKER_COMPOSE_VERSION="v2.24.6"

# Download Docker Compose using Terraform-safe variable escaping
curl -SL "https://github.com/docker/compose/releases/download/$${DOCKER_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" \
  -o /usr/local/bin/docker-compose

# Make it executable and available in PATH
chmod +x /usr/local/bin/docker-compose
ln -s /usr/local/bin/docker-compose /usr/bin/docker-compose || true

# Verify installation
docker-compose version || echo "⚠️ Docker Compose installation failed"

echo "✅ Docker Compose installed successfully"

##########################################
# Helper function for S3 copy with status
##########################################
s3_copy_file() {
    local SRC="$1"
    local DEST="$2"
    echo "Downloading $SRC to $DEST ..."
    if aws s3 cp "$SRC" "$DEST" --region "$REGION"; then
        echo "✅ Successfully downloaded $DEST"
    else
        echo "❌ Failed to download $SRC"
    fi
}

##########################################
# Download AWS IoT Certificates
##########################################
s3_copy_file "s3://${cert_s3_bucket}/AmazonRootCA1.pem" "/opt/iot-simulator/certs/AmazonRootCA1.pem"
s3_copy_file "s3://${cert_s3_bucket}/device-certificate.pem.crt" "/opt/iot-simulator/certs/device-certificate.pem.crt"
s3_copy_file "s3://${cert_s3_bucket}/private.pem.key" "/opt/iot-simulator/certs/private.pem.key"

chmod 600 /opt/iot-simulator/certs/*
chown -R ec2-user:ec2-user /opt/iot-simulator

##########################################
# Validate certificates
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
# Download Config Files
##########################################
s3_copy_file "s3://${config_s3_bucket}/prometheus/prometheus.yml" "/opt/iot-simulator/config/prometheus.yml"
s3_copy_file "s3://${config_s3_bucket}/grafana/provisioning/grafana.ini" "/opt/iot-simulator/config/grafana.ini"
s3_copy_file "s3://${config_s3_bucket}/grafana/provisioning/dashboards/anomalies/anomalies.json" "/opt/iot-simulator/config/dashboards/anomalies/anomalies.json"
s3_copy_file "s3://${config_s3_bucket}/grafana/provisioning/dashboards/iot-sim/iot-sim-dashboard3.json" "/opt/iot-simulator/config/dashboards/iot-sim/iot-sim-dashboard3.json"
s3_copy_file "s3://${config_s3_bucket}/grafana/provisioning/dashboards/latency/latency.json" "/opt/iot-simulator/config/dashboards/latency/latency.json"
s3_copy_file "s3://${config_s3_bucket}/grafana/provisioning/dashboards/system-health/system-health.json" "/opt/iot-simulator/config/dashboards/system-health/system-health.json"
s3_copy_file "s3://${config_s3_bucket}/grafana/provisioning/dashboards/dashboards.yml" "/opt/iot-simulator/config/dashboards/dashboards.yml"
s3_copy_file "s3://${config_s3_bucket}/grafana/provisioning/alerting/anomaly-alerts.yml" "/opt/iot-simulator/config/alerting/anomaly-alerts.yml"
s3_copy_file "s3://${config_s3_bucket}/grafana/provisioning/notifiers/email.yml" "/opt/iot-simulator/config/notifiers/email.yml"

echo "Listing downloaded Grafana files:"
ls -R /opt/iot-simulator/config/

##########################################
# Install IoT Simulator Python script
##########################################
s3_copy_file "s3://${config_s3_bucket}/iot-simulator/iot-simulator.py" "/opt/iot-simulator/app/iot-simulator.py"
chmod +x app/iot-simulator.py
echo "IoT simulator script downloaded:"
ls -ltr /opt/iot-simulator/app/

##########################################
# requirements.txt
##########################################
cat > requirements.txt << 'REQ'
paho-mqtt
prometheus_client
pyOpenSSL<24.0.0
AWSIoTPythonSDK>=1.5.0,<2.0.0
requests
REQ

##########################################
# Dockerfile (Option A - Build Image)
##########################################
cat > Dockerfile << 'DF'
FROM python:3.11-slim
WORKDIR /app

COPY requirements.txt ./ 
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app
#COPY certs ./certs

ENV CERT_DIR=/app/certs
EXPOSE 9100

CMD ["python3", "app/iot-simulator.py"]
DF

##########################################
# docker-compose.yml
##########################################
cat > docker-compose.yml << 'EOF'
version: "3.8"

services:
  iot-simulator:
    build: .
    ports:
    - "9200:9100"
    environment:
      AWS_ENDPOINT: "${aws_endpoint}"
      SIMULATOR_COUNT: "${simulator_count}"
      CERT_DIR: "/app/certs"
      IOT_TOPIC: "${iot_topic}"
    volumes:
      - ./certs:/app/certs:ro
      - ./app:/app
    restart: always
    command: ["python3", "/app/iot-simulator.py"]
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:9100/metrics"]
      interval: 30s
      timeout: 10s
      retries: 3

  node-exporter:
    image: prom/node-exporter:latest
    ports:
      - "9101:9100" #"9100:9100"

  prometheus:
    image: prom/prometheus:latest
    volumes:
      - ./config/prometheus.yml:/etc/prometheus/prometheus.yml
    ports:
      - "9090:9090"

  grafana:
    image: grafana/grafana:latest
    ports:
      - "3000:3000"
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=admin
      - GF_PATHS_PROVISIONING=/etc/grafana/provisioning
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
      # Main Grafana config
      - ./config/grafana.ini:/etc/grafana/provisioning/grafana.ini

      # Provisioned dashboards (requires dashboards.yml + anomalies.json)
      - ./config/dashboards:/etc/grafana/provisioning/dashboards

      # Alerting rules
      - ./config/alerting:/etc/grafana/provisioning/alerting

      # Notifiers (e.g. email)
      - ./config/notifiers:/etc/grafana/provisioning/notifiers
EOF

##########################################
# Start stack
##########################################
echo "Starting Docker containers..."
cd /opt/iot-simulator
docker-compose up -d

##########################################
# --- Health checks and audit logging ---
##########################################
echo "Validating container health..."
docker-compose ps

echo "Checking Docker service status..."
systemctl status docker --no-pager || echo "⚠️ Docker service not healthy"

echo "Checking AWS CLI version..."
aws --version || echo "⚠️ AWS CLI not found"

echo "Checking Python version..."
python3 --version || echo "⚠️ Python3 not found"

sleep 10

echo "Listing simulator logs..."
docker logs iot-simulator --tail 20 || echo "⚠️ Simulator logs unavailable"

echo "Listing Prometheus targets..."
curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets' || echo "⚠️ Prometheus targets check failed"

echo "Listing Grafana plugins..."
docker exec grafana grafana-cli plugins ls || echo "⚠️ Grafana plugins check failed"

echo "Checking Grafana provisioning directories..."
docker exec grafana ls -R /etc/grafana/provisioning || echo "⚠️ Grafana provisioning check failed"

echo "=== IoT Simulator bootstrap complete ==="
