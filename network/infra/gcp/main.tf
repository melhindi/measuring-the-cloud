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
  name_prefix               = "${var.project_name}-${random_id.suffix.hex}"
  cross_region              = trimspace(var.server_region) != "" && var.server_region != var.gcp_region
  use_placement_policy      = var.instance_affinity != "none"
  availability_domain_count = var.instance_affinity == "co-located" ? 1 : var.instance_affinity == "different-host" ? 2 : 0

  labels = {
    project = var.project_name
    run     = random_id.suffix.hex
  }
}

check "placement_requires_same_zone" {
  assert {
    condition = !(local.use_placement_policy && (
      var.client_availability_zone != var.server_availability_zone ||
      local.cross_region
    ))
    error_message = "instance_affinity co-located/different-host requires both VMs in the same zone. For cross-zone or cross-region scenarios set instance_affinity = \"none\"."
  }
}

check "ssh_key_inputs" {
  assert {
    condition     = trimspace(var.ssh_public_key_path) != ""
    error_message = "ssh_public_key_path must be set to write an SSH key into GCP instance metadata."
  }
}

resource "google_compute_resource_policy" "bench" {
  count   = local.use_placement_policy ? 1 : 0
  project = var.gcp_project_id
  name    = "${local.name_prefix}-placement"
  region  = var.gcp_region

  group_placement_policy {
    availability_domain_count = local.availability_domain_count
  }
}

resource "google_compute_network" "bench" {
  count                   = var.existing_network_name == "" ? 1 : 0
  project                 = var.gcp_project_id
  name                    = "${local.name_prefix}-vpc"
  auto_create_subnetworks = false
  mtu                     = 8896
}

resource "google_compute_subnetwork" "client" {
  count         = var.existing_network_name == "" ? 1 : 0
  project       = var.gcp_project_id
  name          = "${local.name_prefix}-subnet-client"
  region        = var.gcp_region
  network       = google_compute_network.bench[0].id
  ip_cidr_range = var.client_subnet_cidr
}

resource "google_compute_subnetwork" "server" {
  count         = var.existing_network_name == "" && local.cross_region ? 1 : 0
  project       = var.gcp_project_id
  name          = "${local.name_prefix}-subnet-server"
  region        = var.server_region
  network       = google_compute_network.bench[0].id
  ip_cidr_range = var.server_subnet_cidr
}

locals {
  network_self_link      = var.existing_network_name != "" ? "projects/${var.gcp_project_id}/global/networks/${var.existing_network_name}" : google_compute_network.bench[0].self_link
  client_subnetwork_link = var.existing_subnetwork_name != "" ? "projects/${var.gcp_project_id}/regions/${var.gcp_region}/subnetworks/${var.existing_subnetwork_name}" : google_compute_subnetwork.client[0].self_link
  server_subnetwork_link = local.cross_region ? google_compute_subnetwork.server[0].self_link : local.client_subnetwork_link
  effective_server_region = local.cross_region ? var.server_region : var.gcp_region
}

resource "google_compute_firewall" "ssh_ingress" {
  count   = var.existing_network_name == "" ? 1 : 0
  project = var.gcp_project_id
  name    = "${local.name_prefix}-allow-ssh"
  network = local.network_self_link

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = [var.ssh_ingress_cidr]
  target_tags   = ["${local.name_prefix}-bench"]
}

resource "google_compute_firewall" "internal_ingress" {
  count   = var.existing_network_name == "" ? 1 : 0
  project = var.gcp_project_id
  name    = "${local.name_prefix}-allow-internal"
  network = local.network_self_link

  allow {
    protocol = "all"
  }

  source_tags = ["${local.name_prefix}-bench"]
  target_tags = ["${local.name_prefix}-bench"]
}

resource "google_compute_address" "client" {
  count   = var.assign_public_ip ? 1 : 0
  project = var.gcp_project_id
  region  = var.gcp_region
  name    = "${local.name_prefix}-client-ip"
}

resource "google_compute_address" "server" {
  count   = var.assign_public_ip ? 1 : 0
  project = var.gcp_project_id
  region  = local.effective_server_region
  name    = "${local.name_prefix}-server-ip"
}

locals {
  ssh_public_key_content = chomp(file(var.ssh_public_key_path))
  metadata_ssh_key       = "ubuntu:${local.ssh_public_key_content}"
}

resource "google_compute_instance" "client" {
  project      = var.gcp_project_id
  name         = "${local.name_prefix}-client"
  machine_type = var.client_machine_type
  zone         = var.client_availability_zone

  tags   = ["${local.name_prefix}-bench"]
  labels = merge(local.labels, { role = "client" })

  boot_disk {
    initialize_params {
      image = var.image
      size  = var.root_volume_size_gib
      type  = var.root_volume_type
    }
    auto_delete = true
  }

  network_interface {
    subnetwork = local.client_subnetwork_link
    nic_type   = "GVNIC"

    dynamic "access_config" {
      for_each = var.assign_public_ip ? [google_compute_address.client[0].address] : []
      content {
        nat_ip = access_config.value
      }
    }
  }

  dynamic "network_performance_config" {
    for_each = var.enable_tier1_networking ? [1] : []
    content {
      total_egress_bandwidth_tier = "TIER_1"
    }
  }

  metadata = {
    "ssh-keys"  = local.metadata_ssh_key
    "user-data" = templatefile("${path.module}/templates/user_data.sh.tftpl", { node_role = "client" })
  }

  resource_policies = local.use_placement_policy ? [google_compute_resource_policy.bench[0].id] : []

  scheduling {
    on_host_maintenance = local.use_placement_policy ? "TERMINATE" : "MIGRATE"
    automatic_restart   = local.use_placement_policy ? false : true
  }

  depends_on = [google_compute_resource_policy.bench]
}

resource "google_compute_instance" "server" {
  project      = var.gcp_project_id
  name         = "${local.name_prefix}-server"
  machine_type = var.server_machine_type
  zone         = var.server_availability_zone

  tags   = ["${local.name_prefix}-bench"]
  labels = merge(local.labels, { role = "server" })

  boot_disk {
    initialize_params {
      image = var.image
      size  = var.root_volume_size_gib
      type  = var.root_volume_type
    }
    auto_delete = true
  }

  network_interface {
    subnetwork = local.server_subnetwork_link
    nic_type   = "GVNIC"

    dynamic "access_config" {
      for_each = var.assign_public_ip ? [google_compute_address.server[0].address] : []
      content {
        nat_ip = access_config.value
      }
    }
  }

  dynamic "network_performance_config" {
    for_each = var.enable_tier1_networking ? [1] : []
    content {
      total_egress_bandwidth_tier = "TIER_1"
    }
  }

  metadata = {
    "ssh-keys"  = local.metadata_ssh_key
    "user-data" = templatefile("${path.module}/templates/user_data.sh.tftpl", { node_role = "server" })
  }

  resource_policies = local.use_placement_policy ? [google_compute_resource_policy.bench[0].id] : []

  scheduling {
    on_host_maintenance = local.use_placement_policy ? "TERMINATE" : "MIGRATE"
    automatic_restart   = local.use_placement_policy ? false : true
  }

  depends_on = [google_compute_resource_policy.bench]
}
