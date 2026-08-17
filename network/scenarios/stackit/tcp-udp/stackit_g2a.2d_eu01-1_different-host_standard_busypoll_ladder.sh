#!/usr/bin/env bash
# Intra-AZ with busy polling: the paired arm to
# stackit_g2a.2d_eu01-1_different-host_standard_ladder.
#
# Everything is held identical to that scenario except BUSY_POLL, for the same
# reason the tuned arm holds everything except OS_TUNING.
#
# What this is testing. STACKIT showed a packet-rate ceiling around 60k
# packets/s that AWS and GCP did not: asking iperf3 for 5 Gbit/s of UDP instead
# of 1 delivered the same packet rate, 62,733 -> 60,413 pps. The explanation
# offered for that difference was that AWS and GCP keep NAPI in polling mode
# under load while STACKIT pays an interrupt per packet -- but that was an
# inference from the shape of the curve, never a measurement, and the one
# profile that would bear on it was never run. The receive path is configurable
# on any Linux guest, so "the provider does not poll" is not something the data
# so far can distinguish from "we never asked it to".
#
# The evidence that made this worth testing is softirq time on the benchmark
# core at 100k msg/s intra-AZ, from mpstat telemetry already on disk:
#
#   GCP      0.0% softirq, 45.3% idle
#   AWS      6.3% softirq, 12.9% idle
#   STACKIT 11.5% softirq, 18.7% idle
#
# STACKIT spends the most CPU in softirq of the three while still having idle
# time, which is the signature of interrupt-driven receive with headroom left.
# busy_poll spends that headroom deliberately: the socket spins inside the
# syscall waiting for the driver instead of sleeping and being woken by the
# softirq, trading CPU for the wakeup.
#
# Why standard and not network-throughput. network-throughput was already run
# here and did not lift the ceiling -- UDP at 1G went 62,733 -> 54,055 pps, at
# 5G 60,413 -> 56,482, slightly worse both times. It also changes six things at
# once, so a knob folded into it could not be attributed. Crossing busy_poll
# with the standard baseline makes this a one-variable comparison against a run
# that already exists.
#
# What "no effect" would mean. busy_poll needs driver support to do anything,
# and on a virtio NIC it may be accepted by sysctl and still change nothing.
# That is a real answer, not a failed run: it would say the ceiling is not the
# guest's to move, which is the more useful finding of the two. Read it from
# the softnet_stat time_squeeze counter and mpstat softirq, not from the sysctl
# read-back -- the read-back only proves the value was set.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.inc"

SCENARIO_NAME=stackit_g2a.2d_eu01-1_different-host_standard_busypoll_ladder
OS_TUNING=standard
BUSY_POLL=1
INSTANCE_AFFINITY=different-host
CLIENT_MACHINE_TYPE=g2a.2d
SERVER_MACHINE_TYPE=g2a.2d
CLIENT_AVAILABILITY_ZONE=eu01-1
SERVER_AVAILABILITY_ZONE=eu01-1
PLACEMENT_MODE=single-az
CPU_IDLE_PINNING=1
