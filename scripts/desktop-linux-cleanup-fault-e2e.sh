#!/usr/bin/env bash
# Production-path Linux teardown regression. Run only inside the disposable VM.
set -euo pipefail

BINARY="${NVPN_UNDERLAY_BINARY:?set NVPN_UNDERLAY_BINARY}"
STATE_DIR="${NVPN_UNDERLAY_STATE_DIR:?set NVPN_UNDERLAY_STATE_DIR}"
CONFIG="$STATE_DIR/config.toml"
PRIMARY_MAC="${NVPN_UNDERLAY_PRIMARY_MAC:?set NVPN_UNDERLAY_PRIMARY_MAC}"
TUN_IFACE="${NVPN_UNDERLAY_TUN_IFACE:?set NVPN_UNDERLAY_TUN_IFACE}"
WG_IFACE="${NVPN_UNDERLAY_WG_INTERFACE:-nvpn-wg-exit}"
PROBE_URL="${NVPN_UNDERLAY_PROBE_URL:?set NVPN_UNDERLAY_PROBE_URL}"
LOCK_HELD="$STATE_DIR/xtables-lock-held"
LOCK_RELEASE="$STATE_DIR/xtables-lock-release"
STOP_LOG="$STATE_DIR/xtables-stop.log"
LOCK_PID=""
DAEMON_PID=""

fail() {
  echo "Linux cleanup fault regression failed: $*" >&2
  exit 1
}

iface_for_mac() {
  local wanted="${1,,}" path
  for path in /sys/class/net/*/address; do
    [[ "$(<"$path")" == "$wanted" ]] && basename "$(dirname "$path")"
  done
}

route_dev() {
  ip -j -4 route get "$1" | jq -er '.[0].dev'
}

native_network_ready() {
  local primary="$1" host="${PROBE_URL#*://}"
  host="${host%%/*}"
  [[ "$(route_dev 1.1.1.1 2>/dev/null || true)" == "$primary" ]] \
    && getent ahostsv4 "${host%%:*}" >/dev/null \
    && curl -4 --fail --silent --show-error --max-time 8 \
      --output /dev/null "$PROBE_URL"
}

release_lock() {
  [[ -n "$LOCK_PID" ]] || return 0
  touch "$LOCK_RELEASE"
  wait "$LOCK_PID" >/dev/null 2>&1 || true
  LOCK_PID=""
}

cleanup() {
  local status="$?"
  trap - EXIT
  release_lock
  if [[ -n "$DAEMON_PID" ]]; then
    kill "$DAEMON_PID" >/dev/null 2>&1 || true
    wait "$DAEMON_PID" >/dev/null 2>&1 || true
  fi
  exit "$status"
}
trap cleanup EXIT

[[ "$(id -u)" == "0" ]] || fail "regression requires root"
command -v flock >/dev/null || fail "flock is required"
primary="$(iface_for_mac "$PRIMARY_MAC")"
[[ -n "$primary" ]] || fail "physical interface is missing"
rm -f "$LOCK_HELD" "$LOCK_RELEASE" "$STOP_LOG"

"$BINARY" set --config "$CONFIG" \
  --wireguard-exit-enabled true \
  --exit-node-leak-protection true \
  --exit-dns-mode automatic >/dev/null
env RUST_LOG=info "$BINARY" daemon \
  --config "$CONFIG" \
  --iface "$TUN_IFACE" \
  --mesh-refresh-interval-secs 2 \
  >"$STATE_DIR/fault-daemon.stdout.log" \
  2>"$STATE_DIR/fault-daemon.stderr.log" &
DAEMON_PID="$!"

deadline=$((SECONDS + 30))
while ((SECONDS < deadline)); do
  status="$("$BINARY" status --config "$CONFIG" --json --discover-secs 0 2>/dev/null || true)"
  if jq -e --argjson pid "$DAEMON_PID" '
      .daemon.running == true
      and .daemon.pid == $pid
      and .daemon.state.vpn_active == true
    ' <<<"$status" >/dev/null 2>&1 \
    && [[ "$(route_dev 1.1.1.1 2>/dev/null || true)" == "$WG_IFACE" ]]
  then
    break
  fi
  sleep 0.2
done
((SECONDS < deadline)) || fail "full-default WireGuard exit did not become active"

(
  exec 9>"/run/xtables.lock"
  flock -x 9
  : >"$LOCK_HELD"
  while [[ ! -e "$LOCK_RELEASE" ]]; do
    sleep 0.05
  done
) &
LOCK_PID="$!"
deadline=$((SECONDS + 5))
while [[ ! -e "$LOCK_HELD" && $SECONDS -lt $deadline ]]; do
  sleep 0.05
done
[[ -e "$LOCK_HELD" ]] || fail "could not hold xtables lock"

set +e
"$BINARY" stop --config "$CONFIG" --timeout-secs 60 --force \
  >"$STOP_LOG" 2>&1
stop_status="$?"
set -e
DAEMON_PID=""
((stop_status != 0)) || fail "stop unexpectedly hid xtables cleanup failure"
grep -Fq "after three attempts" "$STOP_LOG" \
  || fail "stop did not report exhausted production cleanup retries"
native_network_ready "$primary" \
  || fail "native route, DNS, or HTTPS was not restored before repair"
state="$("$BINARY" status --config "$CONFIG" --json --discover-secs 0)"
jq -e '.daemon.running == false and .daemon.state == null' <<<"$state" >/dev/null \
  || fail "failed cleanup retained stale daemon liveness"
jq -e '.vpn_status == "Cleanup failed"' "$STATE_DIR/daemon.state.json" >/dev/null \
  || fail "failed cleanup did not persist its terminal state"
cleanup_state="$STATE_DIR/.nvpn-network-cleanup/daemon.cleanup.json"
[[ -s "$cleanup_state" ]] \
  || fail "failed cleanup did not persist an exact retry obligation"
jq -e '
    .exit_node_runtime.ipv4_outbound_iface != null
    or .exit_node_runtime.wireguard_exit != null
    or (.exit_node_runtime.pending_wireguard_exit_cleanup | length > 0)
  ' "$cleanup_state" >/dev/null \
  || fail "persisted cleanup state lacks the failed production ownership"

release_lock
"$BINARY" repair-network --config "$CONFIG" >/dev/null
native_network_ready "$primary" || fail "native network failed after explicit repair"
state="$("$BINARY" status --config "$CONFIG" --json --discover-secs 0)"
jq -e '.daemon.running == false and .daemon.state == null' <<<"$state" >/dev/null \
  || fail "repair retained stale daemon liveness"
jq -e '.vpn_status == "Disconnected"' "$STATE_DIR/daemon.state.json" >/dev/null \
  || fail "repair did not transition terminal state to Disconnected"
[[ ! -e "$cleanup_state" ]] \
  || fail "repair retained a completed cleanup obligation"
"$BINARY" set --config "$CONFIG" --wireguard-exit-enabled false >/dev/null

jq -cn \
  --arg physical_interface "$primary" \
  --argjson stop_exit_code "$stop_status" \
  '{
    xtables_retries_exhausted: true,
    normal_stop_failed: true,
    physical_network_restored_before_repair: true,
    repair_transitioned_to_disconnected: true,
    physical_interface: $physical_interface,
    stop_exit_code: $stop_exit_code
  }' | tee "$STATE_DIR/cleanup-fault.receipt.json"
