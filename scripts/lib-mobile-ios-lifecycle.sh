#!/usr/bin/env bash

ios_lifecycle_copy_result() {
  local device="$1"
  local bundle_id="$2"
  local result_name="$3"
  local destination="$4"
  rm -f "$destination"
  xcrun devicectl device copy from \
    --device "$device" \
    --domain-type appDataContainer \
    --domain-identifier "$bundle_id" \
    --source "Library/Application Support/Nostr VPN Debug Results/$result_name" \
    --destination "$destination" \
    --quiet
}

ios_lifecycle_validate_history() {
  local history="$1"
  local markers="$2"
  local run_id="$3"
  local cycles="$4"
  local dwell_seconds="$5"

  python3 - "$history" "$markers" "$run_id" "$cycles" "$dwell_seconds" <<'PY'
import json
import sys

history_path, marker_path, run_id, cycles_raw, dwell_raw = sys.argv[1:]
cycles = int(cycles_raw)
dwell_milliseconds = int(dwell_raw) * 1_000

with open(history_path, encoding="utf-8") as handle:
    receipt = json.load(handle)
with open(marker_path, encoding="utf-8") as handle:
    marker_lines = [line.strip() for line in handle if line.strip()]

if receipt.get("runId") != run_id:
    raise SystemExit("lifecycle receipt run ID does not match this XCTest run")
history = receipt.get("history")
if not isinstance(history, list) or not history:
    raise SystemExit("lifecycle receipt has no transition history")
if history[0].get("phase") != "armed":
    raise SystemExit("lifecycle history does not start with its armed event")

transitions = [event.get("transition") for event in history]
if transitions != list(range(1, len(history) + 1)):
    raise SystemExit(f"lifecycle transitions are not contiguous: {transitions!r}")

processes = {event.get("processIdentifier") for event in history}
if len(processes) != 1 or None in processes:
    raise SystemExit(f"lifecycle gate crossed app processes: {processes!r}")

previous_wall = 0
previous_monotonic = 0
background = None
pairs = []
for event in history:
    wall = event.get("wallClockMilliseconds")
    monotonic = event.get("monotonicMilliseconds")
    if not isinstance(wall, int) or wall < previous_wall:
        raise SystemExit("lifecycle wall-clock history is missing or unordered")
    if not isinstance(monotonic, int) or monotonic < previous_monotonic:
        raise SystemExit("lifecycle monotonic history is missing or unordered")
    previous_wall = wall
    previous_monotonic = monotonic

    phase = event.get("phase")
    core_available = event.get("nativeCoreAvailable")
    if phase == "background":
        if core_available is not False:
            raise SystemExit("native core remained available in a background event")
        if background is not None:
            raise SystemExit("two background events occurred without an active event")
        background = event
    elif phase == "active" and background is not None:
        if core_available is not True:
            raise SystemExit("native core was unavailable in an active event")
        elapsed = monotonic - background["monotonicMilliseconds"]
        if elapsed < dwell_milliseconds - 250:
            raise SystemExit(
                f"background dwell was only {elapsed}ms; expected about {dwell_milliseconds}ms"
            )
        pairs.append((background, event))
        background = None

if background is not None:
    raise SystemExit("lifecycle history ended while the app was backgrounded")
if len(pairs) != cycles:
    raise SystemExit(f"lifecycle history has {len(pairs)} completed cycles; expected {cycles}")
if receipt.get("phase") != "active" or receipt.get("nativeCoreAvailable") is not True:
    raise SystemExit("final lifecycle receipt is not active with a reopened native core")
if receipt.get("transition") != history[-1].get("transition"):
    raise SystemExit("final lifecycle transition does not match the retained history")

required_markers = {
    f"NVPN_XCUITEST_RUN_ID={run_id}",
    f"NVPN_IOS_LIFECYCLE_RESULT_NAME={history_path.rsplit('/', 1)[-1].replace('-history', '')}",
}
if not required_markers.issubset(set(marker_lines)):
    raise SystemExit("XCTest lifecycle marker receipt is stale or incomplete")

def marker_milliseconds(name):
    prefix = f"{name}="
    values = [line[len(prefix):] for line in marker_lines if line.startswith(prefix)]
    if len(values) != 1:
        raise SystemExit(f"expected one {name} marker, got {len(values)}")
    try:
        return int(values[0])
    except ValueError as error:
        raise SystemExit(f"{name} is not a timestamp") from error

passed = marker_milliseconds("NVPN_IOS_LIFECYCLE_XCTEST_PASSED_MS")
previous = marker_milliseconds("NVPN_IOS_LIFECYCLE_LAUNCH_FOREGROUND_MS")
for cycle in range(1, cycles + 1):
    home = marker_milliseconds(f"NVPN_IOS_LIFECYCLE_CYCLE_{cycle}_HOME_REQUESTED_MS")
    observed = marker_milliseconds(
        f"NVPN_IOS_LIFECYCLE_CYCLE_{cycle}_BACKGROUND_OBSERVED_MS"
    )
    activate = marker_milliseconds(
        f"NVPN_IOS_LIFECYCLE_CYCLE_{cycle}_ACTIVATE_REQUESTED_MS"
    )
    foreground = marker_milliseconds(
        f"NVPN_IOS_LIFECYCLE_CYCLE_{cycle}_FOREGROUND_OBSERVED_MS"
    )
    if not previous <= home <= observed <= activate <= foreground <= passed:
        raise SystemExit(f"XCTest cycle {cycle} timestamps are unordered")
    if activate - observed < dwell_milliseconds - 250:
        raise SystemExit(
            f"XCTest cycle {cycle} dwell was {activate - observed}ms; "
            f"expected about {dwell_milliseconds}ms"
        )
    previous = foreground

print(
    json.dumps(
        {
            "cycles": cycles,
            "dwellMilliseconds": dwell_milliseconds,
            "firstBackgroundWallClockMilliseconds": pairs[0][0]["wallClockMilliseconds"],
            "lastForegroundWallClockMilliseconds": pairs[-1][1]["wallClockMilliseconds"],
            "processIdentifier": next(iter(processes)),
            "runId": run_id,
            "transitions": len(history),
        },
        sort_keys=True,
    )
)
PY
}

