#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
source "${REPO_ROOT}/common/scripts/common.sh"

declare -a SCENARIO_FILES=()
declare -a BENCHMARK_NAMES=()
SCENARIO_DIR=""
LOCAL_OUT="artifacts/storage"
DESTROY_MODE="always"
CONTINUE_ON_ERROR=0
DRY_RUN=0
ACCESS_MODE="public"
RUN_ID="run-$(date +%Y%m%d-%H%M%S)"
LOCAL_RUN_DIR=""
LOCAL_LAUNCHER_LOG=""
LOCAL_COMMAND_LOG=""

usage() {
  cat >&2 <<USAGE
usage: $0 [--scenario FILE ... | --scenario-dir DIR] [--benchmark NAME ...] [--out DIR] [--destroy always|success|never] [--continue-on-error] [--dry-run] [--access-mode public|private]
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scenario) SCENARIO_FILES+=("$2"); shift 2 ;;
    --scenario-dir) SCENARIO_DIR="$2"; shift 2 ;;
    --benchmark) BENCHMARK_NAMES+=("$2"); shift 2 ;;
    --out) LOCAL_OUT="$2"; shift 2 ;;
    --destroy) DESTROY_MODE="$2"; shift 2 ;;
    --continue-on-error) CONTINUE_ON_ERROR=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --access-mode) ACCESS_MODE="$2"; shift 2 ;;
    --run-id) RUN_ID="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

case "$DESTROY_MODE" in
  always|success|never) ;;
  *) die "--destroy must be one of: always, success, never" ;;
esac
case "$ACCESS_MODE" in
  public|private) ;;
  *) die "--access-mode must be one of: public, private" ;;
esac

cd "$REPO_ROOT"

if [[ -n "$SCENARIO_DIR" ]]; then
  SCENARIO_DIR="$(abs_path "$SCENARIO_DIR")"
  require_dir "$SCENARIO_DIR"
  mapfile -t dir_scenarios < <(find "$SCENARIO_DIR" -type f -name '*.sh' | sort)
  SCENARIO_FILES+=("${dir_scenarios[@]}")
fi

if [[ "${#SCENARIO_FILES[@]}" -eq 0 ]]; then
  SCENARIO_FILES+=("storage/scenarios/stackit/g2a30d-block.sh")
fi

# Validate the whole selection before provisioning anything.
preflight_scenarios "$REPO_ROOT" "${SCENARIO_FILES[@]}"

