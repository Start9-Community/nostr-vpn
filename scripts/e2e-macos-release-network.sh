#!/usr/bin/env bash
# Production-path macOS Release network gate, executed only in macos-utm.
# The controller imports the exact host-built package and supplies a real
# remote WireGuard fixture. This guest runner never builds or signs anything.
set -euo pipefail

ACTION="${1:-${NVPN_MACOS_NETWORK_ACTION:-}}"
NVPN_BIN="${NVPN_E2E_BINARY:-}"
STATE_DIR="${NVPN_MACOS_NETWORK_STATE_DIR:-}"
CONFIG="${NVPN_E2E_CONFIG:-}"
WG_CONFIG="${NVPN_WG_EXIT_CONFIG_FILE:-}"
RESULT_DIR="$STATE_DIR/results"
ENDPOINT_HOST="${NVPN_MACOS_WG_ENDPOINT_HOST:-}"
ENDPOINT_FAMILY="${NVPN_MACOS_WG_ENDPOINT_FAMILY:-}"
TUNNEL_SERVER_IP="${NVPN_MACOS_WG_SERVER_IP:-}"
DNS_PROBE_HOST="${NVPN_MACOS_DNS_PROBE_HOST:-}"
DNS_EXPECTED_IP="${NVPN_MACOS_DNS_EXPECTED_IP:-}"
DNS_LABEL="${NVPN_MACOS_DNS_LABEL:-}"
DNS_MODE="${NVPN_MACOS_DNS_MODE:-}"
DNS_PROVIDER="${NVPN_MACOS_DNS_PROVIDER:-cloudflare}"
DNS_CUSTOM_URL="${NVPN_MACOS_DNS_CUSTOM_URL:-}"
DNS_BOOTSTRAP_IPS="${NVPN_MACOS_DNS_BOOTSTRAP_IPS:-}"
DNS_THROUGH_SERVERS="${NVPN_MACOS_DNS_THROUGH_SERVERS:-}"
CAPTURED_PROBE_URL="${NVPN_MACOS_CAPTURED_PROBE_URL:-}"
CAPTURED_PROBE_TOKEN="${NVPN_MACOS_CAPTURED_PROBE_TOKEN:-}"
INTERNET_URL="${NVPN_MACOS_INTERNET_URL:-https://example.com/}"
SOURCE_IP_URL="${NVPN_MACOS_SOURCE_IP_URL:-https://api.ipify.org}"
EXPECTED_EXIT_SOURCE_IP="${NVPN_MACOS_EXPECTED_EXIT_SOURCE_IP:-}"
PRIMARY_SERVICE="${NVPN_MACOS_PRIMARY_NETWORK_SERVICE:-Ethernet}"
SECONDARY_SERVICE="${NVPN_MACOS_SECONDARY_NETWORK_SERVICE:-Roaming Underlay}"
PRIMARY_IFACE="${NVPN_MACOS_PRIMARY_INTERFACE:-en0}"
SECONDARY_IFACE="${NVPN_MACOS_SECONDARY_INTERFACE:-en2}"
WAIT_SECS="${NVPN_MACOS_NETWORK_WAIT_SECS:-30}"
RECOVERY_DEADLINE_MS="${NVPN_MACOS_UNDERLAY_RECOVERY_DEADLINE_MS:-4000}"
SECURE_RESOLVER="/etc/resolver/nvpn-secure-dns"
MAGIC_RESOLVER="/etc/resolver/nvpn"

truthy() {
  case "${1:-}" in
    1|true|TRUE|True|yes|YES|Yes|on|ON|On) return 0 ;;
    *) return 1 ;;
  esac
}

fail() {
  echo "macOS Release network gate failed: $*" >&2
  return 1
}

