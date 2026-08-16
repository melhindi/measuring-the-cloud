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
# Re-run the first executed scenario at the end of the matrix under a __control
# label. The difference between the two is the drift of the apparatus over the
# run, which is the noise floor any reported effect has to clear. A long matrix
# has no other way to detect that its arms were not comparable in time.
REVERSAL_CONTROL=0
FIRST_EXECUTED_SCENARIO=""
SCENARIO_NAME_SUFFIX=""
# Sample mpstat/iostat/nstat/ss during each repetition.
#
# On by default. It was opt-in while the samplers ran unrestricted, because they
# could be scheduled onto the core running the benchmark; they are now pinned to
# CPU 0, which benchmarks never use, so the cost to the measurement is close to
# nil and the cost of not having it is high. ss -tinH carries the TCP
# retransmit, congestion-window and receive-queue state that is the only way to
# explain a tail-latency difference rather than merely report one -- and it
# cannot be recovered after the fact, because the instances are destroyed at the
# end of the run. Use --no-telemetry to opt out.
COLLECT_TELEMETRY=1
RUN_ID="run-$(date +%Y%m%d-%H%M%S)"
LOCAL_RUN_DIR=""
LOCAL_LAUNCHER_LOG=""
LOCAL_COMMAND_LOG=""

usage() {
  cat >&2 <<USAGE
usage: $0 [--scenario FILE ... | --scenario-dir DIR] [--benchmark NAME ...] [--out DIR] [--destroy always|success|never] [--continue-on-error] [--dry-run] [--reversal-control] [--no-telemetry] [--access-mode public|private]
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
    --reversal-control) REVERSAL_CONTROL=1; shift ;;
    --collect-telemetry) COLLECT_TELEMETRY=1; shift ;;
    --no-telemetry) COLLECT_TELEMETRY=0; shift ;;
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

# Validate the whole selection before provisioning anything.
preflight_scenarios "$REPO_ROOT" "${SCENARIO_FILES[@]}"

