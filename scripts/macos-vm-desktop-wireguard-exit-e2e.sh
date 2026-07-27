#!/usr/bin/env bash
# Import the exact host-built macOS Release package, run its production nvpn
# binary in macos-utm, and use a real remote WireGuard/DNS fixture. The host
# Mac's routes and network services are never changed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/release_common.sh"
# shellcheck disable=SC1091
source "$ROOT/scripts/mobile_env.sh"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib-macos-vm-imported-release.sh"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib-mobile-wireguard-fixture.sh"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib-mobile-release-join-artifacts.sh"

load_release_env "$ROOT"
load_mobile_env "$ROOT"

SSH_HOST="${NVPN_MACOS_SSH_HOST:-${1:-}}"
GUEST_SRC_ROOT="${NVPN_MACOS_GUEST_SRC_ROOT:-src}"
GUEST_REPO="$GUEST_SRC_ROOT/nostr-vpn"
HOST_PORT="${NVPN_MACOS_WG_FIXTURE_PORT:-51889}"
FIPS_PEER_PORT="${NVPN_MACOS_FIPS_PEER_PORT:-51989}"
FIPS_CLIENT_LISTEN_PORT="${NVPN_MACOS_FIPS_CLIENT_LISTEN_PORT:-51990}"
TUNNEL_SERVER_IP="${NVPN_MACOS_WG_SERVER_IP:-10.99.79.1}"
TUNNEL_CLIENT_IP="${NVPN_MACOS_WG_CLIENT_IP:-10.99.79.2}"
THROUGH_DNS_IP="${NVPN_MACOS_WG_THROUGH_DNS_IP:-10.99.79.53}"
DNS_NAME="${NVPN_MACOS_WG_DNS_NAME:-macos-wireguard-exit.nvpn-e2e.test}"
# Use the fixture's already-reserved numeric port by default. WireGuard owns
# UDP while the captured HTTP probe owns TCP, so this avoids colliding with
# unrelated long-lived services on conventional ports such as 8080.
HTTP_PROBE_PORT="${NVPN_MACOS_WG_HTTP_PROBE_PORT:-$HOST_PORT}"
HTTP_PROBE_TOKEN="${NVPN_MACOS_WG_HTTP_TOKEN:-nvpn-macos-$PPID-$$-$RANDOM}"
SOURCE_IP_URL="${NVPN_MACOS_SOURCE_IP_URL:-https://api.ipify.org}"
INTERNET_URL="${NVPN_MACOS_INTERNET_URL:-https://example.com/}"
PRIMARY_SERVICE="${NVPN_MACOS_PRIMARY_NETWORK_SERVICE:-Ethernet}"
SECONDARY_SERVICE="${NVPN_MACOS_SECONDARY_NETWORK_SERVICE:-Roaming Underlay}"
PRIMARY_IFACE="${NVPN_MACOS_PRIMARY_INTERFACE:-en0}"
SECONDARY_IFACE="${NVPN_MACOS_SECONDARY_INTERFACE:-en2}"
RECOVERY_DEADLINE_MS="${NVPN_MACOS_UNDERLAY_RECOVERY_DEADLINE_MS:-4000}"
FIPS_NETWORK_ID="${NVPN_MACOS_FIPS_NETWORK_ID:-macos-release-roaming-$PPID-$$}"
IMAGE="${NVPN_MACOS_WG_FIXTURE_IMAGE:-nostr-vpn-macos-wireguard-exit-e2e}"
CONTAINER="${NVPN_MACOS_WG_FIXTURE_CONTAINER:-nostr-vpn-macos-wireguard-exit-e2e-$$}"
# The IPv4 WireGuard endpoint is intentionally separate from the FIPS peer's
# public address. An IPv4 endpoint must follow the split default in the guest,
# which proves the production Apple IP_BOUND_IF path rather than an endpoint
# host-route fallback. FIPS keeps its independently routed IPv6 endpoint.
FIXTURE_HOST="${NVPN_MACOS_WG_FIXTURE_IPV4:-}"
FIPS_FIXTURE_HOST="${NVPN_MACOS_FIPS_PEER_HOST_IP:-${NVPN_MOBILE_WG_EXIT_HOST_IP:-}}"
FIXTURE_DIR=""
REMOTE_DIR=""
SECONDARY_IP=""
EXPECTED_EXIT_SOURCE_IP=""
PACKAGE=""
ARTIFACT_DIR="${NVPN_MACOS_NETWORK_ARTIFACT_DIR:-${ARTIFACT_ROOT:-$ROOT/artifacts}/macos-release-network-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
PRIMARY_CONTROL_PATH="/tmp/nvpn-macos-network-primary-$PPID-$$"
SECONDARY_CONTROL_PATH="/tmp/nvpn-macos-network-secondary-$PPID-$$"
MOBILE_WG_FIXTURE_REMOTE_MODE=""
MOBILE_WG_FIXTURE_ENDPOINT_FAMILY=""
WIREGUARD_ENDPOINT_AUTHORITY=""
FIPS_PEER_ENDPOINT_AUTHORITY=""
FIPS_PEER_REMOTE_DIR=""
FIPS_PEER_TUN_IFACE="nmf${FIPS_PEER_PORT}"
FIPS_PEER_NPUB=""
FIPS_PEER_TUNNEL_IP=""
MACOS_NPUB=""
MACOS_TUNNEL_IP=""
FIPS_PEER_BINARY=""
FIPS_PEER_BINARY_SHA256=""
FIPS_PEER_IMPORTED=0
APP_GIT_SHA=""
APP_GIT_TREE=""