validate_inputs() {
  [[ "$(uname -s)" == "Darwin" ]] || fail "guest is not macOS"
  truthy "${NVPN_MACOS_VM_IMPORT_ONLY:-0}" \
    || fail "NVPN_MACOS_VM_IMPORT_ONLY=1 is required"
  [[ -n "$NVPN_BIN" && -x "$NVPN_BIN" ]] || fail "imported nvpn is missing"
  codesign --verify --strict "$NVPN_BIN"
  case "$STATE_DIR" in
    /tmp/nvpn-macos-release-network.*) ;;
    *) fail "state directory is outside the dedicated temporary path" ;;
  esac
  [[ "$CONFIG" == "$STATE_DIR/config.toml" ]] \
    || fail "config is outside the dedicated state directory"
  [[ "$WG_CONFIG" == "$STATE_DIR/client.conf" && -r "$WG_CONFIG" ]] \
    || fail "WireGuard config is outside the dedicated state directory"
  [[ -n "$ENDPOINT_HOST" \
    && -n "$TUNNEL_SERVER_IP" \
    && -n "$CAPTURED_PROBE_URL" \
    && -n "$CAPTURED_PROBE_TOKEN" \
    && -n "$EXPECTED_EXIT_SOURCE_IP" ]] \
    || fail "real fixture inputs are incomplete"
  case "$ENDPOINT_FAMILY" in
    ipv4|ipv6) ;;
    *) fail "fixture endpoint family must be ipv4 or ipv6" ;;
  esac
  [[ "$WAIT_SECS" =~ ^[1-9][0-9]*$ && "$WAIT_SECS" -le 45 ]] \
    || fail "network readiness timeout must be 1-45 seconds"
  [[ "$RECOVERY_DEADLINE_MS" =~ ^[1-9][0-9]*$ \
    && "$RECOVERY_DEADLINE_MS" -le 4000 ]] \
    || fail "underlay recovery deadline must be at most four seconds"
}

nvpn() {
  "$NVPN_BIN" "$@"
}

privileged_nvpn() {
  sudo -n "$NVPN_BIN" "$@"
}

route_value() {
  local target="$1" field="$2"
  /sbin/route -n get "$target" 2>/dev/null \
    | awk -v field="$field" '$1 == field ":" { print $2; exit }'
}

endpoint_route_value() {
  local field="$1"
  if [[ "$ENDPOINT_FAMILY" == "ipv6" ]]; then
    /sbin/route -n get -inet6 "$ENDPOINT_HOST" 2>/dev/null \
      | awk -v field="$field" '$1 == field ":" { print $2; exit }'
  else
    route_value "$ENDPOINT_HOST" "$field"
  fi
}

endpoint_route_interface() {
  endpoint_route_value interface
}

split_default_interface() {
  local target="$1" mask
  mask="$(route_value "$target" mask)"
  [[ "$mask" == "128.0.0.0" ]] || return 1
  route_value "$target" interface
}

wireguard_interface() {
  local low high
  low="$(split_default_interface 1.0.0.1)" || return 1
  high="$(split_default_interface 129.0.0.1)" || return 1
  [[ -n "$low" && "$low" == "$high" && "$low" == utun* ]] || return 1
  printf '%s\n' "$low"
}

secure_dns_owned() {
  [[ -f "$SECURE_RESOLVER" && -f "$MAGIC_RESOLVER" ]] \
    && grep -Fq 'Managed by nvpn' "$SECURE_RESOLVER" \
    && grep -Fq 'nameserver 127.0.0.1' "$SECURE_RESOLVER" \
    && /usr/sbin/scutil --dns 2>/dev/null \
      | grep -Eq 'nameserver\\[[0-9]+\\][[:space:]]*:[[:space:]]*127\\.0\\.0\\.1'
}

resolver_files_absent() {
  [[ ! -e "$SECURE_RESOLVER" && ! -e "$MAGIC_RESOLVER" ]]
}

flush_dns_cache() {
  /usr/bin/dscacheutil -flushcache >/dev/null 2>&1 || true
}

