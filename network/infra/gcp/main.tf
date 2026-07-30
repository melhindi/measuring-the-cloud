terraform {
  required_version = ">= 1.6.0"
  required_providers {
    google = { source = "hashicorp/google", version = "~> 6.0" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
  }
}
provider "google" {
  project = var.gcp_project_id
  region  = var.gcp_region
}
resource "random_id" "suffix" { byte_length = 4 }
locals {
  name            = "${var.project_name}-${random_id.suffix.hex}"
  cross_region    = trimspace(var.server_region) != "" && var.server_region != var.gcp_region
  server_region   = local.cross_region ? var.server_region : var.gcp_region
  managed_network = trimspace(var.existing_network_name) == ""
  network         = local.managed_network ? google_compute_network.bench[0].self_link : "projects/${var.gcp_project_id}/global/networks/${var.existing_network_name}"
  client_subnet   = local.managed_network ? google_compute_subnetwork.client[0].self_link : "projects/${var.gcp_project_id}/regions/${var.gcp_region}/subnetworks/${var.existing_client_subnetwork_name}"
  server_subnet   = local.cross_region ? google_compute_subnetwork.server[0].self_link : local.client_subnet
  tag             = "${local.name}-bench"
  ssh_key         = "ubuntu:${chomp(file(var.ssh_public_key_path))}"
}
check "runner_subnet_input" {
  assert {
    condition     = local.managed_network || trimspace(var.existing_client_subnetwork_name) != ""
    error_message = "existing_client_subnetwork_name is required with existing_network_name."
  }
}
check "placement" {
  assert {
    condition     = var.instance_affinity == "none" || (!local.cross_region && var.client_availability_zone == var.server_availability_zone)
    error_message = "GCP affinity requires both VMs in the same zone."
  }
}
resource "google_compute_network" "bench" {
  count                   = local.managed_network ? 1 : 0
  name                    = "${local.name}-vpc"
  auto_create_subnetworks = false
  mtu                     = 8896
}
resource "google_compute_subnetwork" "client" {
  count         = local.managed_network ? 1 : 0
  name          = "${local.name}-client"
  region        = var.gcp_region
  network       = google_compute_network.bench[0].id
  ip_cidr_range = var.client_subnet_cidr
}
resource "google_compute_subnetwork" "server" {
  count         = local.cross_region ? 1 : 0
  name          = "${local.name}-server"
  region        = local.server_region
  network       = local.network
  ip_cidr_range = var.server_subnet_cidr
}
resource "google_compute_firewall" "ssh" {
  name          = "${local.name}-ssh"
  network       = local.network
  source_ranges = [var.ssh_ingress_cidr]
  target_tags   = [local.tag]
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}
resource "google_compute_firewall" "internal" {
  name        = "${local.name}-internal"
  network     = local.network
  source_tags = [local.tag]
  target_tags = [local.tag]
  allow { protocol = "all" }
}
resource "google_compute_address" "client" {
  count  = var.assign_public_ip ? 1 : 0
  name   = "${local.name}-client-ip"
  region = var.gcp_region
}
resource "google_compute_address" "server" {
  count  = var.assign_public_ip ? 1 : 0
  name   = "${local.name}-server-ip"
  region = local.server_region
}
resource "google_compute_resource_policy" "placement" {
  count  = var.instance_affinity == "none" ? 0 : 1
  name   = "${local.name}-placement"
  region = var.gcp_region
  group_placement_policy { availability_domain_count = var.instance_affinity == "co-located" ? 1 : 2 }
}
resource "google_compute_instance" "client" {
  name         = "${local.name}-client"
  machine_type = var.client_machine_type
  zone         = var.client_availability_zone
  tags         = [local.tag]
  boot_disk {
    initialize_params {
      image = var.image
      size  = var.root_volume_size_gib
      type  = var.root_volume_type
    }
  }
  network_interface {
    subnetwork = local.client_subnet
    nic_type   = "GVNIC"
    dynamic "access_config" {
      for_each = var.assign_public_ip ? [1] : []
      content { nat_ip = google_compute_address.client[0].address }
    }
  }
  metadata          = { "ssh-keys" = local.ssh_key, "user-data" = templatefile("${path.module}/templates/user_data.sh.tftpl", {}) }
  resource_policies = var.instance_affinity == "none" ? [] : [google_compute_resource_policy.placement[0].id]
}
resource "google_compute_instance" "server" {
  name         = "${local.name}-server"
  machine_type = var.server_machine_type
  zone         = var.server_availability_zone
  tags         = [local.tag]
  boot_disk {
    initialize_params {
      image = var.image
      size  = var.root_volume_size_gib
      type  = var.root_volume_type
    }
  }
  network_interface {
    subnetwork = local.server_subnet
    nic_type   = "GVNIC"
    dynamic "access_config" {
      for_each = var.assign_public_ip ? [1] : []
      content { nat_ip = google_compute_address.server[0].address }
    }
  }
  metadata          = { "ssh-keys" = local.ssh_key, "user-data" = templatefile("${path.module}/templates/user_data.sh.tftpl", {}) }
  resource_policies = var.instance_affinity == "none" ? [] : [google_compute_resource_policy.placement[0].id]
}
