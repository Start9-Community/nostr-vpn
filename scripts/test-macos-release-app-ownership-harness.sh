#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="$ROOT/scripts/macos-vm-release-mobile-join-e2e.sh"
REMOTE="$ROOT/scripts/macos-release-mobile-join-remote.sh"
HELPER="$ROOT/scripts/lib-macos-release-app-ownership.sh"
DRIVER="$ROOT/scripts/desktop-manual-join-ax.swift"
trap 'echo "macOS app ownership harness failed at line $LINENO" >&2' ERR

bash -n "$HOST" "$REMOTE" "$HELPER"
python3 - "$HOST" "$REMOTE" "$HELPER" "$DRIVER" <<'PY'
import pathlib
import sys

host = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
remote = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
helper = pathlib.Path(sys.argv[3]).read_text(encoding="utf-8")
driver = pathlib.Path(sys.argv[4]).read_text(encoding="utf-8")

for required in (
    "remote_app_ownership_armed=0",
    'if [[ "$remote_app_ownership_armed" -eq 1 ]]',
    "remote_app_ownership_armed=1",
    "macos_release_stop_owned_child",
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
    "MACOS_RELEASE_APP_SUPPORT_DIR",
    "macos_release_app_support_acquire",
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
if launch.index("macos_release_app_support_acquire") > launch.index('"$APP_EXE"'):
    raise SystemExit("VM importer launches before isolating persisted app state")
if launch.index("macos_release_app_acquire") > launch.index(
    "macos_release_app_support_acquire"
):
    raise SystemExit("VM importer isolates state before stopping the prior app")
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
    "app-support-acquired",
    "app-support-prior",
    "macos_release_app_support_restore",
):
    if required not in helper:
        raise SystemExit(f"ownership helper lacks {required}")
stop = helper.split("macos_release_app_stop_pid() {", 1)[1].split(
    "\n}\n\nmacos_release_app_acquire()", 1
)[0]
for required in (
    "kill -TERM",
    "kill -KILL",
    "gate-owned app process survived TERM and KILL",
):
    if required not in stop:
        raise SystemExit(f"bounded stop helper lacks {required}")
if stop.count("macos_release_app_poll_pid_gone") < 2 or "wait " in stop:
    raise SystemExit("bounded stop helper does not poll twice without blocking wait")
if "macos_release_stop_owned_child" not in helper:
    raise SystemExit("host remote child has no shared bounded stop helper")
restore = helper.split("macos_release_app_restore() {", 1)[1]
if restore.index("macos_release_app_support_restore") > restore.index(
    "macos_release_app_launch_installed"
):
    raise SystemExit("prior app is relaunched before its state is restored")

host_prefix = host.split("ROOT=", 1)[0]
remote_prefix = remote.split("ROOT=", 1)[0]
if "exec </dev/null" not in host_prefix:
    raise SystemExit("host join orchestrator does not own stdin before children start")
if "exec </dev/null" not in remote_prefix:
    raise SystemExit("remote join orchestrator does not own stdin before children start")
remote_function = host.split("remote() {", 1)[1].split("\n}", 1)[0]
if "</dev/null" not in remote_function:
    raise SystemExit("host SSH child can consume orchestration stdin")

for required in (
    "findUniqueEnabled",
    "pressStableUniqueEnabled",
    "stablePublicValue",
):
    if required not in driver:
        raise SystemExit(f"macOS AX driver lacks stable target guard: {required}")
create = driver.split('case "release-create-admin":', 1)[1].split(
    'case "release-manual-join":', 1
)[0]
if "try pressStableUniqueEnabled(" not in create:
    raise SystemExit("AX driver does not press a stable unique Link device target")
if create.count("stablePublicValue") < 2:
    raise SystemExit("AX driver does not stabilize both new-network public values")
if "mouseEventSource" in driver or "mouseMoved" in driver or "leftMouse" in driver:
    raise SystemExit("AX driver added a coordinate/mouse fallback")
PY

tmp="$(mktemp -d "${TMPDIR:-/tmp}/nvpn-macos-app-owner.XXXXXX")"
fixture_name="NvOwn$$"
cleanup() {
  while IFS= read -r pid; do
    [[ -n "$pid" ]] && kill "$pid" >/dev/null 2>&1 || true
  done < <(pgrep -x "$fixture_name" 2>/dev/null || true)
  rm -rf "$tmp"
}
trap cleanup EXIT

