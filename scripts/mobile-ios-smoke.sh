#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/release_common.sh"
# shellcheck disable=SC1091
source "$ROOT/scripts/mobile_env.sh"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib-mobile-ios-lifecycle.sh"
load_release_env "$ROOT"
load_appstoreconnect_defaults
load_mobile_env "$ROOT"
resolve_shared_build_metadata "$ROOT"
export NVPN_IOS_BUNDLE_ID="${NVPN_IOS_BUNDLE_ID:-${NVPN_DEFAULT_IOS_BUNDLE_ID:-fi.siriusbusiness.nvpn}}"
export NVPN_IOS_PACKET_TUNNEL_BUNDLE_ID="${NVPN_IOS_PACKET_TUNNEL_BUNDLE_ID:-$NVPN_IOS_BUNDLE_ID.PacketTunnel}"
export NVPN_IOS_APP_GROUP_IDENTIFIER="${NVPN_IOS_APP_GROUP_IDENTIFIER:-group.$NVPN_IOS_BUNDLE_ID.shared}"
BUNDLE_ID="$NVPN_IOS_BUNDLE_ID"
SIMULATOR_NAME="${NVPN_IOS_SIMULATOR_NAME:-iPhone 17 Pro}"
PROJECT="$ROOT/ios/NostrVpnIos.xcodeproj"
SCHEME="${NVPN_IOS_SCHEME:-NostrVpnIos}"
DEVICE_CONFIGURATION="${NVPN_IOS_DEVICE_CONFIGURATION:-Debug}"
DEVICE_DERIVED_DATA="${NVPN_IOS_DEVICE_DERIVED_DATA:-$ROOT/ios/.build/DeviceDerivedData}"
DEVICE_DESTINATION="${NVPN_IOS_DEVICE_DESTINATION:-generic/platform=iOS}"
DEVICE_CODE_SIGN_IDENTITY="${NVPN_IOS_DEVICE_CODE_SIGN_IDENTITY:-Apple Development}"
DEVICE_SIGNING_MODE="${NVPN_IOS_DEVICE_SIGNING_MODE:-adhoc}"
DEVICE_SIGNING_PREPARED=0
DEVICE_PROVISIONING_DIR="${NVPN_IOS_DEVICE_PROVISIONING_DIR:-$ROOT/ios/.build/DeviceSigning}"
DEVICE_PROVISIONING_ENV="$DEVICE_PROVISIONING_DIR/provisioning.env"
INSTALL_DEVICE_APP="${NVPN_IOS_INSTALL:-0}"
CREATE_NETWORK="${NVPN_IOS_DEBUG_CREATE_NETWORK:-0}"
DEBUG_NETWORK_NAME="${NVPN_IOS_DEBUG_NETWORK_NAME:-iOS smoke}"
VPN_START_WAIT_SECS="${NVPN_IOS_VPN_START_WAIT_SECS:-12}"
VPN_RESULT_WAIT_SECS="${NVPN_IOS_VPN_RESULT_WAIT_SECS:-4}"
VPN_RESULT_NAME="${NVPN_IOS_VPN_RESULT_NAME:-mobile-ios-smoke-vpn-$$.json}"
VPN_RESULT_DIR="${NVPN_IOS_RESULT_DIR:-$ROOT/artifacts/mobile-ios}"
IOS_IDLE_CPU_RESULT_NAME="${NVPN_IOS_IDLE_CPU_RESULT_NAME:-mobile-ios-idle-cpu-$$.json}"
TUN_PACKET_PROBE_SUMMARY_NAME="${NVPN_IOS_TUN_PACKET_PROBE_SUMMARY_NAME:-mobile-ios-tun-probe-summary-$$.json}"
TUN_PACKET_PROBE_TARGET="${NVPN_IOS_TUN_PACKET_PROBE_TARGET:-10.44.255.254}"
TUN_PACKET_PROBE_PORT="${NVPN_IOS_TUN_PACKET_PROBE_PORT:-9}"
TUN_PACKET_PROBE_COUNT="${NVPN_IOS_TUN_PACKET_PROBE_COUNT:-4}"
TUN_PACKET_PROBE_WAIT_SECS="${NVPN_IOS_TUN_PACKET_PROBE_WAIT_SECS:-6}"
TUN_PACKET_PROBE_REQUIRE_REPLY="${NVPN_IOS_TUN_PACKET_PROBE_REQUIRE_REPLY:-0}"
DEBUG_WIREGUARD_CONFIG="${NVPN_IOS_DEBUG_WIREGUARD_CONFIG:-}"
DEBUG_WIREGUARD_CONFIG_FILE="${NVPN_IOS_DEBUG_WIREGUARD_CONFIG_FILE:-}"
EXIT_PROBE_HOST="${NVPN_IOS_EXIT_PROBE_HOST:-}"
EXIT_PROBE_EXPECTED_IP="${NVPN_IOS_EXIT_PROBE_EXPECTED_IP:-}"
EXIT_PROBE_URL="${NVPN_IOS_EXIT_PROBE_URL:-}"
DIRECT_PROBE_HOST="${NVPN_IOS_DIRECT_PROBE_HOST:-example.com}"
DIRECT_PROBE_URL="${NVPN_IOS_DIRECT_PROBE_URL:-https://example.com/}"
VERIFY_DIRECT_RESTORATION="${NVPN_IOS_VERIFY_DIRECT_RESTORATION:-0}"
cleanup_after_vpn_cycle="${NVPN_IOS_CLEANUP_AFTER_VPN_CYCLE:-1}"
IDLE_CPU_GATE="${NVPN_IOS_IDLE_CPU_GATE:-${NVPN_IDLE_CPU_GATE:-1}}"
IDLE_CPU_MAX_PERCENT="${NVPN_IOS_IDLE_CPU_MAX_PERCENT:-${NVPN_IDLE_CPU_MAX_PERCENT:-5}}"
IDLE_CPU_SAMPLE_SECONDS="${NVPN_IOS_IDLE_CPU_SAMPLE_SECONDS:-${NVPN_IDLE_CPU_SAMPLE_SECONDS:-10}}"
IDLE_CPU_SETTLE_SECONDS="${NVPN_IOS_IDLE_CPU_SETTLE_SECONDS:-${NVPN_IDLE_CPU_SETTLE_SECONDS:-3}}"
IOS_SIM_PROCESS_NAME="${NVPN_IOS_SIM_PROCESS_NAME:-Nostr VPN}"
IOS_LIFECYCLE_GATE="${NVPN_IOS_LIFECYCLE_GATE:-1}"
IOS_LIFECYCLE_CYCLES="${NVPN_IOS_LIFECYCLE_CYCLES:-3}"
SCREENSHOT="$ROOT/artifacts/nostr-vpn-ios.png"
vpn_cleanup_armed=0
vpn_cleanup_device=""

