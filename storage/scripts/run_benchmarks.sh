#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
source "${REPO_ROOT}/common/scripts/common.sh"

TOFU_DIR=""
SCENARIO_NAME=""
BENCHMARK_DIR=""
RUN_ID=""
OS_TUNING="standard"
LOCAL_LOG_DIR=""
REMOTE_RESULTS_ROOT="/opt/cloud-measuring/results"
ACCESS_MODE="public"
LOCAL_FILESYSTEM=""
BLOCK_FILESYSTEM=""
# Seconds for the per-scenario device calibration probe; 0 disables it.
CALIBRATION_RUNTIME_SEC="20"
CPU_IDLE_PINNING="0"
USE_SPOT="0"
# Repetitions that fail are recorded and skipped rather than aborting the
# scenario; this counts them so the scenario still reports failure at the end.
BENCHMARK_FAILURES=0
declare -a BENCHMARK_NAMES=()

usage() {
  cat >&2 <<USAGE
usage: $0 --tofu-dir PATH --scenario-name NAME --benchmark-dir PATH --run-id ID --local-filesystem ext4|xfs|raw --block-filesystem ext4|xfs|raw [--local-log-dir PATH] [--os-tuning standard|tuned] [--access-mode public|private] [--benchmark NAME]
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tofu-dir) TOFU_DIR="$2"; shift 2 ;;
    --scenario-name) SCENARIO_NAME="$2"; shift 2 ;;
    --benchmark-dir) BENCHMARK_DIR="$2"; shift 2 ;;
    --run-id) RUN_ID="$2"; shift 2 ;;
    --local-log-dir) LOCAL_LOG_DIR="$2"; shift 2 ;;
    --os-tuning) OS_TUNING="$2"; shift 2 ;;
    --access-mode) ACCESS_MODE="$2"; shift 2 ;;
    --local-filesystem) LOCAL_FILESYSTEM="$2"; shift 2 ;;
    --block-filesystem) BLOCK_FILESYSTEM="$2"; shift 2 ;;
    --results-root) REMOTE_RESULTS_ROOT="$2"; shift 2 ;;
    --calibration-runtime-sec) CALIBRATION_RUNTIME_SEC="$2"; shift 2 ;;
    --cpu-idle-pinning) CPU_IDLE_PINNING="$2"; shift 2 ;;
    --use-spot) USE_SPOT="$2"; shift 2 ;;
    --benchmark) BENCHMARK_NAMES+=("$2"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

[[ -n "$TOFU_DIR" ]] || { usage; exit 1; }
[[ -n "$SCENARIO_NAME" ]] || { usage; exit 1; }
[[ -n "$BENCHMARK_DIR" ]] || { usage; exit 1; }
[[ -n "$RUN_ID" ]] || { usage; exit 1; }
[[ -n "$LOCAL_FILESYSTEM" ]] || { usage; exit 1; }
[[ -n "$BLOCK_FILESYSTEM" ]] || { usage; exit 1; }
case "$OS_TUNING" in
  standard|tuned) ;;
  *) die "--os-tuning must be one of: standard, tuned" ;;
esac
case "$ACCESS_MODE" in
  public|private) ;;
  *) die "--access-mode must be one of: public, private" ;;
esac
case "$LOCAL_FILESYSTEM" in
  ext4|xfs|raw) ;;
  *) die "--local-filesystem must be one of: ext4, xfs, raw" ;;
esac
case "$BLOCK_FILESYSTEM" in
  ext4|xfs|raw) ;;
  *) die "--block-filesystem must be one of: ext4, xfs, raw" ;;
esac
[[ "$CALIBRATION_RUNTIME_SEC" =~ ^[0-9]+$ ]] || die "--calibration-runtime-sec must be an integer"
case "$CPU_IDLE_PINNING" in
  0|1) ;;
  *) die "--cpu-idle-pinning must be 0 or 1" ;;
esac
case "$USE_SPOT" in
  0|1) ;;
  *) die "--use-spot must be 0 or 1" ;;
esac

cd "$REPO_ROOT"
TOFU_DIR="$(abs_path "$TOFU_DIR")"
BENCHMARK_DIR="$(abs_path "$BENCHMARK_DIR")"
require_dir "$TOFU_DIR"
require_dir "$BENCHMARK_DIR"

if [[ -n "$LOCAL_LOG_DIR" ]]; then
  LOCAL_LOG_DIR="$(abs_path "$LOCAL_LOG_DIR")"
  mkdir -p "$LOCAL_LOG_DIR"
fi

COMMAND_LOG=""
REMOTE_EXEC_LOG=""
if [[ -n "$LOCAL_LOG_DIR" ]]; then
  COMMAND_LOG="${LOCAL_LOG_DIR}/commands.log"
  REMOTE_EXEC_LOG="${LOCAL_LOG_DIR}/remote-exec.log"
  : >"$COMMAND_LOG"
  : >"$REMOTE_EXEC_LOG"
fi

