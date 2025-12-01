#!/bin/bash
set -euo pipefail

cd /opt/iot-simulator

TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
LOG_DIR="/opt/iot-simulator/logs/shutdown-$TIMESTAMP"

echo "=== Stopping IoT Simulator Stack ==="

mkdir -p "$LOG_DIR"

echo "Collecting logs before stop..."
docker logs iot-simulator > "$LOG_DIR/iot-simulator.log" 2>&1 || true
docker logs prometheus > "$LOG_DIR/prometheus.log" 2>&1 || true
# Uncomment if Grafana is enabled
# docker logs grafana > "$LOG_DIR/grafana.log" 2>&1 || true

echo "Stopping containers..."
docker compose down

echo "Stack stopped. Logs archived at:"
echo "  $LOG_DIR"
echo "=== Done. ==="
