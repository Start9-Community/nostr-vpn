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
FIPS_NETWORK_ID="${NVPN_MACOS_FIPS_NETWORK_ID:-}"
FIPS_PEER_NPUB="${NVPN_MACOS_FIPS_PEER_NPUB:-}"
FIPS_PEER_ENDPOINT="${NVPN_MACOS_FIPS_PEER_ENDPOINT:-}"
FIPS_PEER_TUNNEL_IP="${NVPN_MACOS_FIPS_PEER_TUNNEL_IP:-}"
FIPS_CLIENT_LISTEN_PORT="${NVPN_MACOS_FIPS_CLIENT_LISTEN_PORT:-}"
EXPECTED_FIPS_REV="${NVPN_MACOS_FIPS_EXPECTED_REV:-}"
SECURE_RESOLVER="/etc/resolver/nvpn-secure-dns"
MAGIC_RESOLVER="/etc/resolver/nvpn"
SECURE_DNS_STORE_KEY="State:/Network/Service/to.nostrvpn.nvpn-secure-dns/DNS"

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
  [[ -n "$FIPS_NETWORK_ID" \
    && "$FIPS_PEER_NPUB" == npub1* \
    && -n "$FIPS_PEER_ENDPOINT" \
    && -n "$FIPS_PEER_TUNNEL_IP" ]] \
    || fail "authenticated FIPS peer inputs are incomplete"
  [[ "$FIPS_CLIENT_LISTEN_PORT" =~ ^[1-9][0-9]{0,4}$ \
    && "$FIPS_CLIENT_LISTEN_PORT" -le 65535 ]] \
    || fail "local FIPS client UDP port is invalid"
  [[ "$EXPECTED_FIPS_REV" =~ ^[0-9a-f]{10}$ ]] \
    || fail "expected FIPS revision must be exactly ten hex characters"
  nvpn version --verbose | grep -Fq "(rev $EXPECTED_FIPS_REV)" \
    || fail "imported macOS nvpn does not contain the exact FIPS revision"
}

nvpn() {
  "$NVPN_BIN" "$@"
}

privileged_nvpn() {
  sudo -n "$NVPN_BIN" "$@"
}

read_npub() {
  sed -n 's/^public_key = "\([^"]*\)"/\1/p' "$CONFIG" | head -n 1
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

ipv4_route_table() {
  /usr/sbin/netstat -rn -f inet
}

wireguard_interface() {
  ipv4_route_table | awk '
    $1 == "Destination" {
      for (field = 1; field <= NF; field++) {
        if ($field == "Netif") netif = field
      }
      next
    }
    netif && ($1 == "0/1" || $1 == "0.0.0.0/1") {
      low += 1
      low_interface = $netif
    }
    netif && ($1 == "128/1" || $1 == "128.0/1" || $1 == "128.0.0.0/1") {
      high += 1
      high_interface = $netif
    }
    END {
      if (low == 1 && high == 1 && low_interface == high_interface \
          && low_interface ~ /^utun/) {
        print low_interface
        exit 0
      }
      exit 1
    }
  '
}

wireguard_split_defaults_absent() {
  ipv4_route_table | awk '
    $1 == "0/1" || $1 == "0.0.0.0/1" \
      || $1 == "128/1" || $1 == "128.0/1" || $1 == "128.0.0.0/1" {
      split_default = 1
    }
    END { exit split_default ? 1 : 0 }
  '
}

wireguard_interface_absent() {
  ! wireguard_interface >/dev/null 2>&1
}

wireguard_endpoint_route_absent() {
  local family=inet
  [[ "$ENDPOINT_FAMILY" == "ipv6" ]] && family=inet6
  /usr/sbin/netstat -rn -f "$family" | awk -v endpoint="$ENDPOINT_HOST" '
    $1 == endpoint { found = 1 }
    END { exit found ? 1 : 0 }
  '
}

wireguard_endpoint_route_state_valid() {
  local expected_underlay="${1:-$PRIMARY_IFACE}"
  local endpoint_iface expected_gateway physical_default_iface wg_iface
  [[ "$expected_underlay" == "$PRIMARY_IFACE" \
    || "$expected_underlay" == "$SECONDARY_IFACE" ]] \
    || return 1
  endpoint_iface="$(endpoint_route_interface)" || return 1
  if [[ "$ENDPOINT_FAMILY" == "ipv6" ]]; then
    [[ "$endpoint_iface" == "$expected_underlay" ]]
    return
  fi
  wg_iface="$(wireguard_interface)" || return 1
  physical_default_iface="$(route_value default interface)" || return 1
  expected_gateway="$(route_value default gateway)" || return 1
  # The global lookup remains covered by the WireGuard /1s, while exactly
  # one interface-scoped /32 keeps encrypted UDP on the selected underlay.
  [[ "$endpoint_iface" == "$wg_iface" \
    && "$physical_default_iface" == "$expected_underlay" \
    && -n "$expected_gateway" \
    && "$expected_gateway" != link#* ]] \
    && ipv4_route_table \
      | awk \
        -v endpoint="$ENDPOINT_HOST" \
        -v gateway="$expected_gateway" \
        -v interface="$expected_underlay" '
          $1 == endpoint {
            routes += 1
            if ($2 == gateway && $4 == interface) {
              matching += 1
            }
          }
          END { exit (routes == 1 && matching == 1) ? 0 : 1 }
        '
}

secure_dns_store_state() {
  /usr/sbin/scutil <<EOF
show $SECURE_DNS_STORE_KEY
EOF
}

secure_dns_store_owned() {
  local state expected
  state="$(secure_dns_store_state 2>/dev/null | sed 's/[[:space:]]*$//')" \
    || return 1
  expected='<dictionary> {
  ServerAddresses : <array> {
    0 : 127.0.0.1
  }
  ServerPort : 1053
  SupplementalMatchDomains : <array> {
    0 :
  }
  SupplementalMatchOrders : <array> {
    0 : 1
  }
}'
  [[ "$state" == "$expected" ]]
}

secure_dns_store_absent() {
  local state
  state="$(secure_dns_store_state 2>/dev/null)" || return 1
  [[ "$state" == *"No such key"* ]]
}

secure_dns_owned() {
  [[ ! -e "$SECURE_RESOLVER" && -f "$MAGIC_RESOLVER" ]] \
    && grep -Fq 'Managed by nvpn secure DNS' "$MAGIC_RESOLVER" \
    && grep -Fq 'nameserver 127.0.0.1' "$MAGIC_RESOLVER" \
    && secure_dns_store_owned
}

resolver_files_absent() {
  [[ ! -e "$SECURE_RESOLVER" && ! -e "$MAGIC_RESOLVER" ]] \
    && secure_dns_store_absent
}

flush_dns_cache() {
  /usr/bin/dscacheutil -flushcache >/dev/null 2>&1 || true
}

wait_budget_seconds() {
  local limit="$1"
  local remaining="$limit"
  if (( ${WAIT_DEADLINE_SECONDS:-0} > 0 )); then
    remaining="$((WAIT_DEADLINE_SECONDS - SECONDS))"
    ((remaining > 0)) || return 1
    ((remaining < limit)) || remaining="$limit"
  fi
  printf '%s\n' "$remaining"
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
  local timeout
  timeout="$(wait_budget_seconds 8)" || return 1
  curl -4fsS --max-time "$timeout" "$INTERNET_URL" >/dev/null
}

captured_probe_works() {
  local payload timeout
  timeout="$(wait_budget_seconds 5)" || return 1
  payload="$(curl -4fsS --max-time "$timeout" "$CAPTURED_PROBE_URL")" || return 1
  grep -Fq "$CAPTURED_PROBE_TOKEN" <<<"$payload"
}

source_ip() {
  local timeout
  timeout="$(wait_budget_seconds 8)" || return 1
  curl -4fsS --max-time "$timeout" "$SOURCE_IP_URL" | tr -d '[:space:]'
}

exit_source_is_expected() {
  [[ "$(source_ip)" == "$EXPECTED_EXIT_SOURCE_IP" ]]
}

wireguard_routes_live() {
  local interface
  interface="$(wireguard_interface)" || return 1
  wireguard_endpoint_route_state_valid \
    && secure_dns_owned \
    && captured_probe_works \
    && https_works \
    && exit_source_is_expected
}

capture_wireguard_readiness_failure() {
  local interface="" endpoint_interface="" observed_source=""
  interface="$(wireguard_interface 2>/dev/null || true)"
  endpoint_interface="$(endpoint_route_interface 2>/dev/null || true)"
  observed_source="$(source_ip 2>/dev/null || true)"
  {
    printf 'wireguard_interface=%s\n' "${interface:-unavailable}"
    printf 'endpoint_route_interface=%s\n' \
      "${endpoint_interface:-unavailable}"
    printf 'endpoint_route_state_valid=%s\n' \
      "$(wireguard_endpoint_route_state_valid \
        && printf true || printf false)"
    printf 'secure_dns_owned=%s\n' \
      "$(secure_dns_owned && printf true || printf false)"
    printf 'captured_probe_works=%s\n' \
      "$(captured_probe_works && printf true || printf false)"
    printf 'public_https_works=%s\n' \
      "$(https_works && printf true || printf false)"
    printf 'exit_source_matches=%s\n' \
      "$([[ "$observed_source" == "$EXPECTED_EXIT_SOURCE_IP" ]] \
        && printf true || printf false)"
    printf 'observed_exit_source_ip=%s\n' \
      "${observed_source:-unavailable}"
  } >"$RESULT_DIR/wireguard-readiness-failure.txt"
  {
    /sbin/route -n get default 2>&1 || true
    /sbin/route -n get 1.0.0.1 2>&1 || true
    /sbin/route -n get 129.0.0.1 2>&1 || true
    if [[ "$ENDPOINT_FAMILY" == "ipv6" ]]; then
      /sbin/route -n get -inet6 "$ENDPOINT_HOST" 2>&1 || true
    else
      /sbin/route -n get "$ENDPOINT_HOST" 2>&1 || true
    fi
  } >"$RESULT_DIR/wireguard-readiness-routes.txt"
  /usr/sbin/scutil --dns \
    >"$RESULT_DIR/wireguard-readiness-dns.txt" 2>&1 || true
  nvpn status --config "$CONFIG" --json --discover-secs 0 \
    >"$RESULT_DIR/wireguard-readiness-status.json" 2>&1 || true
  tail -n 240 "$STATE_DIR/daemon.log" \
    >"$RESULT_DIR/wireguard-readiness-daemon.log" 2>&1 || true
}

capture_fips_peer_readiness_failure() {
  if [[ -f "$STATE_DIR/status-fips-peer.json" ]]; then
    cp "$STATE_DIR/status-fips-peer.json" \
      "$RESULT_DIR/fips-peer-readiness-status.json"
  else
    printf '{"error":"client status was not written"}\n' \
      >"$RESULT_DIR/fips-peer-readiness-status.json"
  fi
  tail -n 240 "$STATE_DIR/daemon.log" \
    >"$RESULT_DIR/fips-peer-readiness-daemon.log" 2>&1 || true
}

wait_until() {
  local description="$1"
  shift
  local deadline="${WAIT_DEADLINE_SECONDS:-$((SECONDS + WAIT_SECS))}"
  local WAIT_DEADLINE_SECONDS="$deadline"
  while ((SECONDS < WAIT_DEADLINE_SECONDS)); do
    if "$@"; then
      ((SECONDS <= WAIT_DEADLINE_SECONDS)) && return 0
      break
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
  if [[ "$(service_state "$service")" == "$state" ]]; then
    return 0
  fi
  case "$state" in
    Enabled) sudo -n /usr/sbin/networksetup -setnetworkserviceenabled "$service" on ;;
    Disabled) sudo -n /usr/sbin/networksetup -setnetworkserviceenabled "$service" off ;;
    *) fail "invalid saved state for $service" ;;
  esac
}

