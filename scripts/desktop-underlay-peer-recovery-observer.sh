#!/usr/bin/env bash
# Observe peer-side packets after a physical underlay cut. Evidence must land
# inside the product deadline; the extra two seconds only lets tcpdump flush.
set -euo pipefail

STATE="${1:?state directory is required}"
CUT="${2:?cut timestamp is required}"
SOURCE_IP="${3:?expected source address is required}"
DEADLINE_MS="${4:?deadline milliseconds are required}"
LABEL="${5:?receipt label is required}"
FLUSH_GRACE_MS=2000

decimal_seconds_to_ns() {
  local value="$1" seconds fraction
  [[ "$value" =~ ^([0-9]+)\.([0-9]{1,9})$ ]] || {
    echo "invalid decimal timestamp: $value" >&2
    return 1
  }
  seconds="${BASH_REMATCH[1]}"
  fraction="${BASH_REMATCH[2]}000000000"
  fraction="${fraction:0:9}"
  printf '%s\n' "$((10#$seconds * 1000000000 + 10#$fraction))"
}

first_capture_stamp() {
  local path="$1" source_ip="$2" after_ns="$3" line stamp stamp_ns
  while IFS= read -r line; do
    [[ "$line" == *" IP $source_ip."* ]] || continue
    stamp="${line%% *}"
    stamp_ns="$(decimal_seconds_to_ns "$stamp")"
    ((stamp_ns >= after_ns)) || continue
    printf '%s\n' "$stamp"
    return 0
  done <"$path"
  return 1
}

first_payload_stamp() {
  local path="$1" after_ns="$2" line stamp stamp_ns
  while IFS= read -r line; do
    [[ "$line" == \[* && "$line" == *" bytes from "* ]] || continue
    stamp="${line%% *}"
    stamp="${stamp#[}"
    stamp="${stamp%]}"
    stamp_ns="$(decimal_seconds_to_ns "$stamp")"
    ((stamp_ns >= after_ns)) || continue
    printf '%s\n' "$stamp"
    return 0
  done <"$path"
  return 1
}

format_delta_seconds() {
  local nanoseconds="$1" milliseconds
  milliseconds="$(((nanoseconds + 500000) / 1000000))"
  printf '%d.%03d\n' "$((milliseconds / 1000))" "$((milliseconds % 1000))"
}

[[ "$DEADLINE_MS" =~ ^[1-9][0-9]*$ && "$LABEL" =~ ^[a-z0-9_-]+$ ]] || {
  echo "invalid peer observer deadline or label" >&2
  exit 2
}
for path in \
  "$STATE/fips-underlay.pcap.txt" \
  "$STATE/wireguard-underlay.pcap.txt" \
  "$STATE/peer-payload.log"
do
  [[ -r "$path" ]] || {
    echo "capture state is not readable: $path" >&2
    exit 2
  }
done

cut_ns="$(decimal_seconds_to_ns "$CUT")"
deadline_ns="$((DEADLINE_MS * 1000000))"
evidence_deadline_ns="$((cut_ns + deadline_ns))"
flush_deadline_ns="$((evidence_deadline_ns + FLUSH_GRACE_MS * 1000000))"

while :; do
  fips_at="$(
    first_capture_stamp \
      "$STATE/fips-underlay.pcap.txt" "$SOURCE_IP" "$cut_ns" || true
  )"
  wireguard_at="$(
    first_capture_stamp \
      "$STATE/wireguard-underlay.pcap.txt" "$SOURCE_IP" "$cut_ns" || true
  )"
  reverse_at=""
  if [[ -n "$fips_at" ]]; then
    fips_ns="$(decimal_seconds_to_ns "$fips_at")"
    reverse_at="$(
      first_payload_stamp "$STATE/peer-payload.log" "$fips_ns" || true
    )"
  fi
  if [[ -n "$fips_at" && -n "$wireguard_at" && -n "$reverse_at" ]]; then
    fips_ns="$(decimal_seconds_to_ns "$fips_at")"
    wireguard_ns="$(decimal_seconds_to_ns "$wireguard_at")"
    reverse_ns="$(decimal_seconds_to_ns "$reverse_at")"
    if ((fips_ns <= evidence_deadline_ns \
      && wireguard_ns <= evidence_deadline_ns \
      && reverse_ns <= evidence_deadline_ns \
      && reverse_ns - fips_ns <= deadline_ns))
    then
      printf '%s_fips_expected_source_after_cut_seconds=%s\n' \
        "$LABEL" "$(format_delta_seconds "$((fips_ns - cut_ns))")"
      printf '%s_wireguard_expected_source_after_cut_seconds=%s\n' \
        "$LABEL" "$(format_delta_seconds "$((wireguard_ns - cut_ns))")"
      printf '%s_reverse_payload_after_expected_source_seconds=%s\n' \
        "$LABEL" "$(format_delta_seconds "$((reverse_ns - fips_ns))")"
      exit 0
    fi
    break
  fi
  now_ns="$(date +%s%N)"
  [[ "$now_ns" =~ ^[0-9]+$ ]] || {
    echo "host clock did not return integer nanoseconds" >&2
    exit 2
  }
  ((now_ns < flush_deadline_ns)) || break
  sleep 0.05
done

echo "$LABEL did not produce new-source FIPS/WireGuard traffic and reverse payload within ${DEADLINE_MS}ms" >&2
exit 1
