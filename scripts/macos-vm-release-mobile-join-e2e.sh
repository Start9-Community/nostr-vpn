#!/usr/bin/env bash
# Signed macOS Release <-> physical Android manual join in both role directions.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/release_common.sh"
# shellcheck disable=SC1091
source "$ROOT/scripts/mobile_env.sh"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib-mobile-release-join-artifacts.sh"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib-mobile-release-join-ui.sh"

load_release_env "$ROOT"
load_env_file_defaults "${NVPN_ZAPSTORE_ENV_FILE:-$ROOT/.env.zapstore.local}"
load_mobile_env "$ROOT"

MACOS_SIGNING_IDENTITY="${MACOS_SIGNING_IDENTITY:-}"
EXPECTED_MACOS_TEAM="${NVPN_EXPECTED_MACOS_SIGNING_TEAM_ID:-${NVPN_IOS_TEAM_ID:-}}"
EXPECTED_MACOS_CERT="${NVPN_EXPECTED_MACOS_SIGNER_CERT_SHA256:-}"
[[ -n "$MACOS_SIGNING_IDENTITY" ]] || {
  echo "Set MACOS_SIGNING_IDENTITY to the company Developer ID identity" >&2
  exit 2
}
[[ -n "$EXPECTED_MACOS_TEAM" ]] || {
  echo "Set NVPN_IOS_TEAM_ID or NVPN_EXPECTED_MACOS_SIGNING_TEAM_ID" >&2
  exit 2
}

MAC_HOST="${NVPN_MACOS_SSH_HOST:-${1:-}}"
[[ -n "$MAC_HOST" ]] || {
  echo "Set NVPN_MACOS_SSH_HOST for Release desktop/mobile join coverage" >&2
  exit 2
}
GUEST_SRC_ROOT="${NVPN_MACOS_GUEST_SRC_ROOT:-src}"
GUEST_REPO="$GUEST_SRC_ROOT/nostr-vpn"
REMOTE_SCRIPT="./scripts/macos-release-mobile-join-remote.sh"
RESULT_DIR="${NVPN_RELEASE_JOIN_RESULT_DIR:-$ROOT/artifacts/mobile-release-join}"
PRIVATE_DIR="$RESULT_DIR/.desktop-private-$$"
RELEASE_JOIN_UI_WAIT_SECS="${NVPN_RELEASE_JOIN_UI_WAIT_SECS:-15}"
RELEASE_JOIN_DELIVERY_WAIT_SECS="${NVPN_RELEASE_JOIN_DELIVERY_WAIT_SECS:-15}"
RELEASE_JOIN_CAMERA_WAIT_SECS="${NVPN_RELEASE_JOIN_CAMERA_WAIT_SECS:-30}"
mkdir -p "$PRIVATE_DIR" "$RESULT_DIR/macos"
chmod 700 "$PRIVATE_DIR"

ANDROID_REQUESTED="${NVPN_ANDROID_SERIAL:-${ANDROID_SERIAL:-}}"
[[ -n "$ANDROID_REQUESTED" ]] || {
  echo "Set NVPN_ANDROID_SERIAL to the exact physical Android phone" >&2
  exit 2
}
ANDROID_SERIAL_SELECTED="$(
  select_physical_android_serial \
    "${ADB_BIN:-adb}" \
    "$ANDROID_REQUESTED"
)"
ADB=("${ADB_BIN:-adb}" -s "$ANDROID_SERIAL_SELECTED")
export RESULT_DIR PRIVATE_DIR RELEASE_JOIN_UI_WAIT_SECS
export RELEASE_JOIN_DELIVERY_WAIT_SECS RELEASE_JOIN_CAMERA_WAIT_SECS

remote_pid=""
cleanup() {
  local status=$?
  trap - EXIT
  if [[ -n "$remote_pid" ]] && kill -0 "$remote_pid" 2>/dev/null; then
    kill "$remote_pid" >/dev/null 2>&1 || true
    wait "$remote_pid" >/dev/null 2>&1 || true
  fi
  remote cleanup >/dev/null 2>&1 || true
  rm -rf "$PRIVATE_DIR"
  exit "$status"
}
trap cleanup EXIT

remote() {
  local command="$1"
  shift
  local remote_command argument
  printf -v remote_command \
    'cd %q && env NVPN_FIPS_REPO_PATH=%q NVPN_EXPECTED_FIPS_GIT_SHA=%q NVPN_EXPECTED_MACOS_SIGNING_IDENTITY=%q NVPN_EXPECTED_MACOS_SIGNING_TEAM_ID=%q NVPN_EXPECTED_MACOS_SIGNER_CERT_SHA256=%q %q %q' \
    "$GUEST_REPO" \
    "../fips" \
    "${NVPN_EXPECTED_FIPS_GIT_SHA:-}" \
    "$MACOS_SIGNING_IDENTITY" \
    "$EXPECTED_MACOS_TEAM" \
    "$EXPECTED_MACOS_CERT" \
    "$REMOTE_SCRIPT" \
    "$command"
  for argument in "$@"; do
    printf -v remote_command '%s %q' "$remote_command" "$argument"
  done
  ssh -o BatchMode=yes "$MAC_HOST" "$remote_command"
}

