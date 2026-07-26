#!/usr/bin/env bash
# Required signed-Release, public-UI-only iPhone <-> Android join gate.
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
load_appstoreconnect_defaults
load_mobile_env "$ROOT"
resolve_shared_build_metadata "$ROOT"

[[ "$(uname -s)" == Darwin ]] || {
  echo "Signed Release mobile join gate requires macOS/Xcode" >&2
  exit 2
}
[[ -z "$(git -C "$ROOT" status --porcelain)" ]] || {
  echo "Signed Release mobile join gate requires a clean committed candidate" >&2
  exit 2
}
APP_GIT_SHA="$(git -C "$ROOT" rev-parse HEAD)"
[[ "${NVPN_EXPECTED_APP_GIT_SHA:-}" =~ ^[0-9a-f]{40}$ \
  && "$APP_GIT_SHA" == "$NVPN_EXPECTED_APP_GIT_SHA" ]] || {
  echo "Set NVPN_EXPECTED_APP_GIT_SHA to this exact committed candidate" >&2
  exit 2
}

RESULT_DIR="${NVPN_RELEASE_JOIN_RESULT_DIR:-$ROOT/artifacts/mobile-release-join}"
PRIVATE_DIR="$RESULT_DIR/.private-$$"
SUMMARY="$RESULT_DIR/summary.json"
RELEASE_JOIN_UI_WAIT_SECS="${NVPN_RELEASE_JOIN_UI_WAIT_SECS:-15}"
RELEASE_JOIN_DELIVERY_WAIT_SECS="${NVPN_RELEASE_JOIN_DELIVERY_WAIT_SECS:-15}"
RELEASE_JOIN_CAMERA_WAIT_SECS="${NVPN_RELEASE_JOIN_CAMERA_WAIT_SECS:-30}"
MACOS_JOIN_GATE="${NVPN_RELEASE_JOIN_DESKTOP_MOBILE:-1}"
mkdir -p "$PRIVATE_DIR" "$RESULT_DIR"
chmod 700 "$PRIVATE_DIR"

fail() {
  echo "signed Release join gate failed: $*" >&2
  exit 1
}

for value in \
  "$RELEASE_JOIN_UI_WAIT_SECS" \
  "$RELEASE_JOIN_DELIVERY_WAIT_SECS" \
  "$RELEASE_JOIN_CAMERA_WAIT_SECS"
do
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || fail "timeouts must be positive integers"
done
((RELEASE_JOIN_DELIVERY_WAIT_SECS <= 15)) \
  || fail "join delivery wait cannot exceed 15 seconds"
((RELEASE_JOIN_CAMERA_WAIT_SECS <= 30)) \
  || fail "optical camera wait cannot exceed 30 seconds"

ANDROID_REQUESTED="${NVPN_ANDROID_SERIAL:-${ANDROID_SERIAL:-}}"
IOS_REQUESTED="${NVPN_IOS_DEVICE:-${NVPN_IOS_DEVICE_ID:-}}"
[[ -n "$ANDROID_REQUESTED" ]] \
  || fail "set NVPN_ANDROID_SERIAL to the exact physical Android phone"
[[ -n "${NVPN_EXPECTED_ANDROID_DEVICE_MODEL:-}" ]] \
  || fail "set NVPN_EXPECTED_ANDROID_DEVICE_MODEL to the selected phone's exact model"
[[ -n "$IOS_REQUESTED" ]] \
  || fail "set NVPN_IOS_DEVICE to the exact physical iPhone"
[[ -n "${NVPN_EXPECTED_IOS_DEVICE_NAME:-}" ]] \
  || fail "set NVPN_EXPECTED_IOS_DEVICE_NAME to the selected iPhone's exact name"
