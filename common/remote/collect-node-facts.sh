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
# Overridable so the "this guest exposes no cpufreq" branch can be exercised
# against an empty directory in tests. Production always uses the real path.
CPU_SYSFS_ROOT="/sys/devices/system/cpu"

usage() {
  cat >&2 <<USAGE
usage: $0 --out PATH [--cpu-sysfs-root PATH]
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --cpu-sysfs-root) CPU_SYSFS_ROOT="$2"; shift 2 ;;
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

# CPU frequency scaling state.
#
# This is a different subsystem from the idle states cpu-idle-pin.sh handles:
# cpufreq governs the frequency a core runs at while executing, cpuidle governs
# what it does when it has nothing to run. Setting scaling_governor=performance
# does not keep a core out of a deep C-state, so the two are recorded
# separately and neither substitutes for the other.
#
# Most virtualised guests expose no cpufreq control at all because frequency is
# host-managed, which is itself worth knowing: a provider whose guests can be
# pinned to a fixed frequency and one whose guests cannot would otherwise look
# identical in the data.
cpufreq_facts() {
  local cpu0="${CPU_SYSFS_ROOT}/cpu0/cpufreq"
  if [[ ! -d "$cpu0" ]]; then
    # An explicit marker, not an omitted key: absent would be indistinguishable
    # from a run recorded before this field existed.
    emit NODE_CPUFREQ_DRIVER none
    return 0
  fi

  emit NODE_CPUFREQ_DRIVER "$(cat "${cpu0}/scaling_driver" 2>/dev/null || true)"
  emit NODE_CPUFREQ_GOVERNOR "$(cat "${cpu0}/scaling_governor" 2>/dev/null || true)"
  emit NODE_CPUFREQ_AVAILABLE_GOVERNORS "$(cat "${cpu0}/scaling_available_governors" 2>/dev/null || true)"
  emit NODE_CPUFREQ_CUR_FREQ_KHZ "$(cat "${cpu0}/scaling_cur_freq" 2>/dev/null || true)"
  emit NODE_CPUFREQ_MIN_FREQ_KHZ "$(cat "${cpu0}/scaling_min_freq" 2>/dev/null || true)"
  emit NODE_CPUFREQ_MAX_FREQ_KHZ "$(cat "${cpu0}/scaling_max_freq" 2>/dev/null || true)"

  # Benchmarks are pinned to CPUs 1..n-1, so a governor read from cpu0 alone
  # could describe cores the measurement never ran on.
  local gov0 uniform=1 governor_file
  gov0="$(cat "${cpu0}/scaling_governor" 2>/dev/null || true)"
  for governor_file in "${CPU_SYSFS_ROOT}"/cpu[0-9]*/cpufreq/scaling_governor; do
    [[ -r "$governor_file" ]] || continue
    if [[ "$(cat "$governor_file" 2>/dev/null || true)" != "$gov0" ]]; then
      uniform=0
      break
    fi
  done
  emit NODE_CPUFREQ_GOVERNOR_UNIFORM "$uniform"
}

# Instance identity comes from whichever metadata service answers. Each probe is
# capped with a short timeout so an unreachable endpoint costs ~1s, not a hang.
# Instance identity, including whether this is a spot instance.
#
# The purchase model is read from the metadata service rather than from the
# Terraform input, so it reports what the instance actually is. Spot draws from
# spare capacity and therefore influences which physical host you land on, so a
# comparison whose arms span both models has an uncontrolled variable in it --
# which is only detectable if the model is recorded per node.
cloud_identity() {
  local token image instance purchase

  # AWS IMDSv2, falling back to IMDSv1 for images that still allow it.
  token="$(curl -s -m 1 -X PUT 'http://169.254.169.254/latest/api/token' \
    -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' 2>/dev/null || true)"
  if [[ -n "$token" ]]; then
    image="$(curl -s -m 1 -H "X-aws-ec2-metadata-token: ${token}" \
      'http://169.254.169.254/latest/meta-data/ami-id' 2>/dev/null || true)"
    instance="$(curl -s -m 1 -H "X-aws-ec2-metadata-token: ${token}" \
      'http://169.254.169.254/latest/meta-data/instance-type' 2>/dev/null || true)"
    # "spot" or "on-demand".
    purchase="$(curl -s -m 1 -H "X-aws-ec2-metadata-token: ${token}" \
      'http://169.254.169.254/latest/meta-data/instance-life-cycle' 2>/dev/null || true)"
  else
    image="$(curl -s -m 1 'http://169.254.169.254/latest/meta-data/ami-id' 2>/dev/null || true)"
    instance="$(curl -s -m 1 'http://169.254.169.254/latest/meta-data/instance-type' 2>/dev/null || true)"
    purchase="$(curl -s -m 1 'http://169.254.169.254/latest/meta-data/instance-life-cycle' 2>/dev/null || true)"
  fi

  # GCP. Spot and legacy preemptible VMs both report preemptible = TRUE.
  if [[ -z "$image" ]]; then
    image="$(curl -s -m 1 -H 'Metadata-Flavor: Google' \
      'http://metadata.google.internal/computeMetadata/v1/instance/image' 2>/dev/null || true)"
    instance="$(curl -s -m 1 -H 'Metadata-Flavor: Google' \
      'http://metadata.google.internal/computeMetadata/v1/instance/machine-type' 2>/dev/null || true)"
    local preemptible
    preemptible="$(curl -s -m 1 -H 'Metadata-Flavor: Google' \
      'http://metadata.google.internal/computeMetadata/v1/instance/scheduling/preemptible' 2>/dev/null || true)"
    case "${preemptible^^}" in
      TRUE) purchase="spot" ;;
      FALSE) purchase="on-demand" ;;
    esac
  fi

  # OpenStack (STACKIT). No spot market exists, so anything here is on-demand.
  if [[ -z "$image" ]]; then
    local meta
    meta="$(curl -s -m 1 'http://169.254.169.254/openstack/latest/meta_data.json' 2>/dev/null || true)"
    if [[ -n "$meta" ]] && command -v jq >/dev/null 2>&1; then
      image="$(printf '%s' "$meta" | jq -r '.image_id // empty' 2>/dev/null || true)"
      instance="$(printf '%s' "$meta" | jq -r '.flavor // .meta.flavor // empty' 2>/dev/null || true)"
      [[ -n "$image" ]] && purchase="on-demand"
    fi
  fi

  # Explicit rather than omitted: "unknown" means no metadata service answered,
  # which is different from the field not existing for that run.
  printf '%s\n%s\n%s\n' "${image:-}" "${instance:-}" "${purchase:-unknown}"
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
  emit NODE_PURCHASE_MODEL "${identity[2]:-unknown}"
  cpufreq_facts

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