tofu="$(tofu_bin)"
BENCHMARK_PRIVATE_IP="$(tofu_output_raw "$tofu" "$TOFU_DIR" benchmark_private_ip)"
SSH_KEY="$(expand_home "$(tofu_output_raw "$tofu" "$TOFU_DIR" ssh_private_key_path)")"
SSH_USER="$(tofu_output_raw "$tofu" "$TOFU_DIR" benchmark_ssh_user)"
BENCHMARK_MACHINE_TYPE="$(tofu_output_raw "$tofu" "$TOFU_DIR" benchmark_machine_type)"
BENCHMARK_AVAILABILITY_ZONE="$(tofu_output_raw "$tofu" "$TOFU_DIR" benchmark_availability_zone)"
BENCHMARK_LOCAL_MOUNT_POINT="$(tofu_output_raw "$tofu" "$TOFU_DIR" benchmark_local_mount_point)"
BENCHMARK_BLOCK_MOUNT_POINT="$(tofu_output_raw "$tofu" "$TOFU_DIR" benchmark_block_mount_point)"
require_file "$SSH_KEY"

if [[ "$ACCESS_MODE" == "private" ]]; then
  BENCHMARK_HOST="$BENCHMARK_PRIVATE_IP"
else
  BENCHMARK_HOST="$(tofu_output_raw "$tofu" "$TOFU_DIR" benchmark_public_ip)"
fi

if [[ -n "$LOCAL_LOG_DIR" ]]; then
  KNOWN_HOSTS_FILE="${LOCAL_LOG_DIR}/known_hosts"
  : >"$KNOWN_HOSTS_FILE"
else
  KNOWN_HOSTS_FILE=""
fi

REMOTE_SCENARIO_DIR="${REMOTE_RESULTS_ROOT}/${RUN_ID}/${SCENARIO_NAME}"
REMOTE_BIN_DIR="/opt/cloud-measuring/bin"
REMOTE_STORAGE_ENV="/opt/cloud-measuring/state/storage.env"
REMOTE_STORAGE_PREPARE_LOG=""

ssh_run() {
  local host="$1"
  shift
  local -a ssh_opts
  mapfile -t ssh_opts < <(ssh_base_args "$SSH_KEY" "$KNOWN_HOSTS_FILE")
  local cmd
  cmd=(ssh "${ssh_opts[@]}" "${SSH_USER}@${host}" "$@")
  # An optional wall-clock bound, set by the caller around invocations whose
  # legitimate duration is known. A benchmark that finished its measurement but
  # never exited held one run open for 30 minutes with instances billing; the
  # measurement had already been written, so terminating the ssh loses nothing
  # and the repetition is recorded as failed by the existing handling.
  if [[ -n "${SSH_TIMEOUT_SEC:-}" ]] && [[ "${SSH_TIMEOUT_SEC}" =~ ^[0-9]+$ ]] \
     && (( SSH_TIMEOUT_SEC > 0 )) && command -v timeout >/dev/null 2>&1; then
    cmd=(timeout --signal=TERM --kill-after=15 "$SSH_TIMEOUT_SEC" "${cmd[@]}")
  fi
  if [[ -n "$COMMAND_LOG" ]]; then
    append_command_log "$COMMAND_LOG" "${cmd[@]}"
  fi
  if [[ -z "$REMOTE_EXEC_LOG" ]]; then
    "${cmd[@]}"
    return
  fi

  local stdout_file stderr_file rc
  stdout_file="$(mktemp /tmp/cloud-measuring-ssh-stdout.XXXXXX)"
  stderr_file="$(mktemp /tmp/cloud-measuring-ssh-stderr.XXXXXX)"

  set +e
  "${cmd[@]}" >"$stdout_file" 2>"$stderr_file"
  rc=$?
  set -e

  {
    printf '# %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'host=%s\n' "$host"
    printf 'exit_status=%s\n' "$rc"
    printf 'command=\n'
    shell_join "${cmd[@]}"
    printf '\nstdout:\n'
    cat "$stdout_file"
    printf '\nstderr:\n'
    cat "$stderr_file"
    printf '\n\n'
  } >>"$REMOTE_EXEC_LOG"

  cat "$stdout_file"
  cat "$stderr_file" >&2
  rm -f "$stdout_file" "$stderr_file"
  return "$rc"
}

scp_to() {
  local src="$1"
  local host="$2"
  local dst="$3"
  local -a scp_opts
  mapfile -t scp_opts < <(ssh_base_args "$SSH_KEY" "$KNOWN_HOSTS_FILE")
  local cmd
  cmd=(scp "${scp_opts[@]}" "$src" "${SSH_USER}@${host}:${dst}")
  if [[ -n "$COMMAND_LOG" ]]; then
    append_command_log "$COMMAND_LOG" "${cmd[@]}"
  fi
  "${cmd[@]}"
}

wait_for_host() {
  local label="$1"
  local attempt
  log "waiting for ${label} SSH to be ready"
  for attempt in $(seq 1 90); do
    if ssh_run "$BENCHMARK_HOST" "true" >/dev/null 2>&1; then
      log "${label} SSH is ready"
      return 0
    fi
    if (( attempt % 10 == 0 )); then
      log "still waiting for ${label} SSH to be ready (${attempt}/90 attempts)"
    fi
    sleep 2
  done
  die "${label} SSH did not become ready: ${BENCHMARK_HOST}"
}

