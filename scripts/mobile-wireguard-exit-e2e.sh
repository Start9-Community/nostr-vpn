#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/release_common.sh"
# shellcheck disable=SC1091
source "$ROOT/scripts/mobile_env.sh"
load_release_env "$ROOT"
load_appstoreconnect_defaults
load_mobile_env "$ROOT"
IMAGE="${NVPN_MOBILE_WG_EXIT_IMAGE:-nostr-vpn-mobile-wireguard-exit-e2e}"
CONTAINER="${NVPN_MOBILE_WG_EXIT_CONTAINER:-nostr-vpn-mobile-wireguard-exit-e2e}"
HOST_PORT="${NVPN_MOBILE_WG_EXIT_HOST_PORT:-51886}"
TUNNEL_SERVER_IP="${NVPN_MOBILE_WG_EXIT_SERVER_IP:-10.99.77.1}"
TUNNEL_CLIENT_IP="${NVPN_MOBILE_WG_EXIT_CLIENT_IP:-10.99.77.2}"
DNS_NAME="${NVPN_MOBILE_WG_EXIT_DNS_NAME:-wireguard-exit.nvpn-e2e.test}"
DIRECT_HOST="${NVPN_MOBILE_WG_EXIT_DIRECT_HOST:-example.com}"
DIRECT_URL="${NVPN_MOBILE_WG_EXIT_DIRECT_URL:-https://example.com/}"
PLATFORMS="${NVPN_MOBILE_WG_EXIT_PLATFORMS:-android,ios}"
INSTALL_IOS="${NVPN_MOBILE_WG_EXIT_INSTALL_IOS:-1}"
INSTALL_ANDROID="${NVPN_MOBILE_WG_EXIT_INSTALL_ANDROID:-1}"
LIFECYCLE_GATE="${NVPN_MOBILE_WG_EXIT_LIFECYCLE_GATE:-1}"
IOS_BUNDLE_ID="${NVPN_IOS_BUNDLE_ID:-${NVPN_DEFAULT_IOS_BUNDLE_ID:-fi.siriusbusiness.nvpn}}"
IOS_UI_RESULT_DIR="${NVPN_MOBILE_WG_EXIT_IOS_UI_RESULT_DIR:-$ROOT/artifacts/mobile-ios}"
IOS_UI_DERIVED_DATA="${NVPN_IOS_DEVICE_DERIVED_DATA:-$ROOT/ios/.build/DeviceDerivedData}"
IOS_UI_SIGNING_MODE="${NVPN_IOS_DEVICE_SIGNING_MODE:-adhoc}"
FIXTURE_DIR=""
ANDROID_DEVICE_SERIAL=""
IOS_DEVICE_SELECTED=""
IOS_CLEANUP_ARMED=0

usage() {
  cat >&2 <<'EOF'
usage: scripts/mobile-wireguard-exit-e2e.sh [android|ios|all]

Runs a real WireGuard exit and DNS resolver in Docker, then proves on selected
physical mobile devices that:
  - native device DNS and Internet work before the VPN starts;
  - default traffic crosses the WireGuard exit;
  - Automatic/profile, Cloudflare DoH, Quad9 DoH, custom DoH with explicit
    bootstrap IPs, and DNS-through-exit all use the selected real resolver;
  - public HTTPS works through the exit;
  - each app survives three ten-second active-tunnel background/foreground
    cycles, with tunnel traffic, DNS policy, and HTTPS re-proved after each;
  - selecting Direct disables WireGuard while the OS VPN remains connected;
  - DNS and ordinary Internet work in that connected split-tunnel state; and
  - native device DNS and Internet still work after disconnect.

The host and devices must share a LAN. Override the endpoint address with
NVPN_MOBILE_WG_EXIT_HOST_IP when automatic en0 discovery is unsuitable.
Set NVPN_MOBILE_WG_EXIT_INSTALL_ANDROID=0 to exercise an already-installed
canonical company-signed debug build without replacing it.
NVPN_MOBILE_WG_EXIT_DNS_CASES accepts a comma-separated subset for a focused
failure retry; the release gate leaves it unset and always runs all five.
EOF
}

case "${1:-all}" in
  all) PLATFORMS="android,ios" ;;
  android|ios) PLATFORMS="$1" ;;
  -h|--help|help) usage; exit 0 ;;
  *) usage; exit 2 ;;
