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
INSTANCE_AFFINITY="none"
CPU_IDLE_PINNING="0"
USE_SPOT="0"
# Repetitions that fail are recorded and skipped rather than aborting the
# scenario; this counts them so the scenario still reports failure at the end.
BENCHMARK_FAILURES=0
COLLECT_TELEMETRY="0"
TELEMETRY_INTERVAL_SEC="1"
SERVER_REGION=""
PLACEMENT_MODE=""
LOCAL_LOG_DIR=""
REMOTE_RESULTS_ROOT="/opt/cloud-measuring/results"
ACCESS_MODE="public"
declare -a BENCHMARK_NAMES=()

usage() {
  cat >&2 <<USAGE
usage: $0 --tofu-dir PATH --scenario-name NAME --benchmark-dir PATH --run-id ID [--local-log-dir PATH] [--os-tuning standard|network-throughput] [--instance-affinity none|co-located|different-host] [--access-mode public|private] [--server-region REGION] [--placement-mode MODE] [--benchmark NAME]
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
    --instance-affinity) INSTANCE_AFFINITY="$2"; shift 2 ;;
    --cpu-idle-pinning) CPU_IDLE_PINNING="$2"; shift 2 ;;
    --use-spot) USE_SPOT="$2"; shift 2 ;;
    --collect-telemetry) COLLECT_TELEMETRY="$2"; shift 2 ;;
    --telemetry-interval-sec) TELEMETRY_INTERVAL_SEC="$2"; shift 2 ;;
    --server-region) SERVER_REGION="$2"; shift 2 ;;
    --placement-mode) PLACEMENT_MODE="$2"; shift 2 ;;
    --access-mode) ACCESS_MODE="$2"; shift 2 ;;
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
case "$OS_TUNING" in
  standard|network-throughput) ;;
  *) die "--os-tuning must be one of: standard, network-throughput" ;;
esac
case "$INSTANCE_AFFINITY" in
  none|co-located|different-host) ;;
  *) die "--instance-affinity must be one of: none, co-located, different-host" ;;
esac
case "$ACCESS_MODE" in
  public|private) ;;
  *) die "--access-mode must be one of: public, private" ;;
esac
case "$CPU_IDLE_PINNING" in
  0|1) ;;
  *) die "--cpu-idle-pinning must be 0 or 1" ;;
esac
case "$USE_SPOT" in
  0|1) ;;
  *) die "--use-spot must be 0 or 1" ;;
esac
case "$COLLECT_TELEMETRY" in
  0|1) ;;
  *) die "--collect-telemetry must be 0 or 1" ;;
esac
[[ "$TELEMETRY_INTERVAL_SEC" =~ ^[0-9]+$ ]] || die "--telemetry-interval-sec must be an integer"

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
CLIENT_PRIVATE_IP="$(tofu_output_raw "$tofu" "$TOFU_DIR" client_private_ip)"
SERVER_PRIVATE_IP="$(tofu_output_raw "$tofu" "$TOFU_DIR" server_private_ip)"
SSH_KEY="$(expand_home "$(tofu_output_raw "$tofu" "$TOFU_DIR" ssh_private_key_path)")"
SSH_USER="$(tofu_output_raw "$tofu" "$TOFU_DIR" ssh_user)"
CLIENT_MACHINE_TYPE="$(tofu_output_raw "$tofu" "$TOFU_DIR" client_machine_type)"
SERVER_MACHINE_TYPE="$(tofu_output_raw "$tofu" "$TOFU_DIR" server_machine_type)"
CLIENT_AVAILABILITY_ZONE="$(tofu_output_raw "$tofu" "$TOFU_DIR" client_availability_zone)"
SERVER_AVAILABILITY_ZONE="$(tofu_output_raw "$tofu" "$TOFU_DIR" server_availability_zone)"
PLACEMENT_GROUP_NAME="$("$tofu" -chdir="$TOFU_DIR" output -raw placement_group_name 2>/dev/null || true)"
PLACEMENT_GROUP_STRATEGY="$("$tofu" -chdir="$TOFU_DIR" output -raw placement_group_strategy 2>/dev/null || true)"
require_file "$SSH_KEY"

REMOTE_SCENARIO_DIR="${REMOTE_RESULTS_ROOT}/${RUN_ID}/${SCENARIO_NAME}"
REMOTE_BIN_DIR="/opt/cloud-measuring/bin"
CLIENT_CPU_LIST=""
SERVER_CPU_LIST=""
KNOWN_HOSTS_FILE=""