monotonic_ms() {
  /usr/bin/python3 - <<'PY'
import ctypes

libsystem = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
libsystem.mach_continuous_time.restype = ctypes.c_uint64


class MachTimebaseInfo(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


timebase = MachTimebaseInfo()
if libsystem.mach_timebase_info(ctypes.byref(timebase)) != 0 or timebase.denom == 0:
    raise SystemExit("failed to read the macOS monotonic clock timebase")
ticks = libsystem.mach_continuous_time()
print((ticks * timebase.numer) // timebase.denom // 1_000_000)
PY
}

rebind_count() {
  grep -Fc 'FIPS underlay carrier(s) rebound' "$STATE_DIR/daemon.log" 2>/dev/null \
    || true
}

wireguard_rebind_count() {
  grep -Fc 'WG upstream rebound' "$STATE_DIR/daemon.log" 2>/dev/null \
    || true
}

wireguard_last_rebind_target_is() {
  local expected_iface="$1" last_rebind
  last_rebind="$(
    grep -F 'WG upstream rebound' "$STATE_DIR/daemon.log" 2>/dev/null \
      | tail -n 1
  )"
  [[ "$last_rebind" == *" -> $expected_iface with a fresh handshake" ]]
}

runtime_wireguard_state_is() {
  local expected_enabled="$1" expected_running="$2" status_file
  status_file="$STATE_DIR/status-$expected_enabled-$expected_running.json"
  nvpn status --config "$CONFIG" --json --discover-secs 0 \
    >"$status_file" || return 1
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

runtime_dns_state_matches() {
  local status_file="$STATE_DIR/status-dns-$DNS_LABEL.json"
  nvpn status --config "$CONFIG" --json --discover-secs 0 \
    >"$status_file" || return 1
  /usr/bin/python3 - \
    "$status_file" \
    "$DNS_MODE" \
    "$DNS_PROVIDER" \
    "$DNS_CUSTOM_URL" \
    "$DNS_BOOTSTRAP_IPS" \
    "$DNS_THROUGH_SERVERS" <<'PY'
import json
import sys

(
    path,
    expected_mode,
    expected_provider,
    expected_url,
    expected_bootstrap,
    expected_through,
) = sys.argv[1:]

def csv(value):
    return sorted({part.strip() for part in value.split(",") if part.strip()})

with open(path, encoding="utf-8") as handle:
    dns = json.load(handle).get("exit_dns", {})
if (
    dns.get("mode") == expected_mode
    and dns.get("doh_provider") == expected_provider
    and dns.get("custom_doh_url", "") == expected_url
    and sorted(dns.get("custom_doh_bootstrap_ips", [])) == csv(expected_bootstrap)
    and sorted(dns.get("through_exit_servers", [])) == csv(expected_through)
):
    raise SystemExit(0)
raise SystemExit(1)
PY
}

runtime_fips_peer_connected() {
  local status_file="${1:-$STATE_DIR/status-fips-peer.json}"
  nvpn status --config "$CONFIG" --json --discover-secs 0 \
    >"$status_file" || return 1
  /usr/bin/python3 - \
    "$status_file" \
    "$FIPS_PEER_NPUB" \
    "$FIPS_PEER_ENDPOINT" \
    "$FIPS_CLIENT_LISTEN_PORT" \
    "$EXPECTED_FIPS_REV" <<'PY'
import json
import sys

(
    path,
    expected_peer,
    expected_endpoint,
    expected_listen_port,
    expected_revision,
) = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    status = json.load(handle)
daemon = status.get("daemon", {})
state = daemon.get("state", {})
peers = state.get("fips_endpoint_peers", [])
addresses = peers[0].get("addresses", []) if len(peers) == 1 else []
if (
    status.get("status_source") == "daemon"
    and daemon.get("running") is True
    and state.get("mesh_ready") is True
    and state.get("connected_peer_count") == 1
    and state.get("listen_port") == int(expected_listen_port)
    and len(peers) == 1
    and peers[0].get("npub") == expected_peer
    and any(address.get("addr") == expected_endpoint for address in addresses)
    and state.get("fips_core_version", "").endswith(
        f"(rev {expected_revision})"
    )
):
    raise SystemExit(0)
raise SystemExit(1)
PY
}

normalize_scutil_dns_file() {
  local input="$1" output="$2"
  /usr/bin/python3 - "$input" "$output" <<'PY'
import json
import re
import sys

source, destination = sys.argv[1:]
resolvers = []
current = None
for raw_line in open(source, encoding="utf-8", errors="replace"):
    line = raw_line.strip()
    if re.fullmatch(r"resolver #[0-9]+", line):
        if current is not None:
            resolvers.append(current)
        current = {
            "domain": [],
            "search": [],
            "nameserver": [],
            "interface": [],
            "scoped": False,
        }
        continue
    if current is None or ":" not in line:
        continue
    key, value = (part.strip() for part in line.split(":", 1))
    if re.fullmatch(r"nameserver\[[0-9]+\]", key):
        current["nameserver"].append(value)
    elif re.fullmatch(r"search domain\[[0-9]+\]", key):
        current["search"].append(value)
    elif key == "domain":
        current["domain"].append(value)
    elif key == "if_index":
        match = re.search(r"\(([^()]+)\)", value)
        current["interface"].append(match.group(1) if match else value)
    elif key == "flags":
        current["scoped"] = "Scoped" in re.split(r"[^A-Za-z]+", value)
if current is not None:
    resolvers.append(current)

for resolver in resolvers:
    for key in ("domain", "search", "nameserver", "interface"):
        resolver[key] = sorted(set(resolver[key]))
resolvers.sort(key=lambda resolver: json.dumps(resolver, sort_keys=True))
with open(destination, "w", encoding="utf-8") as handle:
    json.dump(resolvers, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
PY
}

owned_daemon_pid() {
  /usr/bin/python3 - "$STATE_DIR/daemon.pid" "$CONFIG" <<'PY'
import json
import sys

path, config_path = sys.argv[1:]
try:
    with open(path, encoding="utf-8") as handle:
        record = json.load(handle)
except (OSError, ValueError):
    raise SystemExit(1)
pid = record.get("pid")
if (
    not isinstance(pid, int)
    or isinstance(pid, bool)
    or pid <= 0
    or record.get("config_path") != config_path
):
    raise SystemExit(1)
print(pid)
PY
}

daemon_process_alive() {
  local pid="$1"
  kill -0 "$pid" 2>/dev/null \
    || sudo -n /bin/kill -0 "$pid" 2>/dev/null
}

assert_single_owned_daemon() {
  local pid command
  pid="$(owned_daemon_pid)" || return 1
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  daemon_process_alive "$pid" || return 1
  [[ "$(pgrep -x nvpn | wc -l | tr -d '[:space:]')" == "1" ]] \
    || return 1
  command="$(ps -ww -p "$pid" -o command= 2>/dev/null)" || return 1
  [[ "$command" == *"$NVPN_BIN"* \
    && "$command" == *" daemon "* \
    && "$command" == *" --config $CONFIG"* ]]
}

snapshot_predicate() {
  local output="$1" name="$2"
  shift 2
  if "$@" >/dev/null 2>&1; then
    printf '%s=true\n' "$name" >>"$output"
  else
    printf '%s=false\n' "$name" >>"$output"
  fi
}

capture_underlay_routes() {
  {
    printf '%s\n' '--- default route ---'
    /sbin/route -n get default 2>&1 || true
    printf '%s\n' '--- WireGuard low split route ---'
    /sbin/route -n get 1.0.0.1 2>&1 || true
    printf '%s\n' '--- WireGuard high split route ---'
    /sbin/route -n get 129.0.0.1 2>&1 || true
    printf '%s\n' '--- WireGuard endpoint route ---'
    if [[ "$ENDPOINT_FAMILY" == "ipv6" ]]; then
      /sbin/route -n get -inet6 "$ENDPOINT_HOST" 2>&1 || true
    else
      /sbin/route -n get "$ENDPOINT_HOST" 2>&1 || true
    fi
    printf '%s\n' '--- FIPS peer tunnel route ---'
    /sbin/route -n get "$FIPS_PEER_TUNNEL_IP" 2>&1 || true
  }
}

crash_startup_log_order_is_valid() {
  local wireguard_line fips_line
  wireguard_line="$({
    grep -nF 'fips: WG upstream up on ' "$STATE_DIR/daemon.log" \
      || true
  } | tail -n 1 | cut -d: -f1)"
  fips_line="$({
    grep -nF 'daemon: FIPS private mesh on ' "$STATE_DIR/daemon.log" \
      || true
  } | tail -n 1 | cut -d: -f1)"
  [[ "$wireguard_line" =~ ^[1-9][0-9]*$ \
    && "$fips_line" =~ ^[1-9][0-9]*$ \
    && "$wireguard_line" -lt "$fips_line" ]]
}

