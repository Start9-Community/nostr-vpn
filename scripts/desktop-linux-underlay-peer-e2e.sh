#!/usr/bin/env bash
# Stable Linux peer/exit fixture for the physical desktop underlay-change gate.
# The shipped daemon runs in an isolated network namespace whose veth is its
# real default underlay. Both libvirt paths route to that veth while continuous
# payload, exit routing, and resolver traffic are observed on the peer side.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib-desktop-linux-listener-audit.sh"

ACTION="${1:-}"
BINARY="${NVPN_UNDERLAY_PEER_BINARY:?set NVPN_UNDERLAY_PEER_BINARY}"
STATE_DIR="${NVPN_UNDERLAY_PEER_STATE_DIR:?set NVPN_UNDERLAY_PEER_STATE_DIR}"
CONFIG="$STATE_DIR/config.toml"
NETWORK_ID="${NVPN_UNDERLAY_NETWORK_ID:-desktop-underlay-release-gate}"
TUN_IFACE="${NVPN_UNDERLAY_PEER_TUN_IFACE:-nvupeer0}"
LISTEN_PORT="${NVPN_UNDERLAY_PEER_LISTEN_PORT:-45820}"
PUBLIC_ENDPOINT="${NVPN_UNDERLAY_PEER_PUBLIC_ENDPOINT:-}"
TARGET_NPUB="${NVPN_UNDERLAY_TARGET_NPUB:-}"
TARGET_TUNNEL_IP="${NVPN_UNDERLAY_TARGET_TUNNEL_IP:-}"
FIXTURE_DNS_NAME="${NVPN_UNDERLAY_FIXTURE_DNS_NAME:-underlay-gate.nvpn.test}"
CHAIN="${NVPN_UNDERLAY_DNS_COUNTER_CHAIN:-nvu-dns-gate}"
PEER_NETNS="${NVPN_UNDERLAY_PEER_NETNS:-}"
PEER_HOST_VETH="${NVPN_UNDERLAY_PEER_HOST_VETH:-}"
PEER_NS_VETH="${NVPN_UNDERLAY_PEER_NS_VETH:-}"
PEER_HOST_ADDRESS="${NVPN_UNDERLAY_PEER_HOST_ADDRESS:-}"
PEER_ADDRESS="${NVPN_UNDERLAY_PEER_ADDRESS:-}"
PEER_PREFIX="${NVPN_UNDERLAY_PEER_PREFIX:-30}"
PEER_UPLINK="${NVPN_UNDERLAY_PEER_UPLINK:-}"
PEER_FORWARD_CHAIN="${NVPN_UNDERLAY_PEER_FORWARD_CHAIN:-}"
PEER_NAT_CHAIN="${NVPN_UNDERLAY_PEER_NAT_CHAIN:-}"
TARGET_PRIMARY_ADDRESS="${NVPN_UNDERLAY_TARGET_PRIMARY_ADDRESS:-}"
TARGET_SECONDARY_ADDRESS="${NVPN_UNDERLAY_TARGET_SECONDARY_ADDRESS:-}"
TARGET_LISTEN_PORT="${NVPN_UNDERLAY_TARGET_LISTEN_PORT:-}"
EXPECTED_FIPS_REV="${NVPN_UNDERLAY_EXPECTED_FIPS_REV:-}"
WG_IFACE="${NVPN_UNDERLAY_WG_PEER_IFACE:-nvuwg0}"
WG_LISTEN_PORT="${NVPN_UNDERLAY_WG_LISTEN_PORT:-}"
WG_SERVER_ADDRESS="${NVPN_UNDERLAY_WG_SERVER_ADDRESS:-10.232.0.1/24}"
WG_CLIENT_ADDRESS="${NVPN_UNDERLAY_WG_CLIENT_ADDRESS:-10.232.0.2/32}"
WG_TARGET_PUBLIC_KEY="${NVPN_UNDERLAY_WG_TARGET_PUBLIC_KEY:-}"
WG_PRIVATE_KEY_FILE="$STATE_DIR/wg-server-private.key"

