#!/usr/bin/env bash
# Cross-region: us-east4-a to us-west1-a.
#
# Deliberately the same physical corridor as the AWS cross-region scenario.
# us-east4 is Ashburn, Northern Virginia and us-west1 is The Dalles, Oregon --
# the same two metros as AWS us-east-1 and us-west-2. The two providers'
# cross-region arms therefore differ in provider and network fabric but not in
# distance, which is the only way "GCP's cross-region latency vs AWS's" is a
# statement about the providers rather than about geography.
#
# This replaced an earlier europe-west3 to us-central1 pairing, which was
# intercontinental and roughly twice the distance of the AWS leg -- comparing
# the two would have attributed a distance difference to the provider.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.inc"

SCENARIO_NAME=gcp_n2-standard-2_us-east4-a_us-west1-a_none_standard_ladder
OS_TUNING=standard
INSTANCE_AFFINITY=none
CLIENT_MACHINE_TYPE=n2-standard-2
SERVER_MACHINE_TYPE=n2-standard-2
CLIENT_REGION=us-east4
CLIENT_AVAILABILITY_ZONE=us-east4-a
SERVER_AVAILABILITY_ZONE=us-west1-a
SERVER_REGION=us-west1
PLACEMENT_MODE=cross-region
CPU_IDLE_PINNING=1
