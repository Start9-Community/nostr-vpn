#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
continuity="$ROOT/scripts/validate-mobile-underlay-continuity.py"
ios_output_capture="$ROOT/scripts/capture-mobile-ios-underlay-output.py"
android_lib="$ROOT/scripts/lib-mobile-android-underlay.sh"
android_smoke="$ROOT/scripts/mobile-android-smoke.sh"
ios_test="$ROOT/ios/UITests/NostrVpnReleaseNetworkUITests.swift"
ios_underlay="$ROOT/ios/UITests/NostrVpnReleaseNetworkUnderlay.swift"
ios_hotspot="$ROOT/scripts/lib-mobile-ios-hotspot.sh"
mobile_exit_gate="$ROOT/scripts/mobile-wireguard-exit-e2e.sh"
release_gate="$ROOT/scripts/release-gate.sh"
fixture="$ROOT/Dockerfile.mobile-wireguard-exit-e2e"
remote_fixture="$ROOT/scripts/mobile-wireguard-exit-remote-native.sh"
temp="$(mktemp -d "${TMPDIR:-/tmp}/nvpn-mobile-underlay-harness.XXXXXX")"
trap 'rm -rf "$temp"' EXIT

write_ping_fixture() {
  local second_recovery="$1"
  cat >"$temp/ping.log" <<EOF
[1000.000] 64 bytes from 10.0.0.2: icmp_seq=1 ttl=64 time=1 ms
[1000.200] 64 bytes from 10.0.0.2: icmp_seq=2 ttl=64 time=1 ms
[1001.200] 64 bytes from 10.0.0.2: icmp_seq=3 ttl=64 time=1 ms
[1002.000] 64 bytes from 10.0.0.2: icmp_seq=4 ttl=64 time=1 ms
[$second_recovery] 64 bytes from 10.0.0.2: icmp_seq=5 ttl=64 time=1 ms
EOF
  if [[ "$second_recovery" == "1003.100" ]]; then
    cat >>"$temp/ping.log" <<'EOF'
[1005.000] 64 bytes from 10.0.0.2: icmp_seq=6 ttl=64 time=1 ms
[1007.000] 64 bytes from 10.0.0.2: icmp_seq=7 ttl=64 time=1 ms
[1008.000] 64 bytes from 10.0.0.2: icmp_seq=8 ttl=64 time=1 ms
EOF
  else
    cat >>"$temp/ping.log" <<'EOF'
[1007.300] 64 bytes from 10.0.0.2: icmp_seq=6 ttl=64 time=1 ms
[1008.000] 64 bytes from 10.0.0.2: icmp_seq=7 ttl=64 time=1 ms
EOF
  fi
}

cat >"$temp/markers.tsv" <<'EOF'
switch_1_requested	1000500
switch_1_available	1001000
switch_1_payload_recovery	200
switch_1_verified	1001900
switch_2_requested	1002000
switch_2_available	1003000
switch_2_payload_recovery	100
switch_2_verified	1007900
EOF
write_ping_fixture 1003.100
python3 "$continuity" \
  "$temp/ping.log" "$temp/markers.tsv" "$temp/continuity.json" Android 4000 \
  >/dev/null
python3 - "$temp/continuity.json" <<'PY'
import json
import sys

receipt = json.load(open(sys.argv[1], encoding="utf-8"))
assert receipt["passed"] is True
assert [cycle["recoveryMilliseconds"] for cycle in receipt["cycles"]] == [200, 100]
assert receipt["bidirectionalPayload"].startswith("wireguard-server-icmp")
PY

cp "$temp/markers.tsv" "$temp/slow-markers.tsv"
python3 - "$temp/slow-markers.tsv" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
path.write_text(
    path.read_text(encoding="utf-8").replace(
        "switch_2_payload_recovery\t100\n",
        "switch_2_payload_recovery\t4100\n",
    ),
    encoding="utf-8",
)
PY
write_ping_fixture 1003.100
if python3 "$continuity" \
  "$temp/ping.log" "$temp/slow-markers.tsv" "$temp/slow.json" iOS 4000 \
  >"$temp/slow.out" 2>"$temp/slow.err"