usage() {
  cat >&2 <<'EOF'
usage: scripts/mobile-ios-smoke.sh [simulator|device] [--install] [--disconnect] [--create-network] [--vpn-cycle] [--device DEVICE] [--leave-vpn-active] [--probe-target IP] [--probe-port PORT] [--probe-count N] [--probe-require-reply]

simulator  Builds, installs, launches, and screenshots the simulator app.
device     Launches an already installed physical test build.
           By default, backgrounds and foregrounds it three times and proves
           the shared native core closes and reopens on every transition,
           including a ten-second suspended interval.
--install  Builds and installs the current iphoneos test app
           before launching device mode.
--disconnect
           Confirm that the installed physical test app's packet tunnel is off,
           then exit without running a smoke.
--device DEVICE
           Selects the physical device identifier for this run. Equivalent to
           NVPN_IOS_DEVICE=DEVICE.
--create-network
           Creates a local debug network before the device VPN cycle, for OS
           Packet Tunnel coverage without peer dataplane coverage.
--leave-vpn-active
           Preserve a passing VPN cycle for manual inspection. By default a
           passing --vpn-cycle asks the debug app to disconnect afterwards.

Physical-device mode uses NVPN_IOS_DEVICE/NVPN_IOS_DEVICE_ID when set, or auto-
selects the only connected physical iPhone/iPad. Values may live in
.env.mobile.local or shell env. Keep device identifiers and signing details out
of committed files.

Simulator mode is a launch smoke only; iOS Packet Tunnel dataplane checks need
a physical device, and first-run VPN/profile permission prompts may need a
manual approval before --vpn-cycle can run unattended.

Device install mode requires signing access for NVPN_IOS_BUNDLE_ID and
NVPN_IOS_PACKET_TUNNEL_BUNDLE_ID. When App Store Connect credentials are
available, physical gates use company Ad Hoc profiles and fail if those profiles
cannot be prepared. Set
NVPN_IOS_DEVICE_SIGNING_MODE=development only for Xcode-managed development;
that mode may require explicitly trusting its development certificate. Set
NVPN_IOS_TEAM_ID in the shell or local env file.

The physical-device packet probe defaults to 4 UDP packets toward the debug
non-local tunnel probe target. Use --probe-target, --probe-port, --probe-count,
and --probe-require-reply for a reachable peer row that requires native TUN write
counters to increase. NVPN_IOS_TUN_PACKET_PROBE_WAIT_SECS still controls the
observation window.

Set NVPN_IOS_DEBUG_WIREGUARD_CONFIG_FILE with NVPN_IOS_EXIT_PROBE_HOST,
NVPN_IOS_EXIT_PROBE_EXPECTED_IP, and NVPN_IOS_EXIT_PROBE_URL for a real exit
probe. NVPN_IOS_VERIFY_DIRECT_RESTORATION=1 additionally requires native DNS
and HTTPS before connect and after the packet tunnel is fully disconnected.
EOF
}

mode="${1:-simulator}"
if [[ $# -gt 0 ]]; then
  shift
fi
vpn_cycle=0
disconnect_only=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install)
      INSTALL_DEVICE_APP=1
      ;;
    --disconnect)
      disconnect_only=1
      ;;
    --create-network)
      CREATE_NETWORK=1
      ;;
    --device)
      if [[ $# -lt 2 ]]; then
        echo "--device requires a value" >&2
        exit 2
      fi
      export NVPN_IOS_DEVICE="$2"
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
    --probe-port)
      if [[ $# -lt 2 ]]; then
        echo "--probe-port requires a value" >&2
        exit 2
      fi
      TUN_PACKET_PROBE_PORT="$2"
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
    --probe-require-reply)
      TUN_PACKET_PROBE_REQUIRE_REPLY=1
      ;;
    --leave-vpn-active)
      cleanup_after_vpn_cycle=0
      ;;
    --vpn-cycle)
      vpn_cycle=1
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

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "iOS smoke requires macOS with Xcode" >&2
  exit 1
fi

run_simulator() {
  "$ROOT/tools/run-ios" run
  if [[ ! -s "$SCREENSHOT" ]]; then
    echo "Expected simulator screenshot at $SCREENSHOT" >&2
    exit 1
  fi
  run_ios_simulator_idle_cpu_gate
  echo "iOS simulator smoke passed: $SCREENSHOT"
}

