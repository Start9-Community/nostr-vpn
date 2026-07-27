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

ARTIFACT_ACTION="${NVPN_MACOS_RELEASE_ARTIFACT_ACTION:-full}"
case "$ARTIFACT_ACTION" in
  full|prepare-only|verify-only) ;;
  *)
    echo "Unsupported NVPN_MACOS_RELEASE_ARTIFACT_ACTION=$ARTIFACT_ACTION" >&2
    exit 2
    ;;
esac

MACOS_SIGNING_IDENTITY="$(
  printf '%s' "${MACOS_SIGNING_IDENTITY:-}" \
    | tr -d ':[:space:]' \
    | tr '[:lower:]' '[:upper:]'
)"
EXPECTED_MACOS_TEAM="${NVPN_EXPECTED_MACOS_SIGNING_TEAM_ID:-${NVPN_IOS_TEAM_ID:-}}"
EXPECTED_MACOS_CERT="$(
  printf '%s' "${NVPN_EXPECTED_MACOS_SIGNER_CERT_SHA256:-}" \
    | tr -d ':[:space:]' \
    | tr '[:upper:]' '[:lower:]'
)"
[[ "$MACOS_SIGNING_IDENTITY" =~ ^[0-9A-F]{40}$ ]] || {
  echo "Set MACOS_SIGNING_IDENTITY to the exact Developer ID certificate SHA-1" >&2
  exit 2
}
[[ "$EXPECTED_MACOS_TEAM" =~ ^[A-Z0-9]{10}$ ]] || {
  echo "Set NVPN_IOS_TEAM_ID or NVPN_EXPECTED_MACOS_SIGNING_TEAM_ID" >&2
  exit 2
}
if [[ -z "$EXPECTED_MACOS_CERT" ]]; then
  EXPECTED_MACOS_CERT="$(
    python3 "$ROOT/scripts/macos_release_join_artifact.py" \
      resolve-certificate --identity-sha1 "$MACOS_SIGNING_IDENTITY"
  )"
