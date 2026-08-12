#!/usr/bin/env bash
# Hold the CPU out of deep idle states for the lifetime of a benchmark, and
# record whether that actually happened.
#
# Why this exists: idle-state exit latency is a large, rate-dependent addition to
# measured network latency -- on the order of +171 us at ~1k msg/s, falling to
# ~0 at high packet rate. That is bigger than the same-AZ round trip these
# benchmarks try to resolve, so a latency comparison across instance types or
# providers is partly a comparison of idle behaviour unless it is controlled.
#
# Why it probes and records rather than just acting: many virtualised instance
# types do not expose usable idle-state control. The guest may have no cpuidle
# driver, may offer only POLL/C1, or may not permit writes to
# /dev/cpu_dma_latency. On those instances this script MUST NOT silently do
# nothing and let the run look identical to a pinned one -- it records
# CPU_IDLE_PINNING_SUPPORTED=0 so the analysis groups those runs separately
# instead of pooling them into one latency distribution.
#
# Mechanism: writing a 0 to /dev/cpu_dma_latency requests a CPU DMA wake-up
# latency bound of 0 us, which prevents entry into states that cannot meet it.
# The bound is released as soon as the file descriptor closes, so a process must
# hold it open for the whole measurement rather than write and exit.
set -uo pipefail

ACTION=""
OUT=""
PID_FILE="/opt/cloud-measuring/state/cpu-idle-pin.pid"
SNAPSHOT="/opt/cloud-measuring/state/cpu-idle-usage.snapshot"
DEEP_LATENCY_US=10
LATENCY_TARGET_US=0
# Whether this scenario asked for pinning. Counters are snapshotted either way:
# a run that did NOT pin is the baseline that says whether there was anything to
# prevent. Without it, zero deep entries on a pinned run is ambiguous, because a
# CPU that is never idle enters no deep states with or without a bound.
PIN=0
# Overridable so the start/stop lifecycle can be exercised against a regular
# file in tests. Production always uses the real device.
LATENCY_DEVICE="/dev/cpu_dma_latency"
# Overridable so each capability branch can be exercised against a synthetic
# sysfs tree. Instance types differ in what they expose, and the only way to
# trust the classification is to be able to reproduce every outcome.
CPU_SYSFS_ROOT="/sys/devices/system/cpu"

usage() {
  cat >&2 <<USAGE
usage: $0 --action probe|start|stop [--out PATH] [--pid-file PATH] [--snapshot PATH]
          [--deep-latency-us N] [--target-us N] [--device PATH] [--cpu-sysfs-root PATH]

  probe  report capability only, change nothing
  start  report capability, snapshot idle counters, begin holding the bound
  stop   release the bound, re-read counters, report whether pinning held
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --action) ACTION="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --pid-file) PID_FILE="$2"; shift 2 ;;
    --snapshot) SNAPSHOT="$2"; shift 2 ;;
    --deep-latency-us) DEEP_LATENCY_US="$2"; shift 2 ;;
    --target-us) LATENCY_TARGET_US="$2"; shift 2 ;;
    --device) LATENCY_DEVICE="$2"; shift 2 ;;
    --pin) PIN="$2"; shift 2 ;;
    --cpu-sysfs-root) CPU_SYSFS_ROOT="$2"; CPUIDLE_ROOT="${CPU_SYSFS_ROOT}/cpuidle"; CPU0_STATES="${CPU_SYSFS_ROOT}/cpu0/cpuidle"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

case "$ACTION" in
  probe|start|stop) ;;
  *) usage; exit 1 ;;
esac

CPUIDLE_ROOT="${CPU_SYSFS_ROOT}/cpuidle"
CPU0_STATES="${CPU_SYSFS_ROOT}/cpu0/cpuidle"

idle_driver() {
  cat "${CPUIDLE_ROOT}/current_driver" 2>/dev/null || true
}

idle_governor() {
  cat "${CPUIDLE_ROOT}/current_governor" 2>/dev/null || true
}

