#!/usr/bin/env bash
# Pre-campaign smoke: exercise every mechanism that has never run on real
# infrastructure, on the cheapest pair, for a few minutes.
#
# What this is checking, none of which is covered by the local tests:
#   - push_remote_scripts now runs before apply_os_tuning, and the tuning script
#     is shipped from the repository rather than baked into the image
#   - collect-node-facts.sh against a real metadata service (image, instance
#     type, purchase model, MTU, cpufreq)
#   - cpu-idle-pin.sh against a real /dev/cpu_dma_latency
#   - sockperf under-load with a controlled --mps, and whether the offered rate
#     is actually delivered
#   - the ladder resolving its defaults to 3 repetitions rather than 1
#   - the telemetry sidecar with sysstat present
#   - retrieval of node-facts.env, os-tuning.env and cpu-idle-*.env from both
#     ends of the pair
#
# Deliberately a single AZ with no placement group: this is a plumbing test, not
# a measurement, and cluster placement groups add a capacity failure mode that
# would confuse a first run.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/../common.inc"

SCENARIO_NAME=aws_c6id.large_us-east-1a_none_standard_smoke
BENCHMARK_DIR=network/benchmarks/latency-vs-rate

OS_TUNING=standard
INSTANCE_AFFINITY=none
CLIENT_MACHINE_TYPE=c6id.large
SERVER_MACHINE_TYPE=c6id.large
CLIENT_AVAILABILITY_ZONE=us-east-1a
SERVER_AVAILABILITY_ZONE=us-east-1a
PLACEMENT_MODE=single-az

# Exercise the probe/record path. On a virtualised instance this will most
# likely report no-deep-idle-states, which is the correct answer and still
# validates the plumbing; the supported path gets exercised by the c6id.metal
# storage scenarios.
CPU_IDLE_PINNING=1