ios_sim_device_id() {
  local booted
  booted="$(xcrun simctl list devices available \
    | sed -n 's/.*iPhone[^()]*(\([0-9A-F-]\{36\}\)) (Booted).*/\1/p' \
    | head -n 1)"
  if [[ -n "$booted" ]]; then
    printf '%s\n' "$booted"
    return
  fi
  xcrun simctl list devices available \
    | sed -n "s/.*$SIMULATOR_NAME (\([0-9A-F-]\{36\}\)).*/\1/p" \
    | head -n 1
}

ios_simulator_app_pid() {
  local device="$1"
  ps -axo pid=,command= \
    | awk -v device="$device" -v app="$IOS_SIM_PROCESS_NAME.app/$IOS_SIM_PROCESS_NAME" '
        !pid && index($0, device) && index($0, app) { pid = $1 }
        END { if (pid) print pid }
      '
}

run_ios_simulator_idle_cpu_gate() {
  case "$IDLE_CPU_GATE" in
    0|false|FALSE|False|no|NO|No|off|OFF|Off)
      echo "Skipping iOS simulator idle CPU gate because NVPN_IOS_IDLE_CPU_GATE=$IDLE_CPU_GATE"
      return
      ;;
  esac

  local device pid result_path
  device="$(ios_sim_device_id)"
  if [[ -z "$device" ]]; then
    echo "iOS simulator idle CPU gate failed: no simulator device id found" >&2
    exit 1
  fi
  pid="$(ios_simulator_app_pid "$device" | head -n 1)"
  if [[ -z "$pid" ]]; then
    echo "iOS simulator idle CPU gate failed: process $IOS_SIM_PROCESS_NAME not found on simulator $device" >&2
    exit 1
  fi
  mkdir -p "$VPN_RESULT_DIR"
  result_path="$VPN_RESULT_DIR/mobile-ios-simulator-idle-cpu-$$.json"
  "$ROOT/scripts/idle-cpu-gate.py" host-pid \
    --pid "$pid" \
    --label "iOS simulator app" \
    --artifact "$result_path" \
    --max-percent "$IDLE_CPU_MAX_PERCENT" \
    --sample-seconds "$IDLE_CPU_SAMPLE_SECONDS" \
    --settle-seconds "$IDLE_CPU_SETTLE_SECONDS"
}

auto_select_ios_device() {
  xcrun xctrace list devices 2>/dev/null | awk '
    /^== Devices ==/ { in_devices = 1; next }
    /^== Simulators ==/ { in_devices = 0 }
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
  '
}

launch_device() {
  local device="$1"
  shift
  ios_device_launch "$device" "$BUNDLE_ID" "$@"
}

device_app_path() {
  find "$DEVICE_DERIVED_DATA/Build/Products/$DEVICE_CONFIGURATION-iphoneos" \
    -maxdepth 1 -name '*.app' -type d | sort | head -n 1
}

connected_ios_udid() {
  local device="$1"
  local details_file udid
  details_file="$(mktemp "${TMPDIR:-/tmp}/nvpn-ios-device-details.XXXXXX")"
  if ! xcrun devicectl device info details \
    --device "$device" \
    --json-output "$details_file" \
    --quiet >/dev/null
  then
    rm -f "$details_file"
    echo "Could not inspect the selected iOS device for Ad Hoc signing." >&2
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
    echo "The selected iOS device did not report a signing UDID." >&2
    return 1
  }
  rm -f "$details_file"
  printf '%s\n' "$udid"
}

prepare_device_signing() {
  local device="$1"
  if [[ "$DEVICE_SIGNING_PREPARED" -eq 1 ]]; then
    return 0
  fi

  local mode="$DEVICE_SIGNING_MODE"

  case "$mode" in
    adhoc)
      local udid profile_log
      udid="$(connected_ios_udid "$device")"
      mkdir -p "$DEVICE_PROVISIONING_DIR"
      profile_log="$DEVICE_PROVISIONING_DIR/ios-profiles.log"
      if ! NVPN_IOS_PROFILE_TYPE=IOS_APP_ADHOC \
        NVPN_IOS_PROFILE_NAME="Nostr VPN Ad Hoc main physical gate" \
        NVPN_IOS_PACKET_TUNNEL_PROFILE_NAME="Nostr VPN Ad Hoc packet tunnel physical gate" \
        NVPN_IOS_CODE_SIGN_IDENTITY="Apple Distribution" \
        NVPN_IOS_DEVICE_UDIDS="$udid" \
        NVPN_IOS_PROFILES_ENV_PATH="$DEVICE_PROVISIONING_ENV" \
        "$ROOT/scripts/ios-profiles" ensure >"$profile_log" 2>&1
      then
        echo "Unable to prepare company Ad Hoc signing; private details are in $profile_log" >&2
        return 1
      fi
      # shellcheck disable=SC1090
      source "$DEVICE_PROVISIONING_ENV"
      : "${NVPN_IOS_CODE_SIGN_IDENTITY:?Ad Hoc signing identity not set}"
      : "${NVPN_IOS_PROVISIONING_PROFILE_UUID:?Ad Hoc app profile not set}"
      : "${NVPN_IOS_PACKET_TUNNEL_PROVISIONING_PROFILE_UUID:?Ad Hoc tunnel profile not set}"
      DEVICE_CONFIGURATION="DeviceDebug"
      DEVICE_CODE_SIGN_IDENTITY="$NVPN_IOS_CODE_SIGN_IDENTITY"
      echo "Using company Ad Hoc signing for the physical iOS gate (no development-certificate trust required)."
      ;;
    development)
      DEVICE_CONFIGURATION="${NVPN_IOS_DEVICE_CONFIGURATION:-Debug}"
      DEVICE_CODE_SIGN_IDENTITY="${NVPN_IOS_DEVICE_CODE_SIGN_IDENTITY:-Apple Development}"
      echo "Using Xcode development signing for the physical iOS gate."
      ;;
    *)
      echo "NVPN_IOS_DEVICE_SIGNING_MODE must be adhoc or development (got $mode)." >&2
      return 2
      ;;
  esac
  DEVICE_SIGNING_MODE="$mode"
  DEVICE_SIGNING_PREPARED=1
}

