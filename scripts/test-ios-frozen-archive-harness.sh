#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$ROOT/scripts/ios_frozen_archive.py"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/nvpn-ios-frozen-archive.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

PRODUCTS="$TMP_ROOT/DerivedData/Build/Products"
APP="$TMP_ROOT/frozen/Payload/Nostr VPN.app"
RUNNER="$PRODUCTS/Release-iphoneos/NostrVpnIosUITests-Runner.app"
TEST_BUNDLE="$RUNNER/PlugIns/NostrVpnIosUITests.xctest"
TUNNEL="$APP/PlugIns/Nostr VPN Tunnel.appex"
SOURCE="$PRODUCTS/NostrVpnIos_fixture.xctestrun"
PRIVATE_DIR="$TMP_ROOT/private"
OUTPUT="$PRIVATE_DIR/network-case.xctestrun"
mkdir -p "$TEST_BUNDLE" "$TUNNEL" "$PRIVATE_DIR"
chmod 700 "$PRIVATE_DIR"
printf 'app\n' >"$APP/Nostr VPN"
printf 'tunnel\n' >"$TUNNEL/Nostr VPN Tunnel"
printf 'test bundle\n' >"$TEST_BUNDLE/NostrVpnIosUITests"

python3 - "$SOURCE" <<'PY'
import pathlib
import plistlib
import sys

path = pathlib.Path(sys.argv[1])
payload = {
    "CodeCoverageBuildableInfos": [
        {
            "Name": "Nostr VPN.app",
            "ProductPaths": [
                "__TESTROOT__/Release-iphoneos/Nostr VPN.app/Nostr VPN"
            ],
        },
        {
            "Name": "Nostr VPN Tunnel.appex",
            "ProductPaths": [
                "__TESTROOT__/Release-iphoneos/Nostr VPN Tunnel.appex/Nostr VPN Tunnel"
            ],
        },
        {
            "Name": "NostrVpnIosUITests.xctest",
            "ProductPaths": [
                "__TESTROOT__/Release-iphoneos/NostrVpnIosUITests-Runner.app/PlugIns/NostrVpnIosUITests.xctest/NostrVpnIosUITests"
            ],
        },
    ],
    "TestConfigurations": [
        {
            "Name": "Test Scheme Action",
            "TestTargets": [
                {
                    "BlueprintName": "NostrVpnIosUITests",
                    "ClangProfileDataDirectoryPath": "__DERIVEDDATA__/Build/ProfileData/fixture-run",
                    "DependentProductPaths": [
                        "__TESTROOT__/Release-iphoneos/Nostr VPN.app",
                        "__TESTHOST__/PlugIns/NostrVpnIosUITests.xctest",
                    ],
                    "EnvironmentVariables": {
                        "NVPN_RELEASE_JOIN_NETWORK_ID": "stale-private-value",
                    },
                    "ProductModuleName": "NostrVpnIosUITests",
                    "TestBundlePath": "__TESTHOST__/PlugIns/NostrVpnIosUITests.xctest",
                    "TestHostPath": "__TESTROOT__/Release-iphoneos/NostrVpnIosUITests-Runner.app",
                    "TestingEnvironmentVariables": {
                        "DYLD_FRAMEWORK_PATH": "__TESTROOT__/Release-iphoneos",
                        "DYLD_INSERT_LIBRARIES": "__TESTHOST__/Frameworks/TestSupport.dylib",
                        "PROFILE_ROOT": "__DERIVEDDATA__/Build/ProfileData",
                    },
                    "UITargetAppCommandLineArguments": [
                        "--test-only-launch-payload",
                    ],
                    "UITargetAppEnvironmentVariables": {
                        "NVPN_TEST_ONLY_APP_PAYLOAD": "must-not-survive",
                    },
                    "UITargetAppPath": "__TESTROOT__/Release-iphoneos/Nostr VPN.app",
                }
            ],
        }
    ],
}
with path.open("wb") as handle:
    plistlib.dump(payload, handle)
PY

