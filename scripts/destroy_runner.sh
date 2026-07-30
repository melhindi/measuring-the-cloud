#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
source "${REPO_ROOT}/common/scripts/common.sh"

TOFU_DIR="infra/stackit-runner"
TFVARS_FILE="infra/stackit-runner/basic-infra.tfvars"
RUNNER_PROVIDER=""

usage() {
  cat >&2 <<USAGE
usage: $0 [--runner-provider stackit|aws|gcp] [--tofu-dir PATH] [--tfvars-file PATH]
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --runner-provider) RUNNER_PROVIDER="$2"; shift 2 ;;
    --tofu-dir) TOFU_DIR="$2"; shift 2 ;;
    --tfvars-file) TFVARS_FILE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -n "$RUNNER_PROVIDER" ]]; then
  case "$RUNNER_PROVIDER" in
    stackit|aws|gcp) ;;
    *) die "--runner-provider must be one of: stackit, aws, gcp" ;;
  esac
  TOFU_DIR="infra/${RUNNER_PROVIDER}-runner"
  TFVARS_FILE="infra/${RUNNER_PROVIDER}-runner/basic-infra.tfvars"
fi

cd "$REPO_ROOT"
TOFU_DIR="$(abs_path "$TOFU_DIR")"
TFVARS_FILE="$(abs_path "$TFVARS_FILE")"
require_dir "$TOFU_DIR"
require_file "$TFVARS_FILE"

"${REPO_ROOT}/scripts/destroy_infra.sh" --tofu-dir "$TOFU_DIR" --tfvars-file "$TFVARS_FILE"