build_device_app() {
  local device="$1"
  local team="${NVPN_IOS_TEAM_ID:-}"
  if [[ -z "$team" ]]; then
    echo "Set NVPN_IOS_TEAM_ID to build/install a physical iOS device app." >&2
    exit 1
  fi

  prepare_device_signing "$device"

  "$ROOT/tools/run-ios" xcframework
  "$ROOT/tools/run-ios" project

  local cmd=(xcodebuild)
  if bool_is_true "${NVPN_IOS_XCODEBUILD_QUIET:-1}"; then
    cmd+=(-quiet)
  fi
  if bool_is_true "${NVPN_IOS_ALLOW_PROVISIONING_UPDATES:-1}"; then
    cmd+=(-allowProvisioningUpdates)
  fi
  cmd+=(
    -project "$PROJECT"
    -scheme "$SCHEME"
    -configuration "$DEVICE_CONFIGURATION"
    -derivedDataPath "$DEVICE_DERIVED_DATA"
    -destination "$DEVICE_DESTINATION"
    DEVELOPMENT_TEAM="$team"
    NVPN_BUILD_GIT_SHA="$NVPN_BUILD_GIT_SHA"
    NVPN_BUILD_TIMESTAMP_UTC="$NVPN_BUILD_TIMESTAMP_UTC"
  )
  if [[ "$DEVICE_SIGNING_MODE" == "adhoc" ]]; then
    cmd+=(
      NVPN_IOS_CODE_SIGN_IDENTITY="$DEVICE_CODE_SIGN_IDENTITY"
      NVPN_IOS_PROVISIONING_PROFILE_UUID="$NVPN_IOS_PROVISIONING_PROFILE_UUID"
      NVPN_IOS_PACKET_TUNNEL_PROVISIONING_PROFILE_UUID="$NVPN_IOS_PACKET_TUNNEL_PROVISIONING_PROFILE_UUID"
    )
  else
    cmd+=(CODE_SIGN_IDENTITY="$DEVICE_CODE_SIGN_IDENTITY")
  fi
  cmd+=(build)
  "${cmd[@]}"
}

install_device_app() {
  local device="$1"
  local app_path
  disconnect_ios_vpn_before_install "$device"
  build_device_app "$device"
  app_path="$(device_app_path)"
  if [[ -z "$app_path" ]]; then
    echo "Built iOS device app not found under $DEVICE_DERIVED_DATA" >&2
    exit 1
  fi
  xcrun devicectl device install app --device "$device" "$app_path" --quiet
}

device_app_is_installed() {
  local device="$1"
  xcrun devicectl device info apps --device "$device" 2>/dev/null \
    | awk -v bundle="$BUNDLE_ID" '$0 ~ bundle { found = 1 } END { exit !found }'
}

copy_ios_disconnect_result() {
  local device="$1"
  local result_name="$2"
  local destination="$3"
  rm -f "$destination"
  xcrun devicectl device copy from \
    --device "$device" \
    --domain-type appDataContainer \
    --domain-identifier "$BUNDLE_ID" \
    --source "Library/Application Support/Nostr VPN Debug Results/$result_name" \
    --destination "$destination" \
    --quiet
}

validate_ios_disconnect_result() {
  python3 - "$1" <<'PY'
import json, sys

with open(sys.argv[1], encoding="utf-8") as fh:
    result = json.load(fh)
status = result.get("packetTunnelStatusRawValue")
if result.get("ok") is not True or not isinstance(status, int) or status > 1:
    raise SystemExit(1)
PY
}

disconnect_ios_vpn_confirmed() {
  local device="$1"
  local result_name="mobile-ios-disconnect-$$-$(date +%s).json"
  local destination="${TMPDIR:-/tmp}/$result_name"
  if ! launch_device "$device" --nvpn-debug-disconnect-result "$result_name" >/dev/null; then
    echo "iOS VPN cleanup failed: debug disconnect launch failed" >&2
    return 1
  fi
  local ignored
  for ignored in $(seq 1 20); do
    sleep 0.5
    if copy_ios_disconnect_result "$device" "$result_name" "$destination" 2>/dev/null \
      && validate_ios_disconnect_result "$destination"
    then
      rm -f "$destination"
      echo "iOS VPN cleanup verified: packet tunnel is disconnected"
      return 0
    fi
  done
  rm -f "$destination"
  echo "iOS VPN cleanup failed: packet tunnel did not confirm disconnection" >&2
  return 1
}

disconnect_ios_vpn_before_install() {
  local device="$1"
  if ! device_app_is_installed "$device"; then
    return 0
  fi
  if ! disconnect_ios_vpn_confirmed "$device"; then
    echo "Refusing to replace $BUNDLE_ID while its existing packet tunnel may still be active." >&2
    echo "Disconnect it in iOS Settings or trust/launch the installed development app, then retry." >&2
    return 1
  fi
}