# A retained app-support directory must be moved opaquely out of the way for
# the gate, then restored byte-for-byte while all gate-created state disappears.
(
  # shellcheck disable=SC1090
  source "$HELPER"
  MACOS_RELEASE_APP_STATE_DIR="$tmp/support-owner"
  MACOS_RELEASE_APP_SUPPORT_DIR="$tmp/app-support"
  mkdir -p "$MACOS_RELEASE_APP_SUPPORT_DIR"
  printf 'retained\n' >"$MACOS_RELEASE_APP_SUPPORT_DIR/original"
  macos_release_app_support_acquire
  [[ ! -e "$MACOS_RELEASE_APP_SUPPORT_DIR" ]]
  [[ -f "$MACOS_RELEASE_APP_STATE_DIR/app-support-prior/original" ]]
  mkdir -p "$MACOS_RELEASE_APP_SUPPORT_DIR"
  printf 'gate\n' >"$MACOS_RELEASE_APP_SUPPORT_DIR/gate-created"
  macos_release_app_support_restore
  [[ "$(<"$MACOS_RELEASE_APP_SUPPORT_DIR/original")" == retained ]]
  [[ ! -e "$MACOS_RELEASE_APP_SUPPORT_DIR/gate-created" ]]
  [[ ! -e "$MACOS_RELEASE_APP_STATE_DIR/app-support-acquired" ]]
)

# A machine with no prior state must return to no state after cleanup.
(
  # shellcheck disable=SC1090
  source "$HELPER"
  MACOS_RELEASE_APP_STATE_DIR="$tmp/absent-support-owner"
  MACOS_RELEASE_APP_SUPPORT_DIR="$tmp/absent-app-support"
  macos_release_app_support_acquire
  mkdir -p "$MACOS_RELEASE_APP_SUPPORT_DIR"
  : >"$MACOS_RELEASE_APP_SUPPORT_DIR/gate-created"
  macos_release_app_support_restore
  [[ ! -e "$MACOS_RELEASE_APP_SUPPORT_DIR" ]]
  [[ ! -e "$MACOS_RELEASE_APP_STATE_DIR/app-support-acquired" ]]
)

# Restoration fails closed and retains its recovery metadata when the opaque
# prior-state backup is unexpectedly missing.
(
  # shellcheck disable=SC1090
  source "$HELPER"
  MACOS_RELEASE_APP_STATE_DIR="$tmp/broken-support-owner"
  MACOS_RELEASE_APP_SUPPORT_DIR="$tmp/broken-app-support"
  mkdir -p "$MACOS_RELEASE_APP_SUPPORT_DIR"
  : >"$MACOS_RELEASE_APP_SUPPORT_DIR/original"
  macos_release_app_support_acquire
  rm -rf "$MACOS_RELEASE_APP_STATE_DIR/app-support-prior"
  mkdir -p "$MACOS_RELEASE_APP_SUPPORT_DIR"
  : >"$MACOS_RELEASE_APP_SUPPORT_DIR/gate-created"
  if macos_release_app_support_restore >/dev/null 2>&1; then
    echo "app-support cleanup accepted a missing retained-state backup" >&2
    exit 1
  fi
  [[ -f "$MACOS_RELEASE_APP_STATE_DIR/app-support-acquired" ]]
)

python3 - "$HOST" "$tmp/host-cleanup.sh" <<'PY'
import pathlib
import sys

host = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
cleanup = host.split("cleanup() {", 1)[1].split(
    "\n}\ntrap cleanup EXIT", 1
)[0]
pathlib.Path(sys.argv[2]).write_text(
    "cleanup() {" + cleanup + "\n}\n",
    encoding="utf-8",
)
PY
bash -s -- "$tmp/host-cleanup.sh" "$tmp" <<'TEST'
set -euo pipefail
cleanup_source="$1"
tmp="$2"
# shellcheck disable=SC1090
source "$cleanup_source"

run_cleanup_case() {
  local primary_status="$1"
  local remote_status="$2"
  remote_pid=""
  remote_app_ownership_armed=1
  PRIVATE_DIR="$tmp/private-$primary_status-$remote_status"
  mkdir -p "$PRIVATE_DIR"
  remote() {
    echo "synthetic remote cleanup failure" >&2
    return "$remote_status"
  }
  set +e
  (exit "$primary_status")
  cleanup
}

assert_cleanup_case() {
  local primary_status="$1" remote_status="$2" expected="$3"
  local output observed
  set +e
  output="$(run_cleanup_case "$primary_status" "$remote_status" 2>&1)"
  observed=$?
  set -e
  [[ "$observed" -eq "$expected" ]] || {
    echo "cleanup status mismatch: primary=$primary_status cleanup=$remote_status observed=$observed expected=$expected" >&2
    return 1
  }
  grep -Fq "macOS VM app restoration failed during release gate cleanup" \
    <<<"$output" || {
      echo "cleanup failure was not reported" >&2
      return 1
    }
}

assert_cleanup_case 0 23 23
assert_cleanup_case 17 23 17
TEST

mkdir -p \
  "$tmp/installed/$fixture_name.app/Contents/MacOS" \
  "$tmp/unknown" \
  "$tmp/stubborn"