then
  echo "continuity validator accepted recovery slower than four seconds" >&2
  exit 1
fi
grep -Fq "payload recovery was 4100ms" "$temp/slow.err"

cat >"$temp/ping.log" <<'EOF'
[1000.000] 64 bytes from 10.0.0.2: icmp_seq=1 ttl=64 time=1 ms
[1000.200] 64 bytes from 10.0.0.2: icmp_seq=2 ttl=64 time=1 ms
[1001.200] 64 bytes from 10.0.0.2: icmp_seq=3 ttl=64 time=1 ms
[1002.000] 64 bytes from 10.0.0.2: icmp_seq=4 ttl=64 time=1 ms
[1003.100] 64 bytes from 10.0.0.2: icmp_seq=5 ttl=64 time=1 ms
[1007.500] 64 bytes from 10.0.0.2: icmp_seq=6 ttl=64 time=1 ms
[1008.000] 64 bytes from 10.0.0.2: icmp_seq=7 ttl=64 time=1 ms
EOF
if python3 "$continuity" \
  "$temp/ping.log" "$temp/markers.tsv" "$temp/post-recovery-gap.json" Android 4000 \
  >"$temp/post-recovery-gap.out" 2>"$temp/post-recovery-gap.err"
then
  echo "continuity validator accepted a post-recovery payload outage" >&2
  exit 1
fi
grep -Fq "payload gap after recovery was 4400ms" \
  "$temp/post-recovery-gap.err"

printf '%s\n' \
  'NVPN_IOS_UNDERLAY_SWITCH_1_REQUESTED_MS=1' \
  'ordinary xcodebuild output' \
  'NVPN_IOS_UNDERLAY_SWITCH_1_AVAILABLE_MS=2' \
  'NVPN_IOS_UNDERLAY_SWITCH_1_PAYLOAD_RECOVERY_MS=200' \
  'NVPN_IOS_UNDERLAY_SWITCH_1_VERIFIED_MS=3' \
  'NVPN_IOS_UNDERLAY_SWITCH_2_REQUESTED_MS=4' \
  'NVPN_IOS_UNDERLAY_SWITCH_2_AVAILABLE_MS=5' \
  'NVPN_IOS_UNDERLAY_SWITCH_2_PAYLOAD_RECOVERY_MS=100' \
  'NVPN_IOS_UNDERLAY_SWITCH_2_VERIFIED_MS=6' \
  | python3 "$ios_output_capture" \
    "$temp/xcode.log" "$temp/ios-host-markers.tsv"
grep -Fxq 'ordinary xcodebuild output' "$temp/xcode.log"
python3 - "$temp/ios-host-markers.tsv" <<'PY'
import sys

rows = [
    line.rstrip().split("\t")
    for line in open(sys.argv[1], encoding="utf-8")
]
assert [row[0] for row in rows] == [
    "switch_1_requested",
    "switch_1_available",
    "switch_1_payload_recovery",
    "switch_1_verified",
    "switch_2_requested",
    "switch_2_available",
    "switch_2_payload_recovery",
    "switch_2_verified",
]
assert all(value.isdigit() for _, value in rows)
values = dict(rows)
assert values["switch_1_payload_recovery"] == "200"
assert values["switch_2_payload_recovery"] == "100"
timeline = [
    row for row in rows
    if not row[0].endswith("_payload_recovery")
]
assert all(
    int(current[1]) >= int(previous[1])
    for previous, current in zip(timeline, timeline[1:])
)
PY

cat >"$temp/adb" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "Wifi is disabled"
SH
chmod +x "$temp/adb"
bash -eu -c '
  source "$1"
  ADB="$2"
  serial="physical-device"
  android_underlay_wait_wifi_radio disabled 1
' _ "$android_lib" "$temp/adb"

