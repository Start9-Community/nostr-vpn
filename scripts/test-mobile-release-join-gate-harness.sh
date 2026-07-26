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
    "Joiner stayed on its QR page",
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

for required in (
    "phase_ios_admin_android_qr",
    "phase_android_admin_ios_qr",
    "phase_ios_admin_android_manual",
    "phase_android_admin_ios_manual",
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
