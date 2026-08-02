#!/usr/bin/env bash
set -euo pipefail

: "${NVPN_MOBILE_WG_SERVER_PRIVATE_KEY_FILE:=/fixture/server.key}"
: "${NVPN_MOBILE_WG_CLIENT_PUBLIC_KEY_FILE:=/fixture/client.pub}"
: "${NVPN_MOBILE_WG_TUNNEL_CIDR:=10.99.77.1/24}"
: "${NVPN_MOBILE_WG_CLIENT_IP:=10.99.77.2}"
: "${NVPN_MOBILE_WG_THROUGH_DNS_IP:=10.99.77.53}"
: "${NVPN_MOBILE_WG_LISTEN_PORT:=51820}"
: "${NVPN_MOBILE_WG_DNS_NAME:=wireguard-exit.nvpn-e2e.test}"
: "${NVPN_MOBILE_WG_HTTP_PROBE_PORT:=8080}"
: "${NVPN_MOBILE_WG_HTTP_TOKEN:=nvpn-mobile-wireguard-exit-e2e}"

for key_file in "$NVPN_MOBILE_WG_SERVER_PRIVATE_KEY_FILE" "$NVPN_MOBILE_WG_CLIENT_PUBLIC_KEY_FILE"; do
  if [[ ! -s "$key_file" ]]; then
    echo "mobile WireGuard fixture key is missing: $key_file" >&2
    exit 2
  fi
done

server_ip="${NVPN_MOBILE_WG_TUNNEL_CIDR%/*}"
through_dns_ip="$NVPN_MOBILE_WG_THROUGH_DNS_IP"
client_public_key="$(tr -d '\r\n' <"$NVPN_MOBILE_WG_CLIENT_PUBLIC_KEY_FILE")"

ip link add wg0 type wireguard
ip address add "$NVPN_MOBILE_WG_TUNNEL_CIDR" dev wg0
ip address add "$through_dns_ip/32" dev wg0
wg set wg0 \
  listen-port "$NVPN_MOBILE_WG_LISTEN_PORT" \
  private-key "$NVPN_MOBILE_WG_SERVER_PRIVATE_KEY_FILE" \
  peer "$client_public_key" \
  allowed-ips "$NVPN_MOBILE_WG_CLIENT_IP/32"
ip link set wg0 up

iptables -N nvpn-mobile-wg-forward 2>/dev/null || iptables -F nvpn-mobile-wg-forward
iptables -N nvpn-wg-dns-profile 2>/dev/null || iptables -F nvpn-wg-dns-profile
iptables -N nvpn-wg-dns-through 2>/dev/null || iptables -F nvpn-wg-dns-through
iptables -N nvpn-wg-dns-forward 2>/dev/null || iptables -F nvpn-wg-dns-forward
iptables -A nvpn-wg-dns-profile -j ACCEPT
iptables -A nvpn-wg-dns-through -j ACCEPT
iptables -A nvpn-wg-dns-forward -j ACCEPT
iptables -A nvpn-mobile-wg-forward \
  -i wg0 -p udp --dport 53 \
  -j nvpn-wg-dns-forward
iptables -A nvpn-mobile-wg-forward \
  -i wg0 -p tcp --dport 53 \
  -j nvpn-wg-dns-forward
iptables -A nvpn-mobile-wg-forward -i wg0 -j ACCEPT
iptables -A nvpn-mobile-wg-forward -o wg0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -I FORWARD 1 -j nvpn-mobile-wg-forward
iptables -I INPUT 1 \
  -i wg0 -d "$server_ip" -p udp --dport 53 \
  -j nvpn-wg-dns-profile
iptables -I INPUT 1 \
  -i wg0 -d "$server_ip" -p tcp --dport 53 \
  -j nvpn-wg-dns-profile
iptables -I INPUT 1 \
  -i wg0 -d "$through_dns_ip" -p udp --dport 53 \
  -j nvpn-wg-dns-through
iptables -I INPUT 1 \
  -i wg0 -d "$through_dns_ip" -p tcp --dport 53 \
  -j nvpn-wg-dns-through
iptables -t nat -A POSTROUTING -s "${NVPN_MOBILE_WG_TUNNEL_CIDR%.*}.0/24" -o eth0 -j MASQUERADE

resolver_tls_capture_filter='tcp dst port 443 and (dst host 1.1.1.1 or dst host 1.0.0.1 or dst host 9.9.9.9 or dst host 149.112.112.112 or dst host 8.8.8.8 or dst host 8.8.4.4)'
tcpdump -i wg0 -nn -U -s 0 -C 1 -W 1 -Z root \
  -w /fixture/resolver-clienthello.pcap "$resolver_tls_capture_filter" \
  >/fixture/tcpdump.log 2>&1 &
echo "$!" >/fixture/tls-capture.pid

dnsmasq \
  --keep-in-foreground \
  --bind-interfaces \
  --listen-address="$server_ip" \
  --listen-address="$through_dns_ip" \
  --no-hosts \
  --no-resolv \
  --server=1.1.1.1 \
  --server=8.8.8.8 \
  --address="/$NVPN_MOBILE_WG_DNS_NAME/$server_ip" \
  --log-queries \
  --log-facility=/fixture/dns.log \
  >/fixture/dnsmasq.log 2>&1 &

socat UDP4-RECVFROM:9,bind="$server_ip",fork EXEC:/bin/cat >/fixture/udp-echo.log 2>&1 &
python3 /usr/local/bin/mobile-wireguard-http-probe.py \
  "$server_ip" "$NVPN_MOBILE_WG_HTTP_PROBE_PORT" \
  /fixture/http-probe.pid "$NVPN_MOBILE_WG_HTTP_TOKEN" \
  >/fixture/http-probe.log 2>&1 &

cleanup() {
  kill "$(jobs -pr)" 2>/dev/null || true
  wait 2>/dev/null || true
}
trap cleanup EXIT INT TERM

for _ in $(seq 1 50); do
  if wg show wg0 >/dev/null 2>&1 \
    && kill -0 "$(</fixture/tls-capture.pid)" 2>/dev/null \
    && ss -lun | grep -Fq "$server_ip:53" \
    && ss -lun | grep -Fq "$through_dns_ip:53" \
    && ss -lun | grep -Fq "$server_ip:9" \
    && ss -ltn | grep -Fq "$server_ip:$NVPN_MOBILE_WG_HTTP_PROBE_PORT"; then
    touch /fixture/ready
    wait -n
    exit $?
  fi
  sleep 0.1
done

echo "mobile WireGuard fixture services did not become ready" >&2
exit 1