esac

has_platform() {
  local requested="$1"
  [[ ",${PLATFORMS// /}," == *",$requested,"* ]]
}

cleanup() {
  local status="$?"
  local cleanup_failed=0
  trap - EXIT INT TERM
  if [[ "$IOS_CLEANUP_ARMED" == "1" && -n "$IOS_DEVICE_SELECTED" ]]; then
    if ! env \
      NVPN_IOS_DEVICE="$IOS_DEVICE_SELECTED" \
      NVPN_IOS_IDLE_CPU_GATE=0 \
      NVPN_IOS_LIFECYCLE_GATE=0 \
      "$ROOT/scripts/mobile-ios-smoke.sh" device --disconnect
    then
      echo "iOS WireGuard exit gate cleanup could not confirm tunnel disconnect" >&2
      cleanup_failed=1
    fi
  fi
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  if [[ -n "$FIXTURE_DIR" ]]; then
    rm -rf "$FIXTURE_DIR"
  fi
  if [[ "$status" -eq 0 && "$cleanup_failed" -ne 0 ]]; then
    status=1
  fi
  exit "$status"
}
trap cleanup EXIT INT TERM

for command in docker wg; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "mobile WireGuard exit e2e requires $command" >&2
    exit 1
  fi
done

if has_platform android; then
  if ! command -v adb >/dev/null 2>&1; then
    echo "mobile WireGuard exit e2e requires adb for the physical Android device" >&2
    exit 1
  fi
  ANDROID_DEVICE_SERIAL="$(select_physical_android_serial \
    "$(command -v adb)" \
    "${NVPN_ANDROID_SERIAL:-${ANDROID_SERIAL:-}}")"
fi

assert_single_android_app() {
  local installed unexpected
  installed="$(adb -s "$ANDROID_DEVICE_SERIAL" shell pm list packages \
    | tr -d '\r' \
    | sed -n 's/^package://p')"
  unexpected="$(printf '%s\n' "$installed" \
    | awk '$0 == "org.nostrvpn.app" || ($0 ~ /^fi\.siriusbusiness\.nvpn(\.|$)/ && $0 != "fi.siriusbusiness.nvpn")')"
  if [[ -n "$unexpected" ]]; then
    echo "Android WireGuard gate requires exactly the canonical nVPN app; remove stale test variants first." >&2
    return 1
  fi
  if ! printf '%s\n' "$installed" | grep -Fxq 'fi.siriusbusiness.nvpn'; then
    echo "Android WireGuard gate requires the canonical fi.siriusbusiness.nvpn app." >&2
    return 1
  fi
}

run_ios_exit_dns_shipped_ui_case_gate() {
  local label="$1" first="$2" mode="$3" provider="$4"
  local custom_url="$5" bootstrap_ips="$6" through_servers="$7"
  local device team configuration signing_env run_id log marker spec_base64
  local destination_udid
  local -a command=()
  local -a signing_args=()
  device="${IOS_DEVICE_SELECTED:-}"
  if [[ -z "$device" ]]; then
    device="$(select_physical_ios_device)" || {
      echo "iOS shipped Exit DNS UI gate requires exactly one physical iPhone/iPad" >&2
      return 1
    }
  fi
  team="${NVPN_IOS_TEAM_ID:-}"
  [[ -n "$team" ]] || {
    echo "NVPN_IOS_TEAM_ID is required for the physical iOS DNS UI gate" >&2
    return 1
  }
  destination_udid="$(resolve_physical_ios_udid "$device")"

  case "$IOS_UI_SIGNING_MODE" in
    adhoc)
      signing_env="$ROOT/ios/.build/DeviceSigning/provisioning.env"
      [[ -f "$signing_env" ]] || {
        echo "iOS Ad Hoc signing metadata is missing after the physical install" >&2
        return 1
      }
      # shellcheck disable=SC1090
      source "$signing_env"
      : "${NVPN_IOS_CODE_SIGN_IDENTITY:?iOS DNS UI signing identity is missing}"
      : "${NVPN_IOS_PROVISIONING_PROFILE_UUID:?iOS DNS UI app profile is missing}"
      : "${NVPN_IOS_PACKET_TUNNEL_PROVISIONING_PROFILE_UUID:?iOS DNS UI tunnel profile is missing}"
      configuration="${NVPN_IOS_UI_TEST_CONFIGURATION:-DeviceDebug}"
      signing_args=(
        NVPN_IOS_CODE_SIGN_IDENTITY="$NVPN_IOS_CODE_SIGN_IDENTITY"
        NVPN_IOS_PROVISIONING_PROFILE_UUID="$NVPN_IOS_PROVISIONING_PROFILE_UUID"
        NVPN_IOS_PACKET_TUNNEL_PROVISIONING_PROFILE_UUID="$NVPN_IOS_PACKET_TUNNEL_PROVISIONING_PROFILE_UUID"
      )
      ;;
    development)
      configuration="${NVPN_IOS_UI_TEST_CONFIGURATION:-Debug}"
      signing_args=(CODE_SIGN_IDENTITY="${NVPN_IOS_DEVICE_CODE_SIGN_IDENTITY:-Apple Development}")
      ;;
    *)
      echo "NVPN_IOS_DEVICE_SIGNING_MODE must be adhoc or development" >&2
      return 1
      ;;
  esac

  mkdir -p "$IOS_UI_RESULT_DIR"
  spec_base64="$(python3 - \
    "$label" "$mode" "$provider" "$custom_url" "$bootstrap_ips" \
    "$through_servers" "$first" <<'PY'
