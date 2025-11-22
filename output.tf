output "instance_public_ip" { value = aws_instance.sim_host.public_ip }
output "grafana_url" { value = "http://${aws_instance.sim_host.public_ip}:3000" }
output "prometheus_url" { value = "http://${aws_instance.sim_host.public_ip}:9090" }
output "iot_endpoint" { value = aws_iot_certificate.sim_cert.id } # can replace with actual endpoint if needed
