#!/usr/bin/env bash
# Cross-region: us-east1-b to us-west1-a.
#
# Sourced from us-east1 like the intra- and inter-zone arms. It previously
# started in us-east4-c, because us-east4 was chosen to metro-match AWS
# us-east-1 (Ashburn) and only its -c zone had capacity for n2-standard-2.
# That left GCP's own placement axis spanning two source regions, so
# intra -> inter -> cross-region mixed a placement change with a region
# change. Moncks Corner to Oregon is ~3,800 km against Ashburn to Oregon's
# ~3,900 km, so the ~2% of distance given up is far below the effects being
# measured and buys an internally consistent axis.
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

SCENARIO_NAME=gcp_n2-standard-2_us-east1-b_us-west1-a_none_standard_ladder
OS_TUNING=standard
INSTANCE_AFFINITY=none
CLIENT_MACHINE_TYPE=n2-standard-2
SERVER_MACHINE_TYPE=n2-standard-2
CLIENT_REGION=us-east1
CLIENT_AVAILABILITY_ZONE=us-east1-b
SERVER_AVAILABILITY_ZONE=us-west1-a
SERVER_REGION=us-west1
PLACEMENT_MODE=cross-region
CPU_IDLE_PINNING=1