printf '%s\0' \
  NVPN_RELEASE_JOIN_NETWORK_ID= \
  NVPN_RELEASE_JOIN_NETWORK_ID=fixture-network \
  NVPN_RELEASE_JOIN_BLACKBOX=1 \
  | python3 "$TOOL" rewrite-xctestrun \
    --source "$SOURCE" \
    --output "$OUTPUT" \
    --products-root "$PRODUCTS" \
    --target-app "$APP" \
    --environment-stdin0

python3 - \
  "$ROOT/scripts/mobile_release_artifact_receipt.py" \
  "$SOURCE" "$OUTPUT" "$APP" "$RUNNER" "$TEST_BUNDLE" "$TUNNEL" <<'PY'
import importlib.util
import pathlib
import plistlib
import stat
import sys

validator_path = sys.argv[1]
source, output, app, runner, test_bundle, tunnel = map(
    pathlib.Path, sys.argv[2:]
)
spec = importlib.util.spec_from_file_location("artifact_receipt", validator_path)
validator = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(validator)
validator.validate_xctestrun(source)
validator.validate_xctestrun(output)
source_payload = plistlib.load(source.open("rb"))
source_target = source_payload["TestConfigurations"][0]["TestTargets"][0]
if "__TESTROOT__" not in source_target["TestHostPath"]:
    raise SystemExit("xctestrun rewrite mutated its immutable source")
payload = plistlib.load(output.open("rb"))
target = payload["TestConfigurations"][0]["TestTargets"][0]
expected = {
    "TestBundlePath": str(test_bundle.resolve()),
    "TestHostPath": str(runner.resolve()),
    "UITargetAppPath": str(app.resolve()),
}
for key, value in expected.items():
    if target.get(key) != value:
        raise SystemExit(f"rewritten xctestrun has the wrong {key}")
dependent = target.get("DependentProductPaths")
if dependent != [
    str(tunnel.resolve()),
    str(app.resolve()),
    str(runner.resolve()),
    str(test_bundle.resolve()),
]:
    raise SystemExit("rewritten xctestrun has the wrong dependent products")
for value in [*expected.values(), *dependent]:
    if not value.startswith("/") or "__TEST" in value:
        raise SystemExit("rewritten xctestrun retained a relocatable path")
environment = target.get("EnvironmentVariables", {})
if environment.get("NVPN_RELEASE_JOIN_NETWORK_ID") != "fixture-network":
    raise SystemExit("xctestrun environment was not scrubbed then replaced")
if environment.get("NVPN_RELEASE_JOIN_BLACKBOX") != "1":
    raise SystemExit("xctestrun runner environment is incomplete")
if target.get("UITargetAppCommandLineArguments") != []:
    raise SystemExit("xctestrun retained app launch arguments")
if target.get("UITargetAppEnvironmentVariables") != {}:
    raise SystemExit("xctestrun retained app launch environment")
for item in payload["CodeCoverageBuildableInfos"]:
    for path in item["ProductPaths"]:
        if not path.startswith("/") or "__TEST" in path:
            raise SystemExit("rewritten xctestrun retained a coverage placeholder")
expected_profile_root = str((runner.parents[2] / "ProfileData").resolve())
expected_clang_profile = str(
    (runner.parents[2] / "ProfileData" / "fixture-run").resolve()
)
if target["ClangProfileDataDirectoryPath"] != expected_clang_profile:
    raise SystemExit("rewritten xctestrun retained __DERIVEDDATA__")
testing_environment = target["TestingEnvironmentVariables"]
if testing_environment["DYLD_FRAMEWORK_PATH"] != str(
    runner.parent.resolve()
):
    raise SystemExit("rewritten xctestrun retained temp-root framework paths")
if testing_environment["DYLD_INSERT_LIBRARIES"] != str(
    (runner / "Frameworks" / "TestSupport.dylib").resolve()
):
    raise SystemExit("rewritten xctestrun retained temp-host library paths")
if testing_environment["PROFILE_ROOT"] != expected_profile_root:
    raise SystemExit("rewritten xctestrun retained derived-data paths")
if stat.S_IMODE(output.stat().st_mode) != 0o600:
    raise SystemExit("private xctestrun is not mode 0600")
PY