run_scenario() {
  local scenario_file="$1"
  scenario_file="$(abs_path "$scenario_file")"
  require_file "$scenario_file"

  unset SCENARIO_NAME PROVIDER TOFU_DIR TFVARS_FILE BENCHMARK_DIR OS_TUNING BENCHMARK_MACHINE_TYPE BENCHMARK_IMAGE_ID BLOCK_VOLUME_SIZE_GIB BLOCK_VOLUME_PERFORMANCE_CLASS BLOCK_VOLUME_TYPE BLOCK_VOLUME_IOPS BLOCK_VOLUME_THROUGHPUT_MBPS LOCAL_FILESYSTEM BLOCK_FILESYSTEM BENCHMARK_ROOT_VOLUME_SIZE_GIB BENCHMARK_ROOT_VOLUME_PERFORMANCE_CLASS CPU_IDLE_PINNING USE_SPOT SKIP SKIP_REASON
  # shellcheck disable=SC1090
  source "$scenario_file"

  local skip="${SKIP:-0}"
  local skip_reason="${SKIP_REASON:-}"
  local scenario_label="${SCENARIO_NAME:-$(basename "$scenario_file")}"
  if [[ "$skip" == "1" ]]; then
    log "scenario ${scenario_label} skipped"
    if [[ -n "$skip_reason" ]]; then
      echo "  skip_reason=${skip_reason}"
    fi
    if [[ "$DRY_RUN" -eq 1 ]]; then
      echo "  status=skipped"
      [[ -n "$skip_reason" ]] && echo "  skip_reason=${skip_reason}"
    fi
    return 0
  fi

  [[ -n "${SCENARIO_NAME:-}" ]] || die "${scenario_file}: SCENARIO_NAME is required"
  [[ "$SCENARIO_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || die "${scenario_file}: SCENARIO_NAME contains unsafe characters"
  case "${PROVIDER:-}" in
    stackit|aws) ;;
    *) die "${scenario_file}: PROVIDER must be one of: stackit, aws" ;;
  esac
  [[ -n "${TOFU_DIR:-}" ]] || die "${scenario_file}: TOFU_DIR is required"
  [[ -n "${TFVARS_FILE:-}" ]] || die "${scenario_file}: TFVARS_FILE is required"
  BENCHMARK_DIR="${BENCHMARK_DIR:-storage/benchmarks/full}"
  OS_TUNING="${OS_TUNING:-standard}"
  [[ "$OS_TUNING" == "standard" || "$OS_TUNING" == "tuned" ]] || die "${scenario_file}: OS_TUNING must be one of: standard, tuned"
  [[ -n "${BENCHMARK_MACHINE_TYPE:-}" ]] || die "${scenario_file}: BENCHMARK_MACHINE_TYPE is required"
  [[ -n "${BENCHMARK_IMAGE_ID:-}" ]] || die "${scenario_file}: BENCHMARK_IMAGE_ID is required"
  BLOCK_VOLUME_SIZE_GIB="${BLOCK_VOLUME_SIZE_GIB:-0}"
  BLOCK_VOLUME_PERFORMANCE_CLASS="${BLOCK_VOLUME_PERFORMANCE_CLASS:-}"
  BLOCK_VOLUME_TYPE="${BLOCK_VOLUME_TYPE:-}"
  BLOCK_VOLUME_IOPS="${BLOCK_VOLUME_IOPS:-}"
  BLOCK_VOLUME_THROUGHPUT_MBPS="${BLOCK_VOLUME_THROUGHPUT_MBPS:-}"
  LOCAL_FILESYSTEM="${LOCAL_FILESYSTEM:-xfs}"
  BLOCK_FILESYSTEM="${BLOCK_FILESYSTEM:-ext4}"
  case "$LOCAL_FILESYSTEM" in
    ext4|xfs|raw) ;;
    *) die "${scenario_file}: LOCAL_FILESYSTEM must be one of: ext4, xfs, raw" ;;
  esac
  case "$BLOCK_FILESYSTEM" in
    ext4|xfs|raw) ;;
    *) die "${scenario_file}: BLOCK_FILESYSTEM must be one of: ext4, xfs, raw" ;;
  esac
  # Orthogonal to OS_TUNING. The psync qd1 profiles are mostly waiting, so a
  # core dropping into a deep idle state pays exit latency per completion.
  CPU_IDLE_PINNING="${CPU_IDLE_PINNING:-0}"
  case "$CPU_IDLE_PINNING" in
    0|1) ;;
    *) die "${scenario_file}: CPU_IDLE_PINNING must be 0 or 1" ;;
  esac
  # Spot is opt-in and AWS-only: STACKIT has no spot market. Keep every arm of a
  # comparison on one purchasing model -- spot draws from spare capacity, so it
  # influences which physical host you land on, and host draw is not a free
  # variable at the effect sizes measured here.
  USE_SPOT="${USE_SPOT:-0}"
  case "$USE_SPOT" in
    0|1) ;;
    *) die "${scenario_file}: USE_SPOT must be 0 or 1" ;;
  esac
  if [[ "$USE_SPOT" == "1" && "$PROVIDER" != "aws" ]]; then
    die "${scenario_file}: USE_SPOT=1 is only supported for PROVIDER=aws"
  fi
  BENCHMARK_ROOT_VOLUME_SIZE_GIB="${BENCHMARK_ROOT_VOLUME_SIZE_GIB:-30}"
  BENCHMARK_ROOT_VOLUME_PERFORMANCE_CLASS="${BENCHMARK_ROOT_VOLUME_PERFORMANCE_CLASS:-}"

  TOFU_DIR="$(abs_path "$TOFU_DIR")"
  TFVARS_FILE="$(abs_path "$TFVARS_FILE")"
  BENCHMARK_DIR="$(abs_path "$BENCHMARK_DIR")"
  require_dir "$TOFU_DIR"
  require_dir "$BENCHMARK_DIR"
  if [[ "$DRY_RUN" -ne 1 ]]; then
    require_file "$TFVARS_FILE"
  fi

  log "scenario ${SCENARIO_NAME}"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "  status=planned"
    echo "  provider=${PROVIDER}"
    echo "  tofu_dir=${TOFU_DIR}"
    echo "  tfvars_file=${TFVARS_FILE}"
    if [[ -f "$TFVARS_FILE" ]]; then
      echo "  tfvars_exists=1"
    else
      echo "  tfvars_exists=0"
    fi
    echo "  benchmark_dir=${BENCHMARK_DIR}"
    echo "  os_tuning=${OS_TUNING}"
    echo "  cpu_idle_pinning=${CPU_IDLE_PINNING}"
    echo "  use_spot=${USE_SPOT}"
    echo "  benchmark_machine_type=${BENCHMARK_MACHINE_TYPE}"
    echo "  benchmark_image_id=${BENCHMARK_IMAGE_ID}"
    echo "  block_volume_size_gib=${BLOCK_VOLUME_SIZE_GIB}"
    [[ -n "$BLOCK_VOLUME_PERFORMANCE_CLASS" ]] && echo "  block_volume_performance_class=${BLOCK_VOLUME_PERFORMANCE_CLASS}"
    [[ -n "$BLOCK_VOLUME_TYPE" ]] && echo "  block_volume_type=${BLOCK_VOLUME_TYPE}"
    [[ -n "$BLOCK_VOLUME_IOPS" ]] && echo "  block_volume_iops=${BLOCK_VOLUME_IOPS}"
    [[ -n "$BLOCK_VOLUME_THROUGHPUT_MBPS" ]] && echo "  block_volume_throughput_mbps=${BLOCK_VOLUME_THROUGHPUT_MBPS}"
    echo "  local_filesystem=${LOCAL_FILESYSTEM}"
    echo "  block_filesystem=${BLOCK_FILESYSTEM}"
    echo "  access_mode=${ACCESS_MODE}"
    echo "  destroy=${DESTROY_MODE}"
    if [[ "${#BENCHMARK_NAMES[@]}" -gt 0 ]]; then
      echo "  benchmarks=${BENCHMARK_NAMES[*]}"
    else
      echo "  benchmarks=all non-skipped files"
    fi
    return 0
  fi

  local setup_rc=0
  local bench_rc=0
  local fetch_rc=0
  local destroy_rc=0
  local benchmark_args=()
  local merged_tfvars=""
  local name
  for name in "${BENCHMARK_NAMES[@]}"; do
    benchmark_args+=(--benchmark "$name")
  done

  merged_tfvars="$(mktemp /tmp/cloud-measuring-storage-tfvars.XXXXXX.tfvars)"
  cp "$TFVARS_FILE" "$merged_tfvars"
  apply_tfvar_overlay "$merged_tfvars" "benchmark_machine_type" "\"${BENCHMARK_MACHINE_TYPE}\""
  apply_tfvar_overlay "$merged_tfvars" "benchmark_image_id" "\"${BENCHMARK_IMAGE_ID}\""
  apply_tfvar_overlay "$merged_tfvars" "benchmark_block_volume_size_gib" "${BLOCK_VOLUME_SIZE_GIB}"
  apply_tfvar_overlay "$merged_tfvars" "benchmark_block_volume_performance_class" "\"${BLOCK_VOLUME_PERFORMANCE_CLASS}\""
  [[ -n "$BLOCK_VOLUME_TYPE" ]] && apply_tfvar_overlay "$merged_tfvars" "benchmark_block_volume_type" "\"${BLOCK_VOLUME_TYPE}\""
  [[ -n "$BLOCK_VOLUME_IOPS" ]] && apply_tfvar_overlay "$merged_tfvars" "benchmark_block_volume_iops" "${BLOCK_VOLUME_IOPS}"
  [[ -n "$BLOCK_VOLUME_THROUGHPUT_MBPS" ]] && apply_tfvar_overlay "$merged_tfvars" "benchmark_block_volume_throughput_mbps" "${BLOCK_VOLUME_THROUGHPUT_MBPS}"
  # use_spot_instances is declared type = bool, and OpenTofu rejects a number
  # there ("Invalid value for input variable") rather than coercing it, so the
  # 0/1 scenario flag has to become a bool literal. The other bool overlays in
  # this file and in network/runner.sh already write true/false directly.
  if [[ "$PROVIDER" == "aws" ]]; then
    local use_spot_literal="false"
    [[ "$USE_SPOT" == "1" ]] && use_spot_literal="true"
    apply_tfvar_overlay "$merged_tfvars" "use_spot_instances" "$use_spot_literal"
  fi
  apply_tfvar_overlay "$merged_tfvars" "benchmark_local_filesystem" "\"${LOCAL_FILESYSTEM}\""
  apply_tfvar_overlay "$merged_tfvars" "benchmark_block_filesystem" "\"${BLOCK_FILESYSTEM}\""
  apply_tfvar_overlay "$merged_tfvars" "benchmark_root_volume_size_gib" "${BENCHMARK_ROOT_VOLUME_SIZE_GIB}"
  apply_tfvar_overlay "$merged_tfvars" "benchmark_root_volume_performance_class" "\"${BENCHMARK_ROOT_VOLUME_PERFORMANCE_CLASS}\""
  if [[ "$ACCESS_MODE" == "private" ]]; then
    apply_tfvar_overlay "$merged_tfvars" "assign_public_ip" "false"
  fi
  # Persist the overlaid values next to the run's artifacts before provisioning.
  # The merged file is a temp file removed when this function returns, and the
  # scenario's required variables (benchmark_machine_type, benchmark_image_id)
  # exist only in the overlay -- so after a failed apply there is nothing left
  # that can destroy what was created, and cleanup means reconstructing them by
  # hand. This file is exactly what was applied, which also makes it provenance.
  local persisted_tfvars="${LOCAL_RUN_DIR}/${SCENARIO_NAME}.tfvars"
  mkdir -p "$LOCAL_RUN_DIR"
  cp "$merged_tfvars" "$persisted_tfvars"
  trap 'rm -f "${merged_tfvars:-}"' RETURN

  "${SCRIPT_DIR}/scripts/setup_infra.sh" --tofu-dir "$TOFU_DIR" --tfvars-file "$merged_tfvars" || setup_rc=$?

  if [[ "$setup_rc" -eq 0 ]]; then
    "${SCRIPT_DIR}/scripts/run_benchmarks.sh" \
      --tofu-dir "$TOFU_DIR" \
      --scenario-name "$SCENARIO_NAME" \
      --benchmark-dir "$BENCHMARK_DIR" \
      --os-tuning "$OS_TUNING" \
      --cpu-idle-pinning "$CPU_IDLE_PINNING" \
      --use-spot "$USE_SPOT" \
      --access-mode "$ACCESS_MODE" \
      --local-filesystem "$LOCAL_FILESYSTEM" \
      --block-filesystem "$BLOCK_FILESYSTEM" \
      --local-log-dir "$LOCAL_RUN_DIR" \
      --run-id "$RUN_ID" \
      "${benchmark_args[@]}" || bench_rc=$?

    "${SCRIPT_DIR}/scripts/fetch_results.sh" \
      --tofu-dir "$TOFU_DIR" \
      --scenario-name "$SCENARIO_NAME" \
      --run-id "$RUN_ID" \
      --access-mode "$ACCESS_MODE" \
      --out "$LOCAL_OUT" || fetch_rc=$?
  fi

  if [[ "$DESTROY_MODE" == "always" || ( "$DESTROY_MODE" == "success" && "$setup_rc" -eq 0 && "$bench_rc" -eq 0 && "$fetch_rc" -eq 0 ) ]]; then
    "${SCRIPT_DIR}/scripts/destroy_infra.sh" --tofu-dir "$TOFU_DIR" --tfvars-file "$merged_tfvars" || destroy_rc=$?
  fi

  if [[ "$setup_rc" -ne 0 || "$bench_rc" -ne 0 || "$fetch_rc" -ne 0 || "$destroy_rc" -ne 0 ]]; then
    log "scenario ${SCENARIO_NAME} failed: setup=${setup_rc} benchmark=${bench_rc} fetch=${fetch_rc} destroy=${destroy_rc}"
    if [[ "$DESTROY_MODE" != "always" ]] || [[ "$destroy_rc" -ne 0 ]]; then
      log "resources may still exist; clean up with:"
      log "  ./storage/scripts/destroy_infra.sh --tofu-dir ${TOFU_DIR} --tfvars-file ${persisted_tfvars}"
    fi
    return 1
  fi

  log "scenario ${SCENARIO_NAME} completed"
}

