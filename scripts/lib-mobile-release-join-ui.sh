#!/usr/bin/env bash

# Public accessibility-tree drivers for the signed Release join gate. This
# library never reads an app container and never passes arguments/environment
# to either production application.

RELEASE_JOIN_ANDROID_UI_XML=""
RELEASE_JOIN_IOS_TEST_PID=""
RELEASE_JOIN_IOS_TEST_LOG=""
RELEASE_JOIN_IOS_TEST_NAME=""
RELEASE_JOIN_QR_CONTENT_WIDTH_MIN_BPS=9800
RELEASE_JOIN_QR_CONTENT_WIDTH_MAX_BPS=10000
RELEASE_JOIN_ANDROID_QR_CONTENT_WIDTH_BPS=""
RELEASE_JOIN_ANDROID_NETWORK_IDS=()

release_join_now_ms() {
  python3 - <<'PY'
import time
print(time.time_ns() // 1_000_000)
PY
}

release_join_android_dump_ui() {
  RELEASE_JOIN_ANDROID_UI_XML="$PRIVATE_DIR/android-ui.xml"
  "${ADB[@]}" shell uiautomator dump /sdcard/nvpn-release-join.xml >/dev/null 2>&1
  "${ADB[@]}" exec-out cat /sdcard/nvpn-release-join.xml \
    >"$RELEASE_JOIN_ANDROID_UI_XML"
}

release_join_android_query() {
  local kind="$1" expected="$2" output="$3"
  release_join_android_dump_ui
  release_join_android_query_dumped "$kind" "$expected" "$output"
}

release_join_android_query_dumped() {
  local kind="$1" expected="$2" output="$3"
  "$ROOT/scripts/mobile-release-join-ui-query.py" \
    "$RELEASE_JOIN_ANDROID_UI_XML" "$kind" "$expected" "$output"
}

release_join_android_wait_query() {
  local kind="$1" expected="$2" timeout="${3:-$RELEASE_JOIN_UI_WAIT_SECS}"
  local deadline=$((SECONDS + timeout))
  while ((SECONDS < deadline)); do
    if release_join_android_query "$kind" "$expected" center >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

release_join_android_tap() {
  local kind="$1" expected="$2" point
  point="$(release_join_android_query "$kind" "$expected" safe-center)" || return 1
  # shellcheck disable=SC2086
  "${ADB[@]}" shell input tap $point
}

release_join_android_scroll() {
  local size width height
  size="$("${ADB[@]}" shell wm size | tr -d '\r' | sed -n 's/^Physical size: //p')"
  width="${size%x*}"
  height="${size#*x}"
  "${ADB[@]}" shell input swipe \
    "$((width / 2))" "$((height * 4 / 5))" \
    "$((width / 2))" "$((height / 3))" 220
}

release_join_android_scroll_to() {
  local kind="$1" expected="$2"
  local attempts
  for attempts in $(seq 1 12); do
    if release_join_android_query "$kind" "$expected" safe-center >/dev/null 2>&1; then
      return 0
    fi
    release_join_android_scroll >/dev/null
    sleep 0.2
  done
  return 1
}

release_join_android_enter() {
  local resource="$1" value="$2"
  release_join_android_scroll_to resource "$resource"
  release_join_android_tap resource "$resource"
  "${ADB[@]}" shell input text "$value"
  "${ADB[@]}" shell input keyevent KEYCODE_BACK
}

release_join_android_launch() {
  local package="${NVPN_DEFAULT_APP_ID:-fi.siriusbusiness.nvpn}"
  "${ADB[@]}" shell am start -W \
    -n "$package/org.nostrvpn.app.MainActivity" >/dev/null
}

release_join_android_accept_camera_permission() {
  local deadline=$((SECONDS + 8))
  while ((SECONDS < deadline)); do
    if release_join_android_query description "QR scanner camera" center >/dev/null 2>&1; then
      return 0
    fi
    release_join_android_tap resource "com.android.permissioncontroller:id/permission_allow_foreground_only_button" \
      >/dev/null 2>&1 \
      || release_join_android_tap resource "com.android.permissioncontroller:id/permission_allow_button" \
        >/dev/null 2>&1 \
      || release_join_android_tap description "While using the app" >/dev/null 2>&1 \
      || true
    sleep 0.25
  done
  return 1
}

release_join_android_public_value() {
  local resource="$1" prefix="$2" description
  description="$(release_join_android_query resource "$resource" description)" || return 1
  [[ "$description" == "$prefix: "* ]] || return 1
  printf '%s\n' "${description#"$prefix: "}"
}

release_join_valid_npub() {
  [[ "$1" =~ ^npub1[023456789acdefghjklmnpqrstuvwxyz]{58}$ ]]
}

release_join_android_open_devices() {
  release_join_android_launch
  release_join_android_wait_query resource navigation-devices
  release_join_android_tap resource navigation-devices
}

release_join_android_open_link_device() {
  release_join_android_open_devices
  release_join_android_wait_query resource manual-admin-open
  release_join_android_tap resource manual-admin-open
  release_join_android_wait_query resource admin-device-id-value
}

release_join_android_create_admin() {
  release_join_android_launch
  release_join_android_wait_query resource network-setup-create
  release_join_android_tap resource network-setup-create
  release_join_android_wait_query resource network-create-submit
  release_join_android_tap resource network-create-submit
  release_join_android_wait_query resource navigation-devices
  release_join_android_open_link_device
  RELEASE_JOIN_ANDROID_ADMIN_ID="$(
    release_join_android_public_value admin-device-id-value "Admin Device ID value"
  )"
  RELEASE_JOIN_ANDROID_NETWORK_ID="$(
    release_join_android_public_value admin-network-id-value "Admin Network ID value"
  )"
  release_join_valid_npub "$RELEASE_JOIN_ANDROID_ADMIN_ID"
  [[ -n "$RELEASE_JOIN_ANDROID_NETWORK_ID" ]]
  local existing
  for existing in "${RELEASE_JOIN_ANDROID_NETWORK_IDS[@]}"; do
    [[ "$existing" != "$RELEASE_JOIN_ANDROID_NETWORK_ID" ]] || {
      echo "Android join phase reused a retained network" >&2
      return 1
    }
  done
  RELEASE_JOIN_ANDROID_NETWORK_IDS+=("$RELEASE_JOIN_ANDROID_NETWORK_ID")
  export RELEASE_JOIN_ANDROID_ADMIN_ID RELEASE_JOIN_ANDROID_NETWORK_ID
}