bash -eu -o pipefail -c '
  source "$1"
  state="$2"
  calls="$3"
  ADB="$4"
  TMPDIR="$(dirname "$state")"
  select_physical_android_serial() { printf "%s\n" physical-device; }
  mobile_ios_hotspot_read_existing_config() {
    local enabled=false
    [[ ! -s "$state" ]] || enabled="$(<"$state")"
    printf "%s|%s|%s\n" \
      dGVzdC1ob3RzcG90 "$enabled" dGVzdC1wYXNzd29yZA==
  }
  mobile_ios_hotspot_probe_pixel_native() { return 0; }
  mobile_ios_home_wifi_from_host() { printf "%s\n" test-home; }
  mobile_ios_hotspot_set_enabled() {
    printf "%s\n" "$1" >"$state"
    printf "%s\n" "$1" >>"$calls"
  }
  mobile_ios_hotspot_is_serving() {
    [[ -s "$state" && "$(<"$state")" == true ]]
  }
  mobile_ios_hotspot_prepare
  private_state="$MOBILE_IOS_HOTSPOT_STATE_FILE"
  [[ "$(stat -f %Lp "$private_state")" == 600 ]]
  mobile_ios_hotspot_cleanup
  [[ "$(<"$calls")" == $'\''true\nfalse'\'' ]]
  [[ "$(<"$state")" == false ]]
  [[ ! -e "$private_state" ]]
  [[ "$MOBILE_IOS_HOTSPOT_CLEANUP_ARMED" -eq 0 ]]
' _ "$ios_hotspot" "$temp/hotspot-state" "$temp/hotspot-calls" "$temp/adb"

for required in \
  NVPN_ANDROID_UNDERLAY_HOME_SSID \
  NVPN_ANDROID_UNDERLAY_ALTERNATE_SSID \
  android_underlay_wait_for_rebind_after \
  run_android_tun_packet_probe \
  run_android_exit_network_probe
do
  grep -Fq "$required" "$android_lib" \
    || { echo "Android underlay gate is missing $required" >&2; exit 1; }
done
grep -Fq 'run_android_underlay_network_change_gate' "$android_smoke" \
  || { echo "Android smoke does not execute its physical underlay gate" >&2; exit 1; }
for selector in vpn-toggle wireguard-enabled wireguard-config wireguard-save; do
  grep -Fq "id = \"$selector\"" \
    "$ROOT/android/app/src/main/java/org/nostrvpn/app/AndroidComponents.kt" \
    "$ROOT/android/app/src/main/java/org/nostrvpn/app/AndroidShell.kt" \
    || {
      echo "Android production UI is missing release-gate selector $selector" >&2
      exit 1
    }
  grep -Fq ".accessibilityIdentifier(\"$selector\")" \
    "$ROOT/ios/Sources/DevicesViews.swift" \
    "$ROOT/ios/Sources/SettingsViews.swift" \
    || {
      echo "iOS production UI is missing release-gate selector $selector" >&2
      exit 1
    }
done
if grep -Fq 'cmd wifi force-reconnect' "$android_lib"; then
  echo "Android underlay restore uses an unsupported Pixel Wi-Fi shell command" >&2
  exit 1
fi
grep -Fq 'shell svc wifi disable' "$android_lib" \
  && grep -Fq 'shell svc wifi enable' "$android_lib" \
  || { echo "Android saved-home restore does not force a real Wi-Fi reassociation" >&2; exit 1; }
grep -Fq 'selectWiFiNetwork(' "$ios_underlay" \
  && grep -Fq 'ssid: spec.underlayAlternateSsid' "$ios_underlay" \
  && grep -Fq 'ssid: spec.underlayHomeSsid' "$ios_underlay" \
  && grep -Fq 'try selectedWiFiSSID() == spec.underlayHomeSsid' "$ios_underlay" \
  || { echo "iOS underlay XCTest does not select both exact real SSIDs" >&2; exit 1; }
if grep -Fq 'tapControlCenterWiFi' "$ios_test" "$ios_underlay"; then
  echo "iOS underlay XCTest still substitutes a radio toggle for a real SSID change" >&2
  exit 1
