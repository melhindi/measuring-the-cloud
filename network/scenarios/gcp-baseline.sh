#!/usr/bin/env bash
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/gcp/baseline.sh"
if [[ -f network/scenarios/gcp-baseline.tfvars ]]; then
  TFVARS_FILE=network/scenarios/gcp-baseline.tfvars
fi