ANDROID_SERIAL_SELECTED="$(
  select_physical_android_serial \
    "${ADB_BIN:-adb}" \
    "$ANDROID_REQUESTED"
)" || fail "one physical Android phone is required"
IOS_DEVICE="$(
  select_physical_ios_device "$IOS_REQUESTED"
)" || fail "one physical iPhone is required"
ADB=("${ADB_BIN:-adb}" -s "$ANDROID_SERIAL_SELECTED")
export NVPN_ANDROID_SERIAL="$ANDROID_SERIAL_SELECTED"
export IOS_DEVICE RESULT_DIR PRIVATE_DIR
export RELEASE_JOIN_UI_WAIT_SECS RELEASE_JOIN_DELIVERY_WAIT_SECS
export RELEASE_JOIN_CAMERA_WAIT_SECS

cleanup() {
  local status=$?
  trap - EXIT
  if [[ -n "${RELEASE_JOIN_IOS_TEST_PID:-}" ]] \
      && kill -0 "$RELEASE_JOIN_IOS_TEST_PID" 2>/dev/null; then
    kill "$RELEASE_JOIN_IOS_TEST_PID" >/dev/null 2>&1 || true
    wait "$RELEASE_JOIN_IOS_TEST_PID" >/dev/null 2>&1 || true
  fi
  "${ADB[@]}" shell rm -f /sdcard/nvpn-release-join.xml >/dev/null 2>&1 || true
  xcrun devicectl device uninstall app \
    --device "$IOS_DEVICE" \
    "${NVPN_DEFAULT_IOS_BUNDLE_ID:-fi.siriusbusiness.nvpn}.UITests.xctrunner" \
    --quiet >/dev/null 2>&1 || true
  rm -rf "$PRIVATE_DIR"
  exit "$status"
}
trap cleanup EXIT
release_join_record_selected_devices

ios_log() {
  printf '%s/%s.log\n' "$RESULT_DIR" "$1"
}

ios_marker_value_from() {
  local log="$1" name="$2"
  sed -n "s/.*NVPN_RELEASE_JOIN_MARKER $name=//p" "$log" | tail -n 1
}

ios_create_admin() {
  local label="$1" log
  log="$(ios_log "$label-create-admin")"
  release_join_ios_run_test \
    testCreateAdminNetworkAndReportPublicValues "$log" \
    "NVPN_RELEASE_JOIN_NETWORK_NAME=$label"
  RELEASE_JOIN_IOS_ADMIN_ID="$(
    ios_marker_value_from "$log" NVPN_RELEASE_JOIN_ADMIN_ID
  )"
  RELEASE_JOIN_IOS_NETWORK_ID="$(
    ios_marker_value_from "$log" NVPN_RELEASE_JOIN_NETWORK_ID
  )"
  release_join_valid_npub "$RELEASE_JOIN_IOS_ADMIN_ID" \
    || fail "iOS Release UI did not report a valid admin identity"
  [[ -n "$RELEASE_JOIN_IOS_NETWORK_ID" ]] \
    || fail "iOS Release UI did not report a network identity"
}

assert_delivery_deadline() {
  local submitted_ms="$1" completed_ms="$2" label="$3"
  [[ "$submitted_ms" =~ ^[0-9]+$ ]] \
    || fail "$label has no real approval timestamp"
  local elapsed=$((completed_ms - submitted_ms))
  ((elapsed >= 0 && elapsed <= RELEASE_JOIN_DELIVERY_WAIT_SECS * 1000)) \
    || fail "$label took ${elapsed}ms after approval"
  printf '%s\t%s\n' "$label" "$elapsed" >>"$RESULT_DIR/delivery-times.tsv"
}

