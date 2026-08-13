#!/usr/bin/env bash

# shellcheck disable=SC1091
source network/scripts/benchmark_defaults.sh

BENCHMARK_NAME=sockperf-ul-udp-64b-1kmps-quick
BENCHMARK_TOOL=sockperf
SKIP=0

SOCKPERF_PROTOCOL=udp
SOCKPERF_MODE=ul
SOCKPERF_MSG_SIZE=64
SOCKPERF_MPS=1000
SOCKPERF_RUNTIME_SEC=10
REPETITIONS=1
COOLDOWN_SEC=2
