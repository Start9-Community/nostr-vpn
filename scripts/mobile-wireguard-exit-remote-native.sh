#!/usr/bin/env bash
set -euo pipefail

action="${1:-}"
: "${NVPN_MOBILE_WG_REMOTE_STATE_DIR:?remote fixture state dir is required}"
: "${NVPN_MOBILE_WG_REMOTE_INTERFACE:?remote fixture interface is required}"
: "${NVPN_MOBILE_WG_REMOTE_NFT_TABLE:?remote fixture nft table is required}"
state_dir="$NVPN_MOBILE_WG_REMOTE_STATE_DIR"
interface="$NVPN_MOBILE_WG_REMOTE_INTERFACE"
nft_table="$NVPN_MOBILE_WG_REMOTE_NFT_TABLE"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

validate_names() {
  [[ "$state_dir" == /tmp/nvpn-mobile-wg-exit.* ]] \
    && [[ "$interface" =~ ^[a-zA-Z][a-zA-Z0-9]{1,14}$ ]] \
    && [[ "$nft_table" =~ ^[a-zA-Z][a-zA-Z0-9]{1,20}$ ]]
}
validate_names || {
  echo "remote native fixture received an unsafe resource name" >&2
  exit 2
}

system_firewall_rules="$state_dir/system-firewall-rules.tsv"

add_system_firewall_rule() {
  local family="$1" table="$2" chain="$3" marker="$4"
  shift 4
  nft list chain "$family" "$table" "$chain" >/dev/null 2>&1 || return 0
  nft insert rule "$family" "$table" "$chain" "$@" comment "$marker"
  local handle
  handle="$(
    nft -a list chain "$family" "$table" "$chain" \
      | awk -v marker="comment \\\"$marker\\\"" '
          index($0, marker) {
            for (field = 1; field <= NF; field++) {
              if ($field == "handle") {
                print $(field + 1)
                exit
              }
            }
          }
        '
  )"
  [[ "$handle" =~ ^[1-9][0-9]*$ ]] || {
    echo "remote fixture could not record its temporary firewall rule" >&2
    return 1
  }
  printf '%s\t%s\t%s\t%s\n' \
    "$family" "$table" "$chain" "$handle" >>"$system_firewall_rules"
}

remove_system_firewall_rules() {
  [[ -f "$system_firewall_rules" ]] || return 0
  local family table chain handle
  while IFS=$'\t' read -r family table chain handle; do
    [[ "$family" =~ ^[a-z]+$ \
      && "$table" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ \
      && "$chain" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ \
      && "$handle" =~ ^[1-9][0-9]*$ ]] \
      || continue
    nft delete rule "$family" "$table" "$chain" handle "$handle" \
      >/dev/null 2>&1 || true
  done <"$system_firewall_rules"
  rm -f "$system_firewall_rules"
}

pid_matches_fixture() {
  local pid="$1" needle="$2"
  [[ "$pid" =~ ^[1-9][0-9]*$ && -r "/proc/$pid/cmdline" ]] \
    && tr '\0' ' ' <"/proc/$pid/cmdline" | grep -Fq "$needle"
}

stop_fixture() {
  local name pid
  for name in dnsmasq udp-echo http-probe; do
    if [[ -s "$state_dir/$name.pid" ]]; then
      pid="$(<"$state_dir/$name.pid")"
      if pid_matches_fixture "$pid" "$state_dir"; then
        kill "$pid" 2>/dev/null || true
        for _ in $(seq 1 20); do
          kill -0 "$pid" 2>/dev/null || break
          sleep 0.1
        done
        if kill -0 "$pid" 2>/dev/null && pid_matches_fixture "$pid" "$state_dir"; then
          kill -KILL "$pid" 2>/dev/null || true
        fi
      fi
    fi
  done
  rm -f "$state_dir/ready"
  remove_system_firewall_rules
  nft delete table inet "$nft_table" >/dev/null 2>&1 || true
  ip link delete "$interface" >/dev/null 2>&1 || true
  if [[ -s "$state_dir/ip-forward.before" ]]; then
    local previous
    previous="$(<"$state_dir/ip-forward.before")"
    if [[ "$previous" == "0" || "$previous" == "1" ]]; then
      sysctl -q -w "net.ipv4.ip_forward=$previous" >/dev/null
    fi
  fi
}

