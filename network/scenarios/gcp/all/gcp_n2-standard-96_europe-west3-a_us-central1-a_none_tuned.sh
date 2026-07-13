#!/usr/bin/env bash
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/../common.inc"

SCENARIO_NAME=gcp_n2-standard-96_europe-west3-a_us-central1-a_none_tuned
OS_TUNING=network-throughput
INSTANCE_AFFINITY=none
CLIENT_MACHINE_TYPE=n2-standard-96
SERVER_MACHINE_TYPE=n2-standard-96
CLIENT_AVAILABILITY_ZONE=europe-west3-a
SERVER_AVAILABILITY_ZONE=us-central1-a
SERVER_REGION=us-central1
PLACEMENT_MODE=cross-region
ENABLE_TIER1_NETWORKING=true