capture_crash_startup_log_order() {
  {
    printf '%s\n' '--- WireGuard startup receipts ---'
    grep -nF 'fips: WG upstream up on ' "$STATE_DIR/daemon.log" || true
    printf '%s\n' '--- FIPS startup completion receipts ---'
    grep -nF 'daemon: FIPS private mesh on ' "$STATE_DIR/daemon.log" || true
  }
}

crash_live_precondition() {
  # The FIPS-on receipt is emitted only after mandatory cleanup ownership
  # persistence returns successfully. Keep that ordered production log plus
  # externally observable network state; the root-only journal is deliberately
  # not part of this unprivileged release harness's interface.
  wireguard_routes_live \
    && runtime_wireguard_state_is true true \
    && runtime_dns_state_matches \
    && runtime_fips_peer_connected \
    && capture_fips_host_tunnel_route >/dev/null \
    && crash_startup_log_order_is_valid
}

crash_fail_closed_after_sigkill() {
  no_nvpn_processes \
    && wireguard_interface_absent \
    && wireguard_split_defaults_absent \
    && wireguard_endpoint_route_absent \
    && secure_dns_owned
}

snapshot_crash_fail_closed_after_sigkill() {
  local predicates="$1"
  : >"$predicates"
  snapshot_predicate "$predicates" daemon_absent no_nvpn_processes
  snapshot_predicate "$predicates" wireguard_interface_absent \
    wireguard_interface_absent
  snapshot_predicate "$predicates" wireguard_split_defaults_absent \
    wireguard_split_defaults_absent
  snapshot_predicate "$predicates" endpoint_route_absent \
    wireguard_endpoint_route_absent
  snapshot_predicate "$predicates" secure_dns_owned secure_dns_owned
  ! grep -Fq '=false' "$predicates"
}