release_join_android_show_qr() {
  release_join_android_launch
  release_join_android_wait_query resource network-setup-join
  release_join_android_tap resource network-setup-join
  release_join_android_scroll_to resource manual-join-expand
  release_join_android_tap resource manual-join-expand
  release_join_android_wait_query resource joiner-device-id-value
  RELEASE_JOIN_ANDROID_JOINER_ID="$(
    release_join_android_public_value joiner-device-id-value "Joiner Device ID value"
  )"
  release_join_valid_npub "$RELEASE_JOIN_ANDROID_JOINER_ID"
  release_join_android_scroll_to description "Join request QR code"
  release_join_android_assert_qr_full_width
  export RELEASE_JOIN_ANDROID_JOINER_ID
}

release_join_android_background_foreground_pending_qr() {
  local expected_joiner="$RELEASE_JOIN_ANDROID_JOINER_ID"
  local foreground_joiner
  "${ADB[@]}" shell input keyevent KEYCODE_HOME
  sleep 1
  release_join_android_launch
  release_join_android_scroll_to description "Join request QR code"
  release_join_android_assert_pending_qr
  foreground_joiner="$(
    release_join_android_public_value \
      joiner-device-id-value "Joiner Device ID value"
  )"
  [[ "$foreground_joiner" == "$expected_joiner" ]] || {
    echo "Android foregrounded a different pending join request" >&2
    return 1
  }
  release_join_android_assert_qr_full_width
  RELEASE_JOIN_ANDROID_PENDING_QR_LIFECYCLE_READY=1
  export RELEASE_JOIN_ANDROID_PENDING_QR_LIFECYCLE_READY
  echo "NVPN_RELEASE_JOIN_MARKER NVPN_RELEASE_JOIN_ANDROID_PENDING_QR_LIFECYCLE_READY=1"
}

