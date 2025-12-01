#!/bin/bash
set -euo pipefail

cd /opt/iot-simulator

echo "=== Starting IoT Simulator Stack ==="

# Optional: pull latest image versions (safe even for Option B)
docker compose pull || echo "No images to pull (local build). Continuing..."

# Start containers
docker compose up -d

echo "Waiting 5 seconds for services to initialize..."
sleep 5

echo "=== Container Status ==="
docker compose ps

echo "=== IoT Simulator Logs (last 20 lines) ==="
docker logs iot-simulator --tail 20 || true

echo "=== Done. Stack is running. ==="
