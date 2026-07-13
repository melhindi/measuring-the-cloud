variable "project_name" {
  description = "Resource name prefix"
  type        = string
  default     = "cloud-measuring-net"
}

variable "gcp_project_id" {
  description = "GCP project ID"
  type        = string
}

variable "gcp_region" {
  description = "GCP region for the client VM and primary subnet"
  type        = string
  default     = "europe-west3"
}

variable "server_region" {
  description = "GCP region for the server VM"
  type        = string
  default     = ""
}

variable "client_subnet_cidr" {
  description = "IPv4 CIDR for the client subnet"
  type        = string
  default     = "10.64.0.0/24"
}

variable "server_subnet_cidr" {
  description = "IPv4 CIDR for the server subnet"
  type        = string
  default     = "10.65.0.0/24"
}

variable "ssh_ingress_cidr" {
  description = "CIDR allowed to SSH into instances"
  type        = string
  default     = "0.0.0.0/0"
}

variable "ssh_public_key_path" {
  description = "Path to SSH public key"
  type        = string
  default     = ""
}

variable "ssh_private_key_path" {
  description = "Path to SSH private key"
  type        = string
}

variable "existing_network_name" {
  description = "Name of an existing VPC network. If set, no network/subnet/firewall resources are created."
  type        = string
  default     = ""
}

variable "existing_subnetwork_name" {
  description = "Name of an existing subnetwork. Required when existing_network_name is set."
  type        = string
  default     = ""
}

variable "assign_public_ip" {
  description = "Whether to assign external IPs to benchmark VMs"
  type        = bool
  default     = true
}

variable "image" {
  description = "GCP image for both benchmark nodes"
  type        = string
  default     = "ubuntu-os-cloud/ubuntu-2404-lts-amd64"
}

variable "root_volume_size_gib" {
  description = "Boot disk size in GiB"
  type        = number
  default     = 30
}

variable "enable_tier1_networking" {
  description = "Whether to enable Tier_1 (high-bandwidth) networking. Requires at least 46 vCPUs (e.g. n2-standard-48)"
  type        = bool
  default     = false
}

variable "root_volume_type" {
  description = "Boot disk type (pd-balanced, pd-ssd, pd-standard)"
  type        = string
  default     = "pd-balanced"
}

variable "client_machine_type" {
  description = "GCP machine type for the client node"
  type        = string
}

variable "server_machine_type" {
  description = "GCP machine type for the server node"
  type        = string
}

variable "client_availability_zone" {
  description = "GCP zone for the client node"
  type        = string
}

variable "server_availability_zone" {
  description = "GCP zone for the server node"
  type        = string
}

variable "instance_affinity" {
  description = "Placement policy for the client/server pair. none = default GCP scheduling; co-located = availability-domain-count 1; different-host = availability-domain-count 2"
  type        = string
  default     = "none"

  validation {
    condition     = contains(["none", "co-located", "different-host"], var.instance_affinity)
    error_message = "instance_affinity must be one of: none, co-located, different-host"
  }
}
