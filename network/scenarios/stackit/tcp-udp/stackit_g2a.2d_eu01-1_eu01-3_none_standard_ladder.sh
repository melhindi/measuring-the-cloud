#!/usr/bin/env bash
# Inter-AZ: eu01-1 to eu01-3.
#
# The last point on STACKIT's placement axis; there is no cross-region arm for
# this provider.
#
# eu01-3 rather than eu01-2. The first attempt at this scenario paired eu01-1
# with eu01-2 and failed to provision three times in a row on 2026-08-13, each
# attempt erroring on the server's public IP and then the server itself. The
# client in eu01-1 was created without trouble on every attempt, and the
# intra-AZ scenario -- both instances in eu01-1 -- ran to completion minutes
# earlier, so the failure tracked the zone rather than the scenario. eu01-3 is
# used by the pre-existing multi-az scenarios and is the same one hop away.
#
# If this zone also refuses, the thing to check is whether it is capacity for
# the g2a.2d flavor or the public IP allocation specifically, because only the
# second is worth working around -- --access-mode private provisions without
# public IPs.
#
# INSTANCE_AFFINITY=none because an affinity group is scoped to one availability
# zone, and two zones already imply two hosts.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.inc"

SCENARIO_NAME=stackit_g2a.2d_eu01-1_eu01-3_none_standard_ladder
OS_TUNING=standard
INSTANCE_AFFINITY=none
CLIENT_MACHINE_TYPE=g2a.2d
SERVER_MACHINE_TYPE=g2a.2d
CLIENT_AVAILABILITY_ZONE=eu01-1
SERVER_AVAILABILITY_ZONE=eu01-3
PLACEMENT_MODE=multi-az
CPU_IDLE_PINNING=1
