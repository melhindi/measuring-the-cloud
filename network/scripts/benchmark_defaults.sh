#!/usr/bin/env bash

# Shared defaults for network benchmark files.
# Benchmark files source this fragment and then override the values they need,
# mirroring storage/scripts/benchmark_defaults.sh.
#
# The point is that a rate ladder differs only in its rung: everything a ladder
# file has to state is the offered rate, so an accidental difference in message
# size or runtime between rungs cannot creep in.

: "${SKIP:=0}"
: "${REPETITIONS:=3}"
: "${COOLDOWN_SEC:=5}"
: "${SERVER_READY_TIMEOUT_SEC:=30}"

# iperf3
: "${IPERF3_PORT:=5201}"
: "${IPERF3_PROTOCOL:=tcp}"
: "${IPERF3_RUNTIME_SEC:=30}"
: "${IPERF3_OMIT_SEC:=3}"
: "${IPERF3_PARALLEL:=1}"
: "${IPERF3_TCP_LENGTH:=128K}"

# sockperf
: "${SOCKPERF_PORT:=11111}"
: "${SOCKPERF_PROTOCOL:=udp}"
: "${SOCKPERF_MODE:=pp}"
: "${SOCKPERF_MSG_SIZE:=64}"
: "${SOCKPERF_RUNTIME_SEC:=30}"

# sockperf under-load only. reply-every=1 measures round-trip time on every
# message rather than sockperf's default of one in a hundred.
: "${SOCKPERF_BURST:=1}"
: "${SOCKPERF_REPLY_EVERY:=1}"
: "${SOCKPERF_FULL_LOG:=0}"