phase_ios_admin_android_qr() {
  local scan_log submitted completed
  release_join_reset_ios_state
  release_join_reset_android_state
  ios_create_admin "Release QR iPhone admin"
  release_join_android_show_qr
  scan_log="$(ios_log ios-admin-android-qr)"
  release_join_ios_start_test \
    testScanPhysicalJoinQrAndRequireAdminRosterProgress "$scan_log" \
    "NVPN_RELEASE_JOIN_JOINER_ID=$RELEASE_JOIN_ANDROID_JOINER_ID"
  release_join_ios_wait_marker NVPN_RELEASE_JOIN_QR_DECODED=1 \
    "$RELEASE_JOIN_CAMERA_WAIT_SECS" \
    || fail "iPhone camera did not decode the Pixel's displayed QR"
  release_join_android_assert_pending_qr \
    || fail "Pixel QR disappeared before the iPhone submitted acceptance"
  release_join_ios_finish_test \
    || fail "iPhone admin did not accept the exact Pixel joiner"
  submitted="$(
    ios_marker_value_from "$scan_log" NVPN_RELEASE_JOIN_APPROVAL_SUBMITTED_MS
  )"
  release_join_android_wait_qr_join_complete "$RELEASE_JOIN_IOS_ADMIN_ID" \
    || fail "Pixel stayed on QR view or lacked the exact iPhone admin roster row"
  completed="$(release_join_now_ms)"
  assert_delivery_deadline "$submitted" "$completed" "iPhone-admin-to-Pixel-QR"
}

phase_android_admin_ios_qr() {
  local join_log submitted completed
  release_join_reset_ios_state
  release_join_reset_android_state
  release_join_android_create_admin
  join_log="$(ios_log android-admin-ios-qr)"
  release_join_ios_start_test \
    testShowPhysicalJoinQrAndRequireRosterCompletion "$join_log" \
    "NVPN_RELEASE_JOIN_ADMIN_ID=$RELEASE_JOIN_ANDROID_ADMIN_ID"
  release_join_ios_wait_marker NVPN_RELEASE_JOIN_QR_READY=1 15 \
    || fail "iPhone did not display its shipped join QR"
  release_join_ios_wait_marker NVPN_RELEASE_JOIN_LIFECYCLE_READY=1 10 \
    || fail "iPhone pending QR did not survive Home/foreground"
  RELEASE_JOIN_IOS_JOINER_ID="$(
    ios_marker_value_from "$join_log" NVPN_RELEASE_JOIN_JOINER_ID
  )"
  release_join_valid_npub "$RELEASE_JOIN_IOS_JOINER_ID" \
    || fail "iPhone Release UI did not report its joining identity"
  local android_scan_log="$RESULT_DIR/android-admin-ios-qr.log"
  release_join_android_scan_and_accept "$RELEASE_JOIN_IOS_JOINER_ID" \
    | tee "$android_scan_log"
  submitted="$(
    sed -n \
      's/.*NVPN_RELEASE_JOIN_APPROVAL_SUBMITTED_MS=//p' \
      "$android_scan_log" \
      | tail -n 1
  )"
  release_join_ios_finish_test \
    || fail "iPhone stayed on QR view or lacked the exact Pixel admin roster row"
  completed="$(release_join_now_ms)"
  assert_delivery_deadline "$submitted" "$completed" "Pixel-admin-to-iPhone-QR"
}

phase_ios_admin_android_manual() {
  release_join_reset_ios_state
  release_join_reset_android_state
  ios_create_admin "Release manual iPhone admin"
  release_join_android_manual_submit \
    "$RELEASE_JOIN_IOS_ADMIN_ID" "$RELEASE_JOIN_IOS_NETWORK_ID"
  release_join_ios_run_test \
    testManualAdminAddRequiresRosterProgress \
    "$(ios_log ios-admin-android-manual)" \
    "NVPN_RELEASE_JOIN_JOINER_ID=$RELEASE_JOIN_ANDROID_JOINER_ID"
  release_join_android_wait_join_complete "$RELEASE_JOIN_IOS_ADMIN_ID" \
    || fail "Pixel manual join lacked the exact iPhone admin roster row"
}

