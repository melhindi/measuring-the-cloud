#!/usr/bin/env bash

die() {
  echo "ERROR: $*" >&2
  exit 1
}

log() {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

repo_root() {
  local script_dir
  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  cd -- "${script_dir}/../.." && pwd
}

abs_path() {
  local path="$1"
  if [[ "$path" == /* ]]; then
    printf '%s\n' "$path"
  else
    printf '%s/%s\n' "$(pwd)" "$path"
  fi
}

expand_home() {
  local path="$1"
  printf '%s\n' "${path/#\~/$HOME}"
}

write_env_file() {
  local path="$1"
  shift

  {
    echo "#!/usr/bin/env bash"
    local name
    for name in "$@"; do
      if [[ ${!name+x} ]]; then
        printf 'export %s=%q\n' "$name" "${!name}"
      fi
    done
  } >"$path"
}

append_command_text() {
  local log_file="$1"
  local env_file="$2"
  local text="$3"

  {
    printf '# %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [[ -n "$env_file" ]]; then
      printf 'source %q\n' "$env_file"
    fi
    printf '%s\n\n' "$text"
  } >>"$log_file"
}

append_command_log() {
  local log_file="$1"
  shift

  local env_file=""
  if [[ "${1:-}" == "--env-file" ]]; then
    env_file="$2"
    shift 2
  fi

  append_command_text "$log_file" "$env_file" "$(shell_join "$@")"
}

shell_join() {
  printf '%q' "$1"
  shift
  local arg
  for arg in "$@"; do
    printf ' %q' "$arg"
  done
}

require_file() {
  [[ -f "$1" ]] || die "file not found: $1"
}

# Reject a scenario selection that cannot produce a clean result set, before
# anything is provisioned.
#
# Two scenarios sharing a SCENARIO_NAME write into the same artifact directory:
# the second overwrites the first's scenario.env and merges into its benchmark
# tree, so the analysis attributes one configuration's measurements to another.
# Nothing else detects this. It is easy to reach because scenario folders
# deliberately overlap -- an 'all' folder repeats the focused folders, and the
# provider directory contains both -- so selecting a parent directory silently
# runs many configurations twice under one name.
#
# A missing tfvars aborts at that scenario instead. That is loud, but reporting
# every one up front turns a series of restarts into a single fix.
preflight_scenarios() {
  local repo_root="$1"
  shift

  local -A seen_names=()
  local -a duplicates=()
  local -a missing_tfvars=()
  local file name tfvars skip resolved
  local -a meta=()

  for file in "$@"; do
    # Sourced in a child shell so scenario variables cannot leak into the runner
    # or into the next scenario's evaluation.
    #
    # One field per line rather than a delimited record: tab is IFS whitespace,
    # so `IFS=$'\t' read` collapses consecutive separators and an empty
    # TFVARS_FILE would shift SKIP into its place, reporting a missing tfvars
    # named "0". SCENARIO_NAME is charset-validated by the runner and paths here
    # do not contain newlines.
    meta=()
    mapfile -t meta < <(bash -c 'source "$1" >/dev/null 2>&1 || true; printf "%s\n%s\n%s\n" "${SCENARIO_NAME:-}" "${TFVARS_FILE:-}" "${SKIP:-0}"' _ "$file" 2>/dev/null || true)
    name="${meta[0]:-}"
    tfvars="${meta[1]:-}"
    skip="${meta[2]:-0}"

    [[ "${skip:-0}" == "1" ]] && continue
    [[ -n "$name" ]] || continue

    if [[ -n "${seen_names[$name]:-}" ]]; then
      duplicates+=("${name}: ${seen_names[$name]} and ${file}")
    else
      seen_names[$name]="$file"
    fi

    if [[ -n "$tfvars" ]]; then
      resolved="$tfvars"
      [[ "$resolved" == /* ]] || resolved="${repo_root}/${resolved}"
      [[ -f "$resolved" ]] || missing_tfvars+=("${file} -> ${tfvars}")
    fi
  done

  local failed=0
  if [[ "${#duplicates[@]}" -gt 0 ]]; then
    echo "ERROR: scenarios share a SCENARIO_NAME and would write to the same artifact directory:" >&2
    printf '  %s\n' "${duplicates[@]}" >&2
    echo "  Select one folder rather than a parent that contains overlapping sets." >&2
    failed=1
  fi
  if [[ "${#missing_tfvars[@]}" -gt 0 ]]; then
    echo "ERROR: scenarios reference a tfvars file that does not exist:" >&2
    printf '  %s\n' "${missing_tfvars[@]}" >&2
    failed=1
  fi
  [[ "$failed" -eq 0 ]] || die "preflight failed; nothing was provisioned"
}

require_dir() {
  [[ -d "$1" ]] || die "directory not found: $1"
}

# An availability zone belongs to its region, and every provider used here names
# it with the region as a prefix: us-east-1a in us-east-1, eu01-1 in eu01,
# us-east1-b in us-east1.
#
# Checking that prefix catches the mistake that quietly stranded the eu-central-1
# AWS network scenarios: the shared tfvars moved to us-east-1 and the scenarios
# kept their old zones, so every one of them referenced a zone that did not
# exist in the configured region. Nothing detected it until a run failed at
# apply, and only for whichever scenario ran first.
#
# Only checked when a region is explicitly set, which is the case that can
# disagree. A scenario that takes the region from its tfvars cannot.
assert_zone_in_region() {
  local label="$1"
  local region="$2"
  local zone="$3"
  [[ -n "$region" && -n "$zone" ]] || return 0
  [[ "$zone" == "$region"* ]] \
    || die "${label}: availability zone '${zone}' is not in region '${region}'"
}

tofu_bin() {
  if command -v tofu >/dev/null 2>&1; then
    echo tofu
  elif command -v terraform >/dev/null 2>&1; then
    echo terraform
  else
    die "neither tofu nor terraform found in PATH"
  fi
}

# Run a tofu command, retrying a transient provider failure.
#
# Providers fail intermittently in ways a second attempt resolves. The STACKIT
# provider returns "Provider produced inconsistent result after apply" on
# network creation -- twice in four applies during smoke testing, each time
# leaving partially created resources behind. Capacity errors on spot or in a
# pinned availability zone behave the same way.
#
# Retrying is safe because apply and destroy are convergent: the next attempt
# continues from recorded state rather than starting over, so a partial apply is
# completed rather than duplicated. A failure that is not transient still fails,
# just after TOFU_MAX_ATTEMPTS tries.
tofu_with_retry() {
  local attempts="${TOFU_MAX_ATTEMPTS:-3}"
  local delay="${TOFU_RETRY_DELAY_SEC:-15}"
  local attempt=1
  local rc=0

  while :; do
    rc=0
    "$@" || rc=$?
    [[ "$rc" -eq 0 ]] && return 0
    if (( attempt >= attempts )); then
      log "tofu attempt ${attempt}/${attempts} failed with status ${rc}; giving up"
      return "$rc"
    fi
    log "tofu attempt ${attempt}/${attempts} failed with status ${rc}; retrying in ${delay}s"
    sleep "$delay"
    attempt=$((attempt + 1))
  done
}

# Wall-clock bound for one benchmark invocation, derived from what that
# benchmark was configured to do.
#
# A benchmark that has stopped making progress cannot be detected by watching
# it: the local side is blocked in ssh with nothing to observe until the command
# returns. The only signal available is that it has been running longer than it
# could legitimately need, so the bound has to come from the configuration
# rather than from a fixed number someone has to tune per arm. A 30 s arm gets
# 210 s, a 300 s arm gets 1020 s, and neither needs revisiting when the other
# changes.
#
# The multiplier is generous on purpose. Overshooting costs minutes on a run
# that was already broken; undershooting kills a slow but healthy measurement
# and silently biases the results toward whatever completes quickly.
step_timeout_sec() {
  local runtime="${1:-0}"
  local floor="${STEP_TIMEOUT_FLOOR_SEC:-180}"
  [[ "$runtime" =~ ^[0-9]+$ ]] || runtime=0
  local computed=$(( runtime * 3 + 120 ))
  if (( computed > floor )); then printf '%s\n' "$computed"; else printf '%s\n' "$floor"; fi
}

# Warn when a run stops writing to its log.
#
# Complements the per-step bound above rather than duplicating it. The bound
# covers the benchmark invocations, where a hang is expensive and the expected
# duration is known. This covers everything else -- fetch, destroy, provisioning
# -- where no such expectation exists and killing on a timer would be wrong,
# because a tofu apply legitimately taking six minutes is indistinguishable in
# advance from one that is stuck.
#
# So this only reports. A run writes to its log at least once per repetition, so
# silence beyond the threshold means stuck rather than slow, and that is a fact
# worth putting in the log even when nobody is watching -- the alternative is a
# 30-minute gap in the timestamps that has to be reconstructed afterwards.
start_stale_watchdog() {
  local log_file="$1"
  local threshold="${2:-${STALE_WATCHDOG_SEC:-600}}"
  # Overridable so the warning path can be exercised in seconds rather than in
  # ten minutes. The IRQ collector in this repository shipped a silent failure
  # because it could not be run anywhere but the machine it was written for.
  local interval="${STALE_WATCHDOG_INTERVAL_SEC:-60}"
  [[ -n "$log_file" ]] || return 0
  command -v stat >/dev/null 2>&1 || return 0

  (
    local last_warned=0 now last age
    while :; do
      sleep "$interval"
      [[ -f "$log_file" ]] || continue
      now="$(date +%s)"
      last="$(stat -c %Y "$log_file" 2>/dev/null || printf '%s' "$now")"
      age=$(( now - last ))
      if (( age >= threshold )) && (( now - last_warned >= threshold )); then
        printf '[%s] WARNING: no progress logged for %ss; a step may be stuck (watchdog)\n' \
          "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$age" >&2
        last_warned="$now"
      fi
    done
  # stdout closed deliberately. The caller captures the pid with $(...), and a
  # background child that inherits that command substitution's stdout keeps the
  # pipe open -- so $(...) waits for a process designed never to exit, and the
  # run hangs before it starts. Warnings go to stderr, which is unaffected.
  ) >/dev/null &
  printf '%s\n' "$!"
}

stop_stale_watchdog() {
  local pid="${1:-}"
  [[ -n "$pid" ]] || return 0
  kill "$pid" 2>/dev/null || return 0

  # Polled rather than waited on. start_stale_watchdog runs inside a command
  # substitution, so the watchdog is a grandchild of the caller and `wait`
  # returns immediately without reaping it -- which makes an immediate liveness
  # check race the process's own death. Escalate only if TERM is ignored, so a
  # watchdog mid-write is not cut off before its warning lands.
  local i
  for i in 1 2 3 4 5; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.2
  done
  kill -KILL "$pid" 2>/dev/null || true
}

tofu_output_raw() {
  local tofu="$1"
  local tofu_dir="$2"
  local name="$3"
  "$tofu" -chdir="$tofu_dir" output -raw "$name"
}

# Connection options every ssh and scp in the framework inherits.
#
# ConnectTimeout and the keepalives exist because a benchmark host can vanish
# mid-run -- a reclaimed spot instance is the obvious way, but any instance
# failure looks the same. Without them ssh has no deadline of its own and
# inherits the kernel's, which is minutes per attempt.
#
# That interacts badly with the retry loops here. wait_for_server_ready and the
# cloud-init wait are written as "N attempts, sleep 2 between", which bounds
# them at a couple of minutes when each attempt returns promptly. Against a host
# that is simply gone, each attempt instead blocks for the TCP timeout and 180
# attempts becomes hours. One reclaimed pair burned 29 minutes on a single arm
# this way before the run gave up.
#
#   ConnectTimeout       - the host is unreachable when we try to connect
#   ServerAlive*         - the host vanishes while a command is already running,
#                          which ConnectTimeout cannot see because the
#                          connection was established before it died
#
# Neither replaces the per-step bound in run_benchmarks.sh: that covers the
# third case, where the host is healthy and the benchmark process itself hangs.
# Three failure modes, three mechanisms, no overlap.
ssh_base_args() {
  local key="$1"
  local known_hosts="${2:-}"
  printf '%s\n' -i "$key" -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR \
    -o ConnectTimeout="${SSH_CONNECT_TIMEOUT_SEC:-15}" \
    -o ServerAliveInterval="${SSH_KEEPALIVE_INTERVAL_SEC:-15}" \
    -o ServerAliveCountMax="${SSH_KEEPALIVE_COUNT_MAX:-4}"
  if [[ -n "$known_hosts" ]]; then
    printf '%s\n' -o UserKnownHostsFile="$known_hosts"
  fi
}

ssh_base_cmd() {
  local key="$1"
  local known_hosts="${2:-}"
  local -a args
  mapfile -t args < <(ssh_base_args "$key" "$known_hosts")
  shell_join ssh "${args[@]}"
}
