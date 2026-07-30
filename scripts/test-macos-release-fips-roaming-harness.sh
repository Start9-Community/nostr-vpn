#!/usr/bin/env bash
# Source/adversarial contract for the imported real-FIPS macos-utm roaming lane.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTROLLER="$ROOT/scripts/macos-vm-desktop-wireguard-exit-e2e.sh"
GUEST="$ROOT/scripts/e2e-macos-release-network.sh"
REMOTE_PEER="$ROOT/scripts/macos-release-fips-peer-remote.sh"
HOST_PREP="$ROOT/scripts/prepare-macos-release-fips-peer.sh"
RELEASE_GATE="$ROOT/scripts/release-gate.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/nvpn-macos-fips-roaming.XXXXXX")"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

fail() {
  echo "macOS Release FIPS roaming source contract failed: $*" >&2
  exit 1
}

require_tokens() {
  local path="$1" label="$2"
  shift 2
  local token
  for token in "$@"; do
    grep -Fq -- "$token" "$path" \
      || fail "$label is missing: $token"
  done
}

for path in "$CONTROLLER" "$GUEST" "$REMOTE_PEER" "$HOST_PREP"; do
  bash -n "$path"
done

require_tokens "$HOST_PREP" "host-only immutable peer preparation" \
  '[[ "$(uname -s)" == "Darwin" ]]' \
  'x86_64-unknown-linux-musl' \
  'build-nvpn-linux-musl' \
  'builtOnHostMac' \
  '"builtOnRemoteVm": False' \
  '"appGitSha": app_sha' \
  '"appGitTree": app_tree' \
  '"fipsGitSha": fips_sha' \
  '"fipsGitTree": fips_tree' \
  '"binarySha256": hashlib.sha256' \
  'verify_artifact'
require_tokens "$RELEASE_GATE" "parallel macOS preparation" \
  'prepare-macos-release-fips-peer.sh' \
  'peer_build_pid="$!"' \
  'wait "$peer_build_pid"'
require_tokens "$CONTROLLER" "host import and exact receipts" \
  'HTTP_PROBE_PORT="${NVPN_MACOS_WG_HTTP_PROBE_PORT:-$HOST_PORT}"' \
  'FIXTURE_HOST="${NVPN_MACOS_WG_FIXTURE_IPV4:-}"' \
  'discover_remote_fixture_ipv4' \
  'requires a reachable numeric IPv4 WireGuard endpoint' \
  'FIPS_FIXTURE_HOST=' \
  'remote FIPS peer must use its separate numeric IPv6 address' \
  'prepare_host_fips_peer_binary' \
  'fips-peer-host-receipt.json' \
  'import_host_fips_peer_binary' \
  'mktemp -d /tmp/nvpn-macos-fips-peer.XXXXXX' \
  'Vader peer binary differs from the host-built immutable artifact' \
  'NVPN_MACOS_FIPS_PEER_BINARY_SHA256' \
  '"NVPN_MACOS_FIPS_PEER_BINARY=$FIPS_PEER_REMOTE_DIR/nvpn"' \
  '"$fixture_ssh:$FIPS_PEER_REMOTE_DIR/nvpn"' \
  'fips_peer_remote clean-audit' \
  'capture_fips_peer_failure' \
  'fips-peer-failure-status.json' \
  'fips-peer-failure-listener.txt' \
  'fips-peer-failure-logs.txt' \
  'preserving its state' \
  'test ! -e "$FIPS_PEER_REMOTE_DIR"' \
  'remote_phase secondary crash-restart' \
  'macOS SIGKILL/restart WireGuard bytes' \
  'fips-peer-after-crash-restart.json'
require_tokens "$REMOTE_PEER" "owned unique production peer" \
  'EXPECTED_BINARY_SHA256' \
  'EXPECTED_APP_SHA' \
  'DAEMON_PID_FILE="$STATE_DIR/fixture-daemon.pid"' \
  'DAEMON_START_FILE="$STATE_DIR/fixture-daemon.start"' \
  '[[ "$BINARY" == "${STATE_DIR%/state}/nvpn" ]]' \
  'process_start_signature' \
  'daemon_pid_owned' \
  'nvpn_require_single_udp_listener' \
  'so_reuseport_ambiguity=false' \
  '--fips-advertise-public-endpoint false' \
  '--fips-nostr-discovery-enabled false' \
  '--fips-bootstrap-enabled false' \
  'state.get("connected_peer_count") == 1' \
  'peers[0].get("npub") == target' \
  'peer_tunnel_route_live' \
  ')" && peer_tunnel_route_live; then' \
  'ip -4 route get "$TARGET_TUNNEL_IP"' \
  '" dev $TUN_IFACE "' \
  'built_on_remote_vm=false'
