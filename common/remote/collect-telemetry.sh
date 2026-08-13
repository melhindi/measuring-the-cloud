#!/usr/bin/env bash
# Sample system counters alongside a benchmark repetition.
#
# Every benchmark node already installs sysstat and has never used it. Without
# these samples a slow repetition is uninterpretable: "the network was slow" and
# "the receiver was behind" and "the CPU was stolen" all look identical in a
# latency percentile. In particular ss -tinH receive-queue depth is what
# separates a transport problem from an application-side backlog, and mpstat's
# %steal is what separates a real result from a noisy neighbour.
#
# The samplers are pinned away from the benchmark. Waking four processes a
# second on the core running a microsecond-scale latency measurement puts
# scheduler jitter directly into the tail percentiles the telemetry exists to
# explain -- the instrument would be creating the artefact it is meant to
# diagnose. remote_cpu_list() in run_benchmarks.sh pins benchmarks to CPUs
# 1..n-1 precisely so CPU 0 is free for this; the default here is the other half
# of that contract and the two must stay in agreement.
set -uo pipefail

ACTION=""
OUT_DIR=""
PID_FILE=""
INTERVAL=1
# Overridable, but 0 is the only value that holds the contract above on a
# machine whose benchmarks use every other core.
CPU_LIST="0"

usage() {
  cat >&2 <<USAGE
usage: $0 --action start|stop --out-dir PATH --pid-file PATH [--interval SEC] [--cpu-list LIST]
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --action) ACTION="$2"; shift 2 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    --pid-file) PID_FILE="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --cpu-list) CPU_LIST="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

# Absent taskset, or with pinning explicitly disabled, samplers run unrestricted
# rather than not at all -- degraded telemetry beats none, and the run is still
# valid, just noisier.
pin=()
if [[ -n "$CPU_LIST" ]] && command -v taskset >/dev/null 2>&1; then
  pin=(taskset -c "$CPU_LIST")
fi

[[ -n "$ACTION" && -n "$PID_FILE" ]] || { usage; exit 1; }

case "$ACTION" in
  start)
    [[ -n "$OUT_DIR" ]] || { usage; exit 1; }
    mkdir -p "$OUT_DIR" "$(dirname "$PID_FILE")"

    # Each sampler is independent and best-effort: a node missing one tool still
    # produces the others rather than losing all telemetry.
    # mpstat still reports -P ALL: it is pinned to CPU 0 but observes every core,
    # so per-core %steal and softirq remain visible for the benchmark cores.
    if command -v mpstat >/dev/null 2>&1; then
      setsid ${pin[@]+"${pin[@]}"} mpstat -P ALL "$INTERVAL" >"${OUT_DIR}/mpstat.log" 2>&1 &
      printf '%s\n' "$!" >>"$PID_FILE"
    fi
    if command -v iostat >/dev/null 2>&1; then
      setsid ${pin[@]+"${pin[@]}"} iostat -x -t "$INTERVAL" >"${OUT_DIR}/iostat.log" 2>&1 &
      printf '%s\n' "$!" >>"$PID_FILE"
    fi

    # nstat and ss have no repeating mode that records a timestamped series the
    # way mpstat does, so drive them from a loop.
    setsid ${pin[@]+"${pin[@]}"} bash -c '
      out="$1"; interval="$2"
      while :; do
        ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        if command -v ss >/dev/null 2>&1; then
          printf "# %s\n" "$ts" >>"${out}/ss.log"
          ss -tinH >>"${out}/ss.log" 2>/dev/null
        fi
        if command -v nstat >/dev/null 2>&1; then
          printf "# %s\n" "$ts" >>"${out}/nstat.log"
          nstat -az >>"${out}/nstat.log" 2>/dev/null
        fi
        sleep "$interval"
      done
    ' _ "$OUT_DIR" "$INTERVAL" >/dev/null 2>&1 &
    printf '%s\n' "$!" >>"$PID_FILE"
    ;;

  stop)
    [[ -f "$PID_FILE" ]] || exit 0
    while read -r pid; do
      [[ -n "$pid" ]] || continue
      # Negative pid targets the whole process group, since setsid made each
      # sampler its own leader and the loop has a sleep child.
      kill -TERM "-${pid}" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
    done <"$PID_FILE"
    rm -f "$PID_FILE"
    ;;

  *)
    usage
    exit 1
    ;;
esac

exit 0