require_root() {
  if [[ "$(id -u)" != "0" ]]; then
    echo "desktop underlay peer fixture must run as root" >&2
    exit 2
  fi
}

pid_alive() {
  local path="$1"
  [[ -s "$path" ]] || return 1
  local pid
  pid="$(<"$path")"
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$pid" 2>/dev/null
}

stop_pid_file() {
  local path="$1"
  if ! pid_alive "$path"; then
    rm -f "$path"
    return
  fi
  local pid
  pid="$(<"$path")"
  kill "$pid" 2>/dev/null || true
  for _ in $(seq 1 50); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  kill -KILL "$pid" 2>/dev/null || true
  rm -f "$path"
}

remove_counter_chain() {
  while iptables -t mangle -D PREROUTING -i "$TUN_IFACE" -j "$CHAIN" 2>/dev/null; do :; done
  while iptables -t mangle -D PREROUTING -i "$WG_IFACE" -j "$CHAIN" 2>/dev/null; do :; done
  iptables -t mangle -F "$CHAIN" 2>/dev/null || true
  iptables -t mangle -X "$CHAIN" 2>/dev/null || true
}

require_namespace_config() {
  local value
  for value in \
    "$PEER_NETNS" "$PEER_HOST_VETH" "$PEER_NS_VETH" \
    "$PEER_HOST_ADDRESS" "$PEER_ADDRESS" "$PEER_UPLINK" \
    "$PEER_FORWARD_CHAIN" "$PEER_NAT_CHAIN" \
    "$TARGET_PRIMARY_ADDRESS" "$TARGET_SECONDARY_ADDRESS" "$TARGET_LISTEN_PORT" \
    "$WG_LISTEN_PORT"
  do
    [[ -n "$value" ]] || {
      echo "peer namespace action is missing required routing configuration" >&2
      exit 2
    }
  done
}

namespace_cleanup() {
  while iptables -D FORWARD -j "$PEER_FORWARD_CHAIN" 2>/dev/null; do :; done
  iptables -F "$PEER_FORWARD_CHAIN" 2>/dev/null || true
  iptables -X "$PEER_FORWARD_CHAIN" 2>/dev/null || true
  while iptables -t nat -D POSTROUTING -j "$PEER_NAT_CHAIN" 2>/dev/null; do :; done
  iptables -t nat -F "$PEER_NAT_CHAIN" 2>/dev/null || true
  iptables -t nat -X "$PEER_NAT_CHAIN" 2>/dev/null || true
  ip netns del "$PEER_NETNS" 2>/dev/null || true
  ip link del "$PEER_HOST_VETH" 2>/dev/null || true
}

