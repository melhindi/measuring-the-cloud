output "client_public_ip" {
  value = var.assign_public_ip ? google_compute_address.client[0].address : null
}

output "client_private_ip" {
  value = google_compute_instance.client.network_interface[0].network_ip
}

output "server_public_ip" {
  value = var.assign_public_ip ? google_compute_address.server[0].address : null
}

output "server_private_ip" {
  value = google_compute_instance.server.network_interface[0].network_ip
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

output "network_name" {
  value = var.existing_network_name != "" ? var.existing_network_name : google_compute_network.bench[0].name
}

output "instance_affinity" {
  value = var.instance_affinity
}

output "placement_policy_name" {
  value = local.use_placement_policy ? google_compute_resource_policy.bench[0].name : null
}

output "availability_domain_count" {
  value = local.use_placement_policy ? local.availability_domain_count : null
}
