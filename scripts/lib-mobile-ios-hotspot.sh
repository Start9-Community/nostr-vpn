#!/usr/bin/env bash

# Host-side lifecycle for the physical Android hotspot used by the iOS
# Wi-Fi-to-Wi-Fi roaming gate. Credentials and SSIDs remain runtime-only.

MOBILE_IOS_HOTSPOT_CLEANUP_ARMED=0
MOBILE_IOS_HOTSPOT_ANDROID_SERIAL=""
MOBILE_IOS_HOTSPOT_STATE_FILE=""
MOBILE_IOS_HOTSPOT_PREVIOUS_ENABLED=""

mobile_ios_hotspot_dump_ui() {
  local remote="/sdcard/nvpn-hotspot-ui-$$.xml"
  local payload status=0
  "$ADB" -s "$MOBILE_IOS_HOTSPOT_ANDROID_SERIAL" shell \
    uiautomator dump "$remote" >/dev/null 2>&1 || status=1
  if [[ "$status" -eq 0 ]]; then
    payload="$(
      "$ADB" -s "$MOBILE_IOS_HOTSPOT_ANDROID_SERIAL" exec-out \
        cat "$remote" 2>/dev/null
    )" || status=1
  fi
  "$ADB" -s "$MOBILE_IOS_HOTSPOT_ANDROID_SERIAL" shell \
    rm -f "$remote" >/dev/null 2>&1 || true
  [[ "$status" -eq 0 ]] || return "$status"
  printf '%s' "$payload"
}

mobile_ios_hotspot_tap_text() {
  local position
  position="$(
    mobile_ios_hotspot_dump_ui \
      | python3 -c '
import re
import sys
import xml.etree.ElementTree as ET

root = ET.fromstring(sys.stdin.read())
parents = {
    child: parent
    for parent in root.iter()
    for child in parent
}
targets = set(sys.argv[1:])
matches = [
    node for node in root.iter("node")
    if node.attrib.get("text") in targets
]
if len(matches) != 1:
    raise SystemExit(f"expected one shipped Settings row, observed {len(matches)}")
node = matches[0]
while node is not None and node.attrib.get("clickable") != "true":
    node = parents.get(node)
if node is None:
    raise SystemExit("shipped Settings row was not clickable")
match = re.fullmatch(
    r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]",
    node.attrib.get("bounds", ""),
)
if match is None:
    raise SystemExit("shipped Settings row has no bounds")
left, top, right, bottom = map(int, match.groups())
print(f"{(left + right) // 2}|{(top + bottom) // 2}")
' "$@"
  )" || return 1
  local x="${position%%|*}" y="${position#*|}"
  "$ADB" -s "$MOBILE_IOS_HOTSPOT_ANDROID_SERIAL" shell \
    input tap "$x" "$y" >/dev/null
}

mobile_ios_hotspot_ui_switch() {
  local expected_ssid="$1"
  mobile_ios_hotspot_dump_ui \
    | python3 -c '
import re
import sys
import xml.etree.ElementTree as ET

expected_ssid = sys.argv[1]
root = ET.fromstring(sys.stdin.read())
nodes = list(root.iter("node"))
visible = " ".join(
    f"{node.attrib.get('text', '')} {node.attrib.get('content-desc', '')}"
    for node in nodes
)
if expected_ssid not in visible:
    raise SystemExit("hotspot settings do not show the expected private SSID")
switches = [
    node for node in nodes
    if node.attrib.get("class") == "android.widget.Switch"
    or node.attrib.get("resource-id", "").endswith("switch_widget")
]
if len(switches) != 1:
    raise SystemExit(f"expected one hotspot switch, observed {len(switches)}")
switch = switches[0]
match = re.fullmatch(
    r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]",
    switch.attrib.get("bounds", ""),
)
if match is None:
    raise SystemExit("hotspot switch has no bounds")
left, top, right, bottom = map(int, match.groups())
checked = switch.attrib.get("checked", "false").lower()
print(f"{checked}|{(left + right) // 2}|{(top + bottom) // 2}")
' "$expected_ssid"
}

