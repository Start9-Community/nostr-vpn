#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILES=(
  "$ROOT/scripts/mobile-release-join-e2e.sh"
  "$ROOT/scripts/lib-mobile-release-join-artifacts.sh"
  "$ROOT/scripts/lib-mobile-release-artifact-reuse.sh"
  "$ROOT/scripts/lib-mobile-release-join-ui.sh"
  "$ROOT/scripts/macos-vm-release-mobile-join-e2e.sh"
  "$ROOT/scripts/macos-release-mobile-join-remote.sh"
)
for file in "${FILES[@]}"; do
  bash -n "$file"
done
python3 -B "$ROOT/scripts/macos_release_join_artifact.py" --help >/dev/null

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
  "$ROOT/scripts/desktop-manual-join-ax.swift" \
  "$ROOT/scripts/macos_release_join_artifact.py" \
  "$ROOT/ios/UITests/NostrVpnReleaseJoinUITests.swift" \
  "$ROOT/ios/project.yml" \
  "$ROOT/android/app/src/main/java/org/nostrvpn/app/AndroidDevices.kt" \
  "$ROOT/android/app/src/main/java/org/nostrvpn/app/AndroidComponents.kt" \
  "$ROOT/ios/Sources/DevicesViews.swift" \
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
    artifacts,
    ui,
    desktop,
    desktop_remote,
    desktop_ui_driver,
    desktop_artifact,
    ios_test,
    ios_project,
    android_devices,
    android_components,
    ios_devices,
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
    'element("join-request-qr-content")',
    "NVPN_RELEASE_JOIN_QR_CONTENT_WIDTH_BPS",
    "qrContentWidthMinimumBasisPoints",
    "qrContentWidthMaximumBasisPoints",
    "NVPN_RELEASE_JOIN_LIFECYCLE_READY=1",
    "NVPN_RELEASE_JOIN_QR_DECODED=1",
    "NVPN_RELEASE_JOIN_PENDING_QR_VISIBLE_MS",
    "waitForRosterBackedPendingQrDismissal",
    "NVPN_RELEASE_JOIN_QR_DISMISSED_WITH_ROSTER_MS",
    "Join QR disappeared before the exact admin roster was visible",
    "roster-participant-accepted-",
    "testScanPhysicalJoinQrAndRequireAdminRosterProgress",
    "testShowPhysicalJoinQrAndRequireRosterCompletion",
    "testManualJoinAndRequireRosterCompletion",
    "testManualAdminAddRequiresRosterProgress",
    "requireAcceptedRoster",
    "app.terminate()",
    "NVPN_RELEASE_JOIN_RELAUNCH_DURABLE",
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
)[1].split("func testScanPhysicalJoinQrAndRequireAdminRosterProgress()", 1)[0]
for required in (
    "waitForRosterBackedPendingQrDismissal",
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

for required in (
    "phase_ios_admin_android_qr",
    "phase_android_admin_ios_qr",
    "phase_ios_admin_android_manual",
    "phase_android_admin_ios_manual",
    "release_join_android_wait_qr_join_complete",
    "release_join_android_wait_join_complete",
    "release_join_android_relaunch_and_wait_accepted",
    "macos-vm-release-mobile-join-e2e.sh",
    "opticalCameraQr",
    "exactRosterOnBothSides",
    '"androidJoinerRelaunchDurable": True',
    '"iphoneJoinerRelaunchDurable"',
):
    if required not in gate:
        raise SystemExit(f"Release join orchestrator is missing {required}")
ios_qr_joiner_phase = gate.split(
    "phase_android_admin_ios_qr() {", 1
)[1].split("phase_ios_admin_android_manual() {", 1)[0]
for required in (
    "NVPN_RELEASE_JOIN_QR_RELAUNCH_DURABLE",
    "ios_qr_relaunch_admin",
    '[[ "$ios_qr_relaunch_admin" == "$RELEASE_JOIN_ANDROID_ADMIN_ID" ]]',
    "RELEASE_JOIN_IOS_QR_RELAUNCH_DURABLE=1",
    "ios_qr_relaunch_durable != \"1\"",
):
    if required not in gate:
        raise SystemExit(
            f"Mobile receipt does not validate iPhone QR relaunch proof: {required}"
        )
for required in (
    "release_join_ios_finish_test",
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

macos_iphone_joiner_phase = desktop.split(
    "# macOS admin -> physical iPhone joiner.", 1
)[1].split("# Physical iPhone admin -> macOS joiner.", 1)[0]
for required in (
    "NVPN_RELEASE_JOIN_RELAUNCH_DURABLE",
    '[[ "$iphone_joiner_relaunch_admin" == "$DESKTOP_IOS_ADMIN_ID" ]]',
):
    if required not in macos_iphone_joiner_phase:
        raise SystemExit(
            f"macOS/iPhone gate does not consume iPhone-joiner relaunch proof: {required}"
        )

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
    '[[ "$ios_admin_relaunch_joiner" == "$DESKTOP_IOS_JOINER_ID" ]]',
):
    if required not in macos_iphone_admin_phase:
        raise SystemExit(
            f"macOS/iPhone gate does not consume iPhone-admin relaunch proof: {required}"
        )
if "NVPN_RELEASE_JOIN_ALLOW_DEVICE_RESET" not in artifacts:
    raise SystemExit("Physical app-state reset lacks an explicit destructive opt-in")

macos_pixel_admin_phase = desktop.split(
    "# Physical Android admin -> macOS joiner.", 1
)[1].split("python3 -", 1)[0]
for required in (
    'release_join_android_relaunch_and_wait_accepted "$DESKTOP_JOINER_ID"',
    "Android admin did not retain the macOS joiner roster across relaunch",
):
    if required not in macos_pixel_admin_phase:
        raise SystemExit(
            "macOS/Pixel join gate claims Pixel relaunch durability without "
            f"the Android-admin direction check: {required}"
        )

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
    "RELEASE_JOIN_QR_CONTENT_WIDTH_MIN_BPS",
    "RELEASE_JOIN_QR_CONTENT_WIDTH_MAX_BPS",
    'resource "join-request-qr-content" width',
    "RELEASE_JOIN_ANDROID_QR_CONTENT_WIDTH_BPS",
    "release_join_android_assert_pending_qr",
    "release_join_require_fresh_ios_pending_qr",
    "roster-participant-accepted-$admin",
    "roster-participant-accepted-$joiner",
    "release_join_android_wait_accepted_participant",
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
    "minimum_qr_content_width_bps = 9_800",
    "maximum_qr_content_width_bps = 10_000",
    '"minimumRequiredBasisPoints": minimum_qr_content_width_bps',
    '"maximumAllowedBasisPoints": maximum_qr_content_width_bps',
    '"androidObservedBasisPoints"',
    '"iosObservedBasisPoints"',
):
    if required not in gate:
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
    ):
        if required not in source:
            raise SystemExit(f"{label} does not validate QR width evidence: {required}")

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
for source, label, interpolation in (
    (android_components, "Android", "${participant.npub}"),
    (ios_participants, "iOS", "\\(participant.npub)"),
    (macos_devices, "macOS", "\\(participant.npub)"),
):
    if "roster-participant-" not in source or interpolation not in source:
        raise SystemExit(f"{label} Release UI lacks exact roster participant identity")
    if "participant.state == \"pending\"" not in source:
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
if 'NVPN_APP_DATA_DIR=' in desktop_remote or 'NVPN_CLI_PATH=' in desktop_remote:
    raise SystemExit("Desktop Release app is launched against injected private state")
