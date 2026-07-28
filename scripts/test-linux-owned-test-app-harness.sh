#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib-linux-owned-test-app.sh"

[[ "$(uname -s)" == "Linux" && -d /proc ]] || {
  echo "Linux exact-app cleanup harness requires Linux /proc." >&2
  exit 2
}

if [[ "${1:-}" != "--child" ]]; then
  for command in cc python3 readlink; do
    command -v "$command" >/dev/null 2>&1 || {
      echo "Linux exact-app cleanup harness requires $command." >&2
      exit 2
    }
  done
  temp="$(mktemp -d /tmp/nvpn-linux-exact-app.XXXXXX)"
  trap 'rm -rf "$temp"' EXIT
  printf '%s\n' \
    '#include <signal.h>' \
    '#include <unistd.h>' \
    'int main(void) {' \
    '  signal(SIGTERM, SIG_IGN);' \
    '  for (;;) pause();' \
    '}' \
    | cc -x c -o "$temp/exact-app" -
  "$0" --child "$temp/exact-app"
  echo "LINUX_OWNED_TEST_APP_HARNESS_OK"
  exit 0
fi

app="${2:?missing exact test executable}"
exact_pid=""
decoy_pid=""
cleanup() {
  local status="$?"
  trap - EXIT
  [[ -z "$exact_pid" ]] || kill -KILL "$exact_pid" >/dev/null 2>&1 || true
  [[ -z "$decoy_pid" ]] || kill -KILL "$decoy_pid" >/dev/null 2>&1 || true
  [[ -z "$exact_pid" ]] || wait "$exact_pid" >/dev/null 2>&1 || true
  [[ -z "$decoy_pid" ]] || wait "$decoy_pid" >/dev/null 2>&1 || true
  exit "$status"
}
trap cleanup EXIT

"$app" &
exact_pid="$!"
disown "$exact_pid"
python3 -c 'import time; time.sleep(300)' "$app" &
decoy_pid="$!"
sleep 0.1

[[ "$(linux_exact_executable_pids "$app")" == "$exact_pid" ]]
kill -TERM "$exact_pid"
sleep 0.1
kill -0 "$exact_pid"

linux_stop_exact_test_app "$app"
! kill -0 "$exact_pid" 2>/dev/null
exact_pid=""
kill -0 "$decoy_pid"

kill "$decoy_pid"
wait "$decoy_pid" >/dev/null 2>&1 || true
decoy_pid=""
trap - EXIT

preserved_failure() (
  preserve_cleanup_status() {
    local status="$?"
    trap - EXIT
    if ! linux_stop_exact_test_app "$app"; then
      status=1
    fi
    exit "$status"
  }
  trap preserve_cleanup_status EXIT
  false
)
if preserved_failure; then
  echo "Linux exact-app cleanup masked the original failure." >&2
  exit 1
fi