import base64
import json
import sys

label, mode, provider, custom_url, bootstrap_ips, through_servers, first = sys.argv[1:]
payload = json.dumps(
    {
        "caseName": label,
        "mode": mode,
        "provider": provider,
        "customUrl": custom_url,
        "bootstrapIps": bootstrap_ips,
        "throughExitServers": through_servers,
        "createNetwork": first == "1",
    },
    separators=(",", ":"),
).encode()
print(base64.b64encode(payload).decode())
PY
  )"
  run_id="exit-dns-ui-$label-$$-$RANDOM-$(date +%s)"
  log="$IOS_UI_RESULT_DIR/mobile-ios-exit-dns-ui-$label-$$.log"
  marker="$IOS_UI_RESULT_DIR/mobile-ios-exit-dns-ui-markers-$label-$$.log"
  command=(
    xcodebuild
    -quiet
    -allowProvisioningUpdates
    -project "$ROOT/ios/NostrVpnIos.xcodeproj"
    -scheme NostrVpnIos
    -configuration "$configuration"
    -derivedDataPath "$IOS_UI_DERIVED_DATA"
    -destination "platform=iOS,id=$destination_udid"
    -destination-timeout 60
    -collect-test-diagnostics never
    -only-testing:NostrVpnIosUITests/NostrVpnIosUITests/testConfigureExitDnsForPhysicalPacketProbe
    DEVELOPMENT_TEAM="$team"
    "${signing_args[@]}"
  )
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
    NVPN_XCUITEST_EXIT_DNS_SPEC_BASE64="$spec_base64"
    test
  )
  if ! NSUnbufferedIO=YES "${command[@]}" >"$log" 2>&1; then
    tail -n 120 "$log" >&2
    echo "Enable Settings > Developer > Enable UI Automation on the unlocked iPhone, then retry." >&2
    return 1
  fi
  rm -f "$marker"
  xcrun devicectl device copy from \
    --device "$device" \
    --domain-type appDataContainer \
    --domain-identifier "$IOS_BUNDLE_ID.UITests.xctrunner" \
    --source "Documents/nvpn-ui-gate-markers.log" \
    --destination "$marker" \
    --quiet >/dev/null
  grep -Fxq "NVPN_XCUITEST_RUN_ID=$run_id" "$marker" \
    && grep -Fxq "NVPN_EXIT_DNS_UI_CONFIG_PERSISTED=$label" "$marker" \
    || {
      echo "iOS physical Exit DNS XCTest did not emit its exact $label receipt" >&2
      return 1
    }
  echo "iOS shipped Exit DNS config persisted for $label: $log"
}

HOST_IP="${NVPN_MOBILE_WG_EXIT_HOST_IP:-}"
if [[ -z "$HOST_IP" && "$(uname -s)" == "Darwin" ]]; then
  HOST_IP="$(ipconfig getifaddr en0 2>/dev/null || true)"
fi
if [[ -z "$HOST_IP" && "$(uname -s)" == "Linux" ]]; then
  HOST_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit } }')"
