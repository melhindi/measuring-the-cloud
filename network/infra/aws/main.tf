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

provider "aws" {
  alias   = "server"
  region  = local.effective_server_region
  profile = trimspace(var.aws_profile) != "" ? var.aws_profile : null
}

resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  name_prefix                 = "${var.project_name}-${random_id.suffix.hex}"
  cross_region                = trimspace(var.server_region) != "" && var.server_region != var.aws_region
  needs_separate_server_vpc   = local.cross_region
  use_existing_key_pair       = trimspace(var.existing_key_pair_name) != ""
  use_existing_vpc            = trimspace(var.existing_vpc_id) != ""
  use_existing_security_group = trimspace(var.existing_security_group_id) != ""
  use_placement_group         = var.instance_affinity != "none"
  placement_strategy          = var.instance_affinity == "co-located" ? "cluster" : var.instance_affinity == "different-host" ? "spread" : null
  effective_server_region     = trimspace(var.server_region) != "" ? var.server_region : var.aws_region

  availability_zones = distinct([
    var.client_availability_zone,
    var.server_availability_zone,
  ])

  subnet_cidrs_by_az = {
    for idx, az in local.availability_zones : az => idx == 0 ? var.client_subnet_cidr : var.server_subnet_cidr
  }

  client_private_ip = cidrhost(var.client_subnet_cidr, var.client_private_ip_host)
  server_private_ip = cidrhost(
    local.cross_region ? var.server_region_subnet_cidr : local.subnet_cidrs_by_az[var.server_availability_zone],
    var.server_private_ip_host
  )

  labels = {
    Project = var.project_name
    Run     = random_id.suffix.hex
  }
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

check "subnet_inputs" {
  assert {
    condition     = var.client_availability_zone == var.server_availability_zone || var.client_subnet_cidr != var.server_subnet_cidr
    error_message = "client_subnet_cidr and server_subnet_cidr must differ when client/server availability zones differ."
  }
}

check "placement_requires_same_az" {
  assert {
    condition = !(local.use_placement_group && (
      var.client_availability_zone != var.server_availability_zone || local.cross_region
    ))
    error_message = "instance_affinity co-located/different-host requires both instances in the same availability zone. For cross-AZ or cross-region scenarios set instance_affinity = \"none\"."
  }
}

check "cross_region_needs_public_access" {
  assert {
    condition     = !(local.cross_region && !var.assign_public_ip)
    error_message = "Cross-region scenarios require assign_public_ip = true since instances are on separate regional VPCs."
  }
}

resource "aws_placement_group" "bench" {
  count    = local.use_placement_group ? 1 : 0
  name     = "${local.name_prefix}-pg"
  strategy = local.placement_strategy

  tags = merge(local.labels, {
    Name             = "${local.name_prefix}-pg"
    InstanceAffinity = var.instance_affinity
  })
}

resource "aws_vpc" "main" {
  count                = local.use_existing_vpc ? 0 : 1
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.labels, { Name = "${local.name_prefix}-vpc" })
}

resource "aws_internet_gateway" "main" {
  count  = local.use_existing_vpc ? 0 : 1
  vpc_id = aws_vpc.main[0].id

  tags = merge(local.labels, { Name = "${local.name_prefix}-igw" })
}

resource "aws_subnet" "bench" {
  for_each = local.use_existing_vpc ? {} : (
    local.cross_region
      ? { (var.client_availability_zone) = var.client_subnet_cidr }
      : local.subnet_cidrs_by_az
  )

  vpc_id                  = aws_vpc.main[0].id
  cidr_block              = each.value
  availability_zone       = each.key
  map_public_ip_on_launch = var.assign_public_ip

  tags = merge(local.labels, { Name = "${local.name_prefix}-${each.key}-subnet" })
}

