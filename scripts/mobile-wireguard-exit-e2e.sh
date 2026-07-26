#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/release_common.sh"
# shellcheck disable=SC1091
source "$ROOT/scripts/mobile_env.sh"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib-mobile-wireguard-fixture.sh"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib-mobile-android-managed-ap.sh"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib-mobile-underlay-change.sh"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib-mobile-ios-release-network.sh"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib-mobile-ios-hotspot.sh"
load_release_env "$ROOT"
load_appstoreconnect_defaults
load_mobile_env "$ROOT"
IMAGE="${NVPN_MOBILE_WG_EXIT_IMAGE:-nostr-vpn-mobile-wireguard-exit-e2e}"
CONTAINER="${NVPN_MOBILE_WG_EXIT_CONTAINER:-nostr-vpn-mobile-wireguard-exit-e2e}"
HOST_PORT="${NVPN_MOBILE_WG_EXIT_HOST_PORT:-51886}"
TUNNEL_SERVER_IP="${NVPN_MOBILE_WG_EXIT_SERVER_IP:-10.99.77.1}"
TUNNEL_CLIENT_IP="${NVPN_MOBILE_WG_EXIT_CLIENT_IP:-10.99.77.2}"
DNS_NAME="${NVPN_MOBILE_WG_EXIT_DNS_NAME:-wireguard-exit.nvpn-e2e.test}"
HTTP_PROBE_PORT="${NVPN_MOBILE_WG_EXIT_HTTP_PROBE_PORT:-8080}"
HTTP_PROBE_TOKEN="${NVPN_MOBILE_WG_EXIT_HTTP_TOKEN:-nvpn-mobile-$PPID-$$-$RANDOM}"
DIRECT_HOST="${NVPN_MOBILE_WG_EXIT_DIRECT_HOST:-example.com}"
DIRECT_URL="${NVPN_MOBILE_WG_EXIT_DIRECT_URL:-https://example.com/}"
EXIT_SOURCE_PROBE_URL="${NVPN_MOBILE_WG_EXIT_SOURCE_IP_URL:-https://api.ipify.org}"
EXPECTED_EXIT_SOURCE_IP="${NVPN_MOBILE_WG_EXIT_EXPECTED_SOURCE_IP:-}"
PLATFORMS="${NVPN_MOBILE_WG_EXIT_PLATFORMS:-android,ios}"
INSTALL_ANDROID="${NVPN_MOBILE_WG_EXIT_INSTALL_ANDROID:-1}"
LIFECYCLE_GATE="${NVPN_MOBILE_WG_EXIT_LIFECYCLE_GATE:-1}"
UNDERLAY_CHANGE_GATE="${NVPN_MOBILE_WG_EXIT_UNDERLAY_CHANGE_GATE:-0}"
RELEASE_BLACKBOX_GATE="${NVPN_MOBILE_WG_EXIT_RELEASE_BLACKBOX:-1}"
REUSE_ANDROID_BUILD="${NVPN_MOBILE_WG_EXIT_REUSE_ANDROID_BUILD:-0}"
IOS_BUNDLE_ID="${NVPN_IOS_BUNDLE_ID:-${NVPN_DEFAULT_IOS_BUNDLE_ID:-fi.siriusbusiness.nvpn}}"
FIXTURE_DIR=""
ANDROID_DEVICE_SERIAL=""
IOS_DEVICE_SELECTED=""
IOS_CLEANUP_ARMED=0
ADB="${ADB:-$(command -v adb || true)}"

