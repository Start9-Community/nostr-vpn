#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/release_common.sh"
# shellcheck disable=SC1091
source "$ROOT/scripts/mobile_env.sh"
load_release_env "$ROOT"
load_mobile_env "$ROOT"
resolve_shared_build_metadata "$ROOT"
PACKAGE_NAME="${NVPN_ANDROID_PACKAGE:-${NVPN_DEFAULT_APP_ID:-fi.siriusbusiness.nvpn}}"
ACTION_PACKAGE_NAME="${NVPN_ANDROID_ACTION_PACKAGE:-${NVPN_DEFAULT_APP_ID:-fi.siriusbusiness.nvpn}}"
MAIN_ACTIVITY="${NVPN_ANDROID_ACTIVITY:-$PACKAGE_NAME/org.nostrvpn.app.MainActivity}"
DEBUG_ACTION_EXTRA="${NVPN_ANDROID_DEBUG_ACTION_EXTRA:-$ACTION_PACKAGE_NAME.DEBUG_ACTION}"
DEBUG_EXIT_NODE_EXTRA="${NVPN_ANDROID_DEBUG_EXIT_NODE_EXTRA:-$ACTION_PACKAGE_NAME.DEBUG_EXIT_NODE}"
DEBUG_NETWORK_NAME_EXTRA="${NVPN_ANDROID_DEBUG_NETWORK_NAME_EXTRA:-$ACTION_PACKAGE_NAME.DEBUG_NETWORK_NAME}"
DEBUG_WIREGUARD_CONFIG_BASE64_EXTRA="${NVPN_ANDROID_DEBUG_WIREGUARD_CONFIG_BASE64_EXTRA:-$ACTION_PACKAGE_NAME.DEBUG_WIREGUARD_CONFIG_BASE64}"
APK_PATH="${NVPN_ANDROID_APK:-$ROOT/android/app/build/outputs/apk/debug/app-debug.apk}"
VPN_START_WAIT_SECS="${NVPN_ANDROID_VPN_START_WAIT_SECS:-15}"
VPN_STOP_WAIT_SECS="${NVPN_ANDROID_VPN_STOP_WAIT_SECS:-10}"
RUNTIME_STATE_WAIT_SECS="${NVPN_ANDROID_RUNTIME_STATE_WAIT_SECS:-12}"
RUNTIME_STATE_MAX_AGE_SECS="${NVPN_ANDROID_RUNTIME_STATE_MAX_AGE_SECS:-60}"
RUNTIME_STATE_RESULT_DIR="${NVPN_ANDROID_RESULT_DIR:-$ROOT/artifacts/mobile-android}"
RUNTIME_STATE_RESULT_NAME="${NVPN_ANDROID_RUNTIME_STATE_RESULT_NAME:-mobile-android-runtime-state-$$.json}"
ANDROID_BUILD_METADATA_RESULT_NAME="${NVPN_ANDROID_BUILD_METADATA_RESULT_NAME:-mobile-android-build-metadata-$$.json}"
ANDROID_IDLE_CPU_RESULT_NAME="${NVPN_ANDROID_IDLE_CPU_RESULT_NAME:-mobile-android-idle-cpu-$$.json}"
VPN_LINK_STATS_RESULT_NAME="mobile-android-vpn-link-stats-$$.txt"
VPN_LINK_STATS_SUMMARY_RESULT_NAME="mobile-android-vpn-link-stats-summary-$$.tsv"
PING_PROBE_RESULT_NAME="mobile-android-ping-probe-$$.txt"
PING_PROBE_SUMMARY_RESULT_NAME="mobile-android-ping-probe-summary-$$.json"
TUN_PACKET_PROBE_SUMMARY_RESULT_NAME="mobile-android-tun-probe-summary-$$.json"
TUN_PACKET_PROBE="${NVPN_ANDROID_TUN_PACKET_PROBE:-1}"
TUN_PACKET_PROBE_TARGET="${NVPN_ANDROID_TUN_PACKET_PROBE_TARGET:-10.44.255.254}"
TUN_PACKET_PROBE_COUNT="${NVPN_ANDROID_TUN_PACKET_PROBE_COUNT:-4}"
TUN_PACKET_PROBE_WAIT_SECS="${NVPN_ANDROID_TUN_PACKET_PROBE_WAIT_SECS:-15}"
TUN_PACKET_PROBE_TIMEOUT_SECS="${NVPN_ANDROID_TUN_PACKET_PROBE_TIMEOUT_SECS:-1}"
TUN_PACKET_PROBE_REQUIRE_REPLY="${NVPN_ANDROID_TUN_PACKET_PROBE_REQUIRE_REPLY:-0}"
EXIT_PROBE_HOST="${NVPN_ANDROID_EXIT_PROBE_HOST:-}"
EXIT_PROBE_EXPECTED_IP="${NVPN_ANDROID_EXIT_PROBE_EXPECTED_IP:-}"
DIRECT_PROBE_HOST="${NVPN_ANDROID_DIRECT_PROBE_HOST:-example.com}"
DIRECT_RESTORE_WAIT_SECS="${NVPN_ANDROID_DIRECT_RESTORE_WAIT_SECS:-20}"
EXPECTED_VPN_DNS="${NVPN_ANDROID_EXPECTED_VPN_DNS:-10.44.0.53}"
DEBUG_SEED_WAIT_SECS="${NVPN_ANDROID_DEBUG_SEED_WAIT_SECS:-10}"
DEBUG_EXIT_NODE="${NVPN_ANDROID_DEBUG_EXIT_NODE:-}"
DEBUG_WIREGUARD_CONFIG="${NVPN_ANDROID_DEBUG_WIREGUARD_CONFIG:-}"
DEBUG_WIREGUARD_CONFIG_FILE="${NVPN_ANDROID_DEBUG_WIREGUARD_CONFIG_FILE:-}"
DEBUG_NETWORK_NAME="${NVPN_ANDROID_DEBUG_NETWORK_NAME:-Android smoke}"
cleanup_after_vpn_cycle="${NVPN_ANDROID_CLEANUP_AFTER_VPN_CYCLE:-1}"
IDLE_CPU_GATE="${NVPN_ANDROID_IDLE_CPU_GATE:-${NVPN_IDLE_CPU_GATE:-1}}"
IDLE_CPU_MAX_PERCENT="${NVPN_ANDROID_IDLE_CPU_MAX_PERCENT:-${NVPN_IDLE_CPU_MAX_PERCENT:-5}}"
IDLE_CPU_SAMPLE_SECONDS="${NVPN_ANDROID_IDLE_CPU_SAMPLE_SECONDS:-${NVPN_IDLE_CPU_SAMPLE_SECONDS:-10}}"
IDLE_CPU_SETTLE_SECONDS="${NVPN_ANDROID_IDLE_CPU_SETTLE_SECONDS:-${NVPN_IDLE_CPU_SETTLE_SECONDS:-3}}"
ANDROID_LIFECYCLE_GATE="${NVPN_ANDROID_LIFECYCLE_GATE:-1}"
ANDROID_LIFECYCLE_BACKGROUND_DWELL_SECS="${NVPN_ANDROID_LIFECYCLE_BACKGROUND_DWELL_SECS:-2}"

build=1
clear_state=0
create_network="${NVPN_ANDROID_DEBUG_CREATE_NETWORK:-0}"
accept_vpn_dialog="${NVPN_ANDROID_ACCEPT_VPN_DIALOG:-0}"
vpn_cycle=0
serial="${NVPN_ANDROID_SERIAL:-${ANDROID_SERIAL:-}}"
PACKAGE_UID=""
vpn_cleanup_armed=0