require_tokens "$REMOTE_PEER" "pre-cleanup peer log retention" \
  'log_tails' \
  'daemon.stderr.log' \
  'private-payload.log' \
  'log-tails) log_tails'
if grep -Fq 'nvpn-peer' "$CONTROLLER" \
  || grep -Fq 'nvpn-peer' "$REMOTE_PEER"
then
  fail "remote peer fixture renames nvpn and breaks production daemon discovery"
fi
if grep -Fq 'DAEMON_PID_FILE="$STATE_DIR/daemon.pid"' "$REMOTE_PEER"; then
  fail "remote peer fixture overwrites nvpn's production JSON daemon PID record"
fi
if grep -Fq -- '--fips-advertise-public-endpoint true' "$REMOTE_PEER"; then
  fail "known-npub/static-endpoint peer still advertises itself"
fi
for forbidden in \
  'cargo build' \
  'cargo run' \
  'rustc ' \
  'gcc ' \
  'clang ' \
  'apt-get ' \
  'dnf ' \
  'xcodebuild'
do
  if grep -Fq "$forbidden" "$REMOTE_PEER"; then
    fail "remote imported-peer runner can compile/install: $forbidden"
  fi
done

require_tokens "$GUEST" "per-transition authenticated FIPS evidence" \
  '--fips-peer-endpoint "${FIPS_PEER_NPUB}=${FIPS_PEER_ENDPOINT}"' \
  '--fips-advertise-public-endpoint false' \
  'status --config "$CONFIG" --json --discover-secs 0' \
  'runtime_fips_peer_connected' \
  'state.get("connected_peer_count") == 1' \
  'state.get("listen_port") == int(expected_listen_port)' \
  'peers[0].get("npub") == expected_peer' \
  'address.get("addr") == expected_endpoint' \
  'fips_payload_loop' \
  'fips_payload_after "$requested_ms"' \
  'fips_host_tunnel_route_live' \
  'fips_route_interface_owns_tunnel_ip "$actual_iface"' \
  'fips-route-interface' \
  'runtime_fips_peer_connected "$status_file"' \
  'wireguard_endpoint_route_state_valid "$expected_iface"' \
  'wireguard_last_rebind_target_is "$expected_iface"' \
  'wireguard_rebind_count' \
  'runtime_dns_state_matches' \
  'status_file="$RESULT_DIR/fips-peer-$label.json"' \
  'primary-to-secondary' \
  'secondary-to-primary' \
  'primary_to_secondary_fips_pings=' \
  'secondary_to_primary_fips_pings=' \
  'RECOVERY_DEADLINE_MS'
require_tokens "$GUEST" "exact IPv4 WireGuard endpoint route evidence" \
  'ipv4_route_table' \
  '"$endpoint_iface" == "$wg_iface"' \
  '"$physical_default_iface" == "$expected_underlay"' \
  '$2 == gateway && $4 == interface' \
  'routes == 1 && matching == 1'
require_tokens "$GUEST" "real crash/restart cleanup evidence" \
  'run_crash_restart_gate' \
  'cleanup_journal_owns_wireguard_and_dns' \
  'sudo -n /bin/kill -KILL "$old_pid"' \
  'runtime_wireguard_state_is true false' \
  'privileged_nvpn start --config "$CONFIG" --connect --daemon' \
  'restart did not converge to exactly one owned daemon' \
  'restart did not produce exactly one fresh WireGuard bind receipt' \
  'daemon.cleanup.json' \
  'MACOS_RELEASE_NETWORK_CRASH_RESTART_OK'
require_tokens "$GUEST" "production daemon PID record ownership" \
  'json.load(handle)' \
  'record.get("config_path") != config_path' \
  'record.get("pid")' \
  'ps -ww -p "$pid" -o command='
