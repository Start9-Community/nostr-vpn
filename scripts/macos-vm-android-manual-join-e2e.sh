#!/usr/bin/env bash
# Real shipped-UI manual join between the isolated macOS VM and a physical Pixel.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/release_common.sh"
# shellcheck disable=SC1091
source "$ROOT/scripts/mobile_env.sh"
load_release_env "$ROOT"
load_env_file_defaults "$ROOT/.env.zapstore.local"
load_mobile_env "$ROOT"

MAC_HOST="${NVPN_MACOS_SSH_HOST:-${1:-}}"
MAC_GUEST_REPO="${NVPN_MACOS_GUEST_REPO:-src/nostr-vpn}"
REMOTE_SCRIPT="./scripts/e2e-macos-android-manual-join-remote.sh"
PACKAGE="${NVPN_DEFAULT_APP_ID:-fi.siriusbusiness.nvpn}"
ACTIVITY="$PACKAGE/org.nostrvpn.app.MainActivity"
ACTION_EXTRA="$PACKAGE.DEBUG_ACTION"
NETWORK_NAME_EXTRA="$PACKAGE.DEBUG_NETWORK_NAME"
WAIT_SECS="${NVPN_DESKTOP_MOBILE_JOIN_WAIT_SECS:-15}"
RESULT_DIR="${NVPN_DESKTOP_MOBILE_JOIN_RESULT_DIR:-$ROOT/artifacts/macos-android-manual-join}"
PRIVATE_DIR="$RESULT_DIR/.private-$$"
SUMMARY="$RESULT_DIR/summary.json"
APK="$ROOT/android/app/build/outputs/apk/debug/app-debug.apk"
LOCAL_FIXTURE="${NVPN_DESKTOP_MANUAL_JOIN_FIXTURE:-$ROOT/target/debug/examples/desktop_manual_join_e2e_fixture}"
devices_dirty=0
admin_start_pid=""
second_started=""
[[ -n "$MAC_HOST" ]] || {
  echo "set NVPN_MACOS_SSH_HOST or pass the macOS VM SSH target" >&2
  exit 2
}
[[ "$WAIT_SECS" =~ ^[1-9][0-9]*$ ]] \
  || { echo "NVPN_DESKTOP_MOBILE_JOIN_WAIT_SECS must be a positive integer" >&2; exit 2; }
case "${NVPN_MACOS_ANDROID_JOIN_SKIP_BUILD:-0}" in
  1|true|TRUE|True|yes|YES|Yes|on|ON|On)
    REMOTE_SKIP_BUILD=1
    ;;
  *)
    REMOTE_SKIP_BUILD=0
    ;;
esac

fail() {
  echo "physical macOS/Android manual-join e2e failed: $*" >&2
  exit 1
}

select_android_serial() {
  if [[ -n "${NVPN_ANDROID_SERIAL:-${ANDROID_SERIAL:-}}" ]]; then
    printf '%s\n' "${NVPN_ANDROID_SERIAL:-${ANDROID_SERIAL:-}}"
    return
  fi
  adb devices | awk '
    NR > 1 && $2 == "device" && $1 !~ /^emulator-/ { devices[++count] = $1 }
    END { if (count == 1) print devices[1]; else exit 1 }
  '
}

SERIAL="$(select_android_serial)" || fail "exactly one physical Android device is required"
ADB=(adb -s "$SERIAL")
mkdir -p "$PRIVATE_DIR"
chmod 700 "$PRIVATE_DIR"

android_action() {
  local action="$1"
  shift
  "${ADB[@]}" shell am start -W -n "$ACTIVITY" \
    --es "$ACTION_EXTRA" "$action" "$@" >/dev/null
}

copy_android_file() {
  "${ADB[@]}" exec-out run-as "$PACKAGE" cat "files/app-core/$1" >"$2"
}

