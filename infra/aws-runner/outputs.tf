output "runner_public_ip" {
  value = aws_instance.runner.public_ip
}

output "runner_private_ip" {
  value = aws_instance.runner.private_ip
}

output "ssh_private_key_path" {
  value = var.ssh_private_key_path
}

output "ssh_user" {
  value = "ubuntu"
}

output "aws_region" {
  value = var.aws_region
}

output "vpc_id" {
  value = aws_vpc.main.id
}

output "security_group_id" {
  value = aws_security_group.runner.id
}

output "security_group_name" {
  value = aws_security_group.runner.name
}

output "nat_gateway_id" {
  value = aws_nat_gateway.main.id
}

output "runner_route_table_id" {
  value = aws_route_table.public.id
}

output "subnet_cidr" {
  value = var.subnet_cidr
}

output "network_client_subnet_cidr" {
  value = var.network_client_subnet_cidr
}

output "network_server_subnet_cidr" {
  value = var.network_server_subnet_cidr
}

output "network_server_image_id" {
  value = var.network_server_image_id
}

output "storage_subnet_cidr" {
  value = var.storage_subnet_cidr
}

output "image_id" {
  value = local.runner_ami
}

output "runner_machine_type" {
  value = var.runner_machine_type
}

output "runner_availability_zone" {
  value = var.runner_availability_zone
}
