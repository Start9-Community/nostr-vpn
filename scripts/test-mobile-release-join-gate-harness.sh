#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILES=(
  "$ROOT/scripts/mobile-release-join-e2e.sh"
  "$ROOT/scripts/lib-mobile-release-join-artifacts.sh"
  "$ROOT/scripts/lib-mobile-release-artifact-reuse.sh"
  "$ROOT/scripts/lib-mobile-release-join-ui.sh"
  "$ROOT/scripts/lib-mobile-ios-release-artifact.sh"
  "$ROOT/scripts/macos-vm-release-mobile-join-e2e.sh"
  "$ROOT/scripts/macos-release-mobile-join-remote.sh"
)
for file in "${FILES[@]}"; do
  bash -n "$file"
done
join_ui="$ROOT/scripts/lib-mobile-release-join-ui.sh"
grep -Fq -- '-destination "platform=iOS,id=$RELEASE_JOIN_IOS_UDID,arch=arm64"' \
  "$join_ui" \
  || { echo "iOS join runner does not pin the built test architecture" >&2; exit 1; }
grep -Fq 'RELEASE_JOIN_IOS_TEST_NAME="$test_name"' "$join_ui" \
  && grep -Fq 'release_join_ios_assert_selected_test_started' "$join_ui" \
  || { echo "iOS join runner accepts a zero-selected-test success" >&2; exit 1; }
grep -Fq \
  'RELEASE_JOIN_IOS_LAUNCH_WAIT_SECS="${NVPN_RELEASE_JOIN_IOS_LAUNCH_WAIT_SECS:-60}"' \
  "$ROOT/scripts/mobile-release-join-e2e.sh" \
  || { echo "iOS join launch does not have an independent allowance" >&2; exit 1; }
if ! sed -n \
    '/^release_join_ios_start_test() {/,/^release_join_ios_abort_test() {/p' \
    "$join_ui" \
    | grep -Fq 'release_join_ios_wait_selected_test_started'; then
  echo "iOS join setup budget still includes xcodebuild launch" >&2
  exit 1
fi

(
  # Launch and in-test setup each receive their own bounded allowance. The
  # combined elapsed time deliberately exceeds either individual allowance.
  # shellcheck disable=SC1090,SC1091
  source "$join_ui"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/nvpn-ios-launch-budget.XXXXXX")"
  trap 'kill "${RELEASE_JOIN_IOS_TEST_PID:-}" >/dev/null 2>&1 || true; wait "${RELEASE_JOIN_IOS_TEST_PID:-}" >/dev/null 2>&1 || true; rm -rf "$tmp"' EXIT
  RELEASE_JOIN_IOS_TEST_LOG="$tmp/runner.log"
  RELEASE_JOIN_IOS_TEST_NAME="testFixture"
  (
    sleep 1.6
    printf '%s\n' \
      "Test Case '-[NostrVpnIosUITests.NostrVpnReleaseJoinUITests testFixture]' started." \
      >>"$RELEASE_JOIN_IOS_TEST_LOG"
    sleep 1.6
    printf '%s\n' \
      'NVPN_RELEASE_JOIN_MARKER NVPN_RELEASE_JOIN_QR_READY=1' \
      >>"$RELEASE_JOIN_IOS_TEST_LOG"
    sleep 1
  ) &
  RELEASE_JOIN_IOS_TEST_PID=$!
  release_join_ios_wait_selected_test_started 3
  release_join_ios_wait_marker NVPN_RELEASE_JOIN_QR_READY=1 3
)

(
  # The trusted XCTest runner capture must be copied by exact filename/hash.
  # shellcheck disable=SC1091
  source "$join_ui"
  private="$(mktemp -d "${TMPDIR:-/tmp}/nvpn-ios-qr-capture.XXXXXX")"
  trap 'rm -rf "$private"' EXIT
  PRIVATE_DIR="$private"
  IOS_DEVICE=fixture-device
  RELEASE_JOIN_IOS_TEST_LOG="$private/runner.log"
  captured="$private/captured.png"
  printf '\211PNG\r\n\032\nfixture' >"$captured"
  capture_sha="$(shasum -a 256 "$captured" | awk '{print $1}')"
  cat >"$RELEASE_JOIN_IOS_TEST_LOG" <<EOF
NVPN_RELEASE_JOIN_MARKER NVPN_RELEASE_JOIN_QR_SCREENSHOT_FILENAME=nvpn-release-join-qr-ABC123.png
NVPN_RELEASE_JOIN_MARKER NVPN_RELEASE_JOIN_QR_SCREENSHOT_SHA256=$capture_sha
EOF
  xcrun() {
    [[ "$*" == *"device copy from"* ]]
    [[ "$*" == *"--domain-identifier fi.siriusbusiness.nvpn.UITests.xctrunner"* ]]
    [[ "$*" == *"--source Documents/nvpn-release-join-qr-ABC123.png"* ]]
    local destination="${@: -4:1}"
    cp "$captured" "$destination"
  }
  release_join_capture_ios_qr "$private/qr.png"
  [[ "$(od -An -tx1 -N8 "$private/qr.png" | tr -d ' \n')" \
    == 89504e470d0a1a0a ]]
  [[ "$(shasum -a 256 "$private/qr.png" | awk '{print $1}')" == "$capture_sha" ]]
)
for file in \
  "$ROOT/scripts/lib-mobile-ios-release-artifact.sh" \
  "$ROOT/scripts/lib-mobile-release-join-artifacts.sh"
do
  grep -Fq -- '--extract-certificates=' "$file" \
    && ! grep -Eq -- '--extract-certificates[[:space:]]' "$file" || {
    echo "$(basename "$file") uses invalid codesign certificate extraction syntax" >&2
    exit 1
  }
done
python3 -B "$ROOT/scripts/macos_release_join_artifact.py" --help >/dev/null

(
  set -u
  # shellcheck disable=SC1091
  source "$ROOT/scripts/lib-mobile-release-join-artifacts.sh"
  private="$(mktemp -d "${TMPDIR:-/tmp}/nvpn-ios-join-cleanup.XXXXXX")"
  trap 'rm -rf "$private"' EXIT
  PRIVATE_DIR="$private"
  RESULT_DIR="$private"
  RELEASE_JOIN_IOS_XCTESTRUN="$private/fixture.xctestrun"
  RELEASE_JOIN_IOS_QUARANTINE="$private/quarantine"
  NVPN_DEFAULT_IOS_BUNDLE_ID="fixture.join.bundle"
  printf 'fixture\n' >"$RELEASE_JOIN_IOS_XCTESTRUN"
  unset IOS_BUNDLE_ID
  ios_release_network_disconnect_cleanup() {
    [[ "$IOS_BUNDLE_ID" == "$NVPN_DEFAULT_IOS_BUNDLE_ID" ]]
  }
  release_join_arm_ios_disconnect_cleanup \
    "$private/Nostr VPN.app" "$private/derived" fixture-device
  release_join_cleanup_ios_network_state
  [[ ! -e "$RELEASE_JOIN_IOS_QUARANTINE" ]]
)

(
  source "$ROOT/scripts/lib-mobile-release-join-ui.sh"
  release_join_android_launch() { :; }
  release_join_android_query() { return 1; }
  release_join_android_wait_query() { [[ "$*" == "description Devices tab" ]]; }
  release_join_android_tap() { [[ "$*" == "description Devices tab" ]]; }
  release_join_android_open_devices
)

(
  source "$ROOT/scripts/lib-mobile-release-join-ui.sh"
  release_join_android_dump_ui() { :; }
  release_join_android_query_dumped() { return 0; }
  [[ "$(release_join_android_accepted_snapshot_ms npub1accepted)" =~ ^[0-9]+$ ]]
)

(
  # shellcheck disable=SC1091
  source "$ROOT/scripts/lib-mobile-release-join-artifacts.sh"
  fake_adb() {
    case "$*" in
      "shell pm list packages") printf '%s\n' "$FAKE_ANDROID_PACKAGES" ;;
      "shell pm path fi.siriusbusiness.nvpn") return 0 ;;
      *) return 1 ;;
    esac
  }
  ADB=(fake_adb)
  FAKE_ANDROID_PACKAGES=$'package:fi.siriusbusiness.nvpn\npackage:fi.siriusbusiness.nvpn.debug'
  if release_join_assert_one_android_package >/dev/null 2>&1; then
    echo "Android one-package check accepted a stale package" >&2
    exit 1
  fi
  FAKE_ANDROID_PACKAGES='package:fi.siriusbusiness.nvpn'
  release_join_assert_one_android_package
)

(
  # Exact-artifact reuse may explicitly retain both installed mobile apps.
  # shellcheck disable=SC1091
  source "$ROOT/scripts/lib-mobile-release-join-artifacts.sh"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/nvpn-join-noinstall.XXXXXX")"
  trap 'rm -rf "$tmp"' EXIT
  export NVPN_RELEASE_JOIN_REUSE_ARTIFACTS=1
  export NVPN_RELEASE_JOIN_INSTALL_ANDROID=0
  export NVPN_RELEASE_JOIN_INSTALL_IOS=0
  release_join_configure_install_modes
  [[ "$RELEASE_JOIN_INSTALL_ANDROID" -eq 0 \
    && "$RELEASE_JOIN_INSTALL_IOS" -eq 0 ]]
  NVPN_RELEASE_JOIN_REUSE_ARTIFACTS=0
  if release_join_configure_install_modes >"$tmp/no-reuse.log" 2>&1; then
    echo "mobile join accepted disabled installs without exact reuse" >&2
    exit 1
  fi
  grep -Fq 'requires exact artifact reuse' "$tmp/no-reuse.log"
  NVPN_RELEASE_JOIN_REUSE_ARTIFACTS=1
  NVPN_RELEASE_JOIN_INSTALL_IOS=maybe
  if release_join_configure_install_modes >"$tmp/bad-mode.log" 2>&1; then
    echo "mobile join accepted an ambiguous install mode" >&2
    exit 1
  fi
)

(
  # Android no-install reuse pulls and byte-compares the real installed APK.
  # shellcheck disable=SC1091
  source "$ROOT/scripts/lib-mobile-release-join-artifacts.sh"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/nvpn-join-android-noinstall.XXXXXX")"
  trap 'rm -rf "$tmp"' EXIT
  apk="$tmp/app-release.apk"
  printf 'exact installed apk\n' >"$apk"
  fake_adb() {
    printf '%s\n' "$*" >>"$tmp/adb.log"
    case "$*" in
      "shell pm path fi.siriusbusiness.nvpn")
        printf 'package:/data/app/exact/base.apk\n'
        ;;
      "shell pm list packages") printf 'package:fi.siriusbusiness.nvpn\n' ;;
      "pull /data/app/exact/base.apk "*) cp "$apk" "$3" ;;
      "shell dumpsys package fi.siriusbusiness.nvpn") printf '  flags=[ HAS_CODE ]\n' ;;
      "shell pidof fi.siriusbusiness.nvpn") printf '1234\n' ;;
      "install -r "*) return 99 ;;
      *) : ;;
    esac
  }
  ADB=(fake_adb)
  RESULT_DIR="$tmp/result"
  PRIVATE_DIR="$tmp/private"
  mkdir -p "$PRIVATE_DIR"
  mkdir -p "$RESULT_DIR"
  RELEASE_JOIN_ARTIFACTS_VALIDATED=1
  RELEASE_JOIN_DEVICE_MUTATION_ALLOWED=1
  RELEASE_JOIN_ANDROID_APK="$apk"
  RELEASE_JOIN_ANDROID_APP_SHA="$(printf '1%.0s' {1..40})"
  RELEASE_JOIN_ANDROID_APP_TREE="$(printf '2%.0s' {1..40})"
  RELEASE_JOIN_ANDROID_SIGNER_SHA="$(printf 'a%.0s' {1..64})"
  RELEASE_JOIN_FIPS_SHA="$(printf '3%.0s' {1..40})"
  RELEASE_JOIN_FIPS_TREE="$(printf '4%.0s' {1..40})"
  APP_GIT_SHA="$RELEASE_JOIN_ANDROID_APP_SHA"
  APP_GIT_TREE="$RELEASE_JOIN_ANDROID_APP_TREE"
  NVPN_RELEASE_JOIN_REUSE_ARTIFACTS=1
  NVPN_RELEASE_JOIN_INSTALL_ANDROID=0
  NVPN_RELEASE_JOIN_INSTALL_IOS=1
  release_join_configure_install_modes
  release_join_assert_fips_unchanged() { :; }
  release_join_assert_app_unchanged() { :; }
  release_join_prepare_android_release
  ! grep -Fq 'install -r' "$tmp/adb.log"
  python3 - "$RESULT_DIR/android-release-install.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1], encoding="utf-8"))
assert r["installedArtifactVerified"] is True
assert r["replacementInstall"] is False
assert r["replacementInstallVerified"] is False
PY
)