namespace_setup() {
  require_namespace_config
  namespace_cleanup
  [[ "$(sysctl -n net.ipv4.ip_forward)" == "1" ]] || {
    echo "hypervisor IPv4 forwarding must already be enabled" >&2
    exit 1
  }
  ! ip -4 route show exact "$PEER_ADDRESS/$PEER_PREFIX" | grep -q . || {
    echo "peer namespace route conflicts with an existing host route" >&2
    exit 1
  }

  ip netns add "$PEER_NETNS"
  ip link add "$PEER_HOST_VETH" type veth \
    peer name "$PEER_NS_VETH" netns "$PEER_NETNS"
  ip -4 address add "$PEER_HOST_ADDRESS/$PEER_PREFIX" dev "$PEER_HOST_VETH"
  ip link set "$PEER_HOST_VETH" up
  ip -n "$PEER_NETNS" link set lo up
  ip -n "$PEER_NETNS" link set "$PEER_NS_VETH" up
  ip -n "$PEER_NETNS" -4 address add \
    "$PEER_ADDRESS/$PEER_PREFIX" dev "$PEER_NS_VETH"
  ip -n "$PEER_NETNS" -4 route add default via "$PEER_HOST_ADDRESS"
  ip netns exec "$PEER_NETNS" sysctl -qw net.ipv4.ip_forward=1

  iptables -N "$PEER_FORWARD_CHAIN"
  iptables -A "$PEER_FORWARD_CHAIN" \
    -s "$TARGET_PRIMARY_ADDRESS" -d "$PEER_ADDRESS" \
    -p udp --dport "$LISTEN_PORT" -j ACCEPT
  iptables -A "$PEER_FORWARD_CHAIN" \
    -s "$TARGET_SECONDARY_ADDRESS" -d "$PEER_ADDRESS" \
    -p udp --dport "$LISTEN_PORT" -j ACCEPT
  iptables -A "$PEER_FORWARD_CHAIN" \
    -s "$TARGET_PRIMARY_ADDRESS" -d "$PEER_ADDRESS" \
    -p udp --dport "$WG_LISTEN_PORT" -j ACCEPT
  iptables -A "$PEER_FORWARD_CHAIN" \
    -s "$TARGET_SECONDARY_ADDRESS" -d "$PEER_ADDRESS" \
    -p udp --dport "$WG_LISTEN_PORT" -j ACCEPT
  iptables -A "$PEER_FORWARD_CHAIN" \
    -s "$PEER_ADDRESS" -d "$TARGET_PRIMARY_ADDRESS" \
    -p udp --sport "$LISTEN_PORT" --dport "$TARGET_LISTEN_PORT" -j ACCEPT
  iptables -A "$PEER_FORWARD_CHAIN" \
    -s "$PEER_ADDRESS" -d "$TARGET_SECONDARY_ADDRESS" \
    -p udp --sport "$LISTEN_PORT" --dport "$TARGET_LISTEN_PORT" -j ACCEPT
  iptables -A "$PEER_FORWARD_CHAIN" \
    -s "$PEER_ADDRESS" -d "$TARGET_PRIMARY_ADDRESS" \
    -p udp --sport "$WG_LISTEN_PORT" -j ACCEPT
  iptables -A "$PEER_FORWARD_CHAIN" \
    -s "$PEER_ADDRESS" -d "$TARGET_SECONDARY_ADDRESS" \
    -p udp --sport "$WG_LISTEN_PORT" -j ACCEPT
  iptables -A "$PEER_FORWARD_CHAIN" \
    -s "$PEER_ADDRESS" -o "$PEER_UPLINK" -j ACCEPT
  iptables -A "$PEER_FORWARD_CHAIN" -j RETURN
  iptables -I FORWARD 1 -j "$PEER_FORWARD_CHAIN"

  iptables -t nat -N "$PEER_NAT_CHAIN"
  # Preserve each target's real source address so the packet capture proves
  # the physical underlay move rather than observing a gateway masquerade.
  iptables -t nat -A "$PEER_NAT_CHAIN" \
    -s "$TARGET_PRIMARY_ADDRESS" -d "$PEER_ADDRESS" \
    -p udp --dport "$LISTEN_PORT" -j ACCEPT
  iptables -t nat -A "$PEER_NAT_CHAIN" \
    -s "$TARGET_SECONDARY_ADDRESS" -d "$PEER_ADDRESS" \
    -p udp --dport "$LISTEN_PORT" -j ACCEPT
  iptables -t nat -A "$PEER_NAT_CHAIN" \
    -s "$TARGET_PRIMARY_ADDRESS" -d "$PEER_ADDRESS" \
    -p udp --dport "$WG_LISTEN_PORT" -j ACCEPT
  iptables -t nat -A "$PEER_NAT_CHAIN" \
    -s "$TARGET_SECONDARY_ADDRESS" -d "$PEER_ADDRESS" \
    -p udp --dport "$WG_LISTEN_PORT" -j ACCEPT
  # Only exit traffic emitted by the isolated peer is masqueraded onto the
  # hypervisor's physical uplink.
  iptables -t nat -A "$PEER_NAT_CHAIN" \
    -s "$PEER_ADDRESS" -o "$PEER_UPLINK" -j MASQUERADE
  iptables -t nat -A "$PEER_NAT_CHAIN" -j RETURN
  iptables -t nat -I POSTROUTING 1 -j "$PEER_NAT_CHAIN"
}

