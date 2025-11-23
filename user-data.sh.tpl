#!/bin/bash
set -e
exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

# Variables from Terraform
SIMULATOR_COUNT=${simulator_count}
CERT_BUCKET=${cert_s3_bucket}
REGION=${region}
AWS_ENDPOINT=${aws_endpoint}

echo "=== Starting IoT Simulator bootstrap ==="
echo "Simulator count: $SIMULATOR_COUNT"
echo "Bucket: $CERT_BUCKET"
echo "Region: $REGION"
echo "AWS IoT endpoint: $AWS_ENDPOINT"

# Install system updates
yum update -y

# --- Install AWS CLI v2 ---
if ! command -v aws &> /dev/null; then
  yum install -y unzip
  curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
  unzip awscliv2.zip
  ./aws/install
fi

# --- Install Docker ---
amazon-linux-extras install docker -y || dnf install docker -y
systemctl enable docker
systemctl start docker
usermod -aG docker ec2-user

# --- Install Docker Compose v2 ---
curl -SL "https://github.com/docker/compose/releases/download/v2.24.6/docker-compose-$(uname -s)-$(uname -m)" \
  -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose
docker-compose --version

# --- Create working directory ---
mkdir -p /opt/iot-simulator
cd /opt/iot-simulator

# --- Create certificate directory ---
mkdir -p /opt/iot-simulator/certs
chown ec2-user:ec2-user /opt/iot-simulator/certs

echo "Bucket: $CERT_BUCKET"
echo "Region: $REGION"
echo "Downloading certs..."

# --- Download certificates from S3 ---
echo "Downloading certs from: s3://$CERT_BUCKET"

aws s3 cp "s3://$CERT_BUCKET/AmazonRootCA1.pem" \
    "/opt/iot-simulator/certs/AmazonRootCA1.pem" --region "$REGION"

aws s3 cp "s3://$CERT_BUCKET/device-certificate.pem.crt" \
    "/opt/iot-simulator/certs/device-certificate.pem.crt" --region "$REGION"

aws s3 cp "s3://$CERT_BUCKET/private.pem.key" \
    "/opt/iot-simulator/certs/private.pem.key" --region "$REGION"

chmod 600 /opt/iot-simulator/certs/*
chown ec2-user:ec2-user /opt/iot-simulator/certs/*

# --- Validate certificates ---
echo "Validating certificates..."

for file in AmazonRootCA1.pem device-certificate.pem.crt private.pem.key; do
  if [ ! -f "/opt/iot-simulator/certs/$file" ]; then
    echo "❌ ERROR: Missing /opt/iot-simulator/certs/$file"
    exit 1
  else
    echo "✅ Found $file"
  fi
done

# --- (Optional) Install Python IoT SDK ---
yum install -y python3 pip
pip3 install AWSIoTPythonSDK

# --- Generate Docker Compose ---
cat > /opt/iot-simulator/docker-compose.yml <<DOCKER
version: '3.8'
services:
  iot-simulator:
    build: .
    environment:
      - AWS_ENDPOINT=$AWS_ENDPOINT
      - SIMULATOR_COUNT=$SIMULATOR_COUNT
    volumes:
      - ./certs:/app/certs
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
DOCKER

# Prometheus configuration
cat > /opt/iot-simulator/prometheus.yml <<PROM
global:
  scrape_interval: 5s
scrape_configs:
  - job_name: 'iot-sim'
    static_configs:
      - targets: ['localhost:9100']
PROM

# Start containers
echo "Starting Docker containers..."
cd /opt/iot-simulator
docker-compose up -d

echo "=== IoT Simulator bootstrap complete ==="