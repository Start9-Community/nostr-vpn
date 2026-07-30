#!/usr/bin/env bash
# Root-owned Linux FIPS peer for the macos-utm Release roaming gate.
# The controller builds the exact x86_64-musl nvpn on the host Mac and imports
# it here. This runner never invokes Cargo, rustc, a compiler, or a package
# manager.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib-desktop-linux-listener-audit.sh"

ACTION="${1:-}"
STATE_DIR="${NVPN_MACOS_FIPS_PEER_STATE_DIR:?set NVPN_MACOS_FIPS_PEER_STATE_DIR}"
BINARY="${NVPN_MACOS_FIPS_PEER_BINARY:?set NVPN_MACOS_FIPS_PEER_BINARY}"
CONFIG="$STATE_DIR/config.toml"
TUN_IFACE="${NVPN_MACOS_FIPS_PEER_TUN_IFACE:?set NVPN_MACOS_FIPS_PEER_TUN_IFACE}"
LISTEN_PORT="${NVPN_MACOS_FIPS_PEER_LISTEN_PORT:?set NVPN_MACOS_FIPS_PEER_LISTEN_PORT}"
NETWORK_ID="${NVPN_MACOS_FIPS_NETWORK_ID:?set NVPN_MACOS_FIPS_NETWORK_ID}"
PUBLIC_ENDPOINT="${NVPN_MACOS_FIPS_PEER_PUBLIC_ENDPOINT:-}"
TARGET_NPUB="${NVPN_MACOS_FIPS_TARGET_NPUB:-}"
TARGET_TUNNEL_IP="${NVPN_MACOS_FIPS_TARGET_TUNNEL_IP:-}"
EXPECTED_BINARY_SHA256="${NVPN_MACOS_FIPS_PEER_BINARY_SHA256:?set NVPN_MACOS_FIPS_PEER_BINARY_SHA256}"
EXPECTED_FIPS_REV="${NVPN_MACOS_FIPS_EXPECTED_REV:?set NVPN_MACOS_FIPS_EXPECTED_REV}"
EXPECTED_APP_SHA="${NVPN_MACOS_FIPS_EXPECTED_APP_SHA:?set NVPN_MACOS_FIPS_EXPECTED_APP_SHA}"
DAEMON_PID_FILE="$STATE_DIR/fixture-daemon.pid"
DAEMON_START_FILE="$STATE_DIR/fixture-daemon.start"
PING_PID_FILE="$STATE_DIR/ping.pid"
PING_START_FILE="$STATE_DIR/ping.start"

fail() {
  echo "macOS Release FIPS peer fixture failed: $*" >&2
  exit 1
}

require_root() {
  [[ "$(id -u)" == "0" ]] || fail "remote peer runner must execute as root"
}

validate_inputs() {
  [[ "$STATE_DIR" =~ ^/tmp/nvpn-macos-fips-peer\.[A-Za-z0-9._-]+/state$ ]] \
    || fail "peer state directory is outside the owned fixture path"
  [[ "$BINARY" == "${STATE_DIR%/state}/nvpn" ]] \
    || fail "peer binary is outside the owned fixture path"
  [[ "$TUN_IFACE" =~ ^[A-Za-z][A-Za-z0-9]{1,14}$ ]] \
    || fail "peer tunnel interface name is invalid"
  [[ "$LISTEN_PORT" =~ ^[1-9][0-9]{0,4}$ ]] \
    && ((LISTEN_PORT <= 65535)) \
    || fail "peer UDP port is invalid"
  [[ "$EXPECTED_BINARY_SHA256" =~ ^[0-9a-f]{64}$ ]] \
    || fail "expected peer binary SHA-256 is invalid"
  [[ "$EXPECTED_FIPS_REV" =~ ^[0-9a-f]{10}$ ]] \
    || fail "expected FIPS revision must be exactly ten hex characters"
  [[ "$EXPECTED_APP_SHA" =~ ^[0-9a-f]{40}$ ]] \
    || fail "expected app revision must be exactly forty hex characters"
}

process_start_signature() {
  local pid="$1"
  [[ -r "/proc/$pid/stat" ]] || return 1
  awk '{ print $22 }' "/proc/$pid/stat"
}

pid_matches_receipt() {
  local pid="$1" receipt="$2" expected actual
  [[ "$pid" =~ ^[1-9][0-9]*$ && -s "$receipt" ]] || return 1
  expected="$(<"$receipt")"
  actual="$(process_start_signature "$pid")" || return 1
  [[ -n "$actual" && "$actual" == "$expected" ]]
}