build_local_fixture() {
  CARGO_TARGET_DIR="$ROOT/target" \
    cargo build -q -p nostr-vpn-core --example desktop_manual_join_e2e_fixture
  [[ -x "$LOCAL_FIXTURE" ]] \
    || fail "production config verifier is missing: $LOCAL_FIXTURE"
}

stop_android_vpn() {
  android_action disconnect >/dev/null 2>&1 || true
  local deadline=$((SECONDS + 10))
  while ((SECONDS < deadline)); do
    if ! "${ADB[@]}" shell dumpsys activity services "$PACKAGE" 2>/dev/null \
      | grep -Fq NostrVpnService
    then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

cleanup() {
  local status=$?
  trap - EXIT
  if [[ -n "$admin_start_pid" ]] && kill -0 "$admin_start_pid" >/dev/null 2>&1; then
    wait "$admin_start_pid" >/dev/null 2>&1 || true
  fi
  if [[ "$devices_dirty" == 1 ]]; then
    stop_android_vpn || true
    ssh -o BatchMode=yes "$MAC_HOST" \
      "cd '$MAC_GUEST_REPO' && '$REMOTE_SCRIPT' cleanup" >/dev/null 2>&1 || true
  fi
  rm -rf "$PRIVATE_DIR"
  exit "$status"
}
trap cleanup EXIT

ui_dump() {
  "${ADB[@]}" shell uiautomator dump /sdcard/nvpn-desktop-mobile.xml >/dev/null 2>&1
  "${ADB[@]}" exec-out cat /sdcard/nvpn-desktop-mobile.xml >"$PRIVATE_DIR/android-ui.xml"
}

ui_bounds_for_description() {
  local expected="$1"
  ui_dump || return 1
  python3 - "$PRIVATE_DIR/android-ui.xml" "$expected" <<'PY'
import html, re, sys
raw = open(sys.argv[1], encoding="utf-8").read()
for node in re.findall(r"<node [^>]+>", raw):
    description = re.search(r'content-desc="([^"]*)"', node)
    bounds = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', node)
    if description and bounds and html.unescape(description.group(1)) == sys.argv[2]:
        x1, y1, x2, y2 = map(int, bounds.groups())
        if x2 <= x1 or y2 <= y1:
            continue
        print(x1, y1, x2, y2)
        raise SystemExit(0)
raise SystemExit(1)
PY
}

tap_description() {
  local bounds
  bounds="$(ui_bounds_for_description "$1")" || return 1
  # shellcheck disable=SC2086
  set -- $bounds
  "${ADB[@]}" shell input tap "$((($1 + $3) / 2))" "$((($2 + $4) / 2))"
}

tap_resource() {
  local resource="$1" coordinates
  ui_dump || return 1
  coordinates="$(python3 - "$PRIVATE_DIR/android-ui.xml" "$resource" <<'PY'
import re, sys
raw = open(sys.argv[1], encoding="utf-8").read()
match = re.search(
    r'resource-id="' + re.escape(sys.argv[2])
    + r'"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"',
    raw,
)
if not match:
    raise SystemExit(1)
x1, y1, x2, y2 = map(int, match.groups())
print((x1 + x2) // 2, (y1 + y2) // 2)
PY
)" || return 1
  # shellcheck disable=SC2086
  "${ADB[@]}" shell input tap $coordinates
}

scroll_up() {
  local size width height
  size="$("${ADB[@]}" shell wm size | tr -d '\r' | awk -F': ' '/Physical size:/ {print $2}')"
  width="${size%x*}"
  height="${size#*x}"
  "${ADB[@]}" shell input swipe \
    "$((width / 2))" "$((height * 4 / 5))" \
    "$((width / 2))" "$((height / 3))" 250
}

wait_description() {
  local expected="$1" allow_scroll="${2:-0}" deadline=$((SECONDS + WAIT_SECS))
  while ((SECONDS < deadline)); do
    ui_bounds_for_description "$expected" >/dev/null 2>&1 && return 0
    [[ "$allow_scroll" == 1 ]] && scroll_up >/dev/null 2>&1 || true
    sleep 0.25
  done
  return 1
}

enter_field() {
  wait_description "$1" "${3:-0}" || return 1
  tap_description "$1" || return 1
  "${ADB[@]}" shell input keyevent KEYCODE_MOVE_END
  "${ADB[@]}" shell input text "$2"
  "${ADB[@]}" shell input keyevent KEYCODE_BACK
}

allow_vpn_prompt() {
  local deadline=$((SECONDS + WAIT_SECS))
  while ((SECONDS < deadline)); do
    if "${ADB[@]}" shell dumpsys activity services "$PACKAGE" 2>/dev/null \
      | grep -Fq NostrVpnService
    then
      return 0
    fi
    tap_resource "android:id/button1" >/dev/null 2>&1 \
      || tap_resource \
        "com.android.permissioncontroller:id/permission_allow_button" \
        >/dev/null 2>&1 \
      || true
    sleep 0.25
  done
  return 1
}

wait_android_vpn() {
  local deadline=$((SECONDS + WAIT_SECS))
  while ((SECONDS < deadline)); do
    if "${ADB[@]}" shell dumpsys activity services "$PACKAGE" 2>/dev/null \
      | grep -Fq NostrVpnService
    then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

android_manual_join_ui() {
  "${ADB[@]}" shell am start -W -n "$ACTIVITY" >/dev/null
  wait_description "Join Network" || return 1
  tap_description "Join Network" || return 1
  wait_description "Manual join" 1 || return 1
  tap_description "Manual join" || return 1
  enter_field "Manual join admin Device ID" "$1" 1 || return 1
  enter_field "Manual join Network ID" "$2" 1 || return 1
  wait_description "Add network manually" 1 || return 1
  tap_description "Add network manually" || return 1
  allow_vpn_prompt
}

android_admin_add_ui() {
  "${ADB[@]}" shell am start -W -n "$ACTIVITY" >/dev/null
  wait_description "Open manual device approval" || return 1
  tap_description "Open manual device approval" || return 1
  enter_field "Manual joiner Device ID" "$1" 1 || return 1
  wait_description "Add joining device manually" 1 || return 1
  second_started="$(now_ms)"
  tap_description "Add joining device manually"
}

android_join_screen_gone() {
  "${ADB[@]}" shell am start -W -n "$ACTIVITY" >/dev/null
  local deadline=$((SECONDS + WAIT_SECS))
  while ((SECONDS < deadline)); do
    if ! ui_bounds_for_description "Join Network" >/dev/null 2>&1 \
      && ! ui_dump_contains "Nearby join request"
    then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

ui_dump_contains() {
  ui_dump && grep -Fq "$1" "$PRIVATE_DIR/android-ui.xml"
}

json_value() {
  python3 - "$1" "$2" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8")).get(sys.argv[2], "")
if not isinstance(value, str) or not value:
    raise SystemExit(1)
print(value)
PY
}

config_identity_and_mesh() {
  local config="$1" snapshot="$PRIVATE_DIR/android-admin-snapshot"
  rm -rf "$snapshot"
  mkdir -p "$snapshot"
  cp "$config" "$snapshot/config.toml"
  "$LOCAL_FIXTURE" print-active-admin \
    --admin-data-dir "$snapshot" \
    --joiner-data-dir "$PRIVATE_DIR/unused-joiner" \
    --result "$PRIVATE_DIR/unused-result.json"
}

android_config_has_receipt() {
  local config="$1" mesh="$2" admin="$3"
  local snapshot="$PRIVATE_DIR/android-joiner-snapshot"
  rm -rf "$snapshot"
  mkdir -p "$snapshot"
  cp "$config" "$snapshot/config.toml"
  copy_android_file signed-rosters.json "$snapshot/signed-rosters.json" || return 1
  "$LOCAL_FIXTURE" verify-physical-joiner \
    --admin-data-dir "$PRIVATE_DIR/unused-admin" \
    --joiner-data-dir "$snapshot" \
    --result "$PRIVATE_DIR/unused-result.json" \
    --mesh-network-id "$mesh" \
    --admin-npub "$admin"
}

wait_android_receipt() {
  local mesh="$1" admin="$2" deadline=$((SECONDS + WAIT_SECS))
  while ((SECONDS < deadline)); do
    if copy_android_file config.toml "$PRIVATE_DIR/android-config.toml" 2>/dev/null \
      && android_config_has_receipt \
        "$PRIVATE_DIR/android-config.toml" "$mesh" "$admin"
    then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

wait_android_admin_ack() {
  local participant="$1" deadline=$((SECONDS + WAIT_SECS))
  while ((SECONDS < deadline)); do
    if copy_android_file config.toml "$PRIVATE_DIR/android-admin-config.toml" \
      2>/dev/null \
      && config_identity_and_mesh "$PRIVATE_DIR/android-admin-config.toml" \
        >/dev/null 2>&1 \
      && "$LOCAL_FIXTURE" verify-physical-admin \
        --admin-data-dir "$PRIVATE_DIR/android-admin-snapshot" \
        --joiner-data-dir "$PRIVATE_DIR/unused-joiner" \
        --result "$PRIVATE_DIR/unused-result.json" \
        --participant-npub "$participant" >/dev/null 2>&1
    then
      if ! "${ADB[@]}" exec-out run-as "$PACKAGE" sh -c \
        'find files/app-core/config.toml.join-roster-outbox -type f -name "*.json" -print -quit' \
        2>/dev/null | grep -q .
      then
        return 0
      fi
    fi
    sleep 0.25
  done
  return 1
}

assert_single_package() {
  local installed stale
  installed="$("${ADB[@]}" shell pm list packages | tr -d '\r' | sed -n 's/^package://p')"
  stale="$(printf '%s\n' "$installed" \
    | awk -v canonical="$PACKAGE" 'index($0, canonical ".") == 1 && $0 != canonical')"
  while IFS= read -r package; do
    [[ -n "$package" ]] || continue
    "${ADB[@]}" uninstall "$package" >/dev/null || fail "could not remove stale $package"
  done <<<"$stale"
  "${ADB[@]}" shell pm list packages | tr -d '\r' \
    | grep -Fxq "package:$PACKAGE" || fail "canonical Android app is not installed"
}

assert_direct_internet() {
  "${ADB[@]}" shell ping -c 1 -W 5 1.1.1.1 >/dev/null \
    || fail "Pixel direct Internet did not recover after VPN disconnect"
  "${ADB[@]}" shell ping -c 1 -W 5 example.com >/dev/null \
    || fail "Pixel device DNS did not recover after VPN disconnect"
}

elapsed_ms() {
  python3 - "$1" <<'PY'
import sys, time
print((time.time_ns() // 1_000_000) - int(sys.argv[1]))
PY
}

now_ms() {
  python3 - <<'PY'
import time
print(time.time_ns() // 1_000_000)
PY
}

if [[ "${NVPN_DESKTOP_MOBILE_JOIN_BUILD_ANDROID:-1}" != 0 ]]; then
  NVPN_ANDROID_DEBUG_RELEASE_SIGNING=1 \
    NVPN_ANDROID_PACKAGE="$PACKAGE" \
    "$ROOT/tools/run-android" build
fi
build_local_fixture
[[ -f "$APK" ]] || fail "signed debug APK is missing"
"${ADB[@]}" install -r "$APK" >/dev/null
assert_single_package
"${ADB[@]}" shell pm grant "$PACKAGE" android.permission.POST_NOTIFICATIONS \
  >/dev/null 2>&1 || true

case "${NVPN_MACOS_SKIP_GIT_SYNC:-0}" in
  1|true|TRUE|True|yes|YES|Yes|on|ON|On) ;;
  *) "$ROOT/scripts/macos-vm-git-sync.sh" "$MAC_HOST" ;;
esac
ssh -o BatchMode=yes "$MAC_HOST" \
  "cd '$MAC_GUEST_REPO' && env NVPN_MACOS_ANDROID_JOIN_SKIP_BUILD=$REMOTE_SKIP_BUILD NVPN_DESKTOP_MOBILE_JOIN_WAIT_SECS=$WAIT_SECS '$REMOTE_SCRIPT' prepare"
ssh -o BatchMode=yes "$MAC_HOST" \
  "cat '$MAC_GUEST_REPO/artifacts/macos-android-manual-join/desktop-fixture.json'" \
  >"$PRIVATE_DIR/desktop-fixture.json"
MAC_ADMIN_NPUB="$(json_value "$PRIVATE_DIR/desktop-fixture.json" adminNpub)"
MAC_JOINER_NPUB="$(json_value "$PRIVATE_DIR/desktop-fixture.json" joinerNpub)"
MAC_ADMIN_MESH="$(json_value "$PRIVATE_DIR/desktop-fixture.json" meshNetworkId)"
devices_dirty=1
ssh -o BatchMode=yes "$MAC_HOST" \
  "cd '$MAC_GUEST_REPO' && '$REMOTE_SCRIPT' start admin" \
  >"$PRIVATE_DIR/macos-admin-start.log" 2>&1 &
admin_start_pid=$!

# macOS admin -> physical Android joiner.
"${ADB[@]}" shell pm clear "$PACKAGE" >/dev/null
android_action export_join_request
deadline=$((SECONDS + WAIT_SECS))
while ((SECONDS < deadline)); do
  copy_android_file debug-join-request.json "$PRIVATE_DIR/android-joiner.json" \
    2>/dev/null && break
  sleep 0.25
done
ANDROID_JOINER_NPUB="$(json_value "$PRIVATE_DIR/android-joiner.json" deviceId)" \
  || fail "could not read the physical Android identity"
android_manual_join_ui "$MAC_ADMIN_NPUB" "$MAC_ADMIN_MESH" \
  || fail "Pixel shipped manual-join UI did not submit the macOS network"
wait_android_vpn || fail "Pixel joiner transport did not start"
if ! wait "$admin_start_pid"; then
  cat "$PRIVATE_DIR/macos-admin-start.log" >&2
  fail "isolated macOS admin transport did not start"
fi
admin_start_pid=""
cat "$PRIVATE_DIR/macos-admin-start.log"
first_started="$(now_ms)"
ssh -o BatchMode=yes "$MAC_HOST" \
  "cd '$MAC_GUEST_REPO' && '$REMOTE_SCRIPT' admin-add '$ANDROID_JOINER_NPUB' physical-pixel"
wait_android_receipt "$MAC_ADMIN_MESH" "$MAC_ADMIN_NPUB" \
  || fail "macOS admin roster did not become durable on the Pixel"
android_join_screen_gone \
  || fail "Pixel stayed on the Join Network UI after durable roster receipt"
first_elapsed="$(elapsed_ms "$first_started")"
ssh -o BatchMode=yes "$MAC_HOST" \
  "cd '$MAC_GUEST_REPO' && '$REMOTE_SCRIPT' wait-admin-ack '$ANDROID_JOINER_NPUB'"
stop_android_vpn || fail "Pixel VPN did not disconnect after first direction"
ssh -o BatchMode=yes "$MAC_HOST" \
  "cd '$MAC_GUEST_REPO' && '$REMOTE_SCRIPT' stop admin"
assert_direct_internet

# Physical Android admin -> macOS joiner.
"${ADB[@]}" shell pm clear "$PACKAGE" >/dev/null
android_action add_network --es "$NETWORK_NAME_EXTRA" "Pixel desktop join e2e"
deadline=$((SECONDS + WAIT_SECS))
mapfile_output=""
while ((SECONDS < deadline)); do
  if copy_android_file config.toml "$PRIVATE_DIR/android-admin-config.toml" 2>/dev/null \
    && mapfile_output="$(config_identity_and_mesh "$PRIVATE_DIR/android-admin-config.toml" 2>/dev/null)"
  then
    break
  fi
  sleep 0.25
done
ANDROID_ADMIN_NPUB="$(printf '%s\n' "$mapfile_output" | sed -n '1p')"
ANDROID_ADMIN_MESH="$(printf '%s\n' "$mapfile_output" | sed -n '2p')"
[[ -n "$ANDROID_ADMIN_NPUB" && -n "$ANDROID_ADMIN_MESH" ]] \
  || fail "Pixel admin network setup did not persist"
android_action connect
allow_vpn_prompt
wait_android_vpn || fail "Pixel admin transport did not start"
ssh -o BatchMode=yes "$MAC_HOST" \
  "cd '$MAC_GUEST_REPO' && '$REMOTE_SCRIPT' joiner-manual '$ANDROID_ADMIN_NPUB' '$ANDROID_ADMIN_MESH'"
android_admin_add_ui "$MAC_JOINER_NPUB" \
  || fail "Pixel shipped admin UI did not add the macOS joiner"
[[ -n "$second_started" ]] || fail "Pixel admin UI did not record its approval submission"
ssh -o BatchMode=yes "$MAC_HOST" \
  "cd '$MAC_GUEST_REPO' && '$REMOTE_SCRIPT' wait-joiner-receipt '$ANDROID_ADMIN_MESH' '$ANDROID_ADMIN_NPUB'"
ssh -o BatchMode=yes "$MAC_HOST" \
  "cd '$MAC_GUEST_REPO' && '$REMOTE_SCRIPT' verify-joined-ui"
second_elapsed="$(elapsed_ms "$second_started")"
wait_android_admin_ack "$MAC_JOINER_NPUB" \
  || fail "Pixel admin did not receive the macOS durable roster acknowledgement"

ceiling_ms=$((WAIT_SECS * 1000))
((first_elapsed <= ceiling_ms)) \
  || fail "macOS admin -> Pixel roster took ${first_elapsed}ms (ceiling ${ceiling_ms}ms)"
((second_elapsed <= ceiling_ms)) \
  || fail "Pixel admin -> macOS roster took ${second_elapsed}ms (ceiling ${ceiling_ms}ms)"

stop_android_vpn || fail "Pixel VPN did not disconnect after second direction"
ssh -o BatchMode=yes "$MAC_HOST" \
  "cd '$MAC_GUEST_REPO' && '$REMOTE_SCRIPT' cleanup"
assert_direct_internet
assert_single_package
devices_dirty=0

python3 - "$SUMMARY" "$first_elapsed" "$second_elapsed" "$ceiling_ms" <<'PY'
import json, sys
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump({
        "passed": True,
        "directions": [
            "macos-admin-to-physical-android-joiner",
            "physical-android-admin-to-macos-joiner",
        ],
        "joinAndApprovalActions": "shipped UI only",
        "fixtureProvisioning": "isolated configs and debug-signed setup actions",
        "transport": "public-fips-tcp-signed-roster-with-durable-ack",
        "androidPackage": "fi.siriusbusiness.nvpn",
        "deliveryElapsedMs": {
            "macosAdminToAndroidJoiner": int(sys.argv[2]),
            "androidAdminToMacosJoiner": int(sys.argv[3]),
        },
        "deliveryCeilingMs": int(sys.argv[4]),
        "joinedUiTransitionVerified": {
            "android": True,
            "macos": True,
        },
        "deviceInternetRecoveredAfterDisconnect": True,
    }, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY

echo "MACOS_VM_PHYSICAL_ANDROID_BIDIRECTIONAL_MANUAL_JOIN_E2E_OK"
echo "Durable roster elapsed ms (macOS->Pixel, Pixel->macOS): $first_elapsed, $second_elapsed"
echo "Result: $SUMMARY"
