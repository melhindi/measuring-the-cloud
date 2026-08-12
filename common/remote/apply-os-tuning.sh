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

usage() {
  cat >&2 <<USAGE
usage: $0 [standard|network-throughput|tuned] [--facts-out PATH]
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
  } >"$FACTS_OUT"
  chmod 0644 "$FACTS_OUT" 2>/dev/null || true
fi

log "profile ${PROFILE} complete"