installed="$tmp/installed/$fixture_name.app/Contents/MacOS/$fixture_name"
unknown="$tmp/unknown/$fixture_name"
stubborn="$tmp/stubborn/$fixture_name"
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
printf '%s\n' '#include <fcntl.h>
#include <signal.h>
#include <unistd.h>
int main(int argc, char **argv) {
  if (argc != 2) return 2;
  signal(SIGTERM, SIG_IGN);
  int ready = open(argv[1], O_WRONLY | O_CREAT | O_TRUNC, 0600);
  if (ready < 0) return 3;
  close(ready);
  for (;;) pause();
}' | xcrun clang -x c - -o "$stubborn"

bash -s -- \
  "$HELPER" "$installed" "$unknown" "$stubborn" "$fixture_name" "$tmp" <<'TEST'
set -euo pipefail
trap 'echo "ownership fixture failed at line $LINENO" >&2' ERR
helper="$1"
installed="$2"
unknown="$3"
stubborn="$4"
fixture_name="$5"
tmp="$6"

# shellcheck disable=SC1090
source "$helper"

set_artifact() {
  MACOS_RELEASE_APP_STATE_DIR="$1/app-ownership"
  MACOS_RELEASE_APP_GATE_EXE="$1/imported/$fixture_name.app/Contents/MacOS/$fixture_name"
  MACOS_RELEASE_APP_INSTALLED_EXE="$installed"
  MACOS_RELEASE_APP_PROCESS_NAME="$fixture_name"
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
  values="$(pgrep -x "$fixture_name" 2>/dev/null || true)"
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

# Run both bounded stop paths in a watchdog-protected shell where each
# TERM-ignoring fixture is a real child that must be reaped.
child_pid_file="$tmp/stubborn-child.pid"
timings="$tmp/stubborn-timings"
worker_log="$tmp/stubborn-worker.log"
bash -s -- "$HELPER" "$stubborn" "$child_pid_file" "$timings" \
  >"$worker_log" 2>&1 <<'TEST' &
set -euo pipefail
trap 'echo "bounded stop worker failed at line $LINENO" >&2' ERR
source "$1"
stubborn="$2"
child_pid_file="$3"
timings="$4"
child=""
cleanup_child() {
  [[ -n "$child" ]] || return 0
  kill -KILL "$child" >/dev/null 2>&1 || true
  wait "$child" >/dev/null 2>&1 || true
}
trap cleanup_child EXIT
for mode in exact-app owned-child; do
  ready="$timings.$mode.ready"
  "$stubborn" "$ready" &
  child=$!
  printf '%s\n' "$child" >"$child_pid_file"
  for _ in {1..50}; do
    [[ -e "$ready" ]] && break
    sleep 0.02
  done
  [[ -e "$ready" ]]
  SECONDS=0
  if [[ "$mode" == exact-app ]]; then
    macos_release_app_stop_pid "$child" "$stubborn $ready"
  else
    macos_release_stop_owned_child "$child"
  fi
  elapsed="$SECONDS"
  ! kill -0 "$child" >/dev/null 2>&1
  [[ -z "$(ps -ww -p "$child" -o stat= 2>/dev/null)" ]]
  printf '%s\t%s\n' "$mode" "$elapsed" >>"$timings"
  child=""
done
trap - EXIT
TEST
worker_pid=$!
timed_out=1
for _ in {1..180}; do
  if ! kill -0 "$worker_pid" >/dev/null 2>&1; then
    timed_out=0
    break
  fi
  sleep 0.1
done
if [[ "$timed_out" -eq 1 ]]; then
  child="$(cat "$child_pid_file" 2>/dev/null || true)"
  [[ -z "$child" ]] || kill -KILL "$child" >/dev/null 2>&1 || true
  kill -KILL "$worker_pid" >/dev/null 2>&1 || true
  wait "$worker_pid" >/dev/null 2>&1 || true
  tail -n 40 "$worker_log" >&2 || true
  echo "bounded stop helper hung on a TERM-ignoring child" >&2
  exit 1
fi
if ! wait "$worker_pid"; then
  tail -n 40 "$worker_log" >&2 || true
  exit 1
fi
if ! awk -F'\t' '
  ($1 == "exact-app" || $1 == "owned-child") && $2 >= 2 && $2 < 8 {
    passed[$1] = 1
  }
  END { exit !(passed["exact-app"] && passed["owned-child"]) }
' "$timings"
then
  echo "bounded stop timings were incomplete or out of range:" >&2
  cat "$timings" >&2 || true
  tail -n 40 "$worker_log" >&2 || true
  exit 1
fi

echo "MACOS_RELEASE_APP_OWNERSHIP_HARNESS_OK"