fail() {
  echo "macOS VM Release network gate failed: $*" >&2
  return 1
}

valid_npub() {
  [[ "$1" =~ ^npub1[023456789acdefghjklmnpqrstuvwxyz]{58}$ ]]
}

[[ -n "$SSH_HOST" ]] \
  || { echo "set NVPN_MACOS_SSH_HOST or pass the macOS VM SSH target" >&2; exit 2; }
[[ -n "${NVPN_MOBILE_WG_EXIT_FIXTURE_SSH_HOST:-}" ]] \
  || { echo "macOS Release network gate requires the remote Vader fixture" >&2; exit 2; }
[[ "${NVPN_MOBILE_WG_EXIT_REMOTE_MODE:-native}" == "native" ]] \
  || { echo "macOS Release network gate requires the native remote fixture" >&2; exit 2; }
[[ -n "$FIPS_FIXTURE_HOST" ]] \
  || { echo "macOS Release network gate requires the FIPS fixture address" >&2; exit 2; }
for port in "$HOST_PORT" "$FIPS_PEER_PORT" "$FIPS_CLIENT_LISTEN_PORT"; do
  [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] && ((port <= 65535)) \
    || { echo "macOS Release network gate received an invalid UDP port" >&2; exit 2; }
done
[[ "$HOST_PORT" != "$FIPS_PEER_PORT" \
  && "$HOST_PORT" != "$FIPS_CLIENT_LISTEN_PORT" \
  && "$FIPS_PEER_PORT" != "$FIPS_CLIENT_LISTEN_PORT" ]] \
  || { echo "WireGuard, remote FIPS, and local FIPS ports must be distinct" >&2; exit 2; }
[[ "$FIPS_PEER_TUN_IFACE" =~ ^[A-Za-z][A-Za-z0-9]{1,14}$ ]] \
  || { echo "derived FIPS peer tunnel interface name is invalid" >&2; exit 2; }

python3 - "$TUNNEL_SERVER_IP" "$TUNNEL_CLIENT_IP" "$THROUGH_DNS_IP" <<'PY'
import ipaddress
import sys

server, client, through = map(ipaddress.ip_address, sys.argv[1:])
network = ipaddress.ip_network(f"{server}/24", strict=False)
if (
    any(address.version != 4 for address in (server, client, through))
    or through not in network
    or len({server, client, through}) != 3
):
    raise SystemExit(
        "WireGuard server, client, and through-exit DNS addresses must be "
        "distinct IPv4 addresses in one /24"
    )
PY

ssh_args() {
  local lane="$1"
  printf '%s\n' \
    -o BatchMode=yes \
    -o ConnectTimeout=8 \
    -o ConnectionAttempts=1 \
    -o ServerAliveInterval=2 \
    -o ServerAliveCountMax=2 \
    -o ControlMaster=auto \
    -o ControlPersist=45
  if [[ "$lane" == "secondary" ]]; then
    printf '%s\n' \
      -o "ControlPath=$SECONDARY_CONTROL_PATH" \
      -o "Hostname=$SECONDARY_IP" \
      -o "HostKeyAlias=${SSH_HOST#*@}"
  else
    printf '%s\n' -o "ControlPath=$PRIMARY_CONTROL_PATH"
  fi
}

remote_shell() {
  local lane="$1" command="$2"
  local -a options=()
  while IFS= read -r option; do
    options+=("$option")
  done < <(ssh_args "$lane")
  ssh "${options[@]}" "$SSH_HOST" "$command"
}

