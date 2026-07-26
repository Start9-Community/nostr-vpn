#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/nvpn-mobile-provenance.XXXXXX")"
APP_ROOT="$TMP_ROOT/app"
FIPS_ROOT="$TMP_ROOT/fips"
trap 'rm -rf "$TMP_ROOT"' EXIT
mkdir -p "$APP_ROOT" "$FIPS_ROOT/crates/fips-core"
printf 'fixture\n' >"$APP_ROOT/source"
printf '[package]\nname = "fips-core"\nversion = "1.2.3"\n' \
  >"$FIPS_ROOT/crates/fips-core/Cargo.toml"
for repo in "$APP_ROOT" "$FIPS_ROOT"; do
  git -C "$repo" init -q
  git -C "$repo" add .
  git -C "$repo" \
    -c user.name=Harness -c user.email=harness.invalid commit -qm fixture
done

# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/release_common.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib-mobile-android-release-gate.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib-mobile-ios-release-network.sh"
ROOT="$APP_ROOT"
PACKAGE_NAME=fi.siriusbusiness.nvpn
CANONICAL_PACKAGE_NAME="$PACKAGE_NAME"
ANDROID_KEYSTORE_PATH="$TMP_ROOT/release.keystore"
ANDROID_KEYSTORE_PASSWORD=secret
ANDROID_KEY_ALIAS=release
ANDROID_KEY_PASSWORD=secret
NVPN_FIPS_REPO_PATH="$FIPS_ROOT"
NVPN_IOS_EXPECTED_DEVICE_NAME="Expected phone"
NVPN_BUILD_GIT_SHA=""
printf 'keystore\n' >"$ANDROID_KEYSTORE_PATH"

unset NVPN_EXPECTED_ANDROID_SIGNER_CERT_SHA256 NVPN_EXPECTED_FIPS_GIT_SHA
if android_release_require_inputs >"$TMP_ROOT/android-missing.log" 2>&1; then
  echo "Android provenance accepted missing external pins" >&2
  exit 1
fi
grep -Fq 'requires NVPN_EXPECTED_ANDROID_SIGNER_CERT_SHA256' \
  "$TMP_ROOT/android-missing.log"

mkdir -p "$TMP_ROOT/bin"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  "printf 'fixture signer certificate'" \
  >"$TMP_ROOT/bin/keytool"
chmod +x "$TMP_ROOT/bin/keytool"
export PATH="$TMP_ROOT/bin:$PATH"
NVPN_EXPECTED_ANDROID_SIGNER_CERT_SHA256="$(
  printf 'fixture signer certificate' | shasum -a 256 | awk '{print $1}'
)"
NVPN_EXPECTED_FIPS_GIT_SHA=0000000000000000000000000000000000000000
if android_release_require_inputs >"$TMP_ROOT/android-fips.log" 2>&1; then
  echo "Android provenance accepted the wrong FIPS revision" >&2
  exit 1
fi
grep -Fq 'Android Release black-box FIPS mismatch' \
  "$TMP_ROOT/android-fips.log"

unset NVPN_EXPECTED_IOS_DISTRIBUTION_TEAM_ID
unset NVPN_EXPECTED_IOS_DISTRIBUTION_CERT_SHA256
unset NVPN_EXPECTED_FIPS_GIT_SHA
if ios_release_network_prepare selected >"$TMP_ROOT/ios-team.log" 2>&1; then
  echo "iOS provenance accepted a missing team pin" >&2
  exit 1
fi
grep -Fq 'requires an exact distribution team pin' "$TMP_ROOT/ios-team.log"

NVPN_EXPECTED_IOS_DISTRIBUTION_TEAM_ID=ABCDE12345
if ios_release_network_prepare selected >"$TMP_ROOT/ios-cert.log" 2>&1; then
  echo "iOS provenance accepted a missing certificate pin" >&2
  exit 1
fi
grep -Fq 'requires an exact distribution certificate SHA-256 pin' \
  "$TMP_ROOT/ios-cert.log"

NVPN_EXPECTED_IOS_DISTRIBUTION_CERT_SHA256="$(
  printf 'certificate' | shasum -a 256 | awk '{print $1}'
)"
if ios_release_network_prepare selected >"$TMP_ROOT/ios-fips.log" 2>&1; then
  echo "iOS provenance accepted a missing FIPS pin" >&2
  exit 1