(
  # Real devicectl inventory shape uses a CoreDevice UUID unrelated to the UDID.
  # shellcheck disable=SC1091
  source "$ROOT/scripts/lib-mobile-release-join-artifacts.sh"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/nvpn-join-ios-noinstall.XXXXXX")"
  trap 'rm -rf "$tmp"' EXIT
  app="$tmp/Nostr VPN.app"
  runner="$tmp/derived/Build/Products/Release-iphoneos/NostrVpnIosUITests-Runner.app"
  mkdir -p "$app" "$runner" "$tmp/result"
  python3 - "$app/Info.plist" "$runner/Info.plist" <<'PY'
import plistlib, sys
for path, bundle, build, version in (
    (sys.argv[1], "fi.siriusbusiness.nvpn", "4001008", "4.1.5"),
    (sys.argv[2], "fi.siriusbusiness.nvpn.UITests.xctrunner", "1", "1.0"),
):
    with open(path, "wb") as f:
        plistlib.dump({"CFBundleIdentifier": bundle, "CFBundleVersion": build,
                       "CFBundleShortVersionString": version}, f)
PY
  xcrun() {
    printf '%s\n' "$*" >>"$tmp/devicectl.log"
    [[ "$*" != *"device install app"* ]] || return 99
    local output="" previous=""
    for argument in "$@"; do
      [[ "$previous" != --json-output ]] || output="$argument"
      previous="$argument"
    done
    [[ -n "$output" ]] || return 0
    python3 - "$output" "${FAKE_IOS_RUNNER_VERSION:-1.0}" <<'PY'
import json, sys
json.dump({"info": {"outcome": "success"}, "result": {
    "deviceIdentifier": "coredevice-uuid-not-hardware-udid", "apps": [
        {"bundleIdentifier": "example.unrelated", "bundleVersion": "9", "version": "9"},
        {"bundleIdentifier": "fi.siriusbusiness.nvpn", "bundleVersion": "4001008", "version": "4.1.5"},
        {"bundleIdentifier": "fi.siriusbusiness.nvpn.UITests.xctrunner", "bundleVersion": "1", "version": sys.argv[2]},
    ]}}, open(sys.argv[1], "w"))
PY
  }
  RESULT_DIR="$tmp/result"
  IOS_DEVICE=fixture-hardware-udid
  RELEASE_JOIN_ARTIFACTS_VALIDATED=1
  RELEASE_JOIN_DEVICE_MUTATION_ALLOWED=1
  RELEASE_JOIN_INSTALL_IOS=0
  RELEASE_JOIN_FIPS_SHA="$(printf '3%.0s' {1..40})"
  RELEASE_JOIN_FIPS_TREE="$(printf '4%.0s' {1..40})"
  RELEASE_JOIN_FIPS_VERSION=1.2.3
  RELEASE_JOIN_IOS_XCTESTRUN="$tmp/exact.xctestrun"
  printf 'fixture\n' >"$RELEASE_JOIN_IOS_XCTESTRUN"
  RELEASE_JOIN_IOS_QUARANTINE="$tmp/ios.quarantine"
  NVPN_RELEASE_JOIN_IOS_INSTALL_RECEIPT="$tmp/device-bound-ios-install-receipt.json"
  runner_tree="$(
    python3 "$ROOT/scripts/mobile_release_artifact_receipt.py" tree-sha "$runner"
  )"
  python3 - \
    "$NVPN_RELEASE_JOIN_IOS_INSTALL_RECEIPT" fixture-hardware-udid \
    "$runner_tree" <<'PY'
import hashlib, json, sys
json.dump({
    "receiptSchema": 1,
    "artifactType": "installed iOS Release app and XCTest runner",
    "appGitSha": "1" * 40,
    "appGitTree": "2" * 40,
    "fipsGitSha": "3" * 40,
    "fipsGitTree": "4" * 40,
    "bundleManifestSha256": "a" * 64,
    "runnerBundleTreeSha256": sys.argv[3],
    "signerCertificateSha256": "c" * 64,
    "selectedPhysicalDeviceIdentifierSha256": hashlib.sha256(
        sys.argv[2].encode()
    ).hexdigest(),
    "bundleIdentifier": "fi.siriusbusiness.nvpn",
    "installedVersion": "4001008",
    "installedShortVersion": "4.1.5",
}, open(sys.argv[1], "w"))
PY
  release_join_install_ios_release \
    "$app" "$(printf '1%.0s' {1..40})" "$(printf '2%.0s' {1..40})" \
    "$(printf 'a%.0s' {1..64})" "$(printf 'b%.0s' {1..64})" \
    "$(printf 'c%.0s' {1..64})" "$tmp/derived" fixture-hardware-udid
  ! grep -Fq 'device install app' "$tmp/devicectl.log"
  python3 - "$RESULT_DIR/ios-release-install.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1], encoding="utf-8"))
assert r["installedArtifactVerified"] is True
assert r["replacementInstall"] is False
assert r["installedVersion"] == "4001008"
assert r["installedShortVersion"] == "4.1.5"
assert r["runnerBundleTreeSha256"]
assert r["selectedPhysicalDeviceIdentifierSha256"]
PY
  cp "$NVPN_RELEASE_JOIN_IOS_INSTALL_RECEIPT" "$tmp/device-bound-ios-receipt.clean"
  python3 - "$NVPN_RELEASE_JOIN_IOS_INSTALL_RECEIPT" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
value = json.loads(path.read_text())
value["selectedPhysicalDeviceIdentifierSha256"] = "0" * 64
path.write_text(json.dumps(value))
PY
  if release_join_install_ios_release \
      "$app" "$(printf '1%.0s' {1..40})" "$(printf '2%.0s' {1..40})" \
      "$(printf 'a%.0s' {1..64})" "$(printf 'b%.0s' {1..64})" \
      "$(printf 'c%.0s' {1..64})" "$tmp/derived" fixture-hardware-udid \
      >"$tmp/device-receipt-mismatch.log" 2>&1
  then
    echo "iOS no-install reuse accepted another phone's install receipt" >&2
    exit 1
  fi
  grep -Fq 'device-bound iOS receipt mismatch' \
    "$tmp/device-receipt-mismatch.log"
  mv "$tmp/device-bound-ios-receipt.clean" "$NVPN_RELEASE_JOIN_IOS_INSTALL_RECEIPT"
  cp "$NVPN_RELEASE_JOIN_IOS_INSTALL_RECEIPT" "$tmp/device-bound-ios-receipt.clean"
  python3 - "$NVPN_RELEASE_JOIN_IOS_INSTALL_RECEIPT" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
value = json.loads(path.read_text())
value["runnerBundleTreeSha256"] = "0" * 64
path.write_text(json.dumps(value))
PY
  if release_join_install_ios_release \
      "$app" "$(printf '1%.0s' {1..40})" "$(printf '2%.0s' {1..40})" \
      "$(printf 'a%.0s' {1..64})" "$(printf 'b%.0s' {1..64})" \
      "$(printf 'c%.0s' {1..64})" "$tmp/derived" fixture-hardware-udid \
      >"$tmp/runner-receipt-mismatch.log" 2>&1
  then
    echo "iOS no-install reuse accepted another runner binary" >&2
    exit 1
  fi
  grep -Fq 'device-bound iOS receipt mismatch' \
    "$tmp/runner-receipt-mismatch.log"
  mv "$tmp/device-bound-ios-receipt.clean" "$NVPN_RELEASE_JOIN_IOS_INSTALL_RECEIPT"
  plutil -replace CFBundleShortVersionString -string 2.0 "$runner/Info.plist"
  if release_join_install_ios_release \
      "$app" 1 2 3 4 5 "$tmp/derived" fixture-hardware-udid \
      >"$tmp/runner-mismatch.log" 2>&1
  then
    echo "iOS no-install reuse accepted a mismatched installed runner" >&2
    exit 1
  fi
  grep -Fq 'installed iOS bundle version mismatch' "$tmp/runner-mismatch.log"
)

(
  # shellcheck disable=SC1091
  source "$ROOT/scripts/lib-mobile-release-join-ui.sh"
  # shellcheck disable=SC1091
  source "$ROOT/scripts/lib-mobile-ios-release-network.sh"
  log="$(mktemp "${TMPDIR:-/tmp}/nvpn-ios-join-selection.XXXXXX")"
  trap 'rm -f "$log"' EXIT
  RELEASE_JOIN_IOS_TEST_LOG="$log"
  RELEASE_JOIN_IOS_TEST_NAME="testSelectedMethod"
  printf 'NVPN_RELEASE_JOIN_MARKER CRLF_VALUE=npub1fixture\r\n' >"$log"
  [[ "$(release_join_ios_marker_value CRLF_VALUE)" == "npub1fixture" ]]
  : >"$log"
  true &
  RELEASE_JOIN_IOS_TEST_PID=$!
  if release_join_ios_finish_test >/dev/null 2>&1; then
    echo "iOS join runner accepted an exit-0 zero-test run" >&2
    exit 1
  fi
  printf '%s\n' \
    "Test Case '-[NostrVpnIosUITests.NostrVpnReleaseJoinUITests testSelectedMethod]' started." \
    >"$log"
  RELEASE_JOIN_IOS_TEST_NAME="testSelectedMethod"
  true &
  RELEASE_JOIN_IOS_TEST_PID=$!
  release_join_ios_finish_test
)

(
  set -u
  # A failed concurrent phase must reap the whole host process group and stop
  # only the retained runner process on-device, without uninstalling it.
  # shellcheck disable=SC1091
  source "$ROOT/scripts/lib-mobile-release-join-ui.sh"
  # shellcheck disable=SC1091
  source "$ROOT/scripts/lib-mobile-ios-release-network.sh"
  private="$(mktemp -d "${TMPDIR:-/tmp}/nvpn-ios-join-abort.XXXXXX")"
  trap 'rm -rf "$private"' EXIT
  PRIVATE_DIR="$private"
  IOS_DEVICE="fixture-device"
  unset IOS_BUNDLE_ID
  audit="$private/runner-audit"
  ios_release_network_stop_forced_xctrunner() {
    [[ "$IOS_BUNDLE_ID" == "fi.siriusbusiness.nvpn" ]]
    printf 'audited\n' >"$audit"
  }
  release_join_ios_test_command() {
    printf '%s\0' bash -c \
      'printf "%s\n" "Test Case '\''-[NostrVpnIosUITests.NostrVpnReleaseJoinUITests fixture]'\'' started."; sleep 30 & wait'
  }
  release_join_ios_start_test fixture "$private/fixture.log"
  pgid="$RELEASE_JOIN_IOS_TEST_PGID"
  release_join_ios_abort_test
  [[ -s "$audit" ]]
  if ios_release_network_process_group_alive "$pgid"; then
    echo "aborted iOS join test retained a process-group descendant" >&2
    exit 1
  fi
  [[ -z "$RELEASE_JOIN_IOS_TEST_PID" && -z "$RELEASE_JOIN_IOS_TEST_PGID" ]]
)

(
  # Even a failed isolation check must reap both the command's descendants and
  # any separately reported process group before returning.
  # shellcheck disable=SC1091
  source "$ROOT/scripts/lib-mobile-release-join-ui.sh"
  # shellcheck disable=SC1091
  source "$ROOT/scripts/lib-mobile-ios-release-network.sh"
  private="$(mktemp -d "${TMPDIR:-/tmp}/nvpn-ios-join-isolation.XXXXXX")"
  trap 'rm -rf "$private"' EXIT
  PRIVATE_DIR="$private"
  IOS_DEVICE="fixture-device"
  child_file="$private/child.pid"
  set -m
  (exec sleep 30) &
  unexpected_pgid=$!
  set +m
  ios_release_network_stop_forced_xctrunner() { :; }
  release_join_ios_test_command() {
    printf '%s\0' bash -c 'sleep 30 & printf "%s\n" "$!" >"$1"; wait' \
      fixture "$child_file"
  }
  release_join_ios_process_pgid() {
    local deadline=$((SECONDS + 2))
    while [[ ! -s "$child_file" && "$SECONDS" -lt "$deadline" ]]; do
      sleep 0.01
    done
    printf '%s\n' "$unexpected_pgid"
  }
  if release_join_ios_start_test fixture "$private/fixture.log"; then
    echo "iOS join runner accepted unexpected process-group isolation" >&2
    exit 1
  fi
  child_pid="$(cat "$child_file")"
  if kill -0 "$child_pid" >/dev/null 2>&1 \
      || ios_release_network_process_group_alive "$unexpected_pgid"; then
    echo "isolation failure retained a spawned child or process group" >&2
    exit 1
  fi
  [[ -z "$RELEASE_JOIN_IOS_TEST_PID" && -z "$RELEASE_JOIN_IOS_TEST_PGID" ]]
)