remote_phase() {
  local lane="$1" action="$2"
  local -a options=() remote_env=()
  local remote_command quoted assignment
  while IFS= read -r option; do
    options+=("$option")
  done < <(ssh_args "$lane")
  remote_env=(
    NVPN_MACOS_VM_IMPORT_ONLY=1
    "NVPN_E2E_BINARY=$PACKAGE/Nostr VPN.app/Contents/Resources/nvpn"
    "NVPN_MACOS_NETWORK_STATE_DIR=$REMOTE_DIR"
    "NVPN_E2E_CONFIG=$REMOTE_DIR/config.toml"
    "NVPN_WG_EXIT_CONFIG_FILE=$REMOTE_DIR/client.conf"
    "NVPN_MACOS_WG_ENDPOINT_HOST=$FIXTURE_HOST"
    "NVPN_MACOS_WG_ENDPOINT_FAMILY=$MOBILE_WG_FIXTURE_ENDPOINT_FAMILY"
    "NVPN_MACOS_WG_SERVER_IP=$TUNNEL_SERVER_IP"
    "NVPN_MACOS_CAPTURED_PROBE_URL=http://$TUNNEL_SERVER_IP:$HTTP_PROBE_PORT/$HTTP_PROBE_TOKEN"
    "NVPN_MACOS_CAPTURED_PROBE_TOKEN=$HTTP_PROBE_TOKEN"
    "NVPN_MACOS_INTERNET_URL=$INTERNET_URL"
    "NVPN_MACOS_SOURCE_IP_URL=$SOURCE_IP_URL"
    "NVPN_MACOS_EXPECTED_EXIT_SOURCE_IP=$EXPECTED_EXIT_SOURCE_IP"
    "NVPN_MACOS_PRIMARY_NETWORK_SERVICE=$PRIMARY_SERVICE"
    "NVPN_MACOS_SECONDARY_NETWORK_SERVICE=$SECONDARY_SERVICE"
    "NVPN_MACOS_PRIMARY_INTERFACE=$PRIMARY_IFACE"
    "NVPN_MACOS_SECONDARY_INTERFACE=$SECONDARY_IFACE"
    "NVPN_MACOS_UNDERLAY_RECOVERY_DEADLINE_MS=$RECOVERY_DEADLINE_MS"
    "NVPN_MACOS_FIPS_NETWORK_ID=$FIPS_NETWORK_ID"
    "NVPN_MACOS_FIPS_PEER_NPUB=$FIPS_PEER_NPUB"
    "NVPN_MACOS_FIPS_PEER_ENDPOINT=$FIPS_PEER_ENDPOINT_AUTHORITY"
    "NVPN_MACOS_FIPS_PEER_TUNNEL_IP=$FIPS_PEER_TUNNEL_IP"
    "NVPN_MACOS_FIPS_CLIENT_LISTEN_PORT=$FIPS_CLIENT_LISTEN_PORT"
    "NVPN_MACOS_FIPS_EXPECTED_REV=${RELEASE_JOIN_FIPS_SHA:0:10}"
    "NVPN_MACOS_DNS_LABEL=${DNS_CASE_LABEL:-direct-baseline}"
    "NVPN_MACOS_DNS_MODE=${DNS_CASE_MODE:-automatic}"
    "NVPN_MACOS_DNS_PROVIDER=${DNS_CASE_PROVIDER:-cloudflare}"
    "NVPN_MACOS_DNS_CUSTOM_URL=${DNS_CASE_CUSTOM_URL:-}"
    "NVPN_MACOS_DNS_BOOTSTRAP_IPS=${DNS_CASE_BOOTSTRAP_IPS:-}"
    "NVPN_MACOS_DNS_THROUGH_SERVERS=${DNS_CASE_THROUGH_SERVERS:-}"
    "NVPN_MACOS_DNS_PROBE_HOST=${DNS_CASE_PROBE_HOST:-example.com}"
    "NVPN_MACOS_DNS_EXPECTED_IP=${DNS_CASE_EXPECTED_IP:-}"
  )
  printf -v quoted '%q' "$GUEST_REPO"
  remote_command="cd $quoted && env"
  for assignment in "${remote_env[@]}"; do
    printf -v quoted '%q' "$assignment"
    remote_command+=" $quoted"
  done
  printf -v quoted '%q' "$action"
  remote_command+=" ./scripts/e2e-macos-release-network.sh $quoted"
  ssh "${options[@]}" "$SSH_HOST" "$remote_command"
}

copy_guest_results() {
  [[ -n "$REMOTE_DIR" ]] || return 0
  mkdir -p "$ARTIFACT_DIR"
  local lane=primary
  [[ -n "$SECONDARY_IP" ]] && lane=secondary
  local -a options=()
  while IFS= read -r option; do
    options+=("$option")
  done < <(ssh_args "$lane")
  scp -q "${options[@]}" -r \
    "$SSH_HOST:$REMOTE_DIR/results/." "$ARTIFACT_DIR/"
}

