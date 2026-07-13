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

data "aws_iam_policy_document" "runner_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

locals {
  name_prefix       = "${var.project_name}-${random_id.suffix.hex}"
  use_existing_key  = trimspace(var.existing_key_pair_name) != ""
  runner_private_ip = cidrhost(var.subnet_cidr, var.runner_private_ip_host)
  labels = {
    Project = var.project_name
    Run     = random_id.suffix.hex
  }
}

check "ssh_key_inputs" {
  assert {
    condition     = local.use_existing_key || trimspace(var.ssh_public_key_path) != ""
    error_message = "Set existing_key_pair_name, or provide ssh_public_key_path to create a new AWS key pair."
  }
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.labels, { Name = "${local.name_prefix}-vpc" })
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.labels, { Name = "${local.name_prefix}-igw" })
}

resource "aws_subnet" "runner" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.subnet_cidr
  availability_zone       = var.runner_availability_zone
  map_public_ip_on_launch = true

  tags = merge(local.labels, { Name = "${local.name_prefix}-subnet" })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(local.labels, { Name = "${local.name_prefix}-public-rt" })
}

resource "aws_route_table_association" "runner" {
  subnet_id      = aws_subnet.runner.id
  route_table_id = aws_route_table.public.id
}

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = merge(local.labels, { Name = "${local.name_prefix}-nat-eip" })
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.runner.id

  tags = merge(local.labels, { Name = "${local.name_prefix}-nat" })

  depends_on = [aws_internet_gateway.main]
}

resource "aws_security_group" "runner" {
  name        = "${local.name_prefix}-sg"
  description = "Cloud Measuring runner security group"
  vpc_id      = aws_vpc.main.id

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

  tags = merge(local.labels, { Name = "${local.name_prefix}-sg" })
}

resource "aws_key_pair" "runner" {
  count      = local.use_existing_key ? 0 : 1
  key_name   = "${local.name_prefix}-key"
  public_key = chomp(file(var.ssh_public_key_path))

  tags = merge(local.labels, { Name = "${local.name_prefix}-key" })
}

resource "aws_iam_role" "runner" {
  name               = "${local.name_prefix}-role"
  assume_role_policy = data.aws_iam_policy_document.runner_assume_role.json

  tags = merge(local.labels, { Name = "${local.name_prefix}-role" })
}

resource "aws_iam_role_policy_attachment" "runner_admin" {
  role       = aws_iam_role.runner.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_instance_profile" "runner" {
  name = "${local.name_prefix}-profile"
  role = aws_iam_role.runner.name

  tags = merge(local.labels, { Name = "${local.name_prefix}-profile" })
}

resource "aws_instance" "runner" {
  ami                         = var.image_id
  instance_type               = var.runner_machine_type
  availability_zone           = var.runner_availability_zone
  subnet_id                   = aws_subnet.runner.id
  private_ip                  = local.runner_private_ip
  vpc_security_group_ids      = [aws_security_group.runner.id]
  key_name                    = local.use_existing_key ? var.existing_key_pair_name : aws_key_pair.runner[0].key_name
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.runner.name

  root_block_device {
    volume_type           = var.root_volume_type
    volume_size           = var.root_volume_size_gib
    delete_on_termination = true
  }

  user_data = templatefile("${path.module}/templates/user_data.sh.tftpl", {
    node_role = "runner"
  })

  tags = merge(local.labels, { Name = "${local.name_prefix}-runner", Role = "runner" })
}