usage() {
  cat >&2 <<'EOF'
usage: scripts/mobile-wireguard-exit-e2e.sh [android|ios|all]

Runs a real WireGuard exit and DNS resolver in a local Docker fixture or an
environment-selected remote Linux fixture, then proves on physical devices that:
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

The default local fixture requires the host and devices to share a LAN.
For cellular/hotspot coverage, set NVPN_MOBILE_WG_EXIT_FIXTURE_SSH_HOST,
NVPN_MOBILE_WG_EXIT_HOST_IP, and optionally NVPN_MOBILE_WG_EXIT_REMOTE_MODE
(native by default). No remote host, address, or credential is built in.
Set NVPN_MOBILE_WG_EXIT_INSTALL_ANDROID=0 to exercise an already-installed
canonical company-signed debug build without replacing it.
Set NVPN_MOBILE_WG_EXIT_UNDERLAY_CHANGE_GATE=1 for the physical two-underlay
gate. Android then requires env-only home/alternate Wi-Fi credentials. iOS
requires env-only home/Pixel-hotspot Wi-Fi credentials and uses the production
Settings UIs on both phones to switch real SSIDs and control the hotspot.
The fixture endpoint must be reachable through both physical underlays.
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
  mobile_continuity_stop
  if [[ "$IOS_CLEANUP_ARMED" == "1" && -n "$IOS_DEVICE_SELECTED" ]]; then
    if ! ios_release_network_disconnect_cleanup; then
      echo "iOS WireGuard exit gate cleanup could not confirm tunnel disconnect" >&2
      cleanup_failed=1
    fi
  fi
  if ! ios_release_network_cleanup_private_artifacts; then
    cleanup_failed=1
  fi
  if ! mobile_ios_hotspot_cleanup; then
    cleanup_failed=1
  fi
  if ! mobile_android_managed_ap_cleanup; then
    cleanup_failed=1
  fi
  if ! mobile_wg_fixture_cleanup "$CONTAINER" "$IMAGE"; then
    echo "WireGuard exit fixture cleanup left a managed resource behind" >&2
    cleanup_failed=1
  fi
  if [[ -n "$FIXTURE_DIR" ]]; then
    if rm -rf "$FIXTURE_DIR" && [[ ! -e "$FIXTURE_DIR" ]]; then
      FIXTURE_DIR=""
    else
      echo "WireGuard exit fixture private files survived local cleanup" >&2
      cleanup_failed=1
    fi
  fi
  if [[ "$status" -eq 0 && "$cleanup_failed" -ne 0 ]]; then
    status=1
  fi
  exit "$status"
}
trap cleanup EXIT INT TERM

for command in wg; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "mobile WireGuard exit e2e requires $command" >&2
    exit 1
  fi
done

if has_platform android; then
  if [[ -z "$ADB" ]]; then
    echo "mobile WireGuard exit e2e requires adb for the physical Android device" >&2
    exit 1
  fi
  ANDROID_DEVICE_SERIAL="$(select_physical_android_serial \
    "$ADB" \
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
export NVPN_MOBILE_WG_EXIT_HOST_IP="$HOST_IP"

FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nvpn-mobile-wg-exit.XXXXXX")"
chmod 700 "$FIXTURE_DIR"
umask 077
wg genkey >"$FIXTURE_DIR/server.key"
wg pubkey <"$FIXTURE_DIR/server.key" >"$FIXTURE_DIR/server.pub"
wg genkey >"$FIXTURE_DIR/client.key"
wg pubkey <"$FIXTURE_DIR/client.key" >"$FIXTURE_DIR/client.pub"

mobile_wg_fixture_initialize "$ROOT" "$FIXTURE_DIR"
mobile_wg_fixture_assert_available "$CONTAINER" "$HOST_PORT"
if [[ -z "$EXPECTED_EXIT_SOURCE_IP" ]]; then
  if [[ "$MOBILE_WG_FIXTURE_REMOTE" -eq 1 ]]; then
    EXPECTED_EXIT_SOURCE_IP="$(
      mobile_wg_remote_exec curl -4fsS --max-time 10 "$EXIT_SOURCE_PROBE_URL"
    )"
  else
    EXPECTED_EXIT_SOURCE_IP="$(curl -4fsS --max-time 10 "$EXIT_SOURCE_PROBE_URL")"
  fi
fi
if ! python3 - "$EXPECTED_EXIT_SOURCE_IP" <<'PY'
import ipaddress
import sys

try:
    address = ipaddress.ip_address(sys.argv[1].strip())
except ValueError:
    raise SystemExit(1)
raise SystemExit(0 if address.version == 4 else 1)
PY
then
  echo "mobile WireGuard exit fixture has no valid expected IPv4 egress receipt" >&2
  exit 1
fi

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

mobile_wg_fixture_build \
  "$ROOT" "$IMAGE" "${NVPN_MOBILE_WG_EXIT_IMAGE_READY:-0}"