phase_android_admin_ios_manual() {
  local join_log
  release_join_reset_ios_state
  release_join_reset_android_state
  release_join_android_create_admin
  join_log="$(ios_log android-admin-ios-manual)"
  release_join_ios_start_test \
    testManualJoinAndRequireRosterCompletion "$join_log" \
    "NVPN_RELEASE_JOIN_ADMIN_ID=$RELEASE_JOIN_ANDROID_ADMIN_ID" \
    "NVPN_RELEASE_JOIN_NETWORK_ID=$RELEASE_JOIN_ANDROID_NETWORK_ID"
  release_join_ios_wait_marker NVPN_RELEASE_JOIN_JOINER_ID= 10 \
    || fail "iPhone manual join did not expose its public identity"
  RELEASE_JOIN_IOS_JOINER_ID="$(
    ios_marker_value_from "$join_log" NVPN_RELEASE_JOIN_JOINER_ID
  )"
  release_join_valid_npub "$RELEASE_JOIN_IOS_JOINER_ID" \
    || fail "iPhone manual join identity was invalid"
  release_join_ios_wait_marker NVPN_RELEASE_JOIN_MANUAL_SUBMITTED=1 10 \
    || fail "iPhone did not submit through shipped manual-join controls"
  release_join_android_manual_admin_add "$RELEASE_JOIN_IOS_JOINER_ID"
  release_join_ios_finish_test \
    || fail "iPhone manual join lacked the exact Pixel admin roster row"
}

release_join_require_clean_fips
release_join_prepare_android_release
release_join_prepare_ios_release
rm -f "$RESULT_DIR/delivery-times.tsv"

phase_ios_admin_android_qr
phase_android_admin_ios_qr
phase_ios_admin_android_manual
phase_android_admin_ios_manual

release_join_assert_one_android_package
release_join_assert_one_android_process
release_join_launch_ios_release
release_join_assert_one_ios_process

case "$MACOS_JOIN_GATE" in
  0|false|FALSE|False|no|NO|No|off|OFF|Off) ;;
  *)
    "$ROOT/scripts/macos-vm-release-mobile-join-e2e.sh" \
      "${NVPN_MACOS_SSH_HOST:-}"
    ;;
esac

python3 - \
  "$SUMMARY" \
  "$RELEASE_JOIN_ANDROID_APK_SHA" \
  "$RELEASE_JOIN_FIPS_SHA" \
  "$APP_GIT_SHA" \
  "$RESULT_DIR/delivery-times.tsv" \
  "$MACOS_JOIN_GATE" <<'PY'
import json
import pathlib
import sys

path, apk, fips, app, timing_path, desktop_mode = sys.argv[1:]
timings = {}
for line in pathlib.Path(timing_path).read_text(encoding="utf-8").splitlines():
    label, elapsed = line.split("\t")
    timings[label] = int(elapsed)
desktop_enabled = desktop_mode.lower() not in {
    "0", "false", "no", "off",
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(
        {
            "artifact": {
                "androidApkSha256": apk,
                "appGitSha": app,
                "fipsGitSha": fips,
                "androidBuildType": "Release",
                "iosBuildType": "Release",
                "iosDistribution": "Ad Hoc",
            },
            "publicUiOnly": True,
            "opticalCameraQr": True,
            "privateAppStateRead": False,
            "appLaunchArgumentsOrEnvironment": False,
            "qr": {
                "iphoneAdminPixelJoiner": True,
                "pixelAdminIphoneJoiner": True,
                "pendingQrBackgroundForeground": True,
                "exactRosterOnBothSides": True,
            },
            "manual": {
                "iphoneAdminPixelJoiner": True,
                "pixelAdminIphoneJoiner": True,
                "exactRosterOnBothSides": True,
            },
            "deliveryMilliseconds": timings,
            "desktopMobileManual": desktop_enabled,
        },
        handle,
        indent=2,
        sort_keys=True,
    )
    handle.write("\n")
PY

echo "SIGNED_RELEASE_PUBLIC_UI_MOBILE_JOIN_E2E_OK $SUMMARY"
