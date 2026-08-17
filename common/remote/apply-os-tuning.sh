#!/usr/bin/env bash
# The single definition of every OS tuning profile, for all providers and both
# workloads.
#
# This used to be embedded as a heredoc inside five Terraform user_data
# templates. They drifted: the GCP network template applied 5 sysctls where AWS
# and STACKIT applied 15 plus NIC tuning, so os_tuning=network-throughput did not
# mean the same thing on GCP as elsewhere and any cross-provider comparison of
# "tuned" was comparing different interventions. Shipping one file from the repo
# the way run_iperf.sh is shipped removes the opportunity for that to recur.
#
# Profiles, kept under their existing names so no scenario file or recorded
# artifact changes meaning:
#   standard           no tuning beyond the base image
#   network-throughput BBR/fq, larger socket buffers and backlogs, NIC tuning
#   tuned              writeback/dirty-page tuning used by the storage workload
set -euo pipefail

PROFILE="standard"
FACTS_OUT=""
# Orthogonal knobs, not profile members, and that is the point.
#
# network-throughput changes congestion control, qdisc, socket buffers, backlog
# and NIC rings at once, so when it moves a number nothing says which change did
# it -- measured: it cost 28% of TCP throughput on g2a.2d while leaving the UDP
# packet-rate ceiling untouched. These two are the knobs that speak directly to
# interrupt-versus-poll receive behaviour, so they are settable one at a time and
# crossable with any profile, the way CPU_IDLE_PINNING already is.
BUSY_POLL="0"
RPS_CPUS=""

usage() {
  cat >&2 <<USAGE
usage: $0 [standard|network-throughput|tuned] [--facts-out PATH]
          [--busy-poll 0|1] [--rps-cpus HEXMASK]
USAGE
}

if [[ $# -gt 0 && "$1" != --* ]]; then
  PROFILE="$1"
  shift
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2 ;;
    --facts-out) FACTS_OUT="$2"; shift 2 ;;
    --busy-poll) BUSY_POLL="$2"; shift 2 ;;
    --rps-cpus) RPS_CPUS="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

log() {
  echo "[os-tuning][$(date --iso-8601=seconds)] $*"
}

primary_iface() {
  ip route get 1.1.1.1 2>/dev/null | awk '/dev/ {
    for (i = 1; i <= NF; i++) {
      if ($i == "dev") { print $(i + 1); exit }
    }
  }'
}

# Keys applied by this run, in "key=value" form, so the runner can record what
# actually took effect rather than what the scenario asked for.
declare -a APPLIED=()

apply_sysctl() {
  local key="$1"
  local value="$2"
  local before=""
  before="$(sysctl -n "$key" 2>/dev/null || true)"
  log "sysctl ${key}: '${before}' -> '${value}'"
  if sysctl -w "${key}=${value}" >/dev/null 2>&1; then
    local after=""
    after="$(sysctl -n "$key" 2>/dev/null || true)"
    APPLIED+=("${key}=${after}")
  else
    log "sysctl ${key} could not be set"
    APPLIED+=("${key}=UNSET")
  fi
}

apply_best_effort() {
  log "best-effort: $*"
  "$@" || log "best-effort command failed: $*"
}

apply_network_throughput() {
  apply_sysctl net.core.default_qdisc fq
  apply_sysctl net.ipv4.tcp_congestion_control bbr

  apply_sysctl net.core.rmem_max 134217728
  apply_sysctl net.core.wmem_max 134217728
  apply_sysctl net.ipv4.tcp_rmem "4096 87380 67108864"
  apply_sysctl net.ipv4.tcp_wmem "4096 65536 67108864"
  apply_sysctl net.ipv4.udp_rmem_min 16384
  apply_sysctl net.ipv4.udp_wmem_min 16384

  apply_sysctl net.core.somaxconn 32768
  apply_sysctl net.core.netdev_max_backlog 32768
  apply_sysctl net.core.netdev_budget 1000
  apply_sysctl net.core.optmem_max 65535
  apply_sysctl net.ipv4.ip_local_port_range "1024 65535"
  apply_sysctl net.ipv4.tcp_tw_reuse 1
  apply_sysctl net.ipv4.tcp_frto 0

  local iface
  iface="$(primary_iface)"
  if [[ -n "$iface" ]]; then
    log "primary_iface=${iface}"
    if command -v ethtool >/dev/null 2>&1; then
      apply_best_effort ethtool -G "$iface" rx 1024 tx 1024
    fi
    apply_best_effort ip link set "$iface" txqueuelen 10000
  else
    log "primary interface not detected; skipping interface-local tuning"
  fi
}

apply_storage_tuned() {
  apply_sysctl vm.dirty_background_ratio 5
  apply_sysctl vm.dirty_ratio 20
  apply_sysctl vm.swappiness 1
  apply_sysctl vm.vfs_cache_pressure 50
  apply_sysctl vm.dirty_expire_centisecs 3000
  apply_sysctl vm.dirty_writeback_centisecs 500
}

