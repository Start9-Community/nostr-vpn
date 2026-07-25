#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

python3 - \
  "$ROOT/scripts/mobile-ios-android-join-e2e.sh" \
  "$ROOT/ios/UITests/NostrVpnPhysicalQrJoinUITests.swift" \
  "$ROOT/ios/project.yml" \
  "$ROOT/ios/Sources/DevicesViews.swift" \
  "$ROOT/ios/Sources/RootView.swift" \
  "$ROOT/ios/Sources/QRCodeScannerView.swift" \
  "$ROOT/android/app/src/main/java/org/nostrvpn/app/AndroidDevices.kt" \
  "$ROOT/android/app/src/main/java/org/nostrvpn/app/MainActivity.kt" \
  "$ROOT/android/app/src/main/java/org/nostrvpn/app/QrScannerDialog.kt" \
  "$ROOT/scripts/release-gate.sh" <<'PY'
import pathlib
import sys


def read(path: str) -> str:
    file = pathlib.Path(path)
    if not file.is_file():
        raise SystemExit(f"real QR gate file is missing: {file}")
    return file.read_text(encoding="utf-8")


gate, ios_test, ios_project, ios_devices, ios_root, ios_scanner, android_devices, android_main, android_scanner, release_gate = (
    read(path) for path in sys.argv[1:]
)

for forbidden in (
    "ANDROID_JOIN_EXTRA",
    "ANDROID_REQUEST_B64",
    "IOS_REQUEST_B64",
    "--nvpn-debug-import-join-request-base64",
    "android_action import_join_request",
    "--nvpn-debug-manual-join-admin-base64",
    "--nvpn-debug-manual-join-network-base64",
    "--nvpn-debug-add-participant-base64",
):
    if forbidden in gate:
        raise SystemExit(
            f"physical QR join gate can bypass a camera scan via {forbidden}"
        )

for required in (
    "start_ios_physical_qr_ui_test",
    "wait_for_ios_ui_test_marker",
    "NVPN_QR_SCANNER_READY=1",
    "NVPN_QR_APPROVAL_SUBMITTED_MS=",
    "NVPN_QR_DISPLAY_READY=1",
    "scan_android_join_request_from_camera",
    'wait_for_android_description "QR scanner camera"',
    '"Confirm adding scanned join request"',
    "testJoinAdvertisingUsesTheShippedUiAndSurvivesBackgrounding",
    "testJoinAndroidAdminThroughManualEntry",
    "testAddAndroidJoinerThroughManualEntry",
    '"joinAndApprovalActions": "shipped UI only"',
):
    if required not in gate:
        raise SystemExit(f"physical QR join gate is missing {required}")

for test_name in (
    "testPhysicalAutomationPermissionIsReady",
    "testPhysicalEnvironmentBridgeIsReady",
    "testApproveAndroidJoinRequestThroughPhysicalCamera",
    "testJoinAndroidAdminThroughManualEntry",
    "testAddAndroidJoinerThroughManualEntry",
):
    if test_name not in ios_test:
        raise SystemExit(f"physical iOS UI test is missing {test_name}")
if "NVPN_XCUITEST_ENVIRONMENT_BRIDGE_READY=1" not in gate:
    raise SystemExit("physical join gate does not prove its XCTest environment bridge")
if 'Enable UI Automation on the unlocked iPhone' not in gate:
    raise SystemExit("physical join gate does not report the iOS permission fix")
if 'UI_READY_WAIT_SECS="${NVPN_MOBILE_JOIN_E2E_UI_READY_WAIT_SECS:-30}"' not in gate:
    raise SystemExit("physical join UI readiness can stall longer than its 30-second gate")
if 'QR_SCAN_WAIT_SECS="${NVPN_MOBILE_JOIN_E2E_QR_SCAN_WAIT_SECS:-30}"' not in gate:
    raise SystemExit("physical camera aiming can stall longer than its 30-second gate")
ios_general_test = read(
    str(pathlib.Path(sys.argv[2]).with_name("NostrVpnIosUITests.swift"))
)
for forbidden_timeout in ("timeout: 90", "timeout: 180", "TimeInterval = 90", "TimeInterval = 180"):
    if forbidden_timeout in ios_test or forbidden_timeout in ios_general_test:
        raise SystemExit(f"physical QR XCTest retains a long wait: {forbidden_timeout}")
if "PhysicalGateTimeouts.delivery" not in ios_general_test:
    raise SystemExit("iOS QR delivery does not use the bounded 15-second wait")
if "PhysicalGateTimeouts.camera" not in ios_test:
    raise SystemExit("iOS physical camera scan does not use the bounded 30-second wait")
if "testJoinAdvertisingUsesTheShippedUiAndSurvivesBackgrounding" not in ios_general_test:
    raise SystemExit("shipped iOS QR/background XCTest is missing")
