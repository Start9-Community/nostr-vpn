#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="$ROOT/scripts/macos-vm-release-mobile-join-e2e.sh"
REMOTE="$ROOT/scripts/macos-release-mobile-join-remote.sh"
HELPER="$ROOT/scripts/lib-macos-release-app-ownership.sh"

bash -n "$HOST" "$REMOTE" "$HELPER"
python3 - "$HOST" "$REMOTE" "$HELPER" <<'PY'
import pathlib
import sys

host = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
remote = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
helper = pathlib.Path(sys.argv[3]).read_text(encoding="utf-8")

for required in (
    "remote_app_ownership_armed=0",
    'if [[ "$remote_app_ownership_armed" -eq 1 ]]',
    "remote_app_ownership_armed=1",
):
    if required not in host:
        raise SystemExit(f"host importer lacks cleanup ownership guard: {required}")
if host.index("remote_app_ownership_armed=1") > host.index(
    'remote create-admin "ReleaseDesktopAdmin"'
):
    raise SystemExit("host importer arms cleanup after its first app launch")
cleanup = host.split("cleanup() {", 1)[1].split("trap cleanup EXIT", 1)[0]
if "remote cleanup" not in cleanup or "remote_app_ownership_armed" not in cleanup:
    raise SystemExit("host cleanup is not conditional on remote app ownership")

for required in (
    "lib-macos-release-app-ownership.sh",
    "macos_release_app_acquire",
    "macos_release_app_restore",
    "MACOS_RELEASE_APP_STATE_DIR",
    "MACOS_RELEASE_APP_INSTALLED_EXE",
    "MACOS_RELEASE_APP_GATE_EXE",
):
    if required not in remote:
        raise SystemExit(f"VM importer lacks app ownership contract: {required}")
if 'pkill -x "Nostr VPN"' in remote or "pkill" in helper:
    raise SystemExit("VM importer still has a broad Nostr VPN process kill")
stage = remote.split("stage() {", 1)[1].split("prepare() {", 1)[0]
if stage.index("macos_release_app_restore") > stage.index('rm -rf "$ARTIFACT_DIR"'):
    raise SystemExit("VM staging deletes ownership before restoring prior state")
launch = remote.split("launch_app() {", 1)[1].split("run_driver() {", 1)[0]
if launch.index("macos_release_app_acquire") > launch.index('"$APP_EXE"'):
    raise SystemExit("VM importer launches before acquiring app ownership")
cleanup_case = remote.split("  cleanup)", 1)[1].split("    ;;", 1)[0]
if "macos_release_app_restore" not in cleanup_case:
    raise SystemExit("VM cleanup does not restore the displaced installed app")
for required in (
    "macos_release_app_acquire",
    "macos_release_app_restore",
    "prior-state",
    "imported.pid",
    "absent",
    "hidden",
    "visible",
):
    if required not in helper:
        raise SystemExit(f"ownership helper lacks {required}")
PY

tmp="$(mktemp -d "${TMPDIR:-/tmp}/nvpn-macos-app-owner.XXXXXX")"
fixture_name="NvpnOwnTest"
cleanup() {
  while IFS= read -r pid; do
    [[ -n "$pid" ]] && kill "$pid" >/dev/null 2>&1 || true
  done < <(pgrep -x "$fixture_name" 2>/dev/null || true)
  rm -rf "$tmp"
}
trap cleanup EXIT

mkdir -p \
  "$tmp/installed/NvpnOwnTest.app/Contents/MacOS" \
  "$tmp/unknown"
installed="$tmp/installed/NvpnOwnTest.app/Contents/MacOS/$fixture_name"
unknown="$tmp/unknown/$fixture_name"
fixture_source='#include <signal.h>
#include <unistd.h>
int main(void) {
  signal(SIGTERM, SIG_DFL);
  for (;;) pause();
}'
printf '%s\n' "$fixture_source" \
  | xcrun clang -x c - -o "$installed"