record_crash_external_audit() {
  local label="$1" mode predicates
  case "$label" in
    precondition|after-restart) mode=live ;;
    after-sigkill|after-stopped-status) mode=residue ;;
    *) return 1 ;;
  esac
  predicates="$RESULT_DIR/crash-external-$label-predicates.txt"
  if [[ "$mode" == live ]]; then
    : >"$predicates"
    snapshot_predicate "$predicates" secure_dns_owned secure_dns_owned
    snapshot_predicate "$predicates" wireguard_interface wireguard_interface
    snapshot_predicate "$predicates" endpoint_route_bypass \
      wireguard_endpoint_route_state_valid "$PRIMARY_IFACE"
    snapshot_predicate "$predicates" wireguard_routes_live wireguard_routes_live
    snapshot_predicate "$predicates" runtime_wireguard_live \
      runtime_wireguard_state_is true true
    snapshot_predicate "$predicates" runtime_dns_state_matches \
      runtime_dns_state_matches
    snapshot_predicate "$predicates" authenticated_fips_peer \
      runtime_fips_peer_connected
    snapshot_predicate "$predicates" fips_host_tunnel_route_live \
      capture_fips_host_tunnel_route
    snapshot_predicate "$predicates" startup_log_order \
      crash_startup_log_order_is_valid
    crash_live_precondition || return 1
  else
    snapshot_crash_fail_closed_after_sigkill "$predicates" || return 1
  fi
  capture_underlay_routes \
    >"$RESULT_DIR/crash-external-$label-routes.txt" 2>&1 || true
  capture_crash_ownership_resolver_state \
    >"$RESULT_DIR/crash-external-$label-resolver-state.txt" 2>&1 || true
  capture_crash_startup_log_order \
    >"$RESULT_DIR/crash-external-$label-startup-order.txt" 2>&1 || true
  nvpn status --config "$CONFIG" --json --discover-secs 0 \
    >"$RESULT_DIR/crash-external-$label-status.json" 2>&1 || true
  cp -p "$STATE_DIR/daemon.log" \
    "$RESULT_DIR/crash-external-$label-daemon.log" 2>/dev/null || true
}

wait_for_crash_live_precondition() {
  local deadline="$((SECONDS + WAIT_SECS))" polls=0
  while ((SECONDS < deadline)); do
    polls=$((polls + 1))
    if crash_live_precondition; then
      printf 'polls=%s\n' "$polls" \
        >"$RESULT_DIR/crash-external-precondition.txt"
      record_crash_external_audit precondition
      return 0
    fi
    sleep 0.2
  done
  return 1
}

capture_crash_ownership_resolver_state() {
  {
    printf '%s\n' '--- resolver files ---'
    ls -ld "$SECURE_RESOLVER" "$MAGIC_RESOLVER" 2>&1 || true
    printf '%s\n' '--- secure resolver file ---'
    if [[ -f "$SECURE_RESOLVER" ]]; then
      cat "$SECURE_RESOLVER" 2>&1 || true
    else
      printf 'absent\n'
    fi
    printf '%s\n' '--- magic resolver file ---'
    if [[ -f "$MAGIC_RESOLVER" ]]; then
      cat "$MAGIC_RESOLVER" 2>&1 || true
    else
      printf 'absent\n'
    fi
    printf '%s\n' '--- secure DNS dynamic store ---'
    secure_dns_store_state 2>&1 || true
    printf '%s\n' '--- effective resolver state ---'
    /usr/sbin/scutil --dns 2>&1 || true
  }
}

capture_crash_external_failure() {
  local predicates="$RESULT_DIR/crash-external-failure-predicates.txt"
  : >"$predicates"
  snapshot_predicate "$predicates" wireguard_routes_live wireguard_routes_live
  snapshot_predicate "$predicates" runtime_wireguard_live \
    runtime_wireguard_state_is true true
  snapshot_predicate "$predicates" runtime_dns_state_matches \
    runtime_dns_state_matches
  snapshot_predicate "$predicates" authenticated_fips_peer \
    runtime_fips_peer_connected
  snapshot_predicate "$predicates" fips_host_tunnel_route_live \
    capture_fips_host_tunnel_route
  snapshot_predicate "$predicates" startup_log_order \
    crash_startup_log_order_is_valid
  capture_underlay_routes \
    >"$RESULT_DIR/crash-external-failure-routes.txt" 2>&1 || true
  capture_crash_ownership_resolver_state \
    >"$RESULT_DIR/crash-external-failure-resolver-state.txt" 2>&1 || true
  capture_crash_startup_log_order \
    >"$RESULT_DIR/crash-external-failure-startup-order.txt" 2>&1 || true
  nvpn status --config "$CONFIG" --json --discover-secs 0 \
    >"$RESULT_DIR/crash-external-failure-status.json" 2>&1 || true
  cp -p "$STATE_DIR/daemon.log" \
    "$RESULT_DIR/crash-external-failure-daemon.log" 2>/dev/null || true
}

no_nvpn_processes() {
  ! pgrep -x nvpn >/dev/null 2>&1
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
  printf '%s\n' "$DNS_PROBE_HOST" >"$STATE_DIR/direct-dns-probe-host"
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
  normalize_scutil_dns_file \
    "$STATE_DIR/direct-scutil-dns" "$STATE_DIR/direct-scutil-dns.normalized"
  /usr/sbin/networksetup -getdnsservers "$PRIMARY_SERVICE" \
    >"$STATE_DIR/direct-primary-dns"
  /usr/sbin/networksetup -getdnsservers "$SECONDARY_SERVICE" \
    >"$STATE_DIR/direct-secondary-dns"
}

direct_dns_query_works() (
  DNS_PROBE_HOST="$(cat "$STATE_DIR/direct-dns-probe-host")"
  DNS_EXPECTED_IP=""
  DNS_LABEL=direct-restore
  dns_query_works
)

initialize_gate() {
  mkdir -p "$RESULT_DIR"
  chmod 700 "$STATE_DIR"
  if pgrep -x nvpn >/dev/null 2>&1; then
    fail "another nvpn process is already running in macos-utm"
  fi
  [[ ! -e "$CONFIG" ]] \
    || fail "dedicated macOS network config already exists before initialization"
  nvpn init --config "$CONFIG" --force
  nvpn set --config "$CONFIG" --network-id "$FIPS_NETWORK_ID"
  local npub tunnel_ip
  npub="$(read_npub)"
  tunnel_ip="$(nvpn ip --config "$CONFIG")"
  [[ "$npub" == npub1* && -n "$tunnel_ip" ]] \
    || fail "imported Release identity receipt is incomplete"
  printf '%s\n' "$npub" >"$STATE_DIR/original-npub"
  printf '%s\n' "$tunnel_ip" >"$STATE_DIR/original-tunnel-ip"
  printf 'npub=%s\n' "$npub"
  printf 'tunnel_ip=%s\n' "$tunnel_ip"
  echo "MACOS_RELEASE_NETWORK_IDENTITY_READY"
}