fi
grep -Fq 'requires an exact FIPS Git SHA pin' "$TMP_ROOT/ios-fips.log"

receipt="$TMP_ROOT/receipt.json"
info="$TMP_ROOT/Info.plist"
installed="$TMP_ROOT/installed.json"
device="$TMP_ROOT/device.json"
python3 - "$info" "$installed" "$device" <<'PY'
import json
import plistlib
import sys

info, installed, device = sys.argv[1:]
with open(info, "wb") as handle:
    plistlib.dump(
        {"CFBundleShortVersionString": "4.1.5", "CFBundleVersion": "415"},
        handle,
    )
with open(installed, "w", encoding="utf-8") as handle:
    json.dump({}, handle)
with open(device, "w", encoding="utf-8") as handle:
    json.dump({"explicitPhysicalDeviceVerified": True}, handle)
PY
hash64=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
hash40=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
if ios_release_network_write_artifact_receipt \
  "$receipt" cdhash tunnelcd "$hash64" "$hash64" "$hash64" \
  "$hash40" "$hash40" "$info" "$installed" fi.siriusbusiness.nvpn \
  "$device" /tmp/app /tmp/derived /tmp/tests.xctestrun \
  "$hash40" 1.2.3 "$hash64" "$hash64" >/dev/null 2>&1
then
  echo "iOS artifact receipt accepted a missing installed app" >&2
  exit 1
fi
[[ ! -e "$receipt" ]]

python3 - "$installed" <<'PY'
import json
import sys

with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(
        {
            "bundleIdentifier": "fi.siriusbusiness.nvpn",
            "builtByDeveloper": True,
            "removable": True,
            "version": "4.1.5",
            "bundleVersion": "415",
        },
        handle,
    )
PY
ios_release_network_write_artifact_receipt \
  "$receipt" cdhash tunnelcd "$hash64" "$hash64" "$hash64" \
  "$hash40" "$hash40" "$info" "$installed" fi.siriusbusiness.nvpn \
  "$device" /tmp/app /tmp/derived /tmp/tests.xctestrun \
  "$hash40" 1.2.3 "$hash64" "$hash64"
python3 - "$receipt" "$hash64" <<'PY'
import json
import sys

receipt = json.load(open(sys.argv[1], encoding="utf-8"))
if receipt.get("signerCertificateSha256") != sys.argv[2]:
    raise SystemExit("iOS artifact receipt omitted the signer certificate pin")
PY
grep -Fq 'if ! ios_release_network_write_artifact_receipt' \
  "$ROOT_DIR/scripts/lib-mobile-ios-release-artifact.sh"
grep -Fq 'actual_signer_sha != expected_signer_sha' \
  "$ROOT_DIR/scripts/lib-mobile-ios-release-artifact.sh"

IOS_RELEASE_NETWORK_SIGNING_DIR="$(
  mktemp -d "$TMP_ROOT/nvpn-ios-release-signing.XXXXXX"
)"
IOS_RELEASE_NETWORK_SIGNING_ENV="$IOS_RELEASE_NETWORK_SIGNING_DIR/provisioning.env"
IOS_RELEASE_NETWORK_DEVICE_RECEIPT="$IOS_RELEASE_NETWORK_SIGNING_DIR/device.json"
IOS_RELEASE_NETWORK_CASE_XCTESTRUN="$IOS_RELEASE_NETWORK_SIGNING_DIR/case.xctestrun"
printf 'private profile\n' >"$IOS_RELEASE_NETWORK_SIGNING_ENV"
printf 'private device\n' >"$IOS_RELEASE_NETWORK_DEVICE_RECEIPT"
printf 'private spec\n' >"$IOS_RELEASE_NETWORK_CASE_XCTESTRUN"
private_signing_dir="$IOS_RELEASE_NETWORK_SIGNING_DIR"
ios_release_network_cleanup_private_artifacts
[[ ! -e "$private_signing_dir" ]]
[[ -z "$IOS_RELEASE_NETWORK_SIGNING_DIR" ]]
[[ -z "$IOS_RELEASE_NETWORK_DEVICE_RECEIPT" ]]

echo "mobile Release provenance harness passed"
