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
# Overridable for the same reason as CPU_SYSFS_ROOT: the virtio interrupt
# layout cannot be reached from a development machine, and the first version
# of irq_facts shipped a silent failure because it could not be exercised.
NET_SYSFS_ROOT="/sys/class/net"
PROC_INTERRUPTS="/proc/interrupts"

usage() {
  cat >&2 <<USAGE
usage: $0 --out PATH [--cpu-sysfs-root PATH] [--net-sysfs-root PATH] [--proc-interrupts PATH]
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --cpu-sysfs-root) CPU_SYSFS_ROOT="$2"; shift 2 ;;
    --net-sysfs-root) NET_SYSFS_ROOT="$2"; shift 2 ;;
    --proc-interrupts) PROC_INTERRUPTS="$2"; shift 2 ;;
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

# Where the NIC's interrupts are serviced, and whether packet steering is on.
#
# Benchmarks are pinned to CPUs 1..n-1 but nothing places the NIC's interrupts,
# so receive softirq work can land on the same core as the measurement process.
# At microsecond scale that shows up in p99/p99.9 as jitter with no visible
# cause. This does not control the placement -- doing so would change the
# machine under test -- it records it, so "the IRQs shared the benchmark core"
# becomes a checkable fact rather than a suspicion. It is also the confound
# most likely to differ across providers, since NIC model and queue count do.
expand_cpu_list() {
  local spec="$1"
  local -a parts=()
  local part start end i
  IFS=',' read -ra parts <<<"$spec"
  for part in "${parts[@]}"; do
    if [[ "$part" == *-* ]]; then
      start="${part%%-*}"
      end="${part##*-}"
      [[ "$start" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ ]] || continue
      for ((i = start; i <= end; i++)); do printf '%s\n' "$i"; done
    elif [[ "$part" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$part"
    fi
  done
}

irq_facts() {
  local iface="$1"
  [[ -n "$iface" ]] || return 0

  local -a irqs=()
  local devpath devname candidate
  devpath="$(readlink -f "${NET_SYSFS_ROOT}/${iface}/device" 2>/dev/null || true)"
  devname=""
  [[ -n "$devpath" ]] && devname="$(basename "$devpath" 2>/dev/null || true)"

  # msi_irqs belongs to the PCI device. On AWS ENA /sys/class/net/<if>/device is
  # that PCI device and the direct path works. On virtio NICs -- GCP and STACKIT
  # -- it is the virtio device (virtio0) sitting one level below the PCI device
  # that actually owns the interrupts, so the direct path is empty and the
  # parent has to be tried. A first STACKIT run recorded NODE_IRQ_COUNT=0
  # because only the direct path was checked.
  for candidate in \
    "${NET_SYSFS_ROOT}/${iface}/device/msi_irqs" \
    "${NET_SYSFS_ROOT}/${iface}/device/../msi_irqs"; do
    [[ -d "$candidate" ]] || continue
    mapfile -t irqs < <(ls "$candidate" 2>/dev/null | sort -n)
    [[ "${#irqs[@]}" -gt 0 ]] && break
  done

  # /proc/interrupts fallback, matching the device name as well as the interface
  # name. virtio registers its interrupts as "virtio0-input.0", which contains
  # neither the interface name nor anything derivable from it, so the interface
  # match alone finds nothing on exactly the providers that need the fallback.
  if [[ "${#irqs[@]}" -eq 0 ]]; then
    mapfile -t irqs < <(awk -v ifc="$iface" -v dev="${devname:-__nodev__}" 'NR > 1 {
      if (index($NF, ifc) > 0 || (dev != "__nodev__" && index($NF, dev) > 0)) {
        n = $1; sub(/:$/, "", n); if (n ~ /^[0-9]+$/) print n
      }
    }' "$PROC_INTERRUPTS" 2>/dev/null | sort -n -u)
  fi

  emit NODE_IRQ_COUNT "${#irqs[@]}"
  [[ "${#irqs[@]}" -gt 0 ]] || return 0

  local irq affinity
  local -a cpus=()
  for irq in "${irqs[@]}"; do
    affinity="$(cat "/proc/irq/${irq}/smp_affinity_list" 2>/dev/null || true)"
    [[ -n "$affinity" ]] || continue
    mapfile -t -O "${#cpus[@]}" cpus < <(expand_cpu_list "$affinity")
  done
  if [[ "${#cpus[@]}" -gt 0 ]]; then
    local unique
    unique="$(printf '%s\n' "${cpus[@]}" | sort -n -u | paste -sd, -)"
    emit NODE_IRQ_CPUS "$unique"
    emit NODE_IRQ_CPU_COUNT "$(printf '%s\n' "${cpus[@]}" | sort -n -u | wc -l)"
  fi

  # irqbalance moves interrupts while the benchmark runs, so a single reading of
  # the affinities above describes one moment rather than the whole run.
  if pgrep -x irqbalance >/dev/null 2>&1; then
    emit NODE_IRQBALANCE_RUNNING 1
  else
    emit NODE_IRQBALANCE_RUNNING 0
  fi

  local q rps_set=0 xps_set=0 rx=0 tx=0 val
  for q in "${NET_SYSFS_ROOT}/${iface}/queues/rx-"*; do
    [[ -d "$q" ]] || continue
    rx=$((rx + 1))
    val="$(cat "${q}/rps_cpus" 2>/dev/null || true)"
    # A mask of all zeros and commas means RPS is off for that queue.
    [[ -n "$val" && "$val" =~ [1-9a-fA-F] ]] && rps_set=1
  done
  for q in "${NET_SYSFS_ROOT}/${iface}/queues/tx-"*; do
    [[ -d "$q" ]] || continue
    tx=$((tx + 1))
    val="$(cat "${q}/xps_cpus" 2>/dev/null || true)"
    [[ -n "$val" && "$val" =~ [1-9a-fA-F] ]] && xps_set=1
  done
  emit NODE_RX_QUEUES "$rx"
  emit NODE_TX_QUEUES "$tx"
  emit NODE_RPS_ENABLED "$rps_set"
  emit NODE_XPS_ENABLED "$xps_set"
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
# Fetch one metadata value, or nothing.
#
# -f matters: GCP and OpenStack also answer on 169.254.169.254, and the AWS
# paths there return 404 with an HTML body. Without --fail curl exits 0 and that
# body is captured as if it were a value -- which makes the AWS branch look
# successful on GCP, suppresses the GCP branch, and writes markup into the env
# file. The shape check is the second line of defence, for an error page that
# returns 200: a metadata value is one short token, never markup or multi-line.
meta_get() {
  local out
  out="$(curl -fsS -m 1 "$@" 2>/dev/null || true)"
  [[ "$out" == *"<"* ]] && return 0
  [[ "$out" == *$'\n'* ]] && return 0
  printf '%s' "$out"
}

cloud_identity() {
  local token image instance purchase

  # AWS IMDSv2, falling back to IMDSv1 for images that still allow it.
  token="$(meta_get -X PUT 'http://169.254.169.254/latest/api/token' \
    -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')"
  if [[ -n "$token" ]]; then
    image="$(meta_get -H "X-aws-ec2-metadata-token: ${token}" 'http://169.254.169.254/latest/meta-data/ami-id')"
    instance="$(meta_get -H "X-aws-ec2-metadata-token: ${token}" 'http://169.254.169.254/latest/meta-data/instance-type')"
    # "spot" or "on-demand".
    purchase="$(meta_get -H "X-aws-ec2-metadata-token: ${token}" 'http://169.254.169.254/latest/meta-data/instance-life-cycle')"
  else
    image="$(meta_get 'http://169.254.169.254/latest/meta-data/ami-id')"
    instance="$(meta_get 'http://169.254.169.254/latest/meta-data/instance-type')"
    purchase="$(meta_get 'http://169.254.169.254/latest/meta-data/instance-life-cycle')"
  fi

  # GCP. Spot and legacy preemptible VMs both report preemptible = TRUE.
  if [[ -z "$image" ]]; then
    image="$(meta_get -H 'Metadata-Flavor: Google' 'http://metadata.google.internal/computeMetadata/v1/instance/image')"
    instance="$(meta_get -H 'Metadata-Flavor: Google' 'http://metadata.google.internal/computeMetadata/v1/instance/machine-type')"
    local preemptible
    preemptible="$(meta_get -H 'Metadata-Flavor: Google' 'http://metadata.google.internal/computeMetadata/v1/instance/scheduling/preemptible')"
    case "${preemptible^^}" in
      TRUE) purchase="spot" ;;
      FALSE) purchase="on-demand" ;;
    esac
  fi

  # OpenStack (STACKIT). No spot market exists, so anything here is on-demand.
  if [[ -z "$image" ]]; then
    local meta
    meta="$(curl -fsS -m 1 'http://169.254.169.254/openstack/latest/meta_data.json' 2>/dev/null || true)"
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
    emit NODE_PRIMARY_IFACE_MTU "$(cat "${NET_SYSFS_ROOT}/${iface}/mtu" 2>/dev/null || true)"
    if command -v ethtool >/dev/null 2>&1; then
      emit NODE_PRIMARY_IFACE_DRIVER "$(ethtool -i "$iface" 2>/dev/null | awk -F': ' '/^driver/ {print $2; exit}' || true)"
    fi
    irq_facts "$iface"
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