namespace_audit() {
  require_namespace_config
  ! ip netns list | awk '{ print $1 }' | grep -Fxq "$PEER_NETNS"
  ! ip link show dev "$PEER_HOST_VETH" >/dev/null 2>&1
  ! iptables -S "$PEER_FORWARD_CHAIN" >/dev/null 2>&1
  ! iptables -t nat -S "$PEER_NAT_CHAIN" >/dev/null 2>&1
  ! iptables -S FORWARD | grep -Fq -- "-j $PEER_FORWARD_CHAIN"
  ! iptables -t nat -S POSTROUTING | grep -Fq -- "-j $PEER_NAT_CHAIN"
  echo "PEER_NAMESPACE_CLEANUP_AUDIT_OK"
}

wireguard_cleanup() {
  while iptables -D FORWARD -i "$WG_IFACE" -o "$PEER_NS_VETH" -j ACCEPT \
    2>/dev/null; do :; done
  while iptables -D FORWARD -i "$PEER_NS_VETH" -o "$WG_IFACE" \
    -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null; do :; done
  while iptables -t nat -D POSTROUTING -s "$WG_CLIENT_ADDRESS" \
    -o "$PEER_NS_VETH" -j MASQUERADE 2>/dev/null; do :; done
  ip link del "$WG_IFACE" 2>/dev/null || true
  rm -f "$WG_PRIVATE_KEY_FILE"
}

wireguard_setup() {
  [[ -n "$WG_LISTEN_PORT" && -n "$WG_TARGET_PUBLIC_KEY" ]] || {
    echo "WireGuard responder setup requires port and target public key" >&2
    exit 2
  }
  command -v wg >/dev/null
  wireguard_cleanup
  umask 077
  wg genkey >"$WG_PRIVATE_KEY_FILE"
  ip link add dev "$WG_IFACE" type wireguard
  ip address add "$WG_SERVER_ADDRESS" dev "$WG_IFACE"
  wg set "$WG_IFACE" \
    private-key "$WG_PRIVATE_KEY_FILE" \
    listen-port "$WG_LISTEN_PORT" \
    peer "$WG_TARGET_PUBLIC_KEY" \
    allowed-ips "$WG_CLIENT_ADDRESS"
  ip link set "$WG_IFACE" up
  iptables -I FORWARD 1 -i "$WG_IFACE" -o "$PEER_NS_VETH" -j ACCEPT
  iptables -I FORWARD 2 -i "$PEER_NS_VETH" -o "$WG_IFACE" \
    -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  iptables -t nat -I POSTROUTING 1 -s "$WG_CLIENT_ADDRESS" \
    -o "$PEER_NS_VETH" -j MASQUERADE
  printf 'wireguard_public_key=%s\n' "$(wg pubkey <"$WG_PRIVATE_KEY_FILE")"
  printf 'wireguard_endpoint=%s:%s\n' "$PEER_ADDRESS" "$WG_LISTEN_PORT"
}

wireguard_audit() {
  ip link show dev "$WG_IFACE" >/dev/null
  ip -4 address show dev "$WG_IFACE" | grep -Fq " ${WG_SERVER_ADDRESS%/*}/"
  wg show "$WG_IFACE" latest-handshakes \
    | awk 'NF == 2 && $2 + 0 > 0 { found = 1 } END { exit !found }'
  wg show "$WG_IFACE" transfer \
    | awk 'NF == 3 && $2 + 0 > 0 && $3 + 0 > 0 { found = 1 } END { exit !found }'
  echo "WIREGUARD_RESPONDER_TRAFFIC_OK"
}

