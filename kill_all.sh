#!/usr/bin/env bash
set -euo pipefail

# Stop only the Robonix stack rooted at this deployment directory. Persistent
# map and scene data are intentionally left untouched.
DEPLOY_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFEST="$DEPLOY_DIR/robonix_manifest.yaml"
CACHE_DIR="$DEPLOY_DIR/rbnx-boot/cache"
STATE_FILE="$DEPLOY_DIR/rbnx-boot/state.json"
SHUTDOWN_TIMEOUT_SECONDS="${SHUTDOWN_TIMEOUT_SECONDS:-20}"
PROCESS_SCAN_TIMEOUT_SECONDS="${PROCESS_SCAN_TIMEOUT_SECONDS:-3}"
export PATH="$HOME/.cargo/bin:$PATH"

if [[ -f "$DEPLOY_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$DEPLOY_DIR/.env"
  set +a
fi

# rbnx start -p <pkg> launches each package as its own process tree (ROS2
# launch -> component_container / *_node grandchildren, or python -m
# <service>.service module workers). If the top-level `rbnx start` wrapper
# is killed but a grandchild was already detached (observed: ranger_chassis
# and the orbbec camera_container survived a `rbnx shutdown` + Ctrl-C on
# 2026-08-13, reparented to pid 1, with nothing in their /proc/*/cmdline
# tying them back to this deploy) that grandchild is invisible to every
# pattern below -- it never shows $CACHE_DIR, $ROBONIX_SOURCE_PATH, or even
# "robonix" in its argv. Path/name matching alone cannot find those after
# the fact, so snapshot the *process tree* under the current `rbnx boot`
# while it is still intact, and kill that fixed PID set regardless of who
# has reparented them to init by the time we get to it.
descendants_of() {
  local root="$1"
  local -a stack=("$root") out=()
  local cur child
  while ((${#stack[@]})); do
    cur="${stack[-1]}"
    unset 'stack[-1]'
    out+=("$cur")
    while IFS= read -r child; do
      [[ -n "$child" ]] && stack+=("$child")
    done < <(pgrep -P "$cur" 2>/dev/null || true)
  done
  printf '%s\n' "${out[@]:-}"
}

collect_pids() {
  local -a pids=()
  local pid port comm root

  # Keep shutdown functional even if a full /proc command-line scan blocks.
  if [[ -f "$STATE_FILE" ]] && command -v jq >/dev/null 2>&1; then
    while IFS= read -r pid; do
      [[ -n "$pid" ]] && pids+=("$pid")
    done < <(jq -r '.components[]?.pid // empty' "$STATE_FILE" 2>/dev/null || true)
  fi

  # Full descendant tree of every live `rbnx boot` / `rbnx __watch-boot` for
  # this exact manifest -- see the comment above collect_pids for why this
  # is the primary net, not a fallback.
  while IFS= read -r root; do
    [[ -n "$root" ]] || continue
    while IFS= read -r pid; do
      [[ -n "$pid" ]] && pids+=("$pid")
    done < <(descendants_of "$root")
  done < <(timeout "${PROCESS_SCAN_TIMEOUT_SECONDS}s" pgrep -f "rbnx (boot|__watch-boot).*$MANIFEST" || true)

  while IFS= read -r pid; do
    [[ -n "$pid" ]] && pids+=("$pid")
  done < <(timeout "${PROCESS_SCAN_TIMEOUT_SECONDS}s" pgrep -f "$CACHE_DIR" || true)

  # Packages declared with a local `path:` (scene, memsearch, speech,
  # voiceprint, ...) run from $ROBONIX_SOURCE_PATH, never under this
  # deploy's rbnx-boot/cache -- $CACHE_DIR above cannot see them.
  if command -v rbnx >/dev/null 2>&1; then
    robonix_source_path="$(rbnx config --show 2>/dev/null | sed -n 's/^ *Robonix source path: *//p')"
    if [[ -n "$robonix_source_path" ]]; then
      while IFS= read -r pid; do
        [[ -n "$pid" ]] && pids+=("$pid")
      done < <(timeout "${PROCESS_SCAN_TIMEOUT_SECONDS}s" pgrep -f "$robonix_source_path" || true)
    fi
  fi

  # Anything launched from directly under the deploy dir but outside
  # rbnx-boot/cache (skills/*, urdf-relative tooling, ...).
  while IFS= read -r pid; do
    [[ -n "$pid" ]] && pids+=("$pid")
  done < <(timeout "${PROCESS_SCAN_TIMEOUT_SECONDS}s" pgrep -f "$DEPLOY_DIR" || true)

  # The Piper packages currently live outside this deploy's cache directory.
  # Include them in the same graceful TERM -> KILL lifecycle instead of using
  # an unconditional kill -9 after the normal shutdown path.
  while IFS= read -r pid; do
    [[ -n "$pid" ]] && pids+=("$pid")
  done < <(timeout "${PROCESS_SCAN_TIMEOUT_SECONDS}s" pgrep -f "piper" || true)

  # ROS 2 nodes spawned by our services (nav2's lifecycle-managed servers,
  # the rtabmap/costmap nodes, the chassis driver) run straight out of
  # /opt/ros/humble and carry NOTHING in their argv that ties them back to
  # this deploy -- no $CACHE_DIR, no $DEPLOY_DIR, no "robonix". When one is
  # orphaned to init, every path-based pattern above misses it and it
  # survives indefinitely.
  #
  # That is not just untidy: ROS 2 node names are globally unique on the
  # DDS graph, so an orphaned `smoother_server` / `lifecycle_manager`
  # poisons the NEXT boot -- the new lifecycle_manager's ChangeState lands
  # on the stale node and fails in milliseconds, and nav2 bringup aborts.
  # Diagnosed 2026-08-13 after two orphans from a 10:03 failure made every
  # subsequent nav2 bringup fail identically.
  #
  # These names are exact `comm` matches (15-char kernel limit), never
  # substrings, so a user's unrelated ROS 2 work is not caught by accident.
  local ros_node_comms=(
    lifecycle_manag smoother_server controller_serv planner_server
    behavior_server bt_navigator waypoint_follow velocity_smooth
    component_conta rtabmap ranger_base_nod robot_state_pub
    pointcloud_to_l map_to_odom_bri
  )
  local comm_name
  for comm_name in "${ros_node_comms[@]}"; do
    while IFS= read -r pid; do
      [[ -n "$pid" ]] && pids+=("$pid")
    done < <(timeout "${PROCESS_SCAN_TIMEOUT_SECONDS}s" pgrep -x "$comm_name" || true)
  done

  # These are the fixed control-plane ports of this deploy. A second stack
  # cannot legitimately own them at the same time, so this also recovers from
  # a missing rbnx-boot/state.json after an interrupted boot.
  for port in 50051 50061 50071 50081 50091 7447; do
    while IFS= read -r pid; do
      [[ -n "$pid" ]] || continue
      comm="$(cat "/proc/$pid/comm" 2>/dev/null || true)"
      if [[ "$comm" =~ (robonix-|rmw_zenohd) ]]; then
        pids+=("$pid")
      fi
    done < <(lsof -t -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null || true)
  done

  printf '%s\n' "${pids[@]:-}" | awk 'NF && !seen[$0]++'
}

stop_pids() {
  local signal="$1"
  shift
  local pid
  for pid in "$@"; do
    kill -0 "$pid" 2>/dev/null || continue
    echo "[$signal] pid=$pid $(ps -p "$pid" -o comm= 2>/dev/null || true)"
    kill "-$signal" "$pid" 2>/dev/null || true
  done
}

echo "[kill_all] deployment: $DEPLOY_DIR"

# Snapshot the full process tree before rbnx shutdown gets a chance to
# reparent anything to init -- this is what collect_pids replays below.
mapfile -t snapshot_pids < <(collect_pids)

if command -v rbnx >/dev/null 2>&1; then
  if ! timeout --signal=TERM --kill-after=5s "${SHUTDOWN_TIMEOUT_SECONDS}s" \
    rbnx shutdown -f "$MANIFEST"; then
    echo "[kill_all] rbnx shutdown timed out or failed; using process fallback"
  fi
fi

mapfile -t rescan_pids < <(collect_pids)
mapfile -t pids < <(printf '%s\n' "${snapshot_pids[@]:-}" "${rescan_pids[@]:-}" | awk 'NF && !seen[$0]++')
if ((${#pids[@]} == 0)); then
  echo "[kill_all] no matching processes remain"
  exit 0
fi

stop_pids TERM "${pids[@]}"
sleep 8

mapfile -t pids < <(printf '%s\n' "${pids[@]}" | while read -r p; do kill -0 "$p" 2>/dev/null && echo "$p"; done)
if ((${#pids[@]} > 0)); then
  echo "[kill_all] escalating remaining deployment processes"
  stop_pids KILL "${pids[@]}"
fi

echo "[kill_all] done"