copy_vpn_probe_result() {
  local device="$1"
  local result_path="$VPN_RESULT_DIR/$VPN_RESULT_NAME"
  mkdir -p "$VPN_RESULT_DIR"
  rm -f "$result_path"
  if ! xcrun devicectl device copy from \
    --device "$device" \
    --domain-type appDataContainer \
    --domain-identifier "$BUNDLE_ID" \
    --source "Library/Application Support/Nostr VPN Debug Results/$VPN_RESULT_NAME" \
    --destination "$result_path" \
    --quiet
  then
    echo "Failed to copy the current iOS VPN probe receipt for $BUNDLE_ID" >&2
    echo "If this is a first run, approve the iOS VPN configuration prompt on the device and retry." >&2
    return 1
  fi
  if [[ ! -s "$result_path" ]]; then
    echo "iOS VPN probe result not found at $result_path" >&2
    return 1
  fi
  printf '%s\n' "$result_path"
}

copy_ios_debug_logs() {
  local device="$1"
  local stem="${VPN_RESULT_NAME%.json}"
  local copied=0
  mkdir -p "$VPN_RESULT_DIR"
  for name in app-debug.log nvpn-pkt-debug.log; do
    local destination="$VPN_RESULT_DIR/$stem-$name"
    rm -f "$destination"
    launch_device "$device" \
      --nvpn-debug-export-support-file "$name" \
      --nvpn-debug-export-result "$name" >/dev/null 2>&1 || continue
    sleep 0.5
    if xcrun devicectl device copy from \
      --device "$device" \
      --domain-type appDataContainer \
      --domain-identifier "$BUNDLE_ID" \
      --source "Library/Application Support/Nostr VPN Debug Results/$name" \
      --destination "$destination" \
      --quiet \
      2>/dev/null
    then
      if [[ -s "$destination" ]]; then
        echo "Copied iOS debug log: $destination" >&2
        copied=1
      else
        rm -f "$destination"
      fi
    else
      rm -f "$destination"
    fi
  done
  if [[ "$copied" -eq 1 ]]; then
    return 0
  fi
  return 1
}

