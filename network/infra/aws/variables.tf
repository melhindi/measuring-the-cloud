variable "project_name" {
  description = "Resource name prefix"
  type        = string
  default     = "cloud-measuring-net"
}

variable "aws_region" {
  description = "AWS region for the client instance and primary VPC"
  type        = string
  default     = "eu-central-1"
}

variable "aws_profile" {
  description = "AWS CLI profile to use. Leave empty to use environment or instance credentials."
  type        = string
  default     = ""
}

variable "server_region" {
  description = "AWS region for the server instance. Leave empty for same-region scenarios. Set to a different region for cross-region scenarios."
  type        = string
  default     = ""
}

variable "vpc_cidr" {
  description = "IPv4 CIDR for the client VPC"
  type        = string
  default     = "10.74.0.0/16"
}

variable "server_vpc_cidr" {
  description = "IPv4 CIDR for the server VPC (cross-region scenarios only)"
  type        = string
  default     = "10.75.0.0/16"
}

variable "client_subnet_cidr" {
  description = "IPv4 CIDR for the client subnet"
  type        = string
  default     = "10.74.1.0/24"
}

variable "server_subnet_cidr" {
  description = "IPv4 CIDR for the server subnet when client and server share the client VPC (cross-AZ, same region). Must fall within vpc_cidr and must not overlap with client_subnet_cidr."
  type        = string
  default     = "10.74.2.0/24"
}

variable "server_region_subnet_cidr" {
  description = "IPv4 CIDR for the server subnet when the server has its own VPC (cross-region). Must fall within server_vpc_cidr."
  type        = string
  default     = "10.75.1.0/24"
}

variable "client_private_ip_host" {
  description = "Host index in the client subnet CIDR for the client private IP"
  type        = number
  default     = 10
}

variable "server_private_ip_host" {
  description = "Host index in the server subnet CIDR for the server private IP"
  type        = number
  default     = 20
}

variable "ssh_ingress_cidr" {
  description = "CIDR allowed to SSH into benchmark instances"
  type        = string
  default     = "0.0.0.0/0"
}

variable "ssh_public_key_path" {
  description = "Path to SSH public key. Required unless existing_key_pair_name is set."
  type        = string
  default     = ""
}

variable "ssh_private_key_path" {
  description = "Path to SSH private key used by local scripts"
  type        = string
}

variable "existing_key_pair_name" {
  description = "Existing AWS key pair name. If set, no key pair is created."
  type        = string
  default     = ""
}

variable "existing_vpc_id" {
  description = "Existing VPC ID to reuse. If set, no VPC, subnet, or security group resources are created."
  type        = string
  default     = ""
}

variable "existing_subnet_id" {
  description = "Existing subnet ID to reuse. Required when existing_vpc_id is set."
  type        = string
  default     = ""
}

variable "existing_security_group_id" {
  description = "Existing security group ID to reuse. Required when existing_vpc_id is set."
  type        = string
  default     = ""
}

variable "assign_public_ip" {
  description = "Whether to assign public IPs to the benchmark client and server. Required for cross-region scenarios."
  type        = bool
  default     = true
}

variable "image_id" {
  description = "AMI ID for both benchmark nodes. Leave empty to auto-discover the latest Ubuntu 22.04 LTS AMI in each region."
  type        = string
  default     = ""
}

variable "root_volume_size_gib" {
  description = "Root EBS volume size in GiB"
  type        = number
  default     = 30
}

variable "root_volume_type" {
  description = "Root EBS volume type"
  type        = string
  default     = "gp3"
}

variable "root_volume_performance_class" {
  description = "Compatibility placeholder for the shared network runner. AWS uses root_volume_type instead."
  type        = string
  default     = ""
}

variable "client_machine_type" {
  description = "EC2 instance type for the client node"
  type        = string
}

variable "server_machine_type" {
  description = "EC2 instance type for the server node"
  type        = string
}

variable "client_availability_zone" {
  description = "AWS availability zone for the client node"
  type        = string
}

variable "server_availability_zone" {
  description = "AWS availability zone for the server node. Must match client_availability_zone when instance_affinity is co-located or different-host."
  type        = string
}

variable "instance_affinity" {
  description = "Placement policy for the client/server pair. none = default AWS scheduling; co-located = cluster placement group; different-host = spread placement group. co-located and different-host require both instances in the same availability zone."
  type        = string
  default     = "none"

  validation {
    condition     = contains(["none", "co-located", "different-host"], var.instance_affinity)
    error_message = "instance_affinity must be one of: none, co-located, different-host"
  }
}