# "name:latency_us" for every state on cpu0, joined with '|'.
idle_states_summary() {
  local state out=""
  for state in "${CPU0_STATES}"/state*; do
    [[ -d "$state" ]] || continue
    local name latency
    name="$(cat "${state}/name" 2>/dev/null || echo '?')"
    latency="$(cat "${state}/latency" 2>/dev/null || echo '?')"
    out+="${name}:${latency}|"
  done
  printf '%s' "${out%|}"
}

# Number of idle states deeper than the threshold, counted on cpu0.
deep_state_count() {
  local state count=0
  for state in "${CPU0_STATES}"/state*; do
    [[ -d "$state" ]] || continue
    local latency
    latency="$(cat "${state}/latency" 2>/dev/null || echo 0)"
    [[ "$latency" =~ ^[0-9]+$ ]] || continue
    if (( latency >= DEEP_LATENCY_US )); then
      count=$((count + 1))
    fi
  done
  printf '%s' "$count"
}

# Total entries into deep idle states, summed across every CPU. This is the
# evidence that pinning did or did not take effect: a pinned run should add
# approximately nothing to this counter.
deep_entries_total() {
  local total=0 state latency usage
  for state in "${CPU_SYSFS_ROOT}"/cpu[0-9]*/cpuidle/state*; do
    [[ -d "$state" ]] || continue
    latency="$(cat "${state}/latency" 2>/dev/null || echo 0)"
    [[ "$latency" =~ ^[0-9]+$ ]] || continue
    (( latency >= DEEP_LATENCY_US )) || continue
    usage="$(cat "${state}/usage" 2>/dev/null || echo 0)"
    [[ "$usage" =~ ^[0-9]+$ ]] || continue
    total=$((total + usage))
  done
  printf '%s' "$total"
}

# Capability is three separate questions; all must hold for pinning to be real.
#   1. is there a cpuidle driver at all
#   2. are there states deep enough to be worth preventing
#   3. can we actually open the knob for writing
supported_reason=""
is_supported() {
  if [[ -z "$(idle_driver)" ]]; then
    supported_reason="no-cpuidle-driver"
    return 1
  fi
  if [[ "$(deep_state_count)" == "0" ]]; then
    supported_reason="no-deep-idle-states"
    return 1
  fi
  if [[ ! -e "$LATENCY_DEVICE" ]]; then
    supported_reason="no-cpu-dma-latency-device"
    return 1
  fi
  if ! { : >>"$LATENCY_DEVICE"; } 2>/dev/null; then
    supported_reason="cpu-dma-latency-not-writable"
    return 1
  fi
  supported_reason="ok"
  return 0
}