wait_log_marker() {
  local log="$1" marker="$2" timeout="${3:-15}" deadline=$((SECONDS + timeout))
  while ((SECONDS < deadline)); do
    grep -Fq "NVPN_RELEASE_JOIN_MARKER $marker" "$log" 2>/dev/null && return 0
    if [[ -n "$remote_pid" ]] && ! kill -0 "$remote_pid" 2>/dev/null; then
      wait "$remote_pid" || true
      remote_pid=""
      tail -n 100 "$log" >&2 || true
      return 1
    fi
    sleep 0.25
  done
  return 1
}

marker_value() {
  sed -n "s/.*NVPN_RELEASE_JOIN_MARKER $2=//p" "$1" | tail -n 1
}

finish_remote() {
  local log="$1" status=0
  wait "$remote_pid" || status=$?
  remote_pid=""
  if [[ "$status" -ne 0 ]]; then
    tail -n 120 "$log" >&2 || true
  fi
  return "$status"
}

NVPN_MACOS_SYNC_PATH_DEPS=1 \
  NVPN_FIPS_REPO_PATH="$NVPN_FIPS_REPO_PATH" \
  "$ROOT/scripts/macos-vm-git-sync.sh" "$MAC_HOST"
remote prepare | tee "$RESULT_DIR/macos/prepare.log"
scp -q \
  "$MAC_HOST:$GUEST_REPO/artifacts/macos-release-mobile-join/artifact.json" \
  "$RESULT_DIR/macos/artifact.json"

# macOS admin -> physical Android joiner.
release_join_reset_android_state
desktop_admin_log="$RESULT_DIR/macos/desktop-admin.log"
remote create-admin "ReleaseDesktopAdmin" >"$desktop_admin_log" 2>&1
DESKTOP_ADMIN_ID="$(marker_value "$desktop_admin_log" NVPN_RELEASE_JOIN_ADMIN_ID)"
DESKTOP_NETWORK_ID="$(marker_value "$desktop_admin_log" NVPN_RELEASE_JOIN_NETWORK_ID)"
release_join_valid_npub "$DESKTOP_ADMIN_ID"
[[ -n "$DESKTOP_NETWORK_ID" ]]
release_join_android_manual_submit "$DESKTOP_ADMIN_ID" "$DESKTOP_NETWORK_ID"
desktop_add_log="$RESULT_DIR/macos/desktop-add-android.log"
remote admin-add "$RELEASE_JOIN_ANDROID_JOINER_ID" ReleaseGatePhone \
  >"$desktop_add_log" 2>&1 &
remote_pid=$!
wait_log_marker "$desktop_add_log" \
  "NVPN_RELEASE_JOIN_ADMIN_ACCEPTED=$RELEASE_JOIN_ANDROID_JOINER_ID"
wait_log_marker "$desktop_add_log" NVPN_MACOS_RELEASE_APP_HOLDING=1
release_join_android_wait_join_complete "$DESKTOP_ADMIN_ID" \
  || { tail -n 100 "$desktop_add_log" >&2; exit 1; }
kill "$remote_pid" >/dev/null 2>&1 || true
wait "$remote_pid" >/dev/null 2>&1 || true
remote_pid=""
remote verify "$RELEASE_JOIN_ANDROID_JOINER_ID" \
  >"$RESULT_DIR/macos/desktop-admin-verify.log"

# Physical Android admin -> macOS joiner. The remote app remains alive while
# waiting for the exact Android admin row, so receipt delivery is real.
release_join_reset_android_state
release_join_android_create_admin
desktop_join_log="$RESULT_DIR/macos/android-admin-desktop-join.log"
remote manual-join \
  "$RELEASE_JOIN_ANDROID_ADMIN_ID" "$RELEASE_JOIN_ANDROID_NETWORK_ID" \
  >"$desktop_join_log" 2>&1 &
remote_pid=$!
wait_log_marker "$desktop_join_log" NVPN_RELEASE_JOIN_JOINER_ID= 10
DESKTOP_JOINER_ID="$(marker_value "$desktop_join_log" NVPN_RELEASE_JOIN_JOINER_ID)"
release_join_valid_npub "$DESKTOP_JOINER_ID"
wait_log_marker "$desktop_join_log" NVPN_RELEASE_JOIN_MANUAL_SUBMITTED=1 10
release_join_android_manual_admin_add "$DESKTOP_JOINER_ID"
finish_remote "$desktop_join_log"
remote verify "$RELEASE_JOIN_ANDROID_ADMIN_ID" \
  >"$RESULT_DIR/macos/desktop-joiner-verify.log"

python3 - "$RESULT_DIR/macos/summary.json" <<'PY'
import json
import sys

with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(
        {
            "artifact": "signed macOS Release app",
            "publicUiOnly": True,
            "appLaunchArgumentsOrEnvironment": False,
            "privateAppStateRead": False,
            "desktopAdminAndroidJoiner": True,
            "androidAdminDesktopJoiner": True,
            "exactRosterOnBothSides": True,
        },
        handle,
        indent=2,
        sort_keys=True,
    )
    handle.write("\n")
PY

echo "SIGNED_RELEASE_PUBLIC_UI_DESKTOP_MOBILE_JOIN_E2E_OK"
