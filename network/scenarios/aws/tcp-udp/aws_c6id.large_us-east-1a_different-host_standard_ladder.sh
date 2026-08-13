#!/usr/bin/env bash
# Intra-AZ: two instances in one availability zone, on different hosts.
#
# different-host rather than none is load-bearing here. With no placement group
# AWS may put both instances on the same physical host, and it does not report
# which it did -- so "intra-AZ latency" would silently be a mixture of
# same-host and cross-host measurements that varies between provisionings. The
# spread strategy guarantees distinct racks, and unlike the cluster strategy
# used by co-located/ it carries no meaningful capacity risk at two instances.
#
# This is the floor of the placement axis: whatever protocol difference exists
# here is the one attributable to the transport rather than to distance.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.inc"

SCENARIO_NAME=aws_c6id.large_us-east-1a_different-host_standard_ladder
OS_TUNING=standard
INSTANCE_AFFINITY=different-host
CLIENT_MACHINE_TYPE=c6id.large
SERVER_MACHINE_TYPE=c6id.large
CLIENT_AVAILABILITY_ZONE=us-east-1a
SERVER_AVAILABILITY_ZONE=us-east-1a
PLACEMENT_MODE=single-az
CPU_IDLE_PINNING=1
