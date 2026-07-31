#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFIER="$ROOT/scripts/desktop_mobile_manual_join_receipt.py"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/nvpn-desktop-mobile-receipt.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

python3 - "$WORK" <<'PY'
import hashlib
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
apk = root / "app-release.apk"
apk.write_bytes(b"exact signed APK test bytes")
apk_hash = hashlib.sha256(apk.read_bytes()).hexdigest()
metadata = root / "android-fips-metadata.json"
metadata.write_bytes(b'{"exact":"android FIPS linkage"}\n')
metadata_hash = hashlib.sha256(metadata.read_bytes()).hexdigest()
desktop_app_sha = "a" * 40
desktop_app_tree = "b" * 40
desktop_fips_sha = "c" * 40
desktop_fips_tree = "d" * 40
desktop_fips_version = "0.4.45"
android_app_sha = "6" * 40
android_app_tree = "7" * 40
android_fips_sha = "8" * 40
android_fips_tree = "9" * 40
android_fips_version = "0.4.49"

android_install = {
    "artifact": "Android Release APK",
    "apkSha256": apk_hash,
    "installedApkSha256": apk_hash,
    "signerCertificateSha256": "e" * 64,
    "appGitSha": android_app_sha,
    "appGitTree": android_app_tree,
    "fipsGitSha": android_fips_sha,
    "fipsGitTree": android_fips_tree,
    "package": "fi.siriusbusiness.nvpn",
    "replacementInstall": True,
    "replacementInstallVerified": True,
    "debuggable": False,
    "canonicalPackageCount": 1,
    "canonicalProcessCount": 1,
}
android_artifact = {
    "receiptSchema": 2,
    "artifactType": "Android Release APK",
    "aabSha256": "a" * 64,
    "apkDerivedFromAab": True,
    "bundleReceiptSha256": "b" * 64,
    "bundletoolSha256": "c" * 64,
    "bundletoolVersion": "1.18.3",
    "apkSha256": apk_hash,
    "installedApkSha256": apk_hash,
    "signerCertificateSha256": "e" * 64,
    "appGitSha": android_app_sha,
    "appGitTree": android_app_tree,
    "fipsGitSha": android_fips_sha,
    "fipsGitTree": android_fips_tree,
    "fipsCoreVersion": android_fips_version,
    "fipsCargoMetadataReceiptSha256": metadata_hash,
    "package": "fi.siriusbusiness.nvpn",
    "replacementInstall": True,
    "companySigningVerified": True,
    "debuggable": False,
}
phase = {
    "schema": 1,
    "platform": "windows",
    "completionDeadlineSeconds": 15,
    "publicUiOnly": True,
    "privateStateRead": False,
    "fixtureInvoked": False,
    "appLaunchArgumentsOrEnvironment": False,
    "acceptedSelectorSemantics": "participant-state-not-pending",
    "desktopAdminPixelJoiner": {
        "desktopAccepted": True,
        "pixelAccepted": True,
        "desktopRelaunchAccepted": True,
        "pixelRelaunchAccepted": True,
        "deliveryMilliseconds": 912,
    },
    "pixelAdminDesktopJoiner": {
        "desktopAccepted": True,
        "pixelAccepted": True,
        "desktopRelaunchAccepted": True,
        "pixelRelaunchAccepted": True,
        "deliveryMilliseconds": 1103,
    },
}
windows = {
    "schema": 1,
    "platform": "windows",
    "configuration": "Release",
    "builtOnWindowsVm": True,
    "appGitSha": desktop_app_sha,
    "appGitTree": desktop_app_tree,
    "appVersion": "4.1.5",
    "fipsGitSha": desktop_fips_sha,
    "fipsGitTree": desktop_fips_tree,
    "fipsVersion": desktop_fips_version,
    "artifacts": {
        "app": {"file": "NostrVpn.Windows.exe", "sha256": "1" * 64, "size": 10},
        "appCore": {
            "file": "nostr_vpn_app_core.dll",
            "sha256": "2" * 64,
            "size": 20,
        },
        "cli": {
            "file": "nvpn.exe",
            "sha256": "3" * 64,
            "size": 30,
            "shortVersion": "nvpn 4.1.5",
            "verboseVersion": (
                "nvpn 4.1.5; fips 0.4.45 "
                f"(rev {desktop_fips_sha[:10]})"
            ),
        },
    },
}
linux = {
    "schema": 2,
    "builderMode": "remote-native",
    "builtOnHostMac": False,
    "builtOnRemoteVm": True,
    "builderHostOs": "Linux",
    "builderHostArchitecture": "x86_64",
    "containerImageId": f"sha256:{'1' * 64}",
    "dockerfileSha256": "2" * 64,
    "containerPayloadSha256": "3" * 64,
    "dockerPlatform": "linux/amd64",
    "target": "x86_64-unknown-linux-gnu",
    "appGitSha": desktop_app_sha,
    "appGitTree": desktop_app_tree,
    "appVersion": "4.1.5",
    "fipsGitSha": desktop_fips_sha,
    "fipsGitTree": desktop_fips_tree,
    "fipsVersion": desktop_fips_version,
    "cliShortVersion": "nvpn 4.1.5",
    "cliVerboseVersion": (
        "nvpn 4.1.5; fips 0.4.45 "
        f"(rev {desktop_fips_sha[:10]})"
    ),
    "artifacts": {
        "app": {"file": "nostr-vpn", "sha256": "4" * 64, "size": 40},
        "cli": {"file": "nvpn", "sha256": "5" * 64, "size": 50},
    },
}
for name, value in (
    ("android-install.json", android_install),
    ("android-artifact.json", android_artifact),
    ("phase-windows.json", phase),
    ("windows.json", windows),
    ("linux.json", linux),
):
    (root / name).write_text(
        json.dumps(value, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
phase["platform"] = "linux"
(root / "phase-linux.json").write_text(
    json.dumps(phase, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY

common=(
  --android-artifact-receipt "$WORK/android-artifact.json"
  --android-install-receipt "$WORK/android-install.json"
  --android-fips-metadata-receipt "$WORK/android-fips-metadata.json"
  --android-apk "$WORK/app-release.apk"
  --expected-desktop-app-sha aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  --expected-desktop-app-tree bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  --expected-desktop-fips-sha cccccccccccccccccccccccccccccccccccccccc
  --expected-desktop-fips-tree dddddddddddddddddddddddddddddddddddddddd
  --expected-desktop-fips-version 0.4.45
  --expected-android-app-sha 6666666666666666666666666666666666666666
  --expected-android-app-tree 7777777777777777777777777777777777777777
  --expected-android-fips-sha 8888888888888888888888888888888888888888
  --expected-android-fips-tree 9999999999999999999999999999999999999999
  --expected-android-fips-version 0.4.49
)

python3 "$VERIFIER" create \
  --platform windows \
  --desktop-receipt "$WORK/windows.json" \
  --phase-evidence "$WORK/phase-windows.json" \
  "${common[@]}" \
  --output "$WORK/windows-summary.json"
python3 "$VERIFIER" validate \
  --platform windows \
  --receipt "$WORK/windows-summary.json" \
  --desktop-receipt "$WORK/windows.json" \
  --phase-evidence "$WORK/phase-windows.json" \
  "${common[@]}"

python3 "$VERIFIER" create \
  --platform linux \
  --desktop-receipt "$WORK/linux.json" \
  --phase-evidence "$WORK/phase-linux.json" \
  "${common[@]}" \
  --output "$WORK/linux-summary.json"
python3 "$VERIFIER" validate \
  --platform linux \
  --receipt "$WORK/linux-summary.json" \
  --desktop-receipt "$WORK/linux.json" \
  --phase-evidence "$WORK/phase-linux.json" \
  "${common[@]}"

expect_rejected() {
  local label="$1" phase="$2"
  if python3 "$VERIFIER" create \
    --platform windows \
    --desktop-receipt "$WORK/windows.json" \
    --phase-evidence "$phase" \
    "${common[@]}" \
    --output "$WORK/rejected.json" >/dev/null 2>&1
  then
    echo "receipt verifier accepted invalid evidence: $label" >&2
    exit 1
  fi
}

python3 - "$WORK/phase-windows.json" "$WORK" <<'PY'
import copy
import json
import pathlib
import sys

source = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
root = pathlib.Path(sys.argv[2])
cases = {}
pending = copy.deepcopy(source)
pending["acceptedSelectorSemantics"] = "row-exists"
cases["pending.json"] = pending
relaunch = copy.deepcopy(source)
relaunch["desktopAdminPixelJoiner"]["desktopRelaunchAccepted"] = False
cases["no-relaunch.json"] = relaunch
slow = copy.deepcopy(source)
slow["pixelAdminDesktopJoiner"]["deliveryMilliseconds"] = 15001
cases["slow.json"] = slow
fixture = copy.deepcopy(source)
fixture["fixtureInvoked"] = True
cases["fixture.json"] = fixture
for name, value in cases.items():
    (root / name).write_text(
        json.dumps(value, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
PY

expect_rejected "pending row" "$WORK/pending.json"
expect_rejected "missing relaunch acceptance" "$WORK/no-relaunch.json"
expect_rejected "delivery over 15 seconds" "$WORK/slow.json"
expect_rejected "fixture acceptance" "$WORK/fixture.json"

python3 - "$WORK/windows-summary.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
value = json.loads(path.read_text(encoding="utf-8"))
assert value["schema"] == 2
assert value["artifact"]["desktop"]["appGitSha"] == "a" * 40
assert value["artifact"]["android"]["appGitSha"] == "6" * 40
assert value["artifact"]["desktop"]["fipsGitSha"] == "c" * 40
assert value["artifact"]["android"]["fipsGitSha"] == "8" * 40
assert value["artifact"]["desktop"]["artifactReceiptSha256"]
assert value["artifact"]["android"]["artifactReceiptSha256"]
assert value["artifact"]["android"]["installReceiptSha256"]
PY

cp "$WORK/android-artifact.json" "$WORK/android-artifact.original.json"
python3 - "$WORK/android-artifact.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
value = json.loads(path.read_text(encoding="utf-8"))
value["aabSha256"] = "0" * 64
path.write_text(json.dumps(value) + "\n", encoding="utf-8")
PY
if python3 "$VERIFIER" validate \
  --platform windows \
  --receipt "$WORK/windows-summary.json" \
  --desktop-receipt "$WORK/windows.json" \
  --phase-evidence "$WORK/phase-windows.json" \
  "${common[@]}" >/dev/null 2>&1
then
  echo "receipt verifier accepted a changed Android artifact receipt digest" >&2
  exit 1
fi
mv "$WORK/android-artifact.original.json" "$WORK/android-artifact.json"

printf 'tamper' >>"$WORK/app-release.apk"
if python3 "$VERIFIER" validate-android \
  --receipt "$WORK/android-install.json" \
  --android-artifact-receipt "$WORK/android-artifact.json" \
  --android-fips-metadata-receipt "$WORK/android-fips-metadata.json" \
  --apk "$WORK/app-release.apk" \
  --expected-android-app-sha 6666666666666666666666666666666666666666 \
  --expected-android-app-tree 7777777777777777777777777777777777777777 \
  --expected-android-fips-sha 8888888888888888888888888888888888888888 \
  --expected-android-fips-tree 9999999999999999999999999999999999999999 \
  --expected-android-fips-version 0.4.49 \
  >/dev/null 2>&1
then
  echo "receipt verifier accepted a changed APK" >&2
  exit 1
fi

echo "DESKTOP_MOBILE_MANUAL_JOIN_RECEIPT_HARNESS_OK"