remove_remote_dir() {
  [[ -n "$REMOTE_DIR" ]] || return 0
  local lane=primary
  [[ -n "$SECONDARY_IP" ]] && lane=secondary
  local quoted
  printf -v quoted '%q' "$REMOTE_DIR"
  remote_shell "$lane" "rm -rf -- $quoted" >/dev/null
  remote_shell "$lane" "test ! -e $quoted"
  REMOTE_DIR=""
}

close_ssh_controls() {
  ssh -o "ControlPath=$PRIMARY_CONTROL_PATH" -O exit "$SSH_HOST" \
    >/dev/null 2>&1 || true
  if [[ -n "$SECONDARY_IP" ]]; then
    ssh -o "ControlPath=$SECONDARY_CONTROL_PATH" \
      -o "Hostname=$SECONDARY_IP" \
      -o "HostKeyAlias=${SSH_HOST#*@}" \
      -O exit "$SSH_HOST" >/dev/null 2>&1 || true
  fi
}

cleanup() {
  local status="$?" cleanup_failed=0
  trap - EXIT INT TERM
  if [[ -n "$REMOTE_DIR" ]]; then
    local lane=primary
    [[ -n "$SECONDARY_IP" ]] && lane=secondary
    if remote_phase "$lane" cleanup; then
      :
    else
      echo "macOS guest production cleanup failed" >&2
      cleanup_failed=1
    fi
    if ! copy_guest_results; then
      echo "macOS guest network receipts could not be copied" >&2
      cleanup_failed=1
    fi
    if ! remove_remote_dir; then
      echo "macOS guest private fixture state survived cleanup" >&2
      cleanup_failed=1
    fi
  fi
  if ! cleanup_fips_peer; then
    cleanup_failed=1
  fi
  if mobile_wg_fixture_cleanup "$CONTAINER" "$IMAGE"; then
    :
  else
    cleanup_failed=1
  fi
  if [[ -n "$FIXTURE_DIR" ]]; then
    rm -rf "$FIXTURE_DIR"
    [[ ! -e "$FIXTURE_DIR" ]] || cleanup_failed=1
    FIXTURE_DIR=""
  fi
  close_ssh_controls
  if [[ "$status" -eq 0 && "$cleanup_failed" -ne 0 ]]; then
    status=1
  fi
  exit "$status"
}
trap cleanup EXIT INT TERM

transfer_total() {
  awk '{ print ($1 + 0) + ($2 + 0) }'
}

assert_increased() {
  local label="$1" before="$2" after="$3"
  [[ "$before" =~ ^[0-9]+$ && "$after" =~ ^[0-9]+$ \
    && "$after" -gt "$before" ]] \
    || fail "$label did not increase ($before->$after)"
}

parse_key_value() {
  local key="$1"
  awk -F= -v key="$key" \
    '$1 == key { value = substr($0, length(key) + 2) } END { print value }'
}

discover_remote_fixture_ipv4() {
  mobile_wg_remote_exec sh -c '
    ip -4 route get 1.1.1.1 |
      awk '"'"'{ for (field = 1; field <= NF; field++) {
        if ($field == "src" && field < NF) {
          print $(field + 1)
          exit
        }
      } }'"'"'
  '
}