release_join_android_assert_qr_full_width() {
  local qr_width content_width ratio_bps
  release_join_android_dump_ui
  qr_width="$(
    release_join_android_query_dumped \
      description "Join request QR code" width
  )" || return 1
  content_width="$(
    release_join_android_query_dumped \
      resource "join-request-qr-content" width
  )" || return 1
  [[ "$qr_width" =~ ^[1-9][0-9]*$ \
    && "$content_width" =~ ^[1-9][0-9]*$ ]] \
    || return 1
  ratio_bps=$((qr_width * 10000 / content_width))
  ((ratio_bps >= RELEASE_JOIN_QR_CONTENT_WIDTH_MIN_BPS \
    && ratio_bps <= RELEASE_JOIN_QR_CONTENT_WIDTH_MAX_BPS)) || {
    echo "Android join QR does not fill its content width ($qr_width/$content_width px)" >&2
    return 1
  }
  if [[ -z "$RELEASE_JOIN_ANDROID_QR_CONTENT_WIDTH_BPS" ]] \
      || ((ratio_bps < RELEASE_JOIN_ANDROID_QR_CONTENT_WIDTH_BPS))
  then
    RELEASE_JOIN_ANDROID_QR_CONTENT_WIDTH_BPS="$ratio_bps"
  fi
}

release_join_android_assert_pending_qr() {
  release_join_android_query description "Join request QR code" center \
    >/dev/null
  release_join_android_public_value \
    joiner-device-id-value "Joiner Device ID value" \
    | grep -Fxq "$RELEASE_JOIN_ANDROID_JOINER_ID"
}

release_join_android_wait_join_complete() {
  release_join_android_wait_accepted_participant "$1"
}

release_join_android_wait_accepted_participant() {
  local participant="$1" deadline=$((SECONDS + RELEASE_JOIN_DELIVERY_WAIT_SECS))
  while ((SECONDS < deadline)); do
    release_join_android_launch >/dev/null 2>&1 || true
    if release_join_android_query resource navigation-devices center >/dev/null 2>&1; then
      release_join_android_tap resource navigation-devices >/dev/null
      if release_join_android_query \
          resource "roster-participant-accepted-$participant" center \
          >/dev/null 2>&1; then
        return 0
      fi
    fi
    sleep 0.25
  done
  return 1
}

release_join_android_relaunch_and_wait_accepted() {
  local participant="$1"
  local package="${NVPN_DEFAULT_APP_ID:-fi.siriusbusiness.nvpn}"
  "${ADB[@]}" shell am force-stop "$package" >/dev/null
  release_join_android_launch >/dev/null
  release_join_android_wait_accepted_participant "$participant"
}

release_join_android_wait_qr_join_complete() {
  local admin="$1" deadline=$((SECONDS + RELEASE_JOIN_DELIVERY_WAIT_SECS))
  local description
  while ((SECONDS < deadline)); do
    release_join_android_launch >/dev/null 2>&1 || true
    release_join_android_dump_ui
    if release_join_android_query_dumped \
        description "Join request QR code" center >/dev/null 2>&1; then
      description="$(
        release_join_android_query_dumped \
          resource joiner-device-id-value description
      )" || return 1
      [[ "$description" == \
        "Joiner Device ID value: $RELEASE_JOIN_ANDROID_JOINER_ID" ]] \
        || return 1
      sleep 0.25
      continue
    fi
    if ! release_join_android_query_dumped \
        resource navigation-devices center >/dev/null 2>&1; then
      echo "Android join QR disappeared before joined navigation was visible" >&2
      return 1
    fi
    if ! release_join_android_query_dumped \
        resource "roster-participant-accepted-$admin" center >/dev/null 2>&1; then
      echo "Android join QR disappeared before the exact accepted admin roster was visible" >&2
      return 1
    fi
    return 0
  done
  return 1
}

