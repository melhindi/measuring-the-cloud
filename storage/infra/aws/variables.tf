variable "project_name" {
  description = "Resource name prefix"
  type        = string
  default     = "cloud-measuring-storage"
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "eu-central-1"
}

variable "aws_profile" {
  description = "AWS CLI profile to use. Leave empty to use environment or instance credentials."
  type        = string
  default     = ""
}

variable "aws_availability_zone" {
  description = "AWS availability zone for benchmark instance and EBS volume"
  type        = string
  default     = "eu-central-1a"
}

variable "vpc_cidr" {
  description = "Benchmark VPC CIDR"
  type        = string
  default     = "10.76.0.0/16"
}

variable "existing_vpc_id" {
  description = "Existing VPC ID to reuse for private runner mode. Leave empty to create a dedicated VPC."
  type        = string
  default     = ""
}

variable "subnet_cidr" {
  description = "Benchmark subnet CIDR"
  type        = string
  default     = "10.76.1.0/24"
}

variable "ssh_ingress_cidr" {
  description = "CIDR allowed to SSH into benchmark instance"
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
  description = "Whether to assign a public IP to the benchmark instance"
  type        = bool
  default     = true
}

variable "benchmark_private_ip_host" {
  description = "Host index in subnet CIDR for the benchmark private IP"
  type        = number
  default     = 10
}

variable "benchmark_image_id" {
  description = "AMI ID for the benchmark VM"
  type        = string
}

variable "benchmark_machine_type" {
  description = "EC2 instance type for the benchmark VM"
  type        = string
}

variable "benchmark_root_volume_size_gib" {
  description = "Root EBS size in GiB for the benchmark VM"
  type        = number
  default     = 30
}

variable "benchmark_root_volume_type" {
  description = "Root EBS volume type"
  type        = string
  default     = "gp3"
}

variable "benchmark_root_volume_performance_class" {
  description = "Compatibility placeholder for the shared storage runner. AWS uses benchmark_root_volume_type instead."
  type        = string
  default     = ""
}

variable "benchmark_local_storage" {
  description = "Whether to prepare AWS instance-store NVMe disks as a local target. Use auto to detect, or disabled to skip."
  type        = string
  default     = "auto"

  validation {
    condition     = contains(["auto", "disabled"], var.benchmark_local_storage)
    error_message = "benchmark_local_storage must be one of: auto, disabled."
  }
}

variable "benchmark_local_mount_point" {
  description = "Mount point for AWS instance-store local storage"
  type        = string
  default     = "/mnt/local"
}

variable "benchmark_local_filesystem" {
  description = "Filesystem for AWS instance-store local storage"
  type        = string
  default     = "xfs"

  validation {
    condition     = contains(["ext4", "xfs", "raw"], var.benchmark_local_filesystem)
    error_message = "benchmark_local_filesystem must be one of: ext4, xfs, raw."
  }
}

variable "benchmark_block_volume_size_gib" {
  description = "Attached EBS volume size in GiB. Set to 0 to disable the block target."
  type        = number
  default     = 300
}

variable "benchmark_block_volume_type" {
  description = "Attached EBS volume type"
  type        = string
  default     = "gp3"

  validation {
    condition     = contains(["gp2", "gp3", "io1", "io2", "st1", "sc1", "standard"], var.benchmark_block_volume_type)
    error_message = "benchmark_block_volume_type must be a valid EBS volume type."
  }
}

variable "benchmark_block_volume_performance_class" {
  description = "Compatibility placeholder for the shared storage runner. AWS uses benchmark_block_volume_type/iops/throughput instead."
  type        = string
  default     = ""
}

variable "benchmark_block_volume_iops" {
  description = "Provisioned IOPS for gp3/io1/io2 EBS volumes"
  type        = number
  default     = 3000
}

variable "benchmark_block_volume_throughput_mbps" {
  description = "Provisioned throughput in MiB/s for gp3 EBS volumes"
  type        = number
  default     = 125
}

variable "benchmark_block_device_name" {
  description = "Logical attach device name for the benchmark EBS volume"
  type        = string
  default     = "/dev/sdf"
}

variable "benchmark_block_mount_point" {
  description = "Mount point for attached EBS block storage"
  type        = string
  default     = "/mnt/block"
}

variable "benchmark_block_filesystem" {
  description = "Filesystem for attached EBS block storage"
  type        = string
  default     = "ext4"

  validation {
    condition     = contains(["ext4", "xfs", "raw"], var.benchmark_block_filesystem)
    error_message = "benchmark_block_filesystem must be one of: ext4, xfs, raw."
  }
}

variable "benchmark_storage_env_path" {
  description = "Path written by cloud-init describing discovered storage targets"
  type        = string
  default     = "/opt/cloud-measuring/state/storage.env"
}
