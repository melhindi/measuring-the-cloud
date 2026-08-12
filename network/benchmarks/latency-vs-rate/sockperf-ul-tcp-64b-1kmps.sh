#!/usr/bin/env bash

# shellcheck disable=SC1091
source network/scripts/benchmark_defaults.sh

BENCHMARK_NAME=sockperf-ul-tcp-64b-1kmps
BENCHMARK_TOOL=sockperf
SKIP=0

SOCKPERF_PROTOCOL=tcp
SOCKPERF_MODE=ul
SOCKPERF_MSG_SIZE=64
SOCKPERF_MPS=1000