if '"$APP_EXE"' not in desktop_remote:
    raise SystemExit("Desktop gate does not launch the exact signed Release executable")
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
    "release_join_reset_ios_state",
    "testManualJoinAndRequireRosterCompletion",
    "testManualAdminAddRequiresRosterProgress",
    "macOS-admin-to-iPhone-manual",
    "iPhone-admin-to-macOS-manual",
    "desktopAdminIphoneJoiner",
    "iphoneAdminDesktopJoiner",
    "desktopAdminIphoneJoinerRelaunchDurable",
    "iphoneAdminDesktopJoinerRelaunchDurable",
    "NVPN_RELEASE_JOIN_IOS_RECEIPT",
    "release_join_validate_ios_reuse",
):
    if required not in desktop:
        raise SystemExit(
            f"macOS/iPhone frozen Release join gate is missing {required}"
        )
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
trap 'rm -f "$fixture"' EXIT
printf '%s\n' \
  '<hierarchy>' \
  '  <node resource-id="fi.siriusbusiness.nvpn:id/admin-device-id-value" content-desc="Admin Device ID value: npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq" bounds="[10,20][110,80]" />' \
  '  <node resource-id="fi.siriusbusiness.nvpn:id/roster-participant-pending-a" content-desc="Roster participant pending a" bounds="[0,100][100,200]" />' \
  '  <node resource-id="fi.siriusbusiness.nvpn:id/roster-participant-accepted-b" content-desc="Roster participant accepted b" bounds="[0,200][100,300]" />' \
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
    "$fixture" resource admin-device-id-value center
)" == "60 50" ]]
[[ "$(
  "$ROOT/scripts/mobile-release-join-ui-query.py" \
    "$fixture" resource admin-device-id-value width
)" == "100" ]]

echo "Signed Release public-UI join gate contract passed"
