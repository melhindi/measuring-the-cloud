terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 5.0" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
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

resource "random_id" "suffix" { byte_length = 4 }

locals {
  name_prefix                 = "${var.project_name}-${random_id.suffix.hex}"
  cross_region                = trimspace(var.server_region) != "" && var.server_region != var.aws_region
  effective_server_region     = local.cross_region ? var.server_region : var.aws_region
  use_existing_key_pair       = trimspace(var.existing_key_pair_name) != ""
  use_existing_vpc            = trimspace(var.existing_vpc_id) != ""
  use_existing_security_group = trimspace(var.existing_security_group_id) != ""
  use_existing_nat_gateway    = trimspace(var.existing_nat_gateway_id) != ""
  use_public_ip               = var.assign_public_ip
  use_placement_group         = var.instance_affinity != "none"
  placement_strategy          = var.instance_affinity == "co-located" ? "cluster" : var.instance_affinity == "different-host" ? "spread" : null
  client_nat_required         = local.cross_region && !local.use_existing_vpc && !local.use_public_ip

  client_availability_zones = local.cross_region ? [var.client_availability_zone] : distinct([
    var.client_availability_zone,
    var.server_availability_zone,
  ])
  subnet_cidrs_by_az = {
    for idx, az in local.client_availability_zones : az => idx == 0 ? var.client_subnet_cidr : var.server_subnet_cidr
  }

  client_vpc_id     = local.use_existing_vpc ? data.aws_vpc.existing[0].id : aws_vpc.main[0].id
  client_vpc_cidr   = local.use_existing_vpc ? data.aws_vpc.existing[0].cidr_block : var.vpc_cidr
  client_igw_id     = local.use_existing_vpc ? data.aws_internet_gateway.existing[0].id : aws_internet_gateway.main[0].id
  client_private_ip = cidrhost(local.subnet_cidrs_by_az[var.client_availability_zone], var.client_private_ip_host)
  server_private_ip = local.cross_region ? cidrhost(var.server_region_subnet_cidr, var.server_private_ip_host) : cidrhost(local.subnet_cidrs_by_az[var.server_availability_zone], var.server_private_ip_host)
  client_key_name   = local.use_existing_key_pair ? var.existing_key_pair_name : aws_key_pair.bench[0].key_name
  server_key_name   = local.use_existing_key_pair ? var.existing_key_pair_name : (local.cross_region ? aws_key_pair.server[0].key_name : aws_key_pair.bench[0].key_name)
  server_ami        = local.cross_region ? (trimspace(var.server_image_id) != "" ? var.server_image_id : data.aws_ssm_parameter.server_ubuntu[0].value) : var.image_id
  server_ssh_cidr   = local.use_existing_vpc ? var.runner_subnet_cidr : var.ssh_ingress_cidr

  labels = { Project = var.project_name, Run = random_id.suffix.hex }
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

data "aws_ssm_parameter" "server_ubuntu" {
  count    = local.cross_region && trimspace(var.server_image_id) == "" ? 1 : 0
  provider = aws.server
  name     = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

check "ssh_key_inputs" {
  assert {
    condition     = local.use_existing_key_pair || trimspace(var.ssh_public_key_path) != ""
    error_message = "Set existing_key_pair_name, or provide ssh_public_key_path to create new AWS key pairs."
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
    condition     = local.use_public_ip || local.use_existing_nat_gateway || (!local.use_existing_vpc && local.cross_region)
    error_message = "Private benchmark nodes require existing_nat_gateway_id when reusing a VPC; a cross-region managed VPC creates NAT egress automatically."
  }
}

check "cross_region_inputs" {
  assert {
    condition = !local.cross_region || (
      var.instance_affinity == "none" &&
      !cidrcontains(local.client_vpc_cidr, cidrhost(var.server_vpc_cidr, 0)) &&
      !cidrcontains(var.server_vpc_cidr, cidrhost(local.client_vpc_cidr, 0)) &&
      cidrcontains(local.client_vpc_cidr, cidrhost(var.client_subnet_cidr, 0)) &&
      cidrcontains(var.server_vpc_cidr, cidrhost(var.server_region_subnet_cidr, 0)) &&
      cidrcontains(var.server_vpc_cidr, cidrhost(var.server_nat_subnet_cidr, 0)) &&
      !cidrcontains(var.server_region_subnet_cidr, cidrhost(var.server_nat_subnet_cidr, 0)) &&
      !cidrcontains(var.server_nat_subnet_cidr, cidrhost(var.server_region_subnet_cidr, 0)) &&
      (!local.use_existing_vpc || (trimspace(var.existing_runner_route_table_id) != "" && trimspace(var.runner_subnet_cidr) != ""))
    )
    error_message = "Cross-region scenarios require non-overlapping VPC and server subnet CIDRs, instance_affinity = none, and existing_runner_route_table_id plus runner_subnet_cidr when reusing a runner VPC."
  }
}

check "placement_inputs" {
  assert {
    condition     = var.instance_affinity != "co-located" || (!local.cross_region && var.client_availability_zone == var.server_availability_zone)
    error_message = "AWS co-located placement requires both instances in the same availability zone and region."
  }
}

resource "aws_placement_group" "bench" {
  count    = local.use_placement_group && !local.cross_region ? 1 : 0
  name     = "${local.name_prefix}-pg"
  strategy = local.placement_strategy
  tags     = merge(local.labels, { Name = "${local.name_prefix}-pg", InstanceAffinity = var.instance_affinity })
}

resource "aws_vpc" "main" {
  count                = local.use_existing_vpc ? 0 : 1
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(local.labels, { Name = "${local.name_prefix}-vpc" })
}

resource "aws_internet_gateway" "main" {
  count  = local.use_existing_vpc ? 0 : 1
  vpc_id = aws_vpc.main[0].id
  tags   = merge(local.labels, { Name = "${local.name_prefix}-igw" })
}

resource "aws_subnet" "bench" {
  for_each                = local.subnet_cidrs_by_az
  vpc_id                  = local.client_vpc_id
  cidr_block              = each.value
  availability_zone       = each.key
  map_public_ip_on_launch = local.use_public_ip
  tags                    = merge(local.labels, { Name = "${local.name_prefix}-${each.key}-subnet" })
}

resource "aws_subnet" "client_nat" {
  count                   = local.client_nat_required ? 1 : 0
  vpc_id                  = local.client_vpc_id
  cidr_block              = var.client_nat_subnet_cidr
  availability_zone       = var.client_availability_zone
  map_public_ip_on_launch = true
  tags                    = merge(local.labels, { Name = "${local.name_prefix}-client-nat-subnet" })
}

resource "aws_route_table" "client_nat" {
  count  = local.client_nat_required ? 1 : 0
  vpc_id = local.client_vpc_id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = local.client_igw_id
  }
  tags = merge(local.labels, { Name = "${local.name_prefix}-client-nat-rt" })
}

resource "aws_route_table_association" "client_nat" {
  count          = local.client_nat_required ? 1 : 0
  subnet_id      = aws_subnet.client_nat[0].id
  route_table_id = aws_route_table.client_nat[0].id
}

resource "aws_eip" "client_nat" {
  count  = local.client_nat_required ? 1 : 0
  domain = "vpc"
  tags   = merge(local.labels, { Name = "${local.name_prefix}-client-nat-eip" })
}

resource "aws_nat_gateway" "client" {
  count         = local.client_nat_required ? 1 : 0
  allocation_id = aws_eip.client_nat[0].id
  subnet_id     = aws_subnet.client_nat[0].id
  depends_on    = [aws_internet_gateway.main]
  tags          = merge(local.labels, { Name = "${local.name_prefix}-client-nat" })
}

resource "aws_route_table" "client" {
  vpc_id = local.client_vpc_id
  dynamic "route" {
    for_each = local.use_public_ip ? [1] : []
    content {
      cidr_block = "0.0.0.0/0"
      gateway_id = local.client_igw_id
    }
  }
  dynamic "route" {
    for_each = !local.use_public_ip ? [1] : []
    content {
      cidr_block     = "0.0.0.0/0"
      nat_gateway_id = local.use_existing_vpc ? var.existing_nat_gateway_id : aws_nat_gateway.client[0].id
    }
  }
  dynamic "route" {
    for_each = local.cross_region ? [1] : []
    content {
      cidr_block                = var.server_vpc_cidr
      vpc_peering_connection_id = aws_vpc_peering_connection.cross_region[0].id
    }
  }
  depends_on = [aws_vpc_peering_connection_accepter.cross_region]
  tags       = merge(local.labels, { Name = "${local.name_prefix}-client-rt" })
}

resource "aws_route_table_association" "client" {
  for_each       = aws_subnet.bench
  subnet_id      = each.value.id
  route_table_id = aws_route_table.client.id
}

resource "aws_security_group" "bench" {
  count       = local.use_existing_security_group ? 0 : 1
  name        = "${local.name_prefix}-sg"
  description = "Network benchmark security group"
  vpc_id      = local.client_vpc_id
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

resource "aws_key_pair" "bench" {
  count      = local.use_existing_key_pair ? 0 : 1
  key_name   = "${local.name_prefix}-key"
  public_key = chomp(file(var.ssh_public_key_path))
  tags       = merge(local.labels, { Name = "${local.name_prefix}-key" })
}

resource "aws_key_pair" "server" {
  count      = local.cross_region && !local.use_existing_key_pair ? 1 : 0
  provider   = aws.server
  key_name   = "${local.name_prefix}-key"
  public_key = chomp(file(var.ssh_public_key_path))
  tags       = merge(local.labels, { Name = "${local.name_prefix}-key" })
}

resource "aws_vpc" "server" {
  count                = local.cross_region ? 1 : 0
  provider             = aws.server
  cidr_block           = var.server_vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(local.labels, { Name = "${local.name_prefix}-server-vpc" })
}

resource "aws_internet_gateway" "server" {
  count    = local.cross_region ? 1 : 0
  provider = aws.server
  vpc_id   = aws_vpc.server[0].id
  tags     = merge(local.labels, { Name = "${local.name_prefix}-server-igw" })
}

resource "aws_subnet" "server_nat" {
  count                   = local.cross_region ? 1 : 0
  provider                = aws.server
  vpc_id                  = aws_vpc.server[0].id
  cidr_block              = var.server_nat_subnet_cidr
  availability_zone       = var.server_availability_zone
  map_public_ip_on_launch = true
  tags                    = merge(local.labels, { Name = "${local.name_prefix}-server-nat-subnet" })
}

resource "aws_subnet" "server" {
  count                   = local.cross_region ? 1 : 0
  provider                = aws.server
  vpc_id                  = aws_vpc.server[0].id
  cidr_block              = var.server_region_subnet_cidr
  availability_zone       = var.server_availability_zone
  map_public_ip_on_launch = false
  tags                    = merge(local.labels, { Name = "${local.name_prefix}-server-subnet" })
}

resource "aws_route_table" "server_public" {
  count    = local.cross_region ? 1 : 0
  provider = aws.server
  vpc_id   = aws_vpc.server[0].id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.server[0].id
  }
  tags = merge(local.labels, { Name = "${local.name_prefix}-server-public-rt" })
}

resource "aws_route_table_association" "server_public" {
  count          = local.cross_region ? 1 : 0
  provider       = aws.server
  subnet_id      = aws_subnet.server_nat[0].id
  route_table_id = aws_route_table.server_public[0].id
}

resource "aws_eip" "server_nat" {
  count    = local.cross_region ? 1 : 0
  provider = aws.server
  domain   = "vpc"
  tags     = merge(local.labels, { Name = "${local.name_prefix}-server-nat-eip" })
}

resource "aws_nat_gateway" "server" {
  count         = local.cross_region ? 1 : 0
  provider      = aws.server
  allocation_id = aws_eip.server_nat[0].id
  subnet_id     = aws_subnet.server_nat[0].id
  depends_on    = [aws_internet_gateway.server]
  tags          = merge(local.labels, { Name = "${local.name_prefix}-server-nat" })
}

resource "aws_vpc_peering_connection" "cross_region" {
  count       = local.cross_region ? 1 : 0
  vpc_id      = local.client_vpc_id
  peer_vpc_id = aws_vpc.server[0].id
  peer_region = local.effective_server_region
  auto_accept = false
  tags        = merge(local.labels, { Name = "${local.name_prefix}-cross-region" })
}

resource "aws_vpc_peering_connection_accepter" "cross_region" {
  count                     = local.cross_region ? 1 : 0
  provider                  = aws.server
  vpc_peering_connection_id = aws_vpc_peering_connection.cross_region[0].id
  auto_accept               = true
  tags                      = merge(local.labels, { Name = "${local.name_prefix}-cross-region" })
}

resource "aws_route_table" "server_private" {
  count    = local.cross_region ? 1 : 0
  provider = aws.server
  vpc_id   = aws_vpc.server[0].id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.server[0].id
  }
  route {
    cidr_block                = local.client_vpc_cidr
    vpc_peering_connection_id = aws_vpc_peering_connection_accepter.cross_region[0].id
  }
  tags = merge(local.labels, { Name = "${local.name_prefix}-server-private-rt" })
}

