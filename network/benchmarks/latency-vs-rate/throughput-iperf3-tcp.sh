#!/usr/bin/env bash
# Capacity reference for the latency ladder.
#
# The ladder measures round-trip latency at controlled message rates; it says
# nothing about how much bandwidth was available while it did so. Without that,
# "the latency rose at 100k messages/s" leaves a reader unable to tell a
# packet-rate or endpoint limit from a saturated link -- a distinction the whole
# interpretation rests on. This arm turns that from an inference into a
# measurement.
#
# For scale: the top ladder rung is 100k msg/s x 64 B in both directions, about
# 102 Mbit/s. Historical iperf3 runs in this repository show 10-12 Gbit/s on
# comparable pairs, so the ladder is expected to use roughly 1% of capacity and
# every limit it finds should be packet-rate or endpoint bound. This arm is what
# lets that be checked per scenario rather than assumed from other runs.
#
# Deliberately runs LAST. The file name is the run order (see README.md), and
# "throughput-" sorts after every "sockperf-" arm. A 10 Gbit/s transfer leaves
# queues, congestion windows and interrupt-coalescing state quite unlike an idle
# link, so running it first would contaminate the latency arms that are the
# primary measurement. Last, it can only contaminate the teardown.
#
# TCP only, and one stream. One stream because the ladder uses one connection,
# so single-connection throughput is the envelope the ladder actually lived in;
# aggregate NIC capacity would be a different and less relevant number. TCP only
# because iperf3's UDP loss figures cannot separate network loss from receiver
# drops -- in this repository's own historical data, co-located pairs report
# 16-59% "loss" on the shortest possible path, which is the receiver failing to
# drain, not the network. Loss attribution belongs to nstat, not to this arm.
source network/scripts/benchmark_defaults.sh

BENCHMARK_NAME=iperf3-tcp-capacity
BENCHMARK_TOOL=iperf3
SKIP=0

IPERF3_PROTOCOL=tcp
IPERF3_PARALLEL=1
# 15 s with the first 3 s omitted leaves 12 s of steady-state, enough for a
# stable median and for the per-second interval series the analysis uses to
# report throughput variance. Three repetitions add between-run spread on top.
IPERF3_RUNTIME_SEC=15
IPERF3_OMIT_SEC=3
