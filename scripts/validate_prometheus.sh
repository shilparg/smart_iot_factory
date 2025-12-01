#!/bin/bash

PROM_URL="http://44.197.172.202:9090"

# List of metrics to check
METRICS=(
  "node_cpu_seconds_total"
  "node_memory_MemTotal_bytes"
  "node_filesystem_size_bytes"
  "anomaly_type_total"
  "events_total"
  "anomaly_severity_total"
  "temperature_spike_c_bucket"
)

echo "Checking Prometheus metrics at $PROM_URL ..."
echo "--------------------------------------------"

for metric in "${METRICS[@]}"; do
  echo -n "Metric: $metric ... "
  result=$(curl -s "$PROM_URL/api/v1/query?query=$metric" | jq '.data.result | length')
  if [ "$result" -gt 0 ]; then
    echo "✅ Found ($result series)"
  else
    echo "❌ Not found"
  fi
done