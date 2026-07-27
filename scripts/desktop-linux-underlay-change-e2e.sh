#!/usr/bin/env bash
# Guest-side half of the real Linux dual-NIC underlay-change gate.
set -euo pipefail

ACTION="${1:-}"
BINARY="${NVPN_UNDERLAY_BINARY:?set NVPN_UNDERLAY_BINARY}"
STATE_DIR="${NVPN_UNDERLAY_STATE_DIR:?set NVPN_UNDERLAY_STATE_DIR}"
CONFIG="$STATE_DIR/config.toml"
SECONDARY_PROFILE_UUID_FILE="$STATE_DIR/secondary.nm-uuid"
SECONDARY_PROFILE_NAME_FILE="$STATE_DIR/secondary.nm-name"
PRIMARY_MAC="${NVPN_UNDERLAY_PRIMARY_MAC:-}"
SECONDARY_MAC="${NVPN_UNDERLAY_SECONDARY_MAC:-}"
SECONDARY_ADDRESS="${NVPN_UNDERLAY_SECONDARY_ADDRESS:-}"
SECONDARY_PREFIX="${NVPN_UNDERLAY_SECONDARY_PREFIX:-24}"
SECONDARY_GATEWAY="${NVPN_UNDERLAY_SECONDARY_GATEWAY:-}"
NETWORK_ID="${NVPN_UNDERLAY_NETWORK_ID:-}"
PEER_NPUB="${NVPN_UNDERLAY_PEER_NPUB:-}"
PEER_ENDPOINT="${NVPN_UNDERLAY_PEER_ENDPOINT:-}"
PEER_TUNNEL_IP="${NVPN_UNDERLAY_PEER_TUNNEL_IP:-}"
FIXTURE_DNS_NAME="${NVPN_UNDERLAY_FIXTURE_DNS_NAME:-underlay-gate.nvpn.test}"
PROBE_URL="${NVPN_UNDERLAY_PROBE_URL:-https://example.com/}"
TUN_IFACE="${NVPN_UNDERLAY_TUN_IFACE:-nvu-underlay}"
LISTEN_PORT="${NVPN_UNDERLAY_LISTEN_PORT:-45821}"
RECOVERY_DEADLINE_MS="${NVPN_UNDERLAY_RECOVERY_DEADLINE_MS:-4000}"
EXPECTED_FIPS_REV="${NVPN_UNDERLAY_EXPECTED_FIPS_REV:-}"
WG_IFACE="${NVPN_UNDERLAY_WG_INTERFACE:-nvpn-wg-exit}"
WG_PEER_PUBLIC_KEY="${NVPN_UNDERLAY_WG_PEER_PUBLIC_KEY:-}"
WG_ENDPOINT="${NVPN_UNDERLAY_WG_ENDPOINT:-}"
WG_CLIENT_ADDRESS="${NVPN_UNDERLAY_WG_CLIENT_ADDRESS:-10.232.0.2/32}"
WG_PRIVATE_KEY_FILE="$STATE_DIR/wg-client-private.key"
WG_CONFIG_FILE="$STATE_DIR/wg-client.conf"
ORIGINAL_NPUB=""
ORIGINAL_TUNNEL_IP=""

fail() {
  echo "Linux underlay network-change e2e failed: $*" >&2
  exit 1
}

require_root() {
  [[ "$(id -u)" == "0" ]] || fail "the guest runner requires root"
}

normalize_mac() {
  tr '[:upper:]' '[:lower:]' <<<"$1"
}

