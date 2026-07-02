#!/usr/bin/env bash
set -euo pipefail

MOUNT_POINT=""
DEVICE=""
OUT_DIR=""
NAME="fio-benchmark"
IOENGINE="io_uring"
RW="randread"
BS="4k"
IODEPTH="32"
NUMJOBS="1"
RUNTIME_SEC="60"
DIRECT="1"
GROUP_REPORTING="1"
TIME_BASED="1"
SIZE=""
CPU_LIST=""
FSYNC="0"
FDATASYNC="0"

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
usage: $0 (--mount-point PATH | --device PATH) --out-dir PATH [--name NAME] [--ioengine NAME] [--rw MODE] [--bs SIZE] [--iodepth N] [--numjobs N] [--runtime-sec N] [--direct 0|1] [--group-reporting 0|1] [--time-based 0|1] [--size SIZE] [--cpu-list LIST] [--fsync N] [--fdatasync N]
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mount-point) MOUNT_POINT="$2"; shift 2 ;;
    --device) DEVICE="$2"; shift 2 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    --ioengine) IOENGINE="$2"; shift 2 ;;
    --rw) RW="$2"; shift 2 ;;
    --bs) BS="$2"; shift 2 ;;
    --iodepth) IODEPTH="$2"; shift 2 ;;
    --numjobs) NUMJOBS="$2"; shift 2 ;;
    --runtime-sec) RUNTIME_SEC="$2"; shift 2 ;;
    --direct) DIRECT="$2"; shift 2 ;;
    --group-reporting) GROUP_REPORTING="$2"; shift 2 ;;
    --time-based) TIME_BASED="$2"; shift 2 ;;
    --size) SIZE="$2"; shift 2 ;;
    --cpu-list) CPU_LIST="$2"; shift 2 ;;
    --fsync) FSYNC="$2"; shift 2 ;;
    --fdatasync) FDATASYNC="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -n "$MOUNT_POINT" && -n "$DEVICE" ]]; then
  usage
  exit 1
fi
if [[ -z "$MOUNT_POINT" && -z "$DEVICE" ]]; then
  usage
  exit 1
fi
[[ -n "$OUT_DIR" ]] || { usage; exit 1; }
[[ "$FSYNC" =~ ^[0-9]+$ ]] || { echo "--fsync must be an integer" >&2; exit 1; }
[[ "$FDATASYNC" =~ ^[0-9]+$ ]] || { echo "--fdatasync must be an integer" >&2; exit 1; }
if [[ "$FSYNC" != "0" && "$FDATASYNC" != "0" ]]; then
  echo "--fsync and --fdatasync cannot both be non-zero" >&2
  exit 1
fi
command -v fio >/dev/null 2>&1 || { echo "fio not found" >&2; exit 1; }
command -v taskset >/dev/null 2>&1 || { echo "taskset not found" >&2; exit 1; }
CPU_LIST="${CPU_LIST:-$(default_cpu_list)}"

mkdir -p "$OUT_DIR"

cmd=(taskset -c "$CPU_LIST" fio --name="$NAME" --ioengine="$IOENGINE" --rw="$RW" --bs="$BS" --iodepth="$IODEPTH" --numjobs="$NUMJOBS" --runtime="$RUNTIME_SEC" --direct="$DIRECT" --group_reporting="$GROUP_REPORTING" --time_based="$TIME_BASED" --output-format=json --output="${OUT_DIR}/fio.json" --eta=never)
if [[ -n "$DEVICE" ]]; then
  cmd+=(--filename="$DEVICE")
else
  cmd+=(--directory="$MOUNT_POINT")
fi
if [[ -n "$SIZE" ]]; then
  cmd+=(--size "$SIZE")
fi
if [[ "$FSYNC" != "0" ]]; then
  cmd+=(--fsync="$FSYNC")
fi
if [[ "$FDATASYNC" != "0" ]]; then
  cmd+=(--fdatasync="$FDATASYNC")
fi

printf '%q' "${cmd[0]}" >"${OUT_DIR}/fio.cmd"
for arg in "${cmd[@]:1}"; do
  printf ' %q' "$arg" >>"${OUT_DIR}/fio.cmd"
done
printf '\n' >>"${OUT_DIR}/fio.cmd"

"${cmd[@]}" >"${OUT_DIR}/fio.log" 2>&1