resource "aws_route_table" "main" {
  count  = local.use_existing_vpc ? 0 : 1
  vpc_id = aws_vpc.main[0].id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main[0].id
  }

  dynamic "route" {
    for_each = local.needs_separate_server_vpc ? [1] : []
    content {
      cidr_block                = var.server_vpc_cidr
      vpc_peering_connection_id = aws_vpc_peering_connection.cross_region[0].id
    }
  }

  tags = merge(local.labels, { Name = "${local.name_prefix}-rt" })

  depends_on = [aws_vpc_peering_connection_accepter.cross_region]
}

resource "aws_route_table_association" "bench" {
  for_each = aws_subnet.bench

  subnet_id      = each.value.id
  route_table_id = aws_route_table.main[0].id
}

resource "aws_vpc_peering_connection" "cross_region" {
  count       = local.use_existing_vpc == false && local.needs_separate_server_vpc ? 1 : 0
  vpc_id      = aws_vpc.main[0].id
  peer_vpc_id = aws_vpc.server[0].id
  peer_region = local.effective_server_region
  auto_accept = false

  tags = merge(local.labels, { Name = "${local.name_prefix}-peering" })
}

resource "aws_vpc_peering_connection_accepter" "cross_region" {
  count                     = local.use_existing_vpc == false && local.needs_separate_server_vpc ? 1 : 0
  provider                  = aws.server
  vpc_peering_connection_id = aws_vpc_peering_connection.cross_region[0].id
  auto_accept               = true

  tags = merge(local.labels, { Name = "${local.name_prefix}-peering-accepter" })
}

resource "aws_vpc" "server" {
  count                = local.use_existing_vpc == false && local.needs_separate_server_vpc ? 1 : 0
  provider             = aws.server
  cidr_block           = var.server_vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.labels, { Name = "${local.name_prefix}-vpc-server" })
}

resource "aws_internet_gateway" "server" {
  count    = local.use_existing_vpc == false && local.needs_separate_server_vpc ? 1 : 0
  provider = aws.server
  vpc_id   = aws_vpc.server[0].id

  tags = merge(local.labels, { Name = "${local.name_prefix}-igw-server" })
}

resource "aws_subnet" "server" {
  count                   = local.use_existing_vpc == false && local.needs_separate_server_vpc ? 1 : 0
  provider                = aws.server
  vpc_id                  = aws_vpc.server[0].id
  cidr_block              = var.server_region_subnet_cidr
  availability_zone       = var.server_availability_zone
  map_public_ip_on_launch = var.assign_public_ip

  tags = merge(local.labels, { Name = "${local.name_prefix}-subnet-server" })
}

resource "aws_route_table" "server" {
  count    = local.use_existing_vpc == false && local.needs_separate_server_vpc ? 1 : 0
  provider = aws.server
  vpc_id   = aws_vpc.server[0].id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.server[0].id
  }

  route {
    cidr_block                = var.vpc_cidr
    vpc_peering_connection_id = aws_vpc_peering_connection.cross_region[0].id
  }

  tags = merge(local.labels, { Name = "${local.name_prefix}-rt-server" })

  depends_on = [aws_vpc_peering_connection_accepter.cross_region]
}

resource "aws_route_table_association" "server" {
  count          = local.use_existing_vpc == false && local.needs_separate_server_vpc ? 1 : 0
  provider       = aws.server
  subnet_id      = aws_subnet.server[0].id
  route_table_id = aws_route_table.server[0].id
}

resource "aws_security_group" "bench" {
  count       = local.use_existing_security_group ? 0 : 1
  name        = "${local.name_prefix}-sg"
  description = "Network benchmark security group"
  vpc_id      = local.use_existing_vpc ? var.existing_vpc_id : aws_vpc.main[0].id

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

  dynamic "ingress" {
    for_each = local.needs_separate_server_vpc ? [1] : []
    content {
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      cidr_blocks = [var.server_vpc_cidr]
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.labels, { Name = "${local.name_prefix}-sg" })
}

resource "aws_security_group" "server" {
  count       = local.use_existing_security_group == false && local.needs_separate_server_vpc ? 1 : 0
  provider    = aws.server
  name        = "${local.name_prefix}-sg-server"
  description = "Network benchmark server security group (cross-region)"
  vpc_id      = aws_vpc.server[0].id

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

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.labels, { Name = "${local.name_prefix}-sg-server" })
}