resource "aws_route_table_association" "server_private" {
  count          = local.cross_region ? 1 : 0
  provider       = aws.server
  subnet_id      = aws_subnet.server[0].id
  route_table_id = aws_route_table.server_private[0].id
}

resource "aws_route" "runner_to_server" {
  count                     = local.cross_region && local.use_existing_vpc ? 1 : 0
  route_table_id            = var.existing_runner_route_table_id
  destination_cidr_block    = var.server_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.cross_region[0].id
  depends_on                = [aws_vpc_peering_connection_accepter.cross_region]
}

resource "aws_security_group" "server" {
  count       = local.cross_region ? 1 : 0
  provider    = aws.server
  name        = "${local.name_prefix}-server-sg"
  description = "Cross-region network benchmark server security group"
  vpc_id      = aws_vpc.server[0].id
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [local.server_ssh_cidr]
  }
  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.client_subnet_cidr]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = merge(local.labels, { Name = "${local.name_prefix}-server-sg" })
}

resource "aws_instance" "client" {
  ami                         = var.image_id
  instance_type               = var.client_machine_type
  availability_zone           = var.client_availability_zone
  subnet_id                   = aws_subnet.bench[var.client_availability_zone].id
  private_ip                  = local.client_private_ip
  vpc_security_group_ids      = [local.use_existing_security_group ? var.existing_security_group_id : aws_security_group.bench[0].id]
  key_name                    = local.client_key_name
  associate_public_ip_address = local.use_public_ip
  placement_group             = local.use_placement_group && !local.cross_region ? aws_placement_group.bench[0].name : null
  root_block_device {
    volume_type           = var.root_volume_type
    volume_size           = var.root_volume_size_gib
    delete_on_termination = true
  }
  user_data = templatefile("${path.module}/templates/user_data.sh.tftpl", { node_role = "client" })
  tags      = merge(local.labels, { Name = "${local.name_prefix}-client", Role = "client" })

  # Spot is opt-in per scenario and off by default. "one-time" plus "terminate"
  # is deliberate: a persistent request would relaunch after an interruption and
  # leave a standing request that destroy does not clean up. See
  # storage/scenarios/aws/all/README-spot.md for why the study itself should not
  # use this -- spot draws from spare capacity and so influences which physical
  # host you land on.
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
}

