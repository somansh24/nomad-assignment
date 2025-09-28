output "server_public_ip" {
  value = aws_instance.nomad_server.public_ip
}

output "client_public_ips" {
  value = [for c in aws_instance.nomad_client : c.public_ip]
}
