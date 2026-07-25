#!/usr/bin/env bash
set -euo pipefail

: "${NVPN_MOBILE_WG_SERVER_PRIVATE_KEY_FILE:=/fixture/server.key}"
: "${NVPN_MOBILE_WG_CLIENT_PUBLIC_KEY_FILE:=/fixture/client.pub}"
: "${NVPN_MOBILE_WG_TUNNEL_CIDR:=10.99.77.1/24}"
: "${NVPN_MOBILE_WG_CLIENT_IP:=10.99.77.2}"
: "${NVPN_MOBILE_WG_LISTEN_PORT:=51820}"
: "${NVPN_MOBILE_WG_DNS_NAME:=wireguard-exit.nvpn-e2e.test}"

for key_file in "$NVPN_MOBILE_WG_SERVER_PRIVATE_KEY_FILE" "$NVPN_MOBILE_WG_CLIENT_PUBLIC_KEY_FILE"; do
  if [[ ! -s "$key_file" ]]; then
    echo "mobile WireGuard fixture key is missing: $key_file" >&2
    exit 2
  fi
done

server_ip="${NVPN_MOBILE_WG_TUNNEL_CIDR%/*}"
client_public_key="$(tr -d '\r\n' <"$NVPN_MOBILE_WG_CLIENT_PUBLIC_KEY_FILE")"

ip link add wg0 type wireguard
ip address add "$NVPN_MOBILE_WG_TUNNEL_CIDR" dev wg0
wg set wg0 \
  listen-port "$NVPN_MOBILE_WG_LISTEN_PORT" \
  private-key "$NVPN_MOBILE_WG_SERVER_PRIVATE_KEY_FILE" \
  peer "$client_public_key" \
  allowed-ips "$NVPN_MOBILE_WG_CLIENT_IP/32"
ip link set wg0 up

iptables -N nvpn-mobile-wg-forward 2>/dev/null || iptables -F nvpn-mobile-wg-forward
iptables -N nvpn-wg-doh-cf 2>/dev/null || iptables -F nvpn-wg-doh-cf
iptables -N nvpn-wg-doh-q9 2>/dev/null || iptables -F nvpn-wg-doh-q9
iptables -A nvpn-wg-doh-cf -j ACCEPT
iptables -A nvpn-wg-doh-q9 -j ACCEPT
for resolver_ip in 1.1.1.1 1.0.0.1; do
  iptables -A nvpn-mobile-wg-forward \
    -i wg0 -p tcp -d "$resolver_ip" --dport 443 \
    -j nvpn-wg-doh-cf
done
for resolver_ip in 9.9.9.9 149.112.112.112; do
  iptables -A nvpn-mobile-wg-forward \
    -i wg0 -p tcp -d "$resolver_ip" --dport 443 \
    -j nvpn-wg-doh-q9
done
iptables -A nvpn-mobile-wg-forward -i wg0 -j ACCEPT
iptables -A nvpn-mobile-wg-forward -o wg0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -I FORWARD 1 -j nvpn-mobile-wg-forward
iptables -t nat -A POSTROUTING -s "${NVPN_MOBILE_WG_TUNNEL_CIDR%.*}.0/24" -o eth0 -j MASQUERADE

dnsmasq \
  --keep-in-foreground \
  --bind-interfaces \
  --listen-address="$server_ip" \
  --no-hosts \
  --no-resolv \
  --server=1.1.1.1 \
  --server=8.8.8.8 \
  --address="/$NVPN_MOBILE_WG_DNS_NAME/$server_ip" \
  --log-queries \
  --log-facility=/fixture/dns.log \
  >/fixture/dnsmasq.log 2>&1 &

socat UDP4-RECVFROM:9,bind="$server_ip",fork EXEC:/bin/cat >/fixture/udp-echo.log 2>&1 &

cleanup() {
  kill "$(jobs -pr)" 2>/dev/null || true
  wait 2>/dev/null || true
}
trap cleanup EXIT INT TERM

for _ in $(seq 1 50); do
  if wg show wg0 >/dev/null 2>&1 \
    && ss -lun | grep -Fq "$server_ip:53" \
    && ss -lun | grep -Fq "$server_ip:9"; then
    touch /fixture/ready
    wait -n
    exit $?
  fi
  sleep 0.1
done

echo "mobile WireGuard fixture services did not become ready" >&2
exit 1