require_tokens "$GUEST" "failure diagnostics survive cleanup" \
  'capture_wireguard_readiness_failure' \
  'capture_fips_peer_readiness_failure' \
  'fips-peer-readiness-status.json' \
  'fips-peer-readiness-daemon.log' \
  'endpoint_route_state_valid=' \
  'wireguard-readiness-failure.txt' \
  'wireguard-readiness-routes.txt' \
  'wireguard-readiness-dns.txt' \
  'wireguard-readiness-status.json' \
  'wireguard-readiness-daemon.log'
require_tokens "$CONTROLLER" "frozen product and clean harness separation" \
  'NVPN_MACOS_IMPORTED_PRODUCT_GIT_SHA' \
  'NVPN_MACOS_IMPORTED_PRODUCT_GIT_TREE' \
  'HARNESS_GIT_SHA' \
  'release_join_assert_app_unchanged "$HARNESS_GIT_SHA" "$HARNESS_GIT_TREE"' \
  'imported macOS product override crosses non-harness change'
require_tokens "$GUEST" "wall-clock-bounded readiness waits" \
  'local WAIT_DEADLINE_SECONDS="$((SECONDS + WAIT_SECS))"' \
  'while ((SECONDS < WAIT_DEADLINE_SECONDS)); do' \
  'local limit="$1"' \
  'local remaining="$limit"' \
  'timeout="$(wait_budget_seconds 8)"'
if grep -Fq 'local limit="$1" remaining="$limit"' "$GUEST"; then
  fail "macOS wait budget expands a same-declaration local before assignment"
fi
if grep -Fq 'local attempts=$((WAIT_SECS * 5))' "$GUEST"; then
  fail "macOS readiness multiplies blocking network probes by an attempt count"
fi
if grep -Fq 'wait_for_cleanup_condition' "$GUEST"; then
  fail "macOS cleanup retains a second attempt-count wait implementation"
fi
require_tokens "$GUEST" "SIGPIPE-safe secure DNS ownership" \
  'secure_dns_store_state' \
  'SECURE_DNS_STORE_KEY=' \
  'SupplementalMatchDomains : <array>' \
  '[[ "$state" == "$expected" ]]'
secure_dns_source="$(sed -n '/^secure_dns_owned() {/,/^}/p' "$GUEST")"
if [[ "$secure_dns_source" == *'| grep'* ]]; then
  fail "macOS secure-DNS ownership can misread scutil SIGPIPE as resolver loss"
fi
require_tokens "$GUEST" "global secure DNS replaces the suffix-only resolver" \
  '[[ ! -e "$SECURE_RESOLVER" && -f "$MAGIC_RESOLVER" ]]' \
  'secure_dns_store_owned' \
  'secure_dns_store_absent'
require_tokens "$GUEST" "process-stable macOS monotonic clock" \
  'mach_continuous_time' \
  'mach_timebase_info' \
  'failed to read the macOS monotonic clock timebase'
if grep -Fq 'time.monotonic()' "$GUEST"; then
  fail "macOS recovery timing still uses Python's process-relative monotonic origin"
fi
if grep -Fq "tr -d '[:space:]' <\"\$STATE_DIR/daemon.pid\"" "$GUEST"; then
  fail "macOS guest still treats nvpn's JSON daemon PID record as plain digits"
fi
require_tokens "$CONTROLLER" "real bidirectional private payload" \
  'fips_peer_remote wait-ready'
if grep -Fq 'macOS underlay reverse private-FIPS ping replies' "$CONTROLLER"; then
  fail "controller accepts remote pings that may all predate both underlay cuts"
fi

DEFINITIONS="$TMP_ROOT/definitions.sh"
sed '/^validate_inputs$/,$d' "$GUEST" >"$DEFINITIONS"
bash -s -- "$DEFINITIONS" <<'BASH'
set -euo pipefail
definitions="$1"
set -- definitions-only
# shellcheck disable=SC1090
source "$definitions"
ENDPOINT_FAMILY=ipv4
ENDPOINT_HOST=65.109.48.91
PRIMARY_IFACE=en0
SECONDARY_IFACE=en2
GLOBAL_ENDPOINT_IFACE=utun9
PHYSICAL_DEFAULT_IFACE=en0
PHYSICAL_DEFAULT_GATEWAY=192.168.64.1
ROUTE_TABLE='65.109.48.91 192.168.64.1 UGHS en0'