mobile_wg_fixture_run "$IMAGE" "$CONTAINER" "$MOBILE_WG_FIXTURE_VOLUME_DIR"

for _ in $(seq 1 100); do
  mobile_wg_fixture_ready "$CONTAINER" >/dev/null 2>&1 && break
  if ! mobile_wg_fixture_running "$CONTAINER"; then
    mobile_wg_fixture_logs "$CONTAINER" >&2 || true
    echo "mobile WireGuard exit fixture stopped before becoming ready" >&2
    exit 1
  fi
  sleep 0.1
done
if ! mobile_wg_fixture_ready "$CONTAINER" >/dev/null 2>&1; then
  mobile_wg_fixture_logs "$CONTAINER" >&2 || true
  echo "mobile WireGuard exit fixture did not become ready" >&2
  exit 1
fi

if has_platform android && bool_is_true "$UNDERLAY_CHANGE_GATE" \
  && [[ -n "${NVPN_ANDROID_UNDERLAY_MANAGED_AP_SSH_HOST:-}" ]]
then
  if [[ -z "${NVPN_ANDROID_UNDERLAY_HOME_SSID:-}" ]]; then
    NVPN_ANDROID_UNDERLAY_HOME_SSID="$(
      adb -s "$ANDROID_DEVICE_SERIAL" shell cmd wifi status 2>/dev/null \
        | tr -d '\r' \
        | sed -n 's/^Wifi is connected to "\(.*\)"$/\1/p' \
        | head -n 1
    )"
    export NVPN_ANDROID_UNDERLAY_HOME_SSID
  fi
  [[ -n "$NVPN_ANDROID_UNDERLAY_HOME_SSID" ]] || {
    echo "Android managed AP gate could not identify the current saved home Wi-Fi" >&2
    exit 1
  }
  mobile_android_managed_ap_start
fi

wg_bytes() {
  mobile_wg_fixture_wg_bytes "$CONTAINER"
}

forward_packets() {
  mobile_wg_fixture_forward_packets "$CONTAINER"
}

dns_query_count() {
  local name="$1"
  mobile_wg_fixture_dns_count "$CONTAINER" "$name"
}

