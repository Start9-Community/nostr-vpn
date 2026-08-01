#!/usr/bin/env bash

ANDROID_UNDERLAY_HOME_RESTORE_ARMED=0
ANDROID_UNDERLAY_ORIGINAL_SSID=""
ANDROID_UNDERLAY_OUTAGE_MS=""
ANDROID_UNDERLAY_PAYLOAD_COMPLETED_MS=""
ANDROID_UNDERLAY_PAYLOAD_RECOVERY_MS=""
ANDROID_UNDERLAY_FRESH_DNS_HOST=""
ANDROID_UNDERLAY_NO_FALLBACK_INSPECTIONS=0
ANDROID_UNDERLAY_PROCESS_CHECKPOINTS=()
ANDROID_UNDERLAY_NATIVE_CHECKPOINTS=()
ANDROID_VPN_NATIVE_START_LOG="WG upstream socket fd from native runtime:"
ANDROID_VPN_LOG_MARKER=""

android_underlay_require_environment() {
  local name
  for name in \
    NVPN_ANDROID_UNDERLAY_UDP_ECHO_HOST \
    NVPN_ANDROID_UNDERLAY_UDP_ECHO_PORT \
    NVPN_MOBILE_UNDERLAY_CONTINUITY_CONTAINER \
    NVPN_MOBILE_UNDERLAY_CONTINUITY_CLIENT_IP \
    NVPN_ANDROID_EXIT_PROBE_HOST \
    NVPN_ANDROID_EXIT_PROBE_EXPECTED_IP
  do
    if [[ -z "${!name:-}" ]]; then
      echo "Android physical radio-bounce gate requires $name" >&2
      return 1
    fi
  done
  if ! [[ "$NVPN_ANDROID_UNDERLAY_UDP_ECHO_PORT" =~ ^[0-9]+$ ]] \
    || (( NVPN_ANDROID_UNDERLAY_UDP_ECHO_PORT < 1 \
      || NVPN_ANDROID_UNDERLAY_UDP_ECHO_PORT > 65535 ))
  then
    echo "Android physical radio-bounce gate requires a valid UDP echo port" >&2
    return 1
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

android_underlay_original_ssid() {
  "$ADB" -s "$serial" shell cmd wifi status 2>/dev/null \
    | tr -d '\r' \
    | sed -n 's/^Wifi is connected to "\(.*\)"$/\1/p' \
    | head -n 1
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
  local ssid="$1" timeout_secs="$2" deadline
  deadline=$((SECONDS + timeout_secs))
  while ((SECONDS < deadline)); do
    if android_underlay_network_is_validated "$ssid"; then
      return 0
    fi
    sleep 0.2
  done
  return 1
}

android_underlay_has_validated_physical_fallback() {
  local connectivity
  connectivity="$(
    "$ADB" -s "$serial" shell dumpsys connectivity 2>/dev/null \
      | tr -d '\r'
  )" || return 2
  python3 -c '
import re
import sys

text = sys.stdin.read()
lines = text.splitlines()
try:
    active = next(i for i, line in enumerate(lines) if line.startswith("Active default network:"))
    current = next(i for i, line in enumerate(lines) if line.startswith("Current Networks:"))
    status = next(i for i, line in enumerate(lines) if line.startswith("Status for known UIDs:"))
except StopIteration:
    raise SystemExit(2)
blocks = [line.strip() for line in lines[current + 1 : status] if "NetworkAgentInfo{" in line]
if not (active < current < status and blocks):
    raise SystemExit(2)
if any(not block.endswith("}") for block in blocks):
    raise SystemExit(2)
if not any("ni{VPN CONNECTED" in block for block in blocks):
    raise SystemExit(2)
for block in blocks:
    if "NOT_VPN" not in block or "VALIDATED" not in block:
        continue
    if re.search(r"(?<![0-9.])0\.0\.0\.0/0(?![0-9])|(?<!\S)::/0", block):
        raise SystemExit(0)
raise SystemExit(1)
' <<<"$connectivity"
}

