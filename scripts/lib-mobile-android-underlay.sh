#!/usr/bin/env bash

ANDROID_UNDERLAY_HOME_RESTORE_ARMED=0
ANDROID_UNDERLAY_AVAILABLE_LOWER_BOUND_MS=""
ANDROID_UNDERLAY_PAYLOAD_COMPLETED_MS=""
ANDROID_UNDERLAY_PAYLOAD_RECOVERY_MS=""

android_underlay_require_environment() {
  local name
  for name in \
    NVPN_ANDROID_UNDERLAY_HOME_SSID \
    NVPN_ANDROID_UNDERLAY_ALTERNATE_SSID \
    NVPN_ANDROID_UNDERLAY_ALTERNATE_SECURITY \
    NVPN_ANDROID_UNDERLAY_UDP_ECHO_HOST \
    NVPN_ANDROID_UNDERLAY_UDP_ECHO_PORT \
    NVPN_MOBILE_UNDERLAY_CONTINUITY_CONTAINER \
    NVPN_MOBILE_UNDERLAY_CONTINUITY_CLIENT_IP
  do
    if [[ -z "${!name:-}" ]]; then
      echo "Android physical underlay gate requires $name" >&2
      return 1
    fi
  done
  if ! [[ "$NVPN_ANDROID_UNDERLAY_UDP_ECHO_PORT" =~ ^[0-9]+$ ]] \
    || (( NVPN_ANDROID_UNDERLAY_UDP_ECHO_PORT < 1 \
      || NVPN_ANDROID_UNDERLAY_UDP_ECHO_PORT > 65535 ))
  then
    echo "Android physical underlay gate requires a valid UDP echo port" >&2
    return 1
  fi
  case "${NVPN_ANDROID_UNDERLAY_HOME_RECONNECT:-credentials}" in
    saved)
      ;;
    credentials)
      if [[ -z "${NVPN_ANDROID_UNDERLAY_HOME_SECURITY:-}" ]]; then
        echo "Android physical underlay gate requires NVPN_ANDROID_UNDERLAY_HOME_SECURITY" >&2
        return 1
      fi
      android_underlay_validate_network_credentials \
        home \
        "$NVPN_ANDROID_UNDERLAY_HOME_SECURITY" \
        "${NVPN_ANDROID_UNDERLAY_HOME_PASSPHRASE:-}" \
        || return 1
      ;;
    *)
      echo "NVPN_ANDROID_UNDERLAY_HOME_RECONNECT must be credentials or saved" >&2
      return 1
      ;;
  esac
  if [[ "$NVPN_ANDROID_UNDERLAY_HOME_SSID" == \
    "$NVPN_ANDROID_UNDERLAY_ALTERNATE_SSID" ]]
  then
    echo "Android physical underlay gate requires two different Wi-Fi networks" >&2
    return 1
  fi
  android_underlay_validate_network_credentials \
    alternate \
    "$NVPN_ANDROID_UNDERLAY_ALTERNATE_SECURITY" \
    "${NVPN_ANDROID_UNDERLAY_ALTERNATE_PASSPHRASE:-}"
}

android_underlay_stop_managed_ap() {
  local host="${NVPN_ANDROID_UNDERLAY_MANAGED_AP_SSH_HOST:-}"
  local connection="${NVPN_ANDROID_UNDERLAY_MANAGED_AP_CONNECTION:-}"
  [[ -n "$host" || -n "$connection" ]] || return 0
  if [[ -z "$host" || -z "$connection" \
    || "$host" == -* || "$connection" == -* \
    || "$host" =~ [[:space:]] || "$connection" =~ [[:space:]] ]]
  then
    echo "Android managed AP cleanup target is invalid" >&2
    return 1
  fi
  if ! ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" \
      sudo -n nmcli -g NAME connection show \
      | grep -Fxq "$connection"
  then
    return 0
  fi
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" \
    sudo -n nmcli connection down "$connection" >/dev/null 2>&1 || true
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" \
    sudo -n nmcli connection delete "$connection" >/dev/null
  if ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" \
      sudo -n nmcli -g NAME connection show \
      | grep -Fxq "$connection"
  then
    echo "Android managed AP still exists after its exact delete request" >&2
    return 1
  fi
}