fi
[[ "$EXPECTED_MACOS_CERT" =~ ^[0-9a-f]{64}$ ]] || {
  echo "Set NVPN_EXPECTED_MACOS_SIGNER_CERT_SHA256 to the exact Developer ID certificate" >&2
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
HOST_BUILD_ROOT="$PRIVATE_DIR/source"
HOST_FIPS_ROOT="$PRIVATE_DIR/fips"
HOST_APP="$HOST_BUILD_ROOT/dist/macos/Nostr VPN.app"
HOST_PACKAGE="$PRIVATE_DIR/package"
HOST_SUPPORT="$PRIVATE_DIR/support"
HOST_FIXTURE="$HOST_SUPPORT/fixtures/desktop_manual_join_e2e_fixture"
HOST_MANUAL_DRIVER="$HOST_SUPPORT/drivers/desktop-manual-join-ax"
HOST_SERVICE_DRIVER="$HOST_SUPPORT/drivers/macos-service-toggle-ax"
HOST_ARCHIVE="$PRIVATE_DIR/macos-release-gate.zip"
HOST_RECEIPT="$PRIVATE_DIR/artifact.json"
RELEASE_JOIN_UI_WAIT_SECS="${NVPN_RELEASE_JOIN_UI_WAIT_SECS:-15}"
RELEASE_JOIN_DELIVERY_WAIT_SECS="${NVPN_RELEASE_JOIN_DELIVERY_WAIT_SECS:-15}"
RELEASE_JOIN_CAMERA_WAIT_SECS="${NVPN_RELEASE_JOIN_CAMERA_WAIT_SECS:-30}"
mkdir -p "$PRIVATE_DIR" "$RESULT_DIR/macos"
chmod 700 "$PRIVATE_DIR"

export RESULT_DIR PRIVATE_DIR RELEASE_JOIN_UI_WAIT_SECS
export RELEASE_JOIN_DELIVERY_WAIT_SECS RELEASE_JOIN_CAMERA_WAIT_SECS
release_join_require_clean_fips
APP_GIT_SHA="$(git -C "$ROOT" rev-parse HEAD)"
APP_GIT_TREE="$(git -C "$ROOT" rev-parse HEAD^{tree})"
APP_SOURCE_DATE_EPOCH="$(git -C "$ROOT" log -1 --format=%ct HEAD)"
release_join_assert_app_unchanged "$APP_GIT_SHA" "$APP_GIT_TREE"

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
    'cd %q && env NVPN_FIPS_REPO_PATH=%q NVPN_EXPECTED_APP_GIT_SHA=%q NVPN_EXPECTED_APP_GIT_TREE=%q NVPN_EXPECTED_FIPS_GIT_SHA=%q NVPN_EXPECTED_FIPS_GIT_TREE=%q NVPN_EXPECTED_FIPS_VERSION=%q NVPN_EXPECTED_MACOS_SIGNING_IDENTITY_SHA1=%q NVPN_EXPECTED_MACOS_SIGNING_TEAM_ID=%q NVPN_EXPECTED_MACOS_SIGNER_CERT_SHA256=%q %q %q' \
    "$GUEST_REPO" \
    "../fips" \
    "$APP_GIT_SHA" \
    "$APP_GIT_TREE" \
    "$RELEASE_JOIN_FIPS_SHA" \
    "$RELEASE_JOIN_FIPS_TREE" \
    "$RELEASE_JOIN_FIPS_VERSION" \
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

prepare_host_artifact() {
  local build_log="$RESULT_DIR/macos/host-build.log"
  local support
  rm -rf "$HOST_PACKAGE" "$HOST_SUPPORT"
  rm -f "$HOST_ARCHIVE" "$HOST_RECEIPT"
  if ! (
    cd "$HOST_BUILD_ROOT"
    MACOS_SIGNING_IDENTITY="$MACOS_SIGNING_IDENTITY" \
      NVPN_BUILD_GIT_SHA="$APP_GIT_SHA" \
      SOURCE_DATE_EPOCH="$APP_SOURCE_DATE_EPOCH" \
      NVPN_FIPS_REPO_PATH="$HOST_FIPS_ROOT" \
      NVPN_MACOS_RUST_PROFILE=release \
      NVPN_MACOS_XCODE_CONFIGURATION=Release \
      NVPN_MACOS_RUST_TARGETS=aarch64-apple-darwin \
      NVPN_MACOS_REQUIRE_SIGNING=1 \
      "$HOST_BUILD_ROOT/scripts/macos-build" macos-app
    NVPN_FIPS_REPO_PATH="$HOST_FIPS_ROOT" \
      SOURCE_DATE_EPOCH="$APP_SOURCE_DATE_EPOCH" \
      NVPN_MACOS_HOST_TARGET=aarch64-apple-darwin \
      NVPN_MACOS_GATE_SUPPORT_DIR="$HOST_SUPPORT" \
      "$HOST_BUILD_ROOT/scripts/macos-build" macos-gate-support
  ) >"$build_log" 2>&1
  then
    tail -n 120 "$build_log" >&2 || true
    return 1
  fi
  [[ "$(git -C "$HOST_FIPS_ROOT" rev-parse HEAD)" == "$RELEASE_JOIN_FIPS_SHA" \
    && "$(git -C "$HOST_FIPS_ROOT" rev-parse HEAD^{tree})" == "$RELEASE_JOIN_FIPS_TREE" \
    && -z "$(git -C "$HOST_FIPS_ROOT" status --porcelain --untracked-files=all)" ]] || {
    echo "Isolated FIPS source changed while building Release join artifacts" >&2
    return 1
  }
  release_join_assert_app_unchanged "$APP_GIT_SHA" "$APP_GIT_TREE"
  codesign --verify --deep --strict "$HOST_APP"
  for support in \
    "$HOST_FIXTURE" \
    "$HOST_MANUAL_DRIVER" \
    "$HOST_SERVICE_DRIVER"
  do
    [[ -x "$support" ]] || {
      echo "Host-built macOS Release gate support is missing: $support" >&2
      return 1
    }
    codesign --force --timestamp --options runtime \
      --sign "$MACOS_SIGNING_IDENTITY" "$support"
    codesign --verify --strict "$support"
  done

  mkdir -p "$HOST_PACKAGE/fixtures" "$HOST_PACKAGE/drivers"
  ditto "$HOST_APP" "$HOST_PACKAGE/Nostr VPN.app"
  ditto "$HOST_FIXTURE" \
    "$HOST_PACKAGE/fixtures/desktop_manual_join_e2e_fixture"
  ditto "$HOST_MANUAL_DRIVER" \
    "$HOST_PACKAGE/drivers/desktop-manual-join-ax"
  ditto "$HOST_SERVICE_DRIVER" \
    "$HOST_PACKAGE/drivers/macos-service-toggle-ax"
  ditto -c -k --sequesterRsrc --keepParent \
    "$HOST_PACKAGE" "$HOST_ARCHIVE"
  python3 "$ROOT/scripts/macos_release_join_artifact.py" create \
    --receipt "$HOST_RECEIPT" \
    --package "$HOST_PACKAGE" \
    --app "$HOST_PACKAGE/Nostr VPN.app" \
    --archive "$HOST_ARCHIVE" \
    --manual-join-fixture \
      "$HOST_PACKAGE/fixtures/desktop_manual_join_e2e_fixture" \
    --manual-join-driver \
      "$HOST_PACKAGE/drivers/desktop-manual-join-ax" \
    --service-toggle-driver \
      "$HOST_PACKAGE/drivers/macos-service-toggle-ax" \
    --app-root "$ROOT" \
    --fips-root "$HOST_FIPS_ROOT" \
    --expected-app-head "$APP_GIT_SHA" \
    --expected-app-tree "$APP_GIT_TREE" \
    --expected-fips-head "$RELEASE_JOIN_FIPS_SHA" \
    --expected-fips-tree "$RELEASE_JOIN_FIPS_TREE" \
    --expected-fips-version "$RELEASE_JOIN_FIPS_VERSION" \
    --expected-team "$EXPECTED_MACOS_TEAM" \
    --expected-identity-sha1 "$MACOS_SIGNING_IDENTITY" \
    --expected-signer-sha256 "$EXPECTED_MACOS_CERT"
}

prepare_host_sources() {
  rm -rf "$HOST_BUILD_ROOT" "$HOST_FIPS_ROOT"
  mkdir -p "$HOST_BUILD_ROOT"
  git -C "$ROOT" archive --format=tar "$APP_GIT_SHA" \
    | tar -x -C "$HOST_BUILD_ROOT"
  git clone --quiet --no-checkout --no-hardlinks \
    "$NVPN_FIPS_REPO_PATH" "$HOST_FIPS_ROOT"
  git -C "$HOST_FIPS_ROOT" checkout --quiet --detach "$RELEASE_JOIN_FIPS_SHA"
  [[ "$(git -C "$HOST_FIPS_ROOT" rev-parse HEAD)" == "$RELEASE_JOIN_FIPS_SHA" \
    && "$(git -C "$HOST_FIPS_ROOT" rev-parse HEAD^{tree})" == "$RELEASE_JOIN_FIPS_TREE" \
    && -z "$(git -C "$HOST_FIPS_ROOT" status --porcelain --untracked-files=all)" ]] || {
    echo "Could not isolate exact FIPS source for macOS Release artifacts" >&2
    return 1
  }
}

if [[ "$ARTIFACT_ACTION" != "verify-only" ]]; then
  prepare_host_sources
fi
SYNC_FIPS_ROOT="$NVPN_FIPS_REPO_PATH"
if [[ "$ARTIFACT_ACTION" != "verify-only" ]]; then
  SYNC_FIPS_ROOT="$HOST_FIPS_ROOT"
fi

case "${NVPN_MACOS_SKIP_GIT_SYNC:-0}" in
  1|true|TRUE|True|yes|YES|Yes|on|ON|On) ;;
  *)
    NVPN_MACOS_SYNC_PATH_DEPS=1 \
      NVPN_FIPS_REPO_PATH="$SYNC_FIPS_ROOT" \
      "$ROOT/scripts/macos-vm-git-sync.sh" "$MAC_HOST"
    ;;
esac

case "$ARTIFACT_ACTION" in
  verify-only)
    remote verify-import | tee "$RESULT_DIR/macos/verify-import.log"
    ;;
  full|prepare-only)
    prepare_host_artifact
    remote stage
    scp -q "$HOST_ARCHIVE" "$HOST_RECEIPT" \
      "$MAC_HOST:$GUEST_REPO/artifacts/macos-release-mobile-join/"
    remote prepare | tee "$RESULT_DIR/macos/prepare.log"
    cp "$HOST_RECEIPT" "$RESULT_DIR/macos/artifact.json"
    ;;
esac
scp -q \
  "$MAC_HOST:$GUEST_REPO/artifacts/macos-release-mobile-join/verification.json" \
  "$RESULT_DIR/macos/verification.json"

if [[ "$ARTIFACT_ACTION" != "full" ]]; then
  echo "MACOS_VM_IMPORTED_RELEASE_ARTIFACT_OK"
  exit 0
fi

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
            "builtOnHost": True,
            "builtOnTestVm": False,
            "remoteImportVerified": True,
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
