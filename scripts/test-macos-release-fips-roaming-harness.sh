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
  'prepare_host_fips_peer_binary' \
  'fips-peer-host-receipt.json' \
  'import_host_fips_peer_binary' \
  'mktemp -d /tmp/nvpn-macos-fips-peer.XXXXXX' \
  'Vader peer binary differs from the host-built immutable artifact' \
  'NVPN_MACOS_FIPS_PEER_BINARY_SHA256' \
  'fips_peer_remote clean-audit' \
  'preserving its state' \
  'test ! -e "$FIPS_PEER_REMOTE_DIR"'
require_tokens "$REMOTE_PEER" "owned unique production peer" \
  'EXPECTED_BINARY_SHA256' \
  'EXPECTED_APP_SHA' \
  'DAEMON_PID_FILE="$STATE_DIR/fixture-daemon.pid"' \
  'DAEMON_START_FILE="$STATE_DIR/fixture-daemon.start"' \
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
  'status_file="$RESULT_DIR/fips-peer-$label.json"' \
  'primary-to-secondary' \
  'secondary-to-primary' \
  'primary_to_secondary_fips_pings=' \
  'secondary_to_primary_fips_pings=' \
  'RECOVERY_DEADLINE_MS'
require_tokens "$GUEST" "production daemon PID record ownership" \
  'json.load(handle)' \
  'record.get("config_path") != config_path' \
  'record.get("pid")' \
  'ps -ww -p "$pid" -o command='
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
EXPECTED_PEER="npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq"
STATUS_GOOD="$TMP_ROOT/status-good.json"
STATUS_WRONG="$TMP_ROOT/status-wrong.json"
STATUS_ZERO="$TMP_ROOT/status-zero.json"
STATUS_TWO="$TMP_ROOT/status-two.json"
python3 - \
  "$STATUS_GOOD" "$STATUS_WRONG" "$STATUS_ZERO" "$STATUS_TWO" "$EXPECTED_PEER" <<'PY'
import json
import sys

good, wrong, zero, two, expected = sys.argv[1:]

def payload(count, peers):
    return {
        "status_source": "daemon",
        "daemon": {
            "running": True,
            "state": {
                "mesh_ready": True,
                "connected_peer_count": count,
                "listen_port": 51990,
                "fips_core_version": "0.4.44 (rev 0123456789)",
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
}
for path, value in fixtures.items():
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(value, handle)
        handle.write("\n")
PY

bash -s -- \
  "$DEFINITIONS" "$TMP_ROOT" "$EXPECTED_PEER" \
  "$STATUS_GOOD" "$STATUS_WRONG" "$STATUS_ZERO" "$STATUS_TWO" <<'BASH'
set -euo pipefail
definitions="$1"
state="$2"
expected="$3"
shift 3
good="$1"
wrong="$2"
zero="$3"
two="$4"
set -- definitions-only
# shellcheck disable=SC1090
source "$definitions"
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
fips_route_interface() { printf '%s\n' "${FIPS_ROUTE_INTERFACE:-utun8}"; }
fips_route_interface_owns_tunnel_ip() {
  return "${FIPS_ROUTE_ADDRESS_STATUS:-0}"
}
payload_after() { return 0; }
fips_payload_after() { return "${FIPS_PAYLOAD_STATUS:-0}"; }
runtime_fips_peer_connected() { return "${FIPS_STATUS_STATUS:-0}"; }
rebind_count() { printf '1\n'; }
printf 'utun8\n' >"$state/fips-route-interface"
underlay_recovered en2 1000 1 "$state/transition.json"
FIPS_ROUTE_INTERFACE=utun9
if underlay_recovered en2 1000 1 "$state/transition.json"; then
  echo "transition accepted private payload through the WireGuard interface" >&2
  exit 1
fi
FIPS_ROUTE_INTERFACE=en2
if underlay_recovered en2 1000 1 "$state/transition.json"; then
  echo "transition accepted private payload through the physical underlay" >&2
  exit 1
fi
FIPS_ROUTE_INTERFACE=utun8
FIPS_ROUTE_ADDRESS_STATUS=1
if underlay_recovered en2 1000 1 "$state/transition.json"; then
  echo "transition accepted a route through a utun that does not own the nVPN address" >&2
  exit 1
fi
FIPS_ROUTE_ADDRESS_STATUS=0
FIPS_PAYLOAD_STATUS=1
if underlay_recovered en2 1000 1 "$state/transition.json"; then
  echo "transition passed without fresh private-FIPS payload" >&2
  exit 1
fi
FIPS_PAYLOAD_STATUS=0
FIPS_STATUS_STATUS=1
if underlay_recovered en2 1000 1 "$state/transition.json"; then
  echo "transition passed without one authenticated FIPS peer" >&2
  exit 1
fi
BASH

echo "MACOS_RELEASE_FIPS_ROAMING_HARNESS_OK"
