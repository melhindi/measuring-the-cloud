output "client_public_ip" {
  value = var.assign_public_ip ? aws_instance.client.public_ip : null
}

output "client_private_ip" {
  value = aws_instance.client.private_ip
}

output "server_public_ip" {
  value = var.assign_public_ip ? aws_instance.server.public_ip : null
}

output "server_private_ip" {
  value = aws_instance.server.private_ip
}

output "ssh_private_key_path" {
  value = var.ssh_private_key_path
}

output "ssh_user" {
  value = "ubuntu"
}

output "client_machine_type" {
  value = var.client_machine_type
}

output "server_machine_type" {
  value = var.server_machine_type
}

output "client_availability_zone" {
  value = var.client_availability_zone
}

output "server_availability_zone" {
  value = var.server_availability_zone
}

output "cross_region" {
  value = local.cross_region
}

output "name_prefix" {
  value = local.name_prefix
}

output "vpc_id" {
  value = local.use_existing_vpc ? var.existing_vpc_id : aws_vpc.main[0].id
}

output "security_group_id" {
  value = local.use_existing_security_group ? var.existing_security_group_id : aws_security_group.bench[0].id
}

output "security_group_name" {
  value = local.use_existing_security_group ? var.existing_security_group_id : aws_security_group.bench[0].name
}

output "instance_affinity" {
  value = var.instance_affinity
}

output "placement_group_name" {
  value = local.use_placement_group ? aws_placement_group.bench[0].name : null
}

output "placement_group_strategy" {
  value = local.use_placement_group ? local.placement_strategy : null
}