daemon_pid_owned() {
  local pid="$1" executable command
  pid_matches_receipt "$pid" "$DAEMON_START_FILE" || return 1
  executable="$(readlink -f "/proc/$pid/exe" 2>/dev/null)" || return 1
  [[ "$executable" == "$(readlink -f "$BINARY")" ]] || return 1
  command="$(tr '\0' ' ' <"/proc/$pid/cmdline")"
  [[ "$command" == *" daemon "* \
    && "$command" == *" --config $CONFIG "* \
    && "$command" == *" --iface $TUN_IFACE "* ]]
}

ping_pid_owned() {
  local pid="$1" executable command
  pid_matches_receipt "$pid" "$PING_START_FILE" || return 1
  executable="$(readlink -f "/proc/$pid/exe" 2>/dev/null)" || return 1
  [[ "${executable##*/}" == "ping" ]] || return 1
  command="$(tr '\0' ' ' <"/proc/$pid/cmdline")"
  [[ -n "$TARGET_TUNNEL_IP" && "$command" == *" $TARGET_TUNNEL_IP"* ]]
}

stop_owned_pid() {
  local kind="$1" pid_file="$2" start_file="$3" pid ignored
  [[ -s "$pid_file" ]] || {
    rm -f "$pid_file" "$start_file"
    return 0
  }
  pid="$(<"$pid_file")"
  if ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$pid_file" "$start_file"
    return 0
  fi
  case "$kind" in
    daemon) daemon_pid_owned "$pid" ;;
    ping) ping_pid_owned "$pid" ;;
    *) return 2 ;;
  esac || {
    echo "refusing to signal unowned $kind PID $pid" >&2
    return 1
  }
  kill "$pid" 2>/dev/null || true
  for ignored in $(seq 1 50); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
    for ignored in $(seq 1 20); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done
  fi
  kill -0 "$pid" 2>/dev/null \
    && { echo "owned $kind PID $pid survived termination" >&2; return 1; }
  rm -f "$pid_file" "$start_file"
}

read_npub() {
  sed -n 's/^public_key = "\([^"]*\)"/\1/p' "$CONFIG" | head -n 1
}

binary_sha256() {
  sha256sum "$BINARY" | awk '{ print $1 }'
}

verify_binary() {
  [[ -x "$BINARY" ]] || fail "imported peer binary is missing"
  [[ "$(uname -m)" == "x86_64" ]] \
    || fail "imported x86_64 peer is on the wrong fixture architecture"
  [[ "$(binary_sha256)" == "$EXPECTED_BINARY_SHA256" ]] \
    || fail "imported peer binary SHA-256 differs from its host receipt"
  file "$BINARY" | grep -Eq 'ELF 64-bit.*x86-64' \
    || fail "imported peer binary is not x86_64 Linux ELF"
  "$BINARY" version --verbose \
    | grep -Fq "(rev $EXPECTED_FIPS_REV)" \
    || fail "imported peer binary does not contain the exact FIPS revision"
}

listener_rows() {
  ss -H -lunp "sport = :$LISTEN_PORT" 2>/dev/null || true
}

assert_port_free() {
  [[ -z "$(listener_rows)" ]] \
    || fail "unique peer UDP port $LISTEN_PORT is already occupied"
}

default_underlay_interface() {
  local interface
  interface="$(
    ip -6 route show default 2>/dev/null \
      | awk '{ for (field = 1; field <= NF; field++) if ($field == "dev") { print $(field + 1); exit } }'
  )"
  if [[ -z "$interface" ]]; then
    interface="$(
      ip -4 route show default 2>/dev/null \
        | awk '{ for (field = 1; field <= NF; field++) if ($field == "dev") { print $(field + 1); exit } }'
    )"
  fi
  [[ -n "$interface" ]] || fail "remote peer has no physical default underlay"
  printf '%s\n' "$interface"
}

