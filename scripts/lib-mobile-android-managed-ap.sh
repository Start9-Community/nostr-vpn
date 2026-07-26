#!/usr/bin/env bash

MOBILE_ANDROID_MANAGED_AP_STARTED=0
MOBILE_ANDROID_MANAGED_AP_RADIO_BEFORE=""
MOBILE_ANDROID_MANAGED_AP_CONNECTION=""
MOBILE_ANDROID_MANAGED_AP_SSID=""
MOBILE_ANDROID_MANAGED_AP_PASSPHRASE=""
MOBILE_ANDROID_MANAGED_AP_CONTROL_PATH="/tmp/nvpn-managed-ap-$PPID-$$"

mobile_android_managed_ap_validate_name() {
  local label="$1" value="$2"
  if [[ -z "$value" || "$value" == -* || "$value" =~ [[:space:]] ]]; then
    echo "Android managed AP $label is invalid" >&2
    return 1
  fi
}

mobile_android_managed_ap_remote() {
  local host="${NVPN_ANDROID_UNDERLAY_MANAGED_AP_SSH_HOST:-}"
  local command="" argument quoted
  mobile_android_managed_ap_validate_name "SSH host" "$host" || return 1
  for argument in "$@"; do
    printf -v quoted '%q' "$argument"
    command+="$quoted "
  done
  ssh \
    -o BatchMode=yes \
    -o ConnectTimeout=10 \
    -o ConnectionAttempts=1 \
    -o ServerAliveInterval=3 \
    -o ServerAliveCountMax=2 \
    -o ControlMaster=auto \
    -o ControlPersist=60 \
    -o "ControlPath=$MOBILE_ANDROID_MANAGED_AP_CONTROL_PATH" \
    "$host" "$command"
}

mobile_android_managed_ap_close_control() {
  local host="${NVPN_ANDROID_UNDERLAY_MANAGED_AP_SSH_HOST:-}"
  [[ -n "$host" ]] || return 0
  ssh \
    -o "ControlPath=$MOBILE_ANDROID_MANAGED_AP_CONTROL_PATH" \
    -O exit "$host" >/dev/null 2>&1 || true
}

mobile_android_managed_ap_nmcli() {
  mobile_android_managed_ap_remote sudo -n nmcli "$@"
}

mobile_android_managed_ap_random_hex() {
  local bytes="$1"
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex "$bytes"
  else
    python3 - "$bytes" <<'PY'
import secrets
import sys
print(secrets.token_hex(int(sys.argv[1])))
PY
  fi
}

