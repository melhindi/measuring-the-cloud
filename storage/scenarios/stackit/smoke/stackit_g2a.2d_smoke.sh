#!/usr/bin/env bash
# STACKIT storage plumbing smoke, on the smallest machine and volume.
#
# Exercises the storage lifecycle on a second provider: STACKIT discovers the
# local disk by its ephemeral0 filesystem label and the attached volume by
# device serial, which is a different code path from the AWS NVMe by-id lookup.
# Also covers the calibration probe, cpu-idle probing and node-facts on a
# STACKIT storage node.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/../block-storage/common.inc"

SCENARIO_NAME=stackit_g2a.2d_smoke
BENCHMARK_DIR=storage/benchmarks/baseline

BENCHMARK_MACHINE_TYPE=g2a.2d
BLOCK_VOLUME_SIZE_GIB=20
BLOCK_VOLUME_PERFORMANCE_CLASS=storage_premium_perf6
CPU_IDLE_PINNING=1
