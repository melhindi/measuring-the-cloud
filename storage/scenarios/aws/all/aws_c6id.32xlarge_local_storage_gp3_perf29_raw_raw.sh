#!/usr/bin/env bash
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/../common.inc"

SCENARIO_NAME=aws_c6id.32xlarge_local_storage_gp3_perf29_raw_raw
BENCHMARK_MACHINE_TYPE=c6id.32xlarge
BLOCK_VOLUME_SIZE_GIB=300
BLOCK_VOLUME_TYPE=gp3
BLOCK_VOLUME_IOPS=16000
BLOCK_VOLUME_THROUGHPUT_MBPS=1000
LOCAL_FILESYSTEM=raw
BLOCK_FILESYSTEM=raw
