#!/usr/bin/env bash
# STACKIT plumbing smoke.
#
# The first use of network/scenarios/stackit/baseline.tfvars, which was absent
# until recently -- all 43 STACKIT network scenarios pointed at a file that did
# not exist, so none of them could run. This verifies that file provisions.
#
# Also the first exercise of the OpenStack branch of collect-node-facts, which
# reads image and flavor from the config-drive metadata and records
# purchase_model=on-demand because STACKIT has no spot market.
#
# network-throughput checks that the shipped tuning script applies on STACKIT
# and that the read-back lands in os-tuning.env.
# STACKIT keeps common.inc per subfolder rather than at provider level, unlike
# the AWS and GCP trees.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/../all/common.inc"

SCENARIO_NAME=stackit_g2a.2d_eu01-1_none_tuned_smoke
BENCHMARK_DIR=network/benchmarks/smoke

OS_TUNING=network-throughput
INSTANCE_AFFINITY=none
CLIENT_MACHINE_TYPE=g2a.2d
SERVER_MACHINE_TYPE=g2a.2d
CLIENT_AVAILABILITY_ZONE=eu01-1
SERVER_AVAILABILITY_ZONE=eu01-1
PLACEMENT_MODE=single-az
CPU_IDLE_PINNING=1
