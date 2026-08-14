#!/usr/bin/env bash
# Inter-zone: us-east1-b to us-east1-c, one region.
#
# The first inter-zone GCP scenario in the repository -- the existing GCP
# scenarios cover intra-zone and cross-region only, which left a hole exactly
# where the placement axis needs a middle point to be comparable with AWS and
# STACKIT.
#
# INSTANCE_AFFINITY=none: a group placement policy is zonal, so it cannot span
# two zones, and instances in different zones are already on different hosts.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.inc"

SCENARIO_NAME=gcp_n2-standard-2_us-east1-b_us-east1-c_none_standard_ladder
OS_TUNING=standard
INSTANCE_AFFINITY=none
CLIENT_MACHINE_TYPE=n2-standard-2
SERVER_MACHINE_TYPE=n2-standard-2
CLIENT_REGION=us-east1
CLIENT_AVAILABILITY_ZONE=us-east1-b
SERVER_AVAILABILITY_ZONE=us-east1-c
PLACEMENT_MODE=multi-az
CPU_IDLE_PINNING=1