android_underlay_reconnect_home() {
  if [[ "${NVPN_ANDROID_UNDERLAY_HOME_RECONNECT:-credentials}" == "saved" ]]; then
    android_underlay_stop_managed_ap || return 1
    "$ADB" -s "$serial" shell svc wifi disable >/dev/null
    if ! android_underlay_wait_wifi_radio disabled 5; then
      echo "Android Wi-Fi radio did not turn off before saved-home restore" >&2
      return 1
    fi
    "$ADB" -s "$serial" shell svc wifi enable >/dev/null
    if ! android_underlay_wait_wifi_radio enabled 5; then
      echo "Android Wi-Fi radio did not turn on for saved-home restore" >&2
      return 1
    fi
    "$ADB" -s "$serial" shell cmd wifi start-scan >/dev/null 2>&1 || true
  else
    android_underlay_connect_network \
      "$NVPN_ANDROID_UNDERLAY_HOME_SSID" \
      "$NVPN_ANDROID_UNDERLAY_HOME_SECURITY" \
      "${NVPN_ANDROID_UNDERLAY_HOME_PASSPHRASE:-}"
  fi
}

android_underlay_wait_wifi_radio() {
  local expected="$1" timeout_secs="$2" deadline
  deadline=$((SECONDS + timeout_secs))
  while ((SECONDS < deadline)); do
    if "$ADB" -s "$serial" shell cmd wifi status 2>/dev/null \
        | tr -d '\r' \
        | grep -Fxq "Wifi is $expected"
    then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

android_underlay_validate_network_credentials() {
  local label="$1" security="$2" passphrase="$3"
  case "$security" in
    open|owe)
      if [[ -n "$passphrase" ]]; then
        echo "Android $label $security Wi-Fi must not provide a passphrase" >&2
        return 1
      fi
      ;;
    wpa2|wpa3|wep)
      if [[ -z "$passphrase" ]]; then
        echo "Android $label $security Wi-Fi requires its env-only passphrase" >&2
        return 1
      fi
      ;;
    *)
      echo "Android $label Wi-Fi security must be open, owe, wpa2, wpa3, or wep" >&2
      return 1
      ;;
  esac
}

android_underlay_connect_network() {
  local ssid="$1" security="$2" passphrase="$3"
  local ssid_base64 passphrase_base64 command
  ssid_base64="$(printf '%s' "$ssid" | base64 | tr -d '\n')"
  passphrase_base64="$(printf '%s' "$passphrase" | base64 | tr -d '\n')"
  command="ssid=\$(printf %s '$ssid_base64' | base64 -d); "
  if [[ "$security" == "open" || "$security" == "owe" ]]; then
    command+="cmd wifi connect-network \"\$ssid\" '$security'"
  else
    command+="pass=\$(printf %s '$passphrase_base64' | base64 -d); "
    command+="cmd wifi connect-network \"\$ssid\" '$security' \"\$pass\""
  fi
  { set +x; } 2>/dev/null
  "$ADB" -s "$serial" shell "$command" >/dev/null
}

android_underlay_network_is_validated() {
  local ssid="$1" wifi connectivity
  wifi="$("$ADB" -s "$serial" shell cmd wifi status 2>/dev/null | tr -d '\r')" \
    || return 1
  connectivity="$(
    "$ADB" -s "$serial" shell dumpsys connectivity 2>/dev/null | tr -d '\r'
  )" || return 1
  python3 - "$ssid" "$wifi" "$connectivity" <<'PY'
import re
import sys

ssid, wifi, connectivity = sys.argv[1:]
if f'Wifi is connected to "{ssid}"' not in wifi or "isUsable: true" not in wifi:
    raise SystemExit(1)
for block in re.split(r"(?=NetworkAgentInfo\{)", connectivity):
    if "ni{WIFI CONNECTED" not in block or "NOT_VPN" not in block:
        continue
    if "INTERNET" not in block or "VALIDATED" not in block:
        continue
    if f'SSID="{ssid}"' in block or f'SSID: "{ssid}"' in block:
        raise SystemExit(0)
