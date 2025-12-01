#!/bin/bash

#DASHBOARD_DIR="/opt/iot-simulator/config/dashboards"
DASHBOARD_DIR="grafana/provisioning/dashboards"
DATASOURCE="Prometheus"

echo "Patching Grafana dashboard JSON files in $DASHBOARD_DIR ..."
echo "-----------------------------------------------------------"

find "$DASHBOARD_DIR" -type f -name "*.json" | while read -r file; do
  if grep -q '"datasource"' "$file"; then
    echo "✅ $file → already has datasource"
  else
    echo "⚠️ $file → datasource missing, patching..."
    # Use jq to inject datasource into every panel
    tmpfile=$(mktemp)
    jq --arg ds "$DATASOURCE" '
      .panels |= map(
        if has("datasource") then . else . + {datasource: $ds} end
      )
    ' "$file" > "$tmpfile" && mv "$tmpfile" "$file"
    echo "✅ $file → patched with datasource=$DATASOURCE"
  fi
done