printf '%s\n' "$fixture_source" \
  | xcrun clang -x c - -o "$unknown"

bash -s -- "$HELPER" "$installed" "$unknown" "$tmp" <<'TEST'
set -euo pipefail
helper="$1"
installed="$2"
unknown="$3"
tmp="$4"

# shellcheck disable=SC1090
source "$helper"

set_artifact() {
  MACOS_RELEASE_APP_STATE_DIR="$1/app-ownership"
  MACOS_RELEASE_APP_GATE_EXE="$1/imported/NvpnOwnTest.app/Contents/MacOS/NvpnOwnTest"
  MACOS_RELEASE_APP_INSTALLED_EXE="$installed"
  MACOS_RELEASE_APP_PROCESS_NAME=NvpnOwnTest
  APP_PID=""
  mkdir -p "$(dirname "$MACOS_RELEASE_APP_GATE_EXE")"
  printf '%s\n' '#include <signal.h>
#include <unistd.h>
int main(void) {
  signal(SIGTERM, SIG_DFL);
  for (;;) pause();
}' | xcrun clang -x c - -o "$MACOS_RELEASE_APP_GATE_EXE"
}

single_pid() {
  local values
  values="$(pgrep -x NvpnOwnTest 2>/dev/null || true)"
  [[ "$(wc -w <<<"$values" | tr -d " ")" == 1 ]]
  printf '%s\n' "$values"
}

stop_fixture() {
  local pid="$1"
  kill "$pid" >/dev/null 2>&1 || true
  wait "$pid" >/dev/null 2>&1 || true
}

run_restore_case() {
  local mode="$1" artifact="$2" prior imported restored args
  set_artifact "$artifact"
  if [[ "$mode" == hidden ]]; then
    "$installed" --hidden &
  else
    "$installed" &
  fi
  prior=$!
  disown "$prior"
  sleep 0.1
  [[ "$(single_pid)" == "$prior" ]]

  # This is the original regression: cleanup before ownership must not kill
  # the preexisting installed app.
  macos_release_app_restore
  kill -0 "$prior"
  [[ ! -e "$MACOS_RELEASE_APP_STATE_DIR" ]]

  macos_release_app_acquire
  ! kill -0 "$prior" >/dev/null 2>&1
  [[ "$(<"$MACOS_RELEASE_APP_STATE_DIR/prior-state")" == "$mode" ]]
  "$MACOS_RELEASE_APP_GATE_EXE" &
  imported=$!
  disown "$imported"
  APP_PID="$imported"
  printf '%s\n' "$imported" >"$MACOS_RELEASE_APP_STATE_DIR/imported.pid"

  macos_release_app_restore
  ! kill -0 "$imported" >/dev/null 2>&1
  [[ ! -e "$MACOS_RELEASE_APP_STATE_DIR" ]]
  restored="$(single_pid)"
  [[ "$restored" != "$prior" ]]
  args="$(macos_release_app_process_args "$restored")"
  if [[ "$mode" == hidden ]]; then
    [[ "$args" == "$installed --hidden" ]]
  else
    [[ "$args" == "$installed" ]]
  fi
  APP_PID=""
  stop_fixture "$restored"
}

run_restore_case hidden "$tmp/hidden"
run_restore_case visible "$tmp/visible"

# A same-name process from an unknown executable must be left alone.
set_artifact "$tmp/unknown-case"
"$unknown" &
unknown_pid=$!
disown "$unknown_pid"
sleep 0.1
if macos_release_app_acquire >/dev/null 2>&1; then
  echo "ownership accepted an unknown same-name process" >&2
  exit 1
fi
kill -0 "$unknown_pid"
[[ ! -e "$MACOS_RELEASE_APP_STATE_DIR/acquired" ]]
stop_fixture "$unknown_pid"
APP_PID=""
TEST

echo "MACOS_RELEASE_APP_OWNERSHIP_HARNESS_OK"