dns_query_works() {
  local output
  [[ -n "$DNS_PROBE_HOST" ]] || return 1
  flush_dns_cache
  output="$(/usr/bin/dscacheutil -q host -a name "$DNS_PROBE_HOST" 2>/dev/null)" \
    || return 1
  grep -Eq '(^|[[:space:]])(ip|ipv6)_address:' <<<"$output" || return 1
  if [[ -n "$DNS_EXPECTED_IP" ]]; then
    grep -Fq "ip_address: $DNS_EXPECTED_IP" <<<"$output" || return 1
  fi
  printf '%s\n' "$output" >"$RESULT_DIR/dns-$DNS_LABEL.txt"
}

https_works() {
  curl -4fsS --max-time 8 "$INTERNET_URL" >/dev/null
}

captured_probe_works() {
  local payload
  payload="$(curl -4fsS --max-time 5 "$CAPTURED_PROBE_URL")" || return 1
  grep -Fq "$CAPTURED_PROBE_TOKEN" <<<"$payload"
}

source_ip() {
  curl -4fsS --max-time 8 "$SOURCE_IP_URL" | tr -d '[:space:]'
}

exit_source_is_expected() {
  [[ "$(source_ip)" == "$EXPECTED_EXIT_SOURCE_IP" ]]
}

wireguard_routes_live() {
  local interface
  interface="$(wireguard_interface)" || return 1
  [[ "$(endpoint_route_interface)" == "$PRIMARY_IFACE" \
    || "$(endpoint_route_interface)" == "$SECONDARY_IFACE" ]] \
    && secure_dns_owned \
    && captured_probe_works \
    && https_works \
    && exit_source_is_expected
}

wait_until() {
  local description="$1"
  shift
  local attempts=$((WAIT_SECS * 5)) ignored
  for ignored in $(seq 1 "$attempts"); do
    if "$@"; then
      return 0
    fi
    sleep 0.2
  done
  fail "timed out waiting for $description"
}

service_state() {
  /usr/sbin/networksetup -getnetworkserviceenabled "$1"
}

set_service_state() {
  local service="$1" state="$2"
  case "$state" in
    Enabled) sudo -n /usr/sbin/networksetup -setnetworkserviceenabled "$service" on ;;
    Disabled) sudo -n /usr/sbin/networksetup -setnetworkserviceenabled "$service" off ;;
    *) fail "invalid saved state for $service" ;;
  esac
}

monotonic_ms() {
  /usr/bin/python3 -c 'import time; print(int(time.monotonic() * 1000))'
}

rebind_count() {
  grep -Fc 'FIPS underlay carrier(s) rebound' "$STATE_DIR/daemon.log" 2>/dev/null \
    || true
}

runtime_wireguard_state_is() {
  local expected_enabled="$1" expected_running="$2" status_file
  status_file="$STATE_DIR/status-$expected_enabled-$expected_running.json"
  nvpn status --config "$CONFIG" --json >"$status_file" || return 1
  /usr/bin/python3 - "$status_file" "$expected_enabled" "$expected_running" <<'PY'
import json
import sys

path, expected_enabled, expected_running = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    status = json.load(handle)
if status.get("wireguard_exit", {}).get("enabled") is (
    expected_enabled == "true"
) and status.get("daemon", {}).get("running") is (
    expected_running == "true"
):
    raise SystemExit(0)
raise SystemExit(1)
PY
}

assert_single_owned_daemon() {
  local pid
  pid="$(tr -d '[:space:]' <"$STATE_DIR/daemon.pid" 2>/dev/null || true)"
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  [[ "$(pgrep -x nvpn | wc -l | tr -d '[:space:]')" == "1" ]]
}