if "NVPN_QR_DISPLAY_READY=1" not in ios_general_test:
    raise SystemExit("shipped iOS QR/background XCTest is not joined to the physical gate")
if "openJoinNetworkPage()" not in ios_general_test:
    raise SystemExit("iOS QR/background XCTest cannot reach Add Network from an existing network")

if ".launchArguments" in ios_test:
    raise SystemExit("physical QR UI tests must not inject the scanned request")
if ios_test.count("NVPN_QR_APPROVAL_SUBMITTED_MS=") != 1:
    raise SystemExit("iOS approval timing must be emitted exactly at production confirmation")
for selector in (
    "link-device-open",
    "join-request-scan-open",
    "join-request-confirm-add",
):
    if selector not in ios_devices:
        raise SystemExit(f"iOS shipped join UI lacks stable selector {selector}")
if "qr-scanner-camera" not in ios_scanner:
    raise SystemExit("iOS camera scanner lacks a stable ready selector")
for selector in ("network-switcher-open", "add-network-open", "network-setup-join"):
    if selector not in ios_root:
        raise SystemExit(f"iOS shipped Add Network path lacks stable selector {selector}")
if "openJoinNetworkPage()" not in ios_test:
    raise SystemExit("iOS manual join XCTest cannot reach Add Network from an existing network")
for variable in (
    "NVPN_XCUITEST_RUN_ID",
    "NVPN_XCUITEST_PHYSICAL_JOIN_GATE",
    "NVPN_XCUITEST_MANUAL_ADMIN_DEVICE_ID",
    "NVPN_XCUITEST_MANUAL_NETWORK_ID",
    "NVPN_XCUITEST_MANUAL_JOINER_DEVICE_ID",
    "NVPN_XCUITEST_DELIVERY_WAIT_SECS",
    "NVPN_XCUITEST_CAMERA_WAIT_SECS",
):
    mapping = f'{variable}: "$({variable})"'
    if mapping not in ios_project:
        raise SystemExit(f"Xcode TestAction does not bridge build setting {variable}")
    if (
        f'{variable}="${{{variable}:-}}"' not in gate
        and variable != "NVPN_XCUITEST_RUN_ID"
        and variable not in {
            "NVPN_XCUITEST_DELIVERY_WAIT_SECS",
            "NVPN_XCUITEST_CAMERA_WAIT_SECS",
        }
    ):
        raise SystemExit(f"physical gate does not pass xcodebuild setting {variable}")
if 'NVPN_XCUITEST_DELIVERY_WAIT_SECS="$WAIT_SECS"' not in gate:
    raise SystemExit("physical gate does not bridge the 15-second delivery bound")
if 'NVPN_XCUITEST_CAMERA_WAIT_SECS="$QR_SCAN_WAIT_SECS"' not in gate:
    raise SystemExit("physical gate does not bridge the 30-second camera bound")
if gate.count('|| fail "iOS must have an administered network for the QR-admin direction"') != 1:
    raise SystemExit("physical gate has a missing or duplicate iOS admin-network assertion")
if 'NVPN_XCUITEST_RUN_ID="$IOS_UI_TEST_RUN_ID"' not in gate:
    raise SystemExit("physical gate does not pass its run ID as an xcodebuild setting")
if "testPhysicalEnvironmentBridgeIsReady" not in gate:
    raise SystemExit("physical gate does not execute its Xcode TestAction environment bridge")
start_function = gate.split("start_ios_physical_qr_ui_test() {", 1)[1].split(
    "\ncopy_ios_ui_test_markers() {", 1
)[0]
start_lines = start_function.splitlines()
command_line = next(
    (index for index, line in enumerate(start_lines) if '"${command[@]}"' in line),
    None,
)
if command_line is None:
    raise SystemExit("physical gate does not execute its constructed xcodebuild command")
invocation_start = command_line
while invocation_start > 0 and start_lines[invocation_start - 1].rstrip().endswith("\\"):
    invocation_start -= 1
invocation = "\n".join(start_lines[invocation_start : command_line + 1])
if "NVPN_XCUITEST_" in invocation:
    raise SystemExit("physical gate relies on shell env vars the XCTest runner cannot inherit")

if "join-request-scan-open" not in android_devices:
    raise SystemExit("Android shipped join UI lacks its scan button selector")
if "join-request-confirm-add" not in android_main:
    raise SystemExit("Android scanned-request confirmation lacks a stable selector")
if "qr-scanner-camera" not in android_scanner:
    raise SystemExit("Android camera scanner lacks a stable ready selector")

if "./scripts/test-mobile-real-qr-join-harness.sh" not in release_gate:
    raise SystemExit("release preflight does not enforce the real QR join contract")
PY

printf 'Physical QR join source contract passed; device execution is a separate required gate\n'
