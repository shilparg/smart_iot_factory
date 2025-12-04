#!/bin/bash
ENDPOINT="a19iwwhi2w6u01-ats.iot.us-east-1.amazonaws.com"
PORT=8883
TOPIC="test/topic"

CAFILE=/home/shilpakk/terraform_prj/smart_iot_factory/certs/AmazonRootCA1.pem
CERTFILE=/home/shilpakk/terraform_prj/smart_iot_factory/certs/device-certificate.pem.crt
KEYFILE=/home/shilpakk/terraform_prj/smart_iot_factory/certs/private.pem.key

echo "Starting subscriber on topic: $TOPIC..."
mosquitto_sub -h $ENDPOINT -p $PORT \
  --cafile $CAFILE \
  --cert $CERTFILE \
  --key $KEYFILE \
  -t "$TOPIC" > /tmp/mqtt_sub_output.log 2>&1 &

SUB_PID=$!
sleep 2

echo "Publishing test message..."
mosquitto_pub -h $ENDPOINT -p $PORT \
  --cafile $CAFILE \
  --cert $CERTFILE \
  --key $KEYFILE \
  -t "$TOPIC" -m "hello world"

sleep 2

echo "Stopping subscriber..."
kill $SUB_PID 2>/dev/null

echo "Subscriber output:"
cat /tmp/mqtt_sub_output.log