run_scenario() {
  local scenario_file="$1"
  scenario_file="$(abs_path "$scenario_file")"
  require_file "$scenario_file"

  unset SCENARIO_NAME PROVIDER TOFU_DIR TFVARS_FILE BENCHMARK_DIR PLACEMENT_MODE OS_TUNING INSTANCE_AFFINITY CLIENT_MACHINE_TYPE SERVER_MACHINE_TYPE CLIENT_AVAILABILITY_ZONE SERVER_AVAILABILITY_ZONE CLIENT_REGION SERVER_REGION ENABLE_TIER1_NETWORKING CPU_IDLE_PINNING USE_SPOT SKIP SKIP_REASON
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
  # The control arm is the same scenario under a distinct name so it lands in its
  # own artifact directory and appears as its own row in the analysis.
  if [[ -n "$SCENARIO_NAME_SUFFIX" ]]; then
    SCENARIO_NAME="${SCENARIO_NAME}${SCENARIO_NAME_SUFFIX}"
  fi
  if [[ -z "$FIRST_EXECUTED_SCENARIO" ]]; then
    FIRST_EXECUTED_SCENARIO="$scenario_file"
  fi
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
  # Orthogonal to OS_TUNING rather than another value of it, so CPU idle
  # behaviour can be crossed with the network profiles instead of replacing one.
  CPU_IDLE_PINNING="${CPU_IDLE_PINNING:-0}"
  case "$CPU_IDLE_PINNING" in
    0|1) ;;
    *) die "${scenario_file}: CPU_IDLE_PINNING must be 0 or 1" ;;
  esac
  # Off by default and AWS-only: spot is implemented for the AWS module, and
  # STACKIT has no spot market at all. Rejected rather than ignored elsewhere.
  USE_SPOT="${USE_SPOT:-0}"
  case "$USE_SPOT" in
    0|1) ;;
    *) die "${scenario_file}: USE_SPOT must be 0 or 1" ;;
  esac
  if [[ "$USE_SPOT" == "1" && "$PROVIDER" != "aws" ]]; then
    die "${scenario_file}: USE_SPOT=1 is only supported for PROVIDER=aws"
  fi
  if [[ "$USE_SPOT" == "1" && "$INSTANCE_AFFINITY" == "co-located" ]]; then
    # Not fatal, but this is the combination most likely to fail to launch:
    # a cluster placement group needs capacity for both instances on one rack,
    # which spare capacity frequently cannot satisfy.
    log "warning: ${SCENARIO_NAME} combines USE_SPOT=1 with a cluster placement group; expect launch failures"
  fi
  if [[ -n "$CLIENT_MACHINE_TYPE" || -n "$SERVER_MACHINE_TYPE" || -n "$CLIENT_AVAILABILITY_ZONE" || -n "$SERVER_AVAILABILITY_ZONE" ]]; then
    [[ -n "$CLIENT_MACHINE_TYPE" && -n "$SERVER_MACHINE_TYPE" && -n "$CLIENT_AVAILABILITY_ZONE" && -n "$SERVER_AVAILABILITY_ZONE" ]] || die "${scenario_file}: client/server machine types and availability zones must be set together"
  fi

  assert_zone_in_region "${scenario_file} (client)" "${CLIENT_REGION:-}" "${CLIENT_AVAILABILITY_ZONE:-}"
  assert_zone_in_region "${scenario_file} (server)" "${SERVER_REGION:-}" "${SERVER_AVAILABILITY_ZONE:-}"

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
    echo "  cpu_idle_pinning=${CPU_IDLE_PINNING}"
    echo "  use_spot=${USE_SPOT}"
    [[ -n "$CLIENT_MACHINE_TYPE" ]] && echo "  client_machine_type=${CLIENT_MACHINE_TYPE}"
    [[ -n "$SERVER_MACHINE_TYPE" ]] && echo "  server_machine_type=${SERVER_MACHINE_TYPE}"
    [[ -n "$CLIENT_AVAILABILITY_ZONE" ]] && echo "  client_availability_zone=${CLIENT_AVAILABILITY_ZONE}"
    [[ -n "$SERVER_AVAILABILITY_ZONE" ]] && echo "  server_availability_zone=${SERVER_AVAILABILITY_ZONE}"
    [[ -n "${CLIENT_REGION:-}" ]] && echo "  client_region=${CLIENT_REGION}"
    [[ -n "${SERVER_REGION:-}" ]] && echo "  server_region=${SERVER_REGION}"
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
  # A bool literal, not 0/1: use_spot_instances is declared type = bool and
  # OpenTofu rejects a number there rather than coercing it.
  if [[ "$PROVIDER" == "aws" ]]; then
    local use_spot_literal="false"
    [[ "$USE_SPOT" == "1" ]] && use_spot_literal="true"
    apply_tfvar_overlay "$merged_tfvars" "use_spot_instances" "$use_spot_literal"
  fi
  if [[ "$ACCESS_MODE" == "private" ]]; then
    apply_tfvar_overlay "$merged_tfvars" "assign_public_ip" "false"
  fi
  if [[ -n "$CLIENT_MACHINE_TYPE" ]]; then
    apply_tfvar_overlay "$merged_tfvars" "client_machine_type" "\"${CLIENT_MACHINE_TYPE}\""
    apply_tfvar_overlay "$merged_tfvars" "server_machine_type" "\"${SERVER_MACHINE_TYPE}\""
    apply_tfvar_overlay "$merged_tfvars" "client_availability_zone" "\"${CLIENT_AVAILABILITY_ZONE}\""
    apply_tfvar_overlay "$merged_tfvars" "server_availability_zone" "\"${SERVER_AVAILABILITY_ZONE}\""
  fi
  # The client's region, which unlike server_region is spelled differently by
  # each provider's module and so cannot be overlaid under one name.
  #
  # Without this a scenario can only use zones inside whatever region its tfvars
  # happens to name, and the tfvars is shared by every scenario for that
  # provider. Moving one scenario to another region then means either editing
  # the shared file -- silently relocating every other scenario that reads it --
  # or maintaining a second near-identical copy.
  #
  # AWS images are region-scoped, so an AWS scenario setting this must also
  # point image_id at an AMI in the new region; GCP and OpenStack images are
  # global and need no such care. That asymmetry is why the existing
  # eu-central-1 AWS scenarios cannot simply be pointed at the us-east-1
  # baseline.
  if [[ -n "${CLIENT_REGION:-}" ]]; then
    local client_region_var=""
    case "$PROVIDER" in
      aws) client_region_var="aws_region" ;;
      gcp) client_region_var="gcp_region" ;;
      stackit) client_region_var="stackit_region" ;;
      *) die "${SCENARIO_NAME}: CLIENT_REGION is not supported for provider ${PROVIDER}" ;;
    esac
    apply_tfvar_overlay "$merged_tfvars" "$client_region_var" "\"${CLIENT_REGION}\""
  fi
  if [[ -n "${SERVER_REGION:-}" ]]; then
    apply_tfvar_overlay "$merged_tfvars" "server_region" "\"${SERVER_REGION}\""
  fi
  if [[ -n "${ENABLE_TIER1_NETWORKING:-}" ]]; then
    apply_tfvar_overlay "$merged_tfvars" "enable_tier1_networking" "${ENABLE_TIER1_NETWORKING}"
  fi
  # Persist the overlaid values next to the run's artifacts; see the equivalent
  # note in storage/runner.sh. Without this, cleanup after a failed apply has to
  # reconstruct the overlay by hand.
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
      --instance-affinity "$INSTANCE_AFFINITY" \
      --cpu-idle-pinning "$CPU_IDLE_PINNING" \
      --use-spot "$USE_SPOT" \
      --collect-telemetry "$COLLECT_TELEMETRY" \
      --access-mode "$ACCESS_MODE" \
      ${SERVER_REGION:+--server-region "$SERVER_REGION"} \
      ${PLACEMENT_MODE:+--placement-mode "$PLACEMENT_MODE"} \
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
      log "  ./network/scripts/destroy_infra.sh --tofu-dir ${TOFU_DIR} --tfvars-file ${persisted_tfvars}"
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

if [[ "$REVERSAL_CONTROL" -eq 1 ]]; then
  if [[ -z "$FIRST_EXECUTED_SCENARIO" ]]; then
    log "reversal control requested but no scenario executed; skipping"
  elif [[ "${#SCENARIO_FILES[@]}" -lt 2 ]]; then
    log "reversal control requested for a single scenario; skipping (nothing to bracket)"
  else
    log "running reversal control: re-running $(basename "$FIRST_EXECUTED_SCENARIO") as __control"
    SCENARIO_NAME_SUFFIX="__control"
    if ! run_scenario "$FIRST_EXECUTED_SCENARIO"; then
      overall_rc=1
    fi
    SCENARIO_NAME_SUFFIX=""
    log "compare the __control arm against its original before quoting any per-arm difference"
  fi
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  log "dry run complete"
else
  log "run id: ${RUN_ID}"
  log "local output root: $(abs_path "$LOCAL_OUT")/${RUN_ID}"
fi

exit "$overall_rc"
