#!/usr/bin/env bash
# Ping-pong: the closed-loop latency floor, and the ladder's anchor.
#
# One message in flight, the next sent only after the previous reply arrives.
# That makes it self-clocked -- the send rate is 1/RTT, about 7k/s intra-AZ --
# rather than paced to a target like the under-load arms.
#
# It is here for three things the ladder cannot give:
#
#   - A comparable number. Published latency figures are almost always
#     ping-pong, including the ~40 us metal result this work set out to
#     reproduce. Without this arm the study has nothing to compare against.
#   - A controlled measure of coordinated omission. Comparing historical pp
#     against the ladder's 1k rung on STACKIT g2a.2d showed p50 agreeing within
#     8% while p99 differed 5.6x (176 us vs 980 us) -- but those were separate
#     runs weeks apart. Run in the same scenario, on the same instances, within
#     the same hour, the gap becomes a measurement rather than a suggestion.
#   - The idle-state penalty. pp leaves ~140 us between messages, too short for
#     a deep C-state; the 1k rung leaves 1 ms, which is not. pp minus ul-at-1k
#     is therefore the idle-exit cost, and crossing it with CPU_IDLE_PINNING
#     says whether pinning removes it.
#
# Read its percentiles with care. Closed-loop generation under-samples exactly
# when the system is slow: a stall delays the next send instead of being
# recorded, so pp tails understate the tail. That is the whole reason the ladder
# exists and why pp alone cannot answer the study's question -- it is an anchor,
# not a substitute.
#
# Runs first: "pp" sorts before "ul", and it is the lightest load in the
# directory, so it cannot perturb what follows.
source network/scripts/benchmark_defaults.sh

BENCHMARK_NAME=sockperf-pp-64b-tcp
BENCHMARK_TOOL=sockperf

SOCKPERF_PROTOCOL=tcp
SOCKPERF_MODE=pp
SOCKPERF_MSG_SIZE=64
