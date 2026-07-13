variable "project_name" {
  description = "Resource name prefix"
  type        = string
  default     = "cloud-measuring-runner"
}

variable "gcp_project_id" {
  description = "GCP project ID"
  type        = string
}

variable "gcp_region" {
  description = "GCP region for the runner VM"
  type        = string
  default     = "europe-west3"
}

variable "subnet_cidr" {
  description = "Runner subnet CIDR"
  type        = string
  default     = "10.100.0.0/24"
}

variable "network_client_subnet_cidr" {
  description = "Subnet CIDR reserved for GCP network benchmark client instances when reusing the runner VPC"
  type        = string
  default     = "10.100.11.0/24"
}

variable "network_server_subnet_cidr" {
  description = "Subnet CIDR reserved for GCP network benchmark server instances when reusing the runner VPC"
  type        = string
  default     = "10.100.12.0/24"
}

variable "storage_subnet_cidr" {
  description = "Subnet CIDR reserved for GCP storage benchmark instances when reusing the runner VPC"
  type        = string
  default     = "10.100.21.0/24"
}

variable "ssh_ingress_cidr" {
  description = "CIDR allowed to SSH into the runner"
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

variable "image" {
  description = "GCP image for the runner VM"
  type        = string
  default     = "ubuntu-os-cloud/ubuntu-2404-lts-amd64"
}

variable "runner_machine_type" {
  description = "GCP machine type for the runner VM"
  type        = string
  default     = "e2-medium"
}

variable "runner_availability_zone" {
  description = "GCP zone for the runner VM"
  type        = string
  default     = "europe-west3-c"
}

variable "runner_private_ip_host" {
  description = "Host index in subnet CIDR for the runner private IP"
  type        = number
  default     = 10
}

variable "root_volume_size_gib" {
  description = "Boot disk size in GiB"
  type        = number
  default     = 30
}

variable "root_volume_type" {
  description = "Boot disk type (pd-balanced, pd-ssd, pd-standard)"
  type        = string
  default     = "pd-balanced"
}
