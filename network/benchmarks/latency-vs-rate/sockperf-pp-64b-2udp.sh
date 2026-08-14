#!/usr/bin/env bash
# Ping-pong, UDP. See sockperf-pp-64b-1tcp.sh for why this pair exists.
#
# The UDP half matters on its own: at one message in flight there is nothing for
# TCP's control loop to do -- no window to fill, no queue to build, and a loss
# would stall the single outstanding message rather than trigger the fast
# recovery that shows up under load. So this is the operating point where the
# two transports should be closest, and the study's earlier ping-pong data
# agreed, differing by roughly 8%.
#
# That near-equality is the baseline the ladder is measured against. TCP and UDP
# move a packet the same way; every difference the ladder finds at higher rates
# comes from TCP's control loop engaging, and this arm is the control that shows
# what the two look like when it does not.
source network/scripts/benchmark_defaults.sh

BENCHMARK_NAME=sockperf-pp-64b-udp
BENCHMARK_TOOL=sockperf

SOCKPERF_PROTOCOL=udp
SOCKPERF_MODE=pp
SOCKPERF_MSG_SIZE=64
