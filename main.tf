data "aws_availability_zones" "available" {
  state = "available"
}

# Get AWS IoT endpoint
data "aws_iot_endpoint" "iot" {
  endpoint_type = "iot:Data-ATS"
}

# AMI Data Source
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
}

############################################
# Networking
############################################

# VPC and Subnet
resource "aws_vpc" "this" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = { Name = "iot-sim-vpc-${var.environment}" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = data.aws_availability_zones.available.names[0]
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.this.id
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}

resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}


############################################
# Security Group
############################################

resource "aws_security_group" "ec2_sg" {
  name        = "iot-sim-ec2-sg-${var.environment}"
  description = "Allow SSH, Grafana, Prometheus"
  vpc_id      = aws_vpc.this.id

  dynamic "ingress" {
    for_each = [22, 3000, 9090]
    content {
      from_port   = ingress.value
      to_port     = ingress.value
      protocol    = "tcp"
      cidr_blocks = [var.allowed_cidr]
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

############################################
# IAM Role + Instance Profile
############################################
data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

# Policy document for Secrets Manager access
data "aws_iam_policy_document" "secretsmanager_access" {
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = ["arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:grafana/smtp-*"]
    effect    = "Allow"
  }
}

# Caller identity (needed for account_id interpolation)
data "aws_caller_identity" "current" {}

resource "aws_iam_role" "ec2_role" {
  name               = "iot-sim-${var.environment}-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

# Create IAM policy
resource "aws_iam_policy" "secretsmanager_policy" {
  name        = "iot-sim-${var.environment}-secretsmanager-policy"
  description = "Allow EC2 Grafana host to read SMTP secrets"
  policy      = data.aws_iam_policy_document.secretsmanager_access.json
}

# Attach policy to EC2 role
resource "aws_iam_role_policy_attachment" "secretsmanager_attach" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = aws_iam_policy.secretsmanager_policy.arn
}

# Attach Systems Manager core permissions
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Attach CloudWatch agent permissions
resource "aws_iam_role_policy_attachment" "cloudwatch" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# Attach S3 read-only permissions
resource "aws_iam_role_policy_attachment" "s3_read" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
}

# Instance profile for EC2
resource "aws_iam_instance_profile" "ec2_profile" {
  name = "iot-sim-ec2-profile-${var.environment}"
  role = aws_iam_role.ec2_role.name
}

############################################
# S3 Buckets
############################################

variable "create_buckets" {
  type    = bool
  default = true
}

# Create buckets only if flag is true
resource "aws_s3_bucket" "config_bucket" {
  count         = var.create_buckets ? 1 : 0
  bucket        = var.config_s3_bucket
  force_destroy = true
}

resource "aws_s3_bucket" "cert_bucket" {
  count         = var.create_buckets ? 1 : 0
  bucket        = var.cert_s3_bucket
  force_destroy = true
}

# Otherwise, look them up as data sources
data "aws_s3_bucket" "config_bucket" {
  count  = var.create_buckets ? 0 : 1
  bucket = var.config_s3_bucket
}

data "aws_s3_bucket" "cert_bucket" {
  count  = var.create_buckets ? 0 : 1
  bucket = var.cert_s3_bucket
}

###########################################
#Unified locals for downstream references
###########################################
locals {
  config_bucket = var.create_buckets ? aws_s3_bucket.config_bucket[0].bucket : data.aws_s3_bucket.config_bucket[0].bucket
  cert_bucket   = var.create_buckets ? aws_s3_bucket.cert_bucket[0].bucket   : data.aws_s3_bucket.cert_bucket[0].bucket
}

#  Unified outputs (works regardless of create/reuse)
# output "config_bucket_name" {
#   value = var.create_buckets
#     ? aws_s3_bucket.config_bucket[0].bucket
#     : data.aws_s3_bucket.config_bucket[0].bucket
# }

# output "cert_bucket_name" {
#   value = var.create_buckets
#     ? aws_s3_bucket.cert_bucket[0].bucket
#     : data.aws_s3_bucket.cert_bucket[0].bucket
# }

############################################
# EC2 Instance
############################################
resource "aws_instance" "sim_host" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  key_name               = var.key_name
  vpc_security_group_ids = [aws_security_group.ec2_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_profile.name

  user_data = templatefile("${path.module}/user-data.sh.tpl", {
    simulator_count        = var.simulator_count
    cert_s3_bucket         = local.cert_bucket
    config_s3_bucket       = local.config_bucket
    region                 = var.region
    aws_endpoint           = data.aws_iot_endpoint.iot.endpoint_address
    iot_topic              = var.iot_topic
    alert_email_recipients = join(",", var.alert_email_recipients)
  })

  tags = {
    Name = "ce11-grp1-iot-sim-host-${var.environment}"
  }
}


############################################
# IoT Resources
############################################
resource "aws_iot_thing" "simulator" {
  name = "iot-sim-thing-${var.environment}"
}

resource "aws_iot_policy" "sim_policy" {
  name   = "iot-sim-policy-${var.environment}"
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = [
          "iot:Connect",
          "iot:Publish",
          "iot:Subscribe",
          "iot:Receive"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iot_certificate" "sim_cert" {
  active = true
}

resource "aws_iot_policy_attachment" "attach" {
  policy = aws_iot_policy.sim_policy.name
  target = aws_iot_certificate.sim_cert.arn
}

resource "aws_iot_thing_principal_attachment" "attach_cert" {
  thing     = aws_iot_thing.simulator.name
  principal = aws_iot_certificate.sim_cert.arn
}

############################################
# Monitoring Configs (Prometheus + Grafana)
############################################
resource "aws_s3_object" "prometheus_config" {
  bucket = local.config_bucket #$aws_s3_bucket.config_bucket.bucket
  key    = "prometheus/prometheus.yaml"
  source = "${path.module}/prometheus/prometheus.yaml"
  etag   = filemd5("${path.module}/prometheus/prometheus.yaml")
}

resource "aws_s3_object" "grafana_ini" {
  bucket = local.config_bucket #aws_s3_bucket.config_bucket.bucket
  key    = "grafana/provisioning/grafana.ini"
  source = "${path.module}/grafana/provisioning/grafana.ini"
  etag   = filemd5("${path.module}/grafana/provisioning/grafana.ini")
}

resource "aws_s3_object" "grafana_dashboards_config" {
  bucket = local.config_bucket #aws_s3_bucket.config_bucket.bucket
  key    = "grafana/provisioning/dashboards/dashboards.yaml"
  source = "${path.module}/grafana/provisioning/dashboards/dashboards.yaml"
  etag   = filemd5("${path.module}/grafana/provisioning/dashboards/dashboards.yaml")
}

locals {
  dashboard_files = {
    "anomalies/anomalies.json"         = "grafana/provisioning/dashboards/anomalies/anomalies.json"
    "system-health/system-health.json" = "grafana/provisioning/dashboards/system-health/system-health.json"
    "latency/latency.json"             = "grafana/provisioning/dashboards/latency/latency.json"
    "iot-sim/iot-sim-dashboard3.json"  = "grafana/provisioning/dashboards/iot-sim/iot-sim-dashboard3.json"
    "executive-overview/executive-overview.json"  = "grafana/provisioning/dashboards/executive-overview/executive-overview.json"
  }
}

resource "aws_s3_object" "grafana_dashboards" {
  for_each = local.dashboard_files
  bucket   = local.config_bucket #aws_s3_bucket.config_bucket.bucket
  key      = "grafana/provisioning/dashboards/${each.key}"
  source   = "${path.module}/${each.value}"
  etag     = filemd5("${path.module}/${each.value}")
}

resource "aws_s3_object" "grafana_notifier_email" {
  bucket = local.config_bucket #aws_s3_bucket.config_bucket.bucket
  key    = "grafana/provisioning/notifiers/contact-points.yaml"
  source = "${path.module}/grafana/provisioning/notifiers/contact-points.yaml"
  etag   = filemd5("${path.module}/grafana/provisioning/notifiers/contact-points.yaml")
}

resource "aws_s3_object" "grafana_alerting_anomaly_alerts" {
  bucket = local.config_bucket #aws_s3_bucket.config_bucket.bucket
  key    = "grafana/provisioning/alerting/anomaly-alerts.yaml"
  source = "${path.module}/grafana/provisioning/alerting/anomaly-alerts.yaml"
  etag   = filemd5("${path.module}/grafana/provisioning/alerting/anomaly-alerts.yaml")
}

resource "aws_s3_object" "grafana_alerting_notify_policies" {
  bucket = local.config_bucket #aws_s3_bucket.config_bucket.bucket
  key    = "grafana/provisioning/alerting/notification-policies.yaml"
  source = "${path.module}/grafana/provisioning/alerting/notification-policies.yaml"
  etag   = filemd5("${path.module}/grafana/provisioning/alerting/notification-policies.yaml")
}

resource "aws_s3_object" "grafana_datasources" {
  bucket = local.config_bucket #aws_s3_bucket.config_bucket.bucket
  key    = "datasources/datasources.yaml"
  source = "${path.module}/datasources/datasources.yaml"
  etag   = filemd5("${path.module}/datasources/datasources.yaml")
}

resource "aws_s3_object" "iot_simulator_script" {
  bucket = local.config_bucket #aws_s3_bucket.config_bucket.bucket
  key    = "iot-simulator/iot-simulator.py"
  source = "${path.module}/iot-simulator/iot_simulator.py"
  etag   = filemd5("${path.module}/iot-simulator/iot_simulator.py")
}

############################################
# Certificates Upload
############################################
resource "aws_s3_object" "certs" {
  for_each = var.cert_files
  bucket   = local.cert_bucket #aws_s3_bucket.cert_bucket.id
  key      = each.value
  source   = "${path.module}/certs/${each.value}"
  etag     = filemd5("${path.module}/certs/${each.value}")
}