fi
grep -Fq 'waitForPhysicalPath' "$ios_underlay" \
  || { echo "iOS underlay XCTest does not prove the replacement path is available" >&2; exit 1; }
grep -Fq 'ProcessInfo.processInfo.systemUptime' \
  "$ios_underlay" \
  && grep -Fq 'PAYLOAD_RECOVERY_MS=' \
    "$ios_underlay" \
  || {
    echo "iOS Release underlay XCTest lacks same-clock payload recovery evidence" >&2
    exit 1
  }
for required in \
  'android.settings.TETHER_SETTINGS' \
  'Hotspot password' \
  'chmod 600 "$MOBILE_IOS_HOTSPOT_STATE_FILE"' \
  'mCurrentSoftApInfoMap' \
  'mobile_ios_hotspot_probe_pixel_native' \
  'mobile_ios_home_wifi_from_host' \
  'mobile_ios_hotspot_set_enabled "$previous_enabled"'
do
  grep -Fq "$required" "$ios_hotspot" \
    || { echo "iOS Pixel-hotspot lifecycle is missing $required" >&2; exit 1; }
done
grep -Fq 'source "$ROOT/scripts/lib-mobile-ios-hotspot.sh"' "$mobile_exit_gate" \
  && grep -Fq 'mobile_ios_hotspot_prepare' "$mobile_exit_gate" \
  && grep -Fq 'mobile_ios_hotspot_cleanup' "$mobile_exit_gate" \
  || {
    echo "iOS physical gate does not own the Pixel hotspot lifecycle" >&2
    exit 1
  }
if grep -Eq '(echo|printf).*(PASSPHRASE|expected_passphrase)' "$ios_hotspot"; then
  echo "iOS Pixel-hotspot lifecycle could expose a private credential" >&2
  exit 1
fi
grep -Fq 'last_failed_lower_bound_ms="$check_started_ms"' "$android_lib" \
  && grep -Fq 'android_underlay_unique_udp_echo' "$android_lib" \
  && grep -Fq 'switch_%s_payload_recovery' "$android_lib" \
  || {
    echo "Android Release underlay gate lacks conservative unique-payload timing" >&2
    exit 1
  }
grep -Fq 'iputils-ping' "$fixture" \
  || { echo "mobile fixture cannot generate continuous bidirectional payload" >&2; exit 1; }
grep -Fq 'add_system_firewall_rule' "$remote_fixture" \
  && grep -Fq 'remove_system_firewall_rules' "$remote_fixture" \
  && grep -Fq 'iifname "$interface" accept' "$remote_fixture" \
  || {
    echo "remote native fixture cannot cross a host policy-drop firewall safely" >&2
    exit 1
  }

android_position="$(grep -n 'Android physical Wi-Fi underlay change' "$release_gate" | head -n1 | cut -d: -f1)"
ios_position="$(grep -n 'iOS physical Wi-Fi/Pixel-hotspot underlay change' "$release_gate" | head -n1 | cut -d: -f1)"
if [[ -z "$android_position" || -z "$ios_position" ]] \
  || (( android_position >= ios_position ))
then
  echo "release gate does not isolate the two physical underlay lanes serially" >&2
  exit 1
fi
grep -Fq 'NVPN_MOBILE_WG_EXIT_REUSE_ANDROID_BUILD=1' "$release_gate" \
  && grep -Fq 'NVPN_MOBILE_WG_EXIT_REUSE_IOS_BUILD=1' "$release_gate" \
  || {
    echo "release underlay gates do not reuse the exact signed DNS artifacts" >&2
    exit 1
  }
grep -Fq 'xcrun devicectl device info details' "$release_gate" \
  && grep -Fq 'xcrun xcdevice list --timeout 5' "$release_gate" \
  && ! grep -Fq 'xcrun xctrace list devices' "$release_gate" \
  || {
    echo "release iOS preflight still trusts stale xctrace device state" >&2
    exit 1
  }

echo "Mobile physical underlay-change harness passed"