prepare_host_fips_peer_binary() {
  FIPS_PEER_BINARY="$("$ROOT/scripts/prepare-macos-release-fips-peer.sh")"
  [[ "$FIPS_PEER_BINARY" == /* && -x "$FIPS_PEER_BINARY" ]] \
    || fail "host FIPS peer cache returned no executable"
  FIPS_PEER_BINARY_SHA256="$(
    shasum -a 256 "$FIPS_PEER_BINARY" | awk '{ print $1 }'
  )"
  [[ "$FIPS_PEER_BINARY_SHA256" =~ ^[0-9a-f]{64}$ ]] \
    || fail "host FIPS peer cache returned an invalid SHA-256"
  mkdir -p "$ARTIFACT_DIR"
  cp "$(dirname "$FIPS_PEER_BINARY")/receipt.json" \
    "$ARTIFACT_DIR/fips-peer-host-receipt.json"
}

fips_peer_remote() {
  local action="$1"
  mobile_wg_remote_exec \
    sudo -n env \
    "PATH=$MOBILE_WG_FIXTURE_REMOTE_PATH" \
    "NVPN_MACOS_FIPS_PEER_STATE_DIR=$FIPS_PEER_REMOTE_DIR/state" \
    "NVPN_MACOS_FIPS_PEER_BINARY=$FIPS_PEER_REMOTE_DIR/nvpn-peer" \
    "NVPN_MACOS_FIPS_PEER_TUN_IFACE=$FIPS_PEER_TUN_IFACE" \
    "NVPN_MACOS_FIPS_PEER_LISTEN_PORT=$FIPS_PEER_PORT" \
    "NVPN_MACOS_FIPS_NETWORK_ID=$FIPS_NETWORK_ID" \
    "NVPN_MACOS_FIPS_PEER_PUBLIC_ENDPOINT=$FIPS_PEER_ENDPOINT_AUTHORITY" \
    "NVPN_MACOS_FIPS_TARGET_NPUB=$MACOS_NPUB" \
    "NVPN_MACOS_FIPS_TARGET_TUNNEL_IP=$MACOS_TUNNEL_IP" \
    "NVPN_MACOS_FIPS_PEER_BINARY_SHA256=$FIPS_PEER_BINARY_SHA256" \
    "NVPN_MACOS_FIPS_EXPECTED_REV=${RELEASE_JOIN_FIPS_SHA:0:10}" \
    "NVPN_MACOS_FIPS_EXPECTED_APP_SHA=$APP_GIT_SHA" \
    "$FIPS_PEER_REMOTE_DIR/runner.sh" "$action"
}

import_host_fips_peer_binary() {
  local fixture_ssh="${NVPN_MOBILE_WG_EXIT_FIXTURE_SSH_HOST:?}"
  [[ -n "$MOBILE_WG_FIXTURE_REMOTE_DIR" ]] \
    || fail "remote WireGuard fixture SSH session is not initialized"
  FIPS_PEER_REMOTE_DIR="$(
    mobile_wg_remote_exec mktemp -d /tmp/nvpn-macos-fips-peer.XXXXXX
  )"
  case "$FIPS_PEER_REMOTE_DIR" in
    /tmp/nvpn-macos-fips-peer.*) ;;
    *) fail "Vader returned an unsafe FIPS peer temporary directory" ;;
  esac
  mobile_wg_remote_exec \
    mkdir -p "$FIPS_PEER_REMOTE_DIR/state"
  mobile_wg_remote_exec \
    chmod 700 "$FIPS_PEER_REMOTE_DIR" "$FIPS_PEER_REMOTE_DIR/state"
  scp -q \
    -o BatchMode=yes \
    -o ConnectTimeout=10 \
    -o "ControlPath=$MOBILE_WG_FIXTURE_SSH_CONTROL_PATH" \
    "$FIPS_PEER_BINARY" \
    "$fixture_ssh:$FIPS_PEER_REMOTE_DIR/nvpn-peer"
  scp -q \
    -o BatchMode=yes \
    -o ConnectTimeout=10 \
    -o "ControlPath=$MOBILE_WG_FIXTURE_SSH_CONTROL_PATH" \
    "$ROOT/scripts/macos-release-fips-peer-remote.sh" \
    "$fixture_ssh:$FIPS_PEER_REMOTE_DIR/runner.sh"
  scp -q \
    -o BatchMode=yes \
    -o ConnectTimeout=10 \
    -o "ControlPath=$MOBILE_WG_FIXTURE_SSH_CONTROL_PATH" \
    "$ROOT/scripts/lib-desktop-linux-listener-audit.sh" \
    "$fixture_ssh:$FIPS_PEER_REMOTE_DIR/lib-desktop-linux-listener-audit.sh"
  mobile_wg_remote_exec \
    chmod 0500 \
    "$FIPS_PEER_REMOTE_DIR/nvpn-peer" \
    "$FIPS_PEER_REMOTE_DIR/runner.sh"
  mobile_wg_remote_exec \
    chmod 0400 "$FIPS_PEER_REMOTE_DIR/lib-desktop-linux-listener-audit.sh"
  [[ "$(
    mobile_wg_remote_exec \
      sha256sum "$FIPS_PEER_REMOTE_DIR/nvpn-peer" \
      | awk '{ print $1 }'
  )" == "$FIPS_PEER_BINARY_SHA256" ]] \
    || fail "Vader peer binary differs from the host-built immutable artifact"
  FIPS_PEER_IMPORTED=1
}

cleanup_fips_peer() {
  [[ -n "$FIPS_PEER_REMOTE_DIR" ]] || return 0
  local failed=0
  if [[ "$FIPS_PEER_IMPORTED" -eq 1 ]]; then
    fips_peer_remote cleanup >/dev/null 2>&1 || failed=1
    mkdir -p "$ARTIFACT_DIR"
    fips_peer_remote clean-audit \
      >"$ARTIFACT_DIR/fips-peer-cleanup-audit.txt" 2>&1 || failed=1
  fi
  if [[ "$failed" -ne 0 ]]; then
    echo "remote FIPS peer did not prove complete owned cleanup; preserving its state" >&2
    return 1
  fi
  mobile_wg_remote_exec \
    sudo -n find "$FIPS_PEER_REMOTE_DIR" -xdev -depth -mindepth 1 -delete \
    >/dev/null 2>&1 || failed=1
  mobile_wg_remote_exec sudo -n rmdir "$FIPS_PEER_REMOTE_DIR" \
    >/dev/null 2>&1 || failed=1
  mobile_wg_remote_exec test ! -e "$FIPS_PEER_REMOTE_DIR" \
    >/dev/null 2>&1 || failed=1
  if [[ "$failed" -eq 0 ]]; then
    FIPS_PEER_IMPORTED=0
    FIPS_PEER_REMOTE_DIR=""
  else
    echo "remote FIPS peer temporary directory survived cleanup" >&2
  fi
  return "$failed"
}

release_join_require_clean_fips
APP_GIT_SHA="$(git -C "$ROOT" rev-parse HEAD)"
APP_GIT_TREE="$(git -C "$ROOT" rev-parse HEAD^{tree})"
release_join_assert_app_unchanged "$APP_GIT_SHA" "$APP_GIT_TREE"

macos_vm_prepare_or_verify_imported_release "$ROOT" "$SSH_HOST"
PACKAGE="$(macos_vm_imported_release_package "$GUEST_REPO")"
prepare_host_fips_peer_binary

if [[ -z "$FIXTURE_HOST" ]]; then
  FIXTURE_HOST="$(discover_remote_fixture_ipv4)" \
    || fail "could not discover the remote fixture's reachable IPv4 address"
fi
ENDPOINT_FIELDS="$(
  mobile_wg_endpoint_fields "$FIXTURE_HOST" "$HOST_PORT"
)" || fail "remote fixture endpoint is malformed"
IFS=$'\t' read -r \
  MOBILE_WG_FIXTURE_ENDPOINT_FAMILY \
  FIXTURE_HOST \
  WIREGUARD_ENDPOINT_AUTHORITY <<<"$ENDPOINT_FIELDS"
[[ "$MOBILE_WG_FIXTURE_ENDPOINT_FAMILY" == "ipv4" ]] \
  || fail "macOS underlay gate requires a reachable numeric IPv4 WireGuard endpoint"
FIPS_ENDPOINT_FIELDS="$(
  mobile_wg_endpoint_fields "$FIPS_FIXTURE_HOST" "$FIPS_PEER_PORT"
)" || fail "remote FIPS peer endpoint is malformed"
IFS=$'\t' read -r \
  fips_endpoint_family \
  fips_endpoint_host \
  FIPS_PEER_ENDPOINT_AUTHORITY <<<"$FIPS_ENDPOINT_FIELDS"
[[ "$fips_endpoint_family" == "ipv6" \
  && "$fips_endpoint_host" != "$FIXTURE_HOST" ]] \
  || fail "remote FIPS peer must use its separate numeric IPv6 address"
export NVPN_MOBILE_WG_EXIT_HOST_IP="$FIXTURE_HOST"
export NVPN_MOBILE_WG_EXIT_REMOTE_MODE=native

FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nvpn-macos-wg-exit.XXXXXX")"
chmod 700 "$FIXTURE_DIR"
umask 077
wg genkey >"$FIXTURE_DIR/server.key"
wg pubkey <"$FIXTURE_DIR/server.key" >"$FIXTURE_DIR/server.pub"
wg genkey >"$FIXTURE_DIR/client.key"
wg pubkey <"$FIXTURE_DIR/client.key" >"$FIXTURE_DIR/client.pub"

mobile_wg_fixture_initialize "$ROOT" "$FIXTURE_DIR"
import_host_fips_peer_binary
mkdir -p "$ARTIFACT_DIR"
fips_peer_initialize_output="$(fips_peer_remote initialize)"
printf '%s\n' "$fips_peer_initialize_output" \
  >"$ARTIFACT_DIR/fips-peer-import-provenance.txt"
FIPS_PEER_NPUB="$(
  parse_key_value npub <<<"$fips_peer_initialize_output"
)"
FIPS_PEER_TUNNEL_IP="$(
  parse_key_value tunnel_ip <<<"$fips_peer_initialize_output"
)"
valid_npub "$FIPS_PEER_NPUB" \
  || fail "imported FIPS peer returned an invalid identity"
[[ -n "$FIPS_PEER_TUNNEL_IP" ]] \
  || fail "imported FIPS peer returned no private tunnel address"
mobile_wg_fixture_assert_available "$CONTAINER" "$HOST_PORT"
EXPECTED_EXIT_SOURCE_IP="$(
  mobile_wg_remote_exec curl -4fsS --max-time 8 "$SOURCE_IP_URL"
)"
[[ -n "$EXPECTED_EXIT_SOURCE_IP" ]] \
  || fail "remote fixture has no IPv4 egress receipt"

cat >"$FIXTURE_DIR/client.conf" <<EOF
[Interface]
PrivateKey = $(<"$FIXTURE_DIR/client.key")
Address = $TUNNEL_CLIENT_IP/32
DNS = $TUNNEL_SERVER_IP
MTU = 1280

[Peer]
PublicKey = $(<"$FIXTURE_DIR/server.pub")
Endpoint = $WIREGUARD_ENDPOINT_AUTHORITY
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 2
EOF
grep -Fxq "DNS = $TUNNEL_SERVER_IP" "$FIXTURE_DIR/client.conf" \
  || fail "Automatic/profile WireGuard config lost the fixture DNS server"

mobile_wg_fixture_build "$ROOT" "$IMAGE" 0
mobile_wg_fixture_run "$IMAGE" "$CONTAINER" "$MOBILE_WG_FIXTURE_VOLUME_DIR"
for _ in $(seq 1 100); do
  mobile_wg_fixture_ready "$CONTAINER" >/dev/null 2>&1 && break
  mobile_wg_fixture_running "$CONTAINER" \
    || fail "remote fixture stopped during readiness"
  sleep 0.1
done
mobile_wg_fixture_ready "$CONTAINER" \
  || { mobile_wg_fixture_logs "$CONTAINER" >&2; fail "remote fixture is not ready"; }

REMOTE_DIR="$(
  remote_shell primary 'mktemp -d /tmp/nvpn-macos-release-network.XXXXXX'
)"
case "$REMOTE_DIR" in
  /tmp/nvpn-macos-release-network.*) ;;
  *) fail "macos-utm returned an unsafe temporary path" ;;
esac
remote_shell primary "chmod 700 '$REMOTE_DIR'"
scp -q -o BatchMode=yes \
  -o "ControlPath=$PRIMARY_CONTROL_PATH" \
  "$FIXTURE_DIR/client.conf" "$SSH_HOST:$REMOTE_DIR/client.conf"

SECONDARY_IP="$(
  remote_shell primary \
    "/usr/sbin/networksetup -getinfo '$SECONDARY_SERVICE'" \
    | awk -F': ' '/^IP address:/ { print $2; exit }'
)"
[[ "$SECONDARY_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || fail "could not resolve macos-utm's secondary guest address"
remote_shell secondary 'true'

mkdir -p "$ARTIFACT_DIR"
macos_identity_output="$(remote_phase primary initialize)"
printf '%s\n' "$macos_identity_output" \
  >"$ARTIFACT_DIR/macos-fips-identity.txt"
MACOS_NPUB="$(parse_key_value npub <<<"$macos_identity_output")"
MACOS_TUNNEL_IP="$(parse_key_value tunnel_ip <<<"$macos_identity_output")"
valid_npub "$MACOS_NPUB" \
  || fail "macos-utm returned an invalid imported-Release identity"
[[ -n "$MACOS_TUNNEL_IP" ]] \
  || fail "macos-utm returned no private tunnel address"
fips_peer_remote start
DNS_CASE_LABEL=direct-baseline
DNS_CASE_PROBE_HOST=example.com
remote_phase primary prepare
fips_peer_remote wait-ready >"$ARTIFACT_DIR/fips-peer-ready.json"
fips_peer_remote listener-audit >"$ARTIFACT_DIR/fips-peer-listener.txt"
python3 - "$ARTIFACT_DIR/fips-peer-ready.json" "$MACOS_NPUB" <<'PY'
import json
import sys

path, expected = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    status = json.load(handle)
state = status.get("daemon", {}).get("state", {})
peers = state.get("fips_endpoint_peers", [])
if not (
    status.get("status_source") == "daemon"
    and status.get("daemon", {}).get("running") is True
    and state.get("mesh_ready") is True
    and state.get("connected_peer_count") == 1
    and len(peers) == 1
    and peers[0].get("npub") == expected
):
    raise SystemExit("remote peer readiness did not prove one exact authenticated peer")
PY

for DNS_CASE_LABEL in \
  automatic-profile cloudflare-doh quad9-doh custom-doh through-exit
do
  IFS='|' read -r \
    DNS_CASE_MODE \
    DNS_CASE_PROVIDER \
    DNS_CASE_CUSTOM_URL \
    DNS_CASE_BOOTSTRAP_IPS \
    DNS_CASE_THROUGH_SERVERS \
    DNS_CASE_PROBE_HOST \
    DNS_CASE_EXPECTED_IP \
    evidence <<<"$(
      mobile_wg_dns_case_fields \
        "$DNS_CASE_LABEL" "$DNS_NAME" "$TUNNEL_SERVER_IP" "$THROUGH_DNS_IP"
    )"
  before_transfer="$(
    mobile_wg_fixture_wg_bytes "$CONTAINER" | transfer_total
  )"
  before_forward="$(mobile_wg_fixture_forward_packets "$CONTAINER")"
  before_evidence="$(
    mobile_wg_fixture_dns_evidence_snapshot \
      "$CONTAINER" "$DNS_CASE_PROBE_HOST"
  )"
  remote_phase primary dns-case
  after_transfer="$(
    mobile_wg_fixture_wg_bytes "$CONTAINER" | transfer_total
  )"
  after_forward="$(mobile_wg_fixture_forward_packets "$CONTAINER")"
  after_evidence="$(
    mobile_wg_fixture_dns_evidence_snapshot \
      "$CONTAINER" "$DNS_CASE_PROBE_HOST"
  )"
  assert_increased "$DNS_CASE_LABEL WireGuard bytes" \
    "$before_transfer" "$after_transfer"
  assert_increased "$DNS_CASE_LABEL forwarded packets" \
    "$before_forward" "$after_forward"
  mobile_wg_fixture_assert_dns_case_evidence \
    macOS "$DNS_CASE_LABEL" "$evidence" "$before_evidence" "$after_evidence"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$DNS_CASE_LABEL" \
    "$before_transfer" "$after_transfer" \
    "$before_forward" "$after_forward" \
    "$before_evidence" "$after_evidence" \
    >>"$ARTIFACT_DIR/fixture-dns-counters.tsv"
done

before_transfer="$(
  mobile_wg_fixture_wg_bytes "$CONTAINER" | transfer_total
)"
before_forward="$(mobile_wg_fixture_forward_packets "$CONTAINER")"
remote_phase primary underlay-start
underlay_status="$(
  remote_shell secondary "
    for ignored in \$(seq 1 300); do
      status=\$(cat '$REMOTE_DIR/underlay.status' 2>/dev/null || true)
      case \"\$status\" in
        pass|fail:*) printf '%s\\n' \"\$status\"; exit 0 ;;
      esac
      sleep 0.1
    done
    echo timeout
  "
)"
if [[ "$underlay_status" != "pass" ]]; then
  remote_shell secondary \
    "tail -n 120 '$REMOTE_DIR/results/underlay-run.log'" >&2 || true
  fail "macos-utm underlay action ended with $underlay_status"
fi
after_transfer="$(
  mobile_wg_fixture_wg_bytes "$CONTAINER" | transfer_total
)"
after_forward="$(mobile_wg_fixture_forward_packets "$CONTAINER")"
assert_increased "macOS underlay WireGuard bytes" \
  "$before_transfer" "$after_transfer"
assert_increased "macOS underlay forwarded packets" \
  "$before_forward" "$after_forward"
fips_peer_remote wait-ready >"$ARTIFACT_DIR/fips-peer-after-underlay.json"
fips_peer_remote listener-audit \
  >"$ARTIFACT_DIR/fips-peer-listener-after-underlay.txt"

before_transfer="$(
  mobile_wg_fixture_wg_bytes "$CONTAINER" | transfer_total
)"
before_forward="$(mobile_wg_fixture_forward_packets "$CONTAINER")"
remote_phase secondary crash-restart
after_transfer="$(
  mobile_wg_fixture_wg_bytes "$CONTAINER" | transfer_total
)"
after_forward="$(mobile_wg_fixture_forward_packets "$CONTAINER")"
assert_increased "macOS SIGKILL/restart WireGuard bytes" \
  "$before_transfer" "$after_transfer"
assert_increased "macOS SIGKILL/restart forwarded packets" \
  "$before_forward" "$after_forward"
fips_peer_remote wait-ready >"$ARTIFACT_DIR/fips-peer-after-crash-restart.json"
fips_peer_remote listener-audit \
  >"$ARTIFACT_DIR/fips-peer-listener-after-crash-restart.txt"

DNS_CASE_LABEL=direct-restore
DNS_CASE_MODE=automatic
DNS_CASE_PROVIDER=cloudflare
DNS_CASE_CUSTOM_URL=""
DNS_CASE_BOOTSTRAP_IPS=""
DNS_CASE_THROUGH_SERVERS=""
DNS_CASE_PROBE_HOST=example.com
DNS_CASE_EXPECTED_IP=""
remote_phase secondary direct
copy_guest_results
remote_phase secondary cleanup
remove_remote_dir
cleanup_fips_peer
mobile_wg_fixture_cleanup "$CONTAINER" "$IMAGE"

echo "MACOS_VM_WIREGUARD_EXIT_E2E_OK"
echo "Real Direct -> authenticated FIPS + IPv4 WireGuard -> two-underlay handoff -> SIGKILL/restart -> Direct and all five DNS modes passed"