if [[ "$ACCESS_MODE" == "private" ]]; then
  CLIENT_SSH_HOST="$CLIENT_PRIVATE_IP"
  SERVER_SSH_HOST="$SERVER_PRIVATE_IP"
else
  CLIENT_PUBLIC_IP="$(tofu_output_raw "$tofu" "$TOFU_DIR" client_public_ip)"
  SERVER_PUBLIC_IP="$(tofu_output_raw "$tofu" "$TOFU_DIR" server_public_ip)"
  CLIENT_SSH_HOST="$CLIENT_PUBLIC_IP"
  SERVER_SSH_HOST="$SERVER_PUBLIC_IP"
fi

if [[ -n "$LOCAL_LOG_DIR" ]]; then
  KNOWN_HOSTS_FILE="${LOCAL_LOG_DIR}/known_hosts"
  : >"$KNOWN_HOSTS_FILE"
fi

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

  local stdout_file
  local stderr_file
  local rc
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
  local host="$1"
  local label="$2"
  local attempt
  log "waiting for ${label} SSH to be ready"
  for attempt in $(seq 1 90); do
    if ssh_run "$host" "true" >/dev/null 2>&1; then
      log "${label} SSH is ready"
      return 0
    fi
    if (( attempt % 10 == 0 )); then
      log "still waiting for ${label} SSH to be ready (${attempt}/90 attempts)"
    fi
    sleep 2
  done
  die "${label} SSH did not become ready: ${host}"
}