iface_for_mac() {
  local wanted="$1"
  local path
  wanted="$(normalize_mac "$wanted")"
  for path in /sys/class/net/*/address; do
    [[ "$(<"$path")" == "$wanted" ]] && basename "$(dirname "$path")"
  done
  return 0
}

require_iface_for_mac() {
  local mac="$1"
  local matches
  matches="$(iface_for_mac "$mac")"
  [[ "$(grep -c . <<<"$matches" || true)" == "1" ]] \
    || fail "expected exactly one Linux interface for the supplied MAC"
  printf '%s\n' "$matches"
}

read_npub() {
  awk '
    /^\[nostr\]$/ { in_nostr = 1; next }
    /^\[/ { in_nostr = 0 }
    in_nostr && /^public_key[[:space:]]*=/ {
      gsub(/"/, "", $3)
      print $3
      exit
    }
  ' "$CONFIG"
}

status_json() {
  "$BINARY" status --config "$CONFIG" --json --discover-secs 0
}

status_summary() {
  status_json | jq -c '{
    status_source,
    daemon_running: (.daemon.running // false),
    daemon_pid: (.daemon.pid // null),
    mesh_ready: (.daemon.state.mesh_ready // false),
    connected_peer_count: (.daemon.state.connected_peer_count // 0),
    vpn_status: (.daemon.state.vpn_status // null),
    fips_core_version: (.daemon.state.fips_core_version // null)
  }'
}

daemon_pid() {
  status_json | jq -er '
    select(.status_source == "daemon")
    | select(.daemon.running == true)
    | .daemon.pid
  '
}

route_dev() {
  ip -j -4 route get "$1" | jq -er '.[0].dev'
}

physical_default_route_dev() {
  local iface
  while IFS= read -r iface; do
    [[ "$iface" == "$TUN_IFACE" ]] && continue
    [[ -r "/sys/class/net/$iface/carrier" ]] || continue
    [[ "$(<"/sys/class/net/$iface/carrier")" == "1" ]] || continue
    ip -j -4 address show dev "$iface" scope global \
      | jq -e 'any(.[].addr_info[]?; .scope == "global")' >/dev/null \
      || continue
    printf '%s\n' "$iface"
    return 0
  done < <(
    ip -j -4 route show table main default \
      | jq -r 'sort_by(.metric // 0) | .[].dev' \
      | awk '!seen[$0]++'
  )
  return 1
}

endpoint_host() {
  printf '%s\n' "${PEER_ENDPOINT%:*}"
}

probe_host() {
  local host="${PROBE_URL#*://}"
  host="${host%%/*}"
  printf '%s\n' "${host%%:*}"
}

marker_path() {
  printf '%s/%s\n' "$STATE_DIR" "$1"
}

write_marker() {
  printf '%s' "${2:-ok}" >"$(marker_path "$1")"
}

wait_for_marker() {
  local name="$1"
  local deadline="$((SECONDS + 30))"
  while ((SECONDS < deadline)); do
    [[ -e "$(marker_path "$name")" ]] && return 0
    sleep 0.1
  done
  fail "timed out waiting for host signal $name"
}

rebind_count() {
  grep -Fc 'underlay carrier(s) rebound' "$STATE_DIR/daemon.stderr.log" 2>/dev/null || true
}

endpoint_start_count() {
  grep -Ec \
    'daemon: (FIPS private mesh on|restarted FIPS private mesh on|rebuilt FIPS private mesh on)' \
    "$STATE_DIR/daemon.stderr.log" 2>/dev/null || true
}

payload_success_count() {
  grep -Fc 'bytes from' "$STATE_DIR/payload.log" 2>/dev/null || true
}

wireguard_payload_success_count() {
  grep -c . "$STATE_DIR/wireguard-payload.log" 2>/dev/null || true
}

wireguard_handshake_active() {
  wg show "$WG_IFACE" latest-handshakes 2>/dev/null \
    | awk 'NF == 2 && $2 + 0 > 0 { found = 1 } END { exit !found }'
}

wireguard_payload_loop() {
  while :; do
    if curl -4 --fail --silent --max-time 2 --output /dev/null "$PROBE_URL"; then
      monotonic_milliseconds >>"$STATE_DIR/wireguard-payload.log"
    fi
    sleep 0.1
  done
}

assert_wireguard_endpoint_route() {
  local expected_iface="$1"
  local host expected_gateway expected_source
  host="$(endpoint_host)"
  expected_gateway="$(
    ip -j -4 route show default dev "$expected_iface" \
      | jq -er 'sort_by(.metric // 0) | .[0].gateway'
  )"
  expected_source="$(
    ip -j -4 address show dev "$expected_iface" scope global \
      | jq -er '.[].addr_info[] | select(.family == "inet" and .scope == "global") | .local' \
      | head -n1
  )"
  ip -j -4 route show exact "$host/32" \
    | jq -e \
      --arg dev "$expected_iface" \
      --arg gateway "$expected_gateway" \
      --arg source "$expected_source" \
      --arg host "$host" \
      'length == 1
       and .[0].dst == ($host + "/32")
       and .[0].dev == $dev
       and .[0].gateway == $gateway
       and .[0].prefsrc == $source' >/dev/null
}

monotonic_milliseconds() {
  awk '{ printf "%.0f\n", $1 * 1000 }' /proc/uptime
}

unix_milliseconds() {
  local nanoseconds
  nanoseconds="$(date +%s%N)"
  [[ "$nanoseconds" =~ ^[0-9]+$ ]] \
    || fail "date did not return a numeric Unix nanosecond timestamp"
  echo "$((10#$nanoseconds / 1000000))"
}

flush_dns_cache() {
  resolvectl flush-caches >/dev/null
}

resolve_name() {
  local name="$1"
  flush_dns_cache
  resolvectl query --type=A "$name" >/dev/null 2>&1 \
    && getent ahostsv4 "$name" >/dev/null 2>&1
}

resolve_fixture() {
  local addresses
  flush_dns_cache
  resolvectl query --type=A "$FIXTURE_DNS_NAME" >/dev/null 2>&1 || return 1
  addresses="$(getent ahostsv4 "$FIXTURE_DNS_NAME" 2>/dev/null | awk '{ print $1 }')"
  grep -Fxq "$PEER_TUNNEL_IP" <<<"$addresses"
}

test_https() {
  curl -4 --fail --silent --show-error --max-time 8 --output /dev/null "$PROBE_URL"
}

probe_production_platform_network_monitor() (
  local interface="$1"
  local probe_dir="$STATE_DIR/platform-network-monitor-probe"
  local probe_config="$probe_dir/config.toml"
  local probe_iface="nvmp${RANDOM}"
  local probe_pid=""
  cleanup_probe() {
    if [[ -n "$probe_pid" ]]; then
      "$BINARY" stop --config "$probe_config" --timeout-secs 3 --force \
        >/dev/null 2>&1 || true
      kill "$probe_pid" >/dev/null 2>&1 || true
      wait "$probe_pid" >/dev/null 2>&1 || true
    fi
    rm -rf "$probe_dir"
  }
  trap cleanup_probe EXIT

  mkdir -p "$probe_dir"
  chmod 700 "$probe_dir"
  "$BINARY" init --config "$probe_config" --force >/dev/null
  "$BINARY" daemon \
    --paused \
    --config "$probe_config" \
    --iface "$probe_iface" \
    >"$probe_dir/daemon.stdout.log" \
    2>"$probe_dir/daemon.stderr.log" &
  probe_pid="$!"

  local deadline="$((SECONDS + 10))"
  while ((SECONDS < deadline)); do
    if "$BINARY" status --config "$probe_config" --json --discover-secs 0 \
      | jq -e --argjson pid "$probe_pid" '
          .status_source == "daemon"
          and .daemon.running == true
          and .daemon.pid == $pid
        ' >/dev/null 2>&1
    then
      break
    fi
    sleep 0.1
  done
  ((SECONDS < deadline)) \
    || fail "production platform-network monitor probe daemon did not become ready"

  ip link set dev "$interface" down
  sleep 0.1
  ip link set dev "$interface" up
  deadline="$((SECONDS + 3))"
  while ((SECONDS < deadline)); do
    if grep -Fq \
      'daemon: platform network change event; sampling physical route' \
      "$probe_dir/daemon.stderr.log"
    then
      cp "$probe_dir/daemon.stderr.log" "$STATE_DIR/platform-network-monitor-probe.log"
      return 0
    fi
    sleep 0.05
  done
  fail "production daemon did not receive a real Linux netlink link event"
)

assert_same_daemon_ready() {
  local expected_pid="$1"
  local current_status
  [[ -n "$ORIGINAL_NPUB" && -n "$ORIGINAL_TUNNEL_IP" ]] \
    || fail "original daemon identity receipt is missing"
  [[ "$(read_npub)" == "$ORIGINAL_NPUB" ]] \
    || fail "daemon identity npub changed"
  [[ "$("$BINARY" ip --config "$CONFIG")" == "$ORIGINAL_TUNNEL_IP" ]] \
    || fail "daemon tunnel IP changed"
  current_status="$(status_json)"
  jq -e --argjson pid "$expected_pid" --arg rev "$EXPECTED_FIPS_REV" '
    .status_source == "daemon"
    and .daemon.running == true
    and .daemon.pid == $pid
    and .daemon.state.mesh_ready == true
    and .daemon.state.connected_peer_count >= 1
    and (.daemon.state.fips_core_version | endswith("(rev " + $rev + ")"))
  ' <<<"$current_status" >/dev/null \
    && jq -e --arg peer "$PEER_NPUB" '
      (.daemon.state.fips_endpoint_peers // []) as $peers
      | ($peers | length) == 1
        and $peers[0].npub == $peer
    ' <<<"$current_status" >/dev/null
}

assert_secure_dns() {
  resolvectl dns "$TUN_IFACE" | grep -Eq '(^|[[:space:]])127\.0\.0\.1([[:space:]]|$)'
  resolvectl domain "$TUN_IFACE" | grep -Fq '~.'
}

assert_active_exit() {
  local expected_iface="$1"
  local expected_pid="$2"
  local require_fixture="${3:-1}"
  assert_same_daemon_ready "$expected_pid"
  [[ "$(route_dev 1.1.1.1)" == "$WG_IFACE" ]]
  [[ "$(route_dev "$(endpoint_host)")" == "$expected_iface" ]]
  assert_wireguard_endpoint_route "$expected_iface"
  wireguard_handshake_active
  assert_secure_dns
  if [[ "$require_fixture" == "1" ]]; then
    resolve_fixture
  fi
  resolve_name "$(probe_host)"
  test_https
}

wait_initial_ready() {
  local primary_iface="$1"
  local expected_pid="$2"
  local deadline="$((SECONDS + 30))"
  while ((SECONDS < deadline)); do
    if assert_active_exit "$primary_iface" "$expected_pid" 1 \
      && (( $(payload_success_count) > 2 )) \
      && (( $(wireguard_payload_success_count) > 1 )); then
      return 0
    fi
    sleep 0.25
  done
  {
    echo "initial_route=$(route_dev 1.1.1.1 2>/dev/null || echo unavailable)"
    echo "initial_endpoint_route=$(route_dev "$(endpoint_host)" 2>/dev/null || echo unavailable)"
    echo "initial_payload_successes=$(payload_success_count)"
    echo "initial_wireguard_payload_successes=$(wireguard_payload_success_count)"
    echo "initial_rebind_receipts=$(rebind_count)"
    status_summary || true
    resolvectl status "$TUN_IFACE" 2>/dev/null || true
    tail -n 80 "$STATE_DIR/daemon.stderr.log" 2>/dev/null || true
  } >&2
  fail "initial FIPS exit, DNS, HTTPS, and payload did not become ready"
}

observe_recovery() {
  local label="$1"
  local expected_iface="$2"
  local expected_carrier_iface="$3"
  local expected_carrier="$4"
  local expected_pid="$5"
  local probe_before wg_probe_before rebind_before endpoint_starts_before route_usable_at
  local route_usable_monotonic started now elapsed recovered_at recovered_monotonic
  local endpoint_route
  rebind_before="$(rebind_count)"
  endpoint_starts_before="$(endpoint_start_count)"
  [[ "$endpoint_starts_before" == "1" ]] \
    || fail "$label expected exactly one original FIPS endpoint start"

  local carrier_deadline="$((SECONDS + 30))"
  while ((SECONDS < carrier_deadline)); do
    if [[ "$(<"/sys/class/net/$expected_carrier_iface/carrier")" == "$expected_carrier" ]]; then
      break
    fi
    sleep 0.025
  done
  [[ "$(<"/sys/class/net/$expected_carrier_iface/carrier")" == "$expected_carrier" ]] \
    || fail "$label physical carrier did not reach its expected state"

  local route_deadline="$((SECONDS + 15))"
  while ((SECONDS < route_deadline)); do
    if [[ "$(physical_default_route_dev 2>/dev/null || true)" == "$expected_iface" ]]; then
      break
    fi
    sleep 0.025
  done
  [[ "$(physical_default_route_dev 2>/dev/null || true)" == "$expected_iface" ]] \
    || fail "$label physical default route did not become usable within 15s"

  route_usable_at="$(unix_milliseconds)"
  route_usable_monotonic="$(monotonic_milliseconds)"
  probe_before="$(payload_success_count)"
  wg_probe_before="$(wireguard_payload_success_count)"
  started="$route_usable_monotonic"
  while :; do
    now="$(monotonic_milliseconds)"
    elapsed="$((now - started))"
    if ((elapsed > RECOVERY_DEADLINE_MS)); then
      {
        echo "recovery_label=$label"
        echo "expected_interface=$expected_iface"
        echo "last_route=$(route_dev "$(endpoint_host)" 2>/dev/null || echo unavailable)"
        echo "last_physical_default=$(physical_default_route_dev 2>/dev/null || echo unavailable)"
        echo "last_carrier=$(<"/sys/class/net/$expected_carrier_iface/carrier")"
        echo "last_payload_successes=$(payload_success_count)"
        echo "payload_successes_before=$probe_before"
        echo "last_wireguard_payload_successes=$(wireguard_payload_success_count)"
        echo "wireguard_payload_successes_before=$wg_probe_before"
        echo "last_rebind_receipts=$(rebind_count)"
        echo "rebind_receipts_before=$rebind_before"
        echo "route_usable_unix_milliseconds=$route_usable_at"
        echo "route_usable_monotonic_milliseconds=$route_usable_monotonic"
        ip -4 route show
        status_summary || true
        tail -n 120 "$STATE_DIR/daemon.stderr.log" 2>/dev/null || true
      } >&2
      fail "$label payload/route/FIPS rebind exceeded ${RECOVERY_DEADLINE_MS}ms"
    fi
    if [[ "$(route_dev "$(endpoint_host)" 2>/dev/null || true)" == "$expected_iface" ]] \
      && (( $(payload_success_count) > probe_before )) \
      && (( $(wireguard_payload_success_count) > wg_probe_before )) \
      && (( $(rebind_count) == rebind_before + 1 )) \
      && [[ "$(endpoint_start_count)" == "$endpoint_starts_before" ]] \
      && assert_same_daemon_ready "$expected_pid"
    then
      # The final status assertion can perform real daemon IPC. Sample again
      # after every success predicate so a slow final check cannot underreport
      # the enforced recovery duration.
      now="$(monotonic_milliseconds)"
      elapsed="$((now - started))"
      if ((elapsed <= RECOVERY_DEADLINE_MS)); then
        break
      fi
    fi
    sleep 0.025
  done
  [[ "$(endpoint_start_count)" == "$endpoint_starts_before" ]] \
    || fail "$label restarted the FIPS endpoint"
  (( $(rebind_count) == rebind_before + 1 )) \
    || fail "$label did not produce exactly one FIPS carrier rebind"
  ! grep -Eq 'daemon: (restarted|rebuilt) FIPS private mesh on' \
    "$STATE_DIR/daemon.stderr.log" \
    || fail "$label replaced the FIPS endpoint"
  assert_active_exit "$expected_iface" "$expected_pid" 1
  now="$(monotonic_milliseconds)"
  elapsed="$((now - started))"
  ((elapsed <= RECOVERY_DEADLINE_MS)) \
    || fail "$label stable recovery exceeded ${RECOVERY_DEADLINE_MS}ms"
  recovered_at="$(unix_milliseconds)"
  recovered_monotonic="$now"
  endpoint_route="$(ip -j -4 route show exact "$(endpoint_host)/32")"
  jq -cn \
    --argjson recovery_milliseconds "$elapsed" \
    --argjson route_usable_unix_milliseconds "$route_usable_at" \
    --argjson route_usable_monotonic_milliseconds "$route_usable_monotonic" \
    --argjson recovered_unix_milliseconds "$recovered_at" \
    --argjson recovered_monotonic_milliseconds "$recovered_monotonic" \
    --argjson daemon_pid "$expected_pid" \
    --arg physical_interface "$expected_iface" \
    --argjson payload_successes_before "$probe_before" \
    --argjson payload_successes_after "$(payload_success_count)" \
    --argjson wireguard_payload_successes_before "$wg_probe_before" \
    --argjson wireguard_payload_successes_after "$(wireguard_payload_success_count)" \
    --argjson rebind_receipts_before "$rebind_before" \
    --argjson rebind_receipts_after "$(rebind_count)" \
    --argjson endpoint_starts_before "$endpoint_starts_before" \
    --argjson endpoint_starts_after "$(endpoint_start_count)" \
    --arg identity_npub "$ORIGINAL_NPUB" \
    --arg tunnel_ip "$ORIGINAL_TUNNEL_IP" \
    --arg participant_npub "$PEER_NPUB" \
    --argjson wireguard_endpoint_route "$endpoint_route" \
    '{
      recovery_milliseconds: $recovery_milliseconds,
      route_usable_unix_milliseconds: $route_usable_unix_milliseconds,
      route_usable_monotonic_milliseconds: $route_usable_monotonic_milliseconds,
      recovered_unix_milliseconds: $recovered_unix_milliseconds,
      recovered_monotonic_milliseconds: $recovered_monotonic_milliseconds,
      daemon_pid: $daemon_pid,
      physical_interface: $physical_interface,
      payload_successes_before: $payload_successes_before,
      payload_successes_after: $payload_successes_after,
      wireguard_payload_successes_before: $wireguard_payload_successes_before,
      wireguard_payload_successes_after: $wireguard_payload_successes_after,
      rebind_receipts_before: $rebind_receipts_before,
      rebind_receipts_after: $rebind_receipts_after,
      endpoint_starts_before: $endpoint_starts_before,
      endpoint_starts_after: $endpoint_starts_after,
      identity_npub: $identity_npub,
      tunnel_ip: $tunnel_ip,
      participant_npub: $participant_npub,
      wireguard_endpoint_route: $wireguard_endpoint_route
    }' >"$(marker_path "$label.receipt.json")"
}

run_dns_case() {
  local name="$1"
  local lookup_name="$2"
  local expected_pid="$3"
  local expected_iface="$4"
  shift 4
  wait_for_marker "dns-$name.go"
  "$BINARY" set --config "$CONFIG" "$@" >/dev/null

  local deadline="$((SECONDS + 30))"
  while ((SECONDS < deadline)); do
    if [[ "$lookup_name" == "$FIXTURE_DNS_NAME" ]]; then
      resolve_fixture && assert_active_exit "$expected_iface" "$expected_pid" 0 \
        && break
    elif resolve_name "$lookup_name" \
      && assert_active_exit "$expected_iface" "$expected_pid" 0
    then
      break
    fi
    sleep 0.25
  done
  ((SECONDS < deadline)) || fail "real $name DNS lookup did not succeed"
  write_marker "dns-$name.receipt" "$lookup_name"
}

stop_pid_file() {
  local path="$1"
  [[ -s "$path" ]] || return 0
  local pid
  pid="$(<"$path")"
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 0
  kill "$pid" >/dev/null 2>&1 || true
  for _ in $(seq 1 50); do
    kill -0 "$pid" >/dev/null 2>&1 || return 0
    sleep 0.1
  done
  kill -KILL "$pid" >/dev/null 2>&1 || true
}

restore_network() {
  local failed=0
  if [[ -x "$BINARY" && -e "$CONFIG" ]]; then
    "$BINARY" stop --config "$CONFIG" --timeout-secs 5 --force >/dev/null 2>&1 \
      || failed=1
  fi
  stop_pid_file "$STATE_DIR/probe.pid"
  stop_pid_file "$STATE_DIR/wireguard-probe.pid"
  stop_pid_file "$STATE_DIR/runner-daemon.pid"
  if [[ -s "$SECONDARY_PROFILE_UUID_FILE" ]]; then
    nmcli connection delete uuid "$(<"$SECONDARY_PROFILE_UUID_FILE")" \
      >/dev/null 2>&1 || true
  elif [[ -s "$SECONDARY_PROFILE_NAME_FILE" ]]; then
    nmcli connection delete "$(<"$SECONDARY_PROFILE_NAME_FILE")" \
      >/dev/null 2>&1 || true
  fi
  if [[ -n "$PRIMARY_MAC" ]]; then
    local primary_iface
    primary_iface="$(iface_for_mac "$PRIMARY_MAC" | head -n1)"
    [[ -n "$primary_iface" ]] || failed=1
    [[ "$(route_dev 1.1.1.1 2>/dev/null || true)" == "$primary_iface" ]] || failed=1
    resolve_name "$(probe_host)" || failed=1
    test_https || failed=1
  fi
  return "$failed"
}

emergency_restore_network() {
  if restore_network; then
    return 0
  fi
  write_marker "emergency-repair-invoked"
  if [[ -x "$BINARY" && -e "$CONFIG" ]]; then
    "$BINARY" repair-network --config "$CONFIG" >/dev/null 2>&1 || true
  fi
  return 1
}

finish_run_cleanup() {
  local status="$?"
  trap - EXIT
  restore_network || status=1
  exit "$status"
}

initialize() {
  require_root
  for value in \
    "$PRIMARY_MAC" "$SECONDARY_MAC" "$SECONDARY_ADDRESS" \
    "$SECONDARY_GATEWAY" "$NETWORK_ID"
  do
    [[ -n "$value" ]] || fail "Initialize is missing a required argument"
  done
  [[ -x "$BINARY" ]] || fail "candidate Linux nvpn binary is missing"
  command -v nmcli >/dev/null \
    || fail "NetworkManager CLI is required for the transient real NIC"
  command -v wg >/dev/null \
    || fail "WireGuard tools are required for the real upstream profile"
  if pgrep -x nvpn >/dev/null; then
    fail "another nvpn process is already running before the isolated gate"
  fi
  local primary_iface secondary_iface primary_metric secondary_metric
  local primary_gateway primary_address
  local profile_name profile_uuid uuid
  local -a secondary_connections
  primary_iface="$(require_iface_for_mac "$PRIMARY_MAC")"
  secondary_iface="$(require_iface_for_mac "$SECONDARY_MAC")"
  mapfile -t secondary_connections < <(
    nmcli -t -f UUID,DEVICE connection show --active \
      | awk -F: -v iface="$secondary_iface" '$2 == iface { print $1 }'
  )
  for uuid in "${secondary_connections[@]}"; do
    nmcli connection delete uuid "$uuid" >/dev/null
  done
  nmcli device set "$secondary_iface" managed no
  primary_metric="$(
    ip -4 route show default dev "$primary_iface" \
      | awk '{
          for (i = 1; i <= NF; i++) if ($i == "metric") { print $(i + 1); exit }
          print 0
        }' \
      | head -n1
  )"
  [[ "$primary_metric" =~ ^[0-9]+$ ]] || fail "could not read the primary route metric"
  primary_gateway="$(
    ip -j -4 route show default dev "$primary_iface" \
      | jq -er 'sort_by(.metric // 0) | .[0].gateway'
  )"
  primary_address="$(
    ip -j -4 address show dev "$primary_iface" scope global \
      | jq -er '.[].addr_info[]
          | select(.family == "inet" and .scope == "global")
          | .local' \
      | head -n1
  )"
  secondary_metric="$((primary_metric + 500))"

  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"
  restore_network
  rm -rf "$STATE_DIR"
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"

  # Exercise the production netlink monitor before installing the disposable
  # NetworkManager profile. The gate itself then uses the ordinary Linux
  # network-management path for the replacement underlay.
  probe_production_platform_network_monitor "$secondary_iface"

  profile_name="nvpn-underlay-$secondary_iface-$$"
  printf '%s\n' "$profile_name" >"$SECONDARY_PROFILE_NAME_FILE"
  nmcli connection add \
    type ethernet \
    ifname "$secondary_iface" \
    con-name "$profile_name" \
    connection.autoconnect no \
    ipv4.method manual \
    ipv4.addresses "$SECONDARY_ADDRESS/$SECONDARY_PREFIX" \
    ipv4.gateway "$SECONDARY_GATEWAY" \
    ipv4.route-metric "$secondary_metric" \
    ipv4.ignore-auto-dns yes \
    ipv6.method disabled \
    >/dev/null
  profile_uuid="$(nmcli -g connection.uuid connection show "$profile_name")"
  [[ -n "$profile_uuid" ]] || fail "transient NetworkManager profile has no UUID"
  printf '%s\n' "$profile_uuid" >"$SECONDARY_PROFILE_UUID_FILE"
  nmcli device set "$secondary_iface" managed yes
  nmcli connection up uuid "$profile_uuid" >/dev/null

  "$BINARY" init --config "$CONFIG" --force >/dev/null
  "$BINARY" set --config "$CONFIG" --network-id "$NETWORK_ID" >/dev/null
  umask 077
  wg genkey >"$WG_PRIVATE_KEY_FILE"
  jq -cn \
    --arg npub "$(read_npub)" \
    --arg tunnel_ip "$("$BINARY" ip --config "$CONFIG")" \
    --arg primary_interface "$primary_iface" \
    --arg primary_gateway "$primary_gateway" \
    --arg primary_address "$primary_address" \
    --arg secondary_interface "$secondary_iface" \
    --arg secondary_profile_uuid "$profile_uuid" \
    --arg wireguard_public_key "$(wg pubkey <"$WG_PRIVATE_KEY_FILE")" \
    --argjson primary_metric "$primary_metric" \
    --argjson secondary_metric "$secondary_metric" \
    '{
      npub: $npub,
      tunnel_ip: $tunnel_ip,
      primary_interface: $primary_interface,
      primary_gateway: $primary_gateway,
      primary_address: $primary_address,
      secondary_interface: $secondary_interface,
      secondary_profile_uuid: $secondary_profile_uuid,
      wireguard_public_key: $wireguard_public_key,
      primary_metric: $primary_metric,
      secondary_metric: $secondary_metric
    }' | tee "$STATE_DIR/identity.json"
}

assert_secondary_underlay_ready() {
  local interface="$1"
  local profile_uuid active_uuid
  [[ -s "$SECONDARY_PROFILE_UUID_FILE" ]] \
    || fail "secondary NetworkManager profile receipt is missing"
  profile_uuid="$(<"$SECONDARY_PROFILE_UUID_FILE")"
  active_uuid="$(
    nmcli -t -f UUID,DEVICE connection show --active \
      | awk -F: -v iface="$interface" '$2 == iface { print $1 }'
  )"
  [[ "$active_uuid" == "$profile_uuid" ]] \
    || fail "secondary NetworkManager profile is not the active connection"
  [[ "$(<"/sys/class/net/$interface/carrier")" == "1" ]] \
    || fail "secondary physical carrier is not usable before the host cut"
  ip -j -4 address show dev "$interface" scope global \
    | jq -e --arg address "$SECONDARY_ADDRESS" --argjson prefix "$SECONDARY_PREFIX" '
        any(.[].addr_info[]?;
          .local == $address and .prefixlen == $prefix and .scope == "global"
        )
      ' >/dev/null \
    || fail "secondary global IPv4 address is missing before the host cut"
  ip -j -4 route show table main default dev "$interface" \
    | jq -e --arg gateway "$SECONDARY_GATEWAY" '
        any(.[]; .gateway == $gateway)
      ' >/dev/null \
    || fail "secondary default route is missing before the host cut"
  jq -cn \
    --arg interface "$interface" \
    --arg profile_uuid "$profile_uuid" \
    --arg address "$SECONDARY_ADDRESS/$SECONDARY_PREFIX" \
    --arg gateway "$SECONDARY_GATEWAY" \
    '{
      interface: $interface,
      profile_uuid: $profile_uuid,
      address: $address,
      gateway: $gateway,
      carrier: true,
      active_profile: true,
      default_route: true
    }' >"$STATE_DIR/secondary-underlay-ready.json"
}

run_gate() {
  require_root
  for value in \
    "$PRIMARY_MAC" "$SECONDARY_MAC" "$SECONDARY_ADDRESS" "$SECONDARY_GATEWAY" \
    "$NETWORK_ID" "$PEER_NPUB" \
    "$PEER_ENDPOINT" "$PEER_TUNNEL_IP" "$EXPECTED_FIPS_REV" \
    "$WG_PEER_PUBLIC_KEY" "$WG_ENDPOINT" "$WG_CLIENT_ADDRESS"
  do
    [[ -n "$value" ]] || fail "Run is missing a required peer/underlay argument"
  done
  local primary_iface secondary_iface daemon_process daemon_receipt
  primary_iface="$(require_iface_for_mac "$PRIMARY_MAC")"
  secondary_iface="$(require_iface_for_mac "$SECONDARY_MAC")"
  trap finish_run_cleanup EXIT
  [[ -s "$WG_PRIVATE_KEY_FILE" ]] || fail "WireGuard client private key is missing"
  umask 077
  {
    printf '[Interface]\n'
    printf 'PrivateKey = %s\n' "$(<"$WG_PRIVATE_KEY_FILE")"
    printf 'Address = %s\n' "$WG_CLIENT_ADDRESS"
    printf 'DNS = 1.1.1.1\n\n'
    printf '[Peer]\n'
    printf 'PublicKey = %s\n' "$WG_PEER_PUBLIC_KEY"
    printf 'AllowedIPs = 0.0.0.0/0\n'
    printf 'Endpoint = %s\n' "$WG_ENDPOINT"
    printf 'PersistentKeepalive = 1\n'
  } >"$WG_CONFIG_FILE"

  "$BINARY" set \
    --config "$CONFIG" \
    --network-id "$NETWORK_ID" \
    --participant "$PEER_NPUB" \
    --listen-port "$LISTEN_PORT" \
    --fips-advertise-public-endpoint false \
    --fips-nostr-discovery-enabled false \
    --lan-discovery-enabled false \
    --fips-webrtc-enabled false \
    --fips-bootstrap-enabled false \
    --fips-peer-endpoint "${PEER_NPUB}=${PEER_ENDPOINT}" \
    --wireguard-exit-config-file "$WG_CONFIG_FILE" \
    --wireguard-exit-enabled true \
    --exit-node-leak-protection true \
    --exit-dns-mode through_exit \
    --exit-dns-through-exit-servers "$PEER_TUNNEL_IP" \
    --autoconnect true \
    >/dev/null
  ORIGINAL_NPUB="$(read_npub)"
  ORIGINAL_TUNNEL_IP="$("$BINARY" ip --config "$CONFIG")"
  [[ -n "$ORIGINAL_NPUB" && -n "$ORIGINAL_TUNNEL_IP" ]] \
    || fail "failed to pin original daemon identity"

  env RUST_LOG=info "$BINARY" daemon \
    --config "$CONFIG" \
    --iface "$TUN_IFACE" \
    --mesh-refresh-interval-secs 2 \
    >"$STATE_DIR/daemon.stdout.log" \
    2>"$STATE_DIR/daemon.stderr.log" &
  daemon_process="$!"
  printf '%s\n' "$daemon_process" >"$STATE_DIR/runner-daemon.pid"

  local deadline="$((SECONDS + 30))"
  while ((SECONDS < deadline)); do
    daemon_receipt="$(daemon_pid 2>/dev/null || true)"
    [[ "$daemon_receipt" == "$daemon_process" ]] && break
    sleep 0.1
  done
  [[ "$daemon_receipt" == "$daemon_process" ]] \
    || fail "production daemon receipt did not match its process"

  ping -D -n -i 0.1 -W 1 "$PEER_TUNNEL_IP" \
    >"$STATE_DIR/payload.log" 2>&1 &
  printf '%s\n' "$!" >"$STATE_DIR/probe.pid"
  : >"$STATE_DIR/wireguard-payload.log"
  wireguard_payload_loop &
  printf '%s\n' "$!" >"$STATE_DIR/wireguard-probe.pid"
  wait_initial_ready "$primary_iface" "$daemon_process"
  assert_secondary_underlay_ready "$secondary_iface"
  write_marker ready "$daemon_process"

  wait_for_marker arm-secondary
  write_marker armed-secondary
  observe_recovery secondary "$secondary_iface" "$primary_iface" 0 "$daemon_process"

  wait_for_marker arm-primary
  write_marker armed-primary
  observe_recovery primary "$primary_iface" "$primary_iface" 1 "$daemon_process"

  run_dns_case automatic example.com "$daemon_process" "$primary_iface" \
    --exit-dns-mode automatic
  run_dns_case cloudflare www.cloudflare.com "$daemon_process" "$primary_iface" \
    --exit-dns-mode encrypted \
    --exit-dns-doh-provider cloudflare
  run_dns_case quad9 www.quad9.net "$daemon_process" "$primary_iface" \
    --exit-dns-mode encrypted \
    --exit-dns-doh-provider quad9
  run_dns_case custom iana.org "$daemon_process" "$primary_iface" \
    --exit-dns-mode encrypted \
    --exit-dns-doh-provider custom \
    --exit-dns-custom-doh-url https://cloudflare-dns.com/dns-query \
    --exit-dns-custom-doh-bootstrap-ips 1.1.1.1,1.0.0.1
  run_dns_case through-exit "$FIXTURE_DNS_NAME" "$daemon_process" "$primary_iface" \
    --exit-dns-mode through_exit \
    --exit-dns-through-exit-servers "$PEER_TUNNEL_IP"

  wait_for_marker select-direct
  "$BINARY" set \
    --config "$CONFIG" \
    --wireguard-exit-enabled false \
    --exit-dns-mode automatic \
    >/dev/null
  deadline="$((SECONDS + 30))"
  while ((SECONDS < deadline)); do
    if [[ "$(route_dev 1.1.1.1 2>/dev/null || true)" == "$primary_iface" ]] \
      && assert_same_daemon_ready "$daemon_process" \
      && resolve_name "$(probe_host)" \
      && test_https \
      && ! ip link show dev "$WG_IFACE" >/dev/null 2>&1 \
      && ! ip -4 rule show \
        | grep -Eq '^10888:.*from .* lookup 51888$' \
      && [[ -z "$(ip -4 route show exact "$(endpoint_host)/32")" ]]
    then
      break
    fi
    sleep 0.25
  done
  ((SECONDS < deadline)) || fail "native Direct route, DNS, and HTTPS did not restore"
  if resolvectl dns "$TUN_IFACE" 2>/dev/null | grep -Fq 127.0.0.1; then
    fail "secure exit DNS remained installed after selecting Direct"
  fi
  if ip -4 route show table 51888 >"$STATE_DIR/direct-policy-table.txt" 2>&1 \
    && grep -q . "$STATE_DIR/direct-policy-table.txt"
  then
    fail "WireGuard policy table retained routes after selecting Direct"
  elif ! grep -Fq 'FIB table does not exist' "$STATE_DIR/direct-policy-table.txt" \
    && grep -q . "$STATE_DIR/direct-policy-table.txt"
  then
    fail "WireGuard policy-table cleanup returned an unexpected error"
  fi
  jq -cn \
    --argjson daemon_pid "$daemon_process" \
    --arg physical_interface "$primary_iface" \
    --arg identity_npub "$ORIGINAL_NPUB" \
    --arg tunnel_ip "$ORIGINAL_TUNNEL_IP" \
    --arg participant_npub "$PEER_NPUB" \
    --argjson endpoint_start_count "$(endpoint_start_count)" \
    '{
      daemon_pid: $daemon_pid,
      physical_interface: $physical_interface,
      identity_npub: $identity_npub,
      tunnel_ip: $tunnel_ip,
      participant_npub: $participant_npub,
      endpoint_start_count: $endpoint_start_count,
      wireguard_interface_removed: true,
      wireguard_endpoint_route_removed: true,
      wireguard_policy_rule_removed: true,
      wireguard_policy_table_empty: true,
      public_dns: true,
      verified_https: true
    }' >"$(marker_path direct.receipt.json)"
  write_marker done
}

cleanup_gate() {
  require_root
  mkdir -p "$STATE_DIR"
  emergency_restore_network
}

case "$ACTION" in
  initialize) initialize ;;
  run) run_gate ;;
  cleanup-fault)
    require_root
    exec "$(dirname "$0")/desktop-linux-cleanup-fault-e2e.sh"
    ;;
  cleanup) cleanup_gate ;;
  *) echo "usage: $0 {initialize|run|cleanup-fault|cleanup}" >&2; exit 2 ;;
esac
