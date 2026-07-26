#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILES=(
  "$ROOT/scripts/mobile-release-join-e2e.sh"
  "$ROOT/scripts/lib-mobile-release-join-artifacts.sh"
  "$ROOT/scripts/lib-mobile-release-join-ui.sh"
  "$ROOT/scripts/macos-vm-release-mobile-join-e2e.sh"
  "$ROOT/scripts/macos-release-mobile-join-remote.sh"
)
for file in "${FILES[@]}"; do
  bash -n "$file"
done

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

python3 - \
  "$ROOT/scripts/mobile-release-join-e2e.sh" \
  "$ROOT/scripts/lib-mobile-release-join-artifacts.sh" \
  "$ROOT/scripts/lib-mobile-release-join-ui.sh" \
  "$ROOT/scripts/macos-vm-release-mobile-join-e2e.sh" \
  "$ROOT/scripts/macos-release-mobile-join-remote.sh" \
  "$ROOT/ios/UITests/NostrVpnReleaseJoinUITests.swift" \
  "$ROOT/ios/project.yml" \
  "$ROOT/android/app/src/main/java/org/nostrvpn/app/AndroidDevices.kt" \
  "$ROOT/android/app/src/main/java/org/nostrvpn/app/AndroidComponents.kt" \
  "$ROOT/ios/Sources/DevicesViews.swift" \
  "$ROOT/ios/Sources/SettingsViews.swift" \
  "$ROOT/macos/Sources/RootViewDevices.swift" \
  "$ROOT/scripts/release-gate.sh" <<'PY'
import pathlib
import sys


def read(path):
    value = pathlib.Path(path)
    if not value.is_file():
        raise SystemExit(f"Release join gate file is missing: {value}")
    return value.read_text(encoding="utf-8")


(
    gate,
    artifacts,
    ui,
    desktop,
    desktop_remote,
    ios_test,
    ios_project,
    android_devices,
    android_components,
    ios_devices,
    ios_participants,
    macos_devices,
    release_gate,
) = map(read, sys.argv[1:])

runtime_gate_code = "\n".join((gate, ui, desktop, desktop_remote, ios_test))
for forbidden in (
    "run-as",
    "--nvpn-debug",
    "DEBUG_ACTION",
    "appDataContainer",
    "import-join-request",
    "QR_PAYLOAD",
    "REQUEST_BASE64",
):
    if forbidden in runtime_gate_code:
        raise SystemExit(f"Release join gate retains forbidden private/debug path: {forbidden}")
if "run-as" in artifacts:
    raise SystemExit("Release artifact validation still invokes run-as")

for forbidden in (".launchArguments =", ".launchEnvironment ="):
    if forbidden in ios_test:
        raise SystemExit(f"Release join XCTest injects app state through {forbidden}")
for required in (
    "app.launchArguments.isEmpty",
    "app.launchEnvironment.isEmpty",
    'element("qr-scanner-camera")',
    "XCUIDevice.shared.press(.home)",
    "assertQrIsFullWidth(qr)",
    "NVPN_RELEASE_JOIN_LIFECYCLE_READY=1",
    "NVPN_RELEASE_JOIN_QR_DECODED=1",
    "NVPN_RELEASE_JOIN_PENDING_QR_VISIBLE_MS",
    "waitForRosterBackedPendingQrDismissal",
    "NVPN_RELEASE_JOIN_QR_DISMISSED_WITH_ROSTER_MS",
    "Join QR disappeared before the exact admin roster was visible",
    "roster-participant-",
    "testScanPhysicalJoinQrAndRequireAdminRosterProgress",
    "testShowPhysicalJoinQrAndRequireRosterCompletion",
    "testManualJoinAndRequireRosterCompletion",
    "testManualAdminAddRequiresRosterProgress",
):
    if required not in ios_test:
        raise SystemExit(f"Release join XCTest is missing {required}")
if "paste" in ios_test.lower() or "UIPasteboard" in ios_test:
    raise SystemExit("Release QR XCTest may not paste/import a join request")
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
    'guard element("roster-participant-\\(expectedParticipant)").exists else {',
    "NVPN_RELEASE_JOIN_QR_DISMISSED_WITH_ROSTER_MS",
):
    if required not in ios_roster_transition:
        raise SystemExit(
            "Release QR XCTest lacks an immediate roster-backed dismissal check: "
            + required
        )
if ios_roster_transition.index(
    'element("roster-participant-\\(expectedParticipant)").exists'
) > ios_roster_transition.index(
    "NVPN_RELEASE_JOIN_QR_DISMISSED_WITH_ROSTER_MS"
):
    raise SystemExit("Release QR XCTest records dismissal before checking the roster")