wait_for_cloud_init() {
  local host="$1"
  local label="$2"
  local attempt
  log "waiting for cloud-init ${label} setup to finish"
  for attempt in $(seq 1 180); do
    if ssh_run "$host" "cloud-init status 2>/dev/null | grep -Eq 'status: done|status: error'"; then
      break
    fi
    if (( attempt % 10 == 0 )); then
      log "still waiting for cloud-init ${label} setup to finish (${attempt}/180 attempts)"
    fi
    sleep 2
  done
  ssh_run "$host" "cloud-init status --wait >/tmp/cloud-init-status.log 2>&1 || (cat /tmp/cloud-init-status.log; exit 1)"
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

validate_common_benchmark() {
  [[ -n "${BENCHMARK_NAME:-}" ]] || die "${benchmark_file}: BENCHMARK_NAME is required"
  [[ "$BENCHMARK_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || die "${benchmark_file}: BENCHMARK_NAME contains unsafe characters"
  [[ "${BENCHMARK_TOOL:-}" == "iperf3" || "${BENCHMARK_TOOL:-}" == "sockperf" ]] || die "${benchmark_file}: BENCHMARK_TOOL must be iperf3 or sockperf"
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
  [[ "$value" =~ ^[0-9]+([KMG])?$ ]] || die "${benchmark_file}: ${name} must be a size with optional K/M/G suffix"
}

remote_cpu_list() {
  local host="$1"
  local n
  n="$(ssh_run "$host" "nproc" | tr -d '\r\n')"
  if [[ "$n" =~ ^[0-9]+$ && "$n" -ge 2 ]]; then
    echo "1-$((n - 1))"
  else
    echo "0"
  fi
}

wait_for_server_ready() {
  local tool="$1"
  local protocol="$2"
  local port="$3"
  local timeout_sec="$4"
  local socket_flag="-H -lnt"
  if [[ "$tool" == "sockperf" && "$protocol" == "udp" ]]; then
    socket_flag="-H -lnu"
  fi

  ssh_run "$SERVER_SSH_HOST" "deadline=\$((SECONDS + ${timeout_sec})); while (( SECONDS < deadline )); do if ss ${socket_flag} 'sport = :${port}' | grep -q .; then exit 0; fi; sleep 0.2; done; ss ${socket_flag} 'sport = :${port}'; exit 1"
}

kill_stale_server() {
  local tool="$1"
  local port="$2"
  case "$tool" in
    iperf3)
      if ! ssh_run "$SERVER_SSH_HOST" "pkill -x iperf3 >/dev/null 2>&1 || true"; then
        log "ignoring stale iperf3 cleanup failure on port ${port}"
      fi
      ;;
    sockperf)
      if ! ssh_run "$SERVER_SSH_HOST" "pkill -x sockperf >/dev/null 2>&1 || true"; then
        log "ignoring stale sockperf cleanup failure on port ${port}"
      fi
      ;;
  esac
}

write_remote_metadata() {
  local tmp
  tmp="$(mktemp /tmp/cloud-measuring-scenario.XXXXXX.env)"
  write_env_file "$tmp" RUN_ID SCENARIO_NAME OS_TUNING INSTANCE_AFFINITY PLACEMENT_GROUP_NAME PLACEMENT_GROUP_STRATEGY ACCESS_MODE CLIENT_PUBLIC_IP SERVER_PUBLIC_IP CLIENT_PRIVATE_IP SERVER_PRIVATE_IP CLIENT_SSH_HOST SERVER_SSH_HOST SSH_USER CLIENT_MACHINE_TYPE SERVER_MACHINE_TYPE CLIENT_AVAILABILITY_ZONE SERVER_AVAILABILITY_ZONE CLIENT_CPU_LIST SERVER_CPU_LIST SERVER_REGION PLACEMENT_MODE CPU_IDLE_PINNING USE_SPOT
  scp_to "$tmp" "$CLIENT_SSH_HOST" "${REMOTE_SCENARIO_DIR}/scenario.env"
  scp_to "$tmp" "$SERVER_SSH_HOST" "${REMOTE_SCENARIO_DIR}/scenario.env"
  rm -f "$tmp"

  local meta_cmd
  meta_cmd="mkdir -p '${REMOTE_SCENARIO_DIR}' && { date -u +%Y-%m-%dT%H:%M:%SZ; hostname; uname -a; lscpu; echo '---LIMITS---'; printf 'ulimit_soft_nofile='; ulimit -Sn; printf 'ulimit_hard_nofile='; ulimit -Hn; cat /proc/\$\$/limits; echo '---NETWORK---'; ip addr; ip route; command -v ethtool >/dev/null 2>&1 && ethtool -i \$(ip route get 1.1.1.1 | awk '/dev/ {for (i=1;i<=NF;i++) if (\$i==\"dev\") print \$(i+1); exit}') || true; echo '---TOOLS---'; fio --version || true; iperf3 --version 2>/dev/null | head -n1 || true; bash -lc 'ulimit -Hn 32768 2>/dev/null || true; ulimit -Sn 32768 2>/dev/null || true; sockperf --version' || true; } >'${REMOTE_SCENARIO_DIR}/node-meta.log' 2>&1"
  ssh_run "$CLIENT_SSH_HOST" "$meta_cmd"
  ssh_run "$SERVER_SSH_HOST" "$meta_cmd"

  # Structured counterpart to node-meta.log. The client copy sits next to
  # scenario.env where the parser overlays it; the server copy is fetched into
  # server/ by fetch_results.sh.
  local facts_cmd
  facts_cmd="'${REMOTE_BIN_DIR}/collect-node-facts.sh' --out '${REMOTE_SCENARIO_DIR}/node-facts.env'"
  if ! ssh_run "$CLIENT_SSH_HOST" "$facts_cmd"; then
    log "ignoring node-facts collection failure on client"
  fi
  if ! ssh_run "$SERVER_SSH_HOST" "$facts_cmd"; then
    log "ignoring node-facts collection failure on server"
  fi
}

apply_os_tuning() {
  local host="$1"
  local label="$2"
  log "applying OS tuning profile '${OS_TUNING}' on ${label}"
  # The tuning script is shipped by push_remote_scripts, not baked into the
  # image, so this must run after it.
  ssh_run "$host" "mkdir -p '${REMOTE_SCENARIO_DIR}' && sudo '${REMOTE_BIN_DIR}/apply-os-tuning.sh' '${OS_TUNING}' --facts-out '${REMOTE_SCENARIO_DIR}/os-tuning.env' >'${REMOTE_SCENARIO_DIR}/os-tuning.log' 2>&1"
}

push_remote_scripts() {
  local host="$1"
  ssh_run "$host" "mkdir -p '${REMOTE_BIN_DIR}' '${REMOTE_SCENARIO_DIR}'"
  scp_to "${REPO_ROOT}/network/remote/run_iperf.sh" "$host" "${REMOTE_BIN_DIR}/run_iperf.sh"
  scp_to "${REPO_ROOT}/network/remote/run_sockperf.sh" "$host" "${REMOTE_BIN_DIR}/run_sockperf.sh"
  scp_to "${REPO_ROOT}/common/remote/collect-node-facts.sh" "$host" "${REMOTE_BIN_DIR}/collect-node-facts.sh"
  scp_to "${REPO_ROOT}/common/remote/apply-os-tuning.sh" "$host" "${REMOTE_BIN_DIR}/apply-os-tuning.sh"
  scp_to "${REPO_ROOT}/common/remote/cpu-idle-pin.sh" "$host" "${REMOTE_BIN_DIR}/cpu-idle-pin.sh"
  scp_to "${REPO_ROOT}/common/remote/collect-telemetry.sh" "$host" "${REMOTE_BIN_DIR}/collect-telemetry.sh"
  ssh_run "$host" "chmod +x '${REMOTE_BIN_DIR}/run_iperf.sh' '${REMOTE_BIN_DIR}/run_sockperf.sh' '${REMOTE_BIN_DIR}/collect-node-facts.sh' '${REMOTE_BIN_DIR}/apply-os-tuning.sh' '${REMOTE_BIN_DIR}/cpu-idle-pin.sh' '${REMOTE_BIN_DIR}/collect-telemetry.sh'"
}

# System counters sampled for the duration of a repetition, on both hosts.
# Opt-in: it is a small but real extra load on the machine under measurement.
telemetry_start() {
  local remote_rep_dir="$1"
  [[ "$COLLECT_TELEMETRY" == "1" ]] || return 0
  local host role
  for host_role in "${CLIENT_SSH_HOST}:client" "${SERVER_SSH_HOST}:server"; do
    host="${host_role%:*}"
    role="${host_role##*:}"
    ssh_run "$host" "'${REMOTE_BIN_DIR}/collect-telemetry.sh' --action start --out-dir '${remote_rep_dir}/${role}/telemetry' --pid-file '${remote_rep_dir}/${role}/telemetry.pids' --interval ${TELEMETRY_INTERVAL_SEC}" >/dev/null 2>&1 || true
  done
}

telemetry_stop() {
  local remote_rep_dir="$1"
  [[ "$COLLECT_TELEMETRY" == "1" ]] || return 0
  local host role
  for host_role in "${CLIENT_SSH_HOST}:client" "${SERVER_SSH_HOST}:server"; do
    host="${host_role%:*}"
    role="${host_role##*:}"
    ssh_run "$host" "'${REMOTE_BIN_DIR}/collect-telemetry.sh' --action stop --pid-file '${remote_rep_dir}/${role}/telemetry.pids'" >/dev/null 2>&1 || true
  done
}

# CPU idle-state control. Always probed and always recorded, whether or not the
# scenario asked for pinning and whether or not the instance supports it, so the
# analysis can separate "pinned" from "could not pin" instead of pooling them.
cpu_idle_facts_path() {
  local role="$1"
  printf '%s/cpu-idle-%s.env' "$REMOTE_SCENARIO_DIR" "$role"
}

# start/stop run whether or not this scenario asked for pinning. An unpinned
# scenario still snapshots the idle counters, and its delta is the baseline that
# says whether deep idle was being entered at all -- without which a pinned
# run's zero is not interpretable.
cpu_idle_start() {
  local host="$1"
  local role="$2"
  log "cpu-idle start on ${role} (requested pinning=${CPU_IDLE_PINNING})"
  if ! ssh_run "$host" "sudo '${REMOTE_BIN_DIR}/cpu-idle-pin.sh' --action start --pin '${CPU_IDLE_PINNING}' --out '$(cpu_idle_facts_path "$role")' >>'${REMOTE_SCENARIO_DIR}/cpu-idle.log' 2>&1"; then
    log "ignoring cpu-idle start failure on ${role}"
  fi
}

cpu_idle_stop() {
  local host="$1"
  local role="$2"
  if ! ssh_run "$host" "sudo '${REMOTE_BIN_DIR}/cpu-idle-pin.sh' --action stop --pin '${CPU_IDLE_PINNING}' --out '$(cpu_idle_facts_path "$role")' >>'${REMOTE_SCENARIO_DIR}/cpu-idle.log' 2>&1"; then
    log "ignoring cpu-idle stop failure on ${role}"
  fi
}

# Release the bound even if the scenario aborts, so a failed run does not leave
# a VM pinned for whatever runs on it next.
cpu_idle_release_all() {
  cpu_idle_stop "$CLIENT_SSH_HOST" client
  cpu_idle_stop "$SERVER_SSH_HOST" server
}

start_server() {
  local log_path="$1"
  local cmd_path="$2"
  shift 2
  local cmd_text
  local cmd_literal
  cmd_text="$(shell_join "$@")"
  cmd_literal="$(printf '%q' "$cmd_text")"
  ssh_run "$SERVER_SSH_HOST" "mkdir -p '$(dirname "$log_path")'; printf '%s\n' ${cmd_literal} >'${cmd_path}'; nohup ${cmd_text} >'${log_path}' 2>&1 < /dev/null & echo \$! >'${log_path}.pid'"
}

write_benchmark_env() {
  local remote_bench_dir="$1"
  local tmp
  ssh_run "$CLIENT_SSH_HOST" "mkdir -p '${remote_bench_dir}'"
  ssh_run "$SERVER_SSH_HOST" "mkdir -p '${remote_bench_dir}'"
  tmp="$(mktemp /tmp/cloud-measuring-benchmark.XXXXXX.env)"
  write_env_file "$tmp" \
    BENCHMARK_NAME BENCHMARK_TOOL REPETITIONS COOLDOWN_SEC SERVER_READY_TIMEOUT_SEC INSTANCE_AFFINITY \
    IPERF3_PROTOCOL IPERF3_PORT IPERF3_RUNTIME_SEC IPERF3_OMIT_SEC IPERF3_PARALLEL IPERF3_TCP_LENGTH IPERF3_UDP_BITRATE IPERF3_UDP_LENGTH \
    SOCKPERF_PROTOCOL SOCKPERF_MODE SOCKPERF_PORT SOCKPERF_MSG_SIZE SOCKPERF_RUNTIME_SEC SOCKPERF_NOFILE_LIMIT \
    SOCKPERF_MPS SOCKPERF_BURST SOCKPERF_REPLY_EVERY SOCKPERF_FULL_LOG
  scp_to "$tmp" "$CLIENT_SSH_HOST" "${remote_bench_dir}/benchmark.env"
  scp_to "$tmp" "$SERVER_SSH_HOST" "${remote_bench_dir}/benchmark.env"
  rm -f "$tmp"
}

run_one_iperf3_repetition() {
  local remote_rep_dir="$1"
  kill_stale_server iperf3 "$IPERF3_PORT"
  ssh_run "$CLIENT_SSH_HOST" "mkdir -p '${remote_rep_dir}/client'"
  ssh_run "$SERVER_SSH_HOST" "mkdir -p '${remote_rep_dir}/server'"

  start_server "${remote_rep_dir}/server/server.log" "${remote_rep_dir}/server/server.cmd" \
    "${REMOTE_BIN_DIR}/run_iperf.sh" \
    --role server \
    --protocol "$IPERF3_PROTOCOL" \
    --port "$IPERF3_PORT" \
    --cpu-list "$SERVER_CPU_LIST"

  wait_for_server_ready iperf3 "$IPERF3_PROTOCOL" "$IPERF3_PORT" "$SERVER_READY_TIMEOUT_SEC"

  set +e
  SSH_TIMEOUT_SEC="$(step_timeout_sec "$IPERF3_RUNTIME_SEC")"
  ssh_run "$CLIENT_SSH_HOST" "$(shell_join \
    "${REMOTE_BIN_DIR}/run_iperf.sh" \
    --role client \
    --protocol "$IPERF3_PROTOCOL" \
    --server-ip "$SERVER_PRIVATE_IP" \
    --port "$IPERF3_PORT" \
    --runtime-sec "$IPERF3_RUNTIME_SEC" \
    --omit-sec "$IPERF3_OMIT_SEC" \
    --parallel "$IPERF3_PARALLEL" \
    --tcp-length "$IPERF3_TCP_LENGTH" \
    --udp-bitrate "$IPERF3_UDP_BITRATE" \
    --udp-length "$IPERF3_UDP_LENGTH" \
    --out-dir "${remote_rep_dir}/client" \
    --cpu-list "$CLIENT_CPU_LIST")"
  local rc=$?
  SSH_TIMEOUT_SEC=""
  set -e
  if [[ "$rc" -eq 124 ]]; then
    log "iperf3 client exceeded its time bound and was terminated; recording the repetition as failed"
  fi
  stop_server "${remote_rep_dir}/server/server.log.pid"
  kill_stale_server iperf3 "$IPERF3_PORT"
  return "$rc"
}

run_one_sockperf_repetition() {
  local remote_rep_dir="$1"
  kill_stale_server sockperf "$SOCKPERF_PORT"
  ssh_run "$CLIENT_SSH_HOST" "mkdir -p '${remote_rep_dir}/client'"
  ssh_run "$SERVER_SSH_HOST" "mkdir -p '${remote_rep_dir}/server'"

  start_server "${remote_rep_dir}/server/server.log" "${remote_rep_dir}/server/server.cmd" \
    "${REMOTE_BIN_DIR}/run_sockperf.sh" \
    --role server \
    --protocol "$SOCKPERF_PROTOCOL" \
    --mode "$SOCKPERF_MODE" \
    --port "$SOCKPERF_PORT" \
    --cpu-list "$SERVER_CPU_LIST"

  wait_for_server_ready sockperf "$SOCKPERF_PROTOCOL" "$SOCKPERF_PORT" "$SERVER_READY_TIMEOUT_SEC"

  local -a client_args=(
    "${REMOTE_BIN_DIR}/run_sockperf.sh"
    --role client
    --protocol "$SOCKPERF_PROTOCOL"
    --mode "$SOCKPERF_MODE"
    --server-ip "$SERVER_PRIVATE_IP"
    --port "$SOCKPERF_PORT"
    --msg-size "$SOCKPERF_MSG_SIZE"
    --runtime-sec "$SOCKPERF_RUNTIME_SEC"
    --out-dir "${remote_rep_dir}/client"
    --cpu-list "$CLIENT_CPU_LIST"
  )
  if [[ "$SOCKPERF_MODE" == "ul" ]]; then
    client_args+=(--burst "$SOCKPERF_BURST" --reply-every "$SOCKPERF_REPLY_EVERY" --full-log "$SOCKPERF_FULL_LOG")
    [[ -n "$SOCKPERF_MPS" ]] && client_args+=(--mps "$SOCKPERF_MPS")
  fi

  set +e
  # Bounded: sockperf has been observed to finish its measurement, write the
  # summary, and then never exit -- holding the run open indefinitely.
  SSH_TIMEOUT_SEC="$(step_timeout_sec "$SOCKPERF_RUNTIME_SEC")"
  ssh_run "$CLIENT_SSH_HOST" "$(shell_join "${client_args[@]}")"
  local rc=$?
  SSH_TIMEOUT_SEC=""
  set -e
  if [[ "$rc" -eq 124 ]]; then
    log "sockperf client exceeded its time bound and was terminated; recording the repetition as failed"
  fi
  stop_server "${remote_rep_dir}/server/server.log.pid"
  kill_stale_server sockperf "$SOCKPERF_PORT"
  return "$rc"
}

run_repetitions() {
  local remote_bench_dir="$1"
  local runner_fn="$2"
  write_benchmark_env "$remote_bench_dir"
  local rep rc
  for rep in $(seq 1 "$REPETITIONS"); do
    log "running benchmark ${BENCHMARK_NAME} repetition ${rep}/${REPETITIONS}"
    rc=0
    telemetry_start "${remote_bench_dir}/rep-${rep}"
    # Calling through '|| rc=$?' also suppresses errexit for the whole dynamic
    # extent of the repetition, so a server that never becomes ready fails this
    # repetition instead of terminating the scenario.
    "$runner_fn" "${remote_bench_dir}/rep-${rep}" || rc=$?
    telemetry_stop "${remote_bench_dir}/rep-${rep}"
    record_repetition_status "${remote_bench_dir}/rep-${rep}" "$rc"
    if (( rc != 0 )); then
      BENCHMARK_FAILURES=$((BENCHMARK_FAILURES + 1))
      log "benchmark ${BENCHMARK_NAME} repetition ${rep} failed with status ${rc}; continuing"
    fi
    if (( rep < REPETITIONS )); then
      sleep "$COOLDOWN_SEC"
    fi
  done
}

# Every repetition records how it ended. Without this a run that lost half its
# repetitions is indistinguishable from a complete run with fewer rows.
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
      printf 'REP_FAILURE_REASON=%s\n' "benchmark command exited ${rc}"
    fi
  } >"$tmp"
  if ! scp_to "$tmp" "$CLIENT_SSH_HOST" "${remote_rep_dir}/status.env"; then
    log "could not record repetition status for ${remote_rep_dir}"
  fi
  rm -f "$tmp"
}