prepare_gate() {
  mkdir -p "$RESULT_DIR"
  chmod 700 "$STATE_DIR"
  if pgrep -x nvpn >/dev/null 2>&1; then
    fail "another nvpn process is already running in macos-utm"
  fi
  snapshot_direct_state
  [[ -s "$CONFIG" \
    && -s "$STATE_DIR/original-npub" \
    && -s "$STATE_DIR/original-tunnel-ip" ]] \
    || fail "dedicated Release identity was not initialized"
  [[ "$(read_npub)" == "$(<"$STATE_DIR/original-npub")" \
    && "$(nvpn ip --config "$CONFIG")" == "$(<"$STATE_DIR/original-tunnel-ip")" ]] \
    || fail "dedicated Release identity changed before daemon start"
  nvpn set --config "$CONFIG" \
    --network-id "$FIPS_NETWORK_ID" \
    --participant "$FIPS_PEER_NPUB" \
    --listen-port "$FIPS_CLIENT_LISTEN_PORT" \
    --fips-advertise-public-endpoint false \
    --fips-nostr-discovery-enabled false \
    --lan-discovery-enabled false \
    --fips-webrtc-enabled false \
    --fips-bootstrap-enabled false \
    --fips-peer-endpoint "${FIPS_PEER_NPUB}=${FIPS_PEER_ENDPOINT}" \
    --autoconnect true \
    --wireguard-exit-config-file "$WG_CONFIG" \
    --wireguard-exit-enabled true \
    --exit-dns-mode automatic
  privileged_nvpn start --config "$CONFIG" --connect --daemon \
    >"$RESULT_DIR/daemon-start.txt"
  if ! wait_until \
    "the production WireGuard route, DNS, HTTPS, and source IP" \
    wireguard_routes_live
  then
    capture_wireguard_readiness_failure
    return 1
  fi
  wait_until "the daemon runtime/status WireGuard state" \
    runtime_wireguard_state_is true true
  if ! wait_until "one exact authenticated FIPS peer session" \
    runtime_fips_peer_connected
  then
    capture_fips_peer_readiness_failure
    return 1
  fi
  runtime_fips_peer_connected "$RESULT_DIR/fips-peer-initial.json" \
    || fail "authenticated FIPS peer disappeared after initial readiness"
  [[ -s "$STATE_DIR/daemon.log" ]] \
    || fail "the owned daemon did not write its config-scoped log"
  grep -Fq \
    " bound to $PRIMARY_IFACE (split-default kill switch installed)" \
    "$STATE_DIR/daemon.log" \
    || fail "WireGuard did not bind to the initial physical underlay before readiness"
  assert_single_owned_daemon || fail "the gate does not own exactly one daemon"
  wireguard_interface >"$STATE_DIR/wireguard-interface"
  rebind_count >"$STATE_DIR/rebind-baseline"
  wireguard_rebind_count >"$STATE_DIR/wireguard-rebind-baseline"
  {
    printf 'direct_interface=%s\n' "$(cat "$STATE_DIR/direct-interface")"
    printf 'wireguard_interface=%s\n' "$(cat "$STATE_DIR/wireguard-interface")"
    printf 'endpoint_route_interface=%s\n' "$(endpoint_route_interface)"
    printf 'exit_source_ip=%s\n' "$(source_ip)"
    printf 'fips_peer_npub=%s\n' "$FIPS_PEER_NPUB"
    printf 'fips_peer_tunnel_ip=%s\n' "$FIPS_PEER_TUNNEL_IP"
    printf 'connected_peer_count=1\n'
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
  wait_until "$DNS_LABEL exact runtime DNS settings" \
    runtime_dns_state_matches
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

fips_payload_loop() {
  local now
  while true; do
    now="$(monotonic_ms)"
    if /sbin/ping -n -c 1 -W 700 "$FIPS_PEER_TUNNEL_IP" \
      >/dev/null 2>&1
    then
      printf '%s\t%s\n' "$now" "$FIPS_PEER_NPUB"
    fi
    sleep 0.1
  done
}

fips_payload_after() {
  local lower_bound_ms="$1"
  awk -F '\t' -v lower="$lower_bound_ms" -v peer="$FIPS_PEER_NPUB" \
    '$1 >= lower && $2 == peer { found=1 } END { exit found ? 0 : 1 }' \
    "$STATE_DIR/underlay-fips-payload.tsv"
}

fips_payload_works() {
  /sbin/ping -n -c 1 -W 700 "$FIPS_PEER_TUNNEL_IP" \
    >/dev/null 2>&1
}

fips_payload_success_count() {
  awk -F '\t' -v peer="$FIPS_PEER_NPUB" \
    '$2 == peer { count += 1 } END { print count + 0 }' \
    "$STATE_DIR/underlay-fips-payload.tsv" 2>/dev/null
}

fips_route_interface() {
  route_value "$FIPS_PEER_TUNNEL_IP" interface
}

fips_route_interface_owns_tunnel_ip() {
  local interface="$1" tunnel_ip
  tunnel_ip="$(tr -d '[:space:]' <"$STATE_DIR/original-tunnel-ip")"
  [[ -n "$tunnel_ip" ]] || return 1
  /sbin/ifconfig "$interface" 2>/dev/null \
    | awk -v expected="$tunnel_ip" '
      $1 == "inet" && $2 == expected { found = 1 }
      $1 == "inet6" {
        split($2, address, "%")
        if (address[1] == expected) found = 1
      }
      END { exit found ? 0 : 1 }
    '
}

capture_fips_host_tunnel_route() {
  local fips_iface wireguard_iface
  fips_iface="$(fips_route_interface)" || return 1
  wireguard_iface="$(wireguard_interface)" || return 1
  [[ "$fips_iface" == utun* \
    && "$fips_iface" != "$wireguard_iface" \
    && "$fips_iface" != "$PRIMARY_IFACE" \
    && "$fips_iface" != "$SECONDARY_IFACE" ]] \
    && fips_route_interface_owns_tunnel_ip "$fips_iface" \
    || return 1
  printf '%s\n' "$fips_iface"
}

fips_host_tunnel_route_live() {
  local expected_iface actual_iface wireguard_iface
  [[ -s "$STATE_DIR/fips-route-interface" ]] || return 1
  expected_iface="$(tr -d '[:space:]' <"$STATE_DIR/fips-route-interface")"
  actual_iface="$(fips_route_interface)" || return 1
  wireguard_iface="$(wireguard_interface)" || return 1
  [[ "$expected_iface" == utun* \
    && "$actual_iface" == "$expected_iface" \
    && "$actual_iface" != "$wireguard_iface" \
    && "$actual_iface" != "$PRIMARY_IFACE" \
    && "$actual_iface" != "$SECONDARY_IFACE" ]] \
    && fips_route_interface_owns_tunnel_ip "$actual_iface"
}

pid_is_underlay_runner() {
  local pid="$1" command
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  command="$(ps -p "$pid" -o command= 2>/dev/null)" || return 1
  [[ "$command" == *"e2e-macos-release-network.sh underlay-run"* ]]
}

process_start_signature() {
  ps -p "$1" -o lstart= 2>/dev/null | xargs
}

pid_matches_start_receipt() {
  local pid="$1" receipt="$2" expected actual
  [[ -s "$receipt" ]] || return 1
  expected="$(cat "$receipt")"
  actual="$(process_start_signature "$pid")"
  [[ -n "$actual" && "$actual" == "$expected" ]]
}

stop_owned_loop() {
  local name="$1" label="$2" expected_parent="$3" pid parent ignored
  local pid_file="$STATE_DIR/$name.pid"
  local start_file="$STATE_DIR/$name.start"
  [[ -f "$pid_file" ]] || return 0
  pid="$(tr -d '[:space:]' <"$pid_file")"
  if ! pid_is_underlay_runner "$pid" \
    || ! pid_matches_start_receipt "$pid" "$start_file"
  then
    echo "refusing to signal an unowned $label PID: $pid" >&2
    return 1
  fi
  parent="$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d '[:space:]')"
  if [[ "$parent" != "$expected_parent" ]]; then
    if kill -0 "$expected_parent" >/dev/null 2>&1; then
      echo "$label PID $pid is not owned by live underlay runner $expected_parent" >&2
      return 1
    fi
    echo "recovering start-time-verified $label orphaned by underlay runner $expected_parent" >&2
  fi
  kill "$pid" >/dev/null 2>&1 || true
  if [[ "$expected_parent" == "$$" ]]; then
    wait "$pid" >/dev/null 2>&1 || true
  else
    for ignored in $(seq 1 30); do
      kill -0 "$pid" >/dev/null 2>&1 || break
      sleep 0.1
    done
  fi
  if kill -0 "$pid" >/dev/null 2>&1; then
    echo "owned underlay $label PID $pid survived termination" >&2
    return 1
  fi
  rm -f "$pid_file" "$start_file"
}

stop_owned_payload() {
  stop_owned_loop payload "WireGuard payload" "$1"
}

stop_owned_fips_payload() {
  stop_owned_loop fips-payload "private-FIPS payload" "$1"
}

stop_owned_underlay_runner() {
  local pid ignored
  [[ -f "$STATE_DIR/underlay.pid" ]] || return 0
  pid="$(tr -d '[:space:]' <"$STATE_DIR/underlay.pid")"
  if ! kill -0 "$pid" >/dev/null 2>&1; then
    rm -f "$STATE_DIR/underlay.pid"
    return 0
  fi
  if ! pid_is_underlay_runner "$pid" \
    || ! pid_matches_start_receipt "$pid" "$STATE_DIR/underlay.start"
  then
    echo "refusing to signal an unowned underlay PID: $pid" >&2
    return 1
  fi
  kill "$pid" >/dev/null 2>&1 || true
  for ignored in $(seq 1 100); do
    kill -0 "$pid" >/dev/null 2>&1 || break
    sleep 0.1
  done
  if kill -0 "$pid" >/dev/null 2>&1; then
    kill -KILL "$pid" >/dev/null 2>&1 || true
    for ignored in $(seq 1 20); do
      kill -0 "$pid" >/dev/null 2>&1 || break
      sleep 0.1
    done
  fi
  if kill -0 "$pid" >/dev/null 2>&1; then
    echo "owned underlay runner PID $pid survived termination" >&2
    return 1
  fi
  rm -f "$STATE_DIR/underlay.pid" "$STATE_DIR/underlay.start"
}

underlay_recovered() {
  local expected_iface="$1" requested_ms="$2" expected_rebind="$3"
  local expected_wg_rebind="$4" status_file="$5"
  wireguard_endpoint_route_state_valid "$expected_iface" \
    && wireguard_interface >/dev/null \
    && fips_host_tunnel_route_live \
    && payload_after "$requested_ms" \
    && fips_payload_after "$requested_ms" \
    && runtime_dns_state_matches \
    && runtime_fips_peer_connected "$status_file" \
    && [[ "$(rebind_count)" == "$expected_rebind" ]] \
    && [[ "$(wireguard_rebind_count)" == "$expected_wg_rebind" ]] \
    && wireguard_last_rebind_target_is "$expected_iface"
}

wait_for_underlay_recovery() {
  local label="$1" expected_iface="$2" requested_ms="$3"
  local expected_rebind="$4" expected_wg_rebind="$5"
  local now elapsed status_file="$RESULT_DIR/fips-peer-$label.json"
  while true; do
    if underlay_recovered \
      "$expected_iface" "$requested_ms" "$expected_rebind" \
      "$expected_wg_rebind" "$status_file"
    then
      now="$(monotonic_ms)"
      elapsed=$((now - requested_ms))
      if (( elapsed < 0 || elapsed > RECOVERY_DEADLINE_MS )); then
        fail "$label recovered in ${elapsed}ms (limit ${RECOVERY_DEADLINE_MS}ms)"
        return 1
      fi
      printf '%s\n' "$elapsed"
      return 0
    fi
    now="$(monotonic_ms)"
    if (( now - requested_ms > RECOVERY_DEADLINE_MS )); then
      fail "$label did not restore WireGuard + authenticated private-FIPS payload, route, FIPS carrier rebind, and fresh WireGuard handshake on $expected_iface in ${RECOVERY_DEADLINE_MS}ms"
      return 1
    fi
    sleep 0.1
  done
}

run_underlay_gate() {
  local payload_pid fips_payload_pid baseline wg_baseline first_requested first_elapsed
  local second_requested second_elapsed fips_before_first fips_after_first
  local fips_before_second fips_after_second
  baseline="$(tr -d '[:space:]' <"$STATE_DIR/rebind-baseline")"
  wg_baseline="$(tr -d '[:space:]' <"$STATE_DIR/wireguard-rebind-baseline")"
  [[ "$baseline" =~ ^[0-9]+$ ]] || fail "invalid carrier-rebind baseline"
  [[ "$wg_baseline" =~ ^[0-9]+$ ]] || fail "invalid WG-rebind baseline"
  : >"$STATE_DIR/underlay-payload.tsv"
  : >"$STATE_DIR/underlay-fips-payload.tsv"
  payload_loop >>"$STATE_DIR/underlay-payload.tsv" 2>&1 &
  payload_pid="$!"
  printf '%s\n' "$payload_pid" >"$STATE_DIR/payload.pid"
  process_start_signature "$payload_pid" >"$STATE_DIR/payload.start"
  [[ -s "$STATE_DIR/payload.start" ]] \
    || fail "continuous payload process has no start-time receipt"
  fips_payload_loop >>"$STATE_DIR/underlay-fips-payload.tsv" 2>&1 &
  fips_payload_pid="$!"
  printf '%s\n' "$fips_payload_pid" >"$STATE_DIR/fips-payload.pid"
  process_start_signature "$fips_payload_pid" >"$STATE_DIR/fips-payload.start"
  [[ -s "$STATE_DIR/fips-payload.start" ]] \
    || fail "continuous private-FIPS payload has no start-time receipt"
  for _ in $(seq 1 20); do
    [[ "$(fips_payload_success_count)" -gt 0 ]] \
      && runtime_fips_peer_connected \
        "$RESULT_DIR/fips-peer-before-underlay.json" \
      && break
    sleep 0.1
  done
  [[ "$(fips_payload_success_count)" -gt 0 ]] \
    && runtime_fips_peer_connected \
      "$RESULT_DIR/fips-peer-before-underlay.json" \
    || fail "private-FIPS payload/session was not live before the first cut"
  capture_fips_host_tunnel_route >"$STATE_DIR/fips-route-interface" \
    || fail "private-FIPS payload is not routed through its distinct host tunnel"

  fips_before_first="$(fips_payload_success_count)"
  first_requested="$(monotonic_ms)"
  sudo -n /usr/sbin/networksetup \
    -setnetworkserviceenabled "$PRIMARY_SERVICE" off
  first_elapsed="$(
    wait_for_underlay_recovery \
      primary-to-secondary "$SECONDARY_IFACE" "$first_requested" \
      "$((baseline + 1))" "$((wg_baseline + 1))"
  )"
  fips_after_first="$(fips_payload_success_count)"
  (( fips_after_first > fips_before_first )) \
    || fail "primary-to-secondary produced no fresh private-FIPS ping"
  dns_query_works || fail "DNS failed after the secondary underlay recovered"
  captured_probe_works && https_works && exit_source_is_expected \
    || fail "exit traffic failed after the secondary underlay recovered"

  fips_before_second="$(fips_payload_success_count)"
  second_requested="$(monotonic_ms)"
  sudo -n /usr/sbin/networksetup \
    -setnetworkserviceenabled "$PRIMARY_SERVICE" on
  second_elapsed="$(
    wait_for_underlay_recovery \
      secondary-to-primary "$PRIMARY_IFACE" "$second_requested" \
      "$((baseline + 2))" "$((wg_baseline + 2))"
  )"
  fips_after_second="$(fips_payload_success_count)"
  (( fips_after_second > fips_before_second )) \
    || fail "secondary-to-primary produced no fresh private-FIPS ping"
  dns_query_works || fail "DNS failed after the primary underlay recovered"
  captured_probe_works && https_works && exit_source_is_expected \
    || fail "exit traffic failed after the primary underlay recovered"
  stop_owned_payload "$$" \
    || fail "owned continuous payload did not stop cleanly"
  stop_owned_fips_payload "$$" \
    || fail "owned private-FIPS payload did not stop cleanly"

  {
    printf 'primary_to_secondary_ms=%s\n' "$first_elapsed"
    printf 'secondary_to_primary_ms=%s\n' "$second_elapsed"
    printf 'endpoint_route_interface=%s\n' "$(endpoint_route_interface)"
    printf 'carrier_rebinds=%s->%s\n' "$baseline" "$(rebind_count)"
    printf 'wireguard_rebinds=%s->%s\n' \
      "$wg_baseline" "$(wireguard_rebind_count)"
    printf 'primary_to_secondary_fips_pings=%s->%s\n' \
      "$fips_before_first" "$fips_after_first"
    printf 'secondary_to_primary_fips_pings=%s->%s\n' \
      "$fips_before_second" "$fips_after_second"
    printf 'authenticated_fips_peer=%s\n' "$FIPS_PEER_NPUB"
    printf 'fips_route_interface=%s\n' \
      "$(tr -d '[:space:]' <"$STATE_DIR/fips-route-interface")"
    printf 'connected_peer_count=1\n'
  } >"$RESULT_DIR/underlay.txt"
  echo "MACOS_RELEASE_NETWORK_UNDERLAY_OK"
}

