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
  ssh_run "$BENCHMARK_HOST" "cloud-init status --wait >/tmp/cloud-init-status.log 2>&1 || (cat /tmp/cloud-init-status.log; exit 1)"
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
  ssh_run "$BENCHMARK_HOST" "mkdir -p '${REMOTE_SCENARIO_DIR}' && sudo /opt/cloud-measuring/bin/apply-os-tuning.sh '${OS_TUNING}' >'${REMOTE_SCENARIO_DIR}/os-tuning.log' 2>&1"
}

push_remote_scripts() {
  ssh_run "$BENCHMARK_HOST" "mkdir -p '${REMOTE_BIN_DIR}' '${REMOTE_SCENARIO_DIR}'"
  scp_to "${REPO_ROOT}/storage/remote/run_fio.sh" "$BENCHMARK_HOST" "${REMOTE_BIN_DIR}/run_fio.sh"
  scp_to "${REPO_ROOT}/storage/remote/run_benchmarks.sh" "$BENCHMARK_HOST" "${REMOTE_BIN_DIR}/run_benchmarks.sh"
  scp_to "${REPO_ROOT}/storage/remote/prepare_storage_target.sh" "$BENCHMARK_HOST" "${REMOTE_BIN_DIR}/prepare_storage_target.sh"
  ssh_run "$BENCHMARK_HOST" "chmod +x '${REMOTE_BIN_DIR}/run_fio.sh' '${REMOTE_BIN_DIR}/run_benchmarks.sh' '${REMOTE_BIN_DIR}/prepare_storage_target.sh'"
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
  write_env_file "$tmp" RUN_ID SCENARIO_NAME OS_TUNING ACCESS_MODE BENCHMARK_HOST BENCHMARK_PRIVATE_IP SSH_USER BENCHMARK_CPU_LIST BENCHMARK_MACHINE_TYPE BENCHMARK_AVAILABILITY_ZONE STORAGE_TARGETS STORAGE_ROOT_DEVICE STORAGE_LOCAL_DEVICE STORAGE_LOCAL_MOUNT STORAGE_LOCAL_FILESYSTEM STORAGE_BLOCK_DEVICE STORAGE_BLOCK_MOUNT STORAGE_BLOCK_FILESYSTEM
  scp_to "$tmp" "$BENCHMARK_HOST" "${REMOTE_SCENARIO_DIR}/scenario.env"
  rm -f "$tmp"

  local meta_cmd
  meta_cmd="mkdir -p '${REMOTE_SCENARIO_DIR}' && { date -u +%Y-%m-%dT%H:%M:%SZ; hostname; uname -a; lscpu; ip addr; ip route; lsblk -o NAME,TYPE,SIZE,MOUNTPOINT,MODEL,FSTYPE; findmnt; fio --version || true; command -v ethtool >/dev/null 2>&1 && ethtool -i \$(ip route get 1.1.1.1 | awk '/dev/ {for (i=1;i<=NF;i++) if (\$i==\"dev\") print \$(i+1); exit}') || true; } >'${REMOTE_SCENARIO_DIR}/node-meta.log' 2>&1"
  ssh_run "$BENCHMARK_HOST" "$meta_cmd"
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
    FIO_FSYNC FIO_FDATASYNC
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

  set +e
  ssh_run "$BENCHMARK_HOST" "$(shell_join "${fio_cmd[@]}")"
  local rc=$?
  set -e
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
  local rep
  for rep in $(seq 1 "$REPETITIONS"); do
    log "running benchmark ${BENCHMARK_NAME} target ${target_name} repetition ${rep}/${REPETITIONS}"
    run_one_fio_repetition "${remote_target_dir}/rep-${rep}" "$target_mount" "$target_device" "$target_filesystem"
    if (( rep < REPETITIONS )); then
      sleep "$COOLDOWN_SEC"
    fi
  done
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
apply_os_tuning benchmark
BENCHMARK_CPU_LIST="$(remote_cpu_list)"
log "benchmark CPU list: ${BENCHMARK_CPU_LIST}"
push_remote_scripts
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
  unset FIO_IOENGINE FIO_RW FIO_BS FIO_IODEPTH FIO_NUMJOBS FIO_RUNTIME_SEC FIO_DIRECT FIO_GROUP_REPORTING FIO_TIME_BASED FIO_SIZE FIO_FSYNC FIO_FDATASYNC
  REPETITIONS=1
  COOLDOWN_SEC=2

  # shellcheck disable=SC1090
  source "$benchmark_file"
  validate_common_benchmark

  if [[ "$SKIP" == "1" ]]; then
    log "skipping benchmark ${BENCHMARK_NAME}${SKIP_REASON:+: ${SKIP_REASON}}"
    continue
  fi

  if ! selected_benchmark "$BENCHMARK_NAME"; then
    continue
  fi

  log "running benchmark ${BENCHMARK_NAME}"
  run_fio_benchmark
done