stop_server() {
  local pid_file="$1"
  if ! ssh_run "$SERVER_SSH_HOST" "if [[ -f '${pid_file}' ]]; then kill \"\$(cat '${pid_file}')\" >/dev/null 2>&1 || true; fi"; then
    log "ignoring server stop failure for pid file ${pid_file}"
  fi
}

run_iperf3_benchmark() {
  REPETITIONS="${REPETITIONS:-1}"
  COOLDOWN_SEC="${COOLDOWN_SEC:-2}"
  SERVER_READY_TIMEOUT_SEC="${SERVER_READY_TIMEOUT_SEC:-15}"
  IPERF3_PROTOCOL="${IPERF3_PROTOCOL:-tcp}"
  IPERF3_PORT="${IPERF3_PORT:-5201}"
  IPERF3_RUNTIME_SEC="${IPERF3_RUNTIME_SEC:-10}"
  IPERF3_OMIT_SEC="${IPERF3_OMIT_SEC:-1}"
  IPERF3_PARALLEL="${IPERF3_PARALLEL:-1}"
  IPERF3_TCP_LENGTH="${IPERF3_TCP_LENGTH:-128K}"
  IPERF3_UDP_BITRATE="${IPERF3_UDP_BITRATE:-100M}"
  IPERF3_UDP_LENGTH="${IPERF3_UDP_LENGTH:-1492}"

  [[ "$IPERF3_PROTOCOL" == "tcp" || "$IPERF3_PROTOCOL" == "udp" ]] || die "${benchmark_file}: IPERF3_PROTOCOL must be tcp or udp"
  validate_int IPERF3_PORT "$IPERF3_PORT"
  validate_int IPERF3_RUNTIME_SEC "$IPERF3_RUNTIME_SEC"
  validate_int IPERF3_OMIT_SEC "$IPERF3_OMIT_SEC"
  validate_int IPERF3_PARALLEL "$IPERF3_PARALLEL"
  validate_size IPERF3_TCP_LENGTH "$IPERF3_TCP_LENGTH"
  validate_int IPERF3_UDP_LENGTH "$IPERF3_UDP_LENGTH"
  validate_int REPETITIONS "$REPETITIONS"
  validate_int COOLDOWN_SEC "$COOLDOWN_SEC"
  validate_int SERVER_READY_TIMEOUT_SEC "$SERVER_READY_TIMEOUT_SEC"

  local remote_bench_dir="${REMOTE_SCENARIO_DIR}/benchmarks/${BENCHMARK_NAME}"
  run_repetitions "$remote_bench_dir" run_one_iperf3_repetition
}