# Pull cloud-init's own logs back before the instance is destroyed.
#
# The wait above treats "status: error" as terminal, which is right -- it stops
# a doomed setup from burning all 180 attempts. But the reason cloud-init failed
# lives in /var/log/cloud-init-output.log on a machine that is about to be torn
# down, so without this the record of the failure is the single word "error".
#
# Written to the local run directory rather than the remote artifact tree,
# because the tree may not exist: a server whose cloud-init failed never got as
# far as creating one, and fetch_results pulls the client's tree in any case, so
# a server-side failure would be captured where nobody collects it. Best-effort
# throughout -- a host too broken to answer must not turn a diagnosable failure
# into a different one.
capture_cloud_init_failure() {
  local host="$1"
  local label="$2"
  [[ -n "${LOCAL_LOG_DIR:-}" ]] || return 0
  local out="${LOCAL_LOG_DIR}/cloud-init-failure-${label}.log"
  log "cloud-init ${label} failed; capturing its logs to ${out}"
  ssh_run "$host" "
    echo '=== cloud-init status --long ==='; cloud-init status --long 2>&1
    echo; echo '=== cloud-init-output.log (last 200 lines) ==='
    sudo tail -n 200 /var/log/cloud-init-output.log 2>&1
    echo; echo '=== cloud-init.log, error lines (last 100) ==='
    sudo grep -aiE 'error|failed|traceback' /var/log/cloud-init.log 2>/dev/null | tail -n 100
  " >"$out" 2>&1 || log "could not capture cloud-init logs from ${label}; the host may be unreachable"
}

wait_for_cloud_init() {
  local label="$1"
  local attempt
  log "waiting for cloud-init ${label} setup to finish"
  for attempt in $(seq 1 180); do
    if ssh_run "$BENCHMARK_HOST" "cloud-init status 2>/dev/null | grep -Eq 'status: done|status: error'"; then
      break
    fi
    if (( attempt % 10 == 0 )); then
      log "still waiting for cloud-init ${label} setup to finish (${attempt}/180 attempts)"
    fi
    sleep 2
  done
  if ! ssh_run "$BENCHMARK_HOST" "cloud-init status --wait >/tmp/cloud-init-status.log 2>&1 || (cat /tmp/cloud-init-status.log; exit 1)"; then
    capture_cloud_init_failure "$BENCHMARK_HOST" "$label"
    die "cloud-init ${label} setup failed on ${BENCHMARK_HOST}; see cloud-init-failure-${label}.log"
  fi
}

remote_cpu_list() {
  local n
  n="$(ssh_run "$BENCHMARK_HOST" "nproc" | tr -d '\r\n')"
  if [[ "$n" =~ ^[0-9]+$ && "$n" -ge 2 ]]; then
    echo "1-$((n - 1))"
  else
    echo "0"
  fi
}

