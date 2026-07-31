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
  chmod 600 "$STATE_DIR/daemon.cleanup.json" 2>/dev/null || true
  cat >"$STATE_DIR/daemon.cleanup.json" <<'JSON'
{"managed_routes":[{"gateway":"192.0.2.1","target":"0.0.0.0/1"},{"gateway":"192.0.2.1","target":"128.0.0.0/1"}],"secure_dns_resolver_files":true}
JSON
  chmod 000 "$STATE_DIR/daemon.cleanup.json"
}

privileged_cleanup_journal_bytes() {
  chmod 600 "$STATE_DIR/daemon.cleanup.json"
  cat "$STATE_DIR/daemon.cleanup.json"
  local status="$?"
  chmod 000 "$STATE_DIR/daemon.cleanup.json"
  return "$status"
}

privileged_cleanup_journal_stat() {
  printf 'file=%s type=Regular File mode=-rw------- mode_octal=100600 uid=0 user=root gid=0 group=wheel size=1 modified_epoch=1\n' \
    "$STATE_DIR/daemon.cleanup.json"
}

# A transiently incomplete journal must be polled rather than failed once.
printf '{"managed_routes":[],"secure_dns_resolver_files":false}\n' \
  >"$STATE_DIR/daemon.cleanup.json"
chmod 000 "$STATE_DIR/daemon.cleanup.json"
if cat "$STATE_DIR/daemon.cleanup.json" >/dev/null 2>&1; then
  fail "the modeled unprivileged caller read the root-only journal"
fi
sleep() {
  write_valid_journal
}
wait_for_crash_ownership_precondition \
  || fail "transient ownership state did not converge"
grep -Fxq 'polls=2' "$RESULT_DIR/crash-ownership-precondition.txt" \
  || fail "ownership precondition was not polled"
cleanup_journal_owns_wireguard_and_dns \
  || fail "the converged journal did not retain the strict predicate"

# A stable incomplete journal must retain only sanitized fields and source stat.
chmod 600 "$STATE_DIR/daemon.cleanup.json"
cat >"$STATE_DIR/daemon.cleanup.json" <<'JSON'
{"managed_routes":[{"gateway":"192.0.2.1","target":"0.0.0.0/1"}],"private_key":"must-not-enter-evidence","secure_dns_resolver_files":false}
JSON
chmod 000 "$STATE_DIR/daemon.cleanup.json"
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

/usr/bin/python3 - \
  "$RESULT_DIR/crash-ownership-required-fields.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    state = json.load(handle)
assert state["journal_readable"] is True
assert state["secure_dns_resolver_files"] is False
assert state["owns_required_wireguard_and_dns"] is False
assert state["required_managed_route_counts"]["0.0.0.0/1"] == 1
assert state["required_managed_route_counts"]["128.0.0.0/1"] == 0
PY
grep -Fq 'mode=-rw-------' \
  "$RESULT_DIR/crash-ownership-source-stat.txt" \
  || fail "root-only source mode was not retained"
if rg -q 'private_key|must-not-enter-evidence|gateway' "$RESULT_DIR"; then
  fail "sanitized crash evidence exposed a non-required journal field"
fi
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