release_join_android_scan_and_accept() {
  local joiner="$1" before after deadline
  release_join_android_open_link_device
  before="$(release_join_android_query resource-prefix roster-participant- count)"
  release_join_android_scroll_to resource join-request-scan-open
  release_join_android_tap resource join-request-scan-open
  release_join_android_accept_camera_permission
  echo "NVPN_RELEASE_JOIN_MARKER NVPN_RELEASE_JOIN_SCANNER_READY=1"
  release_join_android_wait_query \
    resource join-request-confirm-add "$RELEASE_JOIN_CAMERA_WAIT_SECS"
  release_join_require_fresh_ios_pending_qr
  echo "NVPN_RELEASE_JOIN_MARKER NVPN_RELEASE_JOIN_APPROVAL_SUBMITTED_MS=$(release_join_now_ms)"
  release_join_android_tap resource join-request-confirm-add
  deadline=$((SECONDS + RELEASE_JOIN_DELIVERY_WAIT_SECS))
  while ((SECONDS < deadline)); do
    release_join_android_open_devices >/dev/null 2>&1 || true
    if release_join_android_query \
        resource "roster-participant-accepted-$joiner" center \
        >/dev/null 2>&1; then
      after="$(release_join_android_query resource-prefix roster-participant- count)"
      ((after >= before + 1)) || return 1
      return 0
    fi
    sleep 0.25
  done
  return 1
}

release_join_require_fresh_ios_pending_qr() {
  local deadline=$((SECONDS + 3)) heartbeat now elapsed
  while ((SECONDS < deadline)); do
    heartbeat="$(
      release_join_ios_marker_value NVPN_RELEASE_JOIN_PENDING_QR_VISIBLE_MS
    )"
    now="$(release_join_now_ms)"
    if [[ "$heartbeat" =~ ^[0-9]+$ ]]; then
      elapsed=$((now - heartbeat))
      if ((elapsed >= 0 && elapsed <= 1000)); then
        return 0
      fi
    fi
    sleep 0.1
  done
  echo "iPhone join QR was not visibly pending immediately before Android approval" >&2
  return 1
}

release_join_android_manual_submit() {
  local admin="$1" network="$2"
  release_join_android_launch
  release_join_android_wait_query resource network-setup-join
  release_join_android_tap resource network-setup-join
  release_join_android_scroll_to resource manual-join-expand
  release_join_android_tap resource manual-join-expand
  release_join_android_wait_query resource joiner-device-id-value
  RELEASE_JOIN_ANDROID_JOINER_ID="$(
    release_join_android_public_value joiner-device-id-value "Joiner Device ID value"
  )"
  release_join_valid_npub "$RELEASE_JOIN_ANDROID_JOINER_ID"
  release_join_android_enter manual-join-admin-id "$admin"
  release_join_android_enter manual-join-network-id "$network"
  release_join_android_scroll_to resource manual-join-submit
  release_join_android_tap resource manual-join-submit
  local deadline=$((SECONDS + 3))
  while ((SECONDS < deadline)); do
    if ! release_join_android_query resource manual-join-submit center >/dev/null 2>&1; then
      echo "NVPN_RELEASE_JOIN_MARKER NVPN_RELEASE_JOIN_MANUAL_SUBMITTED=1"
      export RELEASE_JOIN_ANDROID_JOINER_ID
      return 0
    fi
    sleep 0.1
  done
  echo "Android manual join submit did not change the shipped UI" >&2
  return 1
}

release_join_android_manual_admin_add() {
  local joiner="$1" before after deadline
  release_join_android_open_link_device
  before="$(release_join_android_query resource-prefix roster-participant- count)"
  release_join_android_scroll_to resource manual-admin-joiner-id
  release_join_android_enter manual-admin-joiner-id "$joiner"
  release_join_android_scroll_to resource manual-admin-submit
  echo "NVPN_RELEASE_JOIN_MARKER NVPN_RELEASE_JOIN_APPROVAL_SUBMITTED_MS=$(release_join_now_ms)"
  release_join_android_tap resource manual-admin-submit
  deadline=$((SECONDS + RELEASE_JOIN_DELIVERY_WAIT_SECS))
  while ((SECONDS < deadline)); do
    release_join_android_open_devices >/dev/null 2>&1 || true
    if release_join_android_query \
        resource "roster-participant-accepted-$joiner" center \
        >/dev/null 2>&1; then
      after="$(release_join_android_query resource-prefix roster-participant- count)"
      ((after >= before + 1)) || return 1
      return 0
    fi
    sleep 0.25
  done
  return 1
}

