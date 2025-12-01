#!/bin/bash
PROM_URL="http://44.197.172.202:9090"

# Fetch current metrics
curl -s "$PROM_URL/api/v1/label/__name__/values" | jq -r '.data[]' | sort > current_metrics.txt

# Compare with baseline
if [ -f baseline_metrics.txt ]; then
  echo "New metrics since last baseline:"
  comm -13 baseline_metrics.txt current_metrics.txt
else
  echo "No baseline found. Saving current metrics as baseline."
  cp current_metrics.txt baseline_metrics.txt
fi