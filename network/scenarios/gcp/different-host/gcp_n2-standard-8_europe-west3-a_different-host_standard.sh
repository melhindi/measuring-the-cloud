#!/usr/bin/env bash
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/../common.inc"

SCENARIO_NAME=gcp_n2-standard-8_europe-west3-a_different-host_standard
OS_TUNING=standard
INSTANCE_AFFINITY=different-host
CLIENT_MACHINE_TYPE=n2-standard-8
SERVER_MACHINE_TYPE=n2-standard-8
CLIENT_AVAILABILITY_ZONE=europe-west3-a
SERVER_AVAILABILITY_ZONE=europe-west3-a
PLACEMENT_MODE=single-az