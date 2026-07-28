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
app_sha = "a" * 40
app_tree = "b" * 40
fips_sha = "c" * 40
fips_tree = "d" * 40
version = "0.4.45"

android = {
    "artifact": "Android Release APK",
    "apkSha256": apk_hash,
    "installedApkSha256": apk_hash,
    "signerCertificateSha256": "e" * 64,
    "appGitSha": app_sha,
    "appGitTree": app_tree,
    "fipsGitSha": fips_sha,
    "fipsGitTree": fips_tree,
    "package": "fi.siriusbusiness.nvpn",
    "replacementInstall": True,
    "replacementInstallVerified": True,
    "debuggable": False,
    "canonicalPackageCount": 1,
    "canonicalProcessCount": 1,
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
    "appGitSha": app_sha,
    "appGitTree": app_tree,
    "appVersion": "4.1.5",
    "fipsGitSha": fips_sha,
    "fipsGitTree": fips_tree,
    "fipsVersion": version,
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
            "verboseVersion": f"nvpn 4.1.5; fips 0.4.45 (rev {fips_sha[:10]})",
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
    "appGitSha": app_sha,
    "appGitTree": app_tree,
    "appVersion": "4.1.5",
    "fipsGitSha": fips_sha,
    "fipsGitTree": fips_tree,
    "fipsVersion": version,
    "cliShortVersion": "nvpn 4.1.5",
    "cliVerboseVersion": f"nvpn 4.1.5; fips 0.4.45 (rev {fips_sha[:10]})",
    "artifacts": {
        "app": {"file": "nostr-vpn", "sha256": "4" * 64, "size": 40},
        "cli": {"file": "nvpn", "sha256": "5" * 64, "size": 50},
    },
}
for name, value in (
    ("android.json", android),
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
  --android-install-receipt "$WORK/android.json"
  --android-apk "$WORK/app-release.apk"
  --expected-app-sha aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  --expected-app-tree bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  --expected-fips-sha cccccccccccccccccccccccccccccccccccccccc
  --expected-fips-tree dddddddddddddddddddddddddddddddddddddddd
  --expected-fips-version 0.4.45
)

python3 "$VERIFIER" create \
  --platform windows \
  --desktop-receipt "$WORK/windows.json" \
  --phase-evidence "$WORK/phase-windows.json" \
  "${common[@]}" \
  --output "$WORK/windows-summary.json"
python3 "$VERIFIER" validate \
  --platform windows \
  --receipt "$WORK/windows-summary.json"

python3 "$VERIFIER" create \
  --platform linux \
  --desktop-receipt "$WORK/linux.json" \
  --phase-evidence "$WORK/phase-linux.json" \
  "${common[@]}" \
  --output "$WORK/linux-summary.json"
python3 "$VERIFIER" validate \
  --platform linux \
  --receipt "$WORK/linux-summary.json"

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

printf 'tamper' >>"$WORK/app-release.apk"
if python3 "$VERIFIER" validate-android \
  --receipt "$WORK/android.json" \
  --apk "$WORK/app-release.apk" \
  --expected-app-sha aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --expected-app-tree bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  --expected-fips-sha cccccccccccccccccccccccccccccccccccccccc \
  --expected-fips-tree dddddddddddddddddddddddddddddddddddddddd \
  >/dev/null 2>&1
then
  echo "receipt verifier accepted a changed APK" >&2
  exit 1
fi

echo "DESKTOP_MOBILE_MANUAL_JOIN_RECEIPT_HARNESS_OK"