endpoint_route_interface() {
  printf '%s\n' "$GLOBAL_ENDPOINT_IFACE"
}
wireguard_interface() {
  printf 'utun9\n'
}
route_value() {
  case "$1:$2" in
    default:interface) printf '%s\n' "$PHYSICAL_DEFAULT_IFACE" ;;
    default:gateway) printf '%s\n' "$PHYSICAL_DEFAULT_GATEWAY" ;;
    *) return 1 ;;
  esac
}
ipv4_route_table() {
  printf '%s\n' "$ROUTE_TABLE"
}

wireguard_endpoint_route_state_valid

PHYSICAL_DEFAULT_IFACE=en2
PHYSICAL_DEFAULT_GATEWAY=10.0.2.1
ROUTE_TABLE='65.109.48.91 10.0.2.1 UGHS en2'
wireguard_endpoint_route_state_valid en2

PHYSICAL_DEFAULT_IFACE=en0
PHYSICAL_DEFAULT_GATEWAY=192.168.64.1
for ROUTE_TABLE in \
  '65.109.48.91 192.168.64.254 UGHS en0' \
  '65.109.48.91 192.168.64.1 UGHS en2' \
  $'65.109.48.91 192.168.64.1 UGHS en0\n65.109.48.91 192.168.64.1 UGHS en0'
do
  if wireguard_endpoint_route_state_valid; then
    echo "invalid macOS endpoint /32 tuple was accepted: $ROUTE_TABLE" >&2
    exit 1
  fi
done

ROUTE_TABLE='65.109.48.91 192.168.64.1 UGHS en0'
GLOBAL_ENDPOINT_IFACE=en0
if wireguard_endpoint_route_state_valid; then
  echo "global endpoint lookup escaped the WireGuard split default" >&2
  exit 1
fi
GLOBAL_ENDPOINT_IFACE=utun9
PHYSICAL_DEFAULT_IFACE=en2
if wireguard_endpoint_route_state_valid; then
  echo "endpoint /32 on a stale physical underlay was accepted" >&2
  exit 1
fi
if wireguard_endpoint_route_state_valid utun9; then
  echo "tunnel interface was accepted as a physical endpoint underlay" >&2
  exit 1
fi
BASH

REMOTE_DEFINITIONS="$TMP_ROOT/remote-definitions.sh"
sed -n '/^peer_status_is_ready() {/,/^}/p' "$REMOTE_PEER" \
  >"$REMOTE_DEFINITIONS"
EXPECTED_PEER="npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq"
STATUS_GOOD="$TMP_ROOT/status-good.json"
STATUS_WRONG="$TMP_ROOT/status-wrong.json"
STATUS_ZERO="$TMP_ROOT/status-zero.json"
STATUS_TWO="$TMP_ROOT/status-two.json"
STATUS_NULL="$TMP_ROOT/status-null.json"
ROUTES_WASCLONED="$TMP_ROOT/routes-wascloned.txt"
ROUTES_MIXED="$TMP_ROOT/routes-mixed.txt"
ROUTES_WRONG="$TMP_ROOT/routes-wrong.txt"
cat >"$ROUTES_WASCLONED" <<'EOF'
Routing tables

Internet:
Destination        Gateway            Flags               Netif Expire
default            192.168.64.1       UGScg                 en0
0/1                utun5              USc                 utun5
1.0.0.1            utun5              UHWIi               utun5
128.0/1            utun5              USc                 utun5
192.168.178.91     192.168.64.1       UGHSI                 en0
EOF
awk '
  $1 == "128.0/1" { $2 = "utun6"; $4 = "utun6" }
  { print }
' "$ROUTES_WASCLONED" >"$ROUTES_MIXED"
sed 's/utun5/en0/g' "$ROUTES_WASCLONED" >"$ROUTES_WRONG"
python3 - \
  "$STATUS_GOOD" "$STATUS_WRONG" "$STATUS_ZERO" "$STATUS_TWO" \
  "$STATUS_NULL" "$EXPECTED_PEER" <<'PY'
import json
import sys

good, wrong, zero, two, null, expected = sys.argv[1:]

