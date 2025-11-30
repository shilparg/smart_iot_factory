variable "region" {
  type    = string
  default = "us-east-1"
  description = "AWS region to deploy resources"
}

variable "environment" {
  type    = string
  default = "dev"
  description = "Deployment environment (e.g., dev, staging, prod)"
}

variable "instance_type" {
  type    = string
  default = "t3.medium"
  description = "EC2 instance type for simulator host"
}

variable "simulator_count" {
  type    = number
  default = 2
  description = "Number of simulator EC2 instances to launch"
}

variable "allowed_cidr" {
  type        = string
  default     = "0.0.0.0/0"
  description = "CIDR block allowed to access EC2 services (e.g., SSH, Grafana, Prometheus)"
}

variable "config_s3_bucket" {
  type        = string
  description = "S3 bucket name for storing Prometheus/Grafana configs"
  default     = "ce11-grp1-iot-sim-config-dev"
}

variable "cert_s3_bucket" {
  type        = string
  description = "S3 bucket name for storing IoT certificates"
  default     = "ce11-grp1-iot-sim-certs-dev"
}

variable "cert_files" {
  type = map(string)
  description = "Map of certificate and key filenames to upload to S3"
  default = {
    root_ca     = "AmazonRootCA1.pem"
    device_cert = "device-certificate.pem.crt"
    private_key = "private.pem.key"
  }
}

variable "alert_email_recipients" {
  type        = list(string)
  description = "List of email addresses to receive alerts"
  default     = ["shilparg_2000@yahoo.com"]
}

variable "key_name" {
  type        = string
  description = "SSH keypair name for EC2 instance access"
  default     = "grp1-ec2-keypair.pem"
}

variable "iot_topic" {
  type        = string
  default     = "factory/plant1/line1"
  description = "MQTT topic for simulator publishing"
}

# ✅ Optional: Use locals for dynamic naming
# locals {
#   cert_s3_bucket = "iot-simulator-certs-${var.environment}"
# }