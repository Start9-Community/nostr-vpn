#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/release_common.sh"
# shellcheck disable=SC1091
source "$ROOT/scripts/mobile_env.sh"
load_release_env "$ROOT"
load_env_file_defaults "$ROOT/.env.zapstore.local"
load_mobile_env "$ROOT"

CANONICAL_PACKAGE="${NVPN_ANDROID_PACKAGE:-fi.siriusbusiness.nvpn}"
RETIRED_PACKAGES=(
  org.nostrvpn.app
  fi.siriusbusiness.nvpn.releasegate
  fi.siriusbusiness.nvpn.mobileexit
  fi.siriusbusiness.nvpn.joine2e
  fi.siriusbusiness.nvpn.debug
  fi.siriusbusiness.nvpn.test
)
CANONICAL_APK="${NVPN_ANDROID_LEGACY_CANONICAL_APK:-$ROOT/android/app/build/outputs/apk/debug/app-debug.apk}"
REUSE_CANONICAL_APK="${NVPN_ANDROID_LEGACY_REUSE_CANONICAL_APK:-0}"
RESULT_DIR="${NVPN_ANDROID_LEGACY_RESULT_DIR:-$ROOT/artifacts/mobile-android}"
ARTIFACT_RECEIPT="${NVPN_MOBILE_ANDROID_RELEASE_RECEIPT:-}"
WAIT_SECS="${NVPN_ANDROID_LEGACY_WAIT_SECS:-15}"
ADB="${ADB:-adb}"
serial=""
work_dir=""
retired_fixture_total_bytes=0

select_device() {
  if [[ -n "${NVPN_ANDROID_SERIAL:-${ANDROID_SERIAL:-}}" ]]; then
    printf '%s\n' "${NVPN_ANDROID_SERIAL:-${ANDROID_SERIAL:-}}"
    return
  fi
  "$ADB" devices | awk '
    NR > 1 && $2 == "device" && $1 !~ /^emulator-/ { devices[++count] = $1 }
    END { if (count == 1) print devices[1]; else exit 1 }
  '
}

package_installed() {
  "$ADB" -s "$serial" shell pm path "$1" >/dev/null 2>&1
}

cleanup() {
  local status="$?"
  local package
  trap - EXIT
  if [[ -n "$serial" ]]; then
    for package in "${RETIRED_PACKAGES[@]}"; do
      package_installed "$package" \
        && "$ADB" -s "$serial" uninstall "$package" >/dev/null 2>&1 || true
    done
  fi
  if [[ -n "$work_dir" ]]; then
    if [[ -f "$work_dir/canonical.apk" ]]; then
      cp "$work_dir/canonical.apk" "$CANONICAL_APK" || true
    fi
    rm -rf "$work_dir"
  fi
  exit "$status"
}
trap cleanup EXIT

dump_ui() {
  local destination="$1"
  "$ADB" -s "$serial" shell uiautomator dump /sdcard/nvpn-legacy-migration.xml \
    >/dev/null 2>&1
  "$ADB" -s "$serial" exec-out cat /sdcard/nvpn-legacy-migration.xml >"$destination"
}

ui_point() {
  local xml="$1" selector_type="$2" selector="$3"
  python3 - "$xml" "$selector_type" "$selector" <<'PY'
import html
import re
import sys

path, selector_type, selector = sys.argv[1:]
raw = open(path, encoding="utf-8").read()
for node in re.findall(r"<node [^>]+>", raw):
    attributes = {
        name: html.unescape(value)
        for name, value in re.findall(r'([a-z-]+)="([^"]*)"', node)
    }
    if selector_type == "resource":
        matched = attributes.get("resource-id") == selector
    elif selector_type == "description":
        matched = attributes.get("content-desc") == selector
    elif selector_type == "text":
        matched = attributes.get("text") == selector
    else:
        raise SystemExit("unsupported selector")
    bounds = re.fullmatch(
        r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]",
        attributes.get("bounds", ""),
    )
    if matched and bounds:
        left, top, right, bottom = map(int, bounds.groups())
        print((left + right) // 2, (top + bottom) // 2)
        raise SystemExit(0)
raise SystemExit(1)
PY
}