validate_vpn_probe_result() {
  local result_path="$1"
  local summary_path="$VPN_RESULT_DIR/$TUN_PACKET_PROBE_SUMMARY_NAME"
  python3 - "$result_path" "$summary_path" "$NVPN_BUILD_GIT_SHA" \
    "$TUN_PACKET_PROBE_REQUIRE_REPLY" "$EXIT_PROBE_EXPECTED_IP" \
    "$VERIFY_DIRECT_RESTORATION" <<'PY'
import json
import sys

(
    path,
    summary_path,
    expected_build_git_sha,
    require_reply_raw,
    expected_exit_ip,
    verify_direct_raw,
) = sys.argv[1:7]
require_reply = require_reply_raw.strip().lower() in {"1", "true", "yes", "on"}
verify_direct = verify_direct_raw.strip().lower() in {"1", "true", "yes", "on"}
with open(path, encoding="utf-8") as fh:
    result = json.load(fh)

runtime = None

def counter(value):
    if isinstance(value, int):
        return value
    if isinstance(value, str) and value.isdigit():
        return int(value)
    return None

def probe_values():
    expected = counter(result.get("tunPacketProbeExpectedPackets"))
    sent = counter(result.get("tunPacketProbeSentPackets"))
    observed = counter(result.get("tunPacketProbeObservedPackets"))
    missing = counter(result.get("tunPacketProbeMissingPackets"))
    observed_bytes = counter(result.get("tunPacketProbeObservedBytesRead"))
    observed_written = counter(result.get("tunPacketProbeObservedWritten"))
    observed_bytes_written = counter(result.get("tunPacketProbeObservedBytesWritten"))
    dropped_delta = counter(result.get("tunPacketProbeDroppedDelta"))
    loss_pct = None
    observed_pct = None
    if expected and expected > 0:
        if missing is not None:
            loss_pct = round(missing * 100.0 / expected, 3)
        if observed is not None:
            observed_pct = round(observed * 100.0 / expected, 3)
    return {
        "target": result.get("tunPacketProbeTarget"),
        "port": counter(result.get("tunPacketProbePort")),
        "expected": expected,
        "sent": sent,
        "observed": observed,
        "missing": missing,
        "observedPct": observed_pct,
        "packetLossPct": loss_pct,
        "observedBytesRead": observed_bytes,
        "observedWritten": observed_written,
        "observedBytesWritten": observed_bytes_written,
        "droppedDelta": dropped_delta,
        "firstObservedMs": counter(result.get("tunPacketProbeFirstObservedMs")),
        "elapsedMs": counter(result.get("tunPacketProbeElapsedMs")),
        "polls": counter(result.get("tunPacketProbePolls")),
        "pollIntervalMs": counter(result.get("tunPacketProbePollIntervalMs")),
        "baselineRead": counter(result.get("tunPacketProbeBaselineRead")),
        "finalRead": counter(result.get("tunPacketProbeFinalRead")),
        "baselineBytesRead": counter(result.get("tunPacketProbeBaselineBytesRead")),
        "finalBytesRead": counter(result.get("tunPacketProbeFinalBytesRead")),
        "baselineWritten": counter(result.get("tunPacketProbeBaselineWritten")),
        "finalWritten": counter(result.get("tunPacketProbeFinalWritten")),
        "baselineBytesWritten": counter(result.get("tunPacketProbeBaselineBytesWritten")),
        "finalBytesWritten": counter(result.get("tunPacketProbeFinalBytesWritten")),
        "baselineDropped": counter(result.get("tunPacketProbeBaselineDropped")),
        "finalDropped": counter(result.get("tunPacketProbeFinalDropped")),
        "readIncreased": result.get("tunPacketProbeReadIncreased"),
        "bytesReadIncreased": result.get("tunPacketProbeBytesReadIncreased"),
        "writtenIncreased": result.get("tunPacketProbeWrittenIncreased"),
        "bytesWrittenIncreased": result.get("tunPacketProbeBytesWrittenIncreased"),
        "droppedIncreased": result.get("tunPacketProbeDroppedIncreased"),
        "replyRequired": require_reply,
        "replyObserved": result.get("tunPacketProbeWrittenIncreased") is True
        and result.get("tunPacketProbeBytesWrittenIncreased") is True
        and result.get("tunPacketProbeDroppedIncreased") is False,
        "error": result.get("tunPacketProbeError"),
        "sendError": result.get("tunPacketProbeSendError"),
        "rawOutput": path,
    }

def display(value, suffix=""):
    if value is None:
        return "?"
    if isinstance(value, float):
        return f"{value:.3f}".rstrip("0").rstrip(".") + suffix
    return f"{value}{suffix}"

def probe_summary():
    values = probe_values()
    parts = [
        f"read={values['baselineRead']}->{values['finalRead']}",
        f"observed={values['observed']}/{values['expected']}",
        f"observedPct={display(values['observedPct'], '%')}",
        f"missing={values['missing']}",
        f"lossPct={display(values['packetLossPct'], '%')}",
        f"bytes={values['observedBytesRead']}",
        f"written={values['observedWritten']}",
        f"bytesWritten={values['observedBytesWritten']}",
        f"drops={values['droppedDelta']}",
        f"firstMs={values['firstObservedMs']}",
        f"elapsedMs={values['elapsedMs']}",
        f"polls={values['polls']}",
        f"target={values['target']}",
    ]
    if isinstance(runtime, dict):
        parts.extend([
            f"runtimeRead={runtime.get('tunPacketsRead')}",
            f"runtimeWritten={runtime.get('tunPacketsWritten')}",
            f"runtimeDropped={runtime.get('tunPacketsDropped')}",
        ])
    return "iOS TUN packet probe counters: " + " ".join(parts)

def write_probe_summary(validation_errors=None):
    values = probe_values()
    if isinstance(runtime, dict):
        values["runtime"] = {
            "tunPacketsRead": counter(runtime.get("tunPacketsRead")),
            "tunBytesRead": counter(runtime.get("tunBytesRead")),
            "tunPacketsWritten": counter(runtime.get("tunPacketsWritten")),
            "tunBytesWritten": counter(runtime.get("tunBytesWritten")),
            "tunPacketsDropped": counter(runtime.get("tunPacketsDropped")),
        }
    values["replyRequired"] = require_reply
    values["passed"] = not validation_errors
    if validation_errors:
        values["validationErrors"] = validation_errors
    for key in (
        "phase",
        "packetTunnelStatusRawValue",
        "packetTunnelConnected",
        "vpnEnabled",
        "vpnActive",
        "startError",
        "vpnStartElapsedMs",
        "vpnWaitRequestedMs",
        "statusCollectionElapsedMs",
        "fetchElapsedMs",
        "debugProbeElapsedMs",
        "startedAt",
        "vpnStartFinishedAt",
        "finishedAt",
    ):
        if key in result:
            values[key] = result[key]
    for key in (
        "appBundleIdentifier",
        "appVersionName",
        "appVersionCode",
        "appBuildGitSha",
        "appBuildTimestampUtc",
    ):
        if key in result:
            values[key] = result[key]
    with open(summary_path, "w", encoding="utf-8") as fh:
        json.dump(values, fh, sort_keys=True, indent=2)
        fh.write("\n")
    return summary_path

errors = []
actual_build_git_sha = result.get("appBuildGitSha")
if expected_build_git_sha:
    if not actual_build_git_sha:
        errors.append(f"appBuildGitSha missing expected={expected_build_git_sha!r}")
    elif actual_build_git_sha != expected_build_git_sha:
        errors.append(
            f"appBuildGitSha={actual_build_git_sha!r} expected={expected_build_git_sha!r}"
        )
if result.get("phase") != "finished" or "finishedAt" not in result:
    errors.append(
        "debug probe did not finish "
        f"phase={result.get('phase')!r} finishedAt={result.get('finishedAt')!r}"
    )
if result.get("startError"):
    errors.append(f"startError={result['startError']}")
if result.get("packetTunnelStatusRawValue") != 3:
    errors.append(f"packetTunnelStatusRawValue={result.get('packetTunnelStatusRawValue')!r}")
if result.get("vpnEnabled") is not True:
    errors.append(f"vpnEnabled={result.get('vpnEnabled')!r}")
if expected_exit_ip:
    resolved = result.get("resolvedAddresses")
    if result.get("resolveError"):
        errors.append(f"resolveError={result['resolveError']}")
    if not isinstance(resolved, list) or expected_exit_ip not in resolved:
        errors.append(
            f"resolvedAddresses={resolved!r} expected to contain {expected_exit_ip!r}"
        )
    if result.get("fetchError"):
        errors.append(f"fetchError={result['fetchError']}")
    status = result.get("statusCode")
    if not isinstance(status, int) or not 200 <= status < 400:
        errors.append(f"statusCode={status!r}")
if verify_direct:
    for phase in ("directBefore", "directAfter"):
        if result.get(f"{phase}ResolveError"):
            errors.append(f"{phase}ResolveError={result[f'{phase}ResolveError']}")
        addresses = result.get(f"{phase}ResolvedAddresses")
        if not isinstance(addresses, list) or not addresses:
            errors.append(f"{phase}ResolvedAddresses={addresses!r}")
        if result.get(f"{phase}FetchError"):
            errors.append(f"{phase}FetchError={result[f'{phase}FetchError']}")
        status = result.get(f"{phase}StatusCode")
        if not isinstance(status, int) or not 200 <= status < 400:
            errors.append(f"{phase}StatusCode={status!r}")
        tunnel_status = result.get(f"{phase}PacketTunnelStatusRawValue")
        if tunnel_status not in (0, 1):
            errors.append(f"{phase}PacketTunnelStatusRawValue={tunnel_status!r}")
runtime_json = result.get("packetTunnelRuntimeStateJson") or ""
if result.get("packetTunnelStatusRawValue") == 3:
    if not runtime_json:
        errors.append("packetTunnelRuntimeStateJson missing")
    else:
        try:
            runtime = json.loads(runtime_json)
        except json.JSONDecodeError as error:
            errors.append(f"packetTunnelRuntimeStateJson invalid JSON: {error}")
        else:
            if runtime.get("vpnActive") is not True:
                errors.append(f"runtime.vpnActive={runtime.get('vpnActive')!r}")
            for key in (
                "tunPacketsRead",
                "tunBytesRead",
                "tunPacketsWritten",
                "tunBytesWritten",
                "tunPacketsDropped",
            ):
                if key not in runtime:
                    errors.append(f"runtime.{key} missing")
            expected = result.get("tunPacketProbeExpectedPackets")
            sent = result.get("tunPacketProbeSentPackets")
            observed = result.get("tunPacketProbeObservedPackets")
            observed_bytes = counter(result.get("tunPacketProbeObservedBytesRead"))
            observed_written = counter(result.get("tunPacketProbeObservedWritten"))
            observed_bytes_written = counter(result.get("tunPacketProbeObservedBytesWritten"))
            dropped_delta = counter(result.get("tunPacketProbeDroppedDelta"))
            if (
                result.get("tunPacketProbeReadIncreased") is not True
                or result.get("tunPacketProbeBytesReadIncreased") is not True
                or result.get("tunPacketProbeDroppedIncreased") is not False
                or not isinstance(expected, int)
                or sent != expected
                or not isinstance(observed, int)
                or observed < expected
                or observed_bytes is None
                or observed_bytes <= 0
                or dropped_delta is None
                or dropped_delta != 0
            ):
                errors.append(
                    "tunPacketProbeReadIncreased="
                    f"{result.get('tunPacketProbeReadIncreased')!r} "
                    f"bytesIncreased={result.get('tunPacketProbeBytesReadIncreased')!r} "
                    f"droppedIncreased={result.get('tunPacketProbeDroppedIncreased')!r} "
                    f"baseline={result.get('tunPacketProbeBaselineRead')!r} "
                    f"final={result.get('tunPacketProbeFinalRead')!r} "
                    f"expected={expected!r} sent={sent!r} observed={observed!r} "
                    f"observedBytes={observed_bytes!r} droppedDelta={dropped_delta!r} "
                    f"error={result.get('tunPacketProbeError')!r} "
                    f"sendError={result.get('tunPacketProbeSendError')!r}"
                )
            if require_reply and (
                result.get("tunPacketProbeWrittenIncreased") is not True
                or result.get("tunPacketProbeBytesWrittenIncreased") is not True
                or observed_written is None
                or observed_written <= 0
                or observed_bytes_written is None
                or observed_bytes_written <= 0
                or dropped_delta != 0
            ):
                errors.append(
                    "tunPacketProbeWrittenIncreased="
                    f"{result.get('tunPacketProbeWrittenIncreased')!r} "
                    f"bytesWrittenIncreased={result.get('tunPacketProbeBytesWrittenIncreased')!r} "
                    f"baselineWritten={result.get('tunPacketProbeBaselineWritten')!r} "
                    f"finalWritten={result.get('tunPacketProbeFinalWritten')!r} "
                    f"observedWritten={observed_written!r} "
                    f"observedBytesWritten={observed_bytes_written!r} "
                    f"droppedDelta={dropped_delta!r}"
                )

if errors:
    summary_written = write_probe_summary(errors)
    if result.get("tunPacketProbeBaselineRead") is not None:
        print(probe_summary(), file=sys.stderr)
    print("iOS TUN packet probe summary: " + summary_written, file=sys.stderr)
    print("iOS VPN probe failed: " + ", ".join(errors), file=sys.stderr)
    sys.exit(1)

if result.get("tunPacketProbeReadIncreased") is True:
    print("iOS TUN packet probe passed")
    print(probe_summary())
    print("iOS TUN packet probe summary: " + write_probe_summary())
PY
}

