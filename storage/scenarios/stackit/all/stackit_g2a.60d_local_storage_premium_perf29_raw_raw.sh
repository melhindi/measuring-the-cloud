#!/usr/bin/env bash

# shellcheck disable=SC1091
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/../block-storage/common.inc"

SCENARIO_NAME=stackit_g2a.60d_local_storage_premium_perf29_raw_raw
BENCHMARK_MACHINE_TYPE=g2a.60d
BLOCK_VOLUME_PERFORMANCE_CLASS=storage_premium_perf29
LOCAL_FILESYSTEM=raw
BLOCK_FILESYSTEM=raw
