#!/usr/bin/env bash
# Pre-campaign smoke for the storage path, on the spot market.
#
# Spot only exists in the AWS storage module, so this doubles as the first real
# exercise of the storage lifecycle: target discovery and reconciliation, the
# calibration probe now running after the suite, cpu-idle probing on a storage
# node, and node-facts collection.
#
# The thing being verified about spot is not that it is cheaper -- it is that
# purchase_model, read from the instance metadata service, comes back as 'spot'
# rather than agreeing with the request by construction. If a run reports
# use_spot_requested=1 and purchase_model=on-demand, the market option silently
# did not apply and every future spot scenario is mislabelled.
#
# The smallest useful shape: one instance, the minimum gp3 profile, one
# benchmark file, raw targets so no filesystem is created.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/../common.inc"

SCENARIO_NAME=aws_c6id.large_gp3_3000iops_raw_spot_smoke
BENCHMARK_DIR=storage/benchmarks/baseline

BENCHMARK_MACHINE_TYPE=c6id.large
BLOCK_VOLUME_SIZE_GIB=100
LOCAL_FILESYSTEM=raw
BLOCK_FILESYSTEM=raw

USE_SPOT=1

# Exercise the probe/record path on a storage node too. A virtualised instance
# will most likely report no-deep-idle-states, which is the correct answer.
CPU_IDLE_PINNING=1