def payload(count, peers):
    return {
        "status_source": "daemon",
        "daemon": {
            "running": True,
            "state": {
                "mesh_ready": True,
                "connected_peer_count": count,
                "listen_port": 51990,
                "fips_core_version": "0.4.45 (rev 0123456789)",
                "fips_endpoint_peers": [
                    {
                        "npub": peer,
                        "addresses": [{"addr": "[2001:db8::1]:51989"}],
                    }
                    for peer in peers
                ],
            },
        },
    }

fixtures = {
    good: payload(1, [expected]),
    wrong: payload(1, ["npub1wrong"]),
    zero: payload(0, [expected]),
    two: payload(2, [expected, "npub1other"]),
    null: {"status_source": "config", "daemon": {"running": False, "state": None}},
}
for path, value in fixtures.items():
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(value, handle)
        handle.write("\n")
PY

bash -s -- \
  "$DEFINITIONS" "$REMOTE_DEFINITIONS" "$TMP_ROOT" "$EXPECTED_PEER" \
  "$STATUS_GOOD" "$STATUS_WRONG" "$STATUS_ZERO" "$STATUS_TWO" \
  "$STATUS_NULL" "$ROUTES_WASCLONED" "$ROUTES_MIXED" "$ROUTES_WRONG" <<'BASH'
set -euo pipefail
definitions="$1"
remote_definitions="$2"
state="$3"
expected="$4"
shift 4
good="$1"
wrong="$2"
zero="$3"
two="$4"
null="$5"
wascloned="$6"
mixed="$7"
wrong_route="$8"
set -- definitions-only
# shellcheck disable=SC1090
source "$definitions"
ROUTE_FIXTURE="$wascloned"
ipv4_route_table() {
  cat "$ROUTE_FIXTURE"
}
actual_interface="$(wireguard_interface)" || {
  echo "split default rejected a normal WASCLONED host route" >&2
  exit 1
}
[[ "$actual_interface" == "utun5" ]] || {
  echo "split default returned the wrong interface: $actual_interface" >&2
  exit 1
}
for ROUTE_FIXTURE in "$mixed" "$wrong_route"; do
  if wireguard_interface >/dev/null; then
    echo "split default accepted mixed or non-utun route ownership" >&2
    exit 1
  fi
done
STATE_DIR="$state"
CONFIG="$state/config.toml"
FIPS_PEER_NPUB="$expected"
FIPS_PEER_ENDPOINT='[2001:db8::1]:51989'
FIPS_CLIENT_LISTEN_PORT=51990
EXPECTED_FIPS_REV=0123456789
STATUS_FIXTURE="$good"
nvpn() {
  cat "$STATUS_FIXTURE"
}
pgrep() {
  printf '%s\n' "$$"
}
ps() {
  printf '%s daemon --config %s --connect\n' "$NVPN_BIN" "$CONFIG"
}
NVPN_BIN="$state/nvpn"
printf '{"pid":%s,"config_path":"%s","started_at":1}\n' \
  "$$" "$CONFIG" >"$state/daemon.pid"
assert_single_owned_daemon
printf '%s\n' "$$" >"$state/daemon.pid"
if assert_single_owned_daemon 2>/dev/null; then
  echo "plain numeric PID receipt was accepted as nvpn's production record" >&2
  exit 1
fi
printf '{"pid":%s,"config_path":"%s","started_at":1}\n' \
  "$$" "$state/wrong-config.toml" >"$state/daemon.pid"
if assert_single_owned_daemon 2>/dev/null; then
  echo "daemon PID receipt for a different config was accepted" >&2
  exit 1
fi
printf '{"pid":%s,"config_path":"%s","started_at":1}\n' \
  "$$" "$CONFIG" >"$state/daemon.pid"
runtime_fips_peer_connected "$state/accepted.json"
for STATUS_FIXTURE in "$wrong" "$zero" "$two"; do
  if runtime_fips_peer_connected "$state/rejected.json"; then
    echo "invalid authenticated-peer status was accepted: $STATUS_FIXTURE" >&2
    exit 1
  fi
done

