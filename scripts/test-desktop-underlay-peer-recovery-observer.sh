#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OBSERVER="$ROOT/scripts/desktop-underlay-peer-recovery-observer.sh"
STATE="$(mktemp -d "${TMPDIR:-/tmp}/nvpn-underlay-observer.XXXXXX")"
trap 'chmod 700 "$STATE" 2>/dev/null || true; rm -rf "$STATE"' EXIT

fail() {
  echo "desktop underlay peer observer harness failed: $*" >&2
  exit 1
}

run_bounded() {
  perl -e 'alarm shift; exec @ARGV; die "exec failed: $!"' \
    2 "$OBSERVER" "$@"
}

write_fixture() {
  cat >"$STATE/fips-underlay.pcap.txt" <<'EOF'
1785436928.800000 nvwn0 In IP 198.51.100.10.47000 > 192.0.2.2.46000: UDP, length 852
1785436928.900000 nvwn0 In IP 192.0.2.10.47000 > 192.0.2.2.46000: UDP, length 852
1785436929.998726 nvwn0 In IP 198.51.100.10.47000 > 192.0.2.2.46000: UDP, length 852
EOF
  cat >"$STATE/wireguard-underlay.pcap.txt" <<'EOF'
1785436928.850000 nvwn0 In IP 198.51.100.10.51000 > 192.0.2.2.52000: UDP, length 96
1785436928.950000 nvwn0 In IP 192.0.2.10.51000 > 192.0.2.2.52000: UDP, length 96
1785436931.622909 nvwn0 In IP 198.51.100.10.51000 > 192.0.2.2.52000: UDP, length 96
EOF
  cat >"$STATE/peer-payload.log" <<'EOF'
[1785436929.100000] 64 bytes from 10.44.0.2: icmp_seq=1 ttl=128 time=0.7 ms
[1785436930.396074] 64 bytes from 10.44.0.2: icmp_seq=2 ttl=128 time=0.8 ms
EOF
}

write_fixture
output="$(
  run_bounded \
    "$STATE" 1785436929.552248461 198.51.100.10 4000 secondary
)"
for expected in \
  secondary_fips_expected_source_after_cut_seconds=0.446 \
  secondary_wireguard_expected_source_after_cut_seconds=2.071 \
  secondary_reverse_payload_after_expected_source_seconds=0.397
do
  grep -Fqx "$expected" <<<"$output" || fail "missing receipt: $expected"
done

sed -i.bak \
  's/1785436929.998726/1785436933.552248462/' \
  "$STATE/fips-underlay.pcap.txt"
rm -f "$STATE/fips-underlay.pcap.txt.bak"
sed -i.bak \
  's/1785436930.396074/1785436933.652248462/' \
  "$STATE/peer-payload.log"
rm -f "$STATE/peer-payload.log.bak"
if run_bounded \
  "$STATE" 1785436929.552248461 198.51.100.10 4000 late \
  >"$STATE/late.out" 2>"$STATE/late.err"
then
  fail "accepted evidence one nanosecond past the four-second bound"
fi
grep -Fq 'within 4000ms' "$STATE/late.err" \
  || fail "late failure omitted the exact bound"

: >"$STATE/wireguard-underlay.pcap.txt"
set +e
run_bounded \
  "$STATE" 1785436929.552248461 198.51.100.10 4000 missing \
  >"$STATE/missing.out" 2>"$STATE/missing.err"
missing_status="$?"
set -e
[[ "$missing_status" -ne 0 && "$missing_status" -ne 142 ]] \
  || fail "historical missing evidence exceeded its short flush grace"

chmod 000 "$STATE"
if "$OBSERVER" \
  "$STATE" 1785436929.552248461 198.51.100.10 4000 unreadable \
  >"$STATE.out" 2>"$STATE.err"
then
  fail "accepted an unreadable root-owned capture directory"
fi
chmod 700 "$STATE"
grep -Fq 'capture state is not readable' "$STATE.err" \
  || fail "unreadable failure is not actionable"
rm -f "$STATE.out" "$STATE.err"

echo "DESKTOP_UNDERLAY_PEER_RECOVERY_OBSERVER_HARNESS_OK"