fixture_ready() {
  local dns_pid echo_pid server_ip
  server_ip="${NVPN_MOBILE_WG_TUNNEL_CIDR%/*}"
  [[ -s "$state_dir/dnsmasq.pid" \
    && -s "$state_dir/udp-echo.pid" \
    && -s "$state_dir/http-probe.pid" ]] || return 1
  dns_pid="$(<"$state_dir/dnsmasq.pid")"
  echo_pid="$(<"$state_dir/udp-echo.pid")"
  local http_pid
  http_pid="$(<"$state_dir/http-probe.pid")"
  pid_matches_fixture "$dns_pid" "$state_dir" \
    && pid_matches_fixture "$echo_pid" "$state_dir" \
    && pid_matches_fixture "$http_pid" "$state_dir" \
    && ip link show "$interface" >/dev/null 2>&1 \
    && wg show "$interface" >/dev/null 2>&1 \
    && nft list table inet "$nft_table" >/dev/null 2>&1 \
    && ss -H -lun | grep -Fq "$server_ip:53" \
    && ss -H -lun | grep -Fq "$server_ip:9" \
    && ss -H -ltn | grep -Fq "$server_ip:$NVPN_MOBILE_WG_HTTP_PROBE_PORT"
}

counter_packets() {
  local counter="$1"
  nft list counter inet "$nft_table" "$counter" \
    | awk '/packets/ {
        for (field = 1; field <= NF; field++) {
          if ($field == "packets") {
            value = $(field + 1)
            gsub(/[^0-9]/, "", value)
            print value + 0
            exit
          }
        }
      }'
}

case "$action" in
  start)
    : "${NVPN_MOBILE_WG_SERVER_PRIVATE_KEY_FILE:?server key is required}"
    : "${NVPN_MOBILE_WG_CLIENT_PUBLIC_KEY_FILE:?client public key is required}"
    : "${NVPN_MOBILE_WG_TUNNEL_CIDR:?tunnel CIDR is required}"
    : "${NVPN_MOBILE_WG_CLIENT_IP:?client address is required}"
    : "${NVPN_MOBILE_WG_LISTEN_PORT:?listen port is required}"
    : "${NVPN_MOBILE_WG_DNS_NAME:?DNS fixture name is required}"
    : "${NVPN_MOBILE_WG_HTTP_PROBE_PORT:?HTTP fixture port is required}"
    : "${NVPN_MOBILE_WG_HTTP_TOKEN:?HTTP fixture token is required}"
    [[ "$NVPN_MOBILE_WG_LISTEN_PORT" =~ ^[1-9][0-9]{0,4}$ ]] \
      && (( NVPN_MOBILE_WG_LISTEN_PORT <= 65535 )) \
      || {
        echo "remote fixture listen port is invalid" >&2
        exit 2
      }
    for command in ip wg nft dnsmasq python3 ss sysctl; do
      command -v "$command" >/dev/null 2>&1 \
        || { echo "remote fixture requires $command" >&2; exit 2; }
    done
    if ip link show "$interface" >/dev/null 2>&1 \
      || nft list table inet "$nft_table" >/dev/null 2>&1
    then
      echo "remote fixture interface or nft table already exists" >&2
      exit 1
    fi
    mkdir -p "$state_dir"
    chmod 700 "$state_dir"
    : >"$system_firewall_rules"
    cat /proc/sys/net/ipv4/ip_forward >"$state_dir/ip-forward.before"
    trap 'status=$?; stop_fixture; exit "$status"' ERR INT TERM
    local_server_ip="${NVPN_MOBILE_WG_TUNNEL_CIDR%/*}"
    tunnel_subnet="$(
      python3 - "$NVPN_MOBILE_WG_TUNNEL_CIDR" <<'PY'