snapshot_direct_state() {
  local direct_iface direct_gateway direct_source
  direct_iface="$(route_value default interface)"
  direct_gateway="$(route_value default gateway)"
  [[ "$direct_iface" == "$PRIMARY_IFACE" \
    && -n "$direct_gateway" \
    && "$direct_gateway" != link#* ]] \
    || fail "primary service does not own the initial Direct route"
  [[ "$(service_state "$PRIMARY_SERVICE")" == "Enabled" \
    && "$(service_state "$SECONDARY_SERVICE")" == "Enabled" ]] \
    || fail "both guest underlay services must start enabled"
  [[ "$(endpoint_route_interface)" == "$PRIMARY_IFACE" ]] \
    || fail "fixture endpoint does not initially use the primary underlay"
  resolver_files_absent \
    || fail "a stale nvpn resolver is installed before the gate"
  dns_query_works || fail "Direct DNS failed before the gate"
  https_works || fail "Direct HTTPS failed before the gate"
  direct_source="$(source_ip)"
  [[ -n "$direct_source" ]] || fail "Direct source-IP probe failed"

  printf '%s\n' "$direct_iface" >"$STATE_DIR/direct-interface"
  printf '%s\n' "$direct_gateway" >"$STATE_DIR/direct-gateway"
  printf '%s\n' "$direct_source" >"$STATE_DIR/direct-source-ip"
  service_state "$PRIMARY_SERVICE" >"$STATE_DIR/primary-service-state"
  service_state "$SECONDARY_SERVICE" >"$STATE_DIR/secondary-service-state"
  /usr/sbin/scutil --dns >"$STATE_DIR/direct-scutil-dns"
  /usr/sbin/networksetup -getdnsservers "$PRIMARY_SERVICE" \
    >"$STATE_DIR/direct-primary-dns"
  /usr/sbin/networksetup -getdnsservers "$SECONDARY_SERVICE" \
    >"$STATE_DIR/direct-secondary-dns"
}

prepare_gate() {
  mkdir -p "$RESULT_DIR"
  chmod 700 "$STATE_DIR"
  if pgrep -x nvpn >/dev/null 2>&1; then
    fail "another nvpn process is already running in macos-utm"
  fi
  snapshot_direct_state
  nvpn init --config "$CONFIG" --force
  nvpn set --config "$CONFIG" \
    --wireguard-exit-config-file "$WG_CONFIG" \
    --wireguard-exit-enabled true \
    --exit-dns-mode automatic
  privileged_nvpn start --config "$CONFIG" --connect --daemon \
    >"$RESULT_DIR/daemon-start.txt"
  wait_until "the production WireGuard route, DNS, HTTPS, and source IP" \
    wireguard_routes_live
  wait_until "the daemon runtime/status WireGuard state" \
    runtime_wireguard_state_is true true
  [[ -s "$STATE_DIR/daemon.log" ]] \
    || fail "the owned daemon did not write its config-scoped log"
  assert_single_owned_daemon || fail "the gate does not own exactly one daemon"
  wireguard_interface >"$STATE_DIR/wireguard-interface"
  rebind_count >"$STATE_DIR/rebind-baseline"
  {
    printf 'direct_interface=%s\n' "$(cat "$STATE_DIR/direct-interface")"
    printf 'wireguard_interface=%s\n' "$(cat "$STATE_DIR/wireguard-interface")"
    printf 'endpoint_route_interface=%s\n' "$(endpoint_route_interface)"
    printf 'exit_source_ip=%s\n' "$(source_ip)"
  } >"$RESULT_DIR/prepare.txt"
  echo "MACOS_RELEASE_NETWORK_PREPARED"
}

set_dns_case() {
  [[ -n "$DNS_LABEL" && -n "$DNS_MODE" && -n "$DNS_PROBE_HOST" ]] \
    || fail "DNS case inputs are incomplete"
  nvpn set --config "$CONFIG" \
    --exit-dns-mode "$DNS_MODE" \
    --exit-dns-doh-provider "$DNS_PROVIDER" \
    --exit-dns-custom-doh-url "$DNS_CUSTOM_URL" \
    --exit-dns-custom-doh-bootstrap-ips "$DNS_BOOTSTRAP_IPS" \
    --exit-dns-through-exit-servers "$DNS_THROUGH_SERVERS"
  wait_until "$DNS_LABEL production resolver" dns_case_live
  {
    printf 'label=%s\n' "$DNS_LABEL"
    printf 'mode=%s\n' "$DNS_MODE"
    printf 'provider=%s\n' "$DNS_PROVIDER"
    printf 'wireguard_interface=%s\n' "$(wireguard_interface)"
    printf 'endpoint_route_interface=%s\n' "$(endpoint_route_interface)"
    printf 'exit_source_ip=%s\n' "$(source_ip)"
  } >"$RESULT_DIR/dns-$DNS_LABEL.receipt"
  echo "MACOS_RELEASE_NETWORK_DNS_OK=$DNS_LABEL"
}

dns_case_live() {
  wireguard_routes_live \
    && dns_query_works
}

payload_loop() {
  local now payload
  while true; do
    now="$(monotonic_ms)"
    payload="$(curl -4fsS --max-time 1 "$CAPTURED_PROBE_URL" 2>/dev/null || true)"
    if grep -Fq "$CAPTURED_PROBE_TOKEN" <<<"$payload"; then
      printf '%s\t%s\n' "$now" "$CAPTURED_PROBE_TOKEN"
    fi
    sleep 0.1
  done
}

payload_after() {
  local lower_bound_ms="$1"
  awk -F '\t' -v lower="$lower_bound_ms" -v token="$CAPTURED_PROBE_TOKEN" \
    '$1 >= lower && $2 == token { found=1 } END { exit found ? 0 : 1 }' \
    "$STATE_DIR/underlay-payload.tsv"
}

underlay_recovered() {
  local expected_iface="$1" requested_ms="$2" expected_rebind="$3"
  [[ "$(endpoint_route_interface)" == "$expected_iface" ]] \
    && wireguard_interface >/dev/null \
    && payload_after "$requested_ms" \
    && [[ "$(rebind_count)" == "$expected_rebind" ]]
}

wait_for_underlay_recovery() {
  local label="$1" expected_iface="$2" requested_ms="$3" expected_rebind="$4"
  local now elapsed
  while true; do
    if underlay_recovered "$expected_iface" "$requested_ms" "$expected_rebind"; then
      now="$(monotonic_ms)"
      elapsed=$((now - requested_ms))
      if (( elapsed < 0 || elapsed > RECOVERY_DEADLINE_MS )); then
        fail "$label recovered in ${elapsed}ms (limit ${RECOVERY_DEADLINE_MS}ms)"
      fi
      printf '%s\n' "$elapsed"
      return 0
    fi
    now="$(monotonic_ms)"
    if (( now - requested_ms > RECOVERY_DEADLINE_MS )); then
      fail "$label did not restore route, payload, and one carrier rebind in ${RECOVERY_DEADLINE_MS}ms"
    fi
    sleep 0.1
  done
}

run_underlay_gate() {
  local payload_pid baseline first_requested first_elapsed
  local second_requested second_elapsed
  baseline="$(tr -d '[:space:]' <"$STATE_DIR/rebind-baseline")"
  [[ "$baseline" =~ ^[0-9]+$ ]] || fail "invalid carrier-rebind baseline"
  : >"$STATE_DIR/underlay-payload.tsv"
  payload_loop >>"$STATE_DIR/underlay-payload.tsv" 2>&1 &
  payload_pid="$!"
  printf '%s\n' "$payload_pid" >"$STATE_DIR/payload.pid"
  sleep 0.5

  first_requested="$(monotonic_ms)"
  sudo -n /usr/sbin/networksetup \
    -setnetworkserviceenabled "$PRIMARY_SERVICE" off
  first_elapsed="$(
    wait_for_underlay_recovery \
      primary-to-secondary "$SECONDARY_IFACE" "$first_requested" "$((baseline + 1))"
  )"
  dns_query_works || fail "DNS failed after the secondary underlay recovered"
  captured_probe_works && https_works && exit_source_is_expected \
    || fail "exit traffic failed after the secondary underlay recovered"

  second_requested="$(monotonic_ms)"
  sudo -n /usr/sbin/networksetup \
    -setnetworkserviceenabled "$PRIMARY_SERVICE" on
  second_elapsed="$(
    wait_for_underlay_recovery \
      secondary-to-primary "$PRIMARY_IFACE" "$second_requested" "$((baseline + 2))"
  )"
  dns_query_works || fail "DNS failed after the primary underlay recovered"
  captured_probe_works && https_works && exit_source_is_expected \
    || fail "exit traffic failed after the primary underlay recovered"
  kill "$payload_pid" >/dev/null 2>&1 || true
  wait "$payload_pid" >/dev/null 2>&1 || true
  rm -f "$STATE_DIR/payload.pid"

  {
    printf 'primary_to_secondary_ms=%s\n' "$first_elapsed"
    printf 'secondary_to_primary_ms=%s\n' "$second_elapsed"
    printf 'endpoint_route_interface=%s\n' "$(endpoint_route_interface)"
    printf 'carrier_rebinds=%s->%s\n' "$baseline" "$(rebind_count)"
  } >"$RESULT_DIR/underlay.txt"
  echo "MACOS_RELEASE_NETWORK_UNDERLAY_OK"
}

