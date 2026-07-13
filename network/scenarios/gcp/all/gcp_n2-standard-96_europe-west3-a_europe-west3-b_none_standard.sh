#!/usr/bin/env bash
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/../common.inc"

SCENARIO_NAME=gcp_n2-standard-96_europe-west3-a_europe-west3-b_different-host_standard
OS_TUNING=standard
INSTANCE_AFFINITY=none
CLIENT_MACHINE_TYPE=n2-standard-96
SERVER_MACHINE_TYPE=n2-standard-96
CLIENT_AVAILABILITY_ZONE=europe-west3-a
SERVER_AVAILABILITY_ZONE=europe-west3-b
PLACEMENT_MODE=multi-az
ENABLE_TIER1_NETWORKING=true