record_underlay_status_on_exit() {
  local status="$?"
  local cleanup_failed=0 recorded_pid=""
  trap - EXIT HUP INT TERM
  stop_owned_payload "$$" || cleanup_failed=1
  stop_owned_fips_payload "$$" || cleanup_failed=1
  restore_saved_service_states || cleanup_failed=1
  wait_until \
    "both original network-service states" saved_service_states_match \
    || cleanup_failed=1
  if [[ "$status" -ne 0 ]]; then
    repair_owned_network_to_direct || cleanup_failed=1
    wait_for_saved_direct_restore || cleanup_failed=1
  fi
  if [[ -f "$STATE_DIR/underlay.pid" ]]; then
    recorded_pid="$(tr -d '[:space:]' <"$STATE_DIR/underlay.pid")"
    if [[ "$recorded_pid" == "$$" ]]; then
      rm -f "$STATE_DIR/underlay.pid" "$STATE_DIR/underlay.start"
    else
      echo "underlay PID receipt does not belong to this runner" >&2
      cleanup_failed=1
    fi
  fi
  if [[ "$status" -eq 0 && "$cleanup_failed" -ne 0 ]]; then
    status=1
  fi
  if [[ "$status" -eq 0 ]]; then
    printf 'pass\n' >"$STATE_DIR/underlay.status"
  else
    printf 'fail:%s\n' "$status" >"$STATE_DIR/underlay.status"
  fi
  exit "$status"
}

