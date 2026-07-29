#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/lib-release-gate-timeout.sh"

fail() {
  printf 'release gate timeout harness failed: %s\n' "$*" >&2
  exit 1
}

assert_status() {
  local expected="$1"
  local label="$2"
  shift 2
  local status
  set +e
  "$@" >/tmp/nvpn-release-gate-timeout-test.out 2>/tmp/nvpn-release-gate-timeout-test.err
  status=$?
  set -e
  if [[ "$status" != "$expected" ]]; then
    cat /tmp/nvpn-release-gate-timeout-test.out >&2 || true
    cat /tmp/nvpn-release-gate-timeout-test.err >&2 || true
    fail "$label returned $status, expected $expected"
  fi
}

assert_status 0 "success command" \
  release_gate_run_with_timeout "success command" 5 bash -c 'exit 0'

assert_status 0 "success watchdog cleanup" \
  release_gate_run_with_timeout "success watchdog cleanup" 173 bash -c 'exit 0'
if ps -axo command= | awk '$1 == "sleep" && $2 == "173" { found = 1 } END { exit found ? 0 : 1 }'; then
  fail "success watchdog cleanup left sleep 173 running"
fi

assert_status 7 "failure propagation" \
  release_gate_run_with_timeout "failure command" 5 bash -c 'exit 7'

assert_status 3 "disabled timeout still propagates command status" \
  release_gate_run_with_timeout "disabled command" off bash -c 'exit 3'

assert_status 2 "invalid timeout" \
  release_gate_run_with_timeout "invalid command" bananas bash -c 'exit 0'

assert_status 2 "invalid termination grace" \
  env NVPN_RELEASE_GATE_TIMEOUT_KILL_AFTER_SECS=zero \
  bash -c 'source "$1"; release_gate_run_with_timeout "invalid grace" 5 bash -c "exit 0"' \
  _ "$ROOT_DIR/scripts/lib-release-gate-timeout.sh"

assert_status 124 "sleep timeout" \
  release_gate_run_with_timeout "sleep command" 1 bash -c 'sleep 10'

printf 'release gate timeout harness passed\n'