fi
if [[ -z "$HOST_IP" ]]; then
  echo "Could not resolve a LAN host address; set NVPN_MOBILE_WG_EXIT_HOST_IP" >&2
  exit 1
fi

FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nvpn-mobile-wg-exit.XXXXXX")"
chmod 700 "$FIXTURE_DIR"
umask 077
wg genkey >"$FIXTURE_DIR/server.key"
wg pubkey <"$FIXTURE_DIR/server.key" >"$FIXTURE_DIR/server.pub"
wg genkey >"$FIXTURE_DIR/client.key"
wg pubkey <"$FIXTURE_DIR/client.key" >"$FIXTURE_DIR/client.pub"

cat >"$FIXTURE_DIR/client.conf" <<EOF
[Interface]
PrivateKey = $(<"$FIXTURE_DIR/client.key")
Address = $TUNNEL_CLIENT_IP/32
DNS = $TUNNEL_SERVER_IP
MTU = 1280

[Peer]
PublicKey = $(<"$FIXTURE_DIR/server.pub")
Endpoint = $HOST_IP:$HOST_PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 2
EOF

if ! bool_is_true "${NVPN_MOBILE_WG_EXIT_IMAGE_READY:-0}"; then
  docker build -q -f "$ROOT/Dockerfile.mobile-wireguard-exit-e2e" -t "$IMAGE" "$ROOT" >/dev/null
fi
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
docker run -d \
  --name "$CONTAINER" \
  --cap-add NET_ADMIN \
  --device /dev/net/tun \
  --sysctl net.ipv4.ip_forward=1 \
  -p "$HOST_PORT:51820/udp" \
  -v "$FIXTURE_DIR:/fixture" \
  -e "NVPN_MOBILE_WG_TUNNEL_CIDR=$TUNNEL_SERVER_IP/24" \
  -e "NVPN_MOBILE_WG_CLIENT_IP=$TUNNEL_CLIENT_IP" \
  -e "NVPN_MOBILE_WG_DNS_NAME=$DNS_NAME" \
  "$IMAGE" >/dev/null

for _ in $(seq 1 100); do
  [[ -f "$FIXTURE_DIR/ready" ]] && break
  if [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || true)" != "true" ]]; then
    docker logs "$CONTAINER" >&2 || true
    echo "mobile WireGuard exit fixture stopped before becoming ready" >&2
    exit 1
  fi
  sleep 0.1
done
if [[ ! -f "$FIXTURE_DIR/ready" ]]; then
  docker logs "$CONTAINER" >&2 || true
  echo "mobile WireGuard exit fixture did not become ready" >&2
  exit 1
fi

wg_bytes() {
  docker exec "$CONTAINER" wg show wg0 transfer \
    | awk '{ rx += $2; tx += $3 } END { printf "%d\t%d\n", rx, tx }'
}

forward_packets() {
  docker exec "$CONTAINER" iptables -L nvpn-mobile-wg-forward -v -n -x \
    | awk '$3 == "ACCEPT" && ($7 == "wg0" || $8 == "wg0") { packets += $1 } END { print packets + 0 }'
}

dns_query_count() {
  local name="$1"
  if [[ ! -f "$FIXTURE_DIR/dns.log" ]]; then
    echo 0
    return
  fi
  grep -Fci "$name" "$FIXTURE_DIR/dns.log" || true
}

doh_flow_count() {
  local provider="$1"
  local chain
  case "$provider" in
    cloudflare) chain="nvpn-wg-doh-cf" ;;
    quad9) chain="nvpn-wg-doh-q9" ;;
    *)
      echo "unknown DoH counter provider: $provider" >&2
      return 2
      ;;
  esac
  docker exec "$CONTAINER" iptables -L "$chain" -v -n -x \
    | awk '$3 == "ACCEPT" { packets += $1 } END { print packets + 0 }'
}