tap_ui() {
  local selector_type="$1" selector="$2" deadline point xml
  xml="$work_dir/ui.xml"
  deadline=$((SECONDS + WAIT_SECS))
  while ((SECONDS < deadline)); do
    if dump_ui "$xml" && point="$(ui_point "$xml" "$selector_type" "$selector")"; then
      # shellcheck disable=SC2086
      "$ADB" -s "$serial" shell input tap $point
      return 0
    fi
    sleep 0.25
  done
  return 1
}

wait_for_ui() {
  local selector_type="$1" selector="$2" deadline xml
  xml="$work_dir/ui.xml"
  deadline=$((SECONDS + WAIT_SECS))
  while ((SECONDS < deadline)); do
    if dump_ui "$xml" && ui_point "$xml" "$selector_type" "$selector" >/dev/null; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

tap_system_uninstall() {
  local deadline point xml option
  xml="$work_dir/ui.xml"
  deadline=$((SECONDS + WAIT_SECS))
  while ((SECONDS < deadline)); do
    if dump_ui "$xml"; then
      for option in Uninstall OK; do
        if point="$(ui_point "$xml" text "$option")"; then
          # shellcheck disable=SC2086
          "$ADB" -s "$serial" shell input tap $point
          return 0
        fi
      done
    fi
    sleep 0.25
  done
  return 1
}

assert_only_canonical_package() {
  local installed unexpected
  installed="$("$ADB" -s "$serial" shell pm list packages \
    | tr -d '\r' \
    | sed -n 's/^package://p')"
  unexpected="$(printf '%s\n' "$installed" \
    | awk '$0 == "org.nostrvpn.app" || ($0 ~ /^fi\.siriusbusiness\.nvpn(\.|$)/ && $0 != "fi.siriusbusiness.nvpn")')"
  [[ -z "$unexpected" ]] || return 1
  printf '%s\n' "$installed" | grep -Fxq "$CANONICAL_PACKAGE"
}

assert_no_retired_processes() {
  local package
  for package in "${RETIRED_PACKAGES[@]}"; do
    if [[ -n "$("$ADB" -s "$serial" shell pidof "$package" 2>/dev/null | tr -d '\r')" ]]; then
      echo "Retired Android package still has a process: $package" >&2
      return 1
    fi
  done
}

assert_fixture_has_no_native_libraries() {
  local apk="$1" contents
  contents="$(unzip -Z1 "$apk")" \
    || {
      echo "Retired Android fixture is not a readable APK: $apk" >&2
      return 1
    }
  if grep -Eq '^lib/.*\.so$' <<<"$contents"; then
    echo "Retired Android fixture unexpectedly contains native libraries: $apk" >&2
    return 1
  fi
}

build_retired_fixture_apks() {
  local fixture_bytes package output_name
  for package in "${RETIRED_PACKAGES[@]}"; do
    output_name="${package//./_}.apk"
    (
      cd "$ROOT/android"
      NVPN_ANDROID_PACKAGE="$package" \
        NVPN_ANDROID_LEGACY_FIXTURE_WITHOUT_NATIVE_LIBS=1 \
        NVPN_ANDROID_DEBUG_RELEASE_SIGNING=1 \
        gradle :app:assembleDebug -x buildRustArm64
    )
    cp "$ROOT/android/app/build/outputs/apk/debug/app-debug.apk" \
      "$work_dir/$output_name"
    assert_fixture_has_no_native_libraries "$work_dir/$output_name"
    fixture_bytes="$(wc -c <"$work_dir/$output_name" | tr -d ' ')"
    retired_fixture_total_bytes=$((retired_fixture_total_bytes + fixture_bytes))
    printf 'Built native-free retired fixture %s (%s bytes)\n' \
      "$package" "$fixture_bytes"
  done
  printf 'Native-free retired fixtures total %s bytes\n' \
    "$retired_fixture_total_bytes"
  cp "$work_dir/canonical.apk" "$CANONICAL_APK"
}

install_retired_fixture_apks() {
  local package output_name
  local -a fixture_apks=()
  for package in "${RETIRED_PACKAGES[@]}"; do
    output_name="${package//./_}.apk"
    fixture_apks+=("$work_dir/$output_name")
  done
  "$ADB" -s "$serial" install-multi-package -r "${fixture_apks[@]}" >/dev/null
  for package in "${RETIRED_PACKAGES[@]}"; do
    package_installed "$package" \
      || { echo "Retired Android fixture package was not installed: $package" >&2; return 1; }
  done
}

assert_canonical_is_nondebuggable() {
  ! "$ADB" -s "$serial" shell dumpsys package "$CANONICAL_PACKAGE" \
    | tr -d '\r' \
    | grep -Eq '(^|[[:space:]])DEBUGGABLE([[:space:]]|$)'
}

assert_vpn_inactive_while_removal_prompt_is_shown() {
  ! "$ADB" -s "$serial" shell dumpsys activity services "$CANONICAL_PACKAGE" \
    | grep -Fq 'NostrVpnService'
}

installed_canonical_apk_sha256() {
  local package_path
  package_path="$(
    "$ADB" -s "$serial" shell pm path "$CANONICAL_PACKAGE" \
      | tr -d '\r' \
      | sed -n 's/^package://p'
  )"
  [[ -n "$package_path" && "$package_path" != *$'\n'* ]] || return 1
  "$ADB" -s "$serial" exec-out sh -c "cat '$package_path'" \
    | shasum -a 256 \
    | awk '{print $1}'
}

