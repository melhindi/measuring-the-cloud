#!/usr/bin/env bash
# Intra-AZ with network-throughput tuning: the paired arm to
# stackit_g2a.2d_eu01-1_different-host_standard_ladder.
#
# Everything is held identical to that scenario except OS_TUNING, because the
# standard run produced a result that may belong to a sysctl rather than to a
# transport. It lost 7.3% of UDP messages at 100k mps and 1.2% at 50k, and
# nstat attributed every one of them to UdpRcvbufErrors -- socket receive buffer
# overflow on the endpoints, with IpInDiscards at zero, so nothing was lost in
# the network. The buffer that overflowed was the kernel default:
# net.core.rmem_max = 212992, about 208 KB, which at 100k mps and 64 B messages
# holds roughly 33 ms of traffic.
#
# network-throughput sets rmem_max to 134217728 -- 128 MB, some 630x larger --
# plus udp_rmem_min and a deeper netdev backlog. If the loss disappears here,
# "UDP drops under load" was a statement about a default, not about UDP.
#
# The outcome is interesting either way, and not necessarily an improvement: a
# larger buffer converts loss into queueing delay, so UDP p99 may get worse as
# its loss goes to zero. That trade is the finding, whichever way it lands.
#
# Repetitions stay at the default 3 to keep the design matched with the standard
# arm, even though STACKIT bills by the hour and this scenario leaves most of a
# paid hour unused.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.inc"

SCENARIO_NAME=stackit_g2a.2d_eu01-1_different-host_tuned_ladder
OS_TUNING=network-throughput
INSTANCE_AFFINITY=different-host
CLIENT_MACHINE_TYPE=g2a.2d
SERVER_MACHINE_TYPE=g2a.2d
CLIENT_AVAILABILITY_ZONE=eu01-1
SERVER_AVAILABILITY_ZONE=eu01-1
PLACEMENT_MODE=single-az
CPU_IDLE_PINNING=1
