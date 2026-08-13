#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
source "${REPO_ROOT}/common/scripts/common.sh"

TOFU_DIR=""
TFVARS_FILE=""

usage() {
  cat >&2 <<USAGE
usage: $0 --tofu-dir PATH --tfvars-file PATH
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tofu-dir) TOFU_DIR="$2"; shift 2 ;;
    --tfvars-file) TFVARS_FILE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

[[ -n "$TOFU_DIR" ]] || { usage; exit 1; }
[[ -n "$TFVARS_FILE" ]] || { usage; exit 1; }

cd "$REPO_ROOT"
TOFU_DIR="$(abs_path "$TOFU_DIR")"
TFVARS_FILE="$(abs_path "$TFVARS_FILE")"
require_dir "$TOFU_DIR"
require_file "$TFVARS_FILE"

tofu="$(tofu_bin)"
log "initializing ${TOFU_DIR}"
"$tofu" -chdir="$TOFU_DIR" init
log "applying ${TFVARS_FILE}"
tofu_with_retry "$tofu" -chdir="$TOFU_DIR" apply -auto-approve -var-file="$TFVARS_FILE"