run_underlay_with_status() {
  # Keep the core as a simple command under errexit. Placing the function in
  # an `||`/`if` condition disables `set -e` throughout its body in Bash and
  # can turn a failed route, payload, or rebind assertion into a false pass.
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap record_underlay_status_on_exit EXIT
  run_underlay_gate
}

start_underlay_gate() {
  [[ ! -e "$STATE_DIR/underlay.status" ]] \
    || fail "underlay action was already started"
  printf 'running\n' >"$STATE_DIR/underlay.status"
  nohup "$0" underlay-run \
    >"$RESULT_DIR/underlay-run.log" 2>&1 </dev/null &
  local underlay_pid="$!"
  printf '%s\n' "$underlay_pid" >"$STATE_DIR/underlay.pid"
  process_start_signature "$underlay_pid" >"$STATE_DIR/underlay.start"
  [[ -s "$STATE_DIR/underlay.start" ]] \
    || fail "detached underlay runner has no start-time receipt"
  echo "MACOS_RELEASE_NETWORK_UNDERLAY_STARTED"
}

wireguard_bind_receipt_count() {
  grep -Fc \
    " bound to $PRIMARY_IFACE (split-default kill switch installed)" \
    "$STATE_DIR/daemon.log" 2>/dev/null || true
}

crash_restart_state_live() {
  local expected_bind_receipts="$1" old_pid="$2" new_pid
  assert_single_owned_daemon || return 1
  new_pid="$(owned_daemon_pid)" || return 1
  [[ "$new_pid" != "$old_pid" \
    && "$(wireguard_bind_receipt_count)" == "$expected_bind_receipts" ]] \
    && runtime_wireguard_state_is true true \
    && runtime_dns_state_matches \
    && runtime_fips_peer_connected \
    && wireguard_routes_live \
    && fips_host_tunnel_route_live \
    && fips_payload_works
}

wait_for_crash_restart_recovery() {
  local requested_ms="$1" expected_bind_receipts="$2" old_pid="$3"
  local now elapsed wait_seconds
  wait_seconds=$(((RECOVERY_DEADLINE_MS + 999) / 1000))
  local WAIT_DEADLINE_SECONDS="$((SECONDS + wait_seconds))"
  while true; do
    now="$(monotonic_ms)"
    if ((now - requested_ms > RECOVERY_DEADLINE_MS)); then
      fail "crash restart did not restore one fresh daemon, tunnel, routes, DNS, authenticated FIPS payload, and WireGuard payload in ${RECOVERY_DEADLINE_MS}ms"
      return 1
    fi
    if crash_restart_state_live \
      "$expected_bind_receipts" "$old_pid"
    then
      now="$(monotonic_ms)"
      elapsed=$((now - requested_ms))
      if ((elapsed < 0 || elapsed > RECOVERY_DEADLINE_MS)); then
        fail "crash restart recovered in ${elapsed}ms (limit ${RECOVERY_DEADLINE_MS}ms)"
        return 1
      fi
      printf '%s\n' "$elapsed"
      return 0
    fi
    sleep 0.1
  done
}

run_crash_restart_gate() {
  local old_pid new_pid killed_ms restart_elapsed_ms bind_baseline
  local bind_receipts expected_bind_receipts
  assert_single_owned_daemon \
    || fail "SIGKILL gate did not start with exactly one owned daemon"
  if ! wait_for_crash_live_precondition; then
    capture_crash_external_failure
    fail "SIGKILL gate lacks live WireGuard, DNS, HTTPS, and FIPS state"
  fi
  old_pid="$(owned_daemon_pid)"
  bind_baseline="$(wireguard_bind_receipt_count)"
  [[ "$bind_baseline" =~ ^[1-9][0-9]*$ ]] \
    || fail "SIGKILL gate has no initial WireGuard bind receipt"

  killed_ms="$(monotonic_ms)"
  sudo -n /bin/kill -KILL "$old_pid"
  wait_until "the SIGKILLed production daemon to exit" no_nvpn_processes
  daemon_process_alive "$old_pid" \
    && fail "SIGKILLed production daemon is still alive"
  wait_until "fail-closed WireGuard route teardown after SIGKILL" \
    snapshot_crash_fail_closed_after_sigkill \
    "$RESULT_DIR/crash-external-after-sigkill-predicates.txt"
  record_crash_external_audit after-sigkill \
    || fail "SIGKILL did not remove the tunnel/routes or retain secure-DNS repair ownership"
  runtime_wireguard_state_is true false \
    || fail "stopped status did not distinguish the crashed daemon"
  record_crash_external_audit after-stopped-status \
    || fail "status inspection repaired or discarded the crash residue"

  privileged_nvpn start --config "$CONFIG" --connect --daemon \
    >"$RESULT_DIR/daemon-start-after-sigkill.txt"
  expected_bind_receipts="$((bind_baseline + 1))"
  if ! restart_elapsed_ms="$(
    wait_for_crash_restart_recovery \
      "$killed_ms" "$expected_bind_receipts" "$old_pid"
  )"
  then
    capture_wireguard_readiness_failure
    capture_fips_peer_readiness_failure
    return 1
  fi
  assert_single_owned_daemon \
    || fail "restart did not converge to exactly one owned daemon"
  new_pid="$(owned_daemon_pid)"
  [[ "$new_pid" != "$old_pid" ]] \
    || fail "restart reused the SIGKILLed daemon PID"
  record_crash_external_audit after-restart \
    || fail "restarted daemon did not restore the full external network state"
  bind_receipts="$(wireguard_bind_receipt_count)"
  [[ "$bind_receipts" == "$expected_bind_receipts" ]] \
    || fail "restart did not produce exactly one fresh WireGuard bind receipt"

  {
    printf 'startup_persist_path_completed=true\n'
    printf 'sigkill_tunnel_routes_absent=true\n'
    printf 'sigkill_secure_dns_ownership_seen=true\n'
    printf 'old_pid=%s\n' "$old_pid"
    printf 'new_pid=%s\n' "$new_pid"
    printf 'restart_payload_ms=%s\n' "$restart_elapsed_ms"
    printf 'wireguard_interface=%s\n' "$(wireguard_interface)"
    printf 'endpoint_route_interface=%s\n' "$(endpoint_route_interface)"
    printf 'exit_source_ip=%s\n' "$(source_ip)"
    printf 'dns_label=%s\n' "$DNS_LABEL"
    printf 'dns_mode=%s\n' "$DNS_MODE"
    printf 'authenticated_fips_peer=%s\n' "$FIPS_PEER_NPUB"
    printf 'connected_peer_count=1\n'
  } >"$RESULT_DIR/crash-restart.txt"
  echo "MACOS_RELEASE_NETWORK_CRASH_RESTART_OK"
}