run_sockperf_benchmark() {
  REPETITIONS="${REPETITIONS:-1}"
  COOLDOWN_SEC="${COOLDOWN_SEC:-2}"
  SERVER_READY_TIMEOUT_SEC="${SERVER_READY_TIMEOUT_SEC:-15}"
  SOCKPERF_PROTOCOL="${SOCKPERF_PROTOCOL:-udp}"
  SOCKPERF_MODE="${SOCKPERF_MODE:-pp}"
  SOCKPERF_PORT="${SOCKPERF_PORT:-11111}"
  SOCKPERF_MSG_SIZE="${SOCKPERF_MSG_SIZE:-64}"
  SOCKPERF_RUNTIME_SEC="${SOCKPERF_RUNTIME_SEC:-10}"
  SOCKPERF_NOFILE_LIMIT="${SOCKPERF_NOFILE_LIMIT:-32768}"
  # under-load only. Empty MPS leaves sockperf's own default in place.
  SOCKPERF_MPS="${SOCKPERF_MPS:-}"
  SOCKPERF_BURST="${SOCKPERF_BURST:-1}"
  SOCKPERF_REPLY_EVERY="${SOCKPERF_REPLY_EVERY:-1}"
  SOCKPERF_FULL_LOG="${SOCKPERF_FULL_LOG:-0}"

  [[ "$SOCKPERF_PROTOCOL" == "tcp" || "$SOCKPERF_PROTOCOL" == "udp" ]] || die "${benchmark_file}: SOCKPERF_PROTOCOL must be tcp or udp"
  case "$SOCKPERF_MODE" in
    pp|ul) ;;
    *) die "${benchmark_file}: SOCKPERF_MODE must be pp (ping-pong) or ul (under-load)" ;;
  esac
  validate_int SOCKPERF_PORT "$SOCKPERF_PORT"
  validate_int SOCKPERF_MSG_SIZE "$SOCKPERF_MSG_SIZE"
  validate_int SOCKPERF_RUNTIME_SEC "$SOCKPERF_RUNTIME_SEC"
  validate_int SOCKPERF_NOFILE_LIMIT "$SOCKPERF_NOFILE_LIMIT"
  validate_int SOCKPERF_BURST "$SOCKPERF_BURST"
  validate_int SOCKPERF_REPLY_EVERY "$SOCKPERF_REPLY_EVERY"
  [[ "$SOCKPERF_FULL_LOG" == "0" || "$SOCKPERF_FULL_LOG" == "1" ]] || die "${benchmark_file}: SOCKPERF_FULL_LOG must be 0 or 1"
  if [[ -n "$SOCKPERF_MPS" ]]; then
    [[ "$SOCKPERF_MODE" == "ul" ]] || die "${benchmark_file}: SOCKPERF_MPS requires SOCKPERF_MODE=ul"
    [[ "$SOCKPERF_MPS" =~ ^([0-9]+|max)$ ]] || die "${benchmark_file}: SOCKPERF_MPS must be a positive integer or 'max'"
  fi
  validate_int REPETITIONS "$REPETITIONS"
  validate_int COOLDOWN_SEC "$COOLDOWN_SEC"
  validate_int SERVER_READY_TIMEOUT_SEC "$SERVER_READY_TIMEOUT_SEC"

  local remote_bench_dir="${REMOTE_SCENARIO_DIR}/benchmarks/${BENCHMARK_NAME}"
  run_repetitions "$remote_bench_dir" run_one_sockperf_repetition
}