listener_audit() {
  local pid interface rows row tunnel_route
  [[ -s "$DAEMON_PID_FILE" ]] || fail "peer daemon PID receipt is missing"
  pid="$(<"$DAEMON_PID_FILE")"
  daemon_pid_owned "$pid" || fail "peer daemon PID ownership changed"
  interface="$(default_underlay_interface)"
  for _ in $(seq 1 50); do
    rows="$(listener_rows)"
    if row="$(
      nvpn_require_single_udp_listener \
        "$rows" "$interface" "$LISTEN_PORT" "$pid" 2>/dev/null
    )" && peer_tunnel_route_live; then
      printf 'underlay_interface=%s\n' "$interface"
      printf 'daemon_pid=%s\n' "$pid"
      printf 'listener=%s\n' "$row"
      printf 'so_reuseport_ambiguity=false\n'
      tunnel_route="$(ip -4 route get "$TARGET_TUNNEL_IP")"
      printf 'private_tunnel_route=%s\n' "$tunnel_route"
      return 0
    fi
    sleep 0.1
  done
  nvpn_require_single_udp_listener \
    "$rows" "$interface" "$LISTEN_PORT" "$pid" >/dev/null || true
  ss -lunp 2>/dev/null >&2 || true
  ip -4 route get "$TARGET_TUNNEL_IP" >&2 || true
  fail "peer listener and private tunnel route are not ready on $interface:$LISTEN_PORT"
}

peer_status_is_ready() {
  local status_file="$STATE_DIR/status.json"
  "$BINARY" status --config "$CONFIG" --json --discover-secs 0 \
    >"$status_file" 2>/dev/null || return 1
  python3 - \
    "$status_file" "$TARGET_NPUB" "$LISTEN_PORT" "$EXPECTED_FIPS_REV" <<'PY'
import json
import sys

path, target, listen_port, revision = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    status = json.load(handle)
state = status.get("daemon", {}).get("state") or {}
peers = state.get("fips_endpoint_peers", [])
if (
    status.get("status_source") == "daemon"
    and status.get("daemon", {}).get("running") is True
    and state.get("mesh_ready") is True
    and state.get("connected_peer_count") == 1
    and state.get("listen_port") == int(listen_port)
    and len(peers) == 1
    and peers[0].get("npub") == target
    and state.get("fips_core_version", "").endswith(f"(rev {revision})")
):
    raise SystemExit(0)
raise SystemExit(1)
PY
}

peer_tunnel_route_live() {
  local route
  route="$(ip -4 route get "$TARGET_TUNNEL_IP" 2>/dev/null)" || return 1
  [[ " $route " == *" dev $TUN_IFACE "* ]]
}

wait_for_peer_tunnel() {
  local tunnel_ip
  tunnel_ip="$("$BINARY" ip --config "$CONFIG")"
  for _ in $(seq 1 300); do
    if ip -4 address show dev "$TUN_IFACE" 2>/dev/null \
      | grep -Fq " $tunnel_ip/"; then
      return 0
    fi
    sleep 0.1
  done
  fail "peer tunnel interface did not become ready"
}

write_provenance() {
  local version
  version="$("$BINARY" version --verbose | tr '\n' ';')"
  {
    printf 'built_on_host_mac=true\n'
    printf 'built_on_remote_vm=false\n'
    printf 'app_git_sha=%s\n' "$EXPECTED_APP_SHA"
    printf 'fips_git_rev=%s\n' "$EXPECTED_FIPS_REV"
    printf 'binary_sha256=%s\n' "$(binary_sha256)"
    printf 'remote_architecture=%s\n' "$(uname -m)"
    printf 'binary_version=%s\n' "$version"
  } >"$STATE_DIR/provenance.txt"
}

initialize_peer() {
  verify_binary
  assert_port_free
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"
  "$BINARY" init --config "$CONFIG" --force >/dev/null
  "$BINARY" set --config "$CONFIG" --network-id "$NETWORK_ID" >/dev/null
  write_provenance
  local npub tunnel_ip
  npub="$(read_npub)"
  tunnel_ip="$("$BINARY" ip --config "$CONFIG")"
  [[ -n "$npub" && -n "$tunnel_ip" ]] \
    || fail "peer identity receipt is incomplete"
  printf 'npub=%s\n' "$npub"
  printf 'tunnel_ip=%s\n' "$tunnel_ip"
  cat "$STATE_DIR/provenance.txt"
}

