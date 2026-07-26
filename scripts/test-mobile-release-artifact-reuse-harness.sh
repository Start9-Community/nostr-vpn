#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VALIDATOR="$ROOT/scripts/mobile_release_artifact_receipt.py"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/nvpn-artifact-reuse.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

APP_ROOT="$TMP_ROOT/app-checkout"
FIPS_ROOT="$TMP_ROOT/fips-checkout"
ANDROID_DIR="$TMP_ROOT/android"
IOS_DERIVED="$TMP_ROOT/ios-derived"
IOS_PRODUCTS="$IOS_DERIVED/Build/Products"
IOS_APP="$IOS_PRODUCTS/Release-iphoneos/Nostr VPN.app"
IOS_TUNNEL="$IOS_APP/PlugIns/Nostr VPN Tunnel.appex"
IOS_XCTESTRUN="$IOS_PRODUCTS/NostrVpnIos_fixture.xctestrun"
mkdir -p \
  "$APP_ROOT" \
  "$FIPS_ROOT" \
  "$ANDROID_DIR" \
  "$IOS_TUNNEL" \
  "$IOS_PRODUCTS/NostrVpnIosUITests-Runner.app"

printf 'apk fixture\n' >"$ANDROID_DIR/app-release.apk"
printf 'app executable\n' >"$IOS_APP/Nostr VPN"
printf 'tunnel executable\n' >"$IOS_TUNNEL/Nostr VPN Tunnel"
printf 'app profile\n' >"$IOS_APP/embedded.mobileprovision"
printf 'tunnel profile\n' >"$IOS_TUNNEL/embedded.mobileprovision"
printf 'runner product\n' >"$IOS_PRODUCTS/NostrVpnIosUITests-Runner.app/runner"

APP_HEAD=1111111111111111111111111111111111111111
APP_TREE=2222222222222222222222222222222222222222
FIPS_HEAD=3333333333333333333333333333333333333333
FIPS_TREE=4444444444444444444444444444444444444444
FIPS_VERSION=1.2.3
SIGNER_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
APP_CDHASH=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
TUNNEL_CDHASH=cccccccccccccccccccccccccccccccccccccccc
DEVICE_SHA=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
PACKAGE=fi.siriusbusiness.nvpn
ANDROID_METADATA="$ANDROID_DIR/fips-linkage.json"
ANDROID_RECEIPT="$ANDROID_DIR/mobile-android-release-artifact.json"
IOS_METADATA="$TMP_ROOT/ios-fips-linkage.json"
IOS_RECEIPT="$TMP_ROOT/mobile-ios-release-artifact.json"

python3 - \
  "$VALIDATOR" "$APP_ROOT" "$FIPS_ROOT" \
  "$ANDROID_DIR/app-release.apk" "$ANDROID_METADATA" "$ANDROID_RECEIPT" \
  "$IOS_APP" "$IOS_DERIVED" "$IOS_XCTESTRUN" "$IOS_METADATA" "$IOS_RECEIPT" \
  "$APP_HEAD" "$APP_TREE" "$FIPS_HEAD" "$FIPS_TREE" "$FIPS_VERSION" \
  "$SIGNER_SHA" "$APP_CDHASH" "$TUNNEL_CDHASH" "$DEVICE_SHA" "$PACKAGE" <<'PY'
import importlib.util
import json
import pathlib
import plistlib
import sys

