#!/usr/bin/env bash
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.inc"

SCENARIO_NAME=aws_c6id.large_us-east-1a_us-west-2a_none_tuned
OS_TUNING=network-throughput
INSTANCE_AFFINITY=none
CLIENT_MACHINE_TYPE=c6id.large
SERVER_MACHINE_TYPE=c6id.large
CLIENT_AVAILABILITY_ZONE=us-east-1a
SERVER_AVAILABILITY_ZONE=us-west-2a
SERVER_REGION=us-west-2
PLACEMENT_MODE=cross-region