run_ios_device_idle_cpu_gate() {
  local device="$1"
  local process_pattern="$2"
  local label="$3"
  case "$IDLE_CPU_GATE" in
    0|false|FALSE|False|no|NO|No|off|OFF|Off)
      echo "Skipping iOS physical-device idle CPU gate because NVPN_IOS_IDLE_CPU_GATE=$IDLE_CPU_GATE"
      return
      ;;
  esac
  mkdir -p "$VPN_RESULT_DIR"
  "$ROOT/scripts/idle-cpu-gate.py" ios-process \
    --device "$device" \
    --process-pattern "$process_pattern" \
    --label "$label" \
    --artifact "$VPN_RESULT_DIR/$IOS_IDLE_CPU_RESULT_NAME" \
    --max-percent "$IDLE_CPU_MAX_PERCENT" \
    --sample-seconds "$IDLE_CPU_SAMPLE_SECONDS" \
    --settle-seconds "$IDLE_CPU_SETTLE_SECONDS"
}

run_vpn_cycle() {
  local device="$1"
  local args=(
    --nvpn-debug-exit-probe
    --nvpn-debug-wait-seconds "$VPN_START_WAIT_SECS"
    --nvpn-debug-result "$VPN_RESULT_NAME"
    --nvpn-debug-tun-probe-target "$TUN_PACKET_PROBE_TARGET"
    --nvpn-debug-tun-probe-port "$TUN_PACKET_PROBE_PORT"
    --nvpn-debug-tun-probe-count "$TUN_PACKET_PROBE_COUNT"
    --nvpn-debug-tun-probe-wait-seconds "$TUN_PACKET_PROBE_WAIT_SECS"
  )
  local wireguard_config=""
  if [[ -n "$DEBUG_WIREGUARD_CONFIG_FILE" ]]; then
    wireguard_config="$(<"$DEBUG_WIREGUARD_CONFIG_FILE")"
  elif [[ -n "$DEBUG_WIREGUARD_CONFIG" ]]; then
    wireguard_config="$DEBUG_WIREGUARD_CONFIG"
  fi
  if [[ -n "$wireguard_config" ]]; then
    args+=(--nvpn-debug-wireguard-config-base64 "$(printf '%s' "$wireguard_config" | base64 | tr -d '\n')")
  fi
  if [[ -n "$EXIT_PROBE_HOST" ]]; then
    args+=(--nvpn-debug-resolve-host "$EXIT_PROBE_HOST")
  fi
  if [[ -n "$EXIT_PROBE_URL" ]]; then
    args+=(--nvpn-debug-fetch-url "$EXIT_PROBE_URL")
  else
    args+=(--nvpn-debug-skip-fetch)
  fi
  if bool_is_true "$VERIFY_DIRECT_RESTORATION"; then
    args+=(
      --nvpn-debug-verify-direct-restoration
      --nvpn-debug-direct-resolve-host "$DIRECT_PROBE_HOST"
      --nvpn-debug-direct-fetch-url "$DIRECT_PROBE_URL"
    )
  fi
  if bool_is_true "$CREATE_NETWORK"; then
    args+=(--nvpn-debug-add-network "$DEBUG_NETWORK_NAME")
  fi
  if bool_is_true "$cleanup_after_vpn_cycle"; then
    vpn_cleanup_armed=1
    vpn_cleanup_device="$device"
  fi
  launch_device "$device" "${args[@]}"
  sleep "$((VPN_START_WAIT_SECS + VPN_RESULT_WAIT_SECS))"
  local result_path
  if ! result_path="$(copy_vpn_probe_result "$device")"; then
    copy_ios_debug_logs "$device" || true
    return 1
  fi
  if ! validate_vpn_probe_result "$result_path"; then
    copy_ios_debug_logs "$device" || true
    return 1
  fi
  echo "iOS device VPN probe passed: $result_path"
  if ! bool_is_true "$VERIFY_DIRECT_RESTORATION"; then
    run_ios_device_idle_cpu_gate "$device" '^Nostr VPN Tunnel$' "iOS packet tunnel"
  fi
  cleanup_ios_vpn "$device"
}