doh_flow_count() {
  local provider="$1"
  mobile_wg_fixture_doh_count "$CONTAINER" "$provider"
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
  local wireguard_config_file idle_gate lifecycle_gate underlay_gate switch_direct
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
  if bool_is_true "$RELEASE_BLACKBOX_GATE"; then
    android_args=(--release-network-gate "${android_args[@]}")
  fi
  wireguard_config_file="$FIXTURE_DIR/client.conf"
  if [[ "$first" == "1" ]]; then
    android_args=(--create-network "${android_args[@]}")
    idle_gate="${NVPN_IDLE_CPU_GATE:-1}"
    lifecycle_gate="$LIFECYCLE_GATE"
    underlay_gate="$UNDERLAY_CHANGE_GATE"
    if ! bool_is_true "$RELEASE_BLACKBOX_GATE"; then
      case "$INSTALL_ANDROID" in
        0|false|FALSE|False|no|NO|No|off|OFF|Off)
          android_args=(--no-build --no-install "${android_args[@]}")
          ;;
      esac
    elif bool_is_true "$REUSE_ANDROID_BUILD"; then
      android_args=(--no-build "${android_args[@]}")
    fi
  else
    android_args=(--no-build --no-install "${android_args[@]}")
    idle_gate=false
    lifecycle_gate=false
    underlay_gate=false
  fi
  switch_direct="$final"
  if bool_is_true "$underlay_gate"; then
    # The active lifecycle runs after this transition in the Android driver.
    # Native restoration is still proved after disconnect, while the ordinary
    # all-DNS run separately covers connected WireGuard -> Direct.
    switch_direct=0
  fi
  env \
    NVPN_ANDROID_SERIAL="$ANDROID_DEVICE_SERIAL" \
    NVPN_ANDROID_PACKAGE="${NVPN_ANDROID_PACKAGE:-fi.siriusbusiness.nvpn}" \
    NVPN_ANDROID_RELEASE_BLACKBOX_GATE="$RELEASE_BLACKBOX_GATE" \
    NVPN_ANDROID_WIREGUARD_CONFIG_FILE="$wireguard_config_file" \
    NVPN_ANDROID_DEBUG_WIREGUARD_CONFIG_FILE="$wireguard_config_file" \
    NVPN_ANDROID_LIFECYCLE_GATE="$lifecycle_gate" \
    NVPN_ANDROID_UNDERLAY_CHANGE_GATE="$underlay_gate" \
    NVPN_MOBILE_UNDERLAY_CONTINUITY_CONTAINER="$CONTAINER" \
    NVPN_MOBILE_UNDERLAY_CONTINUITY_CLIENT_IP="$TUNNEL_CLIENT_IP" \
    NVPN_MOBILE_UNDERLAY_CONTINUITY_SSH_HOST="${NVPN_MOBILE_WG_EXIT_FIXTURE_SSH_HOST:-}" \
    NVPN_MOBILE_UNDERLAY_CONTINUITY_REMOTE_MODE="$MOBILE_WG_FIXTURE_REMOTE_MODE" \
    NVPN_MOBILE_UNDERLAY_CONTINUITY_REMOTE_INTERFACE="$MOBILE_WG_FIXTURE_REMOTE_INTERFACE" \
    NVPN_MOBILE_UNDERLAY_CONTINUITY_REMOTE_DOCKER_SUDO="${NVPN_MOBILE_WG_EXIT_REMOTE_DOCKER_SUDO:-0}" \
    NVPN_ANDROID_UNDERLAY_UDP_ECHO_HOST="$TUNNEL_SERVER_IP" \
    NVPN_ANDROID_UNDERLAY_UDP_ECHO_PORT=9 \
    NVPN_ANDROID_IDLE_CPU_GATE="$idle_gate" \
    NVPN_ANDROID_EXIT_DNS_MODE="$mode" \
    NVPN_ANDROID_EXIT_DNS_DOH_PROVIDER="$provider" \
    NVPN_ANDROID_EXIT_DNS_CUSTOM_DOH_URL="$custom_url" \
    NVPN_ANDROID_EXIT_DNS_CUSTOM_DOH_BOOTSTRAP_IPS="$bootstrap_ips" \
    NVPN_ANDROID_EXIT_DNS_THROUGH_EXIT_SERVERS="$through_servers" \
    NVPN_ANDROID_EXIT_DNS_USE_SHIPPED_UI=1 \
    NVPN_ANDROID_SWITCH_TO_DIRECT_WHILE_CONNECTED="$switch_direct" \
    NVPN_ANDROID_EXIT_PROBE_HOST="$probe_host" \
    NVPN_ANDROID_EXIT_PROBE_EXPECTED_IP="$expected_ip" \
    NVPN_ANDROID_EXIT_PROBE_URL="$DIRECT_URL" \
    NVPN_ANDROID_DIRECT_PROBE_HOST="$DIRECT_HOST" \
    NVPN_ANDROID_DIRECT_PROBE_URL="$DIRECT_URL" \
    NVPN_ANDROID_EXPECT_WIREGUARD_ENDPOINT="$HOST_IP:$HOST_PORT" \
    NVPN_ANDROID_CAPTURED_PROBE_URL="http://$TUNNEL_SERVER_IP:$HTTP_PROBE_PORT/$HTTP_PROBE_TOKEN" \
    NVPN_ANDROID_CAPTURED_PROBE_TOKEN="$HTTP_PROBE_TOKEN" \
    NVPN_ANDROID_EXIT_SOURCE_PROBE_URL="$EXIT_SOURCE_PROBE_URL" \
    NVPN_ANDROID_EXPECTED_EXIT_SOURCE_IP="$EXPECTED_EXIT_SOURCE_IP" \
    "$ROOT/scripts/mobile-android-smoke.sh" "${android_args[@]}"
  assert_platform_traffic Android "$label" "$before_bytes" "$before_forward"
  case "$evidence" in
    dns) assert_fixture_dns_traffic Android "$label" "$probe_host" "$before_evidence" ;;
    doh-cloudflare) assert_doh_traffic Android "$label" cloudflare "$before_evidence" ;;
    doh-quad9) assert_doh_traffic Android "$label" quad9 "$before_evidence" ;;
  esac
}