release_join_ios_test_command() {
  local test_name="$1"
  shift
  local team="${NVPN_IOS_TEAM_ID:?Release join gate requires NVPN_IOS_TEAM_ID}"
  local bundle="${NVPN_DEFAULT_IOS_BUNDLE_ID:-fi.siriusbusiness.nvpn}"
  local -a command=()
  if release_join_reuse_artifacts; then
    local case_xctestrun
    local -a rewrite_command=()
    local -a runner_environment=()
    if ! case_xctestrun="$(
      mktemp "$PRIVATE_DIR/join-$test_name.XXXXXX.xctestrun"
    )"; then
      return 1
    fi
    rewrite_command=(
      python3 "$ROOT/scripts/ios_frozen_archive.py"
      rewrite-xctestrun
      --source "$RELEASE_JOIN_IOS_XCTESTRUN"
      --output "$case_xctestrun"
      --products-root "$RELEASE_JOIN_IOS_DERIVED_DATA/Build/Products"
      --target-app "$RELEASE_JOIN_IOS_APP_PATH"
      --environment-stdin0
    )
    runner_environment=(
      "NVPN_RELEASE_JOIN_ADMIN_ID="
      "NVPN_RELEASE_JOIN_BLACKBOX="
      "NVPN_RELEASE_JOIN_CAMERA_WAIT_SECS="
      "NVPN_RELEASE_JOIN_DELIVERY_WAIT_SECS="
      "NVPN_RELEASE_JOIN_JOINER_ID="
      "NVPN_RELEASE_JOIN_NETWORK_ID="
      "NVPN_RELEASE_JOIN_NETWORK_NAME="
      "NVPN_IOS_BUNDLE_ID="
      "NVPN_RELEASE_JOIN_BLACKBOX=1"
      "NVPN_RELEASE_JOIN_DELIVERY_WAIT_SECS=$RELEASE_JOIN_DELIVERY_WAIT_SECS"
      "NVPN_RELEASE_JOIN_CAMERA_WAIT_SECS=$RELEASE_JOIN_CAMERA_WAIT_SECS"
      "NVPN_IOS_BUNDLE_ID=$bundle"
    )
    local assignment
    for assignment in "$@"; do
      runner_environment+=("$assignment")
    done
    if ! printf '%s\0' "${runner_environment[@]}" \
      | "${rewrite_command[@]}"
    then
      rm -f "$case_xctestrun"
      return 1
    fi
    command=(
      xcodebuild
      -quiet
      -xctestrun "$case_xctestrun"
      -destination "platform=iOS,id=$RELEASE_JOIN_IOS_UDID,arch=arm64"
      -destination-timeout 60
      -collect-test-diagnostics never
      -only-testing:"NostrVpnIosUITests/NostrVpnReleaseJoinUITests/$test_name"
    )
  else
    command=(
      xcodebuild
      -quiet
      -allowProvisioningUpdates
      -project "$ROOT/ios/NostrVpnIos.xcodeproj"
      -scheme NostrVpnIos
      -configuration Release
      -derivedDataPath "$RELEASE_JOIN_IOS_DERIVED_DATA"
      -destination "platform=iOS,id=$RELEASE_JOIN_IOS_UDID,arch=arm64"
      -destination-timeout 60
      -collect-test-diagnostics never
      -only-testing:"NostrVpnIosUITests/NostrVpnReleaseJoinUITests/$test_name"
      DEVELOPMENT_TEAM="$team"
      NVPN_IOS_CODE_SIGN_IDENTITY="$NVPN_IOS_CODE_SIGN_IDENTITY"
      NVPN_IOS_PROVISIONING_PROFILE_UUID="$NVPN_IOS_PROVISIONING_PROFILE_UUID"
      NVPN_IOS_PACKET_TUNNEL_PROVISIONING_PROFILE_UUID="$NVPN_IOS_PACKET_TUNNEL_PROVISIONING_PROFILE_UUID"
      NVPN_RELEASE_JOIN_BLACKBOX=1
      NVPN_RELEASE_JOIN_DELIVERY_WAIT_SECS="$RELEASE_JOIN_DELIVERY_WAIT_SECS"
      NVPN_RELEASE_JOIN_CAMERA_WAIT_SECS="$RELEASE_JOIN_CAMERA_WAIT_SECS"
      NVPN_IOS_BUNDLE_ID="$bundle"
    )
    command+=("$@")
  fi
  command+=(test-without-building)
  printf '%s\0' "${command[@]}"
}