holder_running() {
  [[ -f "$PID_FILE" ]] || return 1
  local pid
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

start_holder() {
  mkdir -p "$(dirname "$PID_FILE")"

  # The bound is a 32-bit little-endian integer of microseconds. Build the byte
  # escapes here and pass them to the holder as an argument; interpolating them
  # into the quoted body instead needs four levels of backslash escaping.
  local esc
  esc="$(printf '\\x%02x\\x%02x\\x%02x\\x%02x' \
    "$(( LATENCY_TARGET_US & 0xff ))" \
    "$(( (LATENCY_TARGET_US >> 8) & 0xff ))" \
    "$(( (LATENCY_TARGET_US >> 16) & 0xff ))" \
    "$(( (LATENCY_TARGET_US >> 24) & 0xff ))")"

  # setsid detaches the holder from the SSH session so it survives the command
  # that started it. It must outlive this script but not the scenario: the
  # kernel releases the bound the moment fd 3 closes.
  setsid bash -c '
    exec 3>"$1" || exit 1
    printf "$2" >&3
    while :; do sleep 3600; done
  ' _ "$LATENCY_DEVICE" "$esc" >/dev/null 2>&1 &

  local pid=$!
  printf '%s\n' "$pid" >"$PID_FILE"
  # Give the holder a moment to open the device before declaring success.
  sleep 0.3
  kill -0 "$pid" 2>/dev/null
}

stop_holder() {
  [[ -f "$PID_FILE" ]] || return 0
  local pid
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [[ -n "$pid" ]]; then
    kill "$pid" 2>/dev/null || true
    # Killing the process closes fd 3, which releases the latency bound.
    sleep 0.2
  fi
  rm -f "$PID_FILE"
}

emit_facts() {
  local supported="$1"
  local reason="$2"
  local verified="${3:-}"
  local delta="${4:-}"

  # Built into a string rather than redirected: a bare '>/dev/stdout' default
  # truncates the caller's output file when stdout is itself a redirect.
  local content
  content="$(
    printf 'NODE_CPU_IDLE_DRIVER=%s\n' "$(idle_driver)"
    printf 'NODE_CPU_IDLE_GOVERNOR=%s\n' "$(idle_governor)"
    printf 'NODE_CPU_IDLE_STATES=%s\n' "$(idle_states_summary)"
    printf 'NODE_CPU_IDLE_DEEP_STATE_COUNT=%s\n' "$(deep_state_count)"
    printf 'NODE_CPU_IDLE_DEEP_LATENCY_THRESHOLD_US=%s\n' "$DEEP_LATENCY_US"
    printf 'NODE_CPU_IDLE_PINNING_SUPPORTED=%s\n' "$supported"
    printf 'NODE_CPU_IDLE_PINNING_REASON=%s\n' "$reason"
    printf 'NODE_CPU_IDLE_PINNING_REQUESTED=%s\n' "$PIN"
    printf 'NODE_CPU_IDLE_TARGET_US=%s\n' "$LATENCY_TARGET_US"
    [[ -n "$verified" ]] && printf 'NODE_CPU_IDLE_PINNING_VERIFIED=%s\n' "$verified"
    [[ -n "$delta" ]] && printf 'NODE_CPU_IDLE_DEEP_ENTRIES_DELTA=%s\n' "$delta"
    true
  )"

  if [[ -n "$OUT" ]]; then
    mkdir -p "$(dirname "$OUT")"
    printf '%s\n' "$content" >"$OUT"
    chmod 0644 "$OUT" 2>/dev/null || true
  else
    printf '%s\n' "$content"
  fi
}

case "$ACTION" in
  probe)
    if is_supported; then emit_facts 1 "$supported_reason"; else emit_facts 0 "$supported_reason"; fi
    ;;

  start)
    supported=0
    is_supported && supported=1

    # Snapshot unconditionally. On an arm that did not request pinning this is
    # the baseline: if its delta is also near zero, the CPU never entered a deep
    # state anyway and pinning could not have changed the measurement.
    mkdir -p "$(dirname "$SNAPSHOT")"
    deep_entries_total >"$SNAPSHOT"

    if [[ "$PIN" != "1" ]]; then
      emit_facts "$supported" "$supported_reason"
      exit 0
    fi

    if [[ "$supported" != "1" ]]; then
      echo "cpu-idle pinning unsupported on this instance: ${supported_reason}" >&2
      # Unsupported is a recorded outcome, not an error. The run continues.
      emit_facts 0 "$supported_reason" 0 ""
      exit 0
    fi

    if start_holder; then
      emit_facts 1 "$supported_reason"
    else
      echo "cpu-idle holder failed to start" >&2
      emit_facts 0 "holder-failed-to-start" 0 ""
    fi
    ;;

  stop)
    was_running=0
    holder_running && was_running=1
    stop_holder

    delta=""
    verified=""
    if [[ -f "$SNAPSHOT" ]]; then
      before="$(cat "$SNAPSHOT" 2>/dev/null || echo '')"
      after="$(deep_entries_total)"
      if [[ "$before" =~ ^[0-9]+$ && "$after" =~ ^[0-9]+$ ]]; then
        delta=$((after - before))
        # "Verified" is a claim about pinning, so it is only meaningful when
        # pinning was requested and a holder actually ran. On an unpinned arm
        # the delta is still recorded -- as the baseline -- but there is no
        # claim to verify, and reporting 1 there would invite reading an idle
        # CPU as a successful pin.
        if [[ "$PIN" == "1" ]]; then
          if (( was_running == 1 && delta == 0 )); then verified=1; else verified=0; fi
        else
          verified=0
        fi
      fi
      rm -f "$SNAPSHOT"
    fi

    if is_supported; then
      emit_facts 1 "$supported_reason" "${verified:-0}" "$delta"
    else
      emit_facts 0 "$supported_reason" 0 "$delta"
    fi
    ;;
esac

exit 0
