#!/usr/bin/env bash
# Cross-region: us-east-1a to us-west-2a.
#
# The long arm of the placement axis, and the one where the protocols have the
# most room to diverge: at ~60 ms RTT a single TCP retransmission or a
# congestion-control backoff costs far more than it does intra-AZ, while UDP
# simply drops the datagram and reports it. Watch dropped_messages here rather
# than reading the percentiles alone.
#
# Uses the server_image_id in baseline.tfvars, which is a us-west-2 AMI -- AMIs
# are region-scoped, so the server cannot boot the client's image.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.inc"

SCENARIO_NAME=aws_c6id.large_us-east-1a_us-west-2a_none_standard_ladder
OS_TUNING=standard
INSTANCE_AFFINITY=none
CLIENT_MACHINE_TYPE=c6id.large
SERVER_MACHINE_TYPE=c6id.large
CLIENT_AVAILABILITY_ZONE=us-east-1a
SERVER_AVAILABILITY_ZONE=us-west-2a
SERVER_REGION=us-west-2
PLACEMENT_MODE=cross-region
CPU_IDLE_PINNING=1
