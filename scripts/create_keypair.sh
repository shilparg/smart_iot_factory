#!/bin/bash
set -euo pipefail

KEY_NAME="grp1-ec2-keypair"
KEY_FILE="${KEY_NAME}.pem"

# Remove old key file if it exists
rm -f "$KEY_FILE"

# Create new key pair and save private key material
aws ec2 create-key-pair \
  --key-name "$KEY_NAME" \
  --query 'KeyMaterial' \
  --output text > "$KEY_FILE"

# Restrict permissions on the private key
chmod 400 "$KEY_FILE"

echo "Key pair $KEY_NAME created and saved to $KEY_FILE"