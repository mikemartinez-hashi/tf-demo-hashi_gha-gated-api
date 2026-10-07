output "instance_id" {
  description = "ID of the EC2 web server instance"
  value       = aws_instance.web_server.id
}

output "public_ip" {
  description = "Public IP address of the web server"
  value       = aws_instance.web_server.public_ip
}

output "public_dns" {
  description = "Public DNS name of the web server"
  value       = aws_instance.web_server.public_dns
}

output "web_url" {
  description = "URL to access the web server"
  value       = "http://${aws_instance.web_server.public_dns}"
}

output "environment" {
  description = "Deployed environment"
  value       = var.environment
}
