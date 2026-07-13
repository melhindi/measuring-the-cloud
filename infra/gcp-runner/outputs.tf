output "runner_public_ip" {
  value = google_compute_address.runner.address
}

output "runner_private_ip" {
  value = google_compute_instance.runner.network_interface[0].network_ip
}

output "ssh_private_key_path" {
  value = var.ssh_private_key_path
}

output "ssh_user" {
  value = "ubuntu"
}

output "gcp_region" {
  value = var.gcp_region
}

output "network_name" {
  value = google_compute_network.runner.name
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

output "storage_subnet_cidr" {
  value = var.storage_subnet_cidr
}

output "runner_machine_type" {
  value = var.runner_machine_type
}

output "runner_availability_zone" {
  value = var.runner_availability_zone
}
