#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - \
  "$ROOT/ios/Sources/QRCodeScannerView.swift" \
  "$ROOT/ios/UITests/NostrVpnReleaseJoinUITests.swift" \
  "$ROOT/ios/Sources/AppModel.swift" \
  "$ROOT/ios/NostrVpnIos.xcodeproj/project.pbxproj" \
  "$ROOT/scripts/lib-mobile-release-join-ui.sh" <<'PY'
import pathlib
import sys

scanner, tests, app_model, project, harness = (
    pathlib.Path(path).read_text(encoding="utf-8") for path in sys.argv[1:]
)
key = "NVPN_RELEASE_JOIN_QR_IMAGE_IMPORT"
assignment = f'app.launchEnvironment = ["{key}": "1"]'
condition = f'ProcessInfo.processInfo.environment["{key}"] == "1"'

if condition not in scanner:
    raise SystemExit("QR importer is not hidden behind the exact launch environment value")
if scanner.count(key) != 1:
    raise SystemExit("QR importer has more than one production launch-environment path")

setup = tests.split("override func setUpWithError() throws", 1)[1].split(
    "func testCreateAdminNetworkAndReportPublicValues()", 1
)[0]
import_test = tests.split(
    "func testImportJoinQrImageAndRequireAdminRosterProgress()", 1
)[1].split("func test", 1)[0]
other_tests = tests.replace(import_test, "")

for required in (
    "app.launchEnvironment.isEmpty",
    "app.launch()",
):
    if required not in setup:
        raise SystemExit(f"Ordinary Release launch lacks empty-environment contract: {required}")
if tests.count(assignment) != 1 or assignment not in import_test:
    raise SystemExit("Exact QR import test does not own the sole launch flag")
if ".launchEnvironment =" in other_tests:
    raise SystemExit("A non-import release join test sets target-app environment")
for required in (
    "XCTAssertTrue(app.launchEnvironment.isEmpty)",
    "app.terminate()",
    assignment,
    "XCTAssertEqual(app.launchEnvironment.count, 1)",
    "addTeardownBlock { self.app.terminate() }",
    "app.launch()",
    'element("qr-scanner-camera").waitForExistence',
    'element("join-request-import-image")',
):
    if required not in import_test:
        raise SystemExit(f"QR import launch contract lacks {required}")
if import_test.index('element("qr-scanner-camera")') > import_test.index(
    'element("join-request-import-image")'
):
    raise SystemExit("Importer is queried before the real scanner is visible")

combined = "\n".join((scanner, tests, app_model, project, harness))
for forbidden in (
    "QRImageImportTestMarker",
    "nvpn-release-join-qr-image-import",
    "RELEASE_JOIN_IOS_QR_IMPORT_MARKER",
    "appGroupDataContainer",
):
    if forbidden in combined:
        raise SystemExit(f"Legacy QR marker transport remains: {forbidden}")
PY

echo "iOS QR image import launch-environment tests passed"
