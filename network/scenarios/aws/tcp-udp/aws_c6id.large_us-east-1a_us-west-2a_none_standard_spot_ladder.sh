#!/usr/bin/env bash
# Cross-region on spot: us-east-1a to us-west-2a.
#
# A spot-purchased twin of the on-demand cross-region scenario, kept as its own
# file so the on-demand definition survives for anyone who wants the arm without
# the purchase-model difference.
#
# Two things to know before comparing its numbers with the other AWS arms.
#
# Spot barely helps here. Compute is about $0.12 of a roughly $1.07 scenario --
# the rest is cross-region egress from the capacity arms, which spot does not
# discount. A 65% discount on 11% of the bill is worth about eight cents.
#
# And it is the only AWS arm on spot: intra-AZ and inter-AZ ran on-demand. Spot
# draws from spare capacity, so it influences which physical host you land on,
# which is an uncontrolled variable sitting on the quantity being measured. The
# node records purchase_model from the metadata service, so the difference is
# visible in the data rather than merely known -- but visible is not controlled,
# and a cross-region-versus-intra-AZ comparison drawn from these rows carries it.
#
# Spot is also why this may simply fail to launch. Two regions must both have
# spare c6id.large capacity at once; the runner retries, and a scenario that
# never provisions costs nothing.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.inc"

SCENARIO_NAME=aws_c6id.large_us-east-1a_us-west-2a_none_standard_spot_ladder
OS_TUNING=standard
INSTANCE_AFFINITY=none
CLIENT_MACHINE_TYPE=c6id.large
SERVER_MACHINE_TYPE=c6id.large
CLIENT_AVAILABILITY_ZONE=us-east-1a
SERVER_AVAILABILITY_ZONE=us-west-2a
SERVER_REGION=us-west-2
PLACEMENT_MODE=cross-region
CPU_IDLE_PINNING=1
USE_SPOT=1