usage() {
  cat >&2 <<'EOF'
usage: scripts/mobile-android-smoke.sh [--no-build] [--clear] [--vpn-cycle] [--create-network] [--accept-vpn-dialog] [--leave-vpn-active] [--serial SERIAL] [--probe-target IP] [--probe-count N] [--probe-timeout SECS] [--probe-require-reply] [--no-tun-probe]

Builds and installs the debug APK, launches the app through adb, and optionally
cycles the debug VPN action. Values may live in .env.mobile.local, shell env,
or --serial. Keep device identifiers and signing details out of committed files.
The installed debug app must report build metadata matching this repo checkout.
Every smoke backgrounds and foregrounds the Activity and requires the same app
process to survive and resume.

First-run Android VPN permission prompts may need manual approval before
--vpn-cycle can run unattended.

For fresh installs, --vpn-cycle needs an active nvpn network. Use
--create-network for local OS VPN/TUN coverage, or approve the device's signed
join request from an admin device before running peer dataplane coverage.

Use --create-network for a local OS VPN/TUN smoke when peer dataplane coverage is
not required. It creates a debug-only local network named by
NVPN_ANDROID_DEBUG_NETWORK_NAME, then cycles the VPN.

Use --accept-vpn-dialog only on trusted local test devices; it taps Android's
system VPN consent OK button if the prompt appears.

When --vpn-cycle reaches Android's active VPN service/network state, this script
also copies files/app-core/mobile-runtime-state.json from the debug app sandbox
and requires fresh Rust runtime state with native TUN counter fields. It also
captures Android's own VPN interface counters from `ip -s link` or
`/proc/net/dev` under artifacts/mobile-android, plus normalized link-counter
summary rows.

By default --vpn-cycle also sends a small shell ping probe toward a non-local
10.44/16 address and requires tunPacketsRead to increase by at least the probe
count. The ping output is saved under artifacts/mobile-android so physical peer
targets preserve loss/jitter evidence; a separate TUN counter summary JSON records
the native packet observation. Use --probe-target with --probe-require-reply for
a reachable peer row that requires ping replies plus native TUN write counters.
Disable with --no-tun-probe if a device image lacks ping.

When NVPN_ANDROID_EXIT_PROBE_HOST is set, the cycle additionally proves a full
Direct -> WireGuard exit -> Direct transition. The named host must resolve only
through the fixture/profile DNS; NVPN_ANDROID_EXIT_PROBE_EXPECTED_IP pins its
answer. Public DNS and Internet reachability are checked before connect, while
the exit is active, and after disconnect. The Android VPN network must advertise
the local authenticated DNS stub (10.44.0.53 by default).

After a --vpn-cycle pass or failure, the script disconnects the debug VPN so
devices are left clean for the next smoke. Use --leave-vpn-active to preserve
the tunnel for explicit manual inspection.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-build)
      build=0
      ;;
    --clear)
      clear_state=1
      ;;
    --create-network)
      create_network=1
      ;;
    --accept-vpn-dialog)
      accept_vpn_dialog=1
      ;;
    --leave-vpn-active)
      cleanup_after_vpn_cycle=0
      ;;
    --vpn-cycle)
      vpn_cycle=1
      ;;
    --serial)
      if [[ $# -lt 2 ]]; then
        echo "--serial requires a value" >&2
        exit 2
      fi
      serial="$2"
      shift
      ;;
    --probe-target)
      if [[ $# -lt 2 ]]; then
        echo "--probe-target requires a value" >&2
        exit 2
      fi
      TUN_PACKET_PROBE_TARGET="$2"
      shift
      ;;
    --probe-count)
      if [[ $# -lt 2 ]]; then
        echo "--probe-count requires a value" >&2
        exit 2
      fi
      TUN_PACKET_PROBE_COUNT="$2"
      shift
      ;;
    --probe-timeout)
      if [[ $# -lt 2 ]]; then
        echo "--probe-timeout requires a value" >&2
        exit 2
      fi
      TUN_PACKET_PROBE_TIMEOUT_SECS="$2"
      shift
      ;;
    --probe-require-reply)
      TUN_PACKET_PROBE_REQUIRE_REPLY=1
      ;;
    --no-tun-probe)
      TUN_PACKET_PROBE=0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
  shift
done

sdk_from_local_properties() {
  local file="$ROOT/android/local.properties"
  if [[ -f "$file" ]]; then
    sed -n 's/^sdk\.dir=//p' "$file" | head -n 1
  fi
}

resolve_adb() {
  local sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
  if [[ -z "$sdk" ]]; then
    sdk="$(sdk_from_local_properties)"
  fi
  if [[ -z "$sdk" && -d "$HOME/Library/Android/sdk" ]]; then
    sdk="$HOME/Library/Android/sdk"
  fi
  if [[ -n "$sdk" && -x "$sdk/platform-tools/adb" ]]; then
    printf '%s\n' "$sdk/platform-tools/adb"
    return
  fi
  if command -v adb >/dev/null 2>&1; then
    command -v adb
    return
  fi
  echo "adb not found; set ANDROID_HOME/ANDROID_SDK_ROOT or add adb to PATH" >&2
  exit 1
}

select_serial() {
  local adb="$1"
  if [[ -n "$serial" ]]; then
    printf '%s\n' "$serial"
    return
  fi
  "$adb" devices | awk '
    NR > 1 && $2 == "device" {
      if (first == "") first = $1
      if ($1 ~ /^emulator-/) {
        print $1
        selected = 1
        exit
      }
    }
    END { if (!selected && first != "") print first }
  '
}

resolve_package_uid() {
  local adb="$1"
  local target_serial="$2"
  "$adb" -s "$target_serial" shell cmd package list packages -U "$PACKAGE_NAME" \
    | tr -d '\r' \
    | awk -F '[: ]+' -v package="$PACKAGE_NAME" \
      '$1 == "package" && $2 == package && $3 == "uid" { print $4; exit }'
}

vpn_service_running() {
  local services
  services="$("$ADB" -s "$serial" shell dumpsys activity services "$PACKAGE_NAME" 2>/dev/null | tr -d '\r')" || return 1
  awk '
    /ServiceRecord\{.*NostrVpnService/ {
      in_service = 1
      next
    }
    in_service && /^[[:space:]]*\* ServiceRecord/ {
      in_service = 0
    }
    in_service && /app=/ {
      if ($0 !~ /app=null/) found = 1
      in_service = 0
    }
    END { exit found ? 0 : 1 }
  ' <<<"$services"
}

vpn_network_active() {
  local connectivity
  connectivity="$("$ADB" -s "$serial" shell dumpsys connectivity 2>/dev/null | tr -d '\r')" || return 1
  grep -F 'ni{VPN CONNECTED' <<<"$connectivity" \
    | grep -Fq "OwnerUid: $PACKAGE_UID"
}

vpn_active() {
  vpn_service_running && vpn_network_active
}

vpn_state_present() {
  vpn_service_running || vpn_network_active
}

wait_until() {
  local timeout="$1"
  shift
  local start now
  start="$(date +%s)"
  while true; do
    if "$@"; then
      return 0
    fi
    now="$(date +%s)"
    if (( now - start >= timeout )); then
      return 1
    fi
    sleep 1
  done
}

vpn_inactive() {
  ! vpn_state_present
}

truthy() {
  [[ "$1" == "1" || "$1" == "true" || "$1" == "yes" ]]
}

epoch_ms() {
  python3 -c 'import time; print(int(time.time() * 1000))'
}

android_runtime_state_path() {
  printf '%s/%s\n' "$RUNTIME_STATE_RESULT_DIR" "$RUNTIME_STATE_RESULT_NAME"
}

android_build_metadata_path() {
  printf '%s/%s\n' "$RUNTIME_STATE_RESULT_DIR" "$ANDROID_BUILD_METADATA_RESULT_NAME"
}

android_idle_cpu_path() {
  printf '%s/%s\n' "$RUNTIME_STATE_RESULT_DIR" "$ANDROID_IDLE_CPU_RESULT_NAME"
}

run_android_idle_cpu_gate() {
  local label="$1"
  case "$IDLE_CPU_GATE" in
    0|false|FALSE|False|no|NO|No|off|OFF|Off)
      echo "Skipping Android idle CPU gate because NVPN_ANDROID_IDLE_CPU_GATE=$IDLE_CPU_GATE"
      return
      ;;
  esac
  "$ROOT/scripts/idle-cpu-gate.py" android-package \
    --adb "$ADB" \
    --serial "$serial" \
    --package "$PACKAGE_NAME" \
    --label "$label" \
    --artifact "$(android_idle_cpu_path)" \
    --max-percent "$IDLE_CPU_MAX_PERCENT" \
    --sample-seconds "$IDLE_CPU_SAMPLE_SECONDS" \
    --settle-seconds "$IDLE_CPU_SETTLE_SECONDS"
}

android_vpn_link_stats_path() {
  printf '%s/%s\n' "$RUNTIME_STATE_RESULT_DIR" "$VPN_LINK_STATS_RESULT_NAME"
}

android_vpn_link_stats_summary_path() {
  printf '%s/%s\n' "$RUNTIME_STATE_RESULT_DIR" "$VPN_LINK_STATS_SUMMARY_RESULT_NAME"
}

android_ping_probe_path() {
  printf '%s/%s\n' "$RUNTIME_STATE_RESULT_DIR" "$PING_PROBE_RESULT_NAME"
}

android_ping_probe_summary_path() {
  printf '%s/%s\n' "$RUNTIME_STATE_RESULT_DIR" "$PING_PROBE_SUMMARY_RESULT_NAME"
}

android_tun_packet_probe_summary_path() {
  printf '%s/%s\n' "$RUNTIME_STATE_RESULT_DIR" "$TUN_PACKET_PROBE_SUMMARY_RESULT_NAME"
}

android_network_probe_path() {
  local label="$1"
  printf '%s/mobile-android-network-%s-%s.txt\n' "$RUNTIME_STATE_RESULT_DIR" "$label" "$$"
}

android_vpn_dns_servers() {
  "$ADB" -s "$serial" shell dumpsys connectivity 2>/dev/null \
    | tr -d '\r' \
    | python3 -c '
import re
import sys

text = sys.stdin.read()
owner = sys.argv[1]
for block in re.split(r"(?=NetworkAgentInfo\{)", text):
    if "ni{VPN CONNECTED" not in block or f"OwnerUid: {owner}" not in block:
        continue
    match = re.search(r"DnsAddresses:\s*\[([^]]*)\]", block)
    if not match:
        sys.exit(1)
    for value in re.findall(r"/?([0-9a-fA-F:.]+)", match.group(1)):
        print(value)
    sys.exit(0)
sys.exit(1)
' "$PACKAGE_UID"
}

run_android_direct_network_probe() {
  local label="$1" result_path start now attempt always_on_app lockdown
  [[ -n "$EXIT_PROBE_HOST" ]] || return 0
  result_path="$(android_network_probe_path "$label")"
  mkdir -p "$RUNTIME_STATE_RESULT_DIR"
  if vpn_state_present; then
    echo "Android $label Direct probe failed: VPN state is still present" >&2
    return 1
  fi
  always_on_app="$("$ADB" -s "$serial" shell settings get secure always_on_vpn_app 2>/dev/null | tr -d '\r')"
  lockdown="$("$ADB" -s "$serial" shell settings get secure always_on_vpn_lockdown 2>/dev/null | tr -d '\r')"
  if [[ -n "$always_on_app" && "$always_on_app" != "null" && "$lockdown" == "1" ]]; then
    echo "Android $label Direct probe cannot run while system always-on VPN lockdown is enabled for $always_on_app" >&2
    return 1
  fi
  start="$(date +%s)"
  attempt=0
  : >"$result_path"
  while true; do
    attempt=$((attempt + 1))
    {
      printf 'label=%s attempt=%s elapsed=%ss host=%s\n' \
        "$label" "$attempt" "$(( $(date +%s) - start ))" "$DIRECT_PROBE_HOST"
      "$ADB" -s "$serial" shell ping -c 2 -W 3 "$DIRECT_PROBE_HOST"
    } >>"$result_path" 2>&1 && {
      echo "Android $label Direct DNS/Internet probe passed after $(( $(date +%s) - start ))s: $result_path"
      return 0
    }
    now="$(date +%s)"
    if (( now - start >= DIRECT_RESTORE_WAIT_SECS )); then
      echo "Android $label Direct DNS/Internet probe failed after $((now - start))s: $result_path" >&2
      return 1
    fi
    sleep 1
  done
}

run_android_exit_network_probe() {
  [[ -n "$EXIT_PROBE_HOST" ]] || return 0
  local dns_servers result_path resolved_ip
  result_path="$(android_network_probe_path wireguard-exit)"
  mkdir -p "$RUNTIME_STATE_RESULT_DIR"
  if ! dns_servers="$(android_vpn_dns_servers)"; then
    echo "Android WireGuard exit probe failed: active VPN DNS servers were unavailable" >&2
    return 1
  fi
  if ! grep -Fxq "$EXPECTED_VPN_DNS" <<<"$dns_servers"; then
    echo "Android WireGuard exit probe failed: VPN DNS is '$dns_servers', expected local stub $EXPECTED_VPN_DNS" >&2
    return 1
  fi
  {
    printf 'vpnDnsServers=%s\n' "$(tr '\n' ',' <<<"$dns_servers" | sed 's/,$//')"
    printf 'exitHost=%s\n' "$EXIT_PROBE_HOST"
    "$ADB" -s "$serial" shell ping -c 3 -W 3 "$EXIT_PROBE_HOST"
    printf 'publicHost=%s\n' "$DIRECT_PROBE_HOST"
    "$ADB" -s "$serial" shell ping -c 2 -W 3 "$DIRECT_PROBE_HOST"
  } >"$result_path" 2>&1 || {
    echo "Android WireGuard exit DNS/Internet probe failed: $result_path" >&2
    return 1
  }
  resolved_ip="$(sed -n 's/^PING [^(]*(\([^)]*\)).*/\1/p' "$result_path" | head -n 1)"
  if [[ -n "$EXIT_PROBE_EXPECTED_IP" && "$resolved_ip" != "$EXIT_PROBE_EXPECTED_IP" ]]; then
    echo "Android WireGuard exit DNS resolved $EXIT_PROBE_HOST to '$resolved_ip', expected $EXIT_PROBE_EXPECTED_IP: $result_path" >&2
    return 1
  fi
  echo "Android WireGuard exit DNS/Internet probe passed: $result_path DNS=$EXPECTED_VPN_DNS answer=$resolved_ip"
}

copy_android_runtime_state() {
  local result_path
  result_path="$(android_runtime_state_path)"
  mkdir -p "$RUNTIME_STATE_RESULT_DIR"
  rm -f "$result_path.tmp"
  if "$ADB" -s "$serial" exec-out \
    run-as "$PACKAGE_NAME" cat files/app-core/mobile-runtime-state.json \
    >"$result_path.tmp" 2>/dev/null && [[ -s "$result_path.tmp" ]]
  then
    mv "$result_path.tmp" "$result_path"
    return 0
  fi
  rm -f "$result_path.tmp"
  return 1
}

copy_android_build_metadata() {
  local result_path
  result_path="$(android_build_metadata_path)"
  mkdir -p "$RUNTIME_STATE_RESULT_DIR"
  rm -f "$result_path.tmp"
  if "$ADB" -s "$serial" exec-out \
    run-as "$PACKAGE_NAME" sh -c 'test -s files/app-core/android-build-metadata.json && cat files/app-core/android-build-metadata.json' \
    >"$result_path.tmp" 2>/dev/null && [[ -s "$result_path.tmp" ]]
  then
    mv "$result_path.tmp" "$result_path"
    return 0
  fi
  rm -f "$result_path.tmp"
  return 1
}

validate_android_build_metadata() {
  local result_path
  result_path="$(android_build_metadata_path)"
  python3 - "$result_path" "$NVPN_BUILD_GIT_SHA" "$PACKAGE_NAME" <<'PY'
import json
import sys

path, expected_build_git_sha, expected_package = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(path, encoding="utf-8") as fh:
        metadata = json.load(fh)
except (OSError, json.JSONDecodeError) as error:
    print(f"Android build metadata invalid JSON: {error}", file=sys.stderr)
    sys.exit(1)

errors = []
actual_package = metadata.get("appPackageName")
if actual_package != expected_package:
    errors.append(f"appPackageName={actual_package!r} expected={expected_package!r}")
actual_build_git_sha = metadata.get("appBuildGitSha")
if expected_build_git_sha:
    if not actual_build_git_sha:
        errors.append(f"appBuildGitSha missing expected={expected_build_git_sha!r}")
    elif actual_build_git_sha != expected_build_git_sha:
        errors.append(
            f"appBuildGitSha={actual_build_git_sha!r} expected={expected_build_git_sha!r}"
        )

if errors:
    print("Android build metadata invalid: " + ", ".join(errors), file=sys.stderr)
    sys.exit(1)
PY
}

wait_for_android_build_metadata() {
  local start now last_error
  start="$(date +%s)"
  last_error=""
  while true; do
    if copy_android_build_metadata; then
      if last_error="$(validate_android_build_metadata 2>&1)"; then
        echo "Android build metadata passed: $(android_build_metadata_path)"
        return 0
      fi
    else
      last_error="failed to copy files/app-core/android-build-metadata.json from debug app sandbox"
    fi
    now="$(date +%s)"
    if (( now - start >= RUNTIME_STATE_WAIT_SECS )); then
      echo "$last_error" >&2
      return 1
    fi
    sleep 1
  done
}

validate_android_runtime_state() {
  local result_path
  result_path="$(android_runtime_state_path)"
  python3 - "$result_path" "$RUNTIME_STATE_MAX_AGE_SECS" <<'PY'
import json
import sys
import time

path = sys.argv[1]
max_age = int(sys.argv[2])
with open(path, encoding="utf-8") as fh:
    state = json.load(fh)

errors = []
if state.get("vpnEnabled") is not True:
    errors.append(f"vpnEnabled={state.get('vpnEnabled')!r}")
if state.get("vpnActive") is not True:
    errors.append(f"vpnActive={state.get('vpnActive')!r}")

updated_at = state.get("updatedAt")
now = int(time.time())
if not isinstance(updated_at, int) or updated_at <= 0:
    errors.append(f"updatedAt={updated_at!r}")
elif updated_at - now > 120:
    errors.append(f"updatedAt future skew={updated_at - now}s")
elif now - updated_at > max_age:
    errors.append(f"updatedAt age={now - updated_at}s")

for key in (
    "tunPacketsRead",
    "tunBytesRead",
    "tunPacketsWritten",
    "tunBytesWritten",
    "tunPacketsDropped",
):
    value = state.get(key)
    if not isinstance(value, int) or value < 0:
        errors.append(f"{key}={value!r}")

if errors:
    print("Android runtime state invalid: " + ", ".join(errors), file=sys.stderr)
    sys.exit(1)
PY
}

android_runtime_state_number() {
  local key="$1"
  local result_path
  result_path="$(android_runtime_state_path)"
  python3 - "$result_path" "$key" <<'PY'
import json
import sys

path, key = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as fh:
    value = json.load(fh).get(key)
if not isinstance(value, int):
    sys.exit(1)
print(value)
PY
}

android_runtime_state_counters() {
  local result_path
  result_path="$(android_runtime_state_path)"
  python3 - "$result_path" <<'PY'
import json
import sys

path = sys.argv[1]
keys = (
    "tunPacketsRead",
    "tunBytesRead",
    "tunPacketsWritten",
    "tunBytesWritten",
    "tunPacketsDropped",
)
with open(path, encoding="utf-8") as fh:
    state = json.load(fh)
values = [state.get(key) for key in keys]
if not all(isinstance(value, int) and value >= 0 for value in values):
    sys.exit(1)
print("\t".join(str(value) for value in values))
PY
}

android_vpn_interface_name() {
  local connectivity
  connectivity="$("$ADB" -s "$serial" shell dumpsys connectivity 2>/dev/null | tr -d '\r')" || return 1
  python3 -c '
import re
import sys

text = sys.stdin.read()
for block in re.split(r"(?=NetworkAgentInfo\{)", text):
    if "ni{VPN CONNECTED" not in block:
        continue
    match = re.search(r"InterfaceName:\s*([^,\s}\]]+)", block)
    if match:
        print(match.group(1))
        sys.exit(0)
sys.exit(1)
' <<<"$connectivity"
}

capture_android_vpn_link_stats() {
  local label="$1"
  local body captured iface result_path status unavailable_reason source
  local timestamp
  result_path="$(android_vpn_link_stats_path)"
  body="$(mktemp)"
  captured=0
  status=0
  unavailable_reason=""
  source="ip -s link"
  timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  if ! iface="$(android_vpn_interface_name)"; then
    iface="unknown"
    unavailable_reason="unable to resolve active Android VPN interface"
  elif "$ADB" -s "$serial" shell ip -s link show dev "$iface" 2>&1 | tr -d '\r' >"$body"; then
    if grep -Eq '(^|[[:space:]])RX:' "$body" && grep -Eq '(^|[[:space:]])TX:' "$body"; then
      captured=1
    else
      unavailable_reason="ip -s link show dev $iface returned no RX/TX counters"
    fi
  else
    status=$?
    unavailable_reason="ip -s link show dev $iface exited $status"
  fi
  if [[ "$captured" -ne 1 && "$iface" != "unknown" ]]; then
    local proc_body
    proc_body="$(mktemp)"
    if "$ADB" -s "$serial" shell cat /proc/net/dev 2>&1 \
      | tr -d '\r' \
      | awk -v iface="$iface" '
          {
            split($1, name, ":")
            if (name[1] == iface) {
              print
              found = 1
            }
          }
          END { exit found ? 0 : 1 }
        ' >"$proc_body"
    then
      mv "$proc_body" "$body"
      captured=1
      source="/proc/net/dev"
    else
      rm -f "$proc_body"
    fi
  fi
  mkdir -p "$RUNTIME_STATE_RESULT_DIR"
  {
    printf '## label=%s timestamp=%s iface=%s linkStats=%s source=%s\n' \
      "$label" "$timestamp" "$iface" \
      "$([[ "$captured" -eq 1 ]] && printf captured || printf unavailable)" "$source"
    if [[ "$captured" -eq 1 ]]; then
      cat "$body"
    else
      printf 'unavailable: %s\n' "$unavailable_reason"
      if [[ -s "$body" ]]; then
        sed 's/^/    /' "$body"
      fi
    fi
    printf '\n'
  } >>"$result_path"
  write_android_vpn_link_stats_summary "$label" "$timestamp" "$iface" "$source" "$result_path" "$body" "$captured"
  rm -f "$body"
  if [[ "$captured" -eq 1 ]]; then
    echo "Android VPN link counters captured ($label): $result_path iface=$iface"
    return 0
  else
    echo "Android VPN link counters unavailable ($label): $result_path iface=$iface reason=$unavailable_reason"
    return 1
  fi
}

write_android_vpn_link_stats_summary() {
  local label="$1"
  local timestamp="$2"
  local iface="$3"
  local source="$4"
  local raw_path="$5"
  local body_path="$6"
  local captured="$7"
  local summary_path
  summary_path="$(android_vpn_link_stats_summary_path)"
  if [[ ! -s "$summary_path" ]]; then
    printf 'label\ttimestamp\tiface\tsource\tparseStatus\trxBytes\trxPackets\trxDropped\ttxBytes\ttxPackets\ttxDropped\trawOutput\n' >"$summary_path"
  fi
  if [[ "$captured" -ne 1 ]]; then
    printf '%s\t%s\t%s\t%s\tunavailable\t\t\t\t\t\t\t%s\n' \
      "$label" "$timestamp" "$iface" "$source" "$raw_path" >>"$summary_path"
    echo "Android VPN link counter summary: $summary_path label=$label iface=$iface"
    return 0
  fi
  if ! awk -v label="$label" -v timestamp="$timestamp" -v iface="$iface" \
    -v source="$source" -v raw="$raw_path" '
      function emit(rx_bytes, rx_packets, rx_dropped, tx_bytes, tx_packets, tx_dropped) {
        printf "%s\t%s\t%s\t%s\tparsed\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n",
          label, timestamp, iface, source,
          rx_bytes, rx_packets, rx_dropped, tx_bytes, tx_packets, tx_dropped, raw
        found = 1
      }
      $1 == iface ":" && NF >= 17 { emit($2, $3, $5, $10, $11, $13); next }
      $1 == "RX:" { want_rx = 1; next }
      want_rx && NF >= 4 && $1 ~ /^[0-9]+$/ {
        rx_bytes = $1; rx_packets = $2; rx_dropped = $4; want_rx = 0; next
      }
      $1 == "TX:" { want_tx = 1; next }
      want_tx && NF >= 4 && $1 ~ /^[0-9]+$/ {
        emit(rx_bytes, rx_packets, rx_dropped, $1, $2, $4); want_tx = 0; next
      }
      END { exit found ? 0 : 1 }
    ' "$body_path" >>"$summary_path"
  then
    printf '%s\t%s\t%s\t%s\tunparsed\t\t\t\t\t\t\t%s\n' \
      "$label" "$timestamp" "$iface" "$source" "$raw_path" >>"$summary_path"
  fi
  echo "Android VPN link counter summary: $summary_path label=$label iface=$iface"
}

summarize_android_ping_probe() {
  local result_path="$1"
  local exit_status="$2"
  local summary_path
  summary_path="$(android_ping_probe_summary_path)"
  python3 - "$result_path" "$summary_path" "$exit_status" "$TUN_PACKET_PROBE_TARGET" <<'PY'
import json
import math
import re
import sys

path, summary_path, exit_status, target = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
text = open(path, encoding="utf-8", errors="replace").read()
loss = None
loss_match = re.search(r"(\d+(?:\.\d+)?)%\s+packet loss", text)
if loss_match:
    loss = float(loss_match.group(1))

transmitted = None
received = None
packet_match = re.search(r"(\d+)\s+packets transmitted,\s+(\d+)\s+(?:packets )?received", text)
if packet_match:
    transmitted = int(packet_match.group(1))
    received = int(packet_match.group(2))

min_ms = None
avg_ms = None
max_ms = None
jitter_ms = None
rtt_match = re.search(
    r"(?:rtt|round-trip)[^=]*=\s*([\d.]+)/([\d.]+)/([\d.]+)/([\d.]+)\s*ms",
    text,
)
if rtt_match:
    min_ms = float(rtt_match.group(1))
    avg_ms = float(rtt_match.group(2))
    max_ms = float(rtt_match.group(3))
    jitter_ms = float(rtt_match.group(4))

samples = sorted(float(match) for match in re.findall(r"time[=<]\s*([\d.]+)", text))

def percentile(values, pct):
    if not values:
        return None
    index = math.ceil(len(values) * pct / 100) - 1
    index = min(max(index, 0), len(values) - 1)
    return round(values[index], 3)

summary = {
    "target": target,
    "exitStatus": int(exit_status),
    "transmitted": transmitted,
    "received": received,
    "packetLossPct": loss,
    "samples": len(samples),
    "minMs": min_ms,
    "avgMs": avg_ms,
    "maxMs": max_ms,
    "mdevMs": jitter_ms,
    "p95Ms": percentile(samples, 95),
    "p99Ms": percentile(samples, 99),
    "rawOutput": path,
}
with open(summary_path, "w", encoding="utf-8") as fh:
    json.dump(summary, fh, sort_keys=True, indent=2)
    fh.write("\n")

def display(value, suffix=""):
    if value is None:
        return "unknown"
    if isinstance(value, float):
        return f"{value:.3f}".rstrip("0").rstrip(".") + suffix
    return f"{value}{suffix}"

print(
    "Android packet probe ping summary: "
    f"target={target} exit={exit_status} loss={display(loss, '%')} "
    f"samples={len(samples)} avg_ms={display(avg_ms)} p95_ms={display(summary['p95Ms'])} "
    f"p99_ms={display(summary['p99Ms'])} max_ms={display(max_ms)} "
    f"mdev_ms={display(jitter_ms)} output={path} summary={summary_path}"
)
PY
}

write_android_tun_packet_probe_summary() {
  local baseline="$1"
  local current="$2"
  local required_increase="$3"
  local baseline_bytes="$4"
  local current_bytes="$5"
  local baseline_written="$6"
  local current_written="$7"
  local baseline_bytes_written="$8"
  local current_bytes_written="$9"
  local baseline_dropped="${10}"
  local current_dropped="${11}"
  local ping_path="${12}"
  local ping_status="${13}"
  local first_observed_ms="${14}"
  local elapsed_ms="${15}"
  local polls="${16}"
  local poll_interval_ms="${17}"
  local summary_path
  summary_path="$(android_tun_packet_probe_summary_path)"
  python3 - \
    "$summary_path" \
    "$TUN_PACKET_PROBE_TARGET" \
    "$TUN_PACKET_PROBE_TIMEOUT_SECS" \
    "$baseline" \
    "$current" \
    "$required_increase" \
    "$baseline_bytes" \
    "$current_bytes" \
    "$baseline_written" \
    "$current_written" \
    "$baseline_bytes_written" \
    "$current_bytes_written" \
    "$baseline_dropped" \
    "$current_dropped" \
    "$ping_path" \
    "$ping_status" \
    "$first_observed_ms" \
    "$elapsed_ms" \
    "$polls" \
    "$poll_interval_ms" \
    "$TUN_PACKET_PROBE_REQUIRE_REPLY" \
    "$(android_runtime_state_path)" \
    "$(android_ping_probe_summary_path)" \
    "$(android_vpn_link_stats_path)" \
    "$(android_vpn_link_stats_summary_path)" \
    "$(android_build_metadata_path)" <<'PY'
import json
import sys

(
    summary_path,
    target,
    ping_timeout_secs,
    baseline,
    current,
    required_increase,
    baseline_bytes,
    current_bytes,
    baseline_written,
    current_written,
    baseline_bytes_written,
    current_bytes_written,
    baseline_dropped,
    current_dropped,
    ping_path,
    ping_status,
    first_observed_ms,
    elapsed_ms,
    polls,
    poll_interval_ms,
    require_reply,
    runtime_state_path,
    ping_summary_path,
    vpn_link_stats_path,
    vpn_link_stats_summary_path,
    build_metadata_path,
) = sys.argv[1:]

def number(value):
    try:
        return int(value)
    except (TypeError, ValueError):
        return None

baseline = number(baseline)
current = number(current)
required_increase = number(required_increase)
baseline_bytes = number(baseline_bytes)
current_bytes = number(current_bytes)
baseline_written = number(baseline_written)
current_written = number(current_written)
baseline_bytes_written = number(baseline_bytes_written)
current_bytes_written = number(current_bytes_written)
baseline_dropped = number(baseline_dropped)
current_dropped = number(current_dropped)
ping_status = number(ping_status)
ping_timeout_secs = number(ping_timeout_secs)
first_observed_ms = number(first_observed_ms)
elapsed_ms = number(elapsed_ms)
polls = number(polls)
poll_interval_ms = number(poll_interval_ms)
require_reply = str(require_reply).strip().lower() in {"1", "true", "yes", "on"}

observed = None
if baseline is not None and current is not None:
    observed = max(current - baseline, 0)

missing = None
if required_increase is not None and observed is not None:
    missing = max(required_increase - observed, 0)

observed_pct = None
packet_loss_pct = None
if required_increase and required_increase > 0:
    if observed is not None:
        observed_pct = round(observed * 100.0 / required_increase, 3)
    if missing is not None:
        packet_loss_pct = round(missing * 100.0 / required_increase, 3)

bytes_delta = None
if baseline_bytes is not None and current_bytes is not None:
    bytes_delta = current_bytes - baseline_bytes

written_delta = None
if baseline_written is not None and current_written is not None:
    written_delta = current_written - baseline_written

bytes_written_delta = None
if baseline_bytes_written is not None and current_bytes_written is not None:
    bytes_written_delta = current_bytes_written - baseline_bytes_written

dropped_delta = None
if baseline_dropped is not None and current_dropped is not None:
    dropped_delta = current_dropped - baseline_dropped

ping_received = None
try:
    with open(ping_summary_path, encoding="utf-8") as fh:
        ping_summary = json.load(fh)
    value = ping_summary.get("received")
    if isinstance(value, int):
        ping_received = value
except (OSError, json.JSONDecodeError):
    pass

reply_observed = (
    (ping_received is None or ping_received > 0)
    and written_delta is not None
    and written_delta > 0
    and bytes_written_delta is not None
    and bytes_written_delta > 0
    and (dropped_delta is None or dropped_delta == 0)
)

summary = {
    "target": target,
    "pingTimeoutSecs": ping_timeout_secs,
    "pingExitStatus": ping_status,
    "pingReceived": ping_received,
    "expected": required_increase,
    "observed": observed,
    "missing": missing,
    "observedPct": observed_pct,
    "packetLossPct": packet_loss_pct,
    "baselineRead": baseline,
    "finalRead": current,
    "baselineBytesRead": baseline_bytes,
    "finalBytesRead": current_bytes,
    "observedBytesRead": bytes_delta,
    "baselineWritten": baseline_written,
    "finalWritten": current_written,
    "observedWritten": written_delta,
    "baselineBytesWritten": baseline_bytes_written,
    "finalBytesWritten": current_bytes_written,
    "observedBytesWritten": bytes_written_delta,
    "writtenIncreased": written_delta is not None and written_delta > 0,
    "bytesWrittenIncreased": bytes_written_delta is not None and bytes_written_delta > 0,
    "baselineDropped": baseline_dropped,
    "finalDropped": current_dropped,
    "droppedDelta": dropped_delta,
    "firstObservedMs": first_observed_ms,
    "elapsedMs": elapsed_ms,
    "polls": polls,
    "pollIntervalMs": poll_interval_ms,
    "readIncreased": observed is not None
    and required_increase is not None
    and observed >= required_increase,
    "bytesReadIncreased": bytes_delta is not None and bytes_delta > 0,
    "droppedIncreased": dropped_delta is not None and dropped_delta > 0,
    "replyRequired": require_reply,
    "replyObserved": reply_observed,
    "rawPingOutput": ping_path,
    "pingSummaryOutput": ping_summary_path,
    "vpnLinkStatsOutput": vpn_link_stats_path,
    "vpnLinkStatsSummaryOutput": vpn_link_stats_summary_path,
    "runtimeStateOutput": runtime_state_path,
    "buildMetadataOutput": build_metadata_path,
}
try:
    with open(build_metadata_path, encoding="utf-8") as fh:
        build_metadata = json.load(fh)
except (OSError, json.JSONDecodeError):
    build_metadata = {}
for key in (
    "appPackageName",
    "appVersionName",
    "appVersionCode",
    "appBuildGitSha",
    "appBuildTimestampUtc",
):
    if key in build_metadata:
        summary[key] = build_metadata[key]
with open(summary_path, "w", encoding="utf-8") as fh:
    json.dump(summary, fh, sort_keys=True, indent=2)
    fh.write("\n")
PY
  printf '%s\n' "$summary_path"
}

wait_for_android_runtime_state() {
  local start now last_error
  start="$(date +%s)"
  last_error=""
  while true; do
    if copy_android_runtime_state; then
      if last_error="$(validate_android_runtime_state 2>&1)"; then
        echo "Android runtime state passed: $(android_runtime_state_path)"
        return 0
      fi
    else
      last_error="failed to copy files/app-core/mobile-runtime-state.json from debug app sandbox"
    fi
    now="$(date +%s)"
    if (( now - start >= RUNTIME_STATE_WAIT_SECS )); then
      echo "$last_error" >&2
      return 1
    fi
    sleep 1
  done
}

wait_for_tun_packets_read_after() {
  local baseline="$1"
  local required_increase="$2"
  local baseline_dropped="$3"
  local baseline_bytes="$4"
  local start_ms="$5"
  local start now current current_bytes current_written current_bytes_written current_dropped bytes_delta last_error
  local now_ms first_observed_ms elapsed_ms polls poll_interval_ms poll_interval_secs observed
  start="$(date +%s)"
  first_observed_ms=""
  polls=0
  poll_interval_ms=100
  poll_interval_secs=0.1
  last_error=""
  while true; do
    polls=$((polls + 1))
    if copy_android_runtime_state; then
      if last_error="$(validate_android_runtime_state 2>&1)"; then
        current="$(android_runtime_state_number tunPacketsRead 2>/dev/null || true)"
        current_bytes="$(android_runtime_state_number tunBytesRead 2>/dev/null || true)"
        current_written="$(android_runtime_state_number tunPacketsWritten 2>/dev/null || true)"
        current_bytes_written="$(android_runtime_state_number tunBytesWritten 2>/dev/null || true)"
        current_dropped="$(android_runtime_state_number tunPacketsDropped 2>/dev/null || true)"
        now_ms="$(epoch_ms)"
        if [[ "$current" =~ ^[0-9]+$ ]]; then
          observed="$((current - baseline))"
          if (( observed > 0 )) && [[ -z "$first_observed_ms" ]]; then
            first_observed_ms="$((now_ms - start_ms))"
          fi
        fi
        if [[ "$current_dropped" =~ ^[0-9]+$ ]] && (( current_dropped > baseline_dropped )); then
          echo "tunPacketsDropped increased during probe (baseline=$baseline_dropped current=$current_dropped)" >&2
          return 1
        fi
        if [[ "$current" =~ ^[0-9]+$ ]] && (( current >= baseline + required_increase )); then
          elapsed_ms="$((now_ms - start_ms))"
          bytes_delta="unknown"
          if [[ "$current_bytes" =~ ^[0-9]+$ ]]; then
            bytes_delta="$((current_bytes - baseline_bytes))"
          fi
          TUN_PACKET_PROBE_FINAL_READ="$current"
          TUN_PACKET_PROBE_FINAL_BYTES_READ="$current_bytes"
          TUN_PACKET_PROBE_FINAL_WRITTEN="$current_written"
          TUN_PACKET_PROBE_FINAL_BYTES_WRITTEN="$current_bytes_written"
          TUN_PACKET_PROBE_FINAL_DROPPED="$current_dropped"
          TUN_PACKET_PROBE_FIRST_OBSERVED_MS="${first_observed_ms:-$elapsed_ms}"
          TUN_PACKET_PROBE_ELAPSED_MS="$elapsed_ms"
          TUN_PACKET_PROBE_POLLS="$polls"
          TUN_PACKET_PROBE_POLL_INTERVAL_MS="$poll_interval_ms"
          TUN_PACKET_PROBE_BYTES_DELTA="$bytes_delta"
          echo "Android TUN packet probe observed: tunPacketsRead $baseline->$current observed=$((current - baseline))/$required_increase tunBytesReadDelta=$bytes_delta tunPacketsDropped=$baseline_dropped->$current_dropped firstObservedMs=${first_observed_ms:-$elapsed_ms} elapsedMs=$elapsed_ms polls=$polls target=$TUN_PACKET_PROBE_TARGET"
          return 0
        fi
        last_error="tunPacketsRead did not increase enough after probe (baseline=$baseline current=${current:-missing} required=$required_increase tunPacketsDropped=${current_dropped:-missing})"
      fi
    else
      last_error="failed to copy files/app-core/mobile-runtime-state.json from debug app sandbox"
    fi
    now="$(date +%s)"
    if (( now - start >= TUN_PACKET_PROBE_WAIT_SECS )); then
      echo "$last_error" >&2
      return 1
    fi
    sleep "$poll_interval_secs"
  done
}

run_android_tun_packet_probe() {
  truthy "$TUN_PACKET_PROBE" || return 0
  local baseline baseline_bytes baseline_dropped count remote_cmd ping_path ping_status probe_start_ms
  local ping_pid summary_path wait_status
  local baseline_written baseline_bytes_written
  IFS=$'\t' read -r baseline baseline_bytes baseline_written baseline_bytes_written baseline_dropped \
    <<<"$(android_runtime_state_counters 2>/dev/null || printf '0\t0\t0\t0\t0')"
  [[ "$baseline" =~ ^[0-9]+$ ]] || baseline=0
  [[ "$baseline_bytes" =~ ^[0-9]+$ ]] || baseline_bytes=0
  [[ "$baseline_written" =~ ^[0-9]+$ ]] || baseline_written=0
  [[ "$baseline_bytes_written" =~ ^[0-9]+$ ]] || baseline_bytes_written=0
  [[ "$baseline_dropped" =~ ^[0-9]+$ ]] || baseline_dropped=0
  count="$TUN_PACKET_PROBE_COUNT"
  [[ "$count" =~ ^[0-9]+$ ]] || count=4
  (( count > 0 )) || count=1
  ping_path="$(android_ping_probe_path)"
  mkdir -p "$RUNTIME_STATE_RESULT_DIR"
  remote_cmd="ping -c $count -W $TUN_PACKET_PROBE_TIMEOUT_SECS $TUN_PACKET_PROBE_TARGET"
  probe_start_ms="$(epoch_ms)"
  "$ADB" -s "$serial" shell "$remote_cmd" >"$ping_path" 2>&1 &
  ping_pid="$!"
  wait_status=0
  wait_for_tun_packets_read_after "$baseline" "$count" "$baseline_dropped" "$baseline_bytes" "$probe_start_ms" || wait_status=$?
  if wait "$ping_pid"; then
    ping_status=0
  else
    ping_status=$?
  fi
  summarize_android_ping_probe "$ping_path" "$ping_status"
  if (( wait_status != 0 )); then
    return "$wait_status"
  fi
  summary_path="$(
    write_android_tun_packet_probe_summary \
      "$baseline" \
      "$TUN_PACKET_PROBE_FINAL_READ" \
      "$count" \
      "$baseline_bytes" \
      "$TUN_PACKET_PROBE_FINAL_BYTES_READ" \
      "$baseline_written" \
      "$TUN_PACKET_PROBE_FINAL_WRITTEN" \
      "$baseline_bytes_written" \
      "$TUN_PACKET_PROBE_FINAL_BYTES_WRITTEN" \
      "$baseline_dropped" \
      "$TUN_PACKET_PROBE_FINAL_DROPPED" \
      "$ping_path" \
      "$ping_status" \
      "$TUN_PACKET_PROBE_FIRST_OBSERVED_MS" \
      "$TUN_PACKET_PROBE_ELAPSED_MS" \
      "$TUN_PACKET_PROBE_POLLS" \
      "$TUN_PACKET_PROBE_POLL_INTERVAL_MS"
  )"
  if truthy "$TUN_PACKET_PROBE_REQUIRE_REPLY"; then
    if ! python3 - "$summary_path" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    summary = json.load(fh)

errors = []
if not isinstance(summary.get("pingReceived"), int) or summary["pingReceived"] <= 0:
    errors.append(f"pingReceived={summary.get('pingReceived')!r}")
if summary.get("writtenIncreased") is not True:
    errors.append(
        "tunPacketsWritten="
        f"{summary.get('baselineWritten')!r}->{summary.get('finalWritten')!r}"
    )
if summary.get("bytesWrittenIncreased") is not True:
    errors.append(
        "tunBytesWritten="
        f"{summary.get('baselineBytesWritten')!r}->{summary.get('finalBytesWritten')!r}"
    )
if summary.get("droppedIncreased") is True:
    errors.append(f"droppedDelta={summary.get('droppedDelta')!r}")
if errors:
    print("Android TUN reply probe failed: " + ", ".join(errors), file=sys.stderr)
    sys.exit(1)
PY
    then
      return 1
    fi
  fi
  echo "Android TUN packet probe passed: tunPacketsRead $baseline->$TUN_PACKET_PROBE_FINAL_READ observed=$((TUN_PACKET_PROBE_FINAL_READ - baseline))/$count tunBytesReadDelta=$TUN_PACKET_PROBE_BYTES_DELTA tunPacketsWritten=$baseline_written->$TUN_PACKET_PROBE_FINAL_WRITTEN tunBytesWritten=$baseline_bytes_written->$TUN_PACKET_PROBE_FINAL_BYTES_WRITTEN tunPacketsDropped=$baseline_dropped->$TUN_PACKET_PROBE_FINAL_DROPPED firstObservedMs=$TUN_PACKET_PROBE_FIRST_OBSERVED_MS elapsedMs=$TUN_PACKET_PROBE_ELAPSED_MS polls=$TUN_PACKET_PROBE_POLLS target=$TUN_PACKET_PROBE_TARGET summary=$summary_path"
  capture_android_vpn_link_stats "after-probe" || true
}

cleanup_android_vpn_after_pass() {
  truthy "$cleanup_after_vpn_cycle" || return 0
  start_main_activity --es "$DEBUG_ACTION_EXTRA" disconnect
  if wait_until "$VPN_STOP_WAIT_SECS" vpn_inactive; then
    vpn_cleanup_armed=0
    echo "Android VPN cleanup passed: debug disconnect left no active VPN service/network"
    return 0
  fi
  dump_vpn_diagnostics
  echo "Android smoke failed: VPN remained active after post-pass cleanup." >&2
  return 1
}

cleanup_android_vpn_on_exit() {
  local status="$?"
  trap - EXIT
  if [[ "$vpn_cleanup_armed" -eq 1 && -n "${ADB:-}" && -n "$serial" ]]; then
    start_main_activity --es "$DEBUG_ACTION_EXTRA" disconnect >/dev/null 2>&1 || true
    if ! wait_until "$VPN_STOP_WAIT_SECS" vpn_inactive; then
      "$ADB" -s "$serial" shell am force-stop "$PACKAGE_NAME" >/dev/null 2>&1 || true
    fi
    if wait_until "$VPN_STOP_WAIT_SECS" vpn_inactive; then
      echo "Android VPN emergency cleanup verified: no active test service/network"
    else
      echo "Android VPN emergency cleanup failed; disable the VPN in Android Settings before replacing the app." >&2
      if [[ "$status" -eq 0 ]]; then
        status=1
      fi
    fi
  fi
  exit "$status"
}

trap cleanup_android_vpn_on_exit EXIT

android_sdk() {
  "$ADB" -s "$serial" shell getprop ro.build.version.sdk | tr -d '\r'
}

grant_permission_if_declared() {
  local permission="$1"
  "$ADB" -s "$serial" shell pm grant "$PACKAGE_NAME" "$permission" >/dev/null 2>&1 || true
}

grant_debug_runtime_permissions() {
  local sdk
  sdk="$(android_sdk)"
  if [[ "$sdk" =~ ^[0-9]+$ && "$sdk" -ge 36 ]]; then
    grant_permission_if_declared android.permission.NEARBY_WIFI_DEVICES
  fi
  if [[ "$sdk" =~ ^[0-9]+$ && "$sdk" -ge 37 ]]; then
    grant_permission_if_declared android.permission.ACCESS_LOCAL_NETWORK
  fi
}

tap_ui_resource() {
  local resource="$1"
  local package="${2:-}"
  local remote="/sdcard/nvpn-window.xml"
  local xml
  local point
  xml="$(mktemp)"
  if ! "$ADB" -s "$serial" shell uiautomator dump "$remote" >/dev/null 2>&1; then
    rm -f "$xml"
    return 1
  fi
  if ! "$ADB" -s "$serial" pull "$remote" "$xml" >/dev/null 2>&1; then
    rm -f "$xml"
    return 1
  fi
  point="$(python3 - "$xml" "$resource" "$package" <<'PY'
import re
import sys

xml_path, resource, package = sys.argv[1], sys.argv[2], sys.argv[3]
xml = open(xml_path, encoding="utf-8").read()
for node in re.findall(r"<node [^>]+>", xml):
    rid = re.search(r'resource-id="([^"]*)"', node)
    pkg = re.search(r'package="([^"]*)"', node)
    bounds = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', node)
    enabled = re.search(r'enabled="([^"]*)"', node)
    if package and (not pkg or pkg.group(1) != package):
        continue
    if rid and rid.group(1) == resource and bounds and (not enabled or enabled.group(1) == "true"):
        left, top, right, bottom = map(int, bounds.groups())
        print((left + right) // 2, (top + bottom) // 2)
        sys.exit(0)
sys.exit(1)
PY
  )" || {
    rm -f "$xml"
    return 1
  }
  rm -f "$xml"
  "$ADB" -s "$serial" shell input tap $point
}

maybe_accept_vpn_dialog() {
  [[ "$accept_vpn_dialog" == "1" || "$accept_vpn_dialog" == "true" ]] || return 0
  local start now tapped
  start="$(date +%s)"
  tapped=0
  while true; do
    if vpn_active; then
      return 0
    fi
    if tap_ui_resource "android:id/button1" "com.android.vpndialogs"; then
      tapped=1
      sleep 1
      continue
    fi
    if [[ "$tapped" -eq 1 ]]; then
      return 0
    fi
    now="$(date +%s)"
    if (( now - start >= 8 )); then
      return 0
    fi
    sleep 1
  done
}

base64_no_wrap() {
  base64 | tr -d '\n'
}

wireguard_config() {
  if [[ -n "$DEBUG_WIREGUARD_CONFIG_FILE" ]]; then
    cat "$DEBUG_WIREGUARD_CONFIG_FILE"
    return
  fi
  printf '%s' "$DEBUG_WIREGUARD_CONFIG"
}

start_main_activity() {
  "$ADB" -s "$serial" shell am start -n "$MAIN_ACTIVITY" "$@" >/dev/null
}

android_app_pid() {
  "$ADB" -s "$serial" shell pidof "$PACKAGE_NAME" 2>/dev/null \
    | tr -d '\r' \
    | awk '{ print $1 }'
}

android_activity_resumed() {
  "$ADB" -s "$serial" shell dumpsys activity activities 2>/dev/null \
    | tr -d '\r' \
    | grep -F "topResumedActivity=" \
    | grep -Fq "$MAIN_ACTIVITY"
}

run_android_activity_lifecycle_gate() {
  truthy "$ANDROID_LIFECYCLE_GATE" || return 0
  local before_pid background_pid foreground_pid
  before_pid="$(android_app_pid)"
  if [[ -z "$before_pid" ]]; then
    echo "Android lifecycle gate failed: app process is not running" >&2
    return 1
  fi

  "$ADB" -s "$serial" shell input keyevent KEYCODE_HOME
  sleep "$ANDROID_LIFECYCLE_BACKGROUND_DWELL_SECS"
  background_pid="$(android_app_pid)"
  if [[ "$background_pid" != "$before_pid" ]]; then
    echo "Android lifecycle gate failed: app process did not survive backgrounding" >&2
    return 1
  fi

  start_main_activity
  if ! wait_until 5 android_activity_resumed; then
    echo "Android lifecycle gate failed: Activity did not resume" >&2
    return 1
  fi
  foreground_pid="$(android_app_pid)"
  if [[ "$foreground_pid" != "$before_pid" ]]; then
    echo "Android lifecycle gate failed: app process restarted while foregrounding" >&2
    return 1
  fi
  echo "Android background/foreground lifecycle gate passed"
}

seed_debug_config() {
  if [[ "$create_network" == "1" || "$create_network" == "true" ]]; then
    start_main_activity \
      --es "$DEBUG_ACTION_EXTRA" add_network \
      --es "$DEBUG_NETWORK_NAME_EXTRA" "$DEBUG_NETWORK_NAME"
    sleep "$DEBUG_SEED_WAIT_SECS"
  fi

  if [[ -n "$DEBUG_EXIT_NODE" ]]; then
    start_main_activity \
      --es "$DEBUG_ACTION_EXTRA" set_fips_exit \
      --es "$DEBUG_EXIT_NODE_EXTRA" "$DEBUG_EXIT_NODE"
    sleep "$DEBUG_SEED_WAIT_SECS"
  fi

  if [[ -n "$DEBUG_WIREGUARD_CONFIG" || -n "$DEBUG_WIREGUARD_CONFIG_FILE" ]]; then
    local encoded
    encoded="$(wireguard_config | base64_no_wrap)"
    start_main_activity \
      --es "$DEBUG_ACTION_EXTRA" set_wireguard_exit \
      --es "$DEBUG_WIREGUARD_CONFIG_BASE64_EXTRA" "$encoded"
    sleep "$DEBUG_SEED_WAIT_SECS"
  fi
}

dump_vpn_diagnostics() {
  echo "Android VPN cycle did not reach the expected service/network state." >&2
  echo "If this is a first run, approve the Android VPN permission prompt and retry." >&2
  echo "If this device has no active nvpn network, use --create-network or approve its signed join request first." >&2
  echo "NVPN_ANDROID_DEBUG_WIREGUARD_CONFIG_FILE only configures a WG exit; it does not create the required nvpn network." >&2
  echo >&2
  echo "---- dumpsys activity services $PACKAGE_NAME ----" >&2
  "$ADB" -s "$serial" shell dumpsys activity services "$PACKAGE_NAME" >&2 || true
  echo >&2
  echo "---- dumpsys connectivity VPN agents ----" >&2
  "$ADB" -s "$serial" shell dumpsys connectivity 2>/dev/null \
    | tr -d '\r' \
    | grep -E 'NetworkAgentInfo\{.*ni\{VPN|VpnNetworkProvider' >&2 || true
  echo >&2
  echo "---- recent NostrVpnService logcat ----" >&2
  "$ADB" -s "$serial" logcat -d -t 200 2>/dev/null \
    | tr -d '\r' \
    | grep -E 'NostrVpnService|fi.siriusbusiness.nvpn|org.nostrvpn.app|AndroidRuntime|ActivityTaskManager' >&2 || true
}

ADB="$(resolve_adb)"

if [[ "$build" -eq 1 ]]; then
  "$ROOT/tools/run-android" build
fi

if [[ ! -f "$APK_PATH" ]]; then
  echo "Debug APK not found at $APK_PATH; run just android-build first" >&2
  exit 1
fi

serial="$(select_serial "$ADB")"
if [[ -z "$serial" ]]; then
  echo "No online Android device or emulator found; set NVPN_ANDROID_SERIAL or start an emulator" >&2
  exit 1
fi

"$ADB" -s "$serial" wait-for-device
"$ADB" -s "$serial" install -r "$APK_PATH"
PACKAGE_UID="$(resolve_package_uid "$ADB" "$serial")"
if [[ -z "$PACKAGE_UID" ]]; then
  echo "Could not resolve Android uid for installed package $PACKAGE_NAME" >&2
  exit 1
fi

if [[ "$clear_state" -eq 1 ]]; then
  "$ADB" -s "$serial" shell pm clear "$PACKAGE_NAME" >/dev/null
fi

if [[ "$vpn_cycle" -eq 1 ]]; then
  grant_debug_runtime_permissions
fi

start_main_activity
"$ADB" -s "$serial" shell pm path "$PACKAGE_NAME" >/dev/null
wait_for_android_build_metadata
run_android_activity_lifecycle_gate

if [[ "$vpn_cycle" -eq 0 ]]; then
  run_android_idle_cpu_gate "Android foreground app"
fi

if [[ "$vpn_cycle" -eq 1 ]]; then
  seed_debug_config
  start_main_activity --es "$DEBUG_ACTION_EXTRA" disconnect
  if ! wait_until "$VPN_STOP_WAIT_SECS" vpn_inactive; then
    dump_vpn_diagnostics
    echo "Android smoke failed: VPN remained active after debug disconnect." >&2
    exit 1
  fi
  if ! run_android_direct_network_probe before-connect; then
    exit 1
  fi
  if truthy "$cleanup_after_vpn_cycle"; then
    vpn_cleanup_armed=1
  fi
  start_main_activity --es "$DEBUG_ACTION_EXTRA" connect
  maybe_accept_vpn_dialog
  if ! wait_until "$VPN_START_WAIT_SECS" vpn_active; then
    dump_vpn_diagnostics
    echo "Android smoke failed: VPN service and network did not become active after debug connect." >&2
    exit 1
  fi
  if ! wait_for_android_runtime_state; then
    dump_vpn_diagnostics
    echo "Android smoke failed: Rust mobile runtime state did not become fresh after debug connect." >&2
    exit 1
  fi
  capture_android_vpn_link_stats "after-connect" || true
  if ! run_android_tun_packet_probe; then
    dump_vpn_diagnostics
    echo "Android smoke failed: native TUN packet probe failed." >&2
    exit 1
  fi
  if ! run_android_exit_network_probe; then
    dump_vpn_diagnostics
    exit 1
  fi
  "$ADB" -s "$serial" shell input keyevent KEYCODE_HOME
  run_android_idle_cpu_gate "Android background active VPN"
  if ! cleanup_android_vpn_after_pass; then
    exit 1
  fi
  if ! run_android_direct_network_probe after-disconnect; then
    exit 1
  fi
fi

echo "Android smoke passed on adb serial: $serial"