# Receive-path knobs, applied after the profile and independently of it.
#
# Both target the same question -- how much of the receive path is interrupt
# driven versus polled -- from opposite ends, so they are applied separately and
# recorded separately.
#
#   busy_poll/busy_read  the socket spins in the syscall waiting for the driver
#                        instead of sleeping and being woken by the softirq. It
#                        trades CPU for the wakeup, which is the right trade only
#                        when a core is otherwise idle.
#   rps_cpus             moves receive processing to another core, so softirq
#                        work stops competing with the benchmark process for the
#                        core it is pinned to. "Moves", not "spreads": RPS picks
#                        a CPU from the mask by flow hash, and a sockperf run is
#                        one flow, so every packet lands on the same one. The
#                        mask must therefore exclude the benchmark cores or it
#                        changes nothing.
#
# Note what is deliberately absent: net.core.rps_sock_flow_entries. That table
# is RFS, which steers a flow to the CPU its application thread is running on --
# exactly back onto the benchmark core, undoing the reason for setting rps_cpus
# at all. RPS and RFS look like a pair and are opposites for this purpose.
#
# Both are read back below. rps_cpus in particular is normalised by the kernel --
# bits for offline CPUs are dropped, and on a single-queue virtio NIC the write
# may land yet do nothing -- so what was asked for is not evidence of what took.
apply_receive_knobs() {
  if [[ "$BUSY_POLL" == "1" ]]; then
    # 50 us is the conventional starting point: long enough to cover an
    # inter-arrival gap at the rates in this study, short enough that an idle
    # socket is not burning a core.
    apply_sysctl net.core.busy_poll 50
    apply_sysctl net.core.busy_read 50
  fi

  if [[ -n "$RPS_CPUS" ]]; then
    local iface queue applied=0
    iface="$(primary_iface)"
    if [[ -z "$iface" ]]; then
      log "rps_cpus requested but primary interface not detected; skipping"
      APPLIED+=("rps_cpus=NO_IFACE")
      return 0
    fi
    for queue in /sys/class/net/"$iface"/queues/rx-*/rps_cpus; do
      [[ -e "$queue" ]] || continue
      if echo "$RPS_CPUS" >"$queue" 2>/dev/null; then
        applied=$((applied + 1))
      else
        log "could not write ${RPS_CPUS} to ${queue}"
      fi
    done
    if [[ "$applied" -eq 0 ]]; then
      log "rps_cpus requested but no receive queue accepted it"
      APPLIED+=("rps_cpus=UNSET")
    else
      log "rps_cpus=${RPS_CPUS} written to ${applied} receive queue(s) on ${iface}"
      APPLIED+=("rps_cpus=${RPS_CPUS}")
    fi
  fi
}

log "profile=${PROFILE}"
log "kernel=$(uname -r)"

case "$PROFILE" in
  standard)
    log "standard profile selected; no OS tuning applied"
    ;;
  network-throughput)
    apply_network_throughput
    ;;
  tuned)
    apply_storage_tuned
    ;;
  *)
    echo "unknown OS tuning profile: ${PROFILE}" >&2
    exit 1
    ;;
esac

apply_receive_knobs

# Record the read-back values. Drift between what a profile claims and what a
# kernel accepted is only detectable if the applied values reach the dataset.
if [[ -n "$FACTS_OUT" ]]; then
  mkdir -p "$(dirname "$FACTS_OUT")"
  {
    printf 'NODE_OS_TUNING_PROFILE=%s\n' "$PROFILE"
    if [[ "${#APPLIED[@]}" -gt 0 ]]; then
      printf 'NODE_OS_TUNING_APPLIED=%s\n' "$(printf '%s;' "${APPLIED[@]}")"
    fi
    printf 'NODE_OS_TUNING_CONGESTION_CONTROL=%s\n' "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
    printf 'NODE_OS_TUNING_QDISC=%s\n' "$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"
    printf 'NODE_OS_TUNING_RMEM_MAX=%s\n' "$(sysctl -n net.core.rmem_max 2>/dev/null || true)"
    printf 'NODE_OS_TUNING_WMEM_MAX=%s\n' "$(sysctl -n net.core.wmem_max 2>/dev/null || true)"
    printf 'NODE_OS_TUNING_NETDEV_BACKLOG=%s\n' "$(sysctl -n net.core.netdev_max_backlog 2>/dev/null || true)"
    # netdev_budget is how many packets one NAPI poll may drain before yielding.
    # network-throughput raises it 300 -> 1000, which was set but never recorded,
    # so no dataset in this repo can show whether the kernel took the value. Read
    # it back on every profile: knowing standard left it at 300 is what makes the
    # tuned/untuned comparison mean anything.
    printf 'NODE_OS_TUNING_NETDEV_BUDGET=%s\n' "$(sysctl -n net.core.netdev_budget 2>/dev/null || true)"
    printf 'NODE_OS_TUNING_BUSY_POLL=%s\n' "$(sysctl -n net.core.busy_poll 2>/dev/null || true)"
    printf 'NODE_OS_TUNING_BUSY_READ=%s\n' "$(sysctl -n net.core.busy_read 2>/dev/null || true)"
    printf 'NODE_OS_TUNING_RPS_CPUS_REQUESTED=%s\n' "$RPS_CPUS"
    # The effective mask, straight from sysfs, after kernel normalisation.
    printf 'NODE_OS_TUNING_RPS_CPUS_EFFECTIVE=%s\n' "$(
      iface="$(primary_iface)"
      if [[ -n "$iface" ]]; then
        for q in /sys/class/net/"$iface"/queues/rx-*/rps_cpus; do
          [[ -e "$q" ]] || continue
          printf '%s;' "$(tr -d ' \n,' <"$q" 2>/dev/null || true)"
        done
      fi
    )"
  } >"$FACTS_OUT"
  chmod 0644 "$FACTS_OUT" 2>/dev/null || true
fi

log "profile ${PROFILE} complete"