assert_platform_traffic() {
  local platform="$1" label="$2" before_bytes="$3" before_forward="$4"
  local after_bytes after_forward before_rx before_tx after_rx after_tx
  after_bytes="$(wg_bytes)"
  after_forward="$(forward_packets)"
  IFS=$'\t' read -r before_rx before_tx <<<"$before_bytes"
  IFS=$'\t' read -r after_rx after_tx <<<"$after_bytes"
  if (( after_rx <= before_rx || after_tx <= before_tx )); then
    echo "$platform $label failed: WireGuard transfer counters did not increase (rx $before_rx->$after_rx, tx $before_tx->$after_tx)" >&2
    exit 1
  fi
  if (( after_forward <= before_forward )); then
    echo "$platform $label failed: no forwarded Internet traffic crossed wg0 ($before_forward->$after_forward packets)" >&2
    exit 1
  fi
  echo "$platform $label packet path passed: transfer rx=$before_rx->$after_rx tx=$before_tx->$after_tx forwarded=$before_forward->$after_forward"
}

assert_fixture_dns_traffic() {
  local platform="$1" label="$2" name="$3" before_dns="$4"
  local after_dns
  after_dns="$(dns_query_count "$name")"
  if (( after_dns <= before_dns )); then
    echo "$platform $label failed: fixture DNS did not receive a $name query ($before_dns->$after_dns)" >&2
    exit 1
  fi
  echo "$platform $label resolver passed: fixture DNS queries=$before_dns->$after_dns"
}

assert_doh_traffic() {
  local platform="$1" label="$2" provider="$3" before_doh="$4"
  local after_doh
  after_doh="$(doh_flow_count "$provider")"
  if (( after_doh <= before_doh )); then
    echo "$platform $label failed: no HTTPS flow reached the selected $provider DoH bootstrap address ($before_doh->$after_doh packets)" >&2
    exit 1
  fi
  echo "$platform $label resolver passed: $provider DoH packets=$before_doh->$after_doh"
}

dns_case_fields() {
  local label="$1"
  case "$label" in
    automatic-profile)
      printf 'automatic|cloudflare||||%s|dns\n' "$DNS_NAME"
      ;;
    cloudflare-doh)
      printf 'encrypted|cloudflare||||cloudflare.com|doh-cloudflare\n'
      ;;
    quad9-doh)
      printf 'encrypted|quad9||||quad9.net|doh-quad9\n'
      ;;
    custom-doh)
      printf 'encrypted|custom|https://cloudflare-dns.com/dns-query|1.1.1.1||iana.org|doh-cloudflare\n'
      ;;
    through-exit)
      printf 'through_exit|cloudflare|||%s|through-exit.%s|dns\n' \
        "$TUNNEL_SERVER_IP" "$DNS_NAME"
      ;;
    *)
      echo "unknown mobile exit DNS case: $label" >&2
      return 1
      ;;
  esac
}

