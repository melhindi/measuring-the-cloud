#!/usr/bin/env bash
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/../common.inc"

SCENARIO_NAME=aws_c6id.large_eu-central-1a_different-host_tuned
OS_TUNING=network-throughput
INSTANCE_AFFINITY=different-host
CLIENT_MACHINE_TYPE=c6id.large
SERVER_MACHINE_TYPE=c6id.large
CLIENT_AVAILABILITY_ZONE=eu-central-1a
SERVER_AVAILABILITY_ZONE=eu-central-1b
PLACEMENT_MODE=multi-az
