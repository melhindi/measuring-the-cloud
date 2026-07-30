output "client_public_ip" {
  value = var.assign_public_ip ? aws_instance.client.public_ip : null
}

output "client_private_ip" {
  value = aws_instance.client.private_ip
}

output "server_public_ip" {
  value = local.cross_region ? null : (var.assign_public_ip ? aws_instance.server[0].public_ip : null)
}

output "server_private_ip" {
  value = local.cross_region ? aws_instance.server_remote[0].private_ip : aws_instance.server[0].private_ip
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

output "name_prefix" {
  value = local.name_prefix
}

output "vpc_id" {
  value = trimspace(var.existing_vpc_id) != "" ? var.existing_vpc_id : aws_vpc.main[0].id
}

output "security_group_id" {
  value = trimspace(var.existing_security_group_id) != "" ? var.existing_security_group_id : aws_security_group.bench[0].id
}

output "security_group_name" {
  value = trimspace(var.existing_security_group_id) != "" ? data.aws_security_group.existing[0].name : aws_security_group.bench[0].name
}

output "instance_affinity" {
  value = var.instance_affinity
}

output "placement_group_name" {
  value = local.use_placement_group && !local.cross_region ? aws_placement_group.bench[0].name : null
}

output "placement_group_strategy" {
  value = local.use_placement_group && !local.cross_region ? local.placement_strategy : null
}

output "cross_region" {
  value = local.cross_region
}

output "server_region" {
  value = local.effective_server_region
}
