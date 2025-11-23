########################################
# EC2 Simulator Outputs
########################################

output "instance_public_ip" {
  description = "Public IP address of the IoT simulator EC2 host"
  value       = aws_instance.sim_host.public_ip
}

output "grafana_url" {
  description = "Grafana dashboard URL on the simulator host"
  value       = "http://${aws_instance.sim_host.public_ip}:3000"
}

output "prometheus_url" {
  description = "Prometheus dashboard URL on the simulator host"
  value       = "http://${aws_instance.sim_host.public_ip}:9090"
}

output "ec2_instance_profile" {
  description = "IAM instance profile attached to the EC2 simulator host"
  value       = aws_iam_instance_profile.ec2_profile.name
}

########################################
# AWS IoT Core Outputs
########################################

data "aws_iot_endpoint" "mqtt" {
  endpoint_type = "iot:Data-ATS"
}

output "iot_mqtt_endpoint" {
  description = "AWS IoT Core MQTT endpoint for region "
  value       = data.aws_iot_endpoint.mqtt.endpoint_address
}

output "iot_certificate_arn" {
  description = "ARN of the IoT device certificate used for MQTT authentication"
  value       = aws_iot_certificate.sim_cert.arn
}

output "iot_thing_name" {
  description = "Logical name of the IoT Thing resource"
  value       = aws_iot_thing.simulator.name
}

output "iot_policy_name" {
  description = "Name of the IoT policy attached to the device certificate"
  value       = aws_iot_policy.sim_policy.name
}

########################################
# S3 Certificate Storage Outputs
########################################

output "cert_bucket_name" {
  description = "S3 bucket name where IoT certificates and keys are stored"
  value       = aws_s3_bucket.cert_bucket.bucket
}

output "cert_bucket_objects" {
  description = "List of uploaded certificate/key object keys in S3"
  value       = [for obj in aws_s3_bucket_object.certs : obj.key]
}

#output "iot_endpoint" { value = aws_iot_certificate.sim_cert.id } # can replace with actual endpoint if needed