data "aws_availability_zones" "available" {
  state = "available"
}

# VPC and Subnet
resource "aws_vpc" "this" {
  cidr_block = "10.0.0.0/16"
  tags = { Name = "iot-sim-vpc-${var.environment}" }
}

resource "aws_subnet" "public" {
  vpc_id = aws_vpc.this.id
  cidr_block = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone = data.aws_availability_zones.available.names[0]
}

resource "aws_internet_gateway" "igw" { vpc_id = aws_vpc.this.id }

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route { cidr_block = "0.0.0.0/0", gateway_id = aws_internet_gateway.igw.id }
}

resource "aws_route_table_association" "public_assoc" {
  subnet_id = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# Security Group
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

# EC2 IAM Role
data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "ec2_role" {
  name = "iot-sim-${var.environment}-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

resource "aws_iam_role_policy_attachment" "cloudwatch" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_role_policy_attachment" "s3_read" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "iot-sim-ec2-profile-${var.environment}"
  role = aws_iam_role.ec2_role.name
}

# EC2 Instance
data "aws_ami" "amazon_linux" {
  most_recent      = true
  owners           = ["137112412989"]
  name_regex       = "^amzn2-ami-hvm-.*-x86_64-gp2$"
  virtualization_type = "hvm"

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
}

resource "aws_instance" "sim_host" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type           = var.instance_type
  subnet_id               = aws_subnet.public.id
  key_name                = var.key_name
  vpc_security_group_ids  = [aws_security_group.ec2_sg.id]
  iam_instance_profile    = aws_iam_instance_profile.ec2_profile.name

  user_data = templatefile("${path.module}/user-data.sh.tpl", {
    simulator_count   = var.simulator_count,
    cert_s3_bucket    = var.cert_s3_bucket,
    region            = var.region
  })

  tags = { Name = "iot-sim-host-${var.environment}" }
}

# S3 Bucket for IoT Certs
resource "aws_s3_bucket" "cert_bucket" {
  bucket = var.cert_s3_bucket
  force_destroy = true
}

# AWS IoT Thing + Policy + Certificate
resource "aws_iot_thing" "simulator" {
  name = "iot-sim-thing-${var.environment}"
}

resource "aws_iot_policy" "sim_policy" {
  name   = "iot-sim-policy-${var.environment}"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
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
  thing = aws_iot_thing.simulator.name
  principal  = aws_iot_certificate.sim_cert.arn
}

# # Save certificates to S3
# resource "aws_s3_bucket_object" "root_ca" {
#   bucket = aws_s3_bucket.cert_bucket.id
#   key    = "AmazonRootCA1.pem"
#   source = "rootCA1.pem"  # local file to upload manually
# }

# resource "aws_s3_bucket_object" "device_cert" {
#   bucket = aws_s3_bucket.cert_bucket.id
#   key    = "device-certificate.pem.crt"
#   source = "device-certificate.pem.crt"
# }

# resource "aws_s3_bucket_object" "private_key" {
#   bucket = aws_s3_bucket.cert_bucket.id
#   key    = "private.pem.key"
#   source = "private.pem.key"
# }

# Save certificates to S3
resource "aws_s3_bucket_object" "root_ca" {
  bucket  = aws_s3_bucket.cert_bucket.bucket
  key     = "AmazonRootCA1.pem"
  source  = "rootCA1.pem"
  etag    = filemd5("rootCA1.pem")
}

resource "aws_s3_bucket_object" "device_cert" {
  bucket  = aws_s3_bucket.cert_bucket.bucket
  key     = "device-certificate.pem.crt"
  source  = "device-certificate.pem.crt"
  etag    = filemd5("device-certificate.pem.crt")
}

resource "aws_s3_bucket_object" "private_key" {
  bucket  = aws_s3_bucket.cert_bucket.bucket
  key     = "private.pem.key"
  source  = "private.pem.key"
  etag    = filemd5("private.pem.key")
}