android_underlay_wait_offline() {
  local ping_log="$1" deadline=$((SECONDS + 8)) observation_ms replies
  local inspection_status
  ANDROID_UNDERLAY_OUTAGE_MS=""
  while ((SECONDS < deadline)); do
    inspection_status=0
    android_underlay_has_validated_physical_fallback \
      || inspection_status=$?
    if (( inspection_status == 2 )); then
      echo "Android Wi-Fi-off fallback inspection failed" >&2
      return 1
    fi
    if (( inspection_status == 1 )); then
      ANDROID_UNDERLAY_NO_FALLBACK_INSPECTIONS=$((ANDROID_UNDERLAY_NO_FALLBACK_INSPECTIONS + 1))
      observation_ms="$(mobile_underlay_now_ms)"
      sleep 0.8
      replies="$(mobile_continuity_reply_count_after "$ping_log" "$observation_ms")"
      inspection_status=0
      android_underlay_has_validated_physical_fallback \
        || inspection_status=$?
      if (( inspection_status == 2 )); then
        echo "Android Wi-Fi-off fallback reinspection failed" >&2
        return 1
      fi
      if [[ "$replies" == "0" ]] && (( inspection_status == 1 )); then
        ANDROID_UNDERLAY_NO_FALLBACK_INSPECTIONS=$((ANDROID_UNDERLAY_NO_FALLBACK_INSPECTIONS + 1))
        ANDROID_UNDERLAY_OUTAGE_MS="$observation_ms"
        return 0
      fi
    fi
    sleep 0.1
  done
  echo "Android Wi-Fi-off phase never produced a real no-fallback payload outage" >&2
  return 1
}

android_underlay_recovery_payloads() {
  local underlay_validated_ms="$1" recovery_max_ms="$2"
  local result_dir result_path dns_path completion_ms recovery_ms
  local dns_servers fresh_dns_base fresh_dns_host
  result_dir="${NVPN_ANDROID_RESULT_DIR:-$ROOT/artifacts/mobile-android}"
  result_path="$result_dir/mobile-android-radio-bounce-udp-$$.log"
  dns_path="$result_dir/mobile-android-radio-bounce-dns-$$.log"
  ANDROID_UNDERLAY_PAYLOAD_COMPLETED_MS=""
  ANDROID_UNDERLAY_PAYLOAD_RECOVERY_MS=""
  ANDROID_UNDERLAY_FRESH_DNS_HOST=""
  dns_servers="$(android_vpn_dns_servers)" || {
    echo "Android post-radio-on VPN DNS policy was unavailable" >&2
    return 1
  }
  grep -Fxq "$EXPECTED_VPN_DNS" <<<"$dns_servers" || {
    echo "Android post-radio-on VPN DNS was not the production local stub" >&2
    return 1
  }
  fresh_dns_base="${EXIT_PROBE_HOST%.}"
  if ! {
    printf 'vpnDnsServers=%s\n' \
      "$(tr '\n' ',' <<<"$dns_servers" | sed 's/,$//')"
    "$ADB" -s "$serial" shell \
      env "CLASSPATH=$ANDROID_CAPTURED_PROBE_REMOTE_JAR" \
      app_process /system/bin MobileAndroidCapturedNetworkProbe \
      --fresh-dns "$fresh_dns_base" "$EXIT_PROBE_EXPECTED_IP" radio-on
  } >"$dns_path" 2>&1
  then
    echo "Android first post-radio-on VPN DNS payload failed: $dns_path" >&2
    return 1
  fi
  fresh_dns_host="$(
    sed -n 's/.* queryHost=\([^ ]*\) .*/\1/p' "$dns_path" | head -n 1
  )"
  if ! [[ "$fresh_dns_host" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\..+ ]] \
    || ! grep -Fq "expectedAddress=$EXIT_PROBE_EXPECTED_IP" "$dns_path" \
    || ! grep -Eq \
      "answers=([^ ]*,)?${EXIT_PROBE_EXPECTED_IP//./\\.}(,| )" \
      "$dns_path"
  then
    echo "Android post-radio-on DNS receipt was not fresh and exact" >&2
    return 1
  fi
  ANDROID_UNDERLAY_FRESH_DNS_HOST="$fresh_dns_host"

  if ! "$ADB" -s "$serial" shell \
      env "CLASSPATH=$ANDROID_CAPTURED_PROBE_REMOTE_JAR" \
      app_process /system/bin MobileAndroidCapturedNetworkProbe \
      --udp-echo \
      "$NVPN_ANDROID_UNDERLAY_UDP_ECHO_HOST" \
      "$NVPN_ANDROID_UNDERLAY_UDP_ECHO_PORT" \
      radio-on >"$result_path" 2>&1
  then
    echo "Android first post-radio-on WireGuard payload failed: $result_path" >&2
    return 1
  fi
  grep -Fq "udpEchoLabel=radio-on " "$result_path" || {
    echo "Android post-radio-on UDP echo did not return its exact payload" >&2
    return 1
  }
  completion_ms="$(mobile_underlay_now_ms)"
  recovery_ms=$((completion_ms - underlay_validated_ms))
  if (( recovery_ms < 0 || recovery_ms > recovery_max_ms )); then
    echo "Android DNS/WireGuard recovery was ${recovery_ms}ms (limit ${recovery_max_ms}ms)" >&2
    return 1
  fi
  ANDROID_UNDERLAY_PAYLOAD_COMPLETED_MS="$completion_ms"
  ANDROID_UNDERLAY_PAYLOAD_RECOVERY_MS="$recovery_ms"
}