run_android_case() {
  local label="$1" first="$2" final="$3"
  local mode provider custom_url bootstrap_ips through_servers probe_host evidence
  local before_bytes before_forward before_evidence expected_ip
  local wireguard_config_file idle_gate lifecycle_gate
  IFS='|' read -r \
    mode provider custom_url bootstrap_ips through_servers probe_host evidence \
    <<<"$(dns_case_fields "$label")"
  before_bytes="$(wg_bytes)"
  before_forward="$(forward_packets)"
  case "$evidence" in
    dns)
      before_evidence="$(dns_query_count "$probe_host")"
      expected_ip="$TUNNEL_SERVER_IP"
      ;;
    doh-cloudflare)
      before_evidence="$(doh_flow_count cloudflare)"
      expected_ip=""
      ;;
    doh-quad9)
      before_evidence="$(doh_flow_count quad9)"
      expected_ip=""
      ;;
  esac
  local -a android_args=(
    --accept-vpn-dialog
    --vpn-cycle
    --probe-target "$TUNNEL_SERVER_IP"
    --probe-count 4
    --probe-require-reply
  )
  if [[ "$first" == "1" ]]; then
    android_args=(--create-network "${android_args[@]}")
    wireguard_config_file="$FIXTURE_DIR/client.conf"
    idle_gate="${NVPN_IDLE_CPU_GATE:-1}"
    lifecycle_gate="$LIFECYCLE_GATE"
    case "$INSTALL_ANDROID" in
      0|false|FALSE|False|no|NO|No|off|OFF|Off)
        android_args=(--no-build --no-install "${android_args[@]}")
        ;;
    esac
  else
    android_args=(--no-build --no-install "${android_args[@]}")
    wireguard_config_file=""
    idle_gate=false
    lifecycle_gate=false
  fi
  env \
    NVPN_ANDROID_SERIAL="$ANDROID_DEVICE_SERIAL" \
    NVPN_ANDROID_PACKAGE="${NVPN_ANDROID_PACKAGE:-fi.siriusbusiness.nvpn}" \
    NVPN_ANDROID_DEBUG_WIREGUARD_CONFIG_FILE="$wireguard_config_file" \
    NVPN_ANDROID_LIFECYCLE_GATE="$lifecycle_gate" \
    NVPN_ANDROID_IDLE_CPU_GATE="$idle_gate" \
    NVPN_ANDROID_EXIT_DNS_MODE="$mode" \
    NVPN_ANDROID_EXIT_DNS_DOH_PROVIDER="$provider" \
    NVPN_ANDROID_EXIT_DNS_CUSTOM_DOH_URL="$custom_url" \
    NVPN_ANDROID_EXIT_DNS_CUSTOM_DOH_BOOTSTRAP_IPS="$bootstrap_ips" \
    NVPN_ANDROID_EXIT_DNS_THROUGH_EXIT_SERVERS="$through_servers" \
    NVPN_ANDROID_EXIT_DNS_USE_SHIPPED_UI=1 \
    NVPN_ANDROID_SWITCH_TO_DIRECT_WHILE_CONNECTED="$final" \
    NVPN_ANDROID_EXIT_PROBE_HOST="$probe_host" \
    NVPN_ANDROID_EXIT_PROBE_EXPECTED_IP="$expected_ip" \
    NVPN_ANDROID_EXIT_PROBE_URL="$DIRECT_URL" \
    NVPN_ANDROID_DIRECT_PROBE_HOST="$DIRECT_HOST" \
    NVPN_ANDROID_DIRECT_PROBE_URL="$DIRECT_URL" \
    NVPN_ANDROID_EXPECT_WIREGUARD_ENDPOINT="$HOST_IP:$HOST_PORT" \
    "$ROOT/scripts/mobile-android-smoke.sh" "${android_args[@]}"
  assert_platform_traffic Android "$label" "$before_bytes" "$before_forward"
  case "$evidence" in
    dns) assert_fixture_dns_traffic Android "$label" "$probe_host" "$before_evidence" ;;
    doh-cloudflare|doh-quad9)
      echo "Android $label resolver passed: production authenticated-DoH success counter increased"
      ;;
  esac
}

