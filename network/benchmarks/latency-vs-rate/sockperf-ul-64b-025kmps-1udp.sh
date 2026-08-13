#!/usr/bin/env bash

# shellcheck disable=SC1091
source network/scripts/benchmark_defaults.sh

BENCHMARK_NAME=sockperf-ul-64b-025kmps-udp
BENCHMARK_TOOL=sockperf
SKIP=0

SOCKPERF_PROTOCOL=udp
SOCKPERF_MODE=ul
SOCKPERF_MSG_SIZE=64
SOCKPERF_MPS=25000