apply_tfvar_overlay() {
  local file="$1"
  local key="$2"
  local value="$3"
  local tmp
  tmp="$(mktemp /tmp/cloud-measuring-tfvars-overlay.XXXXXX.tfvars)"

  awk -v key="$key" -v value="$value" '
    BEGIN { replaced = 0 }
    /^[[:space:]]*#/ { print; next }
    /^[[:space:]]*$/ { print; next }
    {
      line = $0
      trimmed = line
      sub(/^[[:space:]]+/, "", trimmed)
      candidate = trimmed
      sub(/[[:space:]]*=.*/, "", candidate)
      if (candidate == key) {
        if (!replaced) {
          printf "%s = %s\n", key, value
          replaced = 1
        }
        next
      }
      print
    }
    END {
      if (!replaced) {
        printf "%s = %s\n", key, value
      }
    }
  ' "$file" >"$tmp"

  mv "$tmp" "$file"
}

LOCAL_RUN_DIR="$(abs_path "${LOCAL_OUT}/${RUN_ID}")"
mkdir -p "$LOCAL_RUN_DIR"
LOCAL_LAUNCHER_LOG="${LOCAL_RUN_DIR}/launcher.log"
LOCAL_COMMAND_LOG="${LOCAL_RUN_DIR}/commands.log"
: >"$LOCAL_LAUNCHER_LOG"
: >"$LOCAL_COMMAND_LOG"
exec > >(tee -a "$LOCAL_LAUNCHER_LOG") 2>&1
log "launcher log: ${LOCAL_LAUNCHER_LOG}"
# Report a run that has stopped writing anything. Per-step bounds cover the
# benchmark invocations; this covers the phases where no legitimate duration is
# known -- provisioning, fetch, teardown -- and where killing on a timer would
# be wrong. Started after the log exists so the first check has something to
# stat, and stopped on exit so it cannot outlive the run.
STALE_WATCHDOG_PID="$(start_stale_watchdog "$LOCAL_LAUNCHER_LOG")"
trap 'stop_stale_watchdog "${STALE_WATCHDOG_PID:-}"' EXIT
log "command log: ${LOCAL_COMMAND_LOG}"

overall_rc=0
for scenario in "${SCENARIO_FILES[@]}"; do
  if ! run_scenario "$scenario"; then
    overall_rc=1
    if [[ "$CONTINUE_ON_ERROR" -ne 1 ]]; then
      break
    fi
  fi
done

if [[ "$overall_rc" -ne 0 ]]; then
  exit 1
fi