raise SystemExit(1)
PY
}

android_underlay_wait_validated() {
  local ssid="$1" timeout_secs="$2" initial_lower_bound_ms="${3:-}"
  local deadline check_started_ms last_failed_lower_bound_ms
  deadline=$((SECONDS + timeout_secs))
  ANDROID_UNDERLAY_AVAILABLE_LOWER_BOUND_MS=""
  last_failed_lower_bound_ms="$initial_lower_bound_ms"
  [[ -n "$last_failed_lower_bound_ms" ]] \
    || last_failed_lower_bound_ms="$(mobile_underlay_now_ms)"
  while ((SECONDS < deadline)); do
    # Timestamp before each potentially slow adb/dumpsys check. If the check
    # fails, this is guaranteed to be no later than the last known-unavailable
    # observation, so using it as the eventual availability bound can only make
    # the measured recovery interval longer.
    check_started_ms="$(mobile_underlay_now_ms)"
    if android_underlay_network_is_validated "$ssid"; then
      ANDROID_UNDERLAY_AVAILABLE_LOWER_BOUND_MS="$last_failed_lower_bound_ms"
      return 0
    fi
    last_failed_lower_bound_ms="$check_started_ms"
    sleep 0.2
  done
  return 1
}

android_underlay_unique_udp_echo() {
  local cycle="$1" available_lower_bound_ms="$2" recovery_max_ms="$3"
  local result_path completion_ms recovery_ms
  ANDROID_UNDERLAY_PAYLOAD_COMPLETED_MS=""
  ANDROID_UNDERLAY_PAYLOAD_RECOVERY_MS=""
  result_path="${NVPN_ANDROID_RESULT_DIR:-$ROOT/artifacts/mobile-android}/mobile-android-underlay-udp-$cycle-$$.log"
  android_build_captured_network_probe || return 1
  if ! "$ADB" -s "$serial" shell \
      env "CLASSPATH=$ANDROID_CAPTURED_PROBE_REMOTE_JAR" \
      app_process /system/bin MobileAndroidCapturedNetworkProbe \
      --udp-echo \
      "$NVPN_ANDROID_UNDERLAY_UDP_ECHO_HOST" \
      "$NVPN_ANDROID_UNDERLAY_UDP_ECHO_PORT" \
      "switch-$cycle" >"$result_path" 2>&1
  then
    echo "Android switch $cycle unique post-validation UDP echo failed: $result_path" >&2
    return 1
  fi
  completion_ms="$(mobile_underlay_now_ms)"
  grep -Fq "udpEchoLabel=switch-$cycle " "$result_path" || {
    echo "Android switch $cycle UDP echo did not return its exact payload receipt" >&2
    return 1
  }
  recovery_ms=$((completion_ms - available_lower_bound_ms))
  if (( recovery_ms < 0 || recovery_ms > recovery_max_ms )); then
    echo "Android switch $cycle unique payload recovery was ${recovery_ms}ms (limit ${recovery_max_ms}ms)" >&2
    return 1
  fi
  ANDROID_UNDERLAY_PAYLOAD_COMPLETED_MS="$completion_ms"
  ANDROID_UNDERLAY_PAYLOAD_RECOVERY_MS="$recovery_ms"
}

android_underlay_rebind_count() {
  "$ADB" -s "$serial" logcat -d -v brief 2>/dev/null \
    | grep -Fc \
      "Physical network changed; live FIPS carriers refreshed" \
    || true
}

android_underlay_wait_for_rebind_after() {
  local baseline="$1" deadline=$((SECONDS + 8)) count
  while ((SECONDS < deadline)); do
    count="$(android_underlay_rebind_count)"
    if [[ "$count" =~ ^[0-9]+$ ]] && (( count > baseline )); then
      return 0
    fi
    sleep 0.1
  done
  echo "Android production service did not log a live FIPS carrier refresh" >&2
  return 1
}