initial_source_audit() {
  local capture
  for capture in fips-underlay.pcap.txt wireguard-underlay.pcap.txt; do
    [[ -s "$STATE_DIR/$capture" ]] || {
      echo "initial source audit is missing $capture" >&2
      exit 1
    }
    grep -Fq " IP $TARGET_PRIMARY_ADDRESS." "$STATE_DIR/$capture" || {
      echo "$capture has no primary-source traffic before the physical cut" >&2
      exit 1
    }
    if grep -Fq " IP $TARGET_SECONDARY_ADDRESS." "$STATE_DIR/$capture"; then
      echo "$capture has unexpected secondary-source traffic before the physical cut" >&2
      exit 1
    fi
  done
  echo "INITIAL_PRIMARY_SOURCE_AUDIT_OK"
}

cleanup() {
  stop_pid_file "$STATE_DIR/ping.pid"
  stop_pid_file "$STATE_DIR/tcpdump.pid"
  stop_pid_file "$STATE_DIR/wg-tcpdump.pid"
  stop_pid_file "$STATE_DIR/dnsmasq.pid"
  if [[ -x "$BINARY" && -f "$CONFIG" ]]; then
    "$BINARY" stop --config "$CONFIG" --timeout-secs 5 --force >/dev/null 2>&1 || true
    "$BINARY" repair-network --config "$CONFIG" >/dev/null 2>&1 || true
  fi
  stop_pid_file "$STATE_DIR/peer-process.pid"
  remove_counter_chain
  wireguard_cleanup
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

status_ready() {
  "$BINARY" status --config "$CONFIG" --json --discover-secs 0 2>/dev/null \
    | jq -e --arg rev "$EXPECTED_FIPS_REV" '
        .status_source == "daemon"
        and .daemon.running == true
        and .daemon.state.mesh_ready == true
        and .daemon.state.connected_peer_count >= 1
        and (.daemon.state.fips_core_version | endswith("(rev " + $rev + ")"))
      ' >/dev/null
}

wait_for_peer_tun() {
  for _ in $(seq 1 300); do
    if ip -4 address show dev "$TUN_IFACE" 2>/dev/null \
      | grep -Fq " $("$BINARY" ip --config "$CONFIG")/"; then
      return 0
    fi
    sleep 0.1
  done
  echo "peer tunnel interface did not become ready" >&2
  return 1
}

listener_audit() {
  local default_iface expected_pid listener_row rows
  default_iface="$(
    ip -4 route get 1.1.1.1 \
      | awk '{ for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit } }'
  )"
  [[ "$default_iface" == "$PEER_NS_VETH" ]] || {
    echo "peer namespace default route is not its isolated veth" >&2
    exit 1
  }
  pid_alive "$STATE_DIR/peer-process.pid" || {
    echo "peer daemon PID is missing or no longer running" >&2
    exit 1
  }
  expected_pid="$(<"$STATE_DIR/peer-process.pid")"
  for _ in $(seq 1 50); do
    rows="$(ss -H -lunp "sport = :$LISTEN_PORT" 2>/dev/null || true)"
    if listener_row="$(
      nvpn_require_single_udp_listener \
        "$rows" "$default_iface" "$LISTEN_PORT" "$expected_pid" 2>/dev/null
    )"; then
      printf 'default_interface=%s\n' "$default_iface"
      printf 'daemon_pid=%s\n' "$expected_pid"
      printf 'listener=%s\n' "$listener_row"
      echo "production_device_bind=true"
      return 0
    fi
    sleep 0.1
  done
  nvpn_require_single_udp_listener \
    "$rows" "$default_iface" "$LISTEN_PORT" "$expected_pid" >/dev/null || true
  ss -lunp 2>/dev/null || true
  echo "peer FIPS listener is not the sole daemon-owned socket on $default_iface" >&2
  exit 1
}

