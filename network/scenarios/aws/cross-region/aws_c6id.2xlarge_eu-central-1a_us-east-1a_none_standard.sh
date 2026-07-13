#!/usr/bin/env bash
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.inc"

SCENARIO_NAME=aws_c6id.2xlarge_eu-central-1a_us-east-1a_none_standard
OS_TUNING=standard
INSTANCE_AFFINITY=none
CLIENT_MACHINE_TYPE=c6id.2xlarge
SERVER_MACHINE_TYPE=c6id.2xlarge
CLIENT_AVAILABILITY_ZONE=eu-central-1a
SERVER_AVAILABILITY_ZONE=us-east-1a
SERVER_REGION=us-east-1
PLACEMENT_MODE=cross-region