resource "aws_instance" "server" {
  count                       = local.cross_region ? 0 : 1
  ami                         = var.image_id
  instance_type               = var.server_machine_type
  availability_zone           = var.server_availability_zone
  subnet_id                   = aws_subnet.bench[var.server_availability_zone].id
  private_ip                  = local.server_private_ip
  vpc_security_group_ids      = [local.use_existing_security_group ? var.existing_security_group_id : aws_security_group.bench[0].id]
  key_name                    = local.server_key_name
  associate_public_ip_address = local.use_public_ip
  placement_group             = local.use_placement_group ? aws_placement_group.bench[0].name : null
  root_block_device {
    volume_type           = var.root_volume_type
    volume_size           = var.root_volume_size_gib
    delete_on_termination = true
  }
  user_data = templatefile("${path.module}/templates/user_data.sh.tftpl", { node_role = "server" })
  tags      = merge(local.labels, { Name = "${local.name_prefix}-server", Role = "server" })

  # Spot is opt-in per scenario and off by default. "one-time" plus "terminate"
  # is deliberate: a persistent request would relaunch after an interruption and
  # leave a standing request that destroy does not clean up. See
  # storage/scenarios/aws/all/README-spot.md for why the study itself should not
  # use this -- spot draws from spare capacity and so influences which physical
  # host you land on.
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
}