mobile_ios_hotspot_open_settings() {
  "$ADB" -s "$MOBILE_IOS_HOTSPOT_ANDROID_SERIAL" shell am start \
    -a android.settings.TETHER_SETTINGS >/dev/null || return 1
  local deadline=$((SECONDS + 10))
  while ((SECONDS < deadline)); do
    if mobile_ios_hotspot_tap_text "Wi-Fi hotspot" "Wi‑Fi hotspot"; then
      break
    fi
    sleep 0.2
  done
  while ((SECONDS < deadline)); do
    if mobile_ios_hotspot_dump_ui \
      | python3 -c '
import sys
import xml.etree.ElementTree as ET

root = ET.fromstring(sys.stdin.read())
raise SystemExit(
    0 if any(
        node.attrib.get("text") == "Hotspot name"
        for node in root.iter("node")
    ) else 1
)
'
    then
      return 0
    fi
    sleep 0.2
  done
  echo "Pixel shipped Settings did not open Wi-Fi hotspot details" >&2
  return 1
}

mobile_ios_hotspot_read_existing_config() {
  mobile_ios_hotspot_open_settings || return 1
  local summary password
  summary="$(
    mobile_ios_hotspot_dump_ui \
      | python3 -c '
import base64
import sys
import xml.etree.ElementTree as ET

root = ET.fromstring(sys.stdin.read())
parents = {
    child: parent
    for parent in root.iter()
    for child in parent
}
title = next(
    node for node in root.iter("node")
    if node.attrib.get("text") == "Hotspot name"
)
parent = parents.get(title)
ssid = None
while parent is not None:
    summaries = [
        node.attrib.get("text", "")
        for node in parent.iter("node")
        if node.attrib.get("resource-id", "").endswith("/summary")
    ]
    if len(summaries) == 1:
        ssid = summaries[0]
        break
    parent = parents.get(parent)
switches = [
    node for node in root.iter("node")
    if node.attrib.get("resource-id", "").endswith("/switch_widget")
]
if not ssid or len(switches) != 1:
    raise SystemExit("could not read exact hotspot name/state from shipped Settings")
print(
    base64.b64encode(ssid.encode()).decode()
    + "|"
    + switches[0].attrib.get("checked", "false").lower()
)
'
  )" || return 1
  mobile_ios_hotspot_tap_text "Hotspot password" || return 1
  local deadline=$((SECONDS + 8))
  password=""
  while ((SECONDS < deadline)); do
    password="$(
      mobile_ios_hotspot_dump_ui \
        | python3 -c '
import base64
import sys
import xml.etree.ElementTree as ET

root = ET.fromstring(sys.stdin.read())
fields = [
    node.attrib.get("text", "")
    for node in root.iter("node")
    if node.attrib.get("class") == "android.widget.EditText"
]
if len(fields) != 1 or len(fields[0]) < 8:
    raise SystemExit(1)
print(base64.b64encode(fields[0].encode()).decode())
' 2>/dev/null
    )" || true
    [[ -n "$password" ]] && break
    sleep 0.2
  done
  mobile_ios_hotspot_tap_text "Cancel" || return 1
  [[ -n "$password" ]] || {
    echo "Pixel shipped Settings did not expose its existing hotspot credential" >&2
    return 1
  }
  printf '%s|%s\n' "$summary" "$password"
}

mobile_ios_home_wifi_from_host() {
  system_profiler SPAirPortDataType -json 2>/dev/null \
    | python3 -c '
import json
import sys

payload = json.load(sys.stdin)
names = []
for group in payload.get("SPAirPortDataType", []):
    for interface in group.get("spairport_airport_interfaces", []):
        current = interface.get("spairport_current_network_information", {})
        name = current.get("_name")
        if isinstance(name, str) and name:
            names.append(name)
if len(names) != 1:
    raise SystemExit("could not identify one current host Wi-Fi network")
print(names[0])
'
}