android_vpn_service_log_count() {
  local needle="$1" logs window
  logs="$(
    "$ADB" -s "$serial" logcat -d -v brief \
      -s NostrVpnService:I '*:S' 2>/dev/null
  )" || return 1
  if [[ -n "$ANDROID_VPN_LOG_MARKER" ]]; then
    if ! window="$(awk -v marker="$ANDROID_VPN_LOG_MARKER" '
      index($0, marker) { found = 1; next }
      found { print }
      END { if (!found) exit 42 }
    ' <<<"$logs")"
    then
      echo "Android native-start log marker is no longer present; logcat continuity cannot be proven" >&2
      return 1
    fi
    logs="$window"
  fi
  grep -Fc "$needle" <<<"$logs" || true
}

android_vpn_native_start_count() {
  android_vpn_service_log_count "$ANDROID_VPN_NATIVE_START_LOG"
}

android_vpn_begin_log_window() {
  local marker deadline logs
  marker="NVPN_RELEASE_LOG_WINDOW_$(date +%s)_$$_$RANDOM"
  if ! "$ADB" -s "$serial" logcat -c >/dev/null 2>&1; then
    echo "Android could not clear stale logcat history before the native-start gate" >&2
    return 1
  fi
  if ! "$ADB" -s "$serial" shell log -p i -t NostrVpnService "$marker" \
      >/dev/null 2>&1
  then
    echo "Android could not emit the native-start log marker" >&2
    return 1
  fi
  deadline=$((SECONDS + 2))
  while ((SECONDS < deadline)); do
    logs="$(
      "$ADB" -s "$serial" logcat -d -v brief \
        -s NostrVpnService:I '*:S' 2>/dev/null
    )" || {
      echo "Android could not inspect the native-start log marker" >&2
      return 1
    }
    if grep -Fq "$marker" <<<"$logs"; then
      ANDROID_VPN_LOG_MARKER="$marker"
      return 0
    fi
    sleep 0.1
  done
  echo "Android native-start log marker was not observable within two seconds" >&2
  return 1
}

android_underlay_assert_native_tunnel_unchanged() {
  local label="$1" count
  truthy "${RELEASE_BLACKBOX_GATE:-0}" || return 0
  if ! declare -F android_release_assert_native_tunnel_unchanged >/dev/null; then
    echo "Android Release $label cannot audit native-tunnel continuity" >&2
    return 1
  fi
  android_release_assert_native_tunnel_unchanged "$label" || return 1
  count="$(android_vpn_native_start_count)" || return 1
  [[ "$count" =~ ^[0-9]+$ ]] || return 1
  ANDROID_UNDERLAY_NATIVE_CHECKPOINTS+=("$label=$count")
}

android_underlay_assert_process_and_vpn() {
  local expected_pid="$1" label="${2:-}" current_pid
  current_pid="$(android_app_pid)"
  if [[ "$current_pid" != "$expected_pid" ]]; then
    echo "Android app/VPN process changed during the Wi-Fi radio bounce" >&2
    return 1
  fi
  if ! vpn_active || ! assert_single_android_app_process; then
    echo "Android VPN did not remain active in one canonical process" >&2
    return 1
  fi
  if [[ -n "$label" ]]; then
    ANDROID_UNDERLAY_PROCESS_CHECKPOINTS+=("$label=$current_pid")
  fi
}

android_underlay_background_foreground() {
  local expected_pid="$1"
  "$ADB" -s "$serial" shell input keyevent KEYCODE_HOME
  sleep 2
  android_underlay_assert_process_and_vpn "$expected_pid" background || return 1
  start_main_activity
  if ! wait_until 5 android_activity_resumed; then
    echo "Android Activity did not foreground after the Wi-Fi radio bounce" >&2
    return 1
  fi
  android_underlay_assert_process_and_vpn "$expected_pid" foreground
}

