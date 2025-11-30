# terraform.tfvars

region          = "us-east-1"
environment     = "dev"
instance_type   = "t3.medium"

# Provide your actual SSH keypair name here
key_name        = "grp1-ec2-keypair"

# Number of simulator EC2 instances
simulator_count = 2

# CIDR block allowed to access EC2 services
allowed_cidr    = "0.0.0.0/0"

# S3 bucket name for storing IoT certificates
# Explicitly set here instead of interpolating in variable default
cert_s3_bucket  = "ce11-grp1-iot-sim-certs-dev"

# S3 bucket for configurations
config_s3_bucket  = "ce11-grp1-iot-sim-config-dev"
alert_email_recipients = ["shilparg_2000@yahoo.com"] #["shilparg_2000@yahoo.com", "dev@example.com"]