BINARY="$state/nvpn"
TARGET_NPUB="$expected"
LISTEN_PORT=51990
cat >"$BINARY" <<'FAKE'
#!/usr/bin/env bash
cat "$NVPN_FAKE_STATUS"
FAKE
chmod +x "$BINARY"
# shellcheck disable=SC1090
source "$remote_definitions"
NVPN_FAKE_STATUS="$good" peer_status_is_ready
if NVPN_FAKE_STATUS="$null" peer_status_is_ready \
  2>"$state/null-status.err" \
  || [[ -s "$state/null-status.err" ]]
then
  echo "remote readiness did not cleanly reject a null daemon state" >&2
  exit 1
fi

cat >"$state/daemon.cleanup.json" <<'EOF'
{
  "managed_routes": [
    {"target": "0.0.0.0/1", "interface": "utun9"},
    {"target": "128.0.0.0/1", "interface": "utun9"}
  ],
  "secure_dns_resolver_files": true
}
EOF
cleanup_journal_owns_wireguard_and_dns
printf '{"managed_routes":[],"secure_dns_resolver_files":true}\n' \
  >"$state/daemon.cleanup.json"
if cleanup_journal_owns_wireguard_and_dns; then
  echo "crash journal accepted without both WireGuard split defaults" >&2
  exit 1
fi

cat >"$state/underlay-fips-payload.tsv" <<EOF
999	$expected
1001	$expected
EOF
fips_payload_after 1000
if fips_payload_after 1002; then
  echo "private-FIPS payload freshness accepted a pre-cut packet" >&2
  exit 1
fi

endpoint_route_interface() { printf 'en2\n'; }
wireguard_interface() { printf 'utun9\n'; }
wireguard_endpoint_route_state_valid() { return 0; }
wireguard_last_rebind_target_is() {
  [[ "$1" == "${WG_REBIND_TARGET:-en2}" ]]
}
fips_route_interface() { printf '%s\n' "${FIPS_ROUTE_INTERFACE:-utun8}"; }
fips_route_interface_owns_tunnel_ip() {
  return "${FIPS_ROUTE_ADDRESS_STATUS:-0}"
}
payload_after() { return 0; }
fips_payload_after() { return "${FIPS_PAYLOAD_STATUS:-0}"; }
runtime_dns_state_matches() { return "${DNS_STATUS_STATUS:-0}"; }
runtime_fips_peer_connected() { return "${FIPS_STATUS_STATUS:-0}"; }
rebind_count() { printf '1\n'; }
wireguard_rebind_count() { printf '1\n'; }
printf 'utun8\n' >"$state/fips-route-interface"
underlay_recovered en2 1000 1 1 "$state/transition.json"
FIPS_ROUTE_INTERFACE=utun9
if underlay_recovered en2 1000 1 1 "$state/transition.json"; then
  echo "transition accepted private payload through the WireGuard interface" >&2
  exit 1
fi
FIPS_ROUTE_INTERFACE=en2
if underlay_recovered en2 1000 1 1 "$state/transition.json"; then
  echo "transition accepted private payload through the physical underlay" >&2
  exit 1
fi
FIPS_ROUTE_INTERFACE=utun8
FIPS_ROUTE_ADDRESS_STATUS=1
if underlay_recovered en2 1000 1 1 "$state/transition.json"; then
  echo "transition accepted a route through a utun that does not own the nVPN address" >&2
  exit 1
fi
FIPS_ROUTE_ADDRESS_STATUS=0
FIPS_PAYLOAD_STATUS=1
if underlay_recovered en2 1000 1 1 "$state/transition.json"; then
  echo "transition passed without fresh private-FIPS payload" >&2
  exit 1
fi
FIPS_PAYLOAD_STATUS=0
FIPS_STATUS_STATUS=1
if underlay_recovered en2 1000 1 1 "$state/transition.json"; then
  echo "transition passed without one authenticated FIPS peer" >&2
  exit 1
fi
FIPS_STATUS_STATUS=0
DNS_STATUS_STATUS=1
if underlay_recovered en2 1000 1 1 "$state/transition.json"; then
  echo "transition passed without the configured DNS runtime state" >&2
  exit 1
fi
DNS_STATUS_STATUS=0
WG_REBIND_TARGET=en0
if underlay_recovered en2 1000 1 1 "$state/transition.json"; then
  echo "transition accepted a fresh WireGuard handshake on the wrong underlay" >&2
  exit 1
fi
BASH

echo "MACOS_RELEASE_FIPS_ROAMING_HARNESS_OK"
