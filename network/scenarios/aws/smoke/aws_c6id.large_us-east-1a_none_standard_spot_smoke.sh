#!/usr/bin/env bash
# The plumbing smoke, on the spot market.
#
# Purely a mechanism test. The point is that purchase_model, read from the
# instance metadata service on both ends of the pair, comes back 'spot' rather
# than agreeing with the request by construction -- and that it does so for the
# client and the server independently, since the market option is applied to
# each instance separately.
#
# This is NOT how the TCP-vs-UDP study should run. Spot draws from spare
# capacity and therefore influences which physical host each instance lands on,
# and host draw is not a free variable at the effect sizes that study is trying
# to resolve. Keep every arm of a real comparison on one purchasing model; the
# report warns when a result set spans both.
#
# INSTANCE_AFFINITY is deliberately none: a cluster placement group needs
# capacity for both instances on one rack, which spare capacity frequently
# cannot satisfy, and the runner warns about that combination.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/../common.inc"

SCENARIO_NAME=aws_c6id.large_us-east-1a_none_standard_spot_smoke
BENCHMARK_DIR=network/benchmarks/latency-vs-rate

OS_TUNING=standard
INSTANCE_AFFINITY=none
CLIENT_MACHINE_TYPE=c6id.large
SERVER_MACHINE_TYPE=c6id.large
CLIENT_AVAILABILITY_ZONE=us-east-1a
SERVER_AVAILABILITY_ZONE=us-east-1a
PLACEMENT_MODE=single-az

USE_SPOT=1
CPU_IDLE_PINNING=1