resource "aws_key_pair" "bench" {
  count      = local.use_existing_key_pair ? 0 : 1
  key_name   = "${local.name_prefix}-key"
  public_key = chomp(file(var.ssh_public_key_path))

  tags = merge(local.labels, { Name = "${local.name_prefix}-key" })
}

resource "aws_key_pair" "server" {
  count      = local.use_existing_key_pair == false && local.needs_separate_server_vpc ? 1 : 0
  provider   = aws.server
  key_name   = "${local.name_prefix}-key"
  public_key = chomp(file(var.ssh_public_key_path))

  tags = merge(local.labels, { Name = "${local.name_prefix}-key-server" })
}

locals {
  client_subnet_id = (
    local.use_existing_vpc ? var.existing_subnet_id :
    aws_subnet.bench[var.client_availability_zone].id
  )
  server_subnet_id = (
    local.cross_region ? aws_subnet.server[0].id :
    local.use_existing_vpc ? var.existing_subnet_id :
    aws_subnet.bench[var.server_availability_zone].id
  )
  client_sg_ids = [local.use_existing_security_group ? var.existing_security_group_id : aws_security_group.bench[0].id]
  server_sg_ids = local.needs_separate_server_vpc ? [aws_security_group.server[0].id] : local.client_sg_ids
  client_key    = local.use_existing_key_pair ? var.existing_key_pair_name : aws_key_pair.bench[0].key_name
  server_key    = (
    local.use_existing_key_pair ? var.existing_key_pair_name :
    local.needs_separate_server_vpc ? aws_key_pair.server[0].key_name :
    aws_key_pair.bench[0].key_name
  )
  client_ami = var.image_id != "" ? var.image_id : data.aws_ami.ubuntu_client.id
  server_ami = var.image_id != "" ? var.image_id : (local.needs_separate_server_vpc ? data.aws_ami.ubuntu_server[0].id : data.aws_ami.ubuntu_client.id)
}

data "aws_ami" "ubuntu_client" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_ami" "ubuntu_server" {
  count       = local.needs_separate_server_vpc ? 1 : 0
  provider    = aws.server
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_instance" "client" {
  ami                         = local.client_ami
  instance_type               = var.client_machine_type
  availability_zone           = var.client_availability_zone
  subnet_id                   = local.client_subnet_id
  private_ip                  = local.client_private_ip
  vpc_security_group_ids      = local.client_sg_ids
  key_name                    = local.client_key
  associate_public_ip_address = var.assign_public_ip
  placement_group             = local.use_placement_group ? aws_placement_group.bench[0].name : null

  root_block_device {
    volume_type           = var.root_volume_type
    volume_size           = var.root_volume_size_gib
    delete_on_termination = true
  }

  user_data = templatefile("${path.module}/templates/user_data.sh.tftpl", {
    node_role = "client"
  })

  tags = merge(local.labels, { Name = "${local.name_prefix}-client", Role = "client" })
}

resource "aws_instance" "server" {
  provider                    = aws.server
  ami                         = local.server_ami
  instance_type               = var.server_machine_type
  availability_zone           = var.server_availability_zone
  subnet_id                   = local.server_subnet_id
  private_ip                  = local.server_private_ip
  vpc_security_group_ids      = local.server_sg_ids
  key_name                    = local.server_key
  associate_public_ip_address = var.assign_public_ip
  placement_group             = local.use_placement_group ? aws_placement_group.bench[0].name : null

  root_block_device {
    volume_type           = var.root_volume_type
    volume_size           = var.root_volume_size_gib
    delete_on_termination = true
  }

  user_data = templatefile("${path.module}/templates/user_data.sh.tftpl", {
    node_role = "server"
  })

  depends_on = [aws_vpc_peering_connection_accepter.cross_region]

  tags = merge(local.labels, { Name = "${local.name_prefix}-server", Role = "server" })
}
