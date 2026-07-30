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

variable "server_region" {
  description = "AWS region for the server instance. Leave empty for same-region scenarios."
  type        = string
  default     = ""
}

variable "aws_profile" {
  description = "AWS CLI profile to use. Leave empty to use environment or instance credentials."
  type        = string
  default     = ""
}

variable "vpc_cidr" {
  description = "IPv4 CIDR for the client VPC"
  type        = string
  default     = "10.74.0.0/16"
}

variable "server_vpc_cidr" {
  description = "IPv4 CIDR for the dedicated server VPC in cross-region scenarios"
  type        = string
  default     = "10.75.0.0/16"
}

variable "existing_vpc_id" {
  description = "Existing VPC ID to reuse for private runner mode. Leave empty to create a dedicated VPC."
  type        = string
  default     = ""
}

variable "client_subnet_cidr" {
  description = "Subnet CIDR for the client availability zone"
  type        = string
  default     = "10.74.1.0/24"
}

variable "server_subnet_cidr" {
  description = "Subnet CIDR for the server availability zone. Used only when server availability zone differs from client availability zone."
  type        = string
  default     = "10.74.2.0/24"
}

variable "server_region_subnet_cidr" {
  description = "IPv4 CIDR for the server benchmark subnet in cross-region scenarios"
  type        = string
  default     = "10.75.1.0/24"
}

variable "server_nat_subnet_cidr" {
  description = "IPv4 CIDR for the server NAT gateway subnet in cross-region scenarios"
  type        = string
  default     = "10.75.2.0/24"
}

variable "client_nat_subnet_cidr" {
  description = "IPv4 CIDR for a managed client NAT gateway subnet when running cross-region privately without a shared VPC"
  type        = string
  default     = "10.74.254.0/24"
}

variable "ssh_ingress_cidr" {
  description = "CIDR allowed to SSH into benchmark instances"
  type        = string
  default     = "0.0.0.0/0"
}

variable "existing_security_group_id" {
  description = "Existing security group ID to reuse for private runner mode. Leave empty to create a dedicated security group."
  type        = string
  default     = ""
}

variable "existing_nat_gateway_id" {
  description = "Existing NAT gateway ID to reuse for private runner mode when benchmark instances have no public IP."
  type        = string
  default     = ""
}

variable "existing_runner_route_table_id" {
  description = "Route table ID of the persistent AWS runner subnet. Required for cross-region runs that reuse the runner VPC."
  type        = string
  default     = ""
}

variable "runner_subnet_cidr" {
  description = "CIDR of the persistent AWS runner subnet. Required for cross-region runs that reuse the runner VPC."
  type        = string
  default     = ""
}

variable "ssh_public_key_path" {
  description = "Path to SSH public key, required unless existing_key_pair_name is set"
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

variable "assign_public_ip" {
  description = "Whether to assign public IPs to the benchmark client and server"
  type        = bool
  default     = true
}

variable "image_id" {
  description = "AMI ID for both benchmark nodes"
  type        = string
}

variable "server_image_id" {
  description = "AMI ID for the server region. Leave empty to resolve Canonical Ubuntu 24.04 through the regional AWS SSM public parameter."
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
  description = "AWS availability zone for the server node"
  type        = string
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

variable "root_volume_performance_class" {
  description = "Compatibility placeholder for the shared network runner. AWS uses root_volume_type instead."
  type        = string
  default     = ""
}

variable "instance_affinity" {
  description = "Compatibility placeholder for the shared network runner. AWS placement support is added separately."
  type        = string
  default     = "none"

  validation {
    condition     = contains(["none", "co-located", "different-host"], var.instance_affinity)
    error_message = "instance_affinity must be one of: none, co-located, different-host"
  }
}