run_ios_case() {
  local label="$1" first="$2" final="$3"
  local mode provider custom_url bootstrap_ips through_servers probe_host evidence
  local before_bytes before_forward before_evidence expected_ip
  local wireguard_config_file idle_gate lifecycle_gate
  IFS='|' read -r \
    mode provider custom_url bootstrap_ips through_servers probe_host evidence \
    <<<"$(dns_case_fields "$label")"
  local ios_args=(
    device
    --vpn-cycle
    --probe-target "$TUNNEL_SERVER_IP"
    --probe-port 9
    --probe-count 4
    --probe-require-reply
  )
  if [[ "$first" == "1" ]]; then
    wireguard_config_file="$FIXTURE_DIR/client.conf"
    idle_gate="${NVPN_IDLE_CPU_GATE:-1}"
    lifecycle_gate="$LIFECYCLE_GATE"
  else
    wireguard_config_file=""
    idle_gate=false
    lifecycle_gate=false
  fi
  run_ios_exit_dns_shipped_ui_case_gate \
    "$label" "$first" "$mode" "$provider" "$custom_url" "$bootstrap_ips" \
    "$through_servers"
  before_bytes="$(wg_bytes)"
  before_forward="$(forward_packets)"
  case "$evidence" in
    dns)
      before_evidence="$(dns_query_count "$probe_host")"
      expected_ip="$TUNNEL_SERVER_IP"
      ;;
    doh-cloudflare)
      before_evidence="$(doh_flow_count cloudflare)"
      expected_ip=""
      ;;
    doh-quad9)
      before_evidence="$(doh_flow_count quad9)"
      expected_ip=""
      ;;
  esac
  env \
    NVPN_IOS_DEVICE="$IOS_DEVICE_SELECTED" \
    NVPN_IOS_DEBUG_WIREGUARD_CONFIG_FILE="$wireguard_config_file" \
    NVPN_IOS_LIFECYCLE_GATE="$lifecycle_gate" \
    NVPN_IOS_IDLE_CPU_GATE="$idle_gate" \
    NVPN_IOS_EXIT_DNS_MODE="$mode" \
    NVPN_IOS_EXIT_DNS_DOH_PROVIDER="$provider" \
    NVPN_IOS_EXIT_DNS_CUSTOM_DOH_URL="$custom_url" \
    NVPN_IOS_EXIT_DNS_CUSTOM_DOH_BOOTSTRAP_IPS="$bootstrap_ips" \
    NVPN_IOS_EXIT_DNS_THROUGH_EXIT_SERVERS="$through_servers" \
    NVPN_IOS_EXIT_DNS_USE_SHIPPED_UI=1 \
    NVPN_IOS_EXPECT_DEBUG_DNS_INJECTED=0 \
    NVPN_IOS_EXPECT_WIREGUARD_EXIT=1 \
    NVPN_IOS_SWITCH_TO_DIRECT_WHILE_CONNECTED="$final" \
    NVPN_IOS_EXIT_PROBE_HOST="$probe_host" \
    NVPN_IOS_EXIT_PROBE_EXPECTED_IP="$expected_ip" \
    NVPN_IOS_EXIT_PROBE_URL="$DIRECT_URL" \
    NVPN_IOS_DIRECT_PROBE_HOST="$DIRECT_HOST" \
    NVPN_IOS_DIRECT_PROBE_URL="$DIRECT_URL" \
    NVPN_IOS_EXPECT_WIREGUARD_ENDPOINT="$HOST_IP:$HOST_PORT" \
    NVPN_IOS_VERIFY_DIRECT_RESTORATION="$final" \
    "$ROOT/scripts/mobile-ios-smoke.sh" "${ios_args[@]}"
  assert_platform_traffic iOS "$label" "$before_bytes" "$before_forward"
  case "$evidence" in
    dns) assert_fixture_dns_traffic iOS "$label" "$probe_host" "$before_evidence" ;;
    doh-cloudflare) assert_doh_traffic iOS "$label" cloudflare "$before_evidence" ;;
    doh-quad9) assert_doh_traffic iOS "$label" quad9 "$before_evidence" ;;
  esac
}

DNS_CASES=(automatic-profile cloudflare-doh quad9-doh custom-doh through-exit)
if [[ -n "${NVPN_MOBILE_WG_EXIT_DNS_CASES:-}" ]]; then
  IFS=',' read -r -a DNS_CASES <<<"$NVPN_MOBILE_WG_EXIT_DNS_CASES"
  for label in "${DNS_CASES[@]}"; do
    dns_case_fields "$label" >/dev/null \
      || {
        echo "NVPN_MOBILE_WG_EXIT_DNS_CASES contains an unsupported case" >&2
        exit 2
      }
  done
fi
if has_platform android; then
  assert_single_android_app
  for index in "${!DNS_CASES[@]}"; do
    final=0
    [[ "$index" -eq "$((${#DNS_CASES[@]} - 1))" ]] && final=1
    first=0
    [[ "$index" -eq 0 ]] && first=1
    run_android_case "${DNS_CASES[$index]}" "$first" "$final"
  done
  assert_single_android_app
fi
if has_platform ios; then
  IOS_DEVICE_SELECTED="$(select_physical_ios_device)" || {
    echo "iOS WireGuard exit gate requires exactly one physical iPhone/iPad" >&2
    exit 1
  }
  IOS_CLEANUP_ARMED=1
  case "$INSTALL_IOS" in
    0|false|FALSE|False|no|NO|No|off|OFF|Off) ;;
    *)
      env \
        NVPN_IOS_DEVICE="$IOS_DEVICE_SELECTED" \
        NVPN_IOS_IDLE_CPU_GATE=0 \
        NVPN_IOS_LIFECYCLE_GATE=0 \
        "$ROOT/scripts/mobile-ios-smoke.sh" device --install
      ;;
  esac
  for index in "${!DNS_CASES[@]}"; do
    final=0
    [[ "$index" -eq "$((${#DNS_CASES[@]} - 1))" ]] && final=1
    first=0
    [[ "$index" -eq 0 ]] && first=1
    run_ios_case "${DNS_CASES[$index]}" "$first" "$final"
  done
fi

echo "Mobile WireGuard exit e2e passed for: $PLATFORMS"