cleanup_ios_vpn() {
  local device="$1"
  bool_is_true "$cleanup_after_vpn_cycle" || return 0
  if ! disconnect_ios_vpn_confirmed "$device"; then
    return 1
  fi
  vpn_cleanup_armed=0
  vpn_cleanup_device=""
}

cleanup_ios_vpn_on_exit() {
  local status="$?"
  trap - EXIT
  if [[ "$vpn_cleanup_armed" -eq 1 && -n "$vpn_cleanup_device" ]]; then
    if ! cleanup_ios_vpn "$vpn_cleanup_device"; then
      echo "iOS VPN emergency cleanup failed; turn the VPN off in iOS Settings before replacing the app." >&2
      if [[ "$status" -eq 0 ]]; then
        status=1
      fi
    fi
  fi
  exit "$status"
}

trap cleanup_ios_vpn_on_exit EXIT

run_device() {
  local device="${NVPN_IOS_DEVICE:-${NVPN_IOS_DEVICE_ID:-}}"
  if [[ -z "$device" ]]; then
    if device="$(auto_select_ios_device)"; then
      echo "iOS device smoke auto-selected the only connected physical mobile device"
    else
      case "$?" in
        2)
          echo "Set NVPN_IOS_DEVICE because multiple physical iOS mobile devices are connected" >&2
          ;;
        *)
          echo "Set NVPN_IOS_DEVICE because no physical iOS mobile device could be auto-selected" >&2
          ;;
      esac
      exit 1
    fi
  fi

  xcrun devicectl device info details --device "$device" >/dev/null
  if [[ "$disconnect_only" -eq 1 ]]; then
    disconnect_ios_vpn_confirmed "$device"
    return
  fi
  if bool_is_true "$INSTALL_DEVICE_APP"; then
    install_device_app "$device"
  fi
  if bool_is_true "$IOS_LIFECYCLE_GATE"; then
    run_ios_app_lifecycle_gate \
      "$device" "$BUNDLE_ID" "$VPN_RESULT_DIR" "$IOS_LIFECYCLE_CYCLES"
  fi
  if [[ "$vpn_cycle" -eq 1 ]]; then
    run_vpn_cycle "$device"
  else
    disconnect_ios_vpn_confirmed "$device"
    run_ios_device_idle_cpu_gate "$device" '^Nostr VPN$' "iOS foreground app"
  fi
  echo "iOS device smoke launched bundle $BUNDLE_ID"
}

case "$mode" in
  simulator|sim)
    run_simulator
    ;;
  device)
    run_device
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage
    exit 2
    ;;
esac