log "waiting for client and server SSH/cloud-init readiness"
wait_for_host "$CLIENT_SSH_HOST" client
wait_for_host "$SERVER_SSH_HOST" server
log "waiting for cloud-init client setup to finish and client to be ready"
wait_for_cloud_init "$CLIENT_SSH_HOST" client
log "waiting for cloud-init server setup to finish and server to be ready"
wait_for_cloud_init "$SERVER_SSH_HOST" server
# Scripts must be staged before anything invokes them. apply-os-tuning.sh is
# shipped from the repository rather than embedded in the image, so this push
# has to precede apply_os_tuning.
push_remote_scripts "$CLIENT_SSH_HOST"
push_remote_scripts "$SERVER_SSH_HOST"
apply_os_tuning "$CLIENT_SSH_HOST" client
apply_os_tuning "$SERVER_SSH_HOST" server
trap cpu_idle_release_all EXIT
cpu_idle_start "$CLIENT_SSH_HOST" client
cpu_idle_start "$SERVER_SSH_HOST" server
CLIENT_CPU_LIST="$(remote_cpu_list "$CLIENT_SSH_HOST")"
SERVER_CPU_LIST="$(remote_cpu_list "$SERVER_SSH_HOST")"
log "client CPU list: ${CLIENT_CPU_LIST}"
log "server CPU list: ${SERVER_CPU_LIST}"
if [[ -n "$COMMAND_LOG" ]]; then
  append_command_text "$COMMAND_LOG" "" "scenario=${SCENARIO_NAME} os_tuning=${OS_TUNING} instance_affinity=${INSTANCE_AFFINITY}"
