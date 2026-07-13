terraform {
  required_version = ">= 1.6.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "google" {
  project = var.gcp_project_id
  region  = var.gcp_region
}

resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  name_prefix = "${var.project_name}-${random_id.suffix.hex}"
  runner_private_ip = cidrhost(var.subnet_cidr, var.runner_private_ip_host)

  labels = {
    project = var.project_name
    run     = random_id.suffix.hex
    role    = "runner"
  }
}

check "ssh_key_inputs" {
  assert {
    condition     = trimspace(var.ssh_public_key_path) != ""
    error_message = "ssh_public_key_path must be set."
  }
}

resource "google_compute_network" "runner" {
  project                 = var.gcp_project_id
  name                    = "${local.name_prefix}-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "runner" {
  project       = var.gcp_project_id
  name          = "${local.name_prefix}-subnet"
  region        = var.gcp_region
  network       = google_compute_network.runner.id
  ip_cidr_range = var.subnet_cidr
}

resource "google_compute_firewall" "ssh_ingress" {
  project = var.gcp_project_id
  name    = "${local.name_prefix}-allow-ssh"
  network = google_compute_network.runner.self_link

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = [var.ssh_ingress_cidr]
  target_tags   = ["${local.name_prefix}-runner"]
}

resource "google_compute_address" "runner" {
  project = var.gcp_project_id
  region  = var.gcp_region
  name    = "${local.name_prefix}-ip"
}

locals {
  ssh_public_key_content = chomp(file(var.ssh_public_key_path))
  metadata_ssh_key       = "ubuntu:${local.ssh_public_key_content}"
}

resource "google_compute_instance" "runner" {
  project      = var.gcp_project_id
  name         = "${local.name_prefix}-runner"
  machine_type = var.runner_machine_type
  zone         = var.runner_availability_zone

  tags   = ["${local.name_prefix}-runner"]
  labels = local.labels

  boot_disk {
    initialize_params {
      image = var.image
      size  = var.root_volume_size_gib
      type  = var.root_volume_type
    }
    auto_delete = true
  }

  network_interface {
    subnetwork = google_compute_subnetwork.runner.self_link
    network_ip = local.runner_private_ip

    access_config {
      nat_ip = google_compute_address.runner.address
    }
  }

  metadata = {
    "ssh-keys"  = local.metadata_ssh_key
    "user-data" = templatefile("${path.module}/templates/user_data.sh.tftpl", { node_role = "runner" })
  }

  service_account {
    scopes = ["cloud-platform"]
  }
}