android_underlay_assert_process_and_vpn() {
  local expected_pid="$1" current_pid
  current_pid="$(android_app_pid)"
  if [[ "$current_pid" != "$expected_pid" ]]; then
    echo "Android app/VPN process changed during the physical underlay gate" >&2
    return 1
  fi
  if ! vpn_active || ! assert_single_android_app_process; then
    echo "Android VPN did not remain active in one canonical process" >&2
    return 1
  fi
}

android_underlay_background_foreground() {
  local expected_pid="$1"
  "$ADB" -s "$serial" shell input keyevent KEYCODE_HOME
  sleep 2
  android_underlay_assert_process_and_vpn "$expected_pid" || return 1
  start_main_activity
  if ! wait_until 5 android_activity_resumed; then
    echo "Android Activity did not foreground after the underlay switch" >&2
    return 1
  fi
  android_underlay_assert_process_and_vpn "$expected_pid"
}

android_underlay_restore_home() {
  [[ "$ANDROID_UNDERLAY_HOME_RESTORE_ARMED" -eq 1 ]] || return 0
  local timeout="${NVPN_MOBILE_UNDERLAY_ASSOCIATION_TIMEOUT_SECS:-30}"
  if android_underlay_reconnect_home \
    && android_underlay_wait_validated \
      "$NVPN_ANDROID_UNDERLAY_HOME_SSID" "$timeout"
  then
    ANDROID_UNDERLAY_HOME_RESTORE_ARMED=0
    echo "Android emergency underlay cleanup restored the original validated Wi-Fi"
    return 0
  fi
  echo "Android emergency underlay cleanup could not restore the original Wi-Fi" >&2
  return 1
}

