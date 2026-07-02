#!/usr/bin/env bash
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/../common.inc"

SCENARIO_NAME=aws_c6id.32xlarge_storage_gp3_6000iops_250mbps_standard
BENCHMARK_MACHINE_TYPE=c6id.32xlarge
BLOCK_VOLUME_SIZE_GIB=300
BLOCK_VOLUME_TYPE=gp3
BLOCK_VOLUME_IOPS=6000
BLOCK_VOLUME_THROUGHPUT_MBPS=250
