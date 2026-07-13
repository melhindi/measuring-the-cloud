variable "project_name" {
  description = "Resource name prefix"
  type        = string
  default     = "cloud-measuring-runner"
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "eu-central-1"
}

variable "aws_profile" {
  description = "AWS CLI profile to use locally for provisioning the runner. Leave empty to use environment credentials."
  type        = string
  default     = ""
}

variable "vpc_cidr" {
  description = "Runner VPC CIDR"
  type        = string
  default     = "10.65.0.0/16"
}

variable "subnet_cidr" {
  description = "Runner subnet CIDR"
  type        = string
  default     = "10.65.1.0/24"
}

variable "network_client_subnet_cidr" {
  description = "Subnet CIDR reserved for AWS network benchmark client instances when reusing the runner VPC"
  type        = string
  default     = "10.65.11.0/24"
}

variable "network_server_subnet_cidr" {
  description = "Subnet CIDR reserved for AWS network benchmark server instances when reusing the runner VPC"
  type        = string
  default     = "10.65.12.0/24"
}

variable "storage_subnet_cidr" {
  description = "Subnet CIDR reserved for AWS storage benchmark instances when reusing the runner VPC"
  type        = string
  default     = "10.65.21.0/24"
}

variable "ssh_ingress_cidr" {
  description = "CIDR allowed to SSH into the runner"
  type        = string
  default     = "0.0.0.0/0"
}

variable "ssh_public_key_path" {
  description = "Path to SSH public key. Required unless existing_key_pair_name is set."
  type        = string
  default     = ""
}

variable "ssh_private_key_path" {
  description = "Path to SSH private key used by local scripts to access the runner"
  type        = string
}

variable "existing_key_pair_name" {
  description = "Existing AWS key pair name. If set, no key pair is created."
  type        = string
  default     = ""
}

variable "image_id" {
  description = "AMI ID for the runner VM"
  type        = string
}

variable "runner_machine_type" {
  description = "EC2 instance type for the runner node"
  type        = string
  default     = "c6i.large"
}

variable "runner_availability_zone" {
  description = "AWS availability zone for the runner node"
  type        = string
  default     = "eu-central-1a"
}

variable "runner_private_ip_host" {
  description = "Host index in subnet CIDR for the runner private IP"
  type        = number
  default     = 10
}

variable "root_volume_size_gib" {
  description = "Root volume size in GiB"
  type        = number
  default     = 30
}

variable "root_volume_type" {
  description = "Root EBS volume type"
  type        = string
  default     = "gp3"
}