direct_state_matches() {
  local expected_iface expected_gateway expected_source
  expected_iface="$(cat "$STATE_DIR/direct-interface")"
  expected_gateway="$(cat "$STATE_DIR/direct-gateway")"
  expected_source="$(cat "$STATE_DIR/direct-source-ip")"
  [[ "$(route_value default interface)" == "$expected_iface" \
    && "$(route_value default gateway)" == "$expected_gateway" \
    && "$(endpoint_route_interface)" == "$expected_iface" \
    && "$(source_ip)" == "$expected_source" ]] \
    && wireguard_split_defaults_absent \
    && resolver_files_absent \
    && direct_dns_query_works \
    && https_works
}

exact_direct_dns_matches() {
  /usr/sbin/scutil --dns >"$STATE_DIR/final-scutil-dns"
  normalize_scutil_dns_file \
    "$STATE_DIR/final-scutil-dns" "$STATE_DIR/final-scutil-dns.normalized"
  /usr/sbin/networksetup -getdnsservers "$PRIMARY_SERVICE" \
    >"$STATE_DIR/final-primary-dns"
  /usr/sbin/networksetup -getdnsservers "$SECONDARY_SERVICE" \
    >"$STATE_DIR/final-secondary-dns"
  cmp -s \
    "$STATE_DIR/direct-scutil-dns.normalized" \
    "$STATE_DIR/final-scutil-dns.normalized" \
    && cmp -s "$STATE_DIR/direct-primary-dns" "$STATE_DIR/final-primary-dns" \
    && cmp -s "$STATE_DIR/direct-secondary-dns" "$STATE_DIR/final-secondary-dns"
}

saved_direct_baseline_available() {
  local path
  for path in \
    direct-interface \
    direct-gateway \
    direct-source-ip \
    direct-dns-probe-host \
    direct-scutil-dns.normalized \
    direct-primary-dns \
    direct-secondary-dns \
    primary-service-state \
    secondary-service-state
  do
    [[ -s "$STATE_DIR/$path" ]] || return 1
  done
}

saved_service_states_match() {
  [[ "$(service_state "$PRIMARY_SERVICE")" \
      == "$(cat "$STATE_DIR/primary-service-state")" \
    && "$(service_state "$SECONDARY_SERVICE")" \
      == "$(cat "$STATE_DIR/secondary-service-state")" ]]
}

restore_saved_service_states() {
  saved_direct_baseline_available || return 1
  local failed=0
  set_service_state \
    "$PRIMARY_SERVICE" "$(cat "$STATE_DIR/primary-service-state")" \
    >/dev/null || failed=1
  set_service_state \
    "$SECONDARY_SERVICE" "$(cat "$STATE_DIR/secondary-service-state")" \
    >/dev/null || failed=1
  return "$failed"
}

repair_owned_network_to_direct() {
  local failed=0
  if [[ -f "$CONFIG" ]]; then
    nvpn set --config "$CONFIG" --exit-node "" >/dev/null 2>&1 \
      || failed=1
    privileged_nvpn stop --config "$CONFIG" --timeout-secs 8 --force \
      >/dev/null 2>&1 || failed=1
    privileged_nvpn repair-network --config "$CONFIG" \
      >/dev/null 2>&1 || failed=1
  fi
  return "$failed"
}

wait_for_saved_direct_restore() {
  local WAIT_DEADLINE_SECONDS="$((SECONDS + WAIT_SECS))"
  saved_direct_baseline_available || {
    echo "saved Direct baseline is incomplete" >&2
    return 1
  }
  wait_until \
    "the original route, source IP, DNS, and HTTPS" direct_state_matches \
    && wait_until \
      "the original semantic and per-service DNS state" exact_direct_dns_matches \
    && wait_until \
      "both original network-service states" saved_service_states_match
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
  saved_service_states_match \
    || fail "guest network-service state was not restored"
  wait_until "the exact effective and per-service Direct DNS baseline" \
    exact_direct_dns_matches
  {
    printf 'direct_interface=%s\n' "$(route_value default interface)"
    printf 'direct_gateway=%s\n' "$(route_value default gateway)"
    printf 'direct_source_ip=%s\n' "$(source_ip)"
    printf 'resolver_state_absent=true\n'
  } >"$RESULT_DIR/direct.txt"
  echo "MACOS_RELEASE_NETWORK_DIRECT_OK"
}

cleanup_gate() {
  local cleanup_failed=0 underlay_owner=""
  if [[ -f "$STATE_DIR/underlay.pid" ]]; then
    underlay_owner="$(tr -d '[:space:]' <"$STATE_DIR/underlay.pid")"
    stop_owned_underlay_runner || cleanup_failed=1
  fi
  if [[ -f "$STATE_DIR/payload.pid" ]]; then
    if [[ "$underlay_owner" =~ ^[1-9][0-9]*$ ]]; then
      stop_owned_payload "$underlay_owner" || cleanup_failed=1
    else
      echo "payload receipt survived without an owned underlay PID" >&2
      cleanup_failed=1
    fi
  fi
  if [[ -f "$STATE_DIR/fips-payload.pid" ]]; then
    if [[ "$underlay_owner" =~ ^[1-9][0-9]*$ ]]; then
      stop_owned_fips_payload "$underlay_owner" || cleanup_failed=1
    else
      echo "private-FIPS payload receipt survived without an owned underlay PID" >&2
      cleanup_failed=1
    fi
  fi
  repair_owned_network_to_direct || cleanup_failed=1
  if saved_direct_baseline_available; then
    restore_saved_service_states || cleanup_failed=1
    wait_for_saved_direct_restore || cleanup_failed=1
  else
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
  fi
  if pgrep -x nvpn >/dev/null 2>&1; then
    echo "owned or foreign nvpn process survived macOS network cleanup" >&2
    cleanup_failed=1
  fi
  if ! resolver_files_absent; then
    echo "nvpn resolver state survived production cleanup" >&2
    cleanup_failed=1
  fi
  return "$cleanup_failed"
}

validate_inputs
case "$ACTION" in
  initialize) initialize_gate ;;
  prepare) prepare_gate ;;
  dns-case) set_dns_case ;;
  underlay-start) start_underlay_gate ;;
  underlay-run) run_underlay_with_status ;;
  crash-restart) run_crash_restart_gate ;;
  direct) select_direct_and_stop ;;
  cleanup) cleanup_gate ;;
  *) fail "unknown action: ${ACTION:-empty}" ;;
esac