android_underlay_append_proof() {
  local markers="$1" restored_ssid="$2" row fingerprints original_fp restored_fp
  truthy "${RELEASE_BLACKBOX_GATE:-0}" || return 0
  fingerprints="$(
    python3 -c \
      'import hashlib,secrets,sys;s=secrets.token_bytes(32);print(*(hashlib.sha256(s+x.encode()).hexdigest() for x in sys.argv[1:]))' \
      "$ANDROID_UNDERLAY_ORIGINAL_SSID" "$restored_ssid"
  )" || return 1
  read -r original_fp restored_fp <<<"$fingerprints"
  for row in "${ANDROID_UNDERLAY_PROCESS_CHECKPOINTS[@]}"; do
    printf 'proof_app_%s\t%s\n' "${row%%=*}" "${row#*=}" >>"$markers"
  done
  for row in "${ANDROID_UNDERLAY_NATIVE_CHECKPOINTS[@]}"; do
    printf 'proof_native_%s\t%s\n' "${row%%=*}" "${row#*=}" >>"$markers"
  done
  printf '%s\t%s\n' \
    proof_no_validated_physical_fallback_inspections \
    "$ANDROID_UNDERLAY_NO_FALLBACK_INSPECTIONS" \
    proof_original_wifi_fingerprint "$original_fp" \
    proof_restored_wifi_fingerprint "$restored_fp" \
    proof_fresh_dns_query "$ANDROID_UNDERLAY_FRESH_DNS_HOST" \
    proof_wireguard_payload_label radio-on >>"$markers"
}