mobile_ios_hotspot_set_enabled() {
  local desired="$1" expected_ssid="$2" deadline state checked x y
  mobile_ios_hotspot_open_settings || return 1
  deadline=$((SECONDS + 12))
  state=""
  while ((SECONDS < deadline)); do
    state="$(mobile_ios_hotspot_ui_switch "$expected_ssid" 2>/dev/null || true)"
    [[ "$state" == *"|"* ]] && break
    sleep 0.2
  done
  [[ "$state" == *"|"* ]] || {
    echo "Android hotspot settings did not expose its exact switch" >&2
    return 1
  }
  IFS='|' read -r checked x y <<<"$state"
  if [[ "$checked" != "$desired" ]]; then
    "$ADB" -s "$MOBILE_IOS_HOTSPOT_ANDROID_SERIAL" shell input tap "$x" "$y"
  fi
  deadline=$((SECONDS + 15))
  while ((SECONDS < deadline)); do
    state="$(mobile_ios_hotspot_ui_switch "$expected_ssid" 2>/dev/null || true)"
    checked="${state%%|*}"
    [[ "$checked" == "$desired" ]] && return 0
    sleep 0.2
  done
  echo "Android hotspot switch did not reach the requested state" >&2
  return 1
}

mobile_ios_hotspot_is_serving() {
  local expected_ssid="$1" dump
  dump="$(
    "$ADB" -s "$MOBILE_IOS_HOTSPOT_ANDROID_SERIAL" shell \
      dumpsys wifi 2>/dev/null
  )" || return 1
  EXPECTED_SSID="$expected_ssid" python3 -c '
import os
import re
import sys

dump = sys.stdin.read()
ssid = os.environ["EXPECTED_SSID"]
if f"ssid = \"{ssid}\"" not in dump:
    raise SystemExit(1)
match = re.search(r"mCurrentSoftApInfoMap \{([^}]*)\}", dump)
if match is None or not match.group(1).strip():
    raise SystemExit(1)
' <<<"$dump"
}

mobile_ios_hotspot_probe_pixel_native() {
  local fixture_host="${NVPN_MOBILE_WG_EXIT_HOST_IP:-}"
  local public_host="${NVPN_MOBILE_WG_EXIT_DIRECT_HOST:-example.com}"
  [[ -n "$fixture_host" ]] || {
    echo "iOS hotspot gate requires the independently reachable fixture host" >&2
    return 1
  }
  "$ADB" -s "$MOBILE_IOS_HOTSPOT_ANDROID_SERIAL" shell \
    ping -c 1 -W 3 "$fixture_host" >/dev/null 2>&1 \
    && "$ADB" -s "$MOBILE_IOS_HOTSPOT_ANDROID_SERIAL" shell \
      ping -c 1 -W 3 "$public_host" >/dev/null 2>&1
}