run_underlay_with_status() {
  local status=0
  run_underlay_gate || status="$?"
  if [[ "$status" -eq 0 ]]; then
    printf 'pass\n' >"$STATE_DIR/underlay.status"
  else
    printf 'fail:%s\n' "$status" >"$STATE_DIR/underlay.status"
  fi
  return "$status"
}

start_underlay_gate() {
  [[ ! -e "$STATE_DIR/underlay.status" ]] \
    || fail "underlay action was already started"
  printf 'running\n' >"$STATE_DIR/underlay.status"
  nohup "$0" underlay-run \
    >"$RESULT_DIR/underlay-run.log" 2>&1 </dev/null &
  printf '%s\n' "$!" >"$STATE_DIR/underlay.pid"
  echo "MACOS_RELEASE_NETWORK_UNDERLAY_STARTED"
}

direct_state_matches() {
  local expected_iface expected_gateway expected_source
  expected_iface="$(cat "$STATE_DIR/direct-interface")"
  expected_gateway="$(cat "$STATE_DIR/direct-gateway")"
  expected_source="$(cat "$STATE_DIR/direct-source-ip")"
  [[ -z "$(split_default_interface 1.0.0.1 2>/dev/null || true)" \
    && -z "$(split_default_interface 129.0.0.1 2>/dev/null || true)" \
    && "$(route_value default interface)" == "$expected_iface" \
    && "$(route_value default gateway)" == "$expected_gateway" \
    && "$(endpoint_route_interface)" == "$expected_iface" \
    && "$(source_ip)" == "$expected_source" ]] \
    && resolver_files_absent \
    && dns_query_works \
    && https_works
}