mobile_android_managed_ap_start() {
  local interface="${NVPN_ANDROID_UNDERLAY_MANAGED_AP_INTERFACE:-}"
  [[ -n "${NVPN_ANDROID_UNDERLAY_MANAGED_AP_SSH_HOST:-}" ]] || return 0
  mobile_android_managed_ap_validate_name "interface" "$interface" || return 1
  command -v ssh >/dev/null 2>&1 || {
    echo "Android managed AP requires ssh" >&2
    return 1
  }
  if ! mobile_android_managed_ap_remote sudo -n nmcli -t radio wifi \
      >/dev/null
  then
    echo "Android managed AP host requires passwordless sudo for nmcli" >&2
    return 1
  fi
  if ! mobile_android_managed_ap_remote \
      test -d "/sys/class/net/$interface"
  then
    echo "Android managed AP interface does not exist" >&2
    return 1
  fi
  if ! mobile_android_managed_ap_remote \
      sudo -n sh -c \
      'iw list | grep -Eq "^[[:space:]]*\\* AP([[:space:]]|$)"'
  then
    echo "Android managed AP interface/driver does not advertise AP mode" >&2
    return 1
  fi
  local active
  active="$(
    mobile_android_managed_ap_nmcli \
      -g GENERAL.CONNECTION device show "$interface" \
      | tr -d '\r'
  )"
  if [[ -n "$active" && "$active" != "--" ]]; then
    echo "Android managed AP refuses to replace an active interface connection" >&2
    return 1
  fi
  mobile_android_managed_ap_remote \
    curl -fsS --max-time 8 https://example.com/ >/dev/null \
    || {
      echo "Android managed AP host has no working public uplink" >&2
      return 1
    }
  MOBILE_ANDROID_MANAGED_AP_RADIO_BEFORE="$(
    mobile_android_managed_ap_nmcli -t radio wifi | tr -d '\r'
  )"
  case "$MOBILE_ANDROID_MANAGED_AP_RADIO_BEFORE" in
    enabled|disabled) ;;
    *)
      echo "Android managed AP could not record the original Wi-Fi radio state" >&2
      return 1
      ;;
  esac
  MOBILE_ANDROID_MANAGED_AP_CONNECTION="nvpn-gate-$(mobile_android_managed_ap_random_hex 6)"
  MOBILE_ANDROID_MANAGED_AP_SSID="${NVPN_ANDROID_UNDERLAY_MANAGED_AP_SSID:-$MOBILE_ANDROID_MANAGED_AP_CONNECTION}"
  MOBILE_ANDROID_MANAGED_AP_PASSPHRASE="$(
    if [[ -n "${NVPN_ANDROID_UNDERLAY_MANAGED_AP_PASSPHRASE:-}" ]]; then
      printf '%s\n' "$NVPN_ANDROID_UNDERLAY_MANAGED_AP_PASSPHRASE"
    else
      mobile_android_managed_ap_random_hex 12
    fi
  )"
  if (( ${#MOBILE_ANDROID_MANAGED_AP_SSID} > 32 )) \
    || (( ${#MOBILE_ANDROID_MANAGED_AP_PASSPHRASE} < 8 ))
  then
    echo "Android managed AP ephemeral SSID/passphrase lengths are invalid" >&2
    return 1
  fi

  MOBILE_ANDROID_MANAGED_AP_STARTED=1
  mobile_android_managed_ap_nmcli radio wifi on || return 1
  mobile_android_managed_ap_nmcli device disconnect "$interface" \
    >/dev/null 2>&1 || true
  mobile_android_managed_ap_nmcli \
    connection add \
    type wifi \
    ifname "$interface" \
    con-name "$MOBILE_ANDROID_MANAGED_AP_CONNECTION" \
    autoconnect no \
    ssid "$MOBILE_ANDROID_MANAGED_AP_SSID" >/dev/null \
    || return 1
  mobile_android_managed_ap_nmcli \
    connection modify "$MOBILE_ANDROID_MANAGED_AP_CONNECTION" \
    802-11-wireless.mode ap \
    wifi-sec.key-mgmt wpa-psk \
    wifi-sec.psk "$MOBILE_ANDROID_MANAGED_AP_PASSPHRASE" \
    ipv4.method shared \
    ipv6.method disabled \
    || return 1
  mobile_android_managed_ap_nmcli \
    connection up "$MOBILE_ANDROID_MANAGED_AP_CONNECTION" >/dev/null \
    || return 1
  if [[ "$(
      mobile_android_managed_ap_nmcli \
        -g GENERAL.CONNECTION device show "$interface" \
        | tr -d '\r'
    )" != "$MOBILE_ANDROID_MANAGED_AP_CONNECTION" ]]
  then
    echo "Android managed AP did not own its requested interface" >&2
    return 1
  fi
  mobile_android_managed_ap_remote \
    curl -fsS --max-time 8 https://example.com/ >/dev/null \
    || {
      echo "Android managed AP host lost its public uplink" >&2
      return 1
    }
  export NVPN_ANDROID_UNDERLAY_ALTERNATE_SSID="$MOBILE_ANDROID_MANAGED_AP_SSID"
  export NVPN_ANDROID_UNDERLAY_ALTERNATE_SECURITY=wpa2
  export NVPN_ANDROID_UNDERLAY_ALTERNATE_PASSPHRASE="$MOBILE_ANDROID_MANAGED_AP_PASSPHRASE"
  export NVPN_ANDROID_UNDERLAY_HOME_RECONNECT=saved
  export NVPN_ANDROID_UNDERLAY_MANAGED_AP_CONNECTION="$MOBILE_ANDROID_MANAGED_AP_CONNECTION"
  echo "Android temporary managed AP is active with an env-only ephemeral credential"
}

mobile_android_managed_ap_cleanup() {
  if [[ "$MOBILE_ANDROID_MANAGED_AP_STARTED" -ne 1 ]]; then
    mobile_android_managed_ap_close_control
    return 0
  fi
  local cleanup_failed=0
  mobile_android_managed_ap_nmcli \
    connection down "$MOBILE_ANDROID_MANAGED_AP_CONNECTION" \
    >/dev/null 2>&1 || true
  mobile_android_managed_ap_nmcli \
    connection delete "$MOBILE_ANDROID_MANAGED_AP_CONNECTION" \
    >/dev/null 2>&1 || true
  if mobile_android_managed_ap_nmcli \
      -g NAME connection show \
      | grep -Fxq "$MOBILE_ANDROID_MANAGED_AP_CONNECTION"
  then
    echo "Android managed AP cleanup did not delete its exact connection" >&2
    cleanup_failed=1
  fi
  if [[ "$MOBILE_ANDROID_MANAGED_AP_RADIO_BEFORE" == "disabled" ]]; then
    mobile_android_managed_ap_nmcli radio wifi off \
      >/dev/null 2>&1 || cleanup_failed=1
  fi
  MOBILE_ANDROID_MANAGED_AP_STARTED=0
  mobile_android_managed_ap_close_control
  if [[ "$cleanup_failed" -ne 0 ]]; then
    return 1
  fi
  echo "Android temporary managed AP cleanup restored its prior radio state"
}
