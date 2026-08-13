#!/usr/bin/env bash
# Inter-AZ: us-east-1a to us-east-1b, one region.
#
# INSTANCE_AFFINITY=none because instances in different availability zones are
# in different buildings and therefore already on different hosts -- a placement
# group would add a capacity constraint that buys nothing.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.inc"

SCENARIO_NAME=aws_c6id.large_us-east-1a_us-east-1b_none_standard_ladder
OS_TUNING=standard
INSTANCE_AFFINITY=none
CLIENT_MACHINE_TYPE=c6id.large
SERVER_MACHINE_TYPE=c6id.large
CLIENT_AVAILABILITY_ZONE=us-east-1a
SERVER_AVAILABILITY_ZONE=us-east-1b
PLACEMENT_MODE=multi-az
CPU_IDLE_PINNING=1