fi
write_remote_metadata

mapfile -t benchmark_files < <(find "$BENCHMARK_DIR" -maxdepth 1 -type f -name '*.sh' | sort)
[[ "${#benchmark_files[@]}" -gt 0 ]] || die "no benchmark files found in ${BENCHMARK_DIR}"

for benchmark_file in "${benchmark_files[@]}"; do
  unset BENCHMARK_NAME BENCHMARK_TOOL SKIP SKIP_REASON
  unset REPETITIONS COOLDOWN_SEC SERVER_READY_TIMEOUT_SEC
  unset IPERF3_PROTOCOL IPERF3_PORT IPERF3_RUNTIME_SEC IPERF3_OMIT_SEC IPERF3_PARALLEL IPERF3_TCP_LENGTH IPERF3_UDP_BITRATE IPERF3_UDP_LENGTH
  unset SOCKPERF_PROTOCOL SOCKPERF_MODE SOCKPERF_PORT SOCKPERF_MSG_SIZE SOCKPERF_RUNTIME_SEC SOCKPERF_NOFILE_LIMIT
  unset SOCKPERF_MPS SOCKPERF_BURST SOCKPERF_REPLY_EVERY SOCKPERF_FULL_LOG

  # Deliberately not pre-seeded here. Assigning REPETITIONS/COOLDOWN_SEC/
  # SERVER_READY_TIMEOUT_SEC before sourcing defeats the ':=' defaults in
  # network/scripts/benchmark_defaults.sh, which a benchmark file sources to
  # avoid restating them -- the file would silently run one repetition. The
  # per-tool functions below still apply their own ':-' fallbacks, so a file
  # that sets neither behaves exactly as it did before.
  # shellcheck disable=SC1090
  source "$benchmark_file"
  validate_common_benchmark

  if ! selected_benchmark "$BENCHMARK_NAME"; then
    continue
  fi
  # ${SKIP:-0}: a benchmark file that neither sets SKIP nor sources
  # benchmark_defaults.sh would otherwise abort the scenario under set -u.
  if [[ "${SKIP:-0}" == "1" ]]; then
    log "skipping benchmark ${BENCHMARK_NAME}${SKIP_REASON:+: ${SKIP_REASON}}"
    continue
  fi

  log "running benchmark ${BENCHMARK_NAME}"
  case "$BENCHMARK_TOOL" in
    iperf3) run_iperf3_benchmark ;;
    sockperf) run_sockperf_benchmark ;;
  esac
done

# Every benchmark got its chance and every artifact is on disk; the scenario is
# still reported as failed so the run is not mistaken for a clean one.
if (( BENCHMARK_FAILURES > 0 )); then
  log "scenario ${SCENARIO_NAME}: ${BENCHMARK_FAILURES} repetition(s) failed"
  exit 1
fi