if python3 "$TOOL" rewrite-xctestrun \
  --source "$SOURCE" \
  --output "$PRIVATE_DIR/invalid.xctestrun" \
  --products-root "$PRODUCTS" \
  --target-app "$APP" \
  --environment invalid-name=value >/dev/null 2>&1
then
  echo "Frozen iOS helper accepted an invalid runner variable" >&2
  exit 1
fi

DESTINATION_DIR="$TMP_ROOT/destination-products"
mkdir -p "$DESTINATION_DIR"
python3 - "$SOURCE" "$DESTINATION_DIR" <<'PY'
import pathlib
import plistlib
import sys

source, output_dir = map(pathlib.Path, sys.argv[1:])
for name, value in (
    ("boolean", True),
    ("integer", 1),
    ("string", "true"),
):
    payload = plistlib.load(source.open("rb"))
    payload["TestConfigurations"][0]["TestTargets"][0][
        "UseDestinationArtifacts"
    ] = value
    with (output_dir / f"{name}.xctestrun").open("wb") as handle:
        plistlib.dump(payload, handle)
PY
for destination_source in "$DESTINATION_DIR"/*.xctestrun; do
  if python3 "$TOOL" rewrite-xctestrun \
    --source "$destination_source" \
    --output "$PRIVATE_DIR/destination-products-output.xctestrun" \
    --products-root "$PRODUCTS" \
    --target-app "$APP" >/dev/null 2>&1
  then
    echo "Frozen iOS helper accepted destination-side test products" >&2
    exit 1
  fi
done

ARCHIVE_RECEIPT="$TMP_ROOT/archive.json"
ADHOC_RECEIPT="$TMP_ROOT/adhoc.json"
MOBILE_RECEIPT="$TMP_ROOT/mobile.json"
SEALED_MOBILE_RECEIPT="$TMP_ROOT/sealed-mobile.json"
GATE_SEAL="$TMP_ROOT/gate-seal.json"
ARCHIVE_CLEAN="$TMP_ROOT/archive-clean.json"
ADHOC_CLEAN="$TMP_ROOT/adhoc-clean.json"
MOBILE_CLEAN="$TMP_ROOT/mobile-clean.json"

python3 - \
  "$ARCHIVE_RECEIPT" "$ADHOC_RECEIPT" "$MOBILE_RECEIPT" <<'PY'
import hashlib
import json
import pathlib
import sys

archive_path, adhoc_path, mobile_path = map(pathlib.Path, sys.argv[1:])
identity = {
    "appBundleIdentifier": "example.nvpn",
    "buildNumber": "4001005",
    "marketingVersion": "4.1.5",
}
signing = {
    "appCodeDirectoryHash": "a" * 40,
    "appProvisioningProfileSha256": "b" * 64,
    "packetTunnelCodeDirectoryHash": "c" * 40,
    "packetTunnelProvisioningProfileSha256": "d" * 64,
    "signerCertificateSha256": "e" * 64,
    "signingTeamIdentifier": "AAAAAAAAAA",
}
archive = {
    "receiptSchema": 1,
    "artifactType": "iOS frozen App Store xcarchive",
    "appGitSha": "1" * 40,
    "appGitTree": "2" * 40,
    "archiveAppBundleTreeSha256": "b" * 64,
    "archivePathSha256": "c" * 64,
    "archiveTreeSha256": "3" * 64,
    "fipsCoreVersion": "1.2.3",
    "fipsCargoMetadataReceiptPathSha256": "8" * 64,
    "fipsCargoMetadataReceiptSha256": "9" * 64,
    "fipsCheckoutPathSha256": "a" * 64,
    "fipsGitSha": "4" * 40,
    "fipsGitTree": "5" * 40,
    "identity": identity,
}
adhoc = {
    "receiptSchema": 1,
    "artifactType": "iOS export from frozen xcarchive",
    "appBundleTreeSha256": "6" * 64,
    "appGitSha": archive["appGitSha"],
    "appGitTree": archive["appGitTree"],
    "archiveReceiptSha256": "",
    "archiveTreeSha256": archive["archiveTreeSha256"],
    "distribution": "release-testing",
    "fipsCoreVersion": archive["fipsCoreVersion"],
    "fipsGitSha": archive["fipsGitSha"],
    "fipsGitTree": archive["fipsGitTree"],
    "identity": identity,
    "ipaPathSha256": "d" * 64,
    "ipaSha256": "e" * 64,
    "signing": signing,
}
mobile = {
    "receiptSchema": 2,
    "artifactType": "iOS company Ad Hoc Release app",
    "appBundleTreeSha256": adhoc["appBundleTreeSha256"],
    "appCodeDirectoryHash": signing["appCodeDirectoryHash"],
    "appExecutableSha256": "b" * 64,
    "appGitSha": archive["appGitSha"],
    "appGitTree": archive["appGitTree"],
    "appPathSha256": "c" * 64,
    "appProvisioningProfileSha256": signing[
        "appProvisioningProfileSha256"
    ],
    "cashuAndPaidExitCompiled": False,
    "companySigningVerified": True,
    "debuggable": False,
    "derivedDataPathSha256": "d" * 64,
    "fipsCoreVersion": archive["fipsCoreVersion"],
    "fipsCargoMetadataReceiptPathSha256": archive[
        "fipsCargoMetadataReceiptPathSha256"
    ],
    "fipsCargoMetadataReceiptSha256": archive[
        "fipsCargoMetadataReceiptSha256"
    ],
    "fipsCheckoutPathSha256": archive["fipsCheckoutPathSha256"],
    "fipsDependenciesForcedRebuilt": True,
    "fipsGitSha": archive["fipsGitSha"],
    "fipsGitTree": archive["fipsGitTree"],
    "installedBundleIdentifier": identity["appBundleIdentifier"],
    "installedBuildNumber": identity["buildNumber"],
    "installedMarketingVersion": identity["marketingVersion"],
    "packetTunnelExecutableSha256": "e" * 64,
    "packetTunnelCodeDirectoryHash": signing[
        "packetTunnelCodeDirectoryHash"
    ],
    "packetTunnelProvisioningProfileSha256": signing[
        "packetTunnelProvisioningProfileSha256"
    ],
    "selectedPhysicalDevice": {
        "deviceIdentifierSha256": "7" * 64,
        "explicitPhysicalDeviceVerified": True,
        "model": "Fixture iPhone",
        "platform": "iOS",
        "productType": "Fixture1,1",
    },
    "selectedPhysicalDeviceIdentifierSha256": "7" * 64,
    "signerCertificateSha256": signing["signerCertificateSha256"],
    "testProductsPathSha256": "f" * 64,
    "testProductsTreeSha256": "0" * 64,
    "treeSha256": adhoc["appBundleTreeSha256"],
    "updaterCompiled": False,
    "paidExitWalletWorkerCompiled": False,
    "xctestrunPathSha256": "1" * 64,
    "xctestrunSha256": "2" * 64,
}
archive_path.write_text(
    json.dumps(archive, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
adhoc["archiveReceiptSha256"] = hashlib.sha256(
    archive_path.read_bytes()
).hexdigest()
for path, payload in ((adhoc_path, adhoc), (mobile_path, mobile)):
    path.write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
PY
cp "$ARCHIVE_RECEIPT" "$ARCHIVE_CLEAN"
cp "$ADHOC_RECEIPT" "$ADHOC_CLEAN"
cp "$MOBILE_RECEIPT" "$MOBILE_CLEAN"

restore_receipts() {
  cp "$ARCHIVE_CLEAN" "$ARCHIVE_RECEIPT"
  cp "$ADHOC_CLEAN" "$ADHOC_RECEIPT"
  cp "$MOBILE_CLEAN" "$MOBILE_RECEIPT"
}

GATE_ARGS=(
  --required-gate wireguard-exit-and-five-dns-policies
  --required-gate background-foreground-and-rapid-start-stop
  --required-gate wifi-hotspot-underlay-roaming
  --required-gate bidirectional-mobile-qr-and-manual-join
  --required-gate desktop-mobile-manual-join
)

seal_gate() {
  python3 "$TOOL" seal-gate \
    --archive-receipt "$ARCHIVE_RECEIPT" \
    --adhoc-receipt "$ADHOC_RECEIPT" \
    --mobile-receipt "$MOBILE_RECEIPT" \
    --sealed-mobile-receipt "$SEALED_MOBILE_RECEIPT" \
    --output "$GATE_SEAL" \
    "${GATE_ARGS[@]}"
}

validate_gate() {
  python3 "$TOOL" validate-gate-seal \
    --archive-receipt "$ARCHIVE_RECEIPT" \
    --adhoc-receipt "$ADHOC_RECEIPT" \
    --sealed-mobile-receipt "$SEALED_MOBILE_RECEIPT" \
    --gate-seal "$GATE_SEAL" \
    "${GATE_ARGS[@]}"
}

python3 - \
  "$ARCHIVE_RECEIPT" "$ADHOC_RECEIPT" "$MOBILE_RECEIPT" <<'PY'
import json
import pathlib
import sys

for path in map(pathlib.Path, sys.argv[1:]):
    value = json.loads(path.read_text(encoding="utf-8"))
    del value["appGitTree"]
    path.write_text(json.dumps(value, sort_keys=True) + "\n", encoding="utf-8")
PY
if seal_gate >/dev/null 2>&1; then
  echo "Frozen iOS gate accepted matching omitted source evidence" >&2
  exit 1
fi
restore_receipts

python3 - "$ADHOC_RECEIPT" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
value = json.loads(path.read_text(encoding="utf-8"))
del value["archiveReceiptSha256"]
path.write_text(json.dumps(value, sort_keys=True) + "\n", encoding="utf-8")
PY
if seal_gate >/dev/null 2>&1; then
  echo "Frozen iOS gate accepted an omitted archive-receipt link" >&2
  exit 1
fi
restore_receipts

python3 - "$ADHOC_RECEIPT" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
value = json.loads(path.read_text(encoding="utf-8"))
value["archiveReceiptSha256"] = "0" * 64
path.write_text(json.dumps(value, sort_keys=True) + "\n", encoding="utf-8")
PY
if seal_gate >/dev/null 2>&1; then
  echo "Frozen iOS gate accepted a mismatched archive-receipt link" >&2
  exit 1
fi
restore_receipts

seal_gate
validate_gate
[[ "$(stat -f '%Lp' "$GATE_SEAL" 2>/dev/null || stat -c '%a' "$GATE_SEAL")" == 600 ]] \
  || { echo "Frozen iOS gate seal is not mode 0600" >&2; exit 1; }

python3 - "$GATE_SEAL" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
value = json.loads(path.read_text(encoding="utf-8"))
value["mobileArtifactEvidence"]["appCodeDirectoryHash"] = "0" * 40
path.write_text(json.dumps(value, sort_keys=True) + "\n", encoding="utf-8")
PY
if validate_gate >/dev/null 2>&1; then
  echo "Frozen iOS gate accepted altered physical-artifact evidence" >&2
  exit 1
fi
seal_gate

python3 - "$GATE_SEAL" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
value = json.loads(path.read_text(encoding="utf-8"))
del value["mobileArtifactEvidence"]["fipsGitTree"]
path.write_text(json.dumps(value, sort_keys=True) + "\n", encoding="utf-8")
PY
if validate_gate >/dev/null 2>&1; then
  echo "Frozen iOS gate accepted omitted physical-artifact evidence" >&2
  exit 1
fi
seal_gate

python3 - "$SEALED_MOBILE_RECEIPT" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
value = json.loads(path.read_text(encoding="utf-8"))
value["selectedPhysicalDevice"]["model"] = "Altered iPhone"
path.write_text(json.dumps(value, sort_keys=True) + "\n", encoding="utf-8")
PY
if validate_gate >/dev/null 2>&1; then
  echo "Frozen iOS gate accepted an altered sealed physical receipt" >&2
  exit 1
fi
seal_gate

python3 - "$MOBILE_RECEIPT" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
value = json.loads(path.read_text(encoding="utf-8"))
value["appProvisioningProfileSha256"] = "0" * 64
path.write_text(json.dumps(value, sort_keys=True) + "\n", encoding="utf-8")
PY
if seal_gate >/dev/null 2>&1; then
  echo "Frozen iOS gate accepted different physical signing material" >&2
  exit 1
fi

(
  # shellcheck disable=SC1091
  source "$ROOT/scripts/release_common.sh"
  full_head="$(git -C "$ROOT" rev-parse HEAD)"
  NVPN_BUILD_GIT_SHA="$(git_short_sha "$ROOT")"
  pin_exact_release_build_git_sha \
    "$ROOT" "$full_head" "fixture release"
  [[ "$NVPN_BUILD_GIT_SHA" == "$full_head" ]] || {
    echo "Release Git SHA was not normalized before the frozen build" >&2
    exit 1
  }
  NVPN_BUILD_GIT_SHA="000000000000"
  if pin_exact_release_build_git_sha \
    "$ROOT" "$full_head" "fixture release" >/dev/null 2>&1
  then
    echo "Release Git SHA pin accepted an unrelated override" >&2
    exit 1
  fi

  generated_products="$TMP_ROOT/generated-products"
  canonical_plan="$generated_products/NostrVpnIos_fixture.xctestrun"
  external_plan="$TMP_ROOT/external.xctestrun"
  mkdir -p "$generated_products"
  printf 'canonical\n' >"$canonical_plan"
  printf 'external\n' >"$external_plan"
  NVPN_MOBILE_IOS_RELEASE_XCTESTRUN="$external_plan"
  if select_generated_ios_release_xctestrun \
    "$generated_products" "fixture" >/dev/null 2>&1
  then
    echo "Frozen Release accepted an external iOS xctestrun" >&2
    exit 1
  fi
  unset NVPN_MOBILE_IOS_RELEASE_XCTESTRUN
  selected_plan="$(
    select_generated_ios_release_xctestrun \
      "$generated_products" "fixture"
  )"
  [[ "$selected_plan" == "$canonical_plan" ]] || {
    echo "Frozen Release did not select its sole generated xctestrun" >&2
    exit 1
  }
)

python3 - \
  "$ROOT/scripts/ios-build" \
  "$ROOT/scripts/local-release.mjs" \
  "$ROOT/scripts/release-gate.sh" \
  "$ROOT/scripts/lib-mobile-ios-release-network.sh" \
  "$ROOT/scripts/lib-mobile-release-join-ui.sh" \
  "$TOOL" \
  "$ROOT/scripts/ios_xctestrun.py" <<'PY'
import pathlib
import sys

ios_build, local_release, release_gate, network, join, tool, xctestrun = [
    pathlib.Path(path).read_text(encoding="utf-8") for path in sys.argv[1:]
]
for required in (
    "manageAppVersionAndBuildNumber",
    "release-testing",
    "app-store-connect",
    'validate_frozen_gate_seal',
    'app="$(unpack_ipa "$ipa" "$FROZEN_APPSTORE_UNPACK_DIR")"',
):
    if required not in ios_build:
        raise SystemExit(f"frozen iOS build path lacks {required}")
if (
    "<key>manageAppVersionAndBuildNumber</key>\n  <false/>"
    not in ios_build
):
    raise SystemExit("Xcode export may mutate the frozen version or build")
archive = ios_build.split("run_ios_archive() {", 1)[1].split(
    "\nrun_export_archive() {", 1
)[0]
if archive.index("prepare_frozen_revision_args") > archive.index(
    "run_ios_rust"
):
    raise SystemExit("frozen archive builds before pinning the full Git SHA")
if 'BUNDLE_ID" == "$NVPN_BUILTIN_IOS_BUNDLE_ID' not in ios_build:
    raise SystemExit("frozen archive permits non-production app identifiers")
if 'NVPN_APP_VERSION_NAME" == "$source_version' not in ios_build:
    raise SystemExit("frozen archive permits an untracked marketing version")
release_testing = ios_build.split(
    "run_ios_release_testing_export() {", 1
)[1].split("\nrun_ios_export() {", 1)[0]
reuse = release_testing.split('ensure_dir "$FROZEN_DIR"', 1)[0]
if (
    'app="$(unpack_ipa "$ipa" "$FROZEN_ADHOC_UNPACK_DIR")"'
    not in reuse
):
    raise SystemExit("Ad Hoc reuse validates a stale unpack instead of its IPA")
testflight = ios_build.split("run_ios_testflight() {", 1)[1].split(
    '\ncase "${1:-}"', 1
)[0]
if "run_ios_archive" in testflight:
    raise SystemExit("final iOS release path can rebuild after physical tests")
if "NVPN_RELEASE_IOS_FROZEN_ARCHIVE: '1'" not in local_release:
    raise SystemExit("local release does not require the frozen iOS gate")
if release_gate.index("run_mobile_join_e2e_gate\n") > release_gate.index(
    "seal_frozen_ios_release_gate\n"
):
    raise SystemExit("frozen iOS archive is sealed before the join gate")
full_dns = (
    "NVPN_MOBILE_WG_EXIT_DNS_CASES="
    "automatic-profile,cloudflare-doh,quad9-doh,custom-doh,through-exit"
)
if release_gate.count(full_dns) < 2:
    raise SystemExit("release lanes can inherit a focused DNS subset")
for pinned in (
    "NVPN_MOBILE_WG_EXIT_REUSE_IOS_BUILD=0",
    "NVPN_IOS_ACTIVE_TUNNEL_LIFECYCLE_CYCLES=3",
    "NVPN_IOS_RELEASE_NETWORK_BACKGROUND_DWELL_SECS=20",
    "NVPN_MOBILE_UNDERLAY_ASSOCIATION_TIMEOUT_SECS=30",
    "NVPN_MOBILE_UNDERLAY_RECOVERY_MAX_MS=4000",
):
    if pinned not in release_gate:
        raise SystemExit(f"release gate does not pin {pinned}")
for oracle in (
    "NVPN_MOBILE_WG_EXIT_DIRECT_HOST=example.com",
    "NVPN_MOBILE_WG_EXIT_DIRECT_URL=https://example.com/",
    "NVPN_MOBILE_WG_EXIT_EXPECTED_SOURCE_IP=",
    "NVPN_MOBILE_WG_EXIT_RELEASE_BLACKBOX=1",
    "NVPN_MOBILE_WG_EXIT_SOURCE_IP_URL=https://api.ipify.org",
):
    if release_gate.count(oracle) < 4:
        raise SystemExit(f"physical release lanes do not pin {oracle}")
for source in (network, join):
    if "rewrite-xctestrun" not in source:
        raise SystemExit("temp xctestrun bypasses the absolute-path rewriter")
    if "--environment-stdin0" not in source:
        raise SystemExit("private xctestrun inputs remain visible in argv")
    if 'cp "$IOS_RELEASE_NETWORK_XCTESTRUN"' in source:
        raise SystemExit("network xctestrun still uses a relocatable raw copy")
    if 'cp "$RELEASE_JOIN_IOS_XCTESTRUN"' in source:
        raise SystemExit("join xctestrun still uses a relocatable raw copy")
for source, label in ((network, "network"), (release_gate, "join gate")):
    if "select_generated_ios_release_xctestrun" not in source:
        raise SystemExit(f"{label} does not select the generated xctestrun")
    if "NVPN_MOBILE_IOS_RELEASE_XCTESTRUN" in source:
        raise SystemExit(f"{label} still trusts an external xctestrun")
    if "NVPN_MOBILE_IOS_RELEASE_DERIVED_DATA" in source:
        raise SystemExit(f"{label} still trusts external iOS test products")
if "NVPN_MOBILE_IOS_RELEASE_APP_PATH" in release_gate:
    raise SystemExit("join gate still trusts an external frozen-app path")
for required in (
    'target["TestBundlePath"]',
    'target["TestHostPath"]',
    'target["UITargetAppCommandLineArguments"]',
    'target["UITargetAppEnvironmentVariables"]',
    'target["UITargetAppPath"]',
    'target["DependentProductPaths"]',
):
    if required not in xctestrun:
        raise SystemExit(f"xctestrun rewriter omits {required}")
if "from ios_xctestrun import rewrite_xctestrun" not in tool:
    raise SystemExit("frozen archive CLI does not expose the xctestrun rewriter")
PY

echo "Frozen iOS archive fail-closed harness passed"
