#!/usr/bin/env bash
# Cross-region: europe-west3-a to us-central1-a.
#
# Intercontinental, so the longest arm in the study -- longer than the AWS
# us-east-1 to us-west-2 leg. The two are not interchangeable as "cross-region"
# and should be read as separate points, not pooled: distance is the variable
# they differ in, and it differs by roughly a factor of two.
#
# GCP images are global, so unlike AWS no separate server image is needed.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.inc"

SCENARIO_NAME=gcp_n2-standard-2_europe-west3-a_us-central1-a_none_standard_ladder
OS_TUNING=standard
INSTANCE_AFFINITY=none
CLIENT_MACHINE_TYPE=n2-standard-2
SERVER_MACHINE_TYPE=n2-standard-2
CLIENT_AVAILABILITY_ZONE=europe-west3-a
SERVER_AVAILABILITY_ZONE=us-central1-a
SERVER_REGION=us-central1
PLACEMENT_MODE=cross-region
CPU_IDLE_PINNING=1