resource "aws_instance" "server_remote" {
  count                       = local.cross_region ? 1 : 0
  provider                    = aws.server
  ami                         = local.server_ami
  instance_type               = var.server_machine_type
  availability_zone           = var.server_availability_zone
  subnet_id                   = aws_subnet.server[0].id
  private_ip                  = local.server_private_ip
  vpc_security_group_ids      = [aws_security_group.server[0].id]
  key_name                    = local.server_key_name
  associate_public_ip_address = false
  root_block_device {
    volume_type           = var.root_volume_type
    volume_size           = var.root_volume_size_gib
    delete_on_termination = true
  }
  user_data  = templatefile("${path.module}/templates/user_data.sh.tftpl", { node_role = "server" })
  depends_on = [aws_vpc_peering_connection_accepter.cross_region, aws_route_table_association.server_private]
  tags       = merge(local.labels, { Name = "${local.name_prefix}-server", Role = "server" })

  # Spot is opt-in per scenario and off by default. "one-time" plus "terminate"
  # is deliberate: a persistent request would relaunch after an interruption and
  # leave a standing request that destroy does not clean up. See
  # storage/scenarios/aws/all/README-spot.md for why the study itself should not
  # use this -- spot draws from spare capacity and so influences which physical
  # host you land on.
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
}