exact_direct_dns_matches() {
  /usr/sbin/scutil --dns >"$STATE_DIR/final-scutil-dns"
  /usr/sbin/networksetup -getdnsservers "$PRIMARY_SERVICE" \
    >"$STATE_DIR/final-primary-dns"
  /usr/sbin/networksetup -getdnsservers "$SECONDARY_SERVICE" \
    >"$STATE_DIR/final-secondary-dns"
  cmp -s "$STATE_DIR/direct-scutil-dns" "$STATE_DIR/final-scutil-dns" \
    && cmp -s "$STATE_DIR/direct-primary-dns" "$STATE_DIR/final-primary-dns" \
    && cmp -s "$STATE_DIR/direct-secondary-dns" "$STATE_DIR/final-secondary-dns"
}

select_direct_and_stop() {
  echo "phase=select-direct"
  nvpn set --config "$CONFIG" --exit-node ""
  wait_until "the exact Direct route, DNS, HTTPS, and source IP" \
    direct_state_matches
  wait_until "WireGuard disabled in the running daemon status" \
    runtime_wireguard_state_is false true
  privileged_nvpn stop --config "$CONFIG" --timeout-secs 8 --force
  wait_until "Direct state after daemon stop" direct_state_matches
  wait_until "the stopped daemon status without WireGuard selected" \
    runtime_wireguard_state_is false false
  if pgrep -x nvpn >/dev/null 2>&1; then
    fail "owned nvpn daemon survived Direct cleanup"
  fi
  [[ "$(service_state "$PRIMARY_SERVICE")" \
      == "$(cat "$STATE_DIR/primary-service-state")" \
    && "$(service_state "$SECONDARY_SERVICE")" \
      == "$(cat "$STATE_DIR/secondary-service-state")" ]] \
    || fail "guest network-service state was not restored"
  wait_until "the exact effective and per-service Direct DNS baseline" \
    exact_direct_dns_matches
  {
    printf 'direct_interface=%s\n' "$(route_value default interface)"
    printf 'direct_gateway=%s\n' "$(route_value default gateway)"
    printf 'direct_source_ip=%s\n' "$(source_ip)"
    printf 'resolver_files_absent=true\n'
  } >"$RESULT_DIR/direct.txt"
  echo "MACOS_RELEASE_NETWORK_DIRECT_OK"
}

