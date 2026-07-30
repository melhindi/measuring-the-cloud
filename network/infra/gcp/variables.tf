variable "gcp_project_id" { type = string }
variable "project_name" {
  type    = string
  default = "cloud-measuring-net"
}
variable "gcp_region" {
  type    = string
  default = "europe-west3"
}
variable "server_region" {
  type    = string
  default = ""
}
variable "client_subnet_cidr" {
  type    = string
  default = "10.64.0.0/24"
}
variable "server_subnet_cidr" {
  type    = string
  default = "10.65.0.0/24"
}
variable "existing_network_name" {
  type    = string
  default = ""
}
variable "existing_client_subnetwork_name" {
  type    = string
  default = ""
}
variable "ssh_ingress_cidr" {
  type    = string
  default = "0.0.0.0/0"
}
variable "ssh_public_key_path" { type = string }
variable "ssh_private_key_path" { type = string }
variable "assign_public_ip" {
  type    = bool
  default = true
}
variable "image" {
  type    = string
  default = "ubuntu-os-cloud/ubuntu-2404-lts-amd64"
}
variable "root_volume_size_gib" {
  type    = number
  default = 30
}
variable "root_volume_type" {
  type    = string
  default = "pd-balanced"
}
variable "client_machine_type" { type = string }
variable "server_machine_type" { type = string }
variable "client_availability_zone" { type = string }
variable "server_availability_zone" { type = string }
variable "instance_affinity" {
  type    = string
  default = "none"
  validation {
    condition     = contains(["none", "co-located", "different-host"], var.instance_affinity)
    error_message = "instance_affinity must be none, co-located, or different-host."
  }
}
variable "enable_tier1_networking" {
  type    = bool
  default = false
}
