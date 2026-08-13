#!/usr/bin/env bash
# Inter-AZ: eu01-1 to eu01-2.
#
# The last point on STACKIT's placement axis; there is no cross-region arm for
# this provider.
#
# INSTANCE_AFFINITY=none because an affinity group is scoped to one availability
# zone, and two zones already imply two hosts.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.inc"

SCENARIO_NAME=stackit_g2a.2d_eu01-1_eu01-2_none_standard_ladder
OS_TUNING=standard
INSTANCE_AFFINITY=none
CLIENT_MACHINE_TYPE=g2a.2d
SERVER_MACHINE_TYPE=g2a.2d
CLIENT_AVAILABILITY_ZONE=eu01-1
SERVER_AVAILABILITY_ZONE=eu01-2
PLACEMENT_MODE=multi-az
CPU_IDLE_PINNING=1