cleanup_gate() {
  local cleanup_failed=0 pid="" ignored
  if [[ -f "$STATE_DIR/underlay.pid" ]]; then
    pid="$(tr -d '[:space:]' <"$STATE_DIR/underlay.pid")"
    if [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then
      kill "$pid" >/dev/null 2>&1 || true
      for ignored in $(seq 1 20); do
        kill -0 "$pid" >/dev/null 2>&1 || break
        sleep 0.1
      done
    fi
  fi
  if [[ -f "$STATE_DIR/payload.pid" ]]; then
    pid="$(tr -d '[:space:]' <"$STATE_DIR/payload.pid")"
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] \
      && kill "$pid" >/dev/null 2>&1 || true
  fi
  if [[ -f "$CONFIG" ]]; then
    nvpn set --config "$CONFIG" --exit-node "" >/dev/null 2>&1 || cleanup_failed=1
    privileged_nvpn stop --config "$CONFIG" --timeout-secs 8 --force \
      >/dev/null 2>&1 || cleanup_failed=1
    privileged_nvpn repair-network --config "$CONFIG" \
      >/dev/null 2>&1 || cleanup_failed=1
  fi
  if [[ -f "$STATE_DIR/primary-service-state" ]]; then
    set_service_state \
      "$PRIMARY_SERVICE" "$(cat "$STATE_DIR/primary-service-state")" \
      >/dev/null || cleanup_failed=1
  fi
  if [[ -f "$STATE_DIR/secondary-service-state" ]]; then
    set_service_state \
      "$SECONDARY_SERVICE" "$(cat "$STATE_DIR/secondary-service-state")" \
      >/dev/null || cleanup_failed=1
  fi
  if pgrep -x nvpn >/dev/null 2>&1; then
    echo "owned or foreign nvpn process survived macOS network cleanup" >&2
    cleanup_failed=1
  fi
  if ! resolver_files_absent; then
    echo "nvpn resolver files survived production cleanup" >&2
    cleanup_failed=1
  fi
  return "$cleanup_failed"
}

validate_inputs
case "$ACTION" in
  prepare) prepare_gate ;;
  dns-case) set_dns_case ;;
  underlay-start) start_underlay_gate ;;
  underlay-run) run_underlay_with_status ;;
  direct) select_direct_and_stop ;;
  cleanup) cleanup_gate ;;
  *) fail "unknown action: ${ACTION:-empty}" ;;
esac
