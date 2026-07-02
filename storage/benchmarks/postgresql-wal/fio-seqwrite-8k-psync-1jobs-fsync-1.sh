#!/usr/bin/env bash

# shellcheck disable=SC1091
source storage/scripts/benchmark_defaults.sh

BENCHMARK_NAME=fio-seqwrite-8k-psync-1jobs-fsync-1
BENCHMARK_TOOL=fio
SKIP=0

FIO_IOENGINE=psync
FIO_RW=write
FIO_BS=8k
FIO_IODEPTH=1
FIO_NUMJOBS=1
FIO_RUNTIME_SEC=60
FIO_DIRECT=1
FIO_GROUP_REPORTING=1
FIO_TIME_BASED=1
FIO_SIZE=2G
FIO_FSYNC=1
REPETITIONS=2
COOLDOWN_SEC=5
