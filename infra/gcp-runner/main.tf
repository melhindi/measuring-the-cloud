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
locals { name = "${var.project_name}-${random_id.suffix.hex}" }
resource "google_service_account" "runner" {
  account_id   = substr("${local.name}-sa", 0, 30)
  display_name = "Cloud measuring runner"
}
resource "google_project_iam_member" "compute_admin" {
  project = var.gcp_project_id
  role    = "roles/compute.admin"
  member  = "serviceAccount:${google_service_account.runner.email}"
}
resource "google_project_iam_member" "network_admin" {
  project = var.gcp_project_id
  role    = "roles/compute.networkAdmin"
  member  = "serviceAccount:${google_service_account.runner.email}"
}
resource "google_compute_network" "runner" {
  name                    = "${local.name}-vpc"
  auto_create_subnetworks = false
}
resource "google_compute_subnetwork" "runner" {
  name          = "${local.name}-runner"
  region        = var.gcp_region
  network       = google_compute_network.runner.id
  ip_cidr_range = var.subnet_cidr
}
resource "google_compute_subnetwork" "client" {
  name          = "${local.name}-client"
  region        = var.gcp_region
  network       = google_compute_network.runner.id
  ip_cidr_range = var.network_client_subnet_cidr
}
resource "google_compute_router" "egress" {
  name    = "${local.name}-router"
  region  = var.gcp_region
  network = google_compute_network.runner.id
}
resource "google_compute_router_nat" "egress" {
  name                               = "${local.name}-nat"
  router                             = google_compute_router.egress.name
  region                             = var.gcp_region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}
resource "google_compute_firewall" "ssh" {
  name          = "${local.name}-ssh"
  network       = google_compute_network.runner.self_link
  source_ranges = [var.ssh_ingress_cidr]
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}
resource "google_compute_address" "runner" {
  name   = "${local.name}-ip"
  region = var.gcp_region
}
resource "google_compute_instance" "runner" {
  name         = "${local.name}-runner"
  machine_type = var.runner_machine_type
  zone         = var.runner_availability_zone
  boot_disk {
    initialize_params {
      image = var.image
      size  = 30
    }
  }
  network_interface {
    subnetwork = google_compute_subnetwork.runner.self_link
    access_config { nat_ip = google_compute_address.runner.address }
  }
  metadata = { "ssh-keys" = "ubuntu:${chomp(file(var.ssh_public_key_path))}", "user-data" = templatefile("${path.module}/templates/user_data.sh.tftpl", {}) }
  service_account {
    email  = google_service_account.runner.email
    scopes = ["cloud-platform"]
  }
  depends_on = [google_project_iam_member.compute_admin, google_project_iam_member.network_admin]
}