start_services() {
  [[ -n "$TARGET_TUNNEL_IP" ]] || {
    echo "NVPN_UNDERLAY_TARGET_TUNNEL_IP is required" >&2
    exit 2
  }
  wait_for_peer_tun
  local peer_tunnel_ip wg_server_ip
  peer_tunnel_ip="$("$BINARY" ip --config "$CONFIG")"
  wg_server_ip="${WG_SERVER_ADDRESS%/*}"

  remove_counter_chain
  iptables -t mangle -N "$CHAIN"
  for protocol in udp tcp; do
    for ip in 1.1.1.1 1.0.0.1; do
      iptables -t mangle -A "$CHAIN" -p "$protocol" -d "$ip" --dport 53 -j RETURN
    done
    iptables -t mangle -A "$CHAIN" \
      -p "$protocol" -d "$wg_server_ip" --dport 53 -j RETURN
  done
  for ip in 1.1.1.1 1.0.0.1; do
    iptables -t mangle -A "$CHAIN" -p tcp -d "$ip" --dport 443 -j RETURN
  done
  for ip in 9.9.9.9 149.112.112.112; do
    iptables -t mangle -A "$CHAIN" -p tcp -d "$ip" --dport 443 -j RETURN
  done
  for ip in 8.8.8.8 8.8.4.4; do
    iptables -t mangle -A "$CHAIN" -p tcp -d "$ip" --dport 443 -j RETURN
  done
  iptables -t mangle -A "$CHAIN" -j RETURN
  iptables -t mangle -I PREROUTING 1 -i "$TUN_IFACE" -j "$CHAIN"
  iptables -t mangle -I PREROUTING 1 -i "$WG_IFACE" -j "$CHAIN"

  : >"$STATE_DIR/dns.log"
  dnsmasq \
    --no-daemon \
    --bind-interfaces \
    --listen-address="$peer_tunnel_ip" \
    --listen-address="$wg_server_ip" \
    --no-hosts \
    --no-resolv \
    --server=1.1.1.1 \
    --address="/$FIXTURE_DNS_NAME/$peer_tunnel_ip" \
    --log-queries \
    --log-facility="$STATE_DIR/dns.log" \
    >"$STATE_DIR/dnsmasq.log" 2>&1 &
  echo "$!" >"$STATE_DIR/dnsmasq.pid"

  ping -D -n -i 0.1 -W 1 "$TARGET_TUNNEL_IP" \
    >"$STATE_DIR/peer-payload.log" 2>&1 &
  echo "$!" >"$STATE_DIR/ping.pid"

  tcpdump -n -tt -l -i any "udp port $LISTEN_PORT" \
    >"$STATE_DIR/fips-underlay.pcap.txt" 2>"$STATE_DIR/tcpdump.log" &
  echo "$!" >"$STATE_DIR/tcpdump.pid"
  tcpdump -n -tt -l -i any "udp port $WG_LISTEN_PORT" \
    >"$STATE_DIR/wireguard-underlay.pcap.txt" 2>"$STATE_DIR/wg-tcpdump.log" &
  echo "$!" >"$STATE_DIR/wg-tcpdump.pid"

  for _ in $(seq 1 100); do
    if pid_alive "$STATE_DIR/dnsmasq.pid" \
      && pid_alive "$STATE_DIR/ping.pid" \
      && pid_alive "$STATE_DIR/tcpdump.pid" \
      && pid_alive "$STATE_DIR/wg-tcpdump.pid"; then
      return 0
    fi
    sleep 0.1
  done
  echo "peer payload/DNS/capture services did not remain running" >&2
  return 1
}

counter_for_destinations() {
  local first="$1"
  local second="$2"
  iptables -t mangle -L "$CHAIN" -v -n -x 2>/dev/null \
    | awk -v first="$first" -v second="$second" '
        ($9 == first || $9 == second) && /tcp dpt:443/ { packets += $1 }
        END { print packets + 0 }
      '
}

counter_for_dns_destinations() {
  local first="$1"
  local second="${2:-$first}"
  iptables -t mangle -L "$CHAIN" -v -n -x 2>/dev/null \
    | awk -v first="$first" -v second="$second" '
        ($9 == first || $9 == second) && /dpt:53/ { packets += $1 }
        END { print packets + 0 }
      '
}

