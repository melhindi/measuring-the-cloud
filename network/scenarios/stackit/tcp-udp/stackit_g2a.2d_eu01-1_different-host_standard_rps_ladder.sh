#!/usr/bin/env bash
# Intra-AZ with receive processing steered off the benchmark core: the third
# paired arm to stackit_g2a.2d_eu01-1_different-host_standard_ladder.
#
# Everything is held identical to that scenario except RPS_CPUS.
#
# The same softirq measurement that motivates the busy_poll arm motivates this
# one, read the other way round. At 100k msg/s intra-AZ the benchmark core on
# STACKIT spends 11.5% of its time in softirq -- against 6.3% on AWS and 0.0%
# on GCP -- while the benchmark process is pinned to that same core. Receive
# processing and the latency measurement are competing for one CPU, and every
# microsecond softirq holds it is a microsecond in the tail percentile.
#
# busy_poll answers "stop taking interrupts". This answers "take them
# somewhere else". They are separate arms rather than one combined profile
# because network-throughput already demonstrated what happens when six changes
# ship together: it moved numbers and nothing could say which change did it.
#
# The mask. remote_cpu_list() pins benchmarks to CPUs 1..n-1 and leaves CPU 0
# for the telemetry samplers, so on a 2-vCPU g2a.2d the benchmark owns CPU 1 and
# the only core receive work can move to is CPU 0. RPS_CPUS=1 is bit 0, meaning
# CPU 0. That is the whole available range on this instance type, not a tuned
# choice.
#
# Two things to hold in mind when reading the result.
#
# RPS moves, it does not spread. The CPU is chosen by flow hash, and a sockperf
# run is a single flow, so every packet lands on the same core. On a machine
# with more cores this mask would still send all of one run's traffic to one
# CPU; nothing here is load balancing.
#
# CPU 0 is not idle. It is where collect-telemetry.sh runs its samplers, so
# this arm puts receive softirq alongside them. They wake a few times a second
# against a receive path handling tens of thousands of packets, so the
# interference is small -- but it is not zero, and it is the price of the only
# free core on a 2-vCPU instance. If this arm shows an effect worth pursuing,
# the follow-up belongs on an instance type with a core to spare.
#
# Confirm from rps_cpus_effective, not RPS_CPUS. The kernel normalises the mask
# and a write to a single-queue virtio NIC can succeed while steering nothing,
# so the requested and effective masks are recorded as separate columns. The
# softnet_stat received_rps counter is the direct evidence that packets actually
# crossed to another CPU.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.inc"

SCENARIO_NAME=stackit_g2a.2d_eu01-1_different-host_standard_rps_ladder
OS_TUNING=standard
RPS_CPUS=1
INSTANCE_AFFINITY=different-host
CLIENT_MACHINE_TYPE=g2a.2d
SERVER_MACHINE_TYPE=g2a.2d
CLIENT_AVAILABILITY_ZONE=eu01-1
SERVER_AVAILABILITY_ZONE=eu01-1
PLACEMENT_MODE=single-az
CPU_IDLE_PINNING=1