run_ios_case() {
  local label="$1" first="$2" final="$3"
  local mode provider custom_url bootstrap_ips through_servers probe_host evidence
  local before_bytes before_forward before_evidence
  local lifecycle_gate underlay_gate resolver_probe_url resolver_body
  local underlay_home_ssid underlay_home_passphrase
  local underlay_alternate_ssid underlay_alternate_passphrase
  local run_id spec_base64
  IFS='|' read -r \
    mode provider custom_url bootstrap_ips through_servers probe_host evidence \
    <<<"$(dns_case_fields "$label")"
  if [[ "$first" == "1" ]]; then
    lifecycle_gate="$LIFECYCLE_GATE"
    underlay_gate="$UNDERLAY_CHANGE_GATE"
  else
    lifecycle_gate=false
    underlay_gate=false
  fi
  underlay_home_ssid="${NVPN_IOS_UNDERLAY_HOME_SSID:-}"
  underlay_home_passphrase="${NVPN_IOS_UNDERLAY_HOME_PASSPHRASE:-}"
  underlay_alternate_ssid="${NVPN_IOS_UNDERLAY_ALTERNATE_SSID:-}"
  underlay_alternate_passphrase="${NVPN_IOS_UNDERLAY_ALTERNATE_PASSPHRASE:-}"
  if bool_is_true "$underlay_gate"; then
    [[ -n "$underlay_home_ssid" \
      && -n "$underlay_alternate_ssid" \
      && "$underlay_home_ssid" != "$underlay_alternate_ssid" ]] || {
      echo "iOS physical underlay gate requires distinct private home/hotspot SSIDs" >&2
      return 1
    }
  fi
  before_bytes="$(wg_bytes)"
  before_forward="$(forward_packets)"
  case "$evidence" in
    dns)
      before_evidence="$(dns_query_count "$probe_host")"
      resolver_probe_url="http://$probe_host:$HTTP_PROBE_PORT/$HTTP_PROBE_TOKEN"
      resolver_body="$HTTP_PROBE_TOKEN"
      ;;
    doh-cloudflare)
      before_evidence="$(doh_flow_count cloudflare)"
      resolver_probe_url="$DIRECT_URL"
      resolver_body=""
      ;;
    doh-quad9)
      before_evidence="$(doh_flow_count quad9)"
      resolver_probe_url="$DIRECT_URL"
      resolver_body=""
      ;;
  esac
  run_id="ios-release-$label-$PPID-$$-$RANDOM"
  spec_base64="$(
    python3 - \
      "$run_id" "$label" "$(<"$FIXTURE_DIR/client.conf")" "$mode" "$provider" \
      "$custom_url" "$bootstrap_ips" "$through_servers" "$probe_host" \
      "$resolver_probe_url" "$resolver_body" "$TUNNEL_SERVER_IP" \
      "$DIRECT_URL" "$EXIT_SOURCE_PROBE_URL" "$EXPECTED_EXIT_SOURCE_IP" \
      "$first" "$underlay_gate" "$lifecycle_gate" "$final" \
      "${NVPN_IOS_ACTIVE_TUNNEL_LIFECYCLE_CYCLES:-3}" \
      "${NVPN_IOS_RELEASE_NETWORK_BACKGROUND_DWELL_SECS:-20}" \
      "${NVPN_MOBILE_UNDERLAY_ASSOCIATION_TIMEOUT_SECS:-30}" \
      "$underlay_home_ssid" "$underlay_home_passphrase" \
      "$underlay_alternate_ssid" "$underlay_alternate_passphrase" <<'PY'
import base64
import json
import sys