case "$ACTION" in
  initialize)
    require_root
    [[ -x "$BINARY" ]] || {
      echo "candidate peer nvpn binary is missing: $BINARY" >&2
      exit 2
    }
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"
    cleanup
    rm -rf "$STATE_DIR"
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"
    "$BINARY" init --config "$CONFIG" --force >/dev/null
    "$BINARY" set --config "$CONFIG" --network-id "$NETWORK_ID" >/dev/null
    npub="$(read_npub)"
    tunnel_ip="$("$BINARY" ip --config "$CONFIG")"
    [[ -n "$npub" && -n "$tunnel_ip" ]]
    printf 'npub=%s\n' "$npub"
    printf 'tunnel_ip=%s\n' "$tunnel_ip"
    ;;
  start)
    require_root
    [[ -n "$PUBLIC_ENDPOINT" && -n "$TARGET_NPUB" ]] || {
      echo "peer start requires public endpoint and target npub" >&2
      exit 2
    }
    cleanup
    "$BINARY" set \
      --config "$CONFIG" \
      --network-id "$NETWORK_ID" \
      --participant "$TARGET_NPUB" \
      --endpoint "$PUBLIC_ENDPOINT" \
      --listen-port "$LISTEN_PORT" \
      --fips-advertise-public-endpoint true \
      --fips-nostr-discovery-enabled false \
      --lan-discovery-enabled false \
      --fips-webrtc-enabled false \
      --fips-bootstrap-enabled false \
      --advertise-exit-node true \
      --autoconnect true \
      >/dev/null
    nohup env RUST_LOG=info "$BINARY" daemon \
      --config "$CONFIG" \
      --iface "$TUN_IFACE" \
      --mesh-refresh-interval-secs 2 \
      >"$STATE_DIR/daemon.stdout.log" \
      2>"$STATE_DIR/daemon.stderr.log" \
      </dev/null &
    echo "$!" >"$STATE_DIR/peer-process.pid"
    wait_for_peer_tun
    ;;
  services)
    require_root
    start_services
    ;;
  wait-ready)
    [[ -n "$EXPECTED_FIPS_REV" ]] || {
      echo "peer readiness requires the expected FIPS revision" >&2
      exit 2
    }
    for _ in $(seq 1 300); do
      if status_ready; then
        "$BINARY" status --config "$CONFIG" --json --discover-secs 0
        exit 0
      fi
      sleep 0.1
    done
    "$BINARY" status --config "$CONFIG" --json --discover-secs 0 || true
    tail -n 80 "$STATE_DIR/daemon.stderr.log" 2>/dev/null >&2 || true
    echo "peer FIPS mesh did not become ready" >&2
    exit 1
    ;;
  listener-audit)
    require_root
    listener_audit
    ;;
  counters)
    require_root
    printf 'profile_dns=%s\n' "$(counter_for_dns_destinations 1.1.1.1 1.0.0.1)"
    printf 'cloudflare=%s\n' "$(counter_for_destinations 1.1.1.1 1.0.0.1)"
    printf 'quad9=%s\n' "$(counter_for_destinations 9.9.9.9 149.112.112.112)"
    printf 'google=%s\n' "$(counter_for_destinations 8.8.8.8 8.8.4.4)"
    printf 'fixture_dns=%s\n' \
      "$(counter_for_dns_destinations "${WG_SERVER_ADDRESS%/*}")"
    ;;
  wireguard-setup)
    require_root
    wireguard_setup
    ;;
  wireguard-audit)
    require_root
    wireguard_audit
    ;;
  initial-source-audit)
    require_root
    initial_source_audit
    ;;
  cleanup)
    require_root
    cleanup
    rm -rf "$STATE_DIR"
    ;;
  namespace-setup)
    require_root
    namespace_setup
    ;;
  namespace-cleanup)
    require_root
    require_namespace_config
    namespace_cleanup
    ;;
  namespace-audit)
    require_root
    namespace_audit
    ;;
  *)
    echo "usage: $0 {namespace-setup|initialize|start|listener-audit|services|wait-ready|counters|wireguard-setup|wireguard-audit|initial-source-audit|cleanup|namespace-cleanup|namespace-audit}" >&2
    exit 2
    ;;
esac
