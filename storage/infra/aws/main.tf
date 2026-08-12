terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region  = var.aws_region
  profile = trimspace(var.aws_profile) != "" ? var.aws_profile : null
}

resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  name_prefix                 = "${var.project_name}-${random_id.suffix.hex}"
  use_existing_key_pair       = trimspace(var.existing_key_pair_name) != ""
  use_existing_vpc            = trimspace(var.existing_vpc_id) != ""
  use_existing_security_group = trimspace(var.existing_security_group_id) != ""
  use_existing_nat_gateway    = trimspace(var.existing_nat_gateway_id) != ""
  use_public_ip               = var.assign_public_ip
  benchmark_private_ip        = cidrhost(var.subnet_cidr, var.benchmark_private_ip_host)

  labels = {
    Project = var.project_name
    Run     = random_id.suffix.hex
  }
}

data "aws_vpc" "existing" {
  count = local.use_existing_vpc ? 1 : 0
  id    = var.existing_vpc_id
}

data "aws_internet_gateway" "existing" {
  count = local.use_existing_vpc ? 1 : 0

  filter {
    name   = "attachment.vpc-id"
    values = [var.existing_vpc_id]
  }
}

data "aws_security_group" "existing" {
  count = local.use_existing_security_group ? 1 : 0
  id    = var.existing_security_group_id
}

check "ssh_key_inputs" {
  assert {
    condition     = local.use_existing_key_pair || trimspace(var.ssh_public_key_path) != ""
    error_message = "Set existing_key_pair_name, or provide ssh_public_key_path to create a new AWS key pair."
  }
}

check "existing_network_inputs" {
  assert {
    condition     = local.use_existing_vpc == local.use_existing_security_group
    error_message = "existing_vpc_id and existing_security_group_id must be set together when reusing shared AWS networking."
  }
}

check "private_egress_inputs" {
  assert {
    condition     = local.use_public_ip || !local.use_existing_vpc || local.use_existing_nat_gateway
    error_message = "Set existing_nat_gateway_id when reusing an existing VPC for private benchmark instances with assign_public_ip = false."
  }
}

resource "aws_vpc" "main" {
  count                = local.use_existing_vpc ? 0 : 1
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.labels, {
    Name = "${local.name_prefix}-vpc"
  })
}

resource "aws_internet_gateway" "main" {
  count  = local.use_existing_vpc ? 0 : 1
  vpc_id = aws_vpc.main[0].id

  tags = merge(local.labels, {
    Name = "${local.name_prefix}-igw"
  })
}

resource "aws_subnet" "benchmark" {
  vpc_id                  = local.use_existing_vpc ? data.aws_vpc.existing[0].id : aws_vpc.main[0].id
  cidr_block              = var.subnet_cidr
  availability_zone       = var.aws_availability_zone
  map_public_ip_on_launch = local.use_public_ip

  tags = merge(local.labels, {
    Name = "${local.name_prefix}-subnet"
  })
}

resource "aws_route_table" "public" {
  vpc_id = local.use_existing_vpc ? data.aws_vpc.existing[0].id : aws_vpc.main[0].id

  route {
    cidr_block     = "0.0.0.0/0"
    gateway_id     = local.use_public_ip ? (local.use_existing_vpc ? data.aws_internet_gateway.existing[0].id : aws_internet_gateway.main[0].id) : null
    nat_gateway_id = local.use_public_ip ? null : var.existing_nat_gateway_id
  }

  tags = merge(local.labels, {
    Name = "${local.name_prefix}-public-rt"
  })
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.benchmark.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "benchmark" {
  count       = local.use_existing_security_group ? 0 : 1
  name        = "${local.name_prefix}-sg"
  description = "Storage benchmark security group"
  vpc_id      = local.use_existing_vpc ? data.aws_vpc.existing[0].id : aws_vpc.main[0].id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_ingress_cidr]
  }

  ingress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    self      = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.labels, {
    Name = "${local.name_prefix}-sg"
  })
}

resource "aws_key_pair" "benchmark" {
  count      = local.use_existing_key_pair ? 0 : 1
  key_name   = "${local.name_prefix}-key"
  public_key = chomp(file(var.ssh_public_key_path))

  tags = merge(local.labels, {
    Name = "${local.name_prefix}-key"
  })
}

resource "aws_ebs_volume" "block" {
  count             = var.benchmark_block_volume_size_gib > 0 ? 1 : 0
  availability_zone = var.aws_availability_zone
  type              = var.benchmark_block_volume_type
  size              = var.benchmark_block_volume_size_gib
  iops              = contains(["gp3", "io1", "io2"], var.benchmark_block_volume_type) ? var.benchmark_block_volume_iops : null
  throughput        = var.benchmark_block_volume_type == "gp3" ? var.benchmark_block_volume_throughput_mbps : null

  tags = merge(local.labels, {
    Name = "${local.name_prefix}-block"
    Role = "block"
  })
}

resource "aws_instance" "benchmark" {
  ami                         = var.benchmark_image_id
  instance_type               = var.benchmark_machine_type
  availability_zone           = var.aws_availability_zone
  subnet_id                   = aws_subnet.benchmark.id
  private_ip                  = local.benchmark_private_ip
  vpc_security_group_ids      = [local.use_existing_security_group ? var.existing_security_group_id : aws_security_group.benchmark[0].id]
  key_name                    = local.use_existing_key_pair ? var.existing_key_pair_name : aws_key_pair.benchmark[0].key_name
  associate_public_ip_address = local.use_public_ip

  root_block_device {
    volume_type           = var.benchmark_root_volume_type
    volume_size           = var.benchmark_root_volume_size_gib
    delete_on_termination = true
  }

  # Spot is opt-in per scenario. "one-time" plus "terminate" is deliberate: a
  # persistent request would relaunch the instance after an interruption and
  # leave a standing request behind that destroy does not clean up, which for an
  # ephemeral benchmark VM is a cost leak rather than a recovery. No max_price,
  # so the bid is the on-demand price and interruption is driven by capacity
  # rather than by being outbid.
  dynamic "instance_market_options" {
    for_each = var.use_spot_instances ? [1] : []
    content {
      market_type = "spot"
      spot_options {
        spot_instance_type             = "one-time"
        instance_interruption_behavior = "terminate"
      }
    }
  }

  user_data = templatefile("${path.module}/templates/user_data.sh.tftpl", {
    benchmark_local_storage         = var.benchmark_local_storage
    benchmark_local_mount_point     = var.benchmark_local_mount_point
    benchmark_local_filesystem      = var.benchmark_local_filesystem
    benchmark_block_volume_size_gib = var.benchmark_block_volume_size_gib
    benchmark_block_volume_id       = var.benchmark_block_volume_size_gib > 0 ? aws_ebs_volume.block[0].id : ""
    benchmark_block_mount_point     = var.benchmark_block_mount_point
    benchmark_block_filesystem      = var.benchmark_block_filesystem
    benchmark_storage_env_path      = var.benchmark_storage_env_path
  })

  tags = merge(local.labels, {
    Name = "${local.name_prefix}-benchmark"
    Role = "benchmark"
  })
}

resource "aws_volume_attachment" "block" {
  count       = var.benchmark_block_volume_size_gib > 0 ? 1 : 0
  device_name = var.benchmark_block_device_name
  volume_id   = aws_ebs_volume.block[0].id
  instance_id = aws_instance.benchmark.id
}
