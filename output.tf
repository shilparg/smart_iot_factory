########################################
# EC2 Simulator Outputs
########################################

output "sim_host_public_ip" {
  description = "Public IP of the IoT simulator host"
  value       = aws_instance.sim_host.public_ip
}

output "sim_host_public_dns" {
  description = "Public DNS of the IoT simulator host"
  value       = aws_instance.sim_host.public_dns
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

output "iot_certificate_id" {
  description = "ID of the IoT simulator certificate"
  value       = aws_iot_certificate.sim_cert.id
}

output "iot_thing_name" {
  description = "Logical name of the IoT Thing resource"
  value       = aws_iot_thing.simulator.name
}

output "iot_policy_name" {
  description = "Name of the IoT policy attached to the device certificate"
  value       = aws_iot_policy.sim_policy.name
}

############################################
# S3 Buckets
############################################
output "config_bucket_name" {
  description = "Name of the S3 bucket holding Prometheus/Grafana configs"
  value       = local.config_bucket
}

output "cert_bucket_name" {
  description = "Name of the S3 bucket holding IoT certificates"
  value       = local.cert_bucket
}

############################################
# IoT Certificates
############################################
output "certs" {
  description = "List of uploaded certificate/key object keys in S3"
  value       = [for obj in aws_s3_object.certs : obj.key]
}

output "ec2_role_name" {
  value = aws_iam_role.ec2_role.name
}
output "secretsmanager_policy_arn" {
  value = aws_iam_policy.secretsmanager_policy.arn
}



#output "iot_endpoint" { value = aws_iot_certificate.sim_cert.id } # can replace with actual endpoint if needed