#!/usr/bin/env bash
# GCP plumbing smoke.
#
# OS_TUNING=network-throughput is the point of this scenario, not an incidental
# choice. GCP's tuning profile was the one that had drifted: its user_data
# template applied 5 sysctls where AWS and STACKIT applied 15 plus NIC tuning,
# so os_tuning=network-throughput did not mean the same thing per provider. The
# template no longer carries a profile at all -- the script is shipped from the
# repository -- and the read-back in os-tuning.env is what proves the full
# profile now applies here. Expect bbr / fq / netdev_max_backlog=32768.
#
# Also first exercise of the GCP branch of collect-node-facts (image,
# machine-type, and preemptible -> purchase_model) and of GCP's idle-state and
# cpufreq exposure, which is unknown.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/../common.inc"

SCENARIO_NAME=gcp_n2-standard-2_europe-west3-a_none_tuned_smoke
BENCHMARK_DIR=network/benchmarks/latency-vs-rate

OS_TUNING=network-throughput
INSTANCE_AFFINITY=none
CLIENT_MACHINE_TYPE=n2-standard-2
SERVER_MACHINE_TYPE=n2-standard-2
CLIENT_AVAILABILITY_ZONE=europe-west3-a
SERVER_AVAILABILITY_ZONE=europe-west3-a
PLACEMENT_MODE=single-az
CPU_IDLE_PINNING=1
