#!/usr/bin/env bash
# Focused contract for bounded, externally observable macOS crash evidence.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUEST="$ROOT/scripts/e2e-macos-release-network.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/nvpn-macos-crash-external.XXXXXX")"
DEFINITIONS="$TMP_ROOT/definitions.sh"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

fail() {
  echo "macOS crash external-state diagnostics harness failed: $*" >&2
  exit 1
}

bash -n "$GUEST"
if grep -Eq 'sudo -n /(bin/cat|usr/bin/stat)' "$GUEST"; then
  fail "the guest harness uses unapproved privileged file inspection"
fi
if grep -Fq 'daemon.cleanup.json' "$GUEST"; then
  fail "the unprivileged guest harness reads the daemon's private journal"
fi
while IFS= read -r sudo_line; do
  sudo_line="${sudo_line#*sudo -n }"
  case "$sudo_line" in
    '"$NVPN_BIN" '*|'/usr/sbin/networksetup '*|'/usr/sbin/networksetup \'|'/bin/kill '*) ;;
    *) fail "guest harness sudo command is outside its explicit allowlist: $sudo_line" ;;
  esac
done < <(grep -F 'sudo -n ' "$GUEST")

sed '/^validate_inputs$/,$d' "$GUEST" >"$DEFINITIONS"
export NVPN_MACOS_NETWORK_STATE_DIR="$TMP_ROOT/state"
mkdir -p "$NVPN_MACOS_NETWORK_STATE_DIR/results"
# shellcheck disable=SC1090
source "$DEFINITIONS"

STATE_DIR="$NVPN_MACOS_NETWORK_STATE_DIR"
RESULT_DIR="$STATE_DIR/results"
CONFIG="$STATE_DIR/config.toml"
ENDPOINT_FAMILY=ipv4
ENDPOINT_HOST=192.0.2.10
FIPS_PEER_TUNNEL_IP=100.64.0.2
PRIMARY_IFACE=en0
WAIT_SECS=2
SECURE_RESOLVER="$STATE_DIR/nvpn-secure-dns"
MAGIC_RESOLVER="$STATE_DIR/nvpn"
printf 'config\n' >"$CONFIG"
printf 'Managed by nvpn secure DNS\nnameserver 127.0.0.1\n' >"$MAGIC_RESOLVER"

wireguard_interface() { printf 'utun9\n'; }
wireguard_endpoint_route_state_valid() { [[ "$1" == en0 ]]; }
secure_dns_owned() { return 0; }
wireguard_routes_live() { return 0; }
runtime_wireguard_state_is() { [[ "$1 $2" == 'true true' ]]; }
runtime_dns_state_matches() { return 0; }
runtime_fips_peer_connected() { return 0; }
capture_fips_host_tunnel_route() { printf 'utun8\n'; }
no_nvpn_processes() { return 0; }
capture_underlay_routes() { printf 'route snapshot\n'; }
secure_dns_store_state() { printf 'dynamic resolver snapshot\n'; }
nvpn() { printf '{"daemon":{"running":true}}\n'; }

# The startup completion receipt must follow WireGuard setup. It is the public
# log point reached only after mandatory cleanup-ownership persistence succeeds.
cat >"$STATE_DIR/daemon.log" <<'LOG'
daemon: FIPS private mesh on utun8
fips: WG upstream up on utun9 via 192.0.2.1 bound to en0 (split-default kill switch installed)
LOG
if crash_startup_log_order_is_valid; then
  fail "reversed startup persistence ordering was accepted"
fi

cat >"$STATE_DIR/daemon.log" <<'LOG'
fips: WG upstream up on utun9 via 192.0.2.1 bound to en0 (split-default kill switch installed)
LOG
sleep() {
  printf '%s\n' 'daemon: FIPS private mesh on utun8' >>"$STATE_DIR/daemon.log"
}
wait_for_crash_live_precondition \
  || fail "transient external startup state did not converge"
grep -Fxq 'polls=2' "$RESULT_DIR/crash-external-precondition.txt" \
  || fail "external startup precondition was not polled"
grep -Fxq 'startup_log_order=true' \
  "$RESULT_DIR/crash-external-precondition-predicates.txt" \
  || fail "ordered startup completion was not retained"
grep -Fq 'WG upstream up on utun9' \
  "$RESULT_DIR/crash-external-precondition-startup-order.txt" \
  || fail "WireGuard startup receipt was not retained"
grep -Fq 'FIPS private mesh on utun8' \
  "$RESULT_DIR/crash-external-precondition-startup-order.txt" \
  || fail "post-persistence FIPS startup receipt was not retained"

# A stable externally visible failure must retain predicate, route, resolver,
# status, and daemon-log evidence without inspecting the private journal.
WAIT_SECS=1
runtime_dns_state_matches() { return 1; }
sleep() { SECONDS=$((SECONDS + 1)); }
if wait_for_crash_live_precondition; then
  fail "stable external DNS mismatch passed"
fi
capture_crash_external_failure
grep -Fxq 'runtime_dns_state_matches=false' \
  "$RESULT_DIR/crash-external-failure-predicates.txt" \
  || fail "failing DNS predicate was not retained"
grep -Fxq 'route snapshot' \
  "$RESULT_DIR/crash-external-failure-routes.txt" \
  || fail "live routes were not retained"
grep -Fq 'dynamic resolver snapshot' \
  "$RESULT_DIR/crash-external-failure-resolver-state.txt" \
  || fail "live resolver state was not retained"
grep -Fq 'nameserver 127.0.0.1' \
  "$RESULT_DIR/crash-external-failure-resolver-state.txt" \
  || fail "resolver file state was not retained"
grep -Fq '"running":true' \
  "$RESULT_DIR/crash-external-failure-status.json" \
  || fail "daemon status was not retained"
cmp -s "$STATE_DIR/daemon.log" \
  "$RESULT_DIR/crash-external-failure-daemon.log" \
  || fail "the daemon log was not retained exactly"
if find "$STATE_DIR" -name '*cleanup*json' -print -quit | grep -q .; then
  fail "focused test created or inspected a private cleanup journal fixture"
fi

echo "MACOS_CRASH_EXTERNAL_DIAGNOSTICS_HARNESS_OK"
