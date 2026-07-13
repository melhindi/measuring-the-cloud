#!/usr/bin/env bash
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/../common.inc"

SCENARIO_NAME=gcp_n2-standard-8_europe-west3-a_co-located_tuned
OS_TUNING=network-throughput
INSTANCE_AFFINITY=co-located
CLIENT_MACHINE_TYPE=n2-standard-8
SERVER_MACHINE_TYPE=n2-standard-8
CLIENT_AVAILABILITY_ZONE=europe-west3-a
SERVER_AVAILABILITY_ZONE=europe-west3-a
PLACEMENT_MODE=single-az