run_android_underlay_network_change_gate() {
  truthy "${NVPN_ANDROID_UNDERLAY_CHANGE_GATE:-0}" || return 0
  android_underlay_require_environment || return 1
  local association_timeout="${NVPN_MOBILE_UNDERLAY_ASSOCIATION_TIMEOUT_SECS:-30}"
  local recovery_max_ms="${NVPN_MOBILE_UNDERLAY_RECOVERY_MAX_MS:-4000}"
  mobile_underlay_require_positive_integer \
    NVPN_MOBILE_UNDERLAY_ASSOCIATION_TIMEOUT_SECS "$association_timeout" \
    || return 1
  mobile_underlay_require_positive_integer \
    NVPN_MOBILE_UNDERLAY_RECOVERY_MAX_MS "$recovery_max_ms" \
    || return 1
  if (( recovery_max_ms > 4000 )); then
    echo "Android underlay recovery budget cannot exceed 4000ms" >&2
    return 1
  fi
  if ! android_underlay_network_is_validated \
      "$NVPN_ANDROID_UNDERLAY_HOME_SSID"
  then
    echo "Android underlay gate requires the configured home Wi-Fi to be active and validated" >&2
    return 1
  fi

  local artifact_dir="${NVPN_ANDROID_RESULT_DIR:-$ROOT/artifacts/mobile-android}"
  local stem="mobile-android-underlay-$$"
  local ping_log="$artifact_dir/$stem-continuity.log"
  local markers="$artifact_dir/$stem-markers.tsv"
  local summary="$artifact_dir/$stem-summary.json"
  local expected_pid baseline_rebind available_ms requested_ms recovery_ms cycle
  mkdir -p "$artifact_dir"
  : >"$markers"
  expected_pid="$(android_app_pid)"
  android_underlay_assert_process_and_vpn "$expected_pid" || return 1
  android_build_captured_network_probe || return 1
  mobile_continuity_start \
    "$NVPN_MOBILE_UNDERLAY_CONTINUITY_CONTAINER" \
    "$NVPN_MOBILE_UNDERLAY_CONTINUITY_CLIENT_IP" \
    "$ping_log" \
    || return 1
  ANDROID_UNDERLAY_HOME_RESTORE_ARMED=1

  for cycle in 1 2; do
    local ssid security passphrase label
    if [[ "$cycle" -eq 1 ]]; then
      ssid="$NVPN_ANDROID_UNDERLAY_ALTERNATE_SSID"
      security="$NVPN_ANDROID_UNDERLAY_ALTERNATE_SECURITY"
      passphrase="${NVPN_ANDROID_UNDERLAY_ALTERNATE_PASSPHRASE:-}"
      label="alternate"
    else
      ssid="$NVPN_ANDROID_UNDERLAY_HOME_SSID"
      security="${NVPN_ANDROID_UNDERLAY_HOME_SECURITY:-saved}"
      passphrase="${NVPN_ANDROID_UNDERLAY_HOME_PASSPHRASE:-}"
      label="home"
    fi
    requested_ms="$(mobile_underlay_now_ms)"
    printf 'switch_%s_requested\t%s\n' \
      "$cycle" "$requested_ms" >>"$markers"
    baseline_rebind="$(android_underlay_rebind_count)"
    if [[ "$cycle" -eq 2 ]]; then
      if ! android_underlay_reconnect_home; then
        echo "Android could not reconnect its saved $label Wi-Fi underlay" >&2
        mobile_continuity_stop
        return 1
      fi
    elif ! android_underlay_connect_network "$ssid" "$security" "$passphrase"; then
      echo "Android could not request the $label Wi-Fi underlay" >&2
      mobile_continuity_stop
      return 1
    fi
    if ! android_underlay_wait_validated \
        "$ssid" "$association_timeout" "$requested_ms"
    then
      echo "Android $label Wi-Fi did not become validated in ${association_timeout}s" >&2
      mobile_continuity_stop
      return 1
    fi
    available_ms="$ANDROID_UNDERLAY_AVAILABLE_LOWER_BOUND_MS"
    [[ "$available_ms" =~ ^[0-9]+$ ]] || {
      echo "Android $label Wi-Fi had no conservative availability bound" >&2
      mobile_continuity_stop
      return 1
    }
    printf 'switch_%s_available\t%s\n' "$cycle" "$available_ms" >>"$markers"
    if ! android_underlay_wait_for_rebind_after "$baseline_rebind"; then
      mobile_continuity_stop
      return 1
    fi
    if ! android_underlay_unique_udp_echo \
        "$cycle" "$available_ms" "$recovery_max_ms"
    then
      mobile_continuity_stop
      return 1
    fi
    recovery_ms="$ANDROID_UNDERLAY_PAYLOAD_RECOVERY_MS"
    printf 'switch_%s_payload_recovery\t%s\n' \
      "$cycle" "$recovery_ms" >>"$markers"
    if ! mobile_continuity_wait_for_reply_count_after \
        "$ping_log" "$ANDROID_UNDERLAY_PAYLOAD_COMPLETED_MS" 2 2000 \
      || ! android_underlay_assert_process_and_vpn "$expected_pid"
    then
      mobile_continuity_stop
      return 1
    fi
    if [[ "$cycle" -eq 1 ]]; then
      android_underlay_background_foreground "$expected_pid" || {
        mobile_continuity_stop
        return 1
      }
    fi
    if truthy "${RELEASE_BLACKBOX_GATE:-0}"; then
      run_android_release_exit_network_probe \
        "wireguard-exit-after-underlay-$label" || {
          mobile_continuity_stop
          return 1
        }
    else
      run_android_tun_packet_probe || {
        mobile_continuity_stop
        return 1
      }
      run_android_exit_network_probe "wireguard-exit-after-underlay-$label" || {
        mobile_continuity_stop
        return 1
      }
    fi
    printf 'switch_%s_verified\t%s\n' \
      "$cycle" "$(mobile_underlay_now_ms)" >>"$markers"
  done

  ANDROID_UNDERLAY_HOME_RESTORE_ARMED=0
  mobile_continuity_stop
  mobile_continuity_validate \
    "$ROOT" "$ping_log" "$markers" "$summary" Android "$recovery_max_ms" \
    || return 1
  android_underlay_assert_process_and_vpn "$expected_pid" || return 1
  echo "Android real Wi-Fi underlay-change gate passed without restarting the app/VPN"
}
