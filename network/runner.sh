#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
source "${REPO_ROOT}/common/scripts/common.sh"

declare -a SCENARIO_FILES=()
declare -a BENCHMARK_NAMES=()
SCENARIO_DIR=""
LOCAL_OUT="artifacts/network"
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
  SCENARIO_FILES+=("network/scenarios/stackit/baseline.sh")
fi

run_scenario() {
  local scenario_file="$1"
  scenario_file="$(abs_path "$scenario_file")"
  require_file "$scenario_file"

  unset SCENARIO_NAME PROVIDER TOFU_DIR TFVARS_FILE BENCHMARK_DIR PLACEMENT_MODE OS_TUNING INSTANCE_AFFINITY CLIENT_MACHINE_TYPE SERVER_MACHINE_TYPE CLIENT_AVAILABILITY_ZONE SERVER_AVAILABILITY_ZONE SERVER_REGION ENABLE_TIER1_NETWORKING SKIP SKIP_REASON
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
    stackit|aws|gcp) ;;
    *) die "${scenario_file}: PROVIDER must be one of: stackit, aws, gcp" ;;
  esac
  [[ -n "${TOFU_DIR:-}" ]] || die "${scenario_file}: TOFU_DIR is required"
  [[ -n "${TFVARS_FILE:-}" ]] || die "${scenario_file}: TFVARS_FILE is required"
  BENCHMARK_DIR="${BENCHMARK_DIR:-network/benchmarks}"
  OS_TUNING="${OS_TUNING:-standard}"
  INSTANCE_AFFINITY="${INSTANCE_AFFINITY:-none}"
  CLIENT_MACHINE_TYPE="${CLIENT_MACHINE_TYPE:-}"
  SERVER_MACHINE_TYPE="${SERVER_MACHINE_TYPE:-}"
  CLIENT_AVAILABILITY_ZONE="${CLIENT_AVAILABILITY_ZONE:-}"
  SERVER_AVAILABILITY_ZONE="${SERVER_AVAILABILITY_ZONE:-}"
  case "$OS_TUNING" in
    standard|network-throughput) ;;
    *) die "${scenario_file}: OS_TUNING must be one of: standard, network-throughput" ;;
  esac
  case "$INSTANCE_AFFINITY" in
    none|co-located|different-host) ;;
    *) die "${scenario_file}: INSTANCE_AFFINITY must be one of: none, co-located, different-host" ;;
  esac
  if [[ -n "$CLIENT_MACHINE_TYPE" || -n "$SERVER_MACHINE_TYPE" || -n "$CLIENT_AVAILABILITY_ZONE" || -n "$SERVER_AVAILABILITY_ZONE" ]]; then
    [[ -n "$CLIENT_MACHINE_TYPE" && -n "$SERVER_MACHINE_TYPE" && -n "$CLIENT_AVAILABILITY_ZONE" && -n "$SERVER_AVAILABILITY_ZONE" ]] || die "${scenario_file}: client/server machine types and availability zones must be set together"
  fi

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
    echo "  placement_mode=${PLACEMENT_MODE:-}"
    echo "  os_tuning=${OS_TUNING}"
    echo "  instance_affinity=${INSTANCE_AFFINITY}"
    [[ -n "$CLIENT_MACHINE_TYPE" ]] && echo "  client_machine_type=${CLIENT_MACHINE_TYPE}"
    [[ -n "$SERVER_MACHINE_TYPE" ]] && echo "  server_machine_type=${SERVER_MACHINE_TYPE}"
    [[ -n "$CLIENT_AVAILABILITY_ZONE" ]] && echo "  client_availability_zone=${CLIENT_AVAILABILITY_ZONE}"
    [[ -n "$SERVER_AVAILABILITY_ZONE" ]] && echo "  server_availability_zone=${SERVER_AVAILABILITY_ZONE}"
    if [[ "${#BENCHMARK_NAMES[@]}" -gt 0 ]]; then
    echo "  benchmarks=${BENCHMARK_NAMES[*]}"
  else
    echo "  benchmarks=all non-skipped files"
  fi
    echo "  access_mode=${ACCESS_MODE}"
    echo "  destroy=${DESTROY_MODE}"
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

  merged_tfvars="$(mktemp /tmp/cloud-measuring-tfvars.XXXXXX.tfvars)"
  cp "$TFVARS_FILE" "$merged_tfvars"
  apply_tfvar_overlay "$merged_tfvars" "instance_affinity" "\"${INSTANCE_AFFINITY}\""
  if [[ "$ACCESS_MODE" == "private" ]]; then
    apply_tfvar_overlay "$merged_tfvars" "assign_public_ip" "false"
  fi
  if [[ -n "$CLIENT_MACHINE_TYPE" ]]; then
    apply_tfvar_overlay "$merged_tfvars" "client_machine_type" "\"${CLIENT_MACHINE_TYPE}\""
    apply_tfvar_overlay "$merged_tfvars" "server_machine_type" "\"${SERVER_MACHINE_TYPE}\""
    apply_tfvar_overlay "$merged_tfvars" "client_availability_zone" "\"${CLIENT_AVAILABILITY_ZONE}\""
    apply_tfvar_overlay "$merged_tfvars" "server_availability_zone" "\"${SERVER_AVAILABILITY_ZONE}\""
  fi
  if [[ -n "${ENABLE_TIER1_NETWORKING:-}" ]]; then
    apply_tfvar_overlay "$merged_tfvars" "enable_tier1_networking" "${ENABLE_TIER1_NETWORKING}"
  fi
  if [[ -n "${SERVER_REGION:-}" ]]; then
    apply_tfvar_overlay "$merged_tfvars" "server_region" "\"${SERVER_REGION}\""
  fi
  trap 'rm -f "${merged_tfvars:-}"' RETURN

  "${SCRIPT_DIR}/scripts/setup_infra.sh" --tofu-dir "$TOFU_DIR" --tfvars-file "$merged_tfvars" || setup_rc=$?

  if [[ "$setup_rc" -eq 0 ]]; then
    "${SCRIPT_DIR}/scripts/run_benchmarks.sh" \
      --tofu-dir "$TOFU_DIR" \
      --scenario-name "$SCENARIO_NAME" \
      --benchmark-dir "$BENCHMARK_DIR" \
      --os-tuning "$OS_TUNING" \
      --instance-affinity "$INSTANCE_AFFINITY" \
      --access-mode "$ACCESS_MODE" \
      --local-log-dir "$LOCAL_RUN_DIR" \
      --run-id "$RUN_ID" \
      ${SERVER_REGION:+--server-region "$SERVER_REGION"} \
      ${PLACEMENT_MODE:+--placement-mode "$PLACEMENT_MODE"} \
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

if [[ "$DRY_RUN" -eq 1 ]]; then
  log "dry run complete"
else
  log "run id: ${RUN_ID}"
  log "local output root: $(abs_path "$LOCAL_OUT")/${RUN_ID}"
fi

exit "$overall_rc"
