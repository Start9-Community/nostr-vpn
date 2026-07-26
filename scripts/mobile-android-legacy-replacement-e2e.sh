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
WAIT_SECS="${NVPN_ANDROID_LEGACY_WAIT_SECS:-15}"
ADB="${ADB:-adb}"
serial=""
work_dir=""
logcat_pid=""

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
  if [[ -n "$logcat_pid" ]]; then
    kill "$logcat_pid" >/dev/null 2>&1 || true
    wait "$logcat_pid" >/dev/null 2>&1 || true
  fi
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

build_retired_fixture_apks() {
  local package output_name
  for package in "${RETIRED_PACKAGES[@]}"; do
    output_name="${package//./_}.apk"
    (
      cd "$ROOT/android"
      NVPN_ANDROID_PACKAGE="$package" \
        NVPN_ANDROID_DEBUG_RELEASE_SIGNING=1 \
        gradle :app:assembleDebug -x buildRustArm64
    )
    cp "$ROOT/android/app/build/outputs/apk/debug/app-debug.apk" \
      "$work_dir/$output_name"
  done
  cp "$work_dir/canonical.apk" "$CANONICAL_APK"
}

install_retired_fixture_apks() {
  local package output_name
  for package in "${RETIRED_PACKAGES[@]}"; do
    output_name="${package//./_}.apk"
    "$ADB" -s "$serial" install -r "$work_dir/$output_name" >/dev/null
    package_installed "$package" \
      || { echo "Retired Android fixture package was not installed: $package" >&2; return 1; }
  done
}

assert_canonical_update_preserved_data() {
  local actual marker="canonical-update-$RANDOM-$$"
  "$ADB" -s "$serial" shell run-as "$CANONICAL_PACKAGE" mkdir -p files
  "$ADB" -s "$serial" shell run-as "$CANONICAL_PACKAGE" \
    sh -c "echo $marker > files/nvpn-replacement-marker"
  "$ADB" -s "$serial" install -r "$work_dir/canonical.apk" >/dev/null
  actual="$("$ADB" -s "$serial" exec-out run-as "$CANONICAL_PACKAGE" \
    cat files/nvpn-replacement-marker | tr -d '\r\n')"
  "$ADB" -s "$serial" shell run-as "$CANONICAL_PACKAGE" \
    rm -f files/nvpn-replacement-marker
  [[ "$actual" == "$marker" ]]
}

assert_vpn_start_blocked() {
  local service_component="$CANONICAL_PACKAGE/org.nostrvpn.app.vpn.NostrVpnService"
  "$ADB" -s "$serial" logcat -v brief -s NostrVpnService:E '*:S' \
    >"$work_dir/vpn-start-guard.log" &
  logcat_pid="$!"
  sleep 0.25
  if ! "$ADB" -s "$serial" shell am start-foreground-service \
    -n "$service_component" \
    -a fi.siriusbusiness.nvpn.vpn.CONNECT \
    --es configJson '{}' >/dev/null
  then
    kill "$logcat_pid" >/dev/null 2>&1 || true
    wait "$logcat_pid" >/dev/null 2>&1 || true
    logcat_pid=""
    return 1
  fi
  sleep 1
  kill "$logcat_pid" >/dev/null 2>&1 || true
  wait "$logcat_pid" >/dev/null 2>&1 || true
  logcat_pid=""
  grep -Fq 'Refusing Android VPN start while conflicting nVPN packages remain:' \
    "$work_dir/vpn-start-guard.log" \
    || return 1
  ! "$ADB" -s "$serial" shell dumpsys activity services "$CANONICAL_PACKAGE" \
    | grep -Fq 'NostrVpnService'
}

for command in "$ADB" gradle; do
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
assert_canonical_update_preserved_data \
  || { echo "Canonical Android update did not preserve app data in place" >&2; exit 1; }
"$ADB" -s "$serial" shell am force-stop "$CANONICAL_PACKAGE"
build_retired_fixture_apks
install_retired_fixture_apks
assert_no_retired_processes \
  || { echo "A retired nVPN process started before migration" >&2; exit 1; }
assert_vpn_start_blocked \
  || { echo "Canonical Android VPN service started before retired apps were removed" >&2; exit 1; }

"$ADB" -s "$serial" shell am force-stop "$CANONICAL_PACKAGE"
"$ADB" -s "$serial" shell monkey -p "$CANONICAL_PACKAGE" 1 >/dev/null
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

mkdir -p "$RESULT_DIR"
python3 - "$RESULT_DIR/mobile-android-legacy-replacement.json" <<'PY'
import json
import sys

with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(
        {
            "canonicalPackageCount": 1,
            "retiredPackageCount": 0,
            "canonicalMainProcessCount": 1,
            "canonicalUpdatePreservedData": True,
            "shippedRemovalPrompt": True,
            "vpnStartBlockedBeforeCleanup": True,
            "systemUninstallConfirmed": True,
        },
        handle,
        indent=2,
        sort_keys=True,
    )
    handle.write("\n")
PY

echo "Android legacy-package replacement e2e passed"
