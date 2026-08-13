#!/usr/bin/env bash
# Intra-AZ: two instances in eu01-1, on different hosts.
#
# different-host maps to a hard-anti-affinity server group, which is the
# strongest of the three providers' guarantees -- OpenStack refuses to schedule
# the second instance onto the first's host rather than merely preferring not
# to. If capacity in eu01-1 is tight this can fail to provision, which is the
# correct failure: a silently co-located pair would be worse than no data.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.inc"

SCENARIO_NAME=stackit_g2a.2d_eu01-1_different-host_standard_ladder
OS_TUNING=standard
INSTANCE_AFFINITY=different-host
CLIENT_MACHINE_TYPE=g2a.2d
SERVER_MACHINE_TYPE=g2a.2d
CLIENT_AVAILABILITY_ZONE=eu01-1
SERVER_AVAILABILITY_ZONE=eu01-1
PLACEMENT_MODE=single-az
CPU_IDLE_PINNING=1