(
  set -u
  # shellcheck disable=SC1091
  source "$ROOT/scripts/lib-mobile-release-join-ui.sh"
  release_join_android_launch() { :; }
  release_join_android_wait_query() { :; }
  release_join_android_tap() { :; }
  release_join_android_open_link_device() { :; }
  release_join_valid_npub() { :; }
  release_join_android_public_value() {
    case "$1" in
      "Admin Device ID value") printf '%s\n' npub1admin ;;
      "Admin Network ID value") printf '%s\n' network-1 ;;
      *) return 1 ;;
    esac
  }
  release_join_android_create_admin
  [[ "$RELEASE_JOIN_ANDROID_ADMIN_ID" == npub1admin ]]
  [[ "$RELEASE_JOIN_ANDROID_NETWORK_ID" == network-1 ]]
  ((${#RELEASE_JOIN_ANDROID_NETWORK_IDS[@]} == 1))
) || {
  echo "Android first network creation failed under Bash nounset" >&2
  exit 1
}

for obsolete in \
  "$ROOT/scripts/mobile-ios-android-join-e2e.sh" \
  "$ROOT/scripts/test-mobile-real-qr-join-harness.sh" \
  "$ROOT/ios/UITests/NostrVpnPhysicalQrJoinUITests.swift" \
  "$ROOT/ios/Sources/AppModelDebugJoinAutomation.swift"
do
  [[ ! -e "$obsolete" ]] || {
    echo "Superseded private/debug join path remains: $obsolete" >&2
    exit 1
  }
done
if rg -q -- \
  '--nvpn-debug-(start-join-advertising|import-join-request|export-join-request|manual-join|select-network|wait-for-joined-network|add-participant|remove-participant)' \
  "$ROOT/ios/Sources"
then
  echo "iOS source retains orphaned private join automation tokens" >&2
  exit 1
fi
if rg -q \
  'ACTION_(IMPORT_JOIN_REQUEST|EXPORT_JOIN_REQUEST|REMOVE_ACTIVE_NETWORK|MANUAL_JOIN|ADD_PARTICIPANT|REMOVE_PARTICIPANT)|DEBUG_(JOIN_REQUEST|ADMIN_DEVICE_ID|MESH_NETWORK_ID|PARTICIPANT_DEVICE_ID)' \
  "$ROOT/android/app/src/main/java/org/nostrvpn/app/AndroidDebugAutomation.kt"
then
  echo "Android source retains orphaned private join automation actions" >&2
  exit 1
fi
grep -Fq 'ACTION_ADD_NETWORK' \
  "$ROOT/android/app/src/main/java/org/nostrvpn/app/AndroidDebugAutomation.kt" \
  || { echo "Android debug smoke lost its still-used add-network action" >&2; exit 1; }
grep -Fq 'DEBUG_ACTION_EXTRA" add_network' "$ROOT/scripts/mobile-android-smoke.sh" \
  || { echo "Android debug add-network action has no smoke consumer" >&2; exit 1; }
grep -Fq -- '--ez org.nostrvpn.app.extra.RELEASE_JOIN_IMAGE_IMPORT true' "$join_ui" \
  || { echo "Android release join does not enable its hidden QR image import" >&2; exit 1; }
grep -Fq 'allowImageImport = releaseJoinImageImportEnabled' \
  "$ROOT/android/app/src/main/java/org/nostrvpn/app/MainActivity.kt" \
  && grep -Fq 'getBooleanExtra(EXTRA_RELEASE_JOIN_IMAGE_IMPORT, false)' \
    "$ROOT/android/app/src/main/java/org/nostrvpn/app/MainActivity.kt" \
  || { echo "Android QR image import is not restricted to the release join flag" >&2; exit 1; }
if rg -q -- '--nvpn-ui-test-qr-image-import' \
    "$ROOT/ios" "$join_ui" "$ROOT/scripts/ios_xctestrun.py"; then
  echo "iOS QR image import retains the unreliable argv capability" >&2
  exit 1
fi

python3 - \
  "$ROOT/scripts/mobile-release-join-e2e.sh" \
  "$ROOT/scripts/mobile_release_artifact_receipt.py" \
  "$ROOT/scripts/lib-mobile-release-join-artifacts.sh" \
  "$ROOT/scripts/lib-mobile-release-join-ui.sh" \
  "$ROOT/scripts/macos-vm-release-mobile-join-e2e.sh" \
  "$ROOT/scripts/macos-release-mobile-join-remote.sh" \
  "$ROOT/scripts/desktop-manual-join-ax.swift" \
  "$ROOT/crates/nostr-vpn-core/examples/desktop_manual_join_e2e_fixture.rs" \
  "$ROOT/scripts/macos_release_join_artifact.py" \
  "$ROOT/ios/UITests/NostrVpnReleaseJoinUITests.swift" \
  "$ROOT/ios/UITests/NostrVpnPhysicalGateSupport.swift" \
  "$ROOT/ios/project.yml" \
  "$ROOT/ios/Info.plist" \
  "$ROOT/android/app/src/main/java/org/nostrvpn/app/AndroidDevices.kt" \
  "$ROOT/android/app/src/main/java/org/nostrvpn/app/AndroidComponents.kt" \
  "$ROOT/ios/Sources/DevicesViews.swift" \
  "$ROOT/ios/Sources/QRCodeScannerView.swift" \
  "$ROOT/android/app/src/main/java/org/nostrvpn/app/QrScannerDialog.kt" \
  "$ROOT/ios/Sources/SettingsViews.swift" \
  "$ROOT/macos/Sources/RootViewDevices.swift" \
  "$ROOT/crates/nostr-vpn-app-core/src/ffi/runtime_network.rs" \
  "$ROOT/crates/nostr-vpn-app-core/src/ffi/tests_network.rs" \
  "$ROOT/crates/nostr-vpn-core/src/config/types.rs" \
  "$ROOT/crates/nostr-vpn-core/src/config/app_config_networks.rs" \
  "$ROOT/crates/nostr-vpn-core/src/config/app_config_rosters.rs" \
  "$ROOT/crates/nostr-vpn-core/src/join_requests.rs" \
  "$ROOT/crates/nostr-vpn-core/tests/config_tests/defaults/roster_apply.rs" \
  "$ROOT/scripts/release-gate.sh" \
  "$ROOT/scripts/ios_frozen_gate.py" \
  "$ROOT/scripts/release-artifact-provenance-lib.mjs" \
  "$ROOT/scripts/local-release.mjs" <<'PY'
import pathlib
import sys


def read(path):
    value = pathlib.Path(path)
    if not value.is_file():
        raise SystemExit(f"Release join gate file is missing: {value}")
    return value.read_text(encoding="utf-8")


(
    gate,
    summary_builder,
    artifacts,
    ui,
    desktop,
    desktop_remote,
    desktop_ui_driver,
    desktop_join_fixture,
    desktop_artifact,
    ios_test,
    ios_interaction,
    ios_project,
    ios_info,
    android_devices,
    android_components,
    ios_devices,
    ios_qr_scanner,
    android_qr_scanner,
    ios_participants,
    macos_devices,
    runtime_network,
    runtime_network_tests,
    config_types,
    config_networks,
    config_rosters,
    join_requests,
    roster_apply_tests,
    release_gate,
    ios_frozen_gate,
    release_provenance,
    local_release,
) = map(read, sys.argv[1:])

runtime_gate_code = "\n".join((gate, ui, desktop, desktop_remote, ios_test))
join_receipt_code = "\n".join((gate, summary_builder))
manual_join = ios_devices.split(
    "DisclosureGroup(isExpanded: $manualExpanded) {", 1
)[1].split("struct AddDeviceSheet", 1)[0]
manual_join_content, manual_join_label = manual_join.split("} label: {", 1)
for identifier in (
    "joiner-device-id-value",
    "manual-join-admin-id",
    "manual-join-network-id",
    "manual-join-submit",
):
    if identifier not in manual_join_content:
        raise SystemExit(f"iOS manual join content is missing {identifier}")
if "manual-join-expand" in manual_join_content:
    raise SystemExit("iOS manual join disclosure overwrites child accessibility IDs")
if 'Text("Manual join")' not in manual_join_label or "manual-join-expand" not in manual_join_label:
    raise SystemExit("iOS manual join disclosure label lacks its expand identifier")
for forbidden in (
    "run-as",
    "--nvpn-debug",
    "DEBUG_ACTION",
    "import-join-request",
    "QR_PAYLOAD",
    "REQUEST_BASE64",
):
    if forbidden in runtime_gate_code:
        raise SystemExit(f"Release join gate retains forbidden private/debug path: {forbidden}")
if "run-as" in artifacts:
    raise SystemExit("Release artifact validation still invokes run-as")
for required in (
    "device copy to",
    "appDataContainer",
    'Documents/$filename',
    ".UITests.xctrunner",
    "device copy from",
    "NVPN_RELEASE_JOIN_QR_SCREENSHOT_FILENAME",
    "NVPN_RELEASE_JOIN_QR_SCREENSHOT_SHA256",
):
    if required not in ui:
        raise SystemExit(f"Release join fixture staging is missing {required}")
for forbidden in ("NVPN_IOS_UI_TARGET_APP_ARGUMENT", "ui_target_app_argument"):
    if forbidden in ui:
        raise SystemExit(f"Release join retains obsolete app-argument plumbing: {forbidden}")
run_only = desktop.split("select_run_only_artifact() {", 1)[1].split(
    "write_component_proof() {", 1
)[0]
for required in (
    "NVPN_MACOS_RELEASE_RUN_ONLY_RECEIPT",
    'read_cached_identity "$RUN_ONLY_RECEIPT"',
    'cp "$RUN_ONLY_RECEIPT" "$RESULT_DIR/macos/artifact.json"',
    "NVPN_MACOS_RELEASE_RUN_ONLY_HARNESS_GIT_SHA",
    "NVPN_MACOS_RELEASE_RUN_ONLY_HARNESS_GIT_TREE",
    "verify_run_only_receipt_binding",
    "artifactReceiptSha256",
):
    if required not in desktop:
        raise SystemExit(f"macOS run-only cached-artifact path lacks {required}")
if '$RESULT_DIR/macos/artifact.json"' in run_only.split(
        'read_cached_identity "$RUN_ONLY_RECEIPT"', 1
    )[0]:
    raise SystemExit("macOS run-only still requires its output directory as input")
for forbidden in ("UIFileSharingEnabled", "LSSupportsOpeningDocumentsInPlace"):
    if forbidden in ios_info:
        raise SystemExit(f"Production iOS app exposes test fixture storage: {forbidden}")
for required in (
    "INFOPLIST_KEY_UIFileSharingEnabled: YES",
    "INFOPLIST_KEY_LSSupportsOpeningDocumentsInPlace: YES",
    "INFOPLIST_KEY_CFBundleDisplayName: Nostr VPN Test Files",
):
    if required not in ios_project:
        raise SystemExit(f"Persistent iOS UI runner lacks public fixture storage: {required}")

install_ios = artifacts[
    artifacts.index("release_join_install_ios_release()"):
    artifacts.index("release_join_restart_ios_in_place()")
]
restart_ios = artifacts[
    artifacts.index("release_join_restart_ios_in_place()"):
    artifacts.index("release_join_assert_one_ios_process()")
]
if "device uninstall app" in install_ios or "device uninstall app" in restart_ios:
    raise SystemExit("iOS join phases revoke the already-approved VPN manager")
if "device install app" not in install_ios:
    raise SystemExit("iOS join preparation no longer installs the exact artifact")
for required in ("--terminate-existing", "--no-activate"):
    if required not in restart_ios:
        raise SystemExit(f"iOS join restart does not preserve state via {required}")
for forbidden in (
    "NVPN_RELEASE_JOIN_ALLOW_DEVICE_RESET",
    "NVPN_RELEASE_JOIN_ALLOW_ANDROID_DATA_CLEAR",
    "destructive",
    "reset",
):
    if forbidden in restart_ios:
        raise SystemExit(
            f"Preserved iOS in-place restart is mislabeled as {forbidden}"
        )
if "fresh network ID" not in restart_ios:
    raise SystemExit("iOS in-place restart does not document fresh-network isolation")

ios_setup = ios_test.split("override func setUpWithError() throws", 1)[1].split(
    "func testCreateAdminNetworkAndReportPublicValues()", 1
)[0]
ios_import = ios_test.split(
    "func testImportJoinQrImageAndRequireAdminRosterProgress()", 1
)[1].split("func test", 1)[0]
if "app.launchArguments.isEmpty" not in ios_setup:
    raise SystemExit("Ordinary release join tests do not assert empty launch arguments")
if "app.launchEnvironment.isEmpty" not in ios_setup:
    raise SystemExit("Ordinary release join tests do not assert empty launch environment")
if "app.launch()" not in ios_setup:
    raise SystemExit("Release join XCTest no longer uses its normal app launch")
launch_environment = 'app.launchEnvironment = ["NVPN_RELEASE_JOIN_QR_IMAGE_IMPORT": "1"]'
if launch_environment in ios_test:
    raise SystemExit("QR import still uses the unreliable runtime environment path")
if ".launchEnvironment =" in ios_test.replace(ios_import, ""):
    raise SystemExit("A non-import release join test injects target-app environment")
for required in (
    "XCTAssertTrue(app.launchEnvironment.isEmpty)",
    'element("qr-scanner-camera").waitForExistence',
    'element("join-request-import-image")',
):
    if required not in ios_import:
        raise SystemExit(f"Exact QR image import test lacks launch contract: {required}")
if ios_import.index('element("qr-scanner-camera")') > ios_import.index(
    'element("join-request-import-image")'
):
    raise SystemExit("QR importer is queried before the shipped scanner exists")
for forbidden in ("app.launchArguments =", "app.activate()"):
    if forbidden in ios_import:
        raise SystemExit(f"Release join XCTest retains capability launch plumbing: {forbidden}")
for required in (
    "private static let maximumAttempts = 2",
    'field.value(forKey: "hasKeyboardFocus")',
    "field.typeKey(.delete",
    "if waitForValue(value, in: field)",
):
    if required not in ios_interaction:
        raise SystemExit(f"Release join XCTest lacks bounded verified text entry: {required}")
if "app.keyboards.firstMatch.waitForExistence" in ios_interaction:
    raise SystemExit("Release join XCTest still requires a software keyboard")
if ".coordinate(" in ios_interaction:
    raise SystemExit("Release join XCTest text entry uses coordinate tapping")
for required in (
    'app.navigationBars["VPN Data Use"].buttons["Continue"]',
    'springboard.alerts.buttons["Allow"]',
):
    if required not in ios_test:
        raise SystemExit(f"Release join XCTest does not clear permission UI: {required}")
prompt_handler = ios_test.split(
    "private func dismissSystemPromptsIfPresent() throws", 1
)[1].split("private func emit", 1)[0]
for required in (
    'springboard.staticTexts["Enter iPhone Passcode"].exists',
    'emit("NVPN_RELEASE_JOIN_VPN_APPROVAL_PASSCODE_REQUIRED=1")',
    "throw GateError.vpnApprovalPasscodeRequired",
    "springboard.state == .runningForeground",
    "app.state != .runningForeground",
    'emit("NVPN_RELEASE_JOIN_SYSTEM_UI_COVERING_APP=1")',
    "throw GateError.systemUICoveringApp",
    "springboardCoverSince == nil, let clearSince",
):
    if required not in prompt_handler:
        raise SystemExit(
            f"Release join XCTest can misclassify blocking Apple UI: {required}"
        )
if "allow.tap()" not in prompt_handler or "continue" not in prompt_handler:
    raise SystemExit("Release join XCTest reuses the disappearing Apple Allow hierarchy")
if ios_test.count("try dismissSystemPromptsIfPresent()") != 4:
    raise SystemExit("Release join XCTest does not propagate every system-prompt failure")
for required in (
    "ShippedUIInteraction.reveal(nameField, byTapping: create)",
    "let retained = ShippedUIInteraction.replaceText(field, with: value, in: app)",
    "if retained {",
    "field.typeKey(.return",
):
    if required not in ios_test:
        raise SystemExit(f"Release join XCTest bypasses verified interaction: {required}")
if 'element("join-request-qr")' in ios_test:
    raise SystemExit("Release join XCTest still targets the collapsed QR element")
qr_width_check = ios_test.split(
    "private func assertQrIsFullWidth", 1
)[1].split("private func openLinkDevice", 1)[0]
if 'element("join-request-qr-content")' in qr_width_check:
    raise SystemExit("Release join XCTest compares QR content width with itself")
for required in (
    'app.buttons["Copy Request"]',
    'app.buttons["Share"]',
    "copyRequest.waitForExistence",
    "share.waitForExistence",
    "min(copyRequest.frame.minX, share.frame.minX)",
    "max(copyRequest.frame.maxX, share.frame.maxX)",
    "let contentWidth = contentRight - contentLeft",
):
    if required not in qr_width_check:
        raise SystemExit(
            "Release join XCTest lacks a distinct shipped content boundary: "
            + required
        )
for required in (
    "app.launchArguments.isEmpty",
    "app.launchEnvironment.isEmpty",
    'app.buttons["manual-join-expand"]',
    'element("join-request-import-image")',
    "XCUIDevice.shared.press(.home)",
    "assertQrIsFullWidth(qr)",
    'element("join-request-qr-content")',
    "NVPN_RELEASE_JOIN_QR_CONTENT_WIDTH_BPS",
    "qrContentWidthMinimumBasisPoints",
    "qrContentWidthMaximumBasisPoints",
    "NVPN_RELEASE_JOIN_LIFECYCLE_READY=1",
    "NVPN_RELEASE_JOIN_QR_IMAGE_IMPORTED=1",
    "NVPN_RELEASE_JOIN_PENDING_QR_VISIBLE_MS",
    "waitForRosterBackedPendingQrDismissal",
    "NVPN_RELEASE_JOIN_QR_DISMISSED_WITH_ROSTER_MS",
    "Join QR disappeared before the exact admin roster was visible",
    "roster-participant-accepted-",
    "testImportJoinQrImageAndRequireAdminRosterProgress",
    "testShowPhysicalJoinQrAndRequireRosterCompletion",
    "testManualJoinAndRequireRosterCompletion",
    "testManualAdminAddRequiresRosterProgress",
    "requireAcceptedRoster",
    "app.terminate()",
    "NVPN_RELEASE_JOIN_RELAUNCH_DURABLE",
):
    if required not in ios_test:
        raise SystemExit(f"Release join XCTest is missing {required}")
for forbidden in ("rosterParticipantCount(", "allElementsBoundByIndex"):
    if forbidden in ios_test:
        raise SystemExit(
            "Release join XCTest still performs a redundant full roster traversal: "
            + forbidden
        )
if "NVPN_RELEASE_JOIN_ROSTER_APPLIED_MS" not in ios_test:
    raise SystemExit("Release join XCTest does not timestamp the first exact roster row")
if "UIPasteboard" in ios_test:
    raise SystemExit("Release QR XCTest may not inject a join request payload")
for required in (
    "XCUIScreen.main.screenshot().pngRepresentation",
    "SHA256.hash(data: png)",
    "nvpn-release-join-qr-",
):
    if required not in ios_test:
        raise SystemExit(f"Release QR XCTest lacks trusted screen capture: {required}")
for required in (
    'element("join-request-import-image")',
    'XCUIApplication(bundleIdentifier: "com.apple.DocumentsApp")',
    "selectImportedImage(named: imageFilename)",
):
    if required not in ios_test:
        raise SystemExit(f"Release QR XCTest lacks public image import: {required}")
for required in (
    "#if NVPN_RELEASE_JOIN_TESTING",
    "private let imageImportEnabled = true",
    "private let imageImportEnabled = false",
    "if imageImportEnabled",
    "join-request-import-image",
    "Import QR Image",
):
    if required not in ios_qr_scanner:
        raise SystemExit(f"iOS scanner does not gate QR image import: {required}")
if "NVPN_RELEASE_JOIN_QR_IMAGE_IMPORT" in ios_qr_scanner:
    raise SystemExit("iOS scanner retains unreliable environment transport")
camera = ios_qr_scanner.split("QRCodeScannerView(", 1)[1].split(
    "VStack(spacing: 10)", 1
)[0]
if '.accessibilityIdentifier("qr-scanner-camera")' not in camera:
    raise SystemExit("iOS scanner identifier is not scoped to the camera view")
container = ios_qr_scanner.split("VStack(spacing: 10)", 1)[1].split(
    ".fileImporter(", 1
)[0]
if '.accessibilityIdentifier("qr-scanner-camera")' in container:
    raise SystemExit("iOS scanner identifier leaks onto child controls")
for forbidden in (
    "QRImageImportTestMarker",
    "nvpn-release-join-qr-image-import",
    "appGroupDataContainer",
):
    if forbidden in ui or forbidden in ios_qr_scanner:
        raise SystemExit(f"iOS QR import retains marker transport: {forbidden}")
for required in (
    "allowImageImport: Boolean = false",
    "if (allowImageImport)",
    "join-request-import-image",
    "Import QR Image",
):
    if required not in android_qr_scanner:
        raise SystemExit(
            f"Android shipped scanner does not gate QR image import: {required}"
        )
if "waitForPendingQrDismissal" in ios_test:
    raise SystemExit(
        "Release QR XCTest still permits dismissal before the exact roster is visible"
    )
ios_roster_transition = ios_test.split(
    "private func waitForRosterBackedPendingQrDismissal", 1
)[1].split("private func allowCameraAccessIfNeeded", 1)[0]
for forbidden in (".waitForExistence", "waitUntil(", "openDevicesTab()"):
    if forbidden in ios_roster_transition:
        raise SystemExit(
            "Release QR XCTest waits for roster state after the QR disappeared"
        )
for required in (
    'let devicesTab = app.tabBars.buttons["Devices"]',
    "guard devicesTab.exists else {",
    "devicesTab.tap()",
    'guard element("roster-participant-accepted-\\(expectedParticipant)").exists else {',
    "NVPN_RELEASE_JOIN_QR_DISMISSED_WITH_ROSTER_MS",
):
    if required not in ios_roster_transition:
        raise SystemExit(
            "Release QR XCTest lacks an immediate roster-backed dismissal check: "
            + required
        )
if ios_roster_transition.index(
    'element("roster-participant-accepted-\\(expectedParticipant)").exists'
) > ios_roster_transition.index(
    "NVPN_RELEASE_JOIN_QR_DISMISSED_WITH_ROSTER_MS"
):
    raise SystemExit("Release QR XCTest records dismissal before checking the roster")

ios_qr_joiner = ios_test.split(
    "func testShowPhysicalJoinQrAndRequireRosterCompletion()", 1
)[1].split("func testImportJoinQrImageAndRequireAdminRosterProgress()", 1)[0]
for required in (
    "waitForRosterBackedPendingQrDismissal",
    "timeout: setupTimeout + deliveryTimeout",
    "requireAcceptedRoster(",
    "relaunch: true",
    "NVPN_RELEASE_JOIN_QR_RELAUNCH_DURABLE",
):
    if required not in ios_qr_joiner:
        raise SystemExit(
            f"iPhone QR joiner does not prove real relaunch durability: {required}"
        )
if ios_qr_joiner.index("requireAcceptedRoster(") < ios_qr_joiner.index(
    "waitForRosterBackedPendingQrDismissal"
):
    raise SystemExit("iPhone QR joiner relaunches before the signed roster applies")

android_scan_prepare = ui.split(
    "release_join_android_scan_prepare() {", 1
)[1].split("release_join_android_scan_submit() {", 1)[0]
for required in (
    'release_join_android_scroll_to description "Scan joining device QR"',
    'release_join_android_tap description "Scan joining device QR"',
    "release_join_android_accept_camera_permission",
    'release_join_android_wait_query resource "join-request-import-image"',
):
    if required not in android_scan_prepare:
        raise SystemExit(
            "Android scanner was not ready before the iPhone delivery clock: "
            + required
        )
android_scan_submit = ui.split(
    "release_join_android_scan_submit() {", 1
)[1].split("release_join_capture_android_qr() {", 1)[0]
if 'release_join_android_tap description "Scan joining device QR"' in android_scan_submit:
    raise SystemExit("Android scanner setup still consumes the iPhone delivery clock")

android_qr_lifecycle = ui.split(
    "release_join_android_background_foreground_pending_qr() {", 1
)[1].split("release_join_android_assert_qr_full_width() {", 1)[0]
for required in (
    'local expected_joiner="$RELEASE_JOIN_ANDROID_JOINER_ID"',
    "KEYCODE_HOME",
    "release_join_android_launch",
    "release_join_android_assert_pending_qr",
    "release_join_android_assert_qr_full_width",
    '[[ "$foreground_joiner" == "$expected_joiner" ]]',
    "RELEASE_JOIN_ANDROID_PENDING_QR_LIFECYCLE_READY=1",
):
    if required not in android_qr_lifecycle:
        raise SystemExit(
            "Pixel pending QR lifecycle does not prove the same public request "
            f"after foregrounding: {required}"
        )
if android_qr_lifecycle.index("KEYCODE_HOME") > android_qr_lifecycle.index(
    "release_join_android_assert_pending_qr"
):
    raise SystemExit("Pixel pending QR is checked before the real Home lifecycle")

for required in (
    "phase_ios_admin_android_qr",
    "phase_android_admin_ios_qr",
    "phase_ios_admin_android_manual",
    "phase_android_admin_ios_manual",
    "release_join_android_wait_qr_join_complete",
    "release_join_android_wait_join_complete",
    "release_join_android_relaunch_and_wait_accepted",
    "macos-vm-release-mobile-join-e2e.sh",
):
    if required not in gate:
        raise SystemExit(f"Release join orchestrator is missing {required}")
for required in (
    "productionImageImportQr",
    "actualRenderedQrScreenCapture",
    "exactRosterOnBothSides",
    '"androidJoinerRelaunchDurable": True',
    '"iphoneJoinerRelaunchDurable"',
):
    if required not in summary_builder:
        raise SystemExit(f"Release join summary is missing {required}")
android_qr_joiner_phase = gate.split(
    "phase_ios_admin_android_qr() {", 1
)[1].split("phase_android_admin_ios_qr() {", 1)[0]
for required in (
    "release_join_android_show_qr",
    "release_join_android_background_foreground_pending_qr",
    "release_join_capture_android_qr",
    "release_join_stage_ios_qr_image",
    "release_join_ios_start_test",
):
    if required not in android_qr_joiner_phase:
        raise SystemExit(
            f"Pixel QR joiner phase lacks real lifecycle sequencing: {required}"
        )
if not (
    android_qr_joiner_phase.index("release_join_android_show_qr")
    < android_qr_joiner_phase.index(
        "release_join_android_background_foreground_pending_qr"
    )
    < android_qr_joiner_phase.index("release_join_capture_android_qr")
    < android_qr_joiner_phase.index("release_join_stage_ios_qr_image")
    < android_qr_joiner_phase.index("release_join_ios_start_test")
):
    raise SystemExit(
        "Pixel pending QR lifecycle must finish before iPhone approval starts"
    )
for required in (
    "RELEASE_JOIN_ANDROID_PENDING_QR_LIFECYCLE_READY",
    "args.android_pending_qr_lifecycle_ready",
    '"pendingQrBackgroundForeground": True',
):
    if required not in join_receipt_code:
        raise SystemExit(
            f"Mobile receipt is not bound to the Pixel pending-QR lifecycle: {required}"
        )
ios_qr_joiner_phase = gate.split(
    "phase_android_admin_ios_qr() {", 1
)[1].split("phase_ios_admin_android_manual() {", 1)[0]
for required in (
    "NVPN_RELEASE_JOIN_QR_RELAUNCH_DURABLE",
    "ios_qr_relaunch_admin",
    '[[ "$ios_qr_relaunch_admin" == "$RELEASE_JOIN_ANDROID_ADMIN_ID" ]]',
    "RELEASE_JOIN_IOS_QR_RELAUNCH_DURABLE=1",
    "args.ios_qr_relaunch_durable",
):
    if required not in join_receipt_code:
        raise SystemExit(
            f"Mobile receipt does not validate iPhone QR relaunch proof: {required}"
        )
for required in (
    "release_join_ios_finish_test",
    "RELEASE_JOIN_IOS_SETUP_WAIT_SECS",
    "release_join_android_scan_prepare",
    "release_join_capture_ios_qr",
    "release_join_android_scan_submit",
    "android-admin-ios-qr-approval.log",
    "NVPN_RELEASE_JOIN_APPROVAL_SUBMITTED_MS=",
    "NVPN_RELEASE_JOIN_ROSTER_APPLIED_MS=",
    "assert_delivery_deadline",
    "NVPN_RELEASE_JOIN_QR_RELAUNCH_DURABLE",
    '[[ "$ios_qr_relaunch_admin" == "$RELEASE_JOIN_ANDROID_ADMIN_ID" ]]',
):
    if required not in ios_qr_joiner_phase:
        raise SystemExit(
            f"iPhone QR phase does not consume exact relaunch evidence: {required}"
        )
if ios_qr_joiner_phase.index(
    "NVPN_RELEASE_JOIN_QR_RELAUNCH_DURABLE"
) < ios_qr_joiner_phase.index("release_join_ios_finish_test"):
    raise SystemExit("iPhone QR relaunch evidence is read before XCTest completes")
if ios_qr_joiner_phase.count("RELEASE_JOIN_IOS_SETUP_WAIT_SECS") != 2:
    raise SystemExit("iPhone QR readiness does not use the setup budget")
if "release_join_android_scan_and_accept" in ios_qr_joiner_phase:
    raise SystemExit("iPhone QR delivery still includes Android scanner setup")
if not (
    ios_qr_joiner_phase.index("release_join_android_scan_prepare")
    < ios_qr_joiner_phase.index("release_join_ios_start_test")
    < ios_qr_joiner_phase.index("NVPN_RELEASE_JOIN_LIFECYCLE_READY=1")
    < ios_qr_joiner_phase.index("release_join_capture_ios_qr")
    < ios_qr_joiner_phase.index("release_join_android_scan_submit")
    < ios_qr_joiner_phase.index("NVPN_RELEASE_JOIN_ROSTER_APPLIED_MS=")
    < ios_qr_joiner_phase.index("assert_delivery_deadline")
    < ios_qr_joiner_phase.index("release_join_ios_finish_test")
):
    raise SystemExit(
        "Pixel scanner setup must precede iPhone QR readiness and approval timing"
    )
for required in (
    "Join approval or signed-roster delivery timed out while the QR remained visible",
    "Join QR disappeared before the exact admin roster was visible",
):
    if required not in ios_test:
        raise SystemExit(f"iPhone QR failure diagnostics are missing: {required}")

ios_admin_android_manual_phase = gate.split(
    "phase_ios_admin_android_manual() {", 1
)[1].split("phase_android_admin_ios_manual() {", 1)[0]
for required in (
    "NVPN_RELEASE_JOIN_ADMIN_RELAUNCH_DURABLE",
    '[[ "$ios_admin_relaunch_joiner" == "$RELEASE_JOIN_ANDROID_JOINER_ID" ]]',
    "RELEASE_JOIN_IOS_ADMIN_MANUAL_RELAUNCH_DURABLE=1",
):
    if required not in ios_admin_android_manual_phase:
        raise SystemExit(
            f"iPhone-admin manual phase does not consume exact relaunch proof: {required}"
        )
if ios_admin_android_manual_phase.index(
    "NVPN_RELEASE_JOIN_ADMIN_RELAUNCH_DURABLE"
) < ios_admin_android_manual_phase.index("release_join_ios_finish_test"):
    raise SystemExit("iPhone-admin relaunch evidence is read before XCTest completes")
for required in (
    "release_join_ios_start_test",
    "NVPN_RELEASE_JOIN_APPROVAL_SUBMITTED_MS=",
    "RELEASE_JOIN_IOS_SETUP_WAIT_SECS",
    "release_join_android_wait_join_complete",
    "assert_delivery_deadline",
    "release_join_android_relaunch_and_wait_accepted",
    "release_join_ios_finish_test",
):
    if required not in ios_admin_android_manual_phase:
        raise SystemExit(
            f"iPhone-admin manual phase does not measure concurrent delivery: {required}"
        )
if "RELEASE_JOIN_UI_WAIT_SECS" in ios_admin_android_manual_phase:
    raise SystemExit("iPhone-admin setup incorrectly consumes the delivery/UI budget")
if not (
    ios_admin_android_manual_phase.index("release_join_ios_start_test")
    < ios_admin_android_manual_phase.index("NVPN_RELEASE_JOIN_APPROVAL_SUBMITTED_MS=")
    < ios_admin_android_manual_phase.index("release_join_android_wait_join_complete")
    < ios_admin_android_manual_phase.index("assert_delivery_deadline")
    < ios_admin_android_manual_phase.index("release_join_android_relaunch_and_wait_accepted")
    < ios_admin_android_manual_phase.index("release_join_ios_finish_test")
):
    raise SystemExit(
        "iPhone-admin delivery timing is serialized behind the iOS relaunch proof"
    )

android_admin_ios_manual_phase = gate.split(
    "phase_android_admin_ios_manual() {", 1
)[1].split("release_join_require_clean_fips", 1)[0]
for required in (
    "RELEASE_JOIN_IOS_SETUP_WAIT_SECS",
    "release_join_android_manual_admin_prepare",
    "release_join_android_manual_admin_tap",
    "android-admin-ios-manual-approval.log",
    "NVPN_RELEASE_JOIN_ROSTER_APPLIED_MS=",
    "assert_delivery_deadline",
    "NVPN_RELEASE_JOIN_RELAUNCH_DURABLE",
    '[[ "$ios_joiner_relaunch_admin" == "$RELEASE_JOIN_ANDROID_ADMIN_ID" ]]',
    "RELEASE_JOIN_IOS_JOINER_MANUAL_RELAUNCH_DURABLE=1",
):
    if required not in android_admin_ios_manual_phase:
        raise SystemExit(
            f"iPhone-joiner manual phase does not consume exact relaunch proof: {required}"
        )
if android_admin_ios_manual_phase.index(
    "NVPN_RELEASE_JOIN_RELAUNCH_DURABLE"
) < android_admin_ios_manual_phase.index("release_join_ios_finish_test"):
    raise SystemExit("iPhone-joiner relaunch evidence is read before XCTest completes")
if android_admin_ios_manual_phase.count("RELEASE_JOIN_IOS_SETUP_WAIT_SECS") != 2 \
        or "RELEASE_JOIN_UI_WAIT_SECS" in android_admin_ios_manual_phase:
    raise SystemExit("iPhone manual-join setup does not use only the setup budget")
if 'android_admin_log="$RESULT_DIR/android-admin-ios-manual.log"' \
        in android_admin_ios_manual_phase:
    raise SystemExit("Android approval and iPhone XCTest still share one log path")
if not (
    android_admin_ios_manual_phase.index("release_join_ios_start_test")
    < android_admin_ios_manual_phase.index("NVPN_RELEASE_JOIN_JOINER_ID=")
    < android_admin_ios_manual_phase.index("release_join_android_manual_admin_prepare")
    < android_admin_ios_manual_phase.index("NVPN_RELEASE_JOIN_MANUAL_SUBMITTED=1")
    < android_admin_ios_manual_phase.index("release_join_android_manual_admin_tap")
    < android_admin_ios_manual_phase.index("NVPN_RELEASE_JOIN_ROSTER_APPLIED_MS=")
    < android_admin_ios_manual_phase.index("assert_delivery_deadline")
    < android_admin_ios_manual_phase.index("release_join_ios_finish_test")
):
    raise SystemExit(
        "Pixel-admin/iPhone manual timing does not overlap setup and measure first delivery"
    )
for required in (
    "initialTimeout: setupTimeout",
    'boundedTimeout("NVPN_RELEASE_JOIN_SETUP_WAIT_SECS", maximum: 45)',
):
    if required not in ios_test:
        raise SystemExit(
            f"iPhone manual join does not isolate setup from delivery timing: {required}"
        )
manual_join_test = ios_test.split(
    "func testManualJoinAndRequireRosterCompletion() throws", 1
)[1].split("func testManualAdminAddRequiresRosterProgress() throws", 1)[0]
if not (
    manual_join_test.index("NVPN_RELEASE_JOIN_MANUAL_SUBMITTED=1")
    < manual_join_test.index("requireAcceptedRoster(")
    < manual_join_test.index("initialTimeout: setupTimeout")
):
    raise SystemExit(
        "iPhone manual join does not use the setup budget for initial roster delivery"
    )
accepted_roster = ios_test.split(
    "private func requireAcceptedRoster", 1
)[1].split("private func selectImportedImage", 1)[0]
for required in (
    "initialTimeout ?? deliveryTimeout",
    "guard relaunch else",
    "waitForExistence(timeout: deliveryTimeout)",
):
    if required not in accepted_roster:
        raise SystemExit(f"iPhone roster wait lost its bounded timeout split: {required}")
if "host-ack" in ios_test or "admin_approval" in ui:
    raise SystemExit("iPhone manual join retains a redundant host acknowledgement channel")
for required in (
    "args.ios_admin_manual_relaunch_durable",
    "args.ios_joiner_manual_relaunch_durable",
    '"iphoneAdminPixelJoinerRelaunchDurable": True',
    '"pixelAdminIphoneJoinerRelaunchDurable": True',
):
    if required not in join_receipt_code:
        raise SystemExit(
            f"Mobile receipt is not bound to directional manual relaunch proof: {required}"
        )

macos_iphone_joiner_phase = desktop.split(
    "# macOS admin -> physical iPhone joiner.", 1
)[1].split("# Physical iPhone admin -> macOS joiner.", 1)[0]
for required in (
    "NVPN_RELEASE_JOIN_RELAUNCH_DURABLE",
    "RELEASE_JOIN_IOS_SETUP_WAIT_SECS",
    "NVPN_RELEASE_JOIN_ROSTER_APPLIED_MS",
    "assert_delivery_deadline",
    '[[ "$iphone_joiner_relaunch_admin" == "$DESKTOP_IOS_ADMIN_ID" ]]',
):
    if required not in macos_iphone_joiner_phase:
        raise SystemExit(
            f"macOS/iPhone gate does not consume iPhone-joiner relaunch proof: {required}"
        )
if macos_iphone_joiner_phase.count("RELEASE_JOIN_IOS_SETUP_WAIT_SECS") != 2:
    raise SystemExit("macOS/iPhone manual-join setup does not use the setup budget")
if not (
    macos_iphone_joiner_phase.index("NVPN_RELEASE_JOIN_APPROVAL_SUBMITTED_MS")
    < macos_iphone_joiner_phase.index("NVPN_RELEASE_JOIN_ROSTER_APPLIED_MS")
    < macos_iphone_joiner_phase.index("assert_delivery_deadline")
    < macos_iphone_joiner_phase.index("release_join_ios_finish_test")
):
    raise SystemExit("macOS/iPhone delivery is not measured before relaunch durability")

ios_manual_admin = ios_test.split(
    "func testManualAdminAddRequiresRosterProgress()", 1
)[1].split("func testReportJoinerPublicIdentity()", 1)[0]
for required in (
    "requireAcceptedRoster(",
    "relaunch: true",
    "NVPN_RELEASE_JOIN_ADMIN_RELAUNCH_DURABLE",
):
    if required not in ios_manual_admin:
        raise SystemExit(
            f"iPhone admin does not prove roster durability after relaunch: {required}"
        )

macos_iphone_admin_phase = desktop.split(
    "# Physical iPhone admin -> macOS joiner.", 1
)[1].split("python3 -", 1)[0]
for required in (
    "NVPN_RELEASE_JOIN_ADMIN_RELAUNCH_DURABLE",
    "NVPN_RELEASE_JOIN_MANUAL_COMPLETE_MS",
    "NVPN_RELEASE_JOIN_ROSTER_APPLIED_MS",
    "macOS joiner completed before the iPhone approval",
    "ios_admin_remote_elapsed_ms",
    "ios_admin_phone_elapsed_ms",
    "assert_delivery_duration",
    '[[ "$ios_admin_relaunch_joiner" == "$DESKTOP_IOS_JOINER_ID" ]]',
):
    if required not in macos_iphone_admin_phase:
        raise SystemExit(
            f"macOS/iPhone gate does not consume iPhone-admin relaunch proof: {required}"
        )
if not (
    macos_iphone_admin_phase.index("macOS joiner completed before the iPhone approval")
    < macos_iphone_admin_phase.index("testManualAdminAddRequiresRosterProgress")
    < macos_iphone_admin_phase.index("NVPN_RELEASE_JOIN_APPROVAL_SUBMITTED_MS")
    < macos_iphone_admin_phase.rindex("NVPN_RELEASE_JOIN_MANUAL_COMPLETE_MS")
    < macos_iphone_admin_phase.index("NVPN_RELEASE_JOIN_ROSTER_APPLIED_MS")
    < macos_iphone_admin_phase.index("assert_delivery_duration")
    < macos_iphone_admin_phase.index("finish_remote")
):
    raise SystemExit("iPhone/macOS delivery is not measured before durability checks")
android_clear = artifacts.split(
    "release_join_reset_android_state()", 1
)[1].split("release_join_prepare_android_release()", 1)[0]
if "NVPN_RELEASE_JOIN_ALLOW_ANDROID_DATA_CLEAR" not in android_clear:
    raise SystemExit("Android app-data clearing lacks an explicit destructive opt-in")
if "NVPN_RELEASE_JOIN_ALLOW_DEVICE_RESET" in artifacts:
    raise SystemExit("Ambiguous cross-platform device-reset flag remains")

macos_pixel_admin_phase = desktop.split(
    "# Physical Android admin -> macOS joiner.", 1
)[1].split("python3 -", 1)[0]
for required in (
    'release_join_android_relaunch_and_wait_accepted "$DESKTOP_JOINER_ID"',
    "MACOS_MOBILE_DIRECTION_LABEL=pixel-admin-macos-joiner",
    "android_admin_macos_status=$?",
):
    if required not in macos_pixel_admin_phase:
        raise SystemExit(
            "macOS/Pixel join gate claims Pixel relaunch durability without "
            f"the Android-admin direction check: {required}"
        )
for required in (
    "MACOS_MOBILE_DIRECTION_LABEL=macos-admin-pixel-joiner",
    "macos_admin_android_status=$?",
    "android_admin_macos_status != 0",
    "macos_admin_ios_status != 0",
    "ios_admin_macos_status != 0",
):
    if required not in desktop:
        raise SystemExit(f"macOS/Pixel isolated direction gate is missing {required}")
for source, label, required_tokens in (
    (
        ios_frozen_gate,
        "frozen iOS gate",
        (
            'artifact.get("android")',
            'android.get("artifactReceiptSha256")',
            'android.get("installReceiptSha256"',
            'android.get("installReceiptSize")',
        ),
    ),
    (
        release_provenance,
        "release provenance",
        (
            "receipt.artifact?.android",
            "android?.artifactReceiptSha256",
            "android?.installReceiptSha256",
            "android?.installReceiptSize",
        ),
    ),
):
    for required in required_tokens:
        if required not in source:
            raise SystemExit(
                f"{label} does not validate macOS/Pixel Android binding: {required}"
            )

for required in (
    "-configuration Release",
    "build-for-testing",
    "'OTHER_SWIFT_FLAGS=$(inherited) -DNVPN_RELEASE_JOIN_TESTING'",
    "NVPN_IOS_PROFILE_TYPE=IOS_APP_ADHOC",
    "Apple Distribution",
    "codesign --verify --deep --strict",
    "bundleManifestSha256",
    "installedApkSha256",
    "signerCertificateSha256",
    "replacementInstall",
    "debuggable",
    "RELEASE_JOIN_FIPS_SHA",
    "release_join_assert_fips_unchanged",
    "release_join_assert_app_unchanged",
    "NVPN_EXPECTED_IOS_DISTRIBUTION_TEAM_ID",
    "NVPN_EXPECTED_IOS_DISTRIBUTION_CERT_SHA256",
    "appAndPacketTunnelSignerMatch",
    "release_join_record_selected_devices",
    "expectedDeviceNameMatched",
    "replacementInstallVerified",
    "release_join_launch_ios_release",
    "install -r",
):
    if required not in artifacts:
        raise SystemExit(f"Exact Release artifact gate is missing {required}")
if "app-debug.apk" in artifacts or "DeviceDebug" in artifacts:
    raise SystemExit("Exact Release artifact gate still permits a debug build")
if '"$apk_sha" == "$installed_sha"' not in artifacts:
    raise SystemExit("Android Release artifact is not byte-compared after install")
if "NVPN_EXPECTED_IOS_DEVICE_NAME" not in gate:
    raise SystemExit("Release join gate may auto-select the wrong paired iPhone")
if "NVPN_EXPECTED_ANDROID_DEVICE_MODEL" not in gate:
    raise SystemExit("Release join gate may select the wrong Android phone")
if "NVPN_EXPECTED_APP_GIT_SHA" not in gate:
    raise SystemExit("Release join gate does not pin the exact app candidate")
if "an exact NVPN_EXPECTED_FIPS_GIT_SHA" not in artifacts:
    raise SystemExit("Release join gate does not pin the exact FIPS candidate")

for required in (
    "join-request-import-image",
    "release_join_capture_android_qr",
    "release_join_capture_ios_qr",
    "release_join_stage_ios_qr_image",
    "Confirm adding scanned join request",
    "NVPN_RELEASE_JOIN_APPROVAL_SUBMITTED_MS",
    "KEYCODE_HOME",
    "Join request QR code",
    "release_join_android_assert_qr_full_width",
    "RELEASE_JOIN_QR_CONTENT_WIDTH_MIN_BPS",
    "RELEASE_JOIN_QR_CONTENT_WIDTH_MAX_BPS",
    'resource "join-request-qr-content" width',
    "RELEASE_JOIN_ANDROID_QR_CONTENT_WIDTH_BPS",
    "release_join_android_assert_pending_qr",
    "release_join_require_fresh_ios_pending_qr",
    "roster-participant-accepted-$admin",
    "roster-participant-accepted-$joiner",
    "release_join_android_wait_accepted_participant",
    "release_join_android_query resource manual-join-submit center",
    "Android manual join submit did not change the shipped UI",
    "safe-center",
    "NVPN_RELEASE_JOIN_APPROVAL_SUBMITTED_MS",
    "test-without-building",
):
    if required not in ui:
        raise SystemExit(f"Public UI driver is missing {required}")
if "physical_width * 75" in ui or "appWidth * 0.75" in ios_test:
    raise SystemExit("Mobile full-width QR gate still accepts a 75% screen-width QR")
for source, label in (
    (android_devices, "Android"),
    (ios_devices, "iOS"),
):
    if "join-request-qr-content" not in source:
        raise SystemExit(f"{label} shipped join UI lacks a content-width selector")
for required in (
    '"contentWidth": {',
    "minimum_width = 9_800",
    "maximum_width = 10_000",
    '"minimumRequiredBasisPoints": minimum_width',
    '"maximumAllowedBasisPoints": maximum_width',
    '"androidObservedBasisPoints"',
    '"iosObservedBasisPoints"',
):
    if required not in summary_builder:
        raise SystemExit(f"Mobile join receipt lacks QR width evidence: {required}")
for source, label in (
    (ios_frozen_gate, "frozen iOS gate"),
    (release_provenance, "release provenance"),
):
    for required in (
        "minimumRequiredBasisPoints",
        "maximumAllowedBasisPoints",
        "androidObservedBasisPoints",
        "iosObservedBasisPoints",
        "androidJoinerRelaunchDurable",
        "iphoneJoinerRelaunchDurable",
        "iphoneAdminPixelJoinerRelaunchDurable",
        "pixelAdminIphoneJoinerRelaunchDurable",
    ):
        if required not in source:
            raise SystemExit(
                f"{label} does not validate mobile join evidence: {required}"
            )

for selector in (
    "network-setup-create",
    "network-create-name",
    "network-create-submit",
    "joiner-device-id-value",
    "admin-device-id-value",
    "admin-network-id-value",
):
    if selector not in android_devices:
        raise SystemExit(f"Android shipped UI lacks {selector}")
    if selector not in ios_devices and selector != "network-setup-create":
        raise SystemExit(f"iOS shipped UI lacks {selector}")
    if selector not in macos_devices:
        raise SystemExit(f"macOS shipped UI lacks {selector}")
for source, label, interpolation, accepted_flag in (
    (android_components, "Android", "${participant.npub}", "participant.rosterAccepted"),
    (ios_participants, "iOS", "\\(participant.npub)", "participant.rosterAccepted"),
    (macos_devices, "macOS", "\\(participant.npub)", "participant.rosterAccepted"),
):
    if "roster-participant-" not in source or interpolation not in source:
        raise SystemExit(f"{label} Release UI lacks exact roster participant identity")
    if accepted_flag not in source:
        raise SystemExit(f"{label} Release UI does not distinguish pending from accepted rows")
    if "accepted" not in source or "pending" not in source:
        raise SystemExit(f"{label} Release UI lacks explicit accepted/pending selectors")

if "network_has_confirmed_local_identity(&network.id)" not in runtime_network:
    raise SystemExit(
        "Native UI state does not keep a manual admin pending until a signed roster applies"
    )
for source, required, label in (
    (
        config_types,
        "pub local_identity_confirmation_pending: bool",
        "persisted manual-join confirmation state",
    ),
    (
        config_networks,
        "network.local_identity_confirmation_pending = true",
        "manual-join pending transition",
    ),
    (
        config_rosters,
        "if network.local_identity_confirmation_pending",
        "pending-first confirmation predicate",
    ),
    (
        config_rosters,
        "network.local_identity_confirmation_pending = false",
        "explicit membership confirmation transition",
    ),
    (
        join_requests,
        "&& network.local_identity_confirmation_pending",
        "receipt lookup for a still-pending manual join",
    ),
):
    if required not in source:
        raise SystemExit(f"Release join core lacks {label}")
for required in (
    "manual_join_stays_pending_until_a_signed_roster_contains_this_device",
    "apply_verified_admin_signed_shared_roster(&roster_without_joiner)",
    "!reloaded.active_network_has_confirmed_local_identity()",
    "apply_manual_join_roster(&accepted",
    "reload accepted manual join",
):
    if required not in roster_apply_tests:
        raise SystemExit(f"Manual signed-membership regression is missing {required}")
for required in (
    "an out-of-band admin row must remain pending until its signed roster arrives",
    'pending_admin.state, "pending"',
    'assert_eq!(pending_admin.status_text, "waiting for admin")',
):
    if required not in runtime_network_tests:
        raise SystemExit(f"Manual pending-row regression is missing {required}")

for variable in (
    "NVPN_RELEASE_JOIN_BLACKBOX",
    "NVPN_RELEASE_JOIN_ADMIN_ID",
    "NVPN_RELEASE_JOIN_NETWORK_ID",
    "NVPN_RELEASE_JOIN_JOINER_ID",
):
    if f'{variable}: "$({variable})"' not in ios_project:
        raise SystemExit(f"XCTest runner setting is not bridged: {variable}")
for obsolete in (
    "NVPN_XCUITEST_PHYSICAL_JOIN_GATE",
    "NVPN_XCUITEST_MANUAL_ADMIN_DEVICE_ID",
    "NVPN_XCUITEST_MANUAL_NETWORK_ID",
    "NVPN_XCUITEST_MANUAL_JOINER_DEVICE_ID",
):
    if obsolete in ios_project:
        raise SystemExit(f"XCTest runner retains obsolete debug join setting: {obsolete}")

for required in (
    "release-create-admin",
    "release-manual-join",
    "release-admin-add",
    "release-verify",
):
    if required not in desktop_remote and required not in desktop:
        raise SystemExit(f"Desktop/mobile Release driver is missing {required}")
if "roster-participant-accepted-" not in desktop_ui_driver:
    raise SystemExit(
        "Desktop/mobile Release UI driver does not require an accepted roster row"
    )
if desktop_remote.count('NVPN_APP_DATA_DIR="$TEST_CONFIG_DIR"') != 1:
    raise SystemExit("Desktop Release app does not use its canonical isolated profile")
if desktop_remote.count("NVPN_APP_DATA_DIR=") != 1 or 'NVPN_CLI_PATH=' in desktop_remote:
    raise SystemExit("Desktop Release app is launched with an unsupported injected shortcut")
if '"$APP_EXE"' not in desktop_remote:
    raise SystemExit("Desktop gate does not launch the exact signed Release executable")
for source, required in (
    (desktop_remote, ("service_preflight", "assert_join_listener_ready", "swap_test_profile", "restore_config_dir", "require_delivery_log", 'normalize-npub "$1"')),
    (desktop, ("remote service-preflight", "remote require-delivery-log", "desktop-add-android-daemon.log", "desktop-add-iphone-daemon.log")),
    (desktop_ui_driver, ("requireSuccessfulCompletion", "Action failed", "visibleElements(application)")),
    (desktop_join_fixture, ("normalize-npub", "normalize_nostr_pubkey(&value)")),
):
    if any(value not in source for value in required):
        raise SystemExit("macOS/mobile join service, delivery, or UI evidence regressed")
if "PROFILE_STATE_NAMES" in desktop_remote:
    raise SystemExit("macOS profile isolation still enumerates known files")
completion_poll = desktop_ui_driver.split("func requireSuccessfulCompletion", 1)[1].split(
    "func press", 1
)[0]
if completion_poll.count("visibleElements(application)") != 2:
    raise SystemExit("macOS completion polling does not use one AX snapshot per iteration")
for required in (
    "exec /usr/bin/env -i",
    "NVPN_EXPECTED_MACOS_SIGNING_IDENTITY_SHA1",
    "NVPN_EXPECTED_MACOS_SIGNING_TEAM_ID",
    "NVPN_EXPECTED_MACOS_SIGNER_CERT_SHA256",
    "expected-identity-sha1",
    "appSourceManifestSha256",
    "fipsSourceManifestSha256",
    "signingIdentitySha1",
    "signerCertificateSha256",
):
    if (
        required not in desktop_remote
        and required not in desktop
        and required not in desktop_artifact
    ):
        raise SystemExit(f"Desktop Release provenance gate is missing {required}")
for required in (
    'git -C "$ROOT" archive --format=tar "$APP_GIT_SHA"',
    '"$HOST_BUILD_ROOT/scripts/macos-build" macos-app',
    '"$HOST_BUILD_ROOT/scripts/macos-build" macos-gate-support',
    "validate-published-app",
    "--require-gate-bundle-tree",
    "proveUnchangedPlatformInputs",
    "component-proof.json",
    "PRODUCT_GIT_SHA",
    'expected-harness-head "$APP_GIT_SHA"',
    "desktop_manual_join_e2e_fixture",
    "desktop-manual-join-ax",
    "macos-service-toggle-ax",
    "ditto -c -k --sequesterRsrc --keepParent",
    "macos_release_join_artifact.py\" create",
    "scp -q",
):
    if required not in desktop:
        raise SystemExit(f"Host-built macOS artifact path is missing {required}")
for required in (
    "release_join_restart_ios_in_place",
    "release_join_reuse_artifacts",
    "testManualJoinAndRequireRosterCompletion",
    "testManualAdminAddRequiresRosterProgress",
    "macOS-admin-to-iPhone-manual",
    "iPhone-admin-to-macOS-manual",
    "desktopAdminIphoneJoiner",
    "iphoneAdminDesktopJoiner",
    "desktopAdminIphoneJoinerRelaunchDurable",
    "iphoneAdminDesktopJoinerRelaunchDurable",
    "NVPN_RELEASE_JOIN_IOS_RECEIPT",
    "release_join_validate_reused_artifacts",
):
    if required not in desktop:
        raise SystemExit(
            f"macOS/iPhone frozen Release join gate is missing {required}"
        )
desktop_reuse_required = desktop.index("release_join_reuse_artifacts")
desktop_validation = desktop.index("release_join_validate_reused_artifacts")
desktop_arm = desktop.index(
    "RELEASE_JOIN_DEVICE_MUTATION_ALLOWED=1", desktop_validation
)
desktop_first_reset = min(
    desktop.index("release_join_reset_android_state", desktop_arm),
    desktop.index("release_join_restart_ios_in_place", desktop_arm),
)
if not desktop_reuse_required < desktop_validation < desktop_arm < desktop_first_reset:
    raise SystemExit(
        "macOS/mobile join does not validate exact artifacts before arming mutation"
    )
if "RELEASE_JOIN_ARTIFACTS_VALIDATED=1" in desktop:
    raise SystemExit("macOS/mobile join bypasses exact artifact validation")
for source, label in (
    (ios_frozen_gate, "frozen iOS gate"),
    (release_provenance, "release provenance"),
):
    for required in (
        "desktopAdminIphoneJoiner",
        "iphoneAdminDesktopJoiner",
        "desktopAdminIphoneJoinerRelaunchDurable",
        "iphoneAdminDesktopJoinerRelaunchDurable",
        "macOS-admin-to-iPhone-manual",
        "iPhone-admin-to-macOS-manual",
    ):
        if required not in source:
            raise SystemExit(
                f"{label} does not validate macOS/iPhone join evidence: {required}"
            )
if "desktop_mobile_join" not in local_release:
    raise SystemExit(
        "Local release platform evidence does not include the iPhone/macOS receipt"
    )
for source, label in (
    (desktop, "macOS/iPhone receipt producer"),
    (ios_frozen_gate, "frozen iOS gate"),
    (release_provenance, "release provenance"),
):
    if "iphoneRelaunchDurability" in source:
        raise SystemExit(f"{label} retains ambiguous iPhone relaunch semantics")
for required in (
    "ditto -x -k",
    "macos_release_join_artifact.py\" validate",
    "verify-import",
    "verification.json",
):
    if required not in desktop_remote:
        raise SystemExit(f"VM macOS artifact import path is missing {required}")
for forbidden in ("macos-build", "xcodebuild", "cargo build"):
    if forbidden in desktop_remote:
        raise SystemExit(f"macOS VM still builds the Release app through {forbidden}")
if "security find-certificate" in desktop or "security find-certificate" in desktop_remote:
    raise SystemExit("macOS Release gate may not select an ambiguous certificate by name")
if '"find-certificate", "-c"' in desktop_artifact:
    raise SystemExit("macOS Release artifact helper may not select a certificate by name")
for required in (
    '"security", "find-certificate", "-a", "-p"',
    'verify = ["codesign", "--verify"]',
    'verify.append("--deep")',
    '"--extract-certificates=',
    "tree_sha256(app)",
    "tree_sha256(package)",
    "manualJoinFixtureSha256",
    "manualJoinDriverSha256",
    "serviceToggleDriverSha256",
    "componentInputProofSha256",
    '"builtOnHost": True',
    '"builtOnTestVm": False',
    '"remoteImportVerified": True',
):
    if required not in desktop_artifact:
        raise SystemExit(f"macOS immutable artifact verifier is missing {required}")

main = release_gate.split("main() {", 1)[1]
if "./scripts/mobile-release-join-e2e.sh" not in release_gate:
    raise SystemExit("Release gate does not invoke the signed Release join lane")
if 'NVPN_RELEASE_GATE_MOBILE_JOIN_E2E:-required' not in release_gate:
    raise SystemExit("Signed Release join lane is not required by default")
if "run_mobile_join_e2e_gate" not in main:
    raise SystemExit("Release main does not join the signed Release join lane")
if "run_desktop_mobile_manual_join_e2e_gate" in main:
    raise SystemExit("Release main still counts the private-state desktop/mobile gate")
if "xcrun xctrace list devices" in release_gate:
    raise SystemExit("Release iPhone preflight still trusts stale xctrace availability")
if "devicectl device info details" not in release_gate or "xcrun xcdevice list" not in release_gate:
    raise SystemExit("Release iPhone preflight does not use CoreDevice/xcdevice")
PY

(
  profile_tmp="$(mktemp -d "${TMPDIR:-/tmp}/nvpn-macos-profile-swap.XXXXXX")"
  trap 'find "$profile_tmp" -depth -delete' EXIT
  functions_file="$profile_tmp/functions.sh"
  sed -n '/^swap_test_profile() {/,/^}$/p; /^restore_config_dir() {/,/^}$/p' \
    "$ROOT/scripts/macos-release-mobile-join-remote.sh" >"$functions_file"
  # shellcheck disable=SC1090
  source "$functions_file"
  CONFIG_DIR="$profile_tmp/Application Support/nvpn"
  PROFILE_STATE_DIR="$profile_tmp/profile-transaction"
  CONFIG_BACKUP="$PROFILE_STATE_DIR/prior"
  TEST_CONFIG_DIR="$PROFILE_STATE_DIR/test"
  TEST_PROFILE_MARKER="$PROFILE_STATE_DIR/state"
  mkdir -p "$CONFIG_DIR/unknown/nested"
  printf 'preserve-me\n' >"$CONFIG_DIR/unknown/nested/sentinel"
  swap_test_profile
  [[ -L "$CONFIG_DIR" && "$(readlink "$CONFIG_DIR")" == "$TEST_CONFIG_DIR" ]]
  printf 'test-only\n' >"$TEST_CONFIG_DIR/test-only"
  chmod 000 "$TEST_CONFIG_DIR/test-only"
  restore_config_dir
  grep -Fxq preserve-me "$CONFIG_DIR/unknown/nested/sentinel"
  [[ ! -L "$CONFIG_DIR" && ! -e "$TEST_CONFIG_DIR" && ! -e "$CONFIG_BACKUP" ]]
) || {
  echo "macOS canonical profile swap did not preserve unknown nested state" >&2
  exit 1
}

(
  source "$ROOT/scripts/lib-mobile-release-join-ui.sh"
  fake_qr_width=300
  fake_content_width=400

  release_join_android_dump_ui() { :; }
  release_join_android_query_dumped() {
    local kind="$1" expected="$2" output="$3"
    [[ "$output" == width ]] || return 1
    if [[ "$kind" == description && "$expected" == "Join request QR code" ]]; then
      printf '%s\n' "$fake_qr_width"
      return
    fi
    if [[ "$kind" == resource && "$expected" == join-request-qr-content ]]; then
      printf '%s\n' "$fake_content_width"
      return
    fi
    return 1
  }

  if release_join_android_assert_qr_full_width 2>/dev/null; then
    echo "Android full-width gate accepted a 75% content-width QR" >&2
    exit 1
  fi
  fake_qr_width=396
  release_join_android_assert_qr_full_width || {
    echo "Android full-width gate rejected a 99% content-width QR" >&2
    exit 1
  }
  [[ "$RELEASE_JOIN_ANDROID_QR_CONTENT_WIDTH_BPS" == 9900 ]] || {
    echo "Android full-width gate did not record the observed content ratio" >&2
    exit 1
  }
  fake_qr_width=404
  if release_join_android_assert_qr_full_width 2>/dev/null; then
    echo "Android full-width gate accepted a QR wider than its content" >&2
    exit 1
  fi
)

(
  source "$ROOT/scripts/lib-mobile-release-join-ui.sh"
  RELEASE_JOIN_DELIVERY_WAIT_SECS=2
  RELEASE_JOIN_ANDROID_JOINER_ID=npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq
  roster_queries=0

  release_join_android_launch() { :; }
  release_join_android_dump_ui() { :; }
  release_join_android_query_dumped() {
    local kind="$1" expected="$2"
    if [[ "$kind" == resource && "$expected" == navigation-devices ]]; then
      return 0
    fi
    if [[ "$kind" == resource \
      && "$expected" == roster-participant-accepted-npub1admin ]]
    then
      roster_queries=$((roster_queries + 1))
      ((roster_queries >= 2))
      return
    fi
    return 1
  }

  declare -F release_join_android_wait_qr_join_complete >/dev/null \
    || {
      echo "Android Release join UI lacks the roster-backed QR completion waiter" >&2
      exit 1
    }
  if release_join_android_wait_qr_join_complete npub1admin 2>/dev/null; then
    echo "Android QR join accepted a roster that appeared after premature dismissal" >&2
    exit 1
  fi
  [[ "$roster_queries" == 1 ]] || {
    echo "Android QR join kept polling after the QR disappeared without its roster" >&2
    exit 1
  }
)

(
  source "$ROOT/scripts/lib-mobile-release-join-ui.sh"
  RELEASE_JOIN_DELIVERY_WAIT_SECS=2
  RELEASE_JOIN_ANDROID_JOINER_ID=npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq
  snapshot=0

  release_join_android_launch() { :; }
  release_join_android_dump_ui() {
    snapshot=$((snapshot + 1))
  }
  release_join_android_query_dumped() {
    local kind="$1" expected="$2" output="$3"
    if ((snapshot == 1)); then
      if [[ "$kind" == description && "$expected" == "Join request QR code" ]]; then
        return 0
      fi
      if [[ "$kind" == resource \
        && "$expected" == joiner-device-id-value \
        && "$output" == description ]]
      then
        printf 'Joiner Device ID value: %s\n' "$RELEASE_JOIN_ANDROID_JOINER_ID"
        return 0
      fi
      return 1
    fi
    if [[ "$kind" == resource ]] \
      && [[ "$expected" == navigation-devices \
        || "$expected" == roster-participant-accepted-npub1admin ]]
    then
      return 0
    fi
    return 1
  }
  sleep() { :; }

  release_join_android_wait_qr_join_complete npub1admin \
    || {
      echo "Android QR join rejected an atomic QR-to-exact-roster transition" >&2
      exit 1
    }
  [[ "$snapshot" == 2 ]] || {
    echo "Android QR join did not accept the first exact roster snapshot" >&2
    exit 1
  }
)

(
  source "$ROOT/scripts/lib-mobile-release-join-ui.sh"
  RELEASE_JOIN_DELIVERY_WAIT_SECS=1
  accepted_queries=0

  release_join_android_launch() { :; }
  release_join_android_open_devices() { :; }
  release_join_android_query() {
    local kind="$1" expected="$2"
    if [[ "$kind" == resource && "$expected" == navigation-devices ]]; then
      return 0
    fi
    if [[ "$kind" == resource \
      && "$expected" == roster-participant-pending-npub1admin ]]
    then
      return 0
    fi
    if [[ "$kind" == resource \
      && "$expected" == roster-participant-accepted-npub1admin ]]
    then
      accepted_queries=$((accepted_queries + 1))
      return 1
    fi
    return 1
  }
  release_join_android_tap() { :; }
  sleep() { :; }

  if release_join_android_wait_accepted_participant npub1admin; then
    echo "Android manual join accepted a locally pending roster row" >&2
    exit 1
  fi
  ((accepted_queries > 0)) || {
    echo "Android manual join never queried the accepted-only roster selector" >&2
    exit 1
  }
)

(
  source "$ROOT/scripts/lib-mobile-release-join-ui.sh"
  RELEASE_JOIN_DELIVERY_WAIT_SECS=1

  release_join_android_launch() { :; }
  release_join_android_open_devices() { :; }
  release_join_android_query() {
    local kind="$1" expected="$2"
    [[ "$kind" == resource ]] \
      && [[ "$expected" == navigation-devices \
        || "$expected" == roster-participant-accepted-npub1admin ]]
  }
  release_join_android_tap() { :; }

  release_join_android_wait_accepted_participant npub1admin || {
    echo "Android manual join rejected the exact accepted roster row" >&2
    exit 1
  }
)

fixture="$(mktemp "${TMPDIR:-/tmp}/nvpn-release-join-ui.XXXXXX.xml")"
no_viewport_fixture="${fixture%.xml}-no-viewport.xml"
inset_viewport_fixture="${fixture%.xml}-inset-viewport.xml"
pixel_admin_add_fixture="${fixture%.xml}-pixel-admin-add.xml"
trap 'rm -f "$fixture" "$no_viewport_fixture" "$inset_viewport_fixture" "$pixel_admin_add_fixture"' EXIT
printf '%s\n' \
  '<hierarchy>' \
  '  <node bounds="[0,0][1080,2410]" />' \
  '  <node content-desc="Admin Device ID value: npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq" bounds="[10,20][110,80]" />' \
  '  <node content-desc="Manual joiner Device ID" bounds="[10,80][110,140]" />' \
  '  <node text="npub1joiner" bounds="[10,80][110,140]" />' \
  '  <node content-desc="Add joining device manually" bounds="[10,140][110,200]" />' \
  '  <node resource-id="fi.siriusbusiness.nvpn:id/roster-participant-pending-a" content-desc="Roster participant pending a" bounds="[0,100][100,200]" />' \
  '  <node resource-id="fi.siriusbusiness.nvpn:id/roster-participant-accepted-b" content-desc="Roster participant accepted b" bounds="[0,200][100,300]" />' \
  '  <node resource-id="manual-join-submit-clipped" bounds="[89,2369][991,2410]" />' \
  '  <node resource-id="manual-join-submit-partial" bounds="[89,1950][991,2200]" />' \
  '  <node resource-id="manual-join-submit-safe" enabled="true" bounds="[89,1800][991,1900]" />' \
  '</hierarchy>' >"$fixture"

description="$(
  "$ROOT/scripts/mobile-release-join-ui-query.py" \
    "$fixture" description-prefix "Admin Device ID value: " description
)"
[[ "$description" == "Admin Device ID value: npub1"* ]]
[[ "$(
  "$ROOT/scripts/mobile-release-join-ui-query.py" \
    "$fixture" resource-prefix roster-participant- count
)" == 2 ]]
if "$ROOT/scripts/mobile-release-join-ui-query.py" \
    "$fixture" resource roster-participant-accepted-a center >/dev/null 2>&1
then
  echo "Pending roster row satisfied an accepted-only UI query" >&2
  exit 1
fi
[[ "$(
  "$ROOT/scripts/mobile-release-join-ui-query.py" \
    "$fixture" resource roster-participant-accepted-b center
)" == "50 250" ]]
[[ "$(
  "$ROOT/scripts/mobile-release-join-ui-query.py" \
    "$fixture" description "Manual joiner Device ID" center
)" == "60 110" ]]
[[ "$(
  "$ROOT/scripts/mobile-release-join-ui-query.py" \
    "$fixture" description "Manual joiner Device ID" width
)" == "100" ]]
[[ "$(
  "$ROOT/scripts/mobile-release-join-ui-query.py" \
    "$fixture" text "npub1joiner" center
)" == "60 110" ]]
if "$ROOT/scripts/mobile-release-join-ui-query.py" \
    "$fixture" resource manual-join-submit-clipped safe-center >/dev/null 2>&1
then
  echo "Clipped Android control was treated as safely tappable" >&2
  exit 1
fi
[[ "$(
  "$ROOT/scripts/mobile-release-join-ui-query.py" \
    "$fixture" resource manual-join-submit-safe safe-center
)" == "540 1850" ]]
[[ "$(
  "$ROOT/scripts/mobile-release-join-ui-query.py" \
    "$fixture" resource manual-join-submit-partial visible-center
)" == "540 2030" ]]
[[ "$(
  "$ROOT/scripts/mobile-release-join-ui-query.py" \
    "$fixture" resource manual-join-submit-safe enabled
)" == true ]]
sed '/bounds="\[0,0\]\[1080,2410\]"/d' \
  "$fixture" >"$no_viewport_fixture"
if "$ROOT/scripts/mobile-release-join-ui-query.py" \
    "$no_viewport_fixture" resource manual-join-submit-safe safe-center \
    >/dev/null 2>&1
then
  echo "Android safe-center accepted a hierarchy without viewport bounds" >&2
  exit 1
fi
printf '%s\n' \
  '<hierarchy>' \
  '  <node bounds="[120,172][1200,2582]">' \
  '    <node resource-id="manual-join-submit-safe" bounds="[209,1972][1111,2072]" />' \
  '    <node resource-id="manual-join-submit-clipped" bounds="[209,2541][1111,2582]" />' \
  '  </node>' \
  '</hierarchy>' >"$inset_viewport_fixture"
[[ "$(
  "$ROOT/scripts/mobile-release-join-ui-query.py" \
    "$inset_viewport_fixture" resource manual-join-submit-safe safe-center
)" == "660 2022" ]]
if "$ROOT/scripts/mobile-release-join-ui-query.py" \
    "$inset_viewport_fixture" resource manual-join-submit-clipped safe-center \
    >/dev/null 2>&1
then
  echo "Inset Android viewport applied its bottom margin from screen zero" >&2
  exit 1
fi
printf '%s\n' \
  '<hierarchy>' \
  '  <node resource-id="android:id/content" bounds="[120,172][960,2347]">' \
  '    <node content-desc="Add joining device manually" enabled="true" bounds="[183,1980][375,2085]" />' \
  '  </node>' \
  '</hierarchy>' >"$pixel_admin_add_fixture"
if "$ROOT/scripts/mobile-release-join-ui-query.py" \
    "$pixel_admin_add_fixture" description "Add joining device manually" \
    safe-center >/dev/null 2>&1
then
  echo "Pixel admin Add control unexpectedly fit the full safe-center margin" >&2
  exit 1
fi
[[ "$(
  "$ROOT/scripts/mobile-release-join-ui-query.py" \
    "$pixel_admin_add_fixture" description "Add joining device manually" \
    visible-center
)" == "279 2013" ]]

android_admin_add="$(
  sed -n \
    '/^release_join_android_manual_admin_prepare() {/,/^release_join_android_manual_admin_add() {/p' \
    "$ROOT/scripts/lib-mobile-release-join-ui.sh"
)"
for required in \
  'release_join_android_enter description "Manual joiner Device ID"' \
  'text "$joiner" center' \
  'description "Add joining device manually" visible-center' \
  'description "Add joining device manually" enabled' \
  'release_join_android_admin_add_visible' \
  'NVPN_RELEASE_JOIN_APPROVAL_SUBMITTED_MS'
do
  grep -Fq "$required" <<<"$android_admin_add" \
    || { echo "Android admin-add lacks verified public UI state: $required" >&2; exit 1; }
done

android_field_entry="$(
  sed -n \
    '/^release_join_android_enter() {/,/^release_join_android_launch() {/p' \
    "$ROOT/scripts/lib-mobile-release-join-ui.sh"
)"
for required in 'dumpsys input_method' 'mInputShown=true' KEYCODE_CTRL_LEFT \
  KEYCODE_A KEYCODE_DEL 'text "$value" text' \
  '"$actual" == "$value"'
do
  grep -Fq "$required" <<<"$android_field_entry" \
    || { echo "Android join field entry lacks $required" >&2; exit 1; }
done
tap_line="$(grep -n 'release_join_android_tap_visible' <<<"$android_admin_add" | tail -n 1 | cut -d: -f1)"
visible_line="$(grep -n 'release_join_android_admin_add_visible' <<<"$android_admin_add" | tail -n 1 | cut -d: -f1)"
marker_line="$(grep -n 'NVPN_RELEASE_JOIN_APPROVAL_SUBMITTED_MS' <<<"$android_admin_add" | cut -d: -f1)"
[[ -n "$tap_line" && -n "$visible_line" && -n "$marker_line" \
  && "$tap_line" -lt "$visible_line" && "$visible_line" -lt "$marker_line" ]] || {
  echo "Android admin-add emits approval before the tapped action visibly succeeds" >&2
  exit 1
}

(
  # shellcheck disable=SC1091
  source "$ROOT/scripts/lib-mobile-release-join-ui.sh"
  [[ "$(release_join_desktop_mode full 0)" == 0 ]]
  [[ "$(release_join_desktop_mode full false)" == 0 ]]
  [[ "$(release_join_desktop_mode full 1)" == 1 ]]
  [[ "$(release_join_desktop_mode desktop-only 0)" == 1 ]]
  [[ "$(release_join_desktop_mode manual-only 1)" == 0 ]]
  ! release_join_desktop_mode full invalid >/dev/null
  PRIVATE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nvpn-join-deadline.XXXXXX")"
  trap 'rm -rf "$PRIVATE_DIR"' EXIT
  quick_poll() { release_join_now_ms; }
  retry_poll() {
    local attempts
    attempts="$(<"$PRIVATE_DIR/retry-attempts.txt")"
    attempts=$((attempts + 1))
    printf '%s\n' "$attempts" >"$PRIVATE_DIR/retry-attempts.txt"
    ((attempts > 1)) || return 1
    release_join_now_ms
  }
  stuck_poll() { sleep 5; }
  late_state_poll() { printf '%s\n' "$((deadline + 1))"; }
  reverse_desktop_poll() { sleep 0.25; release_join_now_ms; }
  reverse_pixel_poll() { sleep 0.3; release_join_now_ms; }
  timestamp="$PRIVATE_DIR/detected-ms.txt"
  deadline=$(( $(release_join_now_ms) + 500 ))
  release_join_observe_until_ms "$deadline" "$timestamp" quick quick_poll
  [[ -s "$timestamp" ]]
  printf '0\n' >"$PRIVATE_DIR/retry-attempts.txt"
  deadline=$(( $(release_join_now_ms) + 750 ))
  release_join_observe_until_ms \
    "$deadline" "$PRIVATE_DIR/retry.txt" retry retry_poll
  [[ "$(<"$PRIVATE_DIR/retry-attempts.txt")" == 2 ]]
  ! release_join_observe_until_ms \
    "$deadline" "$PRIVATE_DIR/late.txt" late-state late_state_poll \
    >/dev/null 2>&1
  before="$(release_join_now_ms)"
  deadline=$((before + 150))
  ! release_join_observe_until_ms \
    "$deadline" "$PRIVATE_DIR/unexpected.txt" stuck stuck_poll \
    >/dev/null 2>&1
  elapsed=$(( $(release_join_now_ms) - before ))
  ((elapsed < 1000)) || {
    echo "Blocking public-UI poll outlived its absolute deadline" >&2
    exit 1
  }
  reverse_deadline=$(( $(release_join_now_ms) + 450 ))
  release_join_observe_pair_until_ms \
    "$reverse_deadline" \
    "$PRIVATE_DIR/reverse-desktop.txt" reverse-desktop \
    reverse_desktop_poll _ \
    "$PRIVATE_DIR/reverse-pixel.txt" reverse-pixel \
    reverse_pixel_poll _
  [[ -s "$PRIVATE_DIR/reverse-desktop.txt" \
    && -s "$PRIVATE_DIR/reverse-pixel.txt" ]]
)

external_fixture="$(mktemp -d "${TMPDIR:-/tmp}/nvpn-external-join-harness.XXXXXX")"
mkdir -p "$external_fixture/source/scripts" "$external_fixture/home"
for file in \
  lib-macos-release-app-ownership.sh \
  macos-release-mobile-join-remote.sh \
  macos_release_join_artifact.py \
  mobile_release_artifact_receipt.py
do
  cp "$ROOT/scripts/$file" "$external_fixture/source/scripts/$file"
done
external_digest="$({
  for file in \
    scripts/lib-macos-release-app-ownership.sh \
    scripts/macos-release-mobile-join-remote.sh \
    scripts/macos_release_join_artifact.py \
    scripts/mobile_release_artifact_receipt.py
  do
    printf '%s\t%s\n' \
      "$file" "$(shasum -a 256 "$external_fixture/source/$file" | awk '{print $1}')"
  done
} | shasum -a 256 | awk '{print $1}')"
external_root="$external_fixture/home/.cache/nvpn-release-mobile-join-harness/$external_digest"
mkdir -p "$(dirname "$external_root")"
mv "$external_fixture/source" "$external_root"
printf '\n' >>"$external_root/scripts/mobile_release_artifact_receipt.py"
if HOME="$external_fixture/home" \
    NVPN_EXTERNAL_HARNESS_DIGEST="$external_digest" \
    "$external_root/scripts/macos-release-mobile-join-remote.sh" unknown \
    >"$external_fixture/tampered.log" 2>&1
then
  echo "tampered transferred macOS harness unexpectedly ran" >&2
  exit 1
fi
grep -Fq 'external harness identity is invalid' "$external_fixture/tampered.log"
rm -rf "$external_root"
mkdir -p "$external_root/scripts"
for file in \
  lib-macos-release-app-ownership.sh \
  macos-release-mobile-join-remote.sh \
  macos_release_join_artifact.py \
  mobile_release_artifact_receipt.py
do
  cp "$ROOT/scripts/$file" "$external_root/scripts/$file"
done
HOME="$external_fixture/home" \
NVPN_APP_REPO_PATH="$ROOT" \
NVPN_MACOS_RELEASE_JOIN_ARTIFACT_DIR="$external_fixture/artifacts" \
NVPN_MACOS_RELEASE_JOIN_PROFILE_STATE_DIR="$external_fixture/profile" \
NVPN_EXTERNAL_HARNESS_DIGEST="$external_digest" \
  "$external_root/scripts/macos-release-mobile-join-remote.sh" cleanup
[[ ! -e "$external_root" ]] || {
  echo "macOS external harness cache survived owned cleanup" >&2
  exit 1
}
rm -rf "$external_fixture"

echo "Signed Release public-UI join gate contract passed"