for command in "$ADB" gradle unzip; do
  command -v "$command" >/dev/null 2>&1 \
    || { echo "Android legacy replacement e2e requires $command" >&2; exit 1; }
done
for signing_var in \
  ANDROID_KEYSTORE_PATH \
  ANDROID_KEYSTORE_PASSWORD \
  ANDROID_KEY_ALIAS \
  ANDROID_KEY_PASSWORD
do
  [[ -n "${!signing_var:-}" ]] \
    || { echo "Android legacy replacement e2e requires $signing_var" >&2; exit 1; }
done

[[ "$CANONICAL_PACKAGE" == "fi.siriusbusiness.nvpn" ]] \
  || {
    echo "Android replacement e2e must exercise canonical fi.siriusbusiness.nvpn" >&2
    exit 1
  }
serial="$(select_device)" \
  || { echo "Android legacy replacement e2e requires exactly one physical device" >&2; exit 1; }
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/nvpn-android-legacy-e2e.XXXXXX")"
chmod 700 "$work_dir"

if [[ "$REUSE_CANONICAL_APK" != "1" || ! -f "$CANONICAL_APK" ]]; then
  NVPN_ANDROID_PACKAGE="$CANONICAL_PACKAGE" \
    NVPN_ANDROID_DEBUG_RELEASE_SIGNING=1 \
    "$ROOT/tools/run-android" build
fi
cp "$CANONICAL_APK" "$work_dir/canonical.apk"

"$ADB" -s "$serial" install -r "$work_dir/canonical.apk" >/dev/null
assert_canonical_is_nondebuggable \
  || { echo "Android replacement e2e requires the sealed nondebuggable Release app" >&2; exit 1; }
"$ADB" -s "$serial" shell am force-stop "$CANONICAL_PACKAGE"
build_retired_fixture_apks
install_retired_fixture_apks
assert_no_retired_processes \
  || { echo "A retired nVPN process started before migration" >&2; exit 1; }
"$ADB" -s "$serial" shell am force-stop "$CANONICAL_PACKAGE"
"$ADB" -s "$serial" shell monkey -p "$CANONICAL_PACKAGE" 1 >/dev/null
wait_for_ui description "Remove older Nostr VPN installation" \
  || { echo "Canonical Android migration prompt did not reach the foreground" >&2; exit 1; }
assert_vpn_inactive_while_removal_prompt_is_shown \
  || { echo "Canonical Android VPN service was active behind the removal prompt" >&2; exit 1; }