import ipaddress
import sys
print(ipaddress.ip_interface(sys.argv[1]).network)
PY
    )"
    egress_interface="$(
      ip -4 route get 1.1.1.1 \
        | awk '{ for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit } }'
    )"
    [[ -n "$egress_interface" ]] \
      || { echo "remote fixture cannot resolve its public egress interface" >&2; exit 1; }

    ip link add "$interface" type wireguard
    ip address add "$NVPN_MOBILE_WG_TUNNEL_CIDR" dev "$interface"
    wg set "$interface" \
      listen-port "$NVPN_MOBILE_WG_LISTEN_PORT" \
      private-key "$NVPN_MOBILE_WG_SERVER_PRIVATE_KEY_FILE" \
      peer "$(tr -d '\r\n' <"$NVPN_MOBILE_WG_CLIENT_PUBLIC_KEY_FILE")" \
      allowed-ips "$NVPN_MOBILE_WG_CLIENT_IP/32"
    ip link set "$interface" up

    nft add table inet "$nft_table"
    nft add counter inet "$nft_table" forward_in
    nft add counter inet "$nft_table" forward_out
    nft add counter inet "$nft_table" doh_cf
    nft add counter inet "$nft_table" doh_q9
    nft add counter inet "$nft_table" http_probe
    nft add chain inet "$nft_table" input \
      '{ type filter hook input priority -10; policy accept; }'
    nft add chain inet "$nft_table" forward \
      '{ type filter hook forward priority -10; policy accept; }'
    nft add chain inet "$nft_table" postrouting \
      '{ type nat hook postrouting priority srcnat; policy accept; }'
    nft add rule inet "$nft_table" input \
      udp dport "$NVPN_MOBILE_WG_LISTEN_PORT" accept
    nft add rule inet "$nft_table" input \
      iifname "$interface" udp dport '{ 9, 53 }' accept
    nft add rule inet "$nft_table" input \
      iifname "$interface" tcp dport 53 accept
    nft add rule inet "$nft_table" input \
      iifname "$interface" tcp dport "$NVPN_MOBILE_WG_HTTP_PROBE_PORT" \
      counter name http_probe accept
    nft add rule inet "$nft_table" forward \
      iifname "$interface" ip daddr '{ 1.1.1.1, 1.0.0.1 }' \
      tcp dport 443 counter name doh_cf accept
    nft add rule inet "$nft_table" forward \
      iifname "$interface" ip daddr '{ 9.9.9.9, 149.112.112.112 }' \
      tcp dport 443 counter name doh_q9 accept
    nft add rule inet "$nft_table" forward \
      iifname "$interface" counter name forward_in accept
    nft add rule inet "$nft_table" forward \
      oifname "$interface" ct state established,related \
      counter name forward_out accept
    nft add rule inet "$nft_table" postrouting \
      ip saddr "$tunnel_subnet" oifname "$egress_interface" masquerade
    # A separate accepting base chain cannot override a later host chain with
    # policy drop. Insert narrowly scoped, handle-tracked rules into the
    # standard system chains when present, then remove those exact handles.
    firewall_marker="nvpn-mobile-$interface"
    add_system_firewall_rule \
      inet filter input "$firewall_marker-input" \
      udp dport "$NVPN_MOBILE_WG_LISTEN_PORT" accept
    add_system_firewall_rule \
      inet filter input "$firewall_marker-services" \
      iifname "$interface" accept
    add_system_firewall_rule \
      inet filter forward "$firewall_marker-forward-in" \
      iifname "$interface" accept
    add_system_firewall_rule \
      inet filter forward "$firewall_marker-forward-out" \
      oifname "$interface" ct state established,related accept
    sysctl -q -w net.ipv4.ip_forward=1 >/dev/null

    dnsmasq \
      --interface="$interface" \
      --bind-interfaces \
      --listen-address="$local_server_ip" \
      --no-hosts \
      --no-resolv \
      --server=1.1.1.1 \
      --server=8.8.8.8 \
      --address="/$NVPN_MOBILE_WG_DNS_NAME/$local_server_ip" \
      --log-queries \
      --log-facility="$state_dir/dns.log" \
      --pid-file="$state_dir/dnsmasq.pid"
    python3 "$script_dir/mobile-wireguard-udp-echo.py" \
      "$local_server_ip" 9 "$state_dir/udp-echo.pid" \
      >"$state_dir/udp-echo.log" 2>&1 &
    python3 "$script_dir/mobile-wireguard-http-probe.py" \
      "$local_server_ip" "$NVPN_MOBILE_WG_HTTP_PROBE_PORT" \
      "$state_dir/http-probe.pid" "$NVPN_MOBILE_WG_HTTP_TOKEN" \
      >"$state_dir/http-probe.log" 2>&1 &
    for _ in $(seq 1 50); do
      fixture_ready && {
        trap - ERR INT TERM
        touch "$state_dir/ready"
        exit 0
      }
      sleep 0.1
    done
    echo "remote native fixture did not become ready" >&2
    stop_fixture
    trap - ERR INT TERM
    exit 1
    ;;
  stop)
    stop_fixture
    ;;
  ready)
    fixture_ready
    ;;
  wg-bytes)
    wg show "$interface" transfer \
      | awk '{ rx += $2; tx += $3 } END { printf "%d\t%d\n", rx, tx }'
    ;;
  forward-packets)
    counter_packets forward_in
    ;;
  doh-count)
    case "${2:-}" in
      cloudflare) counter_packets doh_cf ;;
      quad9) counter_packets doh_q9 ;;
      *) echo "unknown remote DoH counter" >&2; exit 2 ;;
    esac
    ;;
  dns-count)
    grep -Fci "${2:?DNS name is required}" "$state_dir/dns.log" 2>/dev/null || true
    ;;
  *)
    echo "usage: mobile-wireguard-exit-remote-native.sh start|stop|ready|wg-bytes|forward-packets|doh-count|dns-count" >&2
    exit 2
    ;;
esac
