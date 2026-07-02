#!/usr/bin/env bash

# Shared defaults for storage benchmark files.
# Benchmark files source this fragment and then override the values they need.

: "${BENCHMARK_TOOL:=fio}"
: "${REPETITIONS:=3}"
: "${COOLDOWN_SEC:=5}"
: "${FIO_IOENGINE:=io_uring}"
: "${FIO_RW:=randread}"
: "${FIO_BS:=4k}"
: "${FIO_IODEPTH:=32}"
: "${FIO_NUMJOBS:=1}"
: "${FIO_RUNTIME_SEC:=60}"
: "${FIO_DIRECT:=1}"
: "${FIO_GROUP_REPORTING:=1}"
: "${FIO_TIME_BASED:=1}"
: "${FIO_SIZE:=1G}"
: "${FIO_FSYNC:=0}"
: "${FIO_FDATASYNC:=0}"
