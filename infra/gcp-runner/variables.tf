variable "gcp_project_id" { type = string }
variable "project_name" {
  type    = string
  default = "cloud-measuring-runner"
}
variable "gcp_region" {
  type    = string
  default = "europe-west3"
}
variable "runner_availability_zone" {
  type    = string
  default = "europe-west3-c"
}
variable "subnet_cidr" {
  type    = string
  default = "10.100.0.0/24"
}
variable "network_client_subnet_cidr" {
  type    = string
  default = "10.100.11.0/24"
}
variable "ssh_ingress_cidr" {
  type    = string
  default = "0.0.0.0/0"
}
variable "ssh_public_key_path" { type = string }
variable "ssh_private_key_path" { type = string }
variable "image" {
  type    = string
  default = "ubuntu-os-cloud/ubuntu-2404-lts-amd64"
}
variable "runner_machine_type" {
  type    = string
  default = "e2-medium"
}
