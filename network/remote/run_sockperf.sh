#!/usr/bin/env bash
set -euo pipefail

ROLE=""
PROTOCOL="udp"
MODE="pp"
SERVER_IP=""
PORT="11111"
MSG_SIZE="64"
RUNTIME_SEC="10"
OUT_DIR=""
CPU_LIST=""
SOCKPERF_NOFILE_LIMIT="${SOCKPERF_NOFILE_LIMIT:-32768}"
# under-load only. sockperf's own defaults are mps=10000 and reply-every=100;
# reply-every=1 is used here instead so round-trip time is measured on every
# message rather than sampled on one in a hundred.
MPS=""
BURST="1"
REPLY_EVERY="1"
FULL_LOG="0"

default_cpu_list() {
  local n
  n="$(nproc 2>/dev/null || echo 1)"
  if [[ "$n" =~ ^[0-9]+$ && "$n" -ge 2 ]]; then
    echo "1-$((n - 1))"
  else
    echo "0"
  fi
}

usage() {
  cat >&2 <<USAGE
usage: $0 --role server|client [--protocol tcp|udp] [--mode pp] [--server-ip IP] [--port N] [--msg-size N] [--runtime-sec N] [--out-dir PATH] [--cpu-list LIST]
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --role) ROLE="$2"; shift 2 ;;
    --protocol) PROTOCOL="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    --server-ip) SERVER_IP="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --msg-size) MSG_SIZE="$2"; shift 2 ;;
    --runtime-sec) RUNTIME_SEC="$2"; shift 2 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    --cpu-list) CPU_LIST="$2"; shift 2 ;;
    --mps) MPS="$2"; shift 2 ;;
    --burst) BURST="$2"; shift 2 ;;
    --reply-every) REPLY_EVERY="$2"; shift 2 ;;
    --full-log) FULL_LOG="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

[[ "$ROLE" == "server" || "$ROLE" == "client" ]] || { usage; exit 1; }
[[ "$PROTOCOL" == "tcp" || "$PROTOCOL" == "udp" ]] || { echo "--protocol must be tcp or udp" >&2; exit 1; }
case "$MODE" in
  pp|ul) ;;
  *) echo "--mode must be pp (ping-pong) or ul (under-load)" >&2; exit 1 ;;
esac
if [[ "$MODE" == "ul" && -n "$MPS" && ! "$MPS" =~ ^([0-9]+|max)$ ]]; then
  echo "--mps must be a positive integer or 'max'" >&2
  exit 1
fi
command -v sockperf >/dev/null 2>&1 || { echo "sockperf not found" >&2; exit 1; }
command -v taskset >/dev/null 2>&1 || { echo "taskset not found" >&2; exit 1; }
CPU_LIST="${CPU_LIST:-$(default_cpu_list)}"

cap_sockperf_nofile() {
  if [[ -n "$SOCKPERF_NOFILE_LIMIT" && "$SOCKPERF_NOFILE_LIMIT" =~ ^[0-9]+$ ]]; then
    ulimit -Hn "$SOCKPERF_NOFILE_LIMIT" 2>/dev/null || true
    ulimit -Sn "$SOCKPERF_NOFILE_LIMIT" 2>/dev/null || true
  fi
}

proto_args=()
if [[ "$PROTOCOL" == "tcp" ]]; then
  proto_args+=(--tcp)
fi

if [[ "$ROLE" == "server" ]]; then
  cap_sockperf_nofile
  exec taskset -c "$CPU_LIST" sockperf server "${proto_args[@]}" --ip 0.0.0.0 --port "$PORT"
fi

[[ -n "$SERVER_IP" ]] || { echo "--server-ip is required for client role" >&2; exit 1; }
[[ -n "$OUT_DIR" ]] || { echo "--out-dir is required for client role" >&2; exit 1; }
mkdir -p "$OUT_DIR"

if [[ "$MODE" == "ul" ]]; then
  # under-load: the client emits at a controlled offered rate instead of waiting
  # for each reply, so latency can be read as a function of load rather than
  # only at the idle operating point ping-pong measures.
  cmd=(taskset -c "$CPU_LIST" sockperf under-load "${proto_args[@]}" --ip "$SERVER_IP" --port "$PORT" --msg-size "$MSG_SIZE" --time "$RUNTIME_SEC" --burst "$BURST" --reply-every "$REPLY_EVERY" --full-rtt)
  [[ -n "$MPS" ]] && cmd+=(--mps "$MPS")
  [[ "$FULL_LOG" == "1" ]] && cmd+=(--full-log "${OUT_DIR}/sockperf-full.csv")
else
  cmd=(taskset -c "$CPU_LIST" sockperf pp "${proto_args[@]}" --ip "$SERVER_IP" --port "$PORT" --msg-size "$MSG_SIZE" --time "$RUNTIME_SEC" --full-rtt)
fi

printf '%q' "${cmd[0]}" >"${OUT_DIR}/client.cmd"
for arg in "${cmd[@]:1}"; do
  printf ' %q' "$arg" >>"${OUT_DIR}/client.cmd"
done
printf '\n' >>"${OUT_DIR}/client.cmd"

set +e
cap_sockperf_nofile
"${cmd[@]}" >"${OUT_DIR}/sockperf.log" 2>&1
rc=$?
set -e
exit "$rc"
