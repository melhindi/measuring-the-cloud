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
  local file meta name tfvars skip resolved

  for file in "$@"; do
    # Sourced in a child shell so scenario variables cannot leak into the runner
    # or into the next scenario's evaluation.
    meta="$(bash -c 'source "$1" >/dev/null 2>&1 || true; printf "%s\t%s\t%s" "${SCENARIO_NAME:-}" "${TFVARS_FILE:-}" "${SKIP:-0}"' _ "$file" 2>/dev/null || true)"
    IFS=$'\t' read -r name tfvars skip <<<"$meta"

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

tofu_bin() {
  if command -v tofu >/dev/null 2>&1; then
    echo tofu
  elif command -v terraform >/dev/null 2>&1; then
    echo terraform
  else
    die "neither tofu nor terraform found in PATH"
  fi
}

tofu_output_raw() {
  local tofu="$1"
  local tofu_dir="$2"
  local name="$3"
  "$tofu" -chdir="$tofu_dir" output -raw "$name"
}

ssh_base_args() {
  local key="$1"
  local known_hosts="${2:-}"
  printf '%s\n' -i "$key" -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR
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