start_peer() {
  [[ -n "$PUBLIC_ENDPOINT" \
    && -n "$TARGET_NPUB" \
    && -n "$TARGET_TUNNEL_IP" ]] \
    || fail "peer start is missing target or endpoint configuration"
  verify_binary
  assert_port_free
  "$BINARY" set \
    --config "$CONFIG" \
    --network-id "$NETWORK_ID" \
    --participant "$TARGET_NPUB" \
    --endpoint "$PUBLIC_ENDPOINT" \
    --listen-port "$LISTEN_PORT" \
    --fips-advertise-public-endpoint false \
    --fips-nostr-discovery-enabled false \
    --lan-discovery-enabled false \
    --fips-webrtc-enabled false \
    --fips-bootstrap-enabled false \
    --advertise-exit-node false \
    --autoconnect true \
    >/dev/null
  nohup env RUST_LOG=info "$BINARY" daemon \
    --config "$CONFIG" \
    --iface "$TUN_IFACE" \
    --mesh-refresh-interval-secs 2 \
    >"$STATE_DIR/daemon.stdout.log" \
    2>"$STATE_DIR/daemon.stderr.log" \
    </dev/null &
  local pid="$!"
  printf '%s\n' "$pid" >"$DAEMON_PID_FILE"
  process_start_signature "$pid" >"$DAEMON_START_FILE"
  [[ -s "$DAEMON_START_FILE" ]] \
    || fail "peer daemon has no start-time ownership receipt"
  wait_for_peer_tunnel
  listener_audit >"$STATE_DIR/listener.txt"

  ping -D -n -i 0.1 -W 1 "$TARGET_TUNNEL_IP" \
    >"$STATE_DIR/private-payload.log" 2>&1 &
  pid="$!"
  printf '%s\n' "$pid" >"$PING_PID_FILE"
  process_start_signature "$pid" >"$PING_START_FILE"
  [[ -s "$PING_START_FILE" ]] \
    || fail "peer payload has no start-time ownership receipt"
}

wait_ready() {
  [[ -n "$TARGET_NPUB" ]] || fail "peer readiness requires target npub"
  for _ in $(seq 1 300); do
    if peer_status_is_ready \
      && peer_tunnel_route_live \
      && grep -Fq 'bytes from' "$STATE_DIR/private-payload.log" 2>/dev/null
    then
      "$BINARY" status --config "$CONFIG" --json --discover-secs 0
      return 0
    fi
    sleep 0.1
  done
  "$BINARY" status --config "$CONFIG" --json --discover-secs 0 || true
  ip -4 route get "$TARGET_TUNNEL_IP" >&2 || true
  tail -n 100 "$STATE_DIR/daemon.stderr.log" >&2 || true
  fail "peer did not establish one authenticated FIPS session and private payload"
}

cleanup_peer() {
  local failed=0
  stop_owned_pid ping "$PING_PID_FILE" "$PING_START_FILE" || failed=1
  if [[ -x "$BINARY" && -f "$CONFIG" ]]; then
    "$BINARY" stop --config "$CONFIG" --timeout-secs 5 --force \
      >/dev/null 2>&1 || failed=1
  fi
  stop_owned_pid daemon "$DAEMON_PID_FILE" "$DAEMON_START_FILE" || failed=1
  if [[ -x "$BINARY" && -f "$CONFIG" ]]; then
    "$BINARY" repair-network --config "$CONFIG" >/dev/null 2>&1 || failed=1
  fi
  [[ -z "$(listener_rows)" ]] || failed=1
  ip link show dev "$TUN_IFACE" >/dev/null 2>&1 && failed=1
  return "$failed"
}

clean_audit() {
  [[ ! -e "$DAEMON_PID_FILE" \
    && ! -e "$DAEMON_START_FILE" \
    && ! -e "$PING_PID_FILE" \
    && ! -e "$PING_START_FILE" ]] \
    || fail "peer process ownership receipts survived cleanup"
  [[ -z "$(listener_rows)" ]] \
    || fail "peer UDP listener survived cleanup"
  ! ip link show dev "$TUN_IFACE" >/dev/null 2>&1 \
    || fail "peer tunnel interface survived cleanup"
  printf 'peer_processes_clean=true\n'
  printf 'peer_listener_clean=true\n'
  printf 'peer_tunnel_clean=true\n'
}

log_tails() {
  local name
  for name in daemon.stdout.log daemon.stderr.log daemon.log private-payload.log; do
    printf '===== %s =====\n' "$name"
    tail -n 160 "$STATE_DIR/$name" 2>&1 || true
  done
}

require_root
validate_inputs
case "$ACTION" in
  initialize) initialize_peer ;;
  start) start_peer ;;
  wait-ready) wait_ready ;;
  listener-audit) listener_audit ;;
  status) "$BINARY" status --config "$CONFIG" --json --discover-secs 0 ;;
  log-tails) log_tails ;;
  cleanup) cleanup_peer ;;
  clean-audit) clean_audit ;;
  *)
    echo "usage: $0 {initialize|start|wait-ready|listener-audit|status|log-tails|cleanup|clean-audit}" >&2
    exit 2
    ;;
esac