for package in "${RETIRED_PACKAGES[@]}"; do
  tap_ui description "Remove older Nostr VPN installation" \
    || {
      echo "Canonical Android app did not prompt to remove $package" >&2
      exit 1
    }
  tap_system_uninstall \
    || { echo "Android system uninstall confirmation did not appear for $package" >&2; exit 1; }
  deadline=$((SECONDS + WAIT_SECS))
  while package_installed "$package" && ((SECONDS < deadline)); do
    sleep 0.25
  done
  package_installed "$package" \
    && { echo "Retired Android package survived confirmed removal: $package" >&2; exit 1; }
done
assert_only_canonical_package \
  || { echo "Android replacement flow did not leave exactly the canonical package" >&2; exit 1; }

process_count="$("$ADB" -s "$serial" shell pidof "$CANONICAL_PACKAGE" 2>/dev/null \
  | tr -d '\r' \
  | wc -w \
  | tr -d ' ')"
[[ "$process_count" == "1" ]] \
  || { echo "Canonical Android app has $process_count main processes after replacement" >&2; exit 1; }
installed_apk_sha="$(installed_canonical_apk_sha256)" \
  || { echo "Could not hash the installed canonical Android APK" >&2; exit 1; }
canonical_apk_sha="$(shasum -a 256 "$work_dir/canonical.apk" | awk '{print $1}')"
[[ "$installed_apk_sha" == "$canonical_apk_sha" ]] \
  || { echo "Installed canonical Android APK differs from the sealed artifact" >&2; exit 1; }

mkdir -p "$RESULT_DIR"
python3 - \
  "$RESULT_DIR/mobile-android-legacy-replacement.json" \
  "$work_dir/canonical.apk" \
  "$ARTIFACT_RECEIPT" \
  "$installed_apk_sha" \
  "$(git -C "$ROOT" rev-parse HEAD)" \
  "$(git -C "$ROOT" rev-parse HEAD^{tree})" <<'PY'
import hashlib
import json
import pathlib
import sys

output, apk_path, receipt_path, installed_apk_sha, app_sha, app_tree = sys.argv[1:]
apk = pathlib.Path(apk_path)
receipt_file = pathlib.Path(receipt_path)
if not receipt_path or not receipt_file.is_file():
    raise SystemExit("Android replacement gate requires the exact artifact receipt")
receipt = json.loads(receipt_file.read_text(encoding="utf-8"))
apk_sha = hashlib.sha256(apk.read_bytes()).hexdigest()
if (
    receipt.get("receiptSchema") != 2
    or receipt.get("artifactType") != "Android Release APK"
    or receipt.get("appGitSha") != app_sha
    or receipt.get("appGitTree") != app_tree
    or receipt.get("apkSha256") != apk_sha
    or receipt.get("installedApkSha256") != apk_sha
    or receipt.get("companySigningVerified") is not True
    or receipt.get("replacementInstall") is not True
    or receipt.get("debuggable") is not False
    or installed_apk_sha != apk_sha
):
    raise SystemExit("Android replacement gate artifact identity differs")
with open(output, "w", encoding="utf-8") as handle:
    json.dump(
        {
            "receiptSchema": 1,
            "artifactType": "Android Release replacement/singleton gate",
            "appGitSha": app_sha,
            "appGitTree": app_tree,
            "artifactReceiptSha256": hashlib.sha256(
                receipt_file.read_bytes()
            ).hexdigest(),
            "apkSha256": apk_sha,
            "installedApkSha256": receipt["installedApkSha256"],
            "package": receipt["package"],
            "signerCertificateSha256": receipt[
                "signerCertificateSha256"
            ],
            "canonicalPackageCount": 1,
            "retiredPackageCount": 0,
            "canonicalMainProcessCount": 1,
            "canonicalReplacementInstallVerified": True,
            "sealedReleaseNonDebuggable": True,
            "shippedRemovalPrompt": True,
            "vpnServiceInactiveWhilePromptShown": True,
            "systemUninstallConfirmed": True,
        },
        handle,
        indent=2,
        sort_keys=True,
    )
    handle.write("\n")
PY

echo "Android legacy-package replacement e2e passed"