(
    run_id,
    label,
    wireguard,
    mode,
    provider,
    custom_url,
    bootstrap_ips,
    through_servers,
    resolver_host,
    resolver_url,
    resolver_body,
    udp_host,
    public_url,
    source_url,
    expected_source,
    create_network,
    underlay,
    lifecycle,
    direct,
    cycles,
    dwell,
    association_timeout,
    underlay_home_ssid,
    underlay_home_passphrase,
    underlay_alternate_ssid,
    underlay_alternate_passphrase,
) = sys.argv[1:]
payload = {
    "runId": run_id,
    "caseName": label,
    "networkName": "Physical Release Network",
    "wireGuardConfig": wireguard,
    "mode": mode,
    "provider": provider,
    "customUrl": custom_url,
    "bootstrapIps": bootstrap_ips,
    "throughExitServers": through_servers,
    "resolverQueryHost": resolver_host,
    "resolverProbeUrl": resolver_url,
    "resolverExpectedBody": resolver_body or None,
    "udpHost": udp_host,
    "udpPort": 9,
    "publicHttpsUrl": public_url,
    "sourceIpUrl": source_url,
    "expectedExitSourceIp": expected_source,
    "createNetwork": create_network == "1",
    "exerciseUnderlay": underlay.lower() in {"1", "true", "yes", "on"},
    "exerciseLifecycle": lifecycle.lower() in {"1", "true", "yes", "on"},
    "switchToDirect": direct == "1",
    "lifecycleCycles": int(cycles),
    "backgroundDwellSeconds": int(dwell),
    "underlayAssociationTimeoutSeconds": int(association_timeout),
    "underlayHomeSsid": underlay_home_ssid,
    "underlayHomePassphrase": underlay_home_passphrase,
    "underlayAlternateSsid": underlay_alternate_ssid,
    "underlayAlternatePassphrase": underlay_alternate_passphrase,
}
print(
    base64.b64encode(
        json.dumps(payload, separators=(",", ":")).encode()
    ).decode()
)
PY
  )"
  NVPN_MOBILE_UNDERLAY_CONTINUITY_CONTAINER="$CONTAINER"
  NVPN_MOBILE_UNDERLAY_CONTINUITY_CLIENT_IP="$TUNNEL_CLIENT_IP"
  NVPN_MOBILE_UNDERLAY_CONTINUITY_SSH_HOST="${NVPN_MOBILE_WG_EXIT_FIXTURE_SSH_HOST:-}"
  NVPN_MOBILE_UNDERLAY_CONTINUITY_REMOTE_MODE="$MOBILE_WG_FIXTURE_REMOTE_MODE"
  NVPN_MOBILE_UNDERLAY_CONTINUITY_REMOTE_INTERFACE="$MOBILE_WG_FIXTURE_REMOTE_INTERFACE"
  NVPN_MOBILE_UNDERLAY_CONTINUITY_REMOTE_DOCKER_SUDO="${NVPN_MOBILE_WG_EXIT_REMOTE_DOCKER_SUDO:-0}"
  run_ios_release_network_case \
    "$label" "$run_id" "$spec_base64" \
    "$lifecycle_gate" "$underlay_gate" "$final"
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
  if ! bool_is_true "$RELEASE_BLACKBOX_GATE"; then
    echo "iOS physical network claims require the company-signed Release black-box gate" >&2
    exit 1
  fi
  if [[ -z "${NVPN_IOS_DEVICE:-${NVPN_IOS_DEVICE_ID:-}}" \
    || -z "${NVPN_IOS_EXPECTED_DEVICE_NAME:-}" ]]
  then
    echo "iOS physical Release gate requires an explicit device selector and expected name" >&2
    exit 1
  fi
  IOS_DEVICE_SELECTED="$(
    select_physical_ios_device "${NVPN_IOS_DEVICE:-${NVPN_IOS_DEVICE_ID:-}}"
  )" || {
    echo "iOS WireGuard exit gate could not select the required physical phone" >&2
    exit 1
  }
  IOS_CLEANUP_ARMED=1
  ios_release_network_prepare "$IOS_DEVICE_SELECTED"
  if bool_is_true "$UNDERLAY_CHANGE_GATE"; then
    [[ -n "$ADB" ]] || {
      echo "iOS physical hotspot gate requires adb for the Pixel host" >&2
      exit 1
    }
    mobile_ios_hotspot_prepare
  fi
  for index in "${!DNS_CASES[@]}"; do
    final=0
    [[ "$index" -eq "$((${#DNS_CASES[@]} - 1))" ]] && final=1
    first=0
    [[ "$index" -eq 0 ]] && first=1
    run_ios_case "${DNS_CASES[$index]}" "$first" "$final"
  done
  ios_release_network_disconnect_cleanup
  IOS_CLEANUP_ARMED=0
  mobile_ios_hotspot_cleanup
fi

echo "Mobile WireGuard exit e2e passed for: $PLATFORMS"
