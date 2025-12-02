#!/bin/bash
set -euo pipefail

LOGFILE="/var/log/iot-healthcheck.log"
exec > >(tee -a "$LOGFILE") 2>&1

echo "=== Starting IoT Simulator Health Check ==="

##########################################
# System & Service Checks
##########################################
echo "[1] Checking Docker service..."
systemctl is-active --quiet docker && echo "✅ Docker is active" || echo "❌ Docker not running"

echo "[2] Checking Docker Compose..."
docker-compose --version || echo "❌ Docker Compose not found"

echo "[3] Checking AWS CLI..."
aws --version || echo "❌ AWS CLI not found"

echo "[4] Checking Python..."
python3 --version || echo "❌ Python3 not found"

##########################################
# Container Checks
##########################################
echo "[5] Listing containers..."
docker-compose ps

echo "[6] IoT Simulator logs (last 20 lines)..."
docker logs iot-simulator --tail 20 || echo "⚠️ Simulator logs unavailable"

echo "[7] Prometheus targets..."
curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets' || echo "⚠️ Prometheus targets check failed"

echo "[8] Grafana plugins..."
docker exec grafana grafana-cli plugins ls || echo "⚠️ Grafana plugins check failed"

echo "[9] Grafana provisioning directories..."
docker exec grafana ls -R /etc/grafana/provisioning || echo "⚠️ Grafana provisioning check failed"

echo "[10] Node Exporter metrics..."
curl -s http://localhost:9101/metrics | head -n 5 || echo "⚠️ Node Exporter metrics unavailable"

##########################################
# Certificate & Config Checks
##########################################
echo "[11] Validating certificates..."
for file in AmazonRootCA1.pem device-certificate.pem.crt private.pem.key; do
  if [ -f "/opt/iot-simulator/certs/$file" ]; then
    echo "✅ Found $file"
  else
    echo "❌ Missing $file"
  fi
done

echo "[12] Listing config files..."
ls -R /opt/iot-simulator/config || echo "⚠️ Config files missing"

##########################################
# End-to-End IoT Connectivity Test
##########################################
echo "[13] Publishing test MQTT message..."

AWS_ENDPOINT="${AWS_ENDPOINT:-$(grep AWS_ENDPOINT docker-compose.yml | head -1 | cut -d: -f2 | tr -d ' ')}"
IOT_TOPIC="${IOT_TOPIC:-test/iot-simulator/health}"

mosquitto_pub -h "$AWS_ENDPOINT" -p 8883 \
  -t "$IOT_TOPIC" \
  -m "healthcheck-$(date)" \
  --cafile /opt/iot-simulator/certs/AmazonRootCA1.pem \
  --cert /opt/iot-simulator/certs/device-certificate.pem.crt \
  --key /opt/iot-simulator/certs/private.pem.key \
  && echo "✅ MQTT publish succeeded" \
  || echo "❌ MQTT publish failed"

echo "=== Health Check Complete ==="