validate_common_benchmark() {
  [[ -n "${BENCHMARK_NAME:-}" ]] || die "${benchmark_file}: BENCHMARK_NAME is required"
  [[ "$BENCHMARK_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || die "${benchmark_file}: BENCHMARK_NAME contains unsafe characters"
  [[ "${BENCHMARK_TOOL:-}" == "fio" ]] || die "${benchmark_file}: BENCHMARK_TOOL must be fio"
  [[ "${SKIP:-0}" == "0" || "${SKIP:-0}" == "1" ]] || die "${benchmark_file}: SKIP must be 0 or 1"
}

validate_int() {
  local name="$1"
  local value="$2"
  [[ "$value" =~ ^[0-9]+$ ]] || die "${benchmark_file}: ${name} must be an integer"
}

validate_size() {
  local name="$1"
  local value="$2"
  [[ "$value" =~ ^[0-9]+([KMGkmg])?$ ]] || die "${benchmark_file}: ${name} must be a size with optional K/M/G suffix"
}

selected_benchmark() {
  local name="$1"
  if [[ "${#BENCHMARK_NAMES[@]}" -eq 0 ]]; then
    return 0
  fi
  local selected
  for selected in "${BENCHMARK_NAMES[@]}"; do
    [[ "$selected" == "$name" ]] && return 0
  done
  return 1
}

apply_os_tuning() {
  local label="$1"
  log "applying OS tuning profile '${OS_TUNING}' on ${label}"
  # The tuning script is shipped by push_remote_scripts, not baked into the
  # image, so this must run after it.
  ssh_run "$BENCHMARK_HOST" "mkdir -p '${REMOTE_SCENARIO_DIR}' && sudo '${REMOTE_BIN_DIR}/apply-os-tuning.sh' '${OS_TUNING}' --facts-out '${REMOTE_SCENARIO_DIR}/os-tuning.env' >'${REMOTE_SCENARIO_DIR}/os-tuning.log' 2>&1"
}

push_remote_scripts() {
  ssh_run "$BENCHMARK_HOST" "mkdir -p '${REMOTE_BIN_DIR}' '${REMOTE_SCENARIO_DIR}'"
  scp_to "${REPO_ROOT}/storage/remote/run_fio.sh" "$BENCHMARK_HOST" "${REMOTE_BIN_DIR}/run_fio.sh"
  scp_to "${REPO_ROOT}/storage/remote/run_benchmarks.sh" "$BENCHMARK_HOST" "${REMOTE_BIN_DIR}/run_benchmarks.sh"
  scp_to "${REPO_ROOT}/storage/remote/prepare_storage_target.sh" "$BENCHMARK_HOST" "${REMOTE_BIN_DIR}/prepare_storage_target.sh"
  scp_to "${REPO_ROOT}/common/remote/collect-node-facts.sh" "$BENCHMARK_HOST" "${REMOTE_BIN_DIR}/collect-node-facts.sh"
  scp_to "${REPO_ROOT}/common/remote/apply-os-tuning.sh" "$BENCHMARK_HOST" "${REMOTE_BIN_DIR}/apply-os-tuning.sh"
  scp_to "${REPO_ROOT}/common/remote/cpu-idle-pin.sh" "$BENCHMARK_HOST" "${REMOTE_BIN_DIR}/cpu-idle-pin.sh"
  ssh_run "$BENCHMARK_HOST" "chmod +x '${REMOTE_BIN_DIR}/run_fio.sh' '${REMOTE_BIN_DIR}/run_benchmarks.sh' '${REMOTE_BIN_DIR}/prepare_storage_target.sh' '${REMOTE_BIN_DIR}/collect-node-facts.sh' '${REMOTE_BIN_DIR}/apply-os-tuning.sh' '${REMOTE_BIN_DIR}/cpu-idle-pin.sh'"
}

# Idle-state control matters here for the same reason it does on the network
# side: the psync queue-depth-1 profiles spend most of their time waiting, so a
# core that drops into a deep state pays exit latency on every completion. As on
# the network side this always runs, so an unpinned scenario still records the
# baseline delta.
cpu_idle_start() {
  log "cpu-idle start on benchmark host (requested pinning=${CPU_IDLE_PINNING})"
  if ! ssh_run "$BENCHMARK_HOST" "sudo '${REMOTE_BIN_DIR}/cpu-idle-pin.sh' --action start --pin '${CPU_IDLE_PINNING}' --out '${REMOTE_SCENARIO_DIR}/cpu-idle-benchmark.env' >>'${REMOTE_SCENARIO_DIR}/cpu-idle.log' 2>&1"; then
    log "ignoring cpu-idle start failure on benchmark host"
  fi
}

cpu_idle_stop() {
  if ! ssh_run "$BENCHMARK_HOST" "sudo '${REMOTE_BIN_DIR}/cpu-idle-pin.sh' --action stop --pin '${CPU_IDLE_PINNING}' --out '${REMOTE_SCENARIO_DIR}/cpu-idle-benchmark.env' >>'${REMOTE_SCENARIO_DIR}/cpu-idle.log' 2>&1"; then
    log "ignoring cpu-idle stop failure on benchmark host"
  fi
}

discover_storage_env() {
  local tmp
  tmp="$(mktemp /tmp/cloud-measuring-storage-env.XXXXXX)"
  ssh_run "$BENCHMARK_HOST" "cat '${REMOTE_STORAGE_ENV}'" >"$tmp"
  unset STORAGE_TARGETS STORAGE_ROOT_DEVICE STORAGE_LOCAL_DEVICE STORAGE_LOCAL_MOUNT STORAGE_LOCAL_FILESYSTEM STORAGE_BLOCK_DEVICE STORAGE_BLOCK_MOUNT STORAGE_BLOCK_FILESYSTEM
  # shellcheck disable=SC1090
  source "$tmp"
  rm -f "$tmp"
  [[ -n "${STORAGE_TARGETS:-}" ]] || die "no storage targets discovered on benchmark host"
}

reconcile_storage_targets() {
  REMOTE_STORAGE_PREPARE_LOG="${REMOTE_SCENARIO_DIR}/storage-prepare.log"
  ssh_run "$BENCHMARK_HOST" "mkdir -p '${REMOTE_SCENARIO_DIR}' && sudo '${REMOTE_BIN_DIR}/prepare_storage_target.sh' --storage-env '${REMOTE_STORAGE_ENV}' --local-mount-point '${BENCHMARK_LOCAL_MOUNT_POINT}' --local-filesystem '${LOCAL_FILESYSTEM}' --block-mount-point '${BENCHMARK_BLOCK_MOUNT_POINT}' --block-filesystem '${BLOCK_FILESYSTEM}' >'${REMOTE_STORAGE_PREPARE_LOG}' 2>&1"
}

write_remote_metadata() {
  local tmp
  tmp="$(mktemp /tmp/cloud-measuring-storage-scenario.XXXXXX.env)"
  write_env_file "$tmp" RUN_ID SCENARIO_NAME OS_TUNING CPU_IDLE_PINNING USE_SPOT ACCESS_MODE BENCHMARK_HOST BENCHMARK_PRIVATE_IP SSH_USER BENCHMARK_CPU_LIST BENCHMARK_MACHINE_TYPE BENCHMARK_AVAILABILITY_ZONE STORAGE_TARGETS STORAGE_ROOT_DEVICE STORAGE_LOCAL_DEVICE STORAGE_LOCAL_MOUNT STORAGE_LOCAL_FILESYSTEM STORAGE_BLOCK_DEVICE STORAGE_BLOCK_MOUNT STORAGE_BLOCK_FILESYSTEM
  scp_to "$tmp" "$BENCHMARK_HOST" "${REMOTE_SCENARIO_DIR}/scenario.env"
  rm -f "$tmp"

  local meta_cmd
  meta_cmd="mkdir -p '${REMOTE_SCENARIO_DIR}' && { date -u +%Y-%m-%dT%H:%M:%SZ; hostname; uname -a; lscpu; ip addr; ip route; lsblk -o NAME,TYPE,SIZE,MOUNTPOINT,MODEL,FSTYPE; findmnt; fio --version || true; command -v ethtool >/dev/null 2>&1 && ethtool -i \$(ip route get 1.1.1.1 | awk '/dev/ {for (i=1;i<=NF;i++) if (\$i==\"dev\") print \$(i+1); exit}') || true; } >'${REMOTE_SCENARIO_DIR}/node-meta.log' 2>&1"
  ssh_run "$BENCHMARK_HOST" "$meta_cmd"

  # Structured counterpart to node-meta.log; see common/remote/collect-node-facts.sh.
  if ! ssh_run "$BENCHMARK_HOST" "'${REMOTE_BIN_DIR}/collect-node-facts.sh' --out '${REMOTE_SCENARIO_DIR}/node-facts.env'"; then
    log "ignoring node-facts collection failure on benchmark host"
  fi
}

# A short 4 KiB queue-depth-1 fsync probe on every discovered target, run once
# per scenario before the benchmark suite.
#
# Two instances of the same type can differ by tens of percent in sustained
# write rate, which is larger than most of the configuration effects this suite
# tries to measure. Per-write fsync latency discriminates a slow device; a
# sequential bandwidth probe does not -- it reports near-identical numbers for
# devices whose fsync rates differ two-fold. Recording this makes "we drew a slow
# disk" separable from "this performance class is slower".
run_device_calibration() {
  local probe_dir="${REMOTE_SCENARIO_DIR}/device-calibration"
  local target_name target_mount_var target_device_var target_filesystem_var
  local target_mount target_device target_filesystem
  local calibration_env
  calibration_env="$(mktemp /tmp/cloud-measuring-calibration.XXXXXX.env)"
  : >"$calibration_env"

  for target_name in $STORAGE_TARGETS; do
    target_mount_var="STORAGE_${target_name^^}_MOUNT"
    target_device_var="STORAGE_${target_name^^}_DEVICE"
    target_filesystem_var="STORAGE_${target_name^^}_FILESYSTEM"
    target_mount="${!target_mount_var:-}"
    target_device="${!target_device_var:-}"
    target_filesystem="${!target_filesystem_var:-}"
    [[ -n "$target_device" ]] || continue
    if [[ "$target_filesystem" != "raw" && -z "$target_mount" ]]; then
      continue
    fi

    local out_dir="${probe_dir}/${target_name}"
    local -a probe_cmd=(
      "${REMOTE_BIN_DIR}/run_fio.sh"
      --out-dir "$out_dir"
      --name "calibration-4k-qd1-fsync-${target_name}"
      --ioengine psync
      --rw randwrite
      --bs 4k
      --iodepth 1
      --numjobs 1
      --runtime-sec "$CALIBRATION_RUNTIME_SEC"
      --direct 1
      --group-reporting 1
      --time-based 1
      --size 256M
      --fsync 1
      --cpu-list "$BENCHMARK_CPU_LIST"
    )
    if [[ "$target_filesystem" == "raw" ]]; then
      probe_cmd=(sudo "${probe_cmd[@]}")
      probe_cmd+=(--device "$target_device")
    else
      probe_cmd+=(--mount-point "$target_mount")
    fi

    log "device calibration probe on target ${target_name}"
    # Bounded like the benchmark itself. The probe runs before any measurement,
    # so a hang here holds the instances open having produced nothing at all --
    # and it is already non-fatal, so a terminated probe costs the calibration
    # numbers rather than the scenario.
    SSH_TIMEOUT_SEC="$(step_timeout_sec "$CALIBRATION_RUNTIME_SEC")"
    if ! ssh_run "$BENCHMARK_HOST" "$(shell_join "${probe_cmd[@]}")"; then
      SSH_TIMEOUT_SEC=""
      log "device calibration probe failed or timed out on target ${target_name}; continuing"
      continue
    fi
    SSH_TIMEOUT_SEC=""

    # Pull the two numbers worth carrying in the scenario row.
    local iops p99
    iops="$(ssh_run "$BENCHMARK_HOST" "jq -r '.jobs[0].write.iops // empty' '${out_dir}/fio.json' 2>/dev/null" | tr -d '\r\n' || true)"
    p99="$(ssh_run "$BENCHMARK_HOST" "jq -r '.jobs[0].write.clat_ns.percentile[\"99.000000\"] // empty' '${out_dir}/fio.json' 2>/dev/null" | tr -d '\r\n' || true)"
    [[ -n "$iops" ]] && printf 'NODE_CALIBRATION_%s_FSYNC_IOPS=%s\n' "${target_name^^}" "$iops" >>"$calibration_env"
    [[ -n "$p99" ]] && printf 'NODE_CALIBRATION_%s_FSYNC_CLAT_P99_NS=%s\n' "${target_name^^}" "$p99" >>"$calibration_env"
    log "calibration ${target_name}: fsync iops=${iops:-unknown} clat_p99_ns=${p99:-unknown}"
  done

  if [[ -s "$calibration_env" ]]; then
    scp_to "$calibration_env" "$BENCHMARK_HOST" "${REMOTE_SCENARIO_DIR}/device-calibration.env"
  fi
  rm -f "$calibration_env"
}

write_benchmark_env() {
  local remote_target_dir="$1"
  local target_name="$2"
  local target_mount="$3"
  local target_device="$4"
  local target_filesystem="$5"
  local tmp
  ssh_run "$BENCHMARK_HOST" "mkdir -p '${remote_target_dir}'"
  tmp="$(mktemp /tmp/cloud-measuring-storage-benchmark.XXXXXX.env)"
  write_env_file "$tmp" \
    BENCHMARK_NAME BENCHMARK_TOOL REPETITIONS COOLDOWN_SEC OS_TUNING BENCHMARK_CPU_LIST \
    STORAGE_TARGET_NAME STORAGE_TARGET_MOUNT STORAGE_TARGET_DEVICE STORAGE_TARGET_FILESYSTEM \
    FIO_IOENGINE FIO_RW FIO_BS FIO_IODEPTH FIO_NUMJOBS FIO_RUNTIME_SEC FIO_DIRECT FIO_GROUP_REPORTING FIO_TIME_BASED FIO_SIZE \
    FIO_FSYNC FIO_FDATASYNC FIO_RATE_IOPS
  scp_to "$tmp" "$BENCHMARK_HOST" "${remote_target_dir}/benchmark.env"
  rm -f "$tmp"
}

run_one_fio_repetition() {
  local remote_rep_dir="$1"
  local target_mount="$2"
  local target_device="$3"
  local target_filesystem="$4"
  ssh_run "$BENCHMARK_HOST" "mkdir -p '${remote_rep_dir}'"

  local fio_cmd=(
    "${REMOTE_BIN_DIR}/run_fio.sh"
    --out-dir "$remote_rep_dir"
    --name "$BENCHMARK_NAME"
    --ioengine "$FIO_IOENGINE"
    --rw "$FIO_RW"
    --bs "$FIO_BS"
    --iodepth "$FIO_IODEPTH"
    --numjobs "$FIO_NUMJOBS"
    --runtime-sec "$FIO_RUNTIME_SEC"
    --direct "$FIO_DIRECT"
    --group-reporting "$FIO_GROUP_REPORTING"
    --time-based "$FIO_TIME_BASED"
    --cpu-list "$BENCHMARK_CPU_LIST"
  )
  if [[ "$target_filesystem" == "raw" ]]; then
    fio_cmd=(sudo "${fio_cmd[@]}")
    fio_cmd+=(--device "$target_device")
  else
    fio_cmd+=(--mount-point "$target_mount")
  fi
  if [[ -n "${FIO_SIZE:-}" ]]; then
    fio_cmd+=(--size "$FIO_SIZE")
  fi
  if [[ "${FIO_FSYNC:-0}" != "0" ]]; then
    fio_cmd+=(--fsync "$FIO_FSYNC")
  fi
  if [[ "${FIO_FDATASYNC:-0}" != "0" ]]; then
    fio_cmd+=(--fdatasync "$FIO_FDATASYNC")
  fi
  if [[ "${FIO_RATE_IOPS:-0}" != "0" ]]; then
    fio_cmd+=(--rate-iops "$FIO_RATE_IOPS")
  fi

  set +e
  # Bounded for the same reason as the network benchmarks: a tool that stops
  # making progress cannot be observed from here, only outlived. fio writes its
  # JSON before exiting, so a terminated run loses the repetition, not the data
  # already on disk.
  SSH_TIMEOUT_SEC="$(step_timeout_sec "$FIO_RUNTIME_SEC")"
  ssh_run "$BENCHMARK_HOST" "$(shell_join "${fio_cmd[@]}")"
  local rc=$?
  SSH_TIMEOUT_SEC=""
  set -e
  if [[ "$rc" -eq 124 ]]; then
    log "fio exceeded its time bound and was terminated; recording the repetition as failed"
  fi
  return "$rc"
}

run_repetitions() {
  local remote_target_dir="$1"
  local target_name="$2"
  local target_mount="$3"
  local target_device="$4"
  local target_filesystem="$5"
  STORAGE_TARGET_NAME="$target_name"
  STORAGE_TARGET_MOUNT="$target_mount"
  STORAGE_TARGET_DEVICE="$target_device"
  STORAGE_TARGET_FILESYSTEM="$target_filesystem"
  write_benchmark_env "$remote_target_dir" "$target_name" "$target_mount" "$target_device" "$target_filesystem"
  local rep rc
  for rep in $(seq 1 "$REPETITIONS"); do
    log "running benchmark ${BENCHMARK_NAME} target ${target_name} repetition ${rep}/${REPETITIONS}"
    rc=0
    # See the network runner: '|| rc=$?' also suppresses errexit for the whole
    # repetition, so one failed fio run does not skip every later benchmark in
    # this scenario.
    run_one_fio_repetition "${remote_target_dir}/rep-${rep}" "$target_mount" "$target_device" "$target_filesystem" || rc=$?
    record_repetition_status "${remote_target_dir}/rep-${rep}" "$rc"
    if (( rc != 0 )); then
      BENCHMARK_FAILURES=$((BENCHMARK_FAILURES + 1))
      log "benchmark ${BENCHMARK_NAME} target ${target_name} repetition ${rep} failed with status ${rc}; continuing"
    fi
    if (( rep < REPETITIONS )); then
      sleep "$COOLDOWN_SEC"
    fi
  done
}

# Complements the fio-content validity checks in analysis/storage/build_csv.R:
# those detect a run that produced bad numbers, this records a run that never
# produced numbers at all.
record_repetition_status() {
  local remote_rep_dir="$1"
  local rc="$2"
  local tmp
  tmp="$(mktemp /tmp/cloud-measuring-rep-status.XXXXXX.env)"
  {
    printf 'REP_EXIT_STATUS=%s\n' "$rc"
    if [[ "$rc" == "0" ]]; then
      printf 'REP_VALID=1\n'
      printf 'REP_FAILURE_REASON=\n'
    else
      printf 'REP_VALID=0\n'
      printf 'REP_FAILURE_REASON=%s\n' "fio command exited ${rc}"
    fi
  } >"$tmp"
  if ! scp_to "$tmp" "$BENCHMARK_HOST" "${remote_rep_dir}/status.env"; then
    log "could not record repetition status for ${remote_rep_dir}"
  fi
  rm -f "$tmp"
}

run_fio_benchmark() {
  REPETITIONS="${REPETITIONS:-1}"
  COOLDOWN_SEC="${COOLDOWN_SEC:-2}"
  FIO_IOENGINE="${FIO_IOENGINE:-io_uring}"
  FIO_RW="${FIO_RW:-randread}"
  FIO_BS="${FIO_BS:-4k}"
  FIO_IODEPTH="${FIO_IODEPTH:-32}"
  FIO_NUMJOBS="${FIO_NUMJOBS:-1}"
  FIO_RUNTIME_SEC="${FIO_RUNTIME_SEC:-60}"
  FIO_DIRECT="${FIO_DIRECT:-1}"
  FIO_GROUP_REPORTING="${FIO_GROUP_REPORTING:-1}"
  FIO_TIME_BASED="${FIO_TIME_BASED:-1}"
  FIO_SIZE="${FIO_SIZE:-}"
  FIO_FSYNC="${FIO_FSYNC:-0}"
  FIO_FDATASYNC="${FIO_FDATASYNC:-0}"
  # 0 keeps the historical saturation behaviour; non-zero turns the benchmark
  # into a latency-at-known-offered-rate measurement.
  FIO_RATE_IOPS="${FIO_RATE_IOPS:-0}"

  validate_int FIO_RATE_IOPS "$FIO_RATE_IOPS"
  validate_int REPETITIONS "$REPETITIONS"
  validate_int COOLDOWN_SEC "$COOLDOWN_SEC"
  validate_int FIO_IODEPTH "$FIO_IODEPTH"
  validate_int FIO_NUMJOBS "$FIO_NUMJOBS"
  validate_int FIO_RUNTIME_SEC "$FIO_RUNTIME_SEC"
  validate_int FIO_DIRECT "$FIO_DIRECT"
  validate_int FIO_GROUP_REPORTING "$FIO_GROUP_REPORTING"
  validate_int FIO_TIME_BASED "$FIO_TIME_BASED"
  validate_int FIO_FSYNC "$FIO_FSYNC"
  validate_int FIO_FDATASYNC "$FIO_FDATASYNC"
  validate_size FIO_BS "$FIO_BS"
  if [[ -n "$FIO_SIZE" ]]; then
    validate_size FIO_SIZE "$FIO_SIZE"
  fi

  [[ -n "$FIO_IOENGINE" ]] || die "${benchmark_file}: FIO_IOENGINE is required"
  [[ -n "$FIO_RW" ]] || die "${benchmark_file}: FIO_RW is required"
  if (( FIO_FSYNC > 0 && FIO_FDATASYNC > 0 )); then
    die "${benchmark_file}: only one of FIO_FSYNC or FIO_FDATASYNC may be non-zero"
  fi

  local remote_target_dir
  local target_name
  local target_mount_var
  local target_device_var
  local target_filesystem_var
  local target_mount
  local target_device
  local target_filesystem

  for target_name in $STORAGE_TARGETS; do
    target_mount_var="STORAGE_${target_name^^}_MOUNT"
    target_device_var="STORAGE_${target_name^^}_DEVICE"
    target_filesystem_var="STORAGE_${target_name^^}_FILESYSTEM"
    target_mount="${!target_mount_var:-}"
    target_device="${!target_device_var:-}"
    target_filesystem="${!target_filesystem_var:-}"
    [[ -n "$target_device" ]] || continue
    if [[ "$target_filesystem" != "raw" && -z "$target_mount" ]]; then
      continue
    fi
    remote_target_dir="${REMOTE_SCENARIO_DIR}/benchmarks/${BENCHMARK_NAME}/${target_name}"
    run_repetitions "$remote_target_dir" "$target_name" "$target_mount" "$target_device" "$target_filesystem"
  done
}

log "waiting for benchmark host SSH to be ready"
wait_for_host benchmark
log "waiting for cloud-init benchmark setup to finish"
wait_for_cloud_init benchmark
# Scripts must be staged before anything invokes them. apply-os-tuning.sh is
# shipped from the repository rather than embedded in the image, so this push
# has to precede apply_os_tuning.
push_remote_scripts
apply_os_tuning benchmark
trap cpu_idle_stop EXIT
cpu_idle_start
BENCHMARK_CPU_LIST="$(remote_cpu_list)"
log "benchmark CPU list: ${BENCHMARK_CPU_LIST}"
discover_storage_env
reconcile_storage_targets
discover_storage_env
write_remote_metadata
ssh_run "$BENCHMARK_HOST" "mkdir -p '${REMOTE_SCENARIO_DIR}'"
ssh_run "$BENCHMARK_HOST" "cp '${REMOTE_STORAGE_ENV}' '${REMOTE_SCENARIO_DIR}/storage.env'"

if [[ -n "$COMMAND_LOG" ]]; then
  append_command_text "$COMMAND_LOG" "" "scenario=${SCENARIO_NAME} os_tuning=${OS_TUNING}"
fi

mapfile -t benchmark_files < <(find "$BENCHMARK_DIR" -maxdepth 1 -type f -name '*.sh' | sort)
[[ "${#benchmark_files[@]}" -gt 0 ]] || die "no benchmark files found in ${BENCHMARK_DIR}"

for benchmark_file in "${benchmark_files[@]}"; do
  unset BENCHMARK_NAME BENCHMARK_TOOL SKIP SKIP_REASON
  unset REPETITIONS COOLDOWN_SEC
  unset FIO_IOENGINE FIO_RW FIO_BS FIO_IODEPTH FIO_NUMJOBS FIO_RUNTIME_SEC FIO_DIRECT FIO_GROUP_REPORTING FIO_TIME_BASED FIO_SIZE FIO_FSYNC FIO_FDATASYNC FIO_RATE_IOPS

  # Deliberately not pre-seeded here; see the same note in
  # network/scripts/run_benchmarks.sh. Assigning REPETITIONS/COOLDOWN_SEC before
  # sourcing defeats the ':=' defaults in benchmark_defaults.sh. Every current
  # storage benchmark sets both explicitly so nothing changes today, but a file
  # that relied on the defaults would silently run one repetition.
  # shellcheck disable=SC1090
  source "$benchmark_file"
  validate_common_benchmark

  # ${SKIP:-0}: a benchmark file that neither sets SKIP nor sources
  # benchmark_defaults.sh would otherwise abort the scenario under set -u.
  if [[ "${SKIP:-0}" == "1" ]]; then
    log "skipping benchmark ${BENCHMARK_NAME}${SKIP_REASON:+: ${SKIP_REASON}}"
    continue
  fi

  if ! selected_benchmark "$BENCHMARK_NAME"; then
    continue
  fi

  log "running benchmark ${BENCHMARK_NAME}"
  run_fio_benchmark
done

# Characterise the devices we drew, after the suite rather than before it.
#
# The probe writes 4k random writes with fsync over the first 256 MB of each
# target, which is inside the region the benchmarks then use -- running it first
# preconditioned a quarter of a 1 GiB working set and left the rest fresh.
# Running it first bought nothing: the instance is already provisioned either
# way, so learning that a device is slow earlier does not save any spend, and
# the measurement it feeds is a post-hoc attribution ("was this a slow draw?")
# rather than a gate. It therefore describes the device as the benchmarks left
# it, consistently across scenarios.
if [[ "$CALIBRATION_RUNTIME_SEC" -gt 0 ]]; then
  run_device_calibration
else
  log "device calibration probe disabled"
fi

# Every benchmark got its chance and every artifact is on disk; the scenario is
# still reported as failed so the run is not mistaken for a clean one.
if (( BENCHMARK_FAILURES > 0 )); then
  log "scenario ${SCENARIO_NAME}: ${BENCHMARK_FAILURES} repetition(s) failed"
  exit 1
fi