_run_ios_app_lifecycle_gate() {
  local device="$1"
  local bundle_id="$2"
  local result_dir="$3"
  local cycles="$4"
  local mode="$5"
  shift 5
  local result_prefix run_id_prefix test_method gate_description
  case "$mode" in
    standalone)
      result_prefix="mobile-ios-lifecycle"
      run_id_prefix="ios-lifecycle"
      test_method="testPhysicalNativeCoreBackgroundForegroundLifecycle"
      gate_description="physical lifecycle"
      ;;
    active-tunnel)
      result_prefix="mobile-ios-active-tunnel-lifecycle"
      run_id_prefix="ios-active-tunnel-lifecycle"
      test_method="testPhysicalActiveTunnelBackgroundForegroundLifecycle"
      gate_description="active-tunnel lifecycle"
      ;;
    *)
      echo "Unknown iOS lifecycle gate mode: $mode" >&2
      return 1
      ;;
  esac

  local result_name="$result_prefix-$$-$RANDOM.json"
  local stem="${result_name%.json}"
  local background_dwell="${NVPN_IOS_LIFECYCLE_BACKGROUND_DWELL_SECS:-10}"
  local run_id="$run_id_prefix-$$-$RANDOM-$(date +%s)"
  local log="$result_dir/$stem-xcodebuild.log"
  local markers="$result_dir/$stem-markers.log"
  local history="$result_dir/$stem-history.json"
  local summary="$result_dir/$stem-summary.json"
  local xcresult="$result_dir/$stem.xcresult"
  local team="${NVPN_IOS_TEAM_ID:-}"
  local destination_udid arguments_base64="" ignored

  if ! [[ "$cycles" =~ ^[1-5]$ ]]; then
    echo "iOS $gate_description gate requires 1-5 lifecycle cycles" >&2
    return 1
  fi
  if ! [[ "$background_dwell" =~ ^[0-9]+$ ]]; then
    echo "iOS $gate_description gate requires an integer background dwell" >&2
    return 1
  fi
  if [[ "$mode" == "active-tunnel" ]]; then
    if (( background_dwell < 10 )); then
      echo "iOS active-tunnel lifecycle requires at least 10s background dwell" >&2
      return 1
    fi
    local lifecycle_timeout="$((background_dwell * cycles + 40 * cycles + 30))"
    local -a app_arguments=(
      "$@"
      --nvpn-debug-lifecycle-result "$result_name"
      --nvpn-debug-lifecycle-run-id "$run_id"
      --nvpn-debug-await-active-tunnel-lifecycle
      --nvpn-debug-active-lifecycle-cycles "$cycles"
      --nvpn-debug-active-lifecycle-timeout-seconds "$lifecycle_timeout"
    )
    arguments_base64="$(python3 - "${app_arguments[@]}" <<'PY'
import base64
import json
import sys

