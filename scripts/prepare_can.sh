#!/usr/bin/env bash
# Bring this machine's CAN buses up before Robonix boots.
#
# Split out of start.sh because CAN wiring is a property of one physical
# robot, not of this deployment: which adapters exist, what they are named,
# and which bitrate each bus runs at all differ per build. start.sh calls
# this only when it is present and executable, so a checkout on a machine
# that is wired differently can replace or delete it without touching the
# boot logic.
#
# Interfaces are matched by NAME, never by USB port. Ports change whenever a
# cable is replugged into a different socket; the names below are pinned to
# adapter serial numbers by systemd .link files in /etc/systemd/network/:
#
#   70-can-candlelight.link  ->  can_ranger
#   71-can-piper.link        ->  can_piper
#
# Every value can be overridden from the environment, so another robot can
# reuse this script by exporting different names or bitrates rather than
# editing it.
set -euo pipefail

DEPLOY_DIR="${ROBONIX_DEPLOY_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
MANIFEST="${ROBONIX_MANIFEST:-$DEPLOY_DIR/robonix_manifest.yaml}"

RANGER_CAN_INTERFACE="${RANGER_CAN_INTERFACE:-can_ranger}"
RANGER_CAN_BITRATE="${RANGER_CAN_BITRATE:-500000}"
PIPER_CAN_INTERFACE="${PIPER_CAN_INTERFACE:-can_piper}"
PIPER_CAN_BITRATE="${PIPER_CAN_BITRATE:-1000000}"
PIPER_CAN_SETUP_SCRIPT="${PIPER_CAN_SETUP_SCRIPT:-$DEPLOY_DIR/rbnx-boot/cache/primitive-agilex-piper-arm-rbnx/scripts/can_activate.sh}"

elevate=()
[[ $EUID -eq 0 ]] || elevate=(sudo)

can_ready() {
  local iface="$1" bitrate="$2" detail
  detail="$(ip -details link show "$iface" 2>/dev/null)" || return 1
  [[ "${detail%%$'\n'*}" == *"state UP"* ]] && [[ "$detail" == *"bitrate $bitrate"* ]]
}

can_bus_info() {
  ethtool -i "$1" 2>/dev/null | awk -F': ' '$1 == "bus-info" { print $2; exit }'
}

# An interface can report UP with a correct bitrate and still be deaf: after a
# USB replug the netdev object can outlive the endpoint it was bound to, and
# then no frame ever arrives while every error counter stays at zero. Reading
# the RX counter is the only way to tell that apart from a healthy idle bus.
can_has_traffic() {
  local iface="$1" timeout_s="${2:-2}" before after
  before="$(cat "/sys/class/net/$iface/statistics/rx_packets" 2>/dev/null || echo 0)"
  sleep "$timeout_s"
  after="$(cat "/sys/class/net/$iface/statistics/rx_packets" 2>/dev/null || echo 0)"
  ((after > before))
}

# Recover a deaf interface by cycling it, which rebinds the netdev to the
# current endpoint.
can_recycle() {
  local iface="$1" bitrate="$2"
  echo "[can] $iface is up but silent; cycling it" >&2
  "${elevate[@]}" ip link set "$iface" down || {
    echo "[can] could not cycle $iface (no privileges?); leaving it as is" >&2
    return 1
  }
  sleep 1
  "${elevate[@]}" ip link set "$iface" type can bitrate "$bitrate" || return 1
  "${elevate[@]}" ip link set "$iface" up || return 1
  sleep 1
}

require_interface() {
  local iface="$1" link_file="$2"
  [[ -e "/sys/class/net/$iface" ]] && return 0
  echo "[can] interface '$iface' does not exist." >&2
  echo "[can] check the adapter is plugged in and that its serial matches" >&2
  echo "[can] $link_file, then: sudo udevadm trigger --subsystem-match=net" >&2
  ip -br link show type can 2>/dev/null | sed 's/^/[can]   /' >&2
  return 1
}

# A silent bus is reported, never fatal. It usually means the hardware on the
# far end is deliberately powered down -- switching the chassis off so the
# robot cannot drive while working on perception indoors is a normal thing to
# do, and refusing to boot for it would be worse than useless. It can also be
# the deaf-interface case a cycle repairs, so try that once before warning.
check_traffic() {
  local iface="$1" bitrate="$2" hint="$3"
  can_has_traffic "$iface" && return 0
  can_recycle "$iface" "$bitrate" || true
  can_has_traffic "$iface" && return 0
  echo "[can] warning: $iface is up but receives no frames." >&2
  echo "[can] warning: this is normal when $hint. Continuing anyway." >&2
  return 0
}

prepare_ranger() {
  local iface="$RANGER_CAN_INTERFACE" bitrate="$RANGER_CAN_BITRATE"
  require_interface "$iface" "/etc/systemd/network/70-can-candlelight.link" || return 1
  if ! can_ready "$iface" "$bitrate"; then
    echo "[can] configuring $iface at $bitrate bps" >&2
    "${elevate[@]}" ip link set "$iface" down 2>/dev/null || true
    "${elevate[@]}" ip link set "$iface" type can bitrate "$bitrate"
    "${elevate[@]}" ip link set "$iface" up
    can_ready "$iface" "$bitrate" || { echo "[can] $iface is not UP at $bitrate bps" >&2; return 1; }
  fi
  check_traffic "$iface" "$bitrate" \
    "the chassis is switched off, or its remote holds it in remote-control mode"
  echo "[can] $iface ready at $bitrate bps ($(can_bus_info "$iface"))" >&2
}

prepare_piper() {
  local iface="$PIPER_CAN_INTERFACE" bitrate="$PIPER_CAN_BITRATE"
  # Only required when the manifest actually deploys the arm.
  rg -q '^[[:space:]]*- name:[[:space:]]+piper_ctl([[:space:]]|$)' "$MANIFEST" || return 0
  require_interface "$iface" "/etc/systemd/network/71-can-piper.link" || return 1
  if ! can_ready "$iface" "$bitrate"; then
    [[ -f "$PIPER_CAN_SETUP_SCRIPT" ]] || {
      echo "[can] missing Piper CAN setup script: $PIPER_CAN_SETUP_SCRIPT" >&2
      return 1
    }
    echo "[can] configuring $iface at $bitrate bps" >&2
    bash "$PIPER_CAN_SETUP_SCRIPT" "$iface" "$bitrate" "$(can_bus_info "$iface")"
    can_ready "$iface" "$bitrate" || { echo "[can] $iface is not UP at $bitrate bps" >&2; return 1; }
  fi
  check_traffic "$iface" "$bitrate" "the arm is switched off"
  echo "[can] $iface ready at $bitrate bps ($(can_bus_info "$iface"))" >&2
}

# A cold boot or a replug leaves the kernel walking the hub tree for several
# seconds before adapters settle, so a first miss is not yet a failure.
retry() {
  local desc="$1"; shift
  local attempts="${CAN_PREP_RETRIES:-6}"
  local delay_s="${CAN_PREP_RETRY_DELAY_S:-1.5}"
  local n
  for ((n = 1; n <= attempts; n++)); do
    "$@" && return 0
    if ((n < attempts)); then
      echo "[can] $desc: attempt $n/$attempts not ready, retrying in ${delay_s}s" >&2
      sleep "$delay_s"
    fi
  done
  echo "[can] $desc: still not ready after $attempts attempts" >&2
  return 1
}

retry "Ranger CAN" prepare_ranger
retry "Piper CAN" prepare_piper