(
    module_path,
    app_root,
    fips_root,
    apk,
    android_metadata,
    android_receipt,
    ios_app,
    ios_derived,
    ios_xctestrun,
    ios_metadata,
    ios_receipt,
    app_head,
    app_tree,
    fips_head,
    fips_tree,
    fips_version,
    signer,
    app_cdhash,
    tunnel_cdhash,
    device_sha,
    package,
) = sys.argv[1:]
spec = importlib.util.spec_from_file_location("artifact_receipt", module_path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
app_root = pathlib.Path(app_root)
fips_root = pathlib.Path(fips_root)
apk = pathlib.Path(apk)
android_metadata = pathlib.Path(android_metadata)
android_receipt = pathlib.Path(android_receipt)
ios_app = pathlib.Path(ios_app)
ios_derived = pathlib.Path(ios_derived)
ios_xctestrun = pathlib.Path(ios_xctestrun)
ios_metadata = pathlib.Path(ios_metadata)
ios_receipt = pathlib.Path(ios_receipt)

metadata = {
    "checkoutPathSha256": module.path_sha256(fips_root),
    "checkoutHead": fips_head,
    "checkoutTree": fips_tree,
    "fipsCoreVersion": fips_version,
}
android_metadata.write_text(
    json.dumps(metadata, sort_keys=True) + "\n", encoding="utf-8"
)
ios_metadata.write_text(
    json.dumps(metadata, sort_keys=True) + "\n", encoding="utf-8"
)
android = {
    "receiptSchema": 2,
    "artifactType": "Android Release APK",
    "apkPathSha256": module.path_sha256(apk),
    "apkSha256": module.sha256_file(apk),
    "installedApkSha256": module.sha256_file(apk),
    "companySigningVerified": True,
    "signerCertificateSha256": signer,
    "appGitSha": app_head,
    "appGitTree": app_tree,
    "fipsGitSha": fips_head,
    "fipsGitTree": fips_tree,
    "fipsCoreVersion": fips_version,
    "fipsCheckoutPathSha256": module.path_sha256(fips_root),
    "fipsCargoMetadataReceiptPathSha256": module.path_sha256(android_metadata),
    "fipsCargoMetadataReceiptSha256": module.sha256_file(android_metadata),
    "fipsDependenciesForcedRebuilt": True,
    "package": package,
    "replacementInstall": True,
    "debuggable": False,
}
android_receipt.write_text(
    json.dumps(android, indent=2, sort_keys=True) + "\n", encoding="utf-8"
)
with (ios_app / "Info.plist").open("wb") as handle:
    plistlib.dump(
        {
            "CFBundleIdentifier": package,
            "CFBundleShortVersionString": "4.1.5",
            "CFBundleVersion": "4001007",
        },
        handle,
    )
with ios_xctestrun.open("wb") as handle:
    plistlib.dump(
        {
            "NostrVpnIosUITests": {
                "EnvironmentVariables": {},
                "TestBundlePath": "__TESTHOST__/PlugIns/NostrVpnIosUITests.xctest",
                "TestHostPath": "__TESTROOT__/NostrVpnIosUITests-Runner.app",
                "UITargetAppPath": "__TESTROOT__/Release-iphoneos/Nostr VPN.app",
            }
        },
        handle,
    )
products = ios_derived / "Build" / "Products"
ios = {
    "receiptSchema": 2,
    "artifactType": "iOS company Ad Hoc Release app",
    "appCodeDirectoryHash": app_cdhash,
    "packetTunnelCodeDirectoryHash": tunnel_cdhash,
    "appExecutableSha256": module.sha256_file(ios_app / "Nostr VPN"),
    "packetTunnelExecutableSha256": module.sha256_file(
        ios_app / "PlugIns" / "Nostr VPN Tunnel.appex" / "Nostr VPN Tunnel"
    ),
    "appGitSha": app_head,
    "appGitTree": app_tree,
    "appPathSha256": module.path_sha256(ios_app),
    "appBundleTreeSha256": module.tree_sha256(ios_app),
    "treeSha256": module.tree_sha256(ios_app),
    "derivedDataPathSha256": module.path_sha256(ios_derived),
    "testProductsPathSha256": module.path_sha256(products),
    "testProductsTreeSha256": module.tree_sha256(products),
    "xctestrunPathSha256": module.path_sha256(ios_xctestrun),
    "xctestrunSha256": module.sha256_file(ios_xctestrun),
    "fipsGitSha": fips_head,
    "fipsGitTree": fips_tree,
    "fipsCoreVersion": fips_version,
    "fipsCheckoutPathSha256": module.path_sha256(fips_root),
    "fipsCargoMetadataReceiptPathSha256": module.path_sha256(ios_metadata),
    "fipsCargoMetadataReceiptSha256": module.sha256_file(ios_metadata),
    "fipsDependenciesForcedRebuilt": True,
    "appProvisioningProfileSha256": module.sha256_file(
        ios_app / "embedded.mobileprovision"
    ),
    "packetTunnelProvisioningProfileSha256": module.sha256_file(
        ios_app / "PlugIns" / "Nostr VPN Tunnel.appex" / "embedded.mobileprovision"
    ),
    "companySigningVerified": True,
    "signerCertificateSha256": signer,
    "selectedPhysicalDeviceIdentifierSha256": device_sha,
    "selectedPhysicalDevice": {
        "deviceIdentifierSha256": device_sha,
        "explicitPhysicalDeviceVerified": True,
        "model": "Fixture Phone",
        "platform": "iOS",
        "productType": "Fixture1,1",
    },
    "installedBundleIdentifier": package,
    "cashuAndPaidExitCompiled": False,
    "paidExitWalletWorkerCompiled": False,
    "updaterCompiled": False,
    "debuggable": False,
}
ios_receipt.write_text(
    json.dumps(ios, indent=2, sort_keys=True) + "\n", encoding="utf-8"
)
PY

validate_android() {
  python3 "$VALIDATOR" validate-android \
    --receipt "$ANDROID_RECEIPT" \
    --apk "$ANDROID_DIR/app-release.apk" \
    --fips-metadata "$ANDROID_METADATA" \
    --app-root "$APP_ROOT" \
    --fips-root "$FIPS_ROOT" \
    --app-head "$APP_HEAD" \
    --app-tree "$APP_TREE" \
    --fips-head "$FIPS_HEAD" \
    --fips-tree "$FIPS_TREE" \
    --fips-version "$FIPS_VERSION" \
    --package "$PACKAGE" \
    --actual-package "$PACKAGE" \
    --signer-sha "$SIGNER_SHA"
}

validate_ios() {
  python3 "$VALIDATOR" validate-ios \
    --receipt "$IOS_RECEIPT" \
    --app "$IOS_APP" \
    --derived-data "$IOS_DERIVED" \
    --xctestrun "$IOS_XCTESTRUN" \
    --fips-metadata "$IOS_METADATA" \
    --fips-root "$FIPS_ROOT" \
    --app-head "$APP_HEAD" \
    --app-tree "$APP_TREE" \
    --fips-head "$FIPS_HEAD" \
    --fips-tree "$FIPS_TREE" \
    --fips-version "$FIPS_VERSION" \
    --bundle "$PACKAGE" \
    --signer-sha "$SIGNER_SHA" \
    --app-cdhash "$APP_CDHASH" \
    --tunnel-cdhash "$TUNNEL_CDHASH" \
    --device-identifier-sha "$DEVICE_SHA"
}

validate_android
validate_ios

cp "$ANDROID_DIR/app-release.apk" "$TMP_ROOT/app-release.clean.apk"
printf 'tamper\n' >>"$ANDROID_DIR/app-release.apk"
if validate_android >"$TMP_ROOT/android-apk-tamper.log" 2>&1; then
  echo "Android artifact receipt accepted tampered APK bytes" >&2
  exit 1
fi
mv "$TMP_ROOT/app-release.clean.apk" "$ANDROID_DIR/app-release.apk"

cp "$ANDROID_RECEIPT" "$TMP_ROOT/android-receipt.clean.json"
python3 - "$ANDROID_RECEIPT" <<'PY'
import json
import sys
path = sys.argv[1]
receipt = json.load(open(path, encoding="utf-8"))
receipt["appGitTree"] = "0" * 40
with open(path, "w", encoding="utf-8") as handle:
    json.dump(receipt, handle)
PY
if validate_android >"$TMP_ROOT/android-tree-mismatch.log" 2>&1; then
  echo "Android artifact receipt accepted a mismatched application tree" >&2
  exit 1
fi
mv "$TMP_ROOT/android-receipt.clean.json" "$ANDROID_RECEIPT"

cp "$IOS_XCTESTRUN" "$TMP_ROOT/ios-xctestrun.clean"
printf 'tamper\n' >>"$IOS_XCTESTRUN"
if validate_ios >"$TMP_ROOT/ios-xctestrun-tamper.log" 2>&1; then
  echo "iOS artifact receipt accepted tampered xctestrun bytes" >&2
  exit 1
fi
mv "$TMP_ROOT/ios-xctestrun.clean" "$IOS_XCTESTRUN"

cp "$IOS_PRODUCTS/NostrVpnIosUITests-Runner.app/runner" "$TMP_ROOT/runner.clean"
printf 'tamper\n' >>"$IOS_PRODUCTS/NostrVpnIosUITests-Runner.app/runner"
if validate_ios >"$TMP_ROOT/ios-products-tamper.log" 2>&1; then
  echo "iOS artifact receipt accepted tampered UI test products" >&2
  exit 1
fi
mv "$TMP_ROOT/runner.clean" "$IOS_PRODUCTS/NostrVpnIosUITests-Runner.app/runner"

ln -s "$TMP_ROOT" "$IOS_PRODUCTS/escaping-product"
if python3 "$VALIDATOR" tree-sha "$IOS_PRODUCTS" \
    >"$TMP_ROOT/ios-symlink-escape.log" 2>&1
then
  echo "iOS artifact tree accepted an escaping test-product symlink" >&2
  exit 1
fi
rm "$IOS_PRODUCTS/escaping-product"

(
  # shellcheck disable=SC1091
  source "$ROOT/scripts/lib-mobile-release-join-artifacts.sh"
  # shellcheck disable=SC1091
  source "$ROOT/scripts/lib-mobile-release-artifact-reuse.sh"
  # shellcheck disable=SC1091
  source "$ROOT/scripts/lib-mobile-release-join-ui.sh"
  export NVPN_RELEASE_JOIN_REUSE_ARTIFACTS=1
  NVPN_IOS_TEAM_ID=ABCDE12345
  NVPN_DEFAULT_IOS_BUNDLE_ID="$PACKAGE"
  PRIVATE_DIR="$TMP_ROOT/join-private"
  RELEASE_JOIN_IOS_XCTESTRUN="$IOS_XCTESTRUN"
  RELEASE_JOIN_IOS_UDID=fixture-device
  RELEASE_JOIN_DELIVERY_WAIT_SECS=15
  RELEASE_JOIN_CAMERA_WAIT_SECS=30
  mkdir -p "$PRIVATE_DIR"
  base_sha="$(shasum -a 256 "$IOS_XCTESTRUN" | awk '{print $1}')"
  command_file="$TMP_ROOT/join-command.bin"
  release_join_ios_test_command \
    testManualJoinAndRequireRosterCompletion \
    "NVPN_RELEASE_JOIN_ADMIN_ID=npub1fixture" \
    "NVPN_RELEASE_JOIN_NETWORK_ID=fixture-network" \
    >"$command_file"
  python3 - "$command_file" "$IOS_XCTESTRUN" "$base_sha" <<'PY'
import hashlib
import pathlib
import plistlib
import sys

command_path, base_path, base_sha = sys.argv[1:]
command = pathlib.Path(command_path).read_bytes().split(b"\0")
command = [value.decode() for value in command if value]
if "-xctestrun" not in command or "test-without-building" not in command:
    raise SystemExit("strict join command does not use xctestrun test-without-building")
if "-project" in command or "build-for-testing" in command:
    raise SystemExit("strict join command retained a rebuild path")
case_path = pathlib.Path(command[command.index("-xctestrun") + 1])
payload = plistlib.load(case_path.open("rb"))["NostrVpnIosUITests"]
environment = payload["EnvironmentVariables"]
expected = {
    "NVPN_RELEASE_JOIN_BLACKBOX": "1",
    "NVPN_RELEASE_JOIN_ADMIN_ID": "npub1fixture",
    "NVPN_RELEASE_JOIN_NETWORK_ID": "fixture-network",
}
for name, value in expected.items():
    if environment.get(name) != value:
        raise SystemExit(f"strict join xctestrun omitted {name}")
actual_base_sha = hashlib.sha256(pathlib.Path(base_path).read_bytes()).hexdigest()
if actual_base_sha != base_sha:
    raise SystemExit("strict join mutated the byte-validated base xctestrun")
PY
)

python3 - \
  "$ROOT/scripts/mobile-release-join-e2e.sh" \
  "$ROOT/scripts/lib-mobile-release-join-artifacts.sh" \
  "$ROOT/scripts/lib-mobile-release-artifact-reuse.sh" \
  "$ROOT/scripts/lib-mobile-release-join-ui.sh" \
  "$ROOT/scripts/release-gate.sh" <<'PY'
import pathlib
import sys

gate, artifacts, reuse, ui, release = [
    pathlib.Path(path).read_text(encoding="utf-8") for path in sys.argv[1:]
]
validation = gate.index("release_join_validate_reused_artifacts")
arm = gate.index("RELEASE_JOIN_DEVICE_MUTATION_ALLOWED=1")
android_install = gate.index("release_join_prepare_android_release", validation)
ios_install = gate.index("release_join_prepare_ios_release", validation)
if not validation < arm < android_install < ios_install:
    raise SystemExit("Release join does not validate both artifacts before mutation")
if '[[ "${RELEASE_JOIN_DEVICE_MUTATED:-0}" -eq 1 ]]' not in gate:
    raise SystemExit("prevalidation failure can still mutate devices during cleanup")
for required in (
    "NVPN_RELEASE_JOIN_REUSE_ARTIFACTS=1",
    "NVPN_RELEASE_JOIN_ANDROID_APK=",
    "NVPN_RELEASE_JOIN_ANDROID_RECEIPT=",
    "NVPN_RELEASE_JOIN_ANDROID_FIPS_METADATA_RECEIPT=",
    "NVPN_RELEASE_JOIN_IOS_APP_PATH=",
    "NVPN_RELEASE_JOIN_IOS_DERIVED_DATA=",
    "NVPN_RELEASE_JOIN_IOS_XCTESTRUN=",
    "NVPN_RELEASE_JOIN_IOS_RECEIPT=",
    "NVPN_RELEASE_JOIN_IOS_FIPS_METADATA_RECEIPT=",
):
    if required not in release:
        raise SystemExit(f"release gate does not wire strict artifact reuse: {required}")
for required in (
    'export NVPN_MOBILE_ANDROID_RELEASE_RECEIPT="$mobile_artifact_receipt_dir/android.json"',
    'export NVPN_MOBILE_IOS_RELEASE_RECEIPT="$mobile_artifact_receipt_dir/ios.json"',
    'rm -f \\\n    "$NVPN_MOBILE_ANDROID_RELEASE_RECEIPT"',
):
    if required not in release:
        raise SystemExit("release gate can reuse a stale prior-run receipt")
strict_android = artifacts.split(
    "if release_join_reuse_artifacts; then", 1
)[1].split("else", 1)[0]
for forbidden in ("run-android", "build-for-testing"):
    if forbidden in strict_android:
        raise SystemExit(f"strict Android reuse can rebuild through {forbidden}")
if "-xctestrun \"$case_xctestrun\"" not in ui:
    raise SystemExit("strict iOS join does not use its byte-validated xctestrun")
if "test-without-building" not in ui:
    raise SystemExit("strict iOS join no longer uses test-without-building")
for required in (
    "validate-android",
    "validate-ios",
    "release_join_validate_android_reuse",
    "release_join_validate_ios_reuse",
    "selected phone",
):
    if required not in reuse:
        raise SystemExit(f"strict artifact validator is missing {required}")
PY

echo "mobile Release exact-artifact reuse/tamper harness passed"