print(base64.b64encode(json.dumps(sys.argv[1:]).encode()).decode())
PY
    )"
  fi

  [[ -n "$team" ]] || {
    echo "Set NVPN_IOS_TEAM_ID to run the physical iOS $gate_description XCTest." >&2
    return 1
  }
  destination_udid="$(resolve_physical_ios_udid "$device")"
  prepare_device_signing "$device"
  mkdir -p "$result_dir"
  rm -rf "$xcresult"
  rm -f "$log" "$markers" "$history" "$summary"

  local -a command=(
    xcodebuild
    -allowProvisioningUpdates
    -project "$PROJECT"
    -scheme "$SCHEME"
    -configuration "$DEVICE_CONFIGURATION"
    -derivedDataPath "$DEVICE_DERIVED_DATA"
    -destination "platform=iOS,id=$destination_udid"
    -destination-timeout 60
    -collect-test-diagnostics never
    -resultBundlePath "$xcresult"
    "-only-testing:NostrVpnIosUITests/NostrVpnLifecycleUITests/$test_method"
    DEVELOPMENT_TEAM="$team"
  )
  if bool_is_true "${NVPN_IOS_XCODEBUILD_QUIET:-1}"; then
    command+=( -quiet )
  fi
  if [[ "$DEVICE_SIGNING_MODE" == "adhoc" ]]; then
    command+=(
      NVPN_IOS_CODE_SIGN_IDENTITY="$DEVICE_CODE_SIGN_IDENTITY"
      NVPN_IOS_PROVISIONING_PROFILE_UUID="$NVPN_IOS_PROVISIONING_PROFILE_UUID"
      NVPN_IOS_PACKET_TUNNEL_PROVISIONING_PROFILE_UUID="$NVPN_IOS_PACKET_TUNNEL_PROVISIONING_PROFILE_UUID"
    )
  else
    command+=(CODE_SIGN_IDENTITY="$DEVICE_CODE_SIGN_IDENTITY")
  fi
  if [[
    -n "${NVPN_ASC_AUTH_KEY_PATH:-}" &&
    -n "${NVPN_ASC_AUTH_KEY_ID:-}" &&
    -n "${NVPN_ASC_AUTH_KEY_ISSUER_ID:-}"
  ]]; then
    command+=(
      -authenticationKeyPath "$NVPN_ASC_AUTH_KEY_PATH"
      -authenticationKeyID "$NVPN_ASC_AUTH_KEY_ID"
      -authenticationKeyIssuerID "$NVPN_ASC_AUTH_KEY_ISSUER_ID"
    )
  fi
  command+=(
    NVPN_XCUITEST_RUN_ID="$run_id"
    NVPN_XCUITEST_LIFECYCLE_GATE=1
    NVPN_XCUITEST_LIFECYCLE_RESULT_NAME="$result_name"
    NVPN_XCUITEST_LIFECYCLE_CYCLES="$cycles"
    NVPN_XCUITEST_LIFECYCLE_BACKGROUND_DWELL_SECS="$background_dwell"
  )
  if [[ "$mode" == "active-tunnel" ]]; then
    command+=(NVPN_XCUITEST_APP_LAUNCH_ARGS_BASE64="$arguments_base64")
  fi
  command+=(test)

  if ! NSUnbufferedIO=YES "${command[@]}" >"$log" 2>&1; then
    tail -n 120 "$log" >&2
    echo "Enable Settings > Developer > Enable UI Automation on the unlocked iPhone, then retry." >&2
    echo "iOS $gate_description XCTest failed: $xcresult" >&2
    return 1
  fi

  xcrun devicectl device copy from \
    --device "$device" \
    --domain-type appDataContainer \
    --domain-identifier "$bundle_id.UITests.xctrunner" \
    --source "Documents/nvpn-ui-gate-markers.log" \
    --destination "$markers" \
    --quiet >/dev/null

  for ignored in $(seq 1 40); do
    if ios_lifecycle_copy_result \
      "$device" "$bundle_id" "$result_name" "$history" 2>/dev/null
    then
      if ios_lifecycle_validate_history \
        "$history" "$markers" "$run_id" "$cycles" "$background_dwell" \
        >"$summary" 2>"$summary.error"
      then
        rm -f "$summary.error"
        printf 'iOS %s gate passed: %s cycles, %ss dwell; artifacts: %s\n' \
          "$gate_description" "$cycles" "$background_dwell" "$result_dir"
        return 0
      fi
    fi
    sleep 0.25
  done

  cat "$summary.error" >&2 2>/dev/null || true
  echo "iOS $gate_description XCTest passed but app-side lifecycle history was incomplete." >&2
  echo "iOS $gate_description artifacts: $result_dir" >&2
  return 1
}

run_ios_app_lifecycle_gate() {
  local device="$1"
  local bundle_id="$2"
  local result_dir="$3"
  local cycles="$4"
  _run_ios_app_lifecycle_gate \
    "$device" "$bundle_id" "$result_dir" "$cycles" standalone
}

run_ios_active_tunnel_lifecycle_gate() {
  local device="$1"
  local bundle_id="$2"
  local result_dir="$3"
  local cycles="$4"
  shift 4
  _run_ios_app_lifecycle_gate \
    "$device" "$bundle_id" "$result_dir" "$cycles" active-tunnel "$@"
}