android_underlay_restore_home() {
  [[ "$ANDROID_UNDERLAY_HOME_RESTORE_ARMED" -eq 1 ]] || return 0
  local timeout="${NVPN_MOBILE_UNDERLAY_ASSOCIATION_TIMEOUT_SECS:-30}"
  "$ADB" -s "$serial" shell svc wifi enable >/dev/null 2>&1 || return 1
  android_underlay_wait_wifi_radio enabled 5 || return 1
  "$ADB" -s "$serial" shell cmd wifi start-scan >/dev/null 2>&1 || true
  if android_underlay_wait_validated \
      "$ANDROID_UNDERLAY_ORIGINAL_SSID" "$timeout"
  then
    ANDROID_UNDERLAY_HOME_RESTORE_ARMED=0
    echo "Android cleanup restored the original validated Wi-Fi"
    return 0
  fi
  echo "Android cleanup could not restore the original validated Wi-Fi" >&2
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
    echo "Android radio-on recovery budget cannot exceed 4000ms" >&2
    return 1
  fi

  ANDROID_UNDERLAY_ORIGINAL_SSID="$(android_underlay_original_ssid)"
  [[ -n "$ANDROID_UNDERLAY_ORIGINAL_SSID" ]] \
    && android_underlay_network_is_validated "$ANDROID_UNDERLAY_ORIGINAL_SSID" \
    || {
      echo "Android radio-bounce gate requires an active validated Wi-Fi" >&2
      return 1
    }

  local artifact_dir="${NVPN_ANDROID_RESULT_DIR:-$ROOT/artifacts/mobile-android}"
  local stem="mobile-android-underlay-$$"
  local ping_log="$artifact_dir/$stem-continuity.log"
  local markers="$artifact_dir/$stem-markers.tsv"
  local summary="$artifact_dir/$stem-summary.json"
  local expected_pid requested_ms recovery_requested_ms underlay_validated_ms
  local recovery_ms restored_ssid
  mkdir -p "$artifact_dir"
  : >"$markers"
  ANDROID_UNDERLAY_NO_FALLBACK_INSPECTIONS=0
  ANDROID_UNDERLAY_PROCESS_CHECKPOINTS=()
  ANDROID_UNDERLAY_NATIVE_CHECKPOINTS=()
  expected_pid="$(android_app_pid)"
  android_underlay_assert_process_and_vpn \
    "$expected_pid" radio-bounce-start || return 1
  android_underlay_assert_native_tunnel_unchanged radio-bounce-start || return 1
  android_build_captured_network_probe || return 1
  mobile_continuity_start \
    "$NVPN_MOBILE_UNDERLAY_CONTINUITY_CONTAINER" \
    "$NVPN_MOBILE_UNDERLAY_CONTINUITY_CLIENT_IP" \
    "$ping_log" \
    || return 1
  mobile_continuity_wait_for_reply_count_after \
    "$ping_log" "$(mobile_underlay_now_ms)" 2 2000 || {
      mobile_continuity_stop
      return 1
    }
  ANDROID_UNDERLAY_HOME_RESTORE_ARMED=1

  requested_ms="$(mobile_underlay_now_ms)"
  printf 'switch_1_requested\t%s\n' "$requested_ms" >>"$markers"
  "$ADB" -s "$serial" shell svc wifi disable >/dev/null
  android_underlay_wait_wifi_radio disabled 5 || {
    echo "Android Wi-Fi radio did not turn off" >&2
    mobile_continuity_stop
    return 1
  }
  android_underlay_wait_offline "$ping_log" || {
    mobile_continuity_stop
    return 1
  }
  printf 'switch_1_outage\t%s\n' "$ANDROID_UNDERLAY_OUTAGE_MS" >>"$markers"
  android_underlay_assert_process_and_vpn "$expected_pid" radio-off \
    && android_underlay_assert_native_tunnel_unchanged radio-off \
    || {
      mobile_continuity_stop
      return 1
    }

  recovery_requested_ms="$(mobile_underlay_now_ms)"
  printf 'switch_1_recovery_requested\t%s\n' \
    "$recovery_requested_ms" >>"$markers"
  "$ADB" -s "$serial" shell svc wifi enable >/dev/null
  android_underlay_wait_wifi_radio enabled 5 || {
    echo "Android Wi-Fi radio did not turn on" >&2
    mobile_continuity_stop
    return 1
  }
  "$ADB" -s "$serial" shell cmd wifi start-scan >/dev/null 2>&1 || true
  android_underlay_wait_validated \
    "$ANDROID_UNDERLAY_ORIGINAL_SSID" "$association_timeout" \
    || {
      echo "Android original Wi-Fi did not return validated" >&2
      mobile_continuity_stop
      return 1
    }
  underlay_validated_ms="$(mobile_underlay_now_ms)"
  printf 'switch_1_underlay_validated\t%s\n' \
    "$underlay_validated_ms" >>"$markers"
  android_underlay_recovery_payloads \
    "$underlay_validated_ms" "$recovery_max_ms" || {
    mobile_continuity_stop
    return 1
  }
  recovery_ms="$ANDROID_UNDERLAY_PAYLOAD_RECOVERY_MS"
  printf 'switch_%s_payload_recovery\t%s\n' 1 "$recovery_ms" >>"$markers"
  mobile_continuity_wait_for_reply_count_after \
    "$ping_log" "$ANDROID_UNDERLAY_PAYLOAD_COMPLETED_MS" 2 2000 \
    && android_underlay_assert_process_and_vpn "$expected_pid" radio-on \
    && android_underlay_assert_native_tunnel_unchanged radio-on \
    || {
      mobile_continuity_stop
      return 1
    }
  android_underlay_background_foreground "$expected_pid" || {
    mobile_continuity_stop
    return 1
  }
  if truthy "${RELEASE_BLACKBOX_GATE:-0}"; then
    run_android_release_exit_network_probe wireguard-exit-after-radio-on || {
      mobile_continuity_stop
      return 1
    }
  else
    run_android_tun_packet_probe \
      && run_android_exit_network_probe wireguard-exit-after-radio-on || {
        mobile_continuity_stop
        return 1
      }
  fi
  printf 'switch_1_verified\t%s\n' "$(mobile_underlay_now_ms)" >>"$markers"
  restored_ssid="$(android_underlay_original_ssid)"
  [[ "$restored_ssid" == "$ANDROID_UNDERLAY_ORIGINAL_SSID" ]] || {
    echo "Android radio bounce did not restore the original Wi-Fi" >&2
    mobile_continuity_stop
    return 1
  }
  android_underlay_append_proof "$markers" "$restored_ssid" || {
    mobile_continuity_stop
    return 1
  }

  ANDROID_UNDERLAY_HOME_RESTORE_ARMED=0
  mobile_continuity_stop
  mobile_continuity_validate \
    "$ROOT" "$ping_log" "$markers" "$summary" Android "$recovery_max_ms" \
    || return 1
  android_underlay_assert_process_and_vpn "$expected_pid" || return 1
  echo "Android real Wi-Fi radio off/on gate passed without restarting the app/VPN"
}
