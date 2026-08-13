#!/usr/bin/env bash
# Intra-zone: two instances in us-east4-a, on different hosts.
#
# different-host maps to a group placement policy with
# availability_domain_count = 2, which spreads the pair across failure domains
# within the zone. As on AWS, the point is that "intra-AZ" means one thing
# rather than a mixture of same-host and cross-host draws.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.inc"

SCENARIO_NAME=gcp_n2-standard-2_us-east4-a_different-host_standard_ladder
OS_TUNING=standard
INSTANCE_AFFINITY=different-host
CLIENT_MACHINE_TYPE=n2-standard-2
SERVER_MACHINE_TYPE=n2-standard-2
CLIENT_REGION=us-east4
CLIENT_AVAILABILITY_ZONE=us-east4-a
SERVER_AVAILABILITY_ZONE=us-east4-a
PLACEMENT_MODE=single-az
CPU_IDLE_PINNING=1
