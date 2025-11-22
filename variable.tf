variable "region" {
  type    = string
  default = "us-east-1"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "instance_type" {
  type    = string
  default = "t3.medium"
}

variable "key_name" {
  type        = string
  description = "SSH keypair name for EC2 instance access"
}

variable "simulator_count" {
  type    = number
  default = 2
}

variable "allowed_cidr" {
  type    = string
  default = "0.0.0.0/0"
  description = "CIDR block allowed to access EC2 services (e.g., SSH, Grafana, Prometheus)"
}

variable "cert_s3_bucket" {
  type        = string
  description = "S3 bucket name for storing IoT certificates"
  default     = "iot-simulator-certs-${var.environment}"  # ❌ Invalid interpolation in default
}