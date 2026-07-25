#!/usr/bin/env bash

load_mobile_env() {
  local root="$1"
  local env_file="${NVPN_MOBILE_ENV_FILE:-$root/.env.mobile.local}"

  if [[ -f "$env_file" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$env_file"
    set +a
  fi
}

select_physical_android_serial() {
  local adb="$1"
  local requested="${2:-}"
  local selected=""

  if [[ -n "$requested" ]]; then
    if [[ "$requested" == emulator-* ]]; then
      printf 'Physical Android test refuses emulator serial %s\n' "$requested" >&2
      return 1
    fi
    if ! "$adb" devices 2>/dev/null | awk -v requested="$requested" '
      NR > 1 && $1 == requested && $2 == "device" { found = 1 }
      END { exit !found }
    '; then
      printf 'Requested physical Android device is not online: %s\n' "$requested" >&2
      return 1
    fi
    printf '%s\n' "$requested"
    return
  fi

  selected="$("$adb" devices 2>/dev/null | awk '
    NR > 1 && $2 == "device" && $1 !~ /^emulator-/ {
      print $1
      exit
    }
  ')"
  if [[ -z "$selected" ]]; then
    printf 'No physical Android device is online; emulators do not satisfy this test\n' >&2
    return 1
  fi
  printf '%s\n' "$selected"
}

select_physical_ios_device() {
  local requested="${1:-${NVPN_IOS_DEVICE:-${NVPN_IOS_DEVICE_ID:-}}}"
  local selected=""
  local status=0

  if [[ -n "$requested" ]]; then
    if ! xcrun devicectl device info details --device "$requested" >/dev/null 2>&1; then
      printf 'Requested physical iOS device is not online\n' >&2
      return 1
    fi
    printf '%s\n' "$requested"
    return
  fi

  selected="$(xcrun xctrace list devices 2>/dev/null | awk '
    /^== Devices ==/ { in_devices = 1; next }
    /^== Devices Offline ==/ || /^== Simulators ==/ { in_devices = 0 }
    in_devices && /iPhone|iPad/ {
      device = $0
      sub(/^.*\(/, "", device)
      sub(/\)[[:space:]]*$/, "", device)
      if (device ~ /^[0-9A-Fa-f-]{8,}$/) devices[++count] = device
    }
    END {
      if (count == 1) { print devices[1]; exit 0 }
      if (count > 1) exit 2
      exit 1
    }
  ')" || status=$?
  case "$status" in
    0)
      printf '%s\n' "$selected"
      ;;
    2)
      printf 'Multiple physical iOS devices are online; set NVPN_IOS_DEVICE\n' >&2
      return 1
      ;;
    *)
      printf 'No physical iOS device is online\n' >&2
      return 1
      ;;
  esac
}

resolve_physical_ios_udid() {
  local device="$1"
  local details_file udid
  details_file="$(mktemp "${TMPDIR:-/tmp}/nvpn-ios-device-details.XXXXXX")"
  if ! xcrun devicectl device info details \
    --device "$device" \
    --json-output "$details_file" \
    --quiet >/dev/null
  then
    rm -f "$details_file"
    printf 'Could not inspect the selected physical iOS device\n' >&2
    return 1
  fi
  udid="$(python3 - "$details_file" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    details = json.load(handle)
value = details.get("result", {}).get("hardwareProperties", {}).get("udid")
if not isinstance(value, str) or not value.strip():
    raise SystemExit(1)
print(value.strip())
PY
  )" || {
    rm -f "$details_file"
    printf 'The selected physical iOS device did not report a hardware UDID\n' >&2
    return 1
  }
  rm -f "$details_file"
  printf '%s\n' "$udid"
}

ios_device_launch() {
  local device="$1"
  local bundle_id="$2"
  shift 2

  if [[ "$#" -eq 0 ]]; then
    xcrun devicectl device process launch \
      --device "$device" \
      --activate \
      "$bundle_id"
    return
  fi

  local encoded_arguments
  encoded_arguments="$(python3 - "$@" <<'PY'
import base64
import json
import sys

payload = json.dumps(sys.argv[1:], separators=(",", ":")).encode()
print(base64.urlsafe_b64encode(payload).decode().rstrip("="))
PY
)"
  xcrun devicectl device process launch \
    --device "$device" \
    --activate \
    --payload-url "nvpn://debug/automation?arguments=$encoded_arguments" \
    "$bundle_id"
}