mobile_ios_hotspot_prepare() {
  local requested="${NVPN_IOS_HOTSPOT_ANDROID_SERIAL:-${NVPN_ANDROID_SERIAL:-}}"
  local captured ssid_b64 previous_enabled passphrase_b64
  local expected_ssid expected_passphrase
  MOBILE_IOS_HOTSPOT_ANDROID_SERIAL="$(
    select_physical_android_serial "$ADB" "$requested"
  )" || return 1
  captured="$(mobile_ios_hotspot_read_existing_config)" || return 1
  IFS='|' read -r ssid_b64 previous_enabled passphrase_b64 <<<"$captured"
  expected_ssid="$(
    python3 -c 'import base64,sys; print(base64.b64decode(sys.argv[1]).decode())' \
      "$ssid_b64"
  )" || return 1
  expected_passphrase="$(
    python3 -c 'import base64,sys; print(base64.b64decode(sys.argv[1]).decode())' \
      "$passphrase_b64"
  )" || return 1
  [[ -n "$expected_ssid" && ${#expected_passphrase} -ge 8 \
    && "$previous_enabled" =~ ^(true|false)$ ]] || {
    echo "Pixel existing hotspot configuration was incomplete" >&2
    return 1
  }
  export NVPN_IOS_UNDERLAY_ALTERNATE_SSID="$expected_ssid"
  export NVPN_IOS_UNDERLAY_ALTERNATE_PASSPHRASE="$expected_passphrase"
  if [[ -z "${NVPN_IOS_UNDERLAY_HOME_SSID:-}" ]]; then
    NVPN_IOS_UNDERLAY_HOME_SSID="$(mobile_ios_home_wifi_from_host)" || {
      echo "iOS hotspot gate could not derive the unchanged host home Wi-Fi" >&2
      return 1
    }
    export NVPN_IOS_UNDERLAY_HOME_SSID
  fi
  NVPN_IOS_UNDERLAY_HOME_PASSPHRASE="${NVPN_IOS_UNDERLAY_HOME_PASSPHRASE:-}"
  export NVPN_IOS_UNDERLAY_HOME_PASSPHRASE
  umask 077
  MOBILE_IOS_HOTSPOT_STATE_FILE="$(
    mktemp "${TMPDIR:-/tmp}/nvpn-ios-hotspot-state.XXXXXX"
  )"
  chmod 600 "$MOBILE_IOS_HOTSPOT_STATE_FILE"
  printf '%s\t%s\n' \
    "$ssid_b64" "$passphrase_b64" \
    >"$MOBILE_IOS_HOTSPOT_STATE_FILE"
  MOBILE_IOS_HOTSPOT_PREVIOUS_ENABLED="$previous_enabled"
  MOBILE_IOS_HOTSPOT_CLEANUP_ARMED=1
  mobile_ios_hotspot_probe_pixel_native || {
    echo "Pixel did not have independent native fixture/Internet reachability" >&2
    return 1
  }
  mobile_ios_hotspot_set_enabled true "$expected_ssid" || return 1
  local deadline=$((SECONDS + 15))
  while ((SECONDS < deadline)); do
    if mobile_ios_hotspot_is_serving "$expected_ssid"; then
      echo "Pixel physical hotspot is enabled and serving the private alternate SSID"
      return 0
    fi
    sleep 0.2
  done
  echo "Pixel hotspot never exposed a serving SoftAP interface" >&2
  return 1
}

mobile_ios_hotspot_cleanup() {
  [[ "$MOBILE_IOS_HOTSPOT_CLEANUP_ARMED" -eq 1 ]] || return 0
  local ssid_b64 passphrase_b64
  local previous_enabled="$MOBILE_IOS_HOTSPOT_PREVIOUS_ENABLED"
  local expected_ssid current
  local failed=0
  if ! IFS=$'\t' read -r ssid_b64 passphrase_b64 \
    <"$MOBILE_IOS_HOTSPOT_STATE_FILE"
  then
    echo "Pixel hotspot cleanup state was unavailable" >&2
    failed=1
    ssid_b64=""
  fi
  expected_ssid="$(
    python3 -c 'import base64,sys; print(base64.b64decode(sys.argv[1]).decode())' \
      "$ssid_b64"
  )" || failed=1
  if [[ -n "$expected_ssid" ]]; then
    current="$(mobile_ios_hotspot_read_existing_config)" || failed=1
    if [[ "$current" != "$ssid_b64|$previous_enabled|$passphrase_b64" \
      && "$current" != "$ssid_b64|true|$passphrase_b64" ]]
    then
      echo "Pixel hotspot configuration changed during the iOS gate" >&2
      failed=1
    fi
    mobile_ios_hotspot_set_enabled "$previous_enabled" "$expected_ssid" || failed=1
    if [[ "$previous_enabled" == "true" ]]; then
      mobile_ios_hotspot_is_serving "$expected_ssid" || {
        echo "Pixel hotspot prior enabled state was not restored" >&2
        failed=1
      }
    elif mobile_ios_hotspot_is_serving "$expected_ssid"; then
      echo "Pixel hotspot prior disabled state was not restored" >&2
      failed=1
    fi
  fi
  mobile_ios_hotspot_probe_pixel_native || {
    echo "Pixel native Internet did not recover after hotspot cleanup" >&2
    failed=1
  }
  rm -f "$MOBILE_IOS_HOTSPOT_STATE_FILE"
  MOBILE_IOS_HOTSPOT_STATE_FILE=""
  MOBILE_IOS_HOTSPOT_PREVIOUS_ENABLED=""
  MOBILE_IOS_HOTSPOT_CLEANUP_ARMED=0
  return "$failed"
}
