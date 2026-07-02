#!/usr/bin/env bash
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/../common.inc"

SCENARIO_NAME=aws_c6id.metal_local_storage_gp3_perf29_xfs_xfs
BENCHMARK_MACHINE_TYPE=c6id.metal
BLOCK_VOLUME_SIZE_GIB=300
BLOCK_VOLUME_TYPE=gp3
BLOCK_VOLUME_IOPS=16000
BLOCK_VOLUME_THROUGHPUT_MBPS=1000
LOCAL_FILESYSTEM=xfs
BLOCK_FILESYSTEM=xfs
