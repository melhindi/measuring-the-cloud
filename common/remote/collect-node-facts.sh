#!/usr/bin/env bash
# Emit structured node provenance as KEY=value lines for the analysis layer.
#
# node-meta.log captures the same ground truth as free text for a human reader.
# This file exists so the parser does not have to read prose: every value here
# lands in a CSV column. Keys are namespaced NODE_ so they can be overlaid onto
# scenario.env without colliding with it.
#
# This must never fail a benchmark run. Every probe is best-effort and a value
# that cannot be determined is simply omitted, which the parser reads as NA.
set -uo pipefail

OUT=""

usage() {
  cat >&2 <<USAGE
usage: $0 --out PATH
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

[[ -n "$OUT" ]] || { usage; exit 1; }
mkdir -p "$(dirname "$OUT")"

# Collapse whitespace and drop '#', which the env parser treats as a comment.
sanitize() {
  tr '\n' ' ' | tr -s '[:space:]' ' ' | tr -d '#' | sed 's/^ *//; s/ *$//'
}

emit() {
  local key="$1"
  local value="$2"
  value="$(printf '%s' "$value" | sanitize)"
  [[ -n "$value" ]] || return 0
  printf '%s=%s\n' "$key" "$value"
}

primary_iface() {
  ip route get 1.1.1.1 2>/dev/null | awk '/dev/ {
    for (i = 1; i <= NF; i++) {
      if ($i == "dev") { print $(i + 1); exit }
    }
  }'
}

# Instance identity comes from whichever metadata service answers. Each probe is
# capped with a short timeout so an unreachable endpoint costs ~1s, not a hang.
cloud_identity() {
  local token image instance

  # AWS IMDSv2, falling back to IMDSv1 for images that still allow it.
  token="$(curl -s -m 1 -X PUT 'http://169.254.169.254/latest/api/token' \
    -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' 2>/dev/null || true)"
  if [[ -n "$token" ]]; then
    image="$(curl -s -m 1 -H "X-aws-ec2-metadata-token: ${token}" \
      'http://169.254.169.254/latest/meta-data/ami-id' 2>/dev/null || true)"
    instance="$(curl -s -m 1 -H "X-aws-ec2-metadata-token: ${token}" \
      'http://169.254.169.254/latest/meta-data/instance-type' 2>/dev/null || true)"
  else
    image="$(curl -s -m 1 'http://169.254.169.254/latest/meta-data/ami-id' 2>/dev/null || true)"
    instance="$(curl -s -m 1 'http://169.254.169.254/latest/meta-data/instance-type' 2>/dev/null || true)"
  fi

  # GCP.
  if [[ -z "$image" ]]; then
    image="$(curl -s -m 1 -H 'Metadata-Flavor: Google' \
      'http://metadata.google.internal/computeMetadata/v1/instance/image' 2>/dev/null || true)"
    instance="$(curl -s -m 1 -H 'Metadata-Flavor: Google' \
      'http://metadata.google.internal/computeMetadata/v1/instance/machine-type' 2>/dev/null || true)"
  fi

  # OpenStack (STACKIT).
  if [[ -z "$image" ]]; then
    local meta
    meta="$(curl -s -m 1 'http://169.254.169.254/openstack/latest/meta_data.json' 2>/dev/null || true)"
    if [[ -n "$meta" ]] && command -v jq >/dev/null 2>&1; then
      image="$(printf '%s' "$meta" | jq -r '.image_id // empty' 2>/dev/null || true)"
      instance="$(printf '%s' "$meta" | jq -r '.flavor // .meta.flavor // empty' 2>/dev/null || true)"
    fi
  fi

  printf '%s\n%s\n' "${image:-}" "${instance:-}"
}

iface="$(primary_iface || true)"
mapfile -t identity < <(cloud_identity || true)

{
  emit NODE_HOSTNAME "$(hostname 2>/dev/null || true)"
  emit NODE_KERNEL_RELEASE "$(uname -r 2>/dev/null || true)"
  emit NODE_NPROC "$(nproc 2>/dev/null || true)"

  if [[ -r /etc/os-release ]]; then
    emit NODE_OS_PRETTY_NAME "$(. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-}")"
  fi

  emit NODE_CPU_MODEL "$(awk -F': ' '/^model name/ {print $2; exit}' /proc/cpuinfo 2>/dev/null || true)"
  emit NODE_IMAGE_ID "${identity[0]:-}"
  emit NODE_INSTANCE_TYPE "${identity[1]:-}"

  if [[ -n "$iface" ]]; then
    emit NODE_PRIMARY_IFACE "$iface"
    emit NODE_PRIMARY_IFACE_MTU "$(cat "/sys/class/net/${iface}/mtu" 2>/dev/null || true)"
    if command -v ethtool >/dev/null 2>&1; then
      emit NODE_PRIMARY_IFACE_DRIVER "$(ethtool -i "$iface" 2>/dev/null | awk -F': ' '/^driver/ {print $2; exit}' || true)"
    fi
  fi

  emit NODE_IPERF3_VERSION "$(iperf3 --version 2>/dev/null | head -n1 || true)"
  emit NODE_FIO_VERSION "$(fio --version 2>/dev/null | head -n1 || true)"
  # sockperf refuses to start when the hard nofile limit is very large; the
  # runner applies the same cap before invoking it for real.
  #
  # Two lines, not one: some builds print an empty version on line 1 and put the
  # compile date on line 2, so line 1 alone can identify nothing.
  emit NODE_SOCKPERF_VERSION "$(bash -lc 'ulimit -Hn 32768 2>/dev/null || true; ulimit -Sn 32768 2>/dev/null || true; sockperf --version 2>/dev/null | head -n2' || true)"
} >"$OUT" 2>/dev/null

chmod 0644 "$OUT" 2>/dev/null || true
exit 0