release_join_ios_start_test() {
  local test_name="$1" log="$2"
  shift 2
  local -a command=()
  local command_file
  command_file="$(mktemp "$PRIVATE_DIR/ios-command.XXXXXX")"
  if ! release_join_ios_test_command "$test_name" "$@" >"$command_file"; then
    rm -f "$command_file"
    return 1
  fi
  while IFS= read -r -d '' item; do
    command+=("$item")
  done <"$command_file"
  rm -f "$command_file"
  [[ "${#command[@]}" -gt 0 ]] || return 1
  mkdir -p "$(dirname "$log")"
  "${command[@]}" >"$log" 2>&1 &
  RELEASE_JOIN_IOS_TEST_PID=$!
  RELEASE_JOIN_IOS_TEST_LOG="$log"
  RELEASE_JOIN_IOS_TEST_NAME="$test_name"
}

release_join_ios_assert_selected_test_started() {
  local expected="Test Case '-[NostrVpnIosUITests.NostrVpnReleaseJoinUITests $RELEASE_JOIN_IOS_TEST_NAME]' started."
  grep -Fq "$expected" "$RELEASE_JOIN_IOS_TEST_LOG" || {
    echo "iOS join xcodebuild selected zero tests: $RELEASE_JOIN_IOS_TEST_NAME" >&2
    tail -n 120 "$RELEASE_JOIN_IOS_TEST_LOG" >&2 || true
    return 1
  }
}

release_join_ios_wait_marker() {
  local marker="$1" timeout="${2:-$RELEASE_JOIN_UI_WAIT_SECS}"
  local deadline=$((SECONDS + timeout))
  while ((SECONDS < deadline)); do
    if grep -Fq "NVPN_RELEASE_JOIN_MARKER $marker" "$RELEASE_JOIN_IOS_TEST_LOG" \
        2>/dev/null; then
      return 0
    fi
    if [[ -n "$RELEASE_JOIN_IOS_TEST_PID" ]] \
        && ! kill -0 "$RELEASE_JOIN_IOS_TEST_PID" 2>/dev/null; then
      wait "$RELEASE_JOIN_IOS_TEST_PID" || true
      RELEASE_JOIN_IOS_TEST_PID=""
      tail -n 100 "$RELEASE_JOIN_IOS_TEST_LOG" >&2 || true
      return 1
    fi
    sleep 0.25
  done
  return 1
}

release_join_ios_marker_value() {
  local name="$1"
  sed -n "s/.*NVPN_RELEASE_JOIN_MARKER $name=//p" "$RELEASE_JOIN_IOS_TEST_LOG" \
    | tail -n 1
}

release_join_ios_finish_test() {
  [[ -n "$RELEASE_JOIN_IOS_TEST_PID" ]] || return 1
  local status=0
  wait "$RELEASE_JOIN_IOS_TEST_PID" || status=$?
  RELEASE_JOIN_IOS_TEST_PID=""
  if [[ "$status" -eq 0 ]] \
      && ! release_join_ios_assert_selected_test_started; then
    status=1
  fi
  if [[ "$status" -ne 0 ]]; then
    tail -n 120 "$RELEASE_JOIN_IOS_TEST_LOG" >&2 || true
  fi
  RELEASE_JOIN_IOS_TEST_NAME=""
  return "$status"
}

release_join_ios_run_test() {
  local test_name="$1" log="$2"
  shift 2
  release_join_ios_start_test "$test_name" "$log" "$@"
  release_join_ios_finish_test
}
