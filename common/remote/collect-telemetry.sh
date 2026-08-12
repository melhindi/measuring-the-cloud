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
# Off by default. One sample per second for the duration of a repetition is a
# few kilobytes and negligible load, but it is still load, so scenarios opt in.
set -uo pipefail

ACTION=""
OUT_DIR=""
PID_FILE=""
INTERVAL=1

usage() {
  cat >&2 <<USAGE
usage: $0 --action start|stop --out-dir PATH --pid-file PATH [--interval SEC]
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --action) ACTION="$2"; shift 2 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    --pid-file) PID_FILE="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

[[ -n "$ACTION" && -n "$PID_FILE" ]] || { usage; exit 1; }

case "$ACTION" in
  start)
    [[ -n "$OUT_DIR" ]] || { usage; exit 1; }
    mkdir -p "$OUT_DIR" "$(dirname "$PID_FILE")"

    # Each sampler is independent and best-effort: a node missing one tool still
    # produces the others rather than losing all telemetry.
    if command -v mpstat >/dev/null 2>&1; then
      setsid mpstat -P ALL "$INTERVAL" >"${OUT_DIR}/mpstat.log" 2>&1 &
      printf '%s\n' "$!" >>"$PID_FILE"
    fi
    if command -v iostat >/dev/null 2>&1; then
      setsid iostat -x -t "$INTERVAL" >"${OUT_DIR}/iostat.log" 2>&1 &
      printf '%s\n' "$!" >>"$PID_FILE"
    fi

    # nstat and ss have no repeating mode that records a timestamped series the
    # way mpstat does, so drive them from a loop.
    setsid bash -c '
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