for required in (
    "phase_ios_admin_android_qr",
    "phase_android_admin_ios_qr",
    "phase_ios_admin_android_manual",
    "phase_android_admin_ios_manual",
    "release_join_android_wait_qr_join_complete",
    "release_join_android_wait_join_complete",
    "macos-vm-release-mobile-join-e2e.sh",
    "opticalCameraQr",
    "exactRosterOnBothSides",
):
    if required not in gate:
        raise SystemExit(f"Release join orchestrator is missing {required}")
if "NVPN_RELEASE_JOIN_ALLOW_DEVICE_RESET" not in artifacts:
    raise SystemExit("Physical app-state reset lacks an explicit destructive opt-in")

for required in (
    "-configuration Release",
    "build-for-testing",
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
    "QR scanner camera",
    "join-request-confirm-add",
    "NVPN_RELEASE_JOIN_APPROVAL_SUBMITTED_MS",
    "KEYCODE_HOME",
    "Join request QR code",
    "release_join_android_assert_qr_full_width",
    "release_join_android_assert_pending_qr",
    "release_join_require_fresh_ios_pending_qr",
    "roster-participant-$admin",
    "roster-participant-$joiner",
    "test-without-building",
):
    if required not in ui:
        raise SystemExit(f"Public UI driver is missing {required}")

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
if "roster-participant-${participant.npub}" not in android_components:
    raise SystemExit("Android Release UI lacks exact roster participant identity")
if "roster-participant-\\(participant.npub)" not in ios_participants:
    raise SystemExit("iOS Release UI lacks exact roster participant identity")
if "roster-participant-\\(participant.npub)" not in macos_devices:
    raise SystemExit("macOS Release UI lacks exact roster participant identity")

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
if 'NVPN_APP_DATA_DIR=' in desktop_remote or 'NVPN_CLI_PATH=' in desktop_remote:
    raise SystemExit("Desktop Release app is launched against injected private state")
if '"$APP_EXE"' not in desktop_remote:
    raise SystemExit("Desktop gate does not launch the exact signed Release executable")
for required in (
    "exec /usr/bin/env -i",
    "NVPN_EXPECTED_MACOS_SIGNING_IDENTITY",
    "NVPN_EXPECTED_MACOS_SIGNING_TEAM_ID",
    "NVPN_EXPECTED_MACOS_SIGNER_CERT_SHA256",
    'MACOS_SIGNING_IDENTITY="$EXPECTED_SIGNING_IDENTITY"',
    '[[ "$team" == "$EXPECTED_SIGNING_TEAM" ]]',
    '[[ "$authority" == "$EXPECTED_SIGNING_IDENTITY" ]]',
    "signerCertificateSha256",
):
    if required not in desktop_remote and required not in desktop:
        raise SystemExit(f"Desktop Release provenance gate is missing {required}")

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
    if [[ "$kind" == resource && "$expected" == roster-participant-npub1admin ]]; then
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
        || "$expected" == roster-participant-npub1admin ]]
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

fixture="$(mktemp "${TMPDIR:-/tmp}/nvpn-release-join-ui.XXXXXX.xml")"
trap 'rm -f "$fixture"' EXIT
printf '%s\n' \
  '<hierarchy>' \
  '  <node resource-id="fi.siriusbusiness.nvpn:id/admin-device-id-value" content-desc="Admin Device ID value: npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq" bounds="[10,20][110,80]" />' \
  '  <node resource-id="fi.siriusbusiness.nvpn:id/roster-participant-a" content-desc="Roster participant a" bounds="[0,100][100,200]" />' \
  '  <node resource-id="fi.siriusbusiness.nvpn:id/roster-participant-b" content-desc="Roster participant b" bounds="[0,200][100,300]" />' \
  '</hierarchy>' >"$fixture"

description="$(
  "$ROOT/scripts/mobile-release-join-ui-query.py" \
    "$fixture" resource admin-device-id-value description
)"
[[ "$description" == "Admin Device ID value: npub1"* ]]
[[ "$(
  "$ROOT/scripts/mobile-release-join-ui-query.py" \
    "$fixture" resource-prefix roster-participant- count
)" == 2 ]]
[[ "$(
  "$ROOT/scripts/mobile-release-join-ui-query.py" \
    "$fixture" resource admin-device-id-value center
)" == "60 50" ]]
[[ "$(
  "$ROOT/scripts/mobile-release-join-ui-query.py" \
    "$fixture" resource admin-device-id-value width
)" == "100" ]]

echo "Signed Release public-UI join gate contract passed"
