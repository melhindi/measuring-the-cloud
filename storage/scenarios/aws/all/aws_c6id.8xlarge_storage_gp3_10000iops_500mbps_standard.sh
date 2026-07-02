#!/usr/bin/env bash
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/../common.inc"

SCENARIO_NAME=aws_c6id.8xlarge_storage_gp3_10000iops_500mbps_standard
BENCHMARK_MACHINE_TYPE=c6id.8xlarge
BLOCK_VOLUME_SIZE_GIB=300
BLOCK_VOLUME_TYPE=gp3
BLOCK_VOLUME_IOPS=10000
BLOCK_VOLUME_THROUGHPUT_MBPS=500
