#!/usr/bin/env bash
# Focused contract for bounded macOS crash-ownership polling and evidence.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUEST="$ROOT/scripts/e2e-macos-release-network.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/nvpn-macos-crash-ownership.XXXXXX")"
DEFINITIONS="$TMP_ROOT/definitions.sh"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

fail() {
  echo "macOS crash ownership diagnostics harness failed: $*" >&2
  exit 1
}

bash -n "$GUEST"
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
WAIT_SECS=2
SECURE_RESOLVER="$STATE_DIR/nvpn-secure-dns"
MAGIC_RESOLVER="$STATE_DIR/nvpn"
printf 'config\n' >"$CONFIG"
printf 'daemon log\n' >"$STATE_DIR/daemon.log"

write_valid_journal() {
  cat >"$STATE_DIR/daemon.cleanup.json" <<'JSON'
{"managed_routes":[{"gateway":"192.0.2.1","target":"0.0.0.0/1"},{"gateway":"192.0.2.1","target":"128.0.0.0/1"}],"secure_dns_resolver_files":true}
JSON
}

# A transiently incomplete journal must be polled rather than failed once.
printf '{"managed_routes":[],"secure_dns_resolver_files":false}\n' \
  >"$STATE_DIR/daemon.cleanup.json"
sleep() {
  write_valid_journal
}
wait_for_crash_ownership_precondition \
  || fail "transient ownership state did not converge"
grep -Fxq 'polls=2' "$RESULT_DIR/crash-ownership-precondition.txt" \
  || fail "ownership precondition was not polled"
cleanup_journal_owns_wireguard_and_dns \
  || fail "the converged journal did not retain the strict predicate"

# A stable incomplete journal must retain exact and parsed state before failure.
cat >"$STATE_DIR/daemon.cleanup.json" <<'JSON'
{"managed_routes":[{"gateway":"192.0.2.1","target":"0.0.0.0/1"}],"secure_dns_resolver_files":false}
JSON
cp "$STATE_DIR/daemon.cleanup.json" "$TMP_ROOT/expected-journal.json"
WAIT_SECS=1
sleep() { command sleep "$@"; }
capture_underlay_routes() { printf 'route snapshot\n'; }
secure_dns_store_state() { printf 'dynamic resolver snapshot\n'; }
nvpn() { printf '{"daemon":{"running":true}}\n'; }
printf 'nameserver 127.0.0.1\n' >"$MAGIC_RESOLVER"
if wait_for_crash_ownership_precondition; then
  fail "stable incomplete ownership state passed"
fi
capture_crash_ownership_failure

cmp -s \
  "$TMP_ROOT/expected-journal.json" \
  "$RESULT_DIR/crash-ownership-daemon.cleanup.json" \
  || fail "the exact cleanup journal was not retained"
/usr/bin/python3 - \
  "$RESULT_DIR/crash-ownership-required-fields.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    state = json.load(handle)
assert state["snapshot_present"] is True
assert state["secure_dns_resolver_files"] is False
assert len(state["required_managed_routes"]["0.0.0.0/1"]) == 1
assert state["required_managed_routes"]["128.0.0.0/1"] == []
PY
grep -Fxq 'route snapshot' \
  "$RESULT_DIR/crash-ownership-live-routes.txt" \
  || fail "live routes were not retained"
grep -Fq 'dynamic resolver snapshot' \
  "$RESULT_DIR/crash-ownership-live-resolver-state.txt" \
  || fail "live resolver state was not retained"
grep -Fq 'nameserver 127.0.0.1' \
  "$RESULT_DIR/crash-ownership-live-resolver-state.txt" \
  || fail "resolver file state was not retained"
grep -Fq '"running":true' \
  "$RESULT_DIR/crash-ownership-daemon-status.json" \
  || fail "daemon status was not retained"
cmp -s "$STATE_DIR/daemon.log" \
  "$RESULT_DIR/crash-ownership-daemon.log" \
  || fail "the daemon log was not retained exactly"

echo "MACOS_CRASH_OWNERSHIP_DIAGNOSTICS_HARNESS_OK"
