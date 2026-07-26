#!/usr/bin/env bash

MOBILE_CONTINUITY_PID=""

mobile_underlay_now_ms() {
  python3 - <<'PY'
import time
print(time.time_ns() // 1_000_000)
PY
}

mobile_underlay_require_positive_integer() {
  local name="$1" value="$2"
  if ! [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
    echo "$name must be a positive integer" >&2
    return 1
  fi
}

mobile_continuity_start() {
  local container="$1" client_ip="$2" output="$3"
  local remote_host="${NVPN_MOBILE_UNDERLAY_CONTINUITY_SSH_HOST:-}"
  local remote_mode="${NVPN_MOBILE_UNDERLAY_CONTINUITY_REMOTE_MODE:-}"
  local remote_interface="${NVPN_MOBILE_UNDERLAY_CONTINUITY_REMOTE_INTERFACE:-}"
  local -a command=()
  if [[ -n "$MOBILE_CONTINUITY_PID" ]]; then
    echo "mobile continuity probe is already running" >&2
    return 1
  fi
  if ! [[ "$client_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "mobile continuity probe requires an IPv4 WireGuard client address" >&2
    return 1
  fi
  if [[ -n "$remote_host" ]]; then
    if [[ "$remote_host" == -* || "$remote_host" =~ [[:space:]] ]]; then
      echo "mobile continuity SSH host is invalid" >&2
      return 1
    fi
    case "$remote_mode" in
      native)
        if ! [[ "$remote_interface" =~ ^[a-zA-Z][a-zA-Z0-9]{1,14}$ ]]; then
          echo "mobile continuity remote WireGuard interface is invalid" >&2
          return 1
        fi
        if ! ssh -o BatchMode=yes -o ConnectTimeout=10 "$remote_host" \
          sudo -n wg show "$remote_interface" >/dev/null
        then
          echo "mobile continuity remote native fixture is not running" >&2
          return 1
        fi
        command=(
          ssh -o BatchMode=yes -o ConnectTimeout=10 "$remote_host"
          sudo -n timeout 900 stdbuf -oL
          ping -I "$remote_interface" -n -i 0.2 -W 1 "$client_ip"
        )
        ;;
      docker)
        if ! [[ "$container" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
          echo "mobile continuity remote Docker container is invalid" >&2
          return 1
        fi
        local -a remote_docker=(docker)
        if [[ "${NVPN_MOBILE_UNDERLAY_CONTINUITY_REMOTE_DOCKER_SUDO:-0}" == "1" ]]; then
          remote_docker=(sudo -n docker)
        fi
        if ! ssh -o BatchMode=yes -o ConnectTimeout=10 "$remote_host" \
          "${remote_docker[@]}" inspect -f '{{.State.Running}}' "$container" \
          2>/dev/null | grep -Fxq true
        then
          echo "mobile continuity remote Docker fixture is not running" >&2
          return 1
        fi
        command=(
          ssh -o BatchMode=yes -o ConnectTimeout=10 "$remote_host"
          "${remote_docker[@]}" exec "$container"
          stdbuf -oL ping -n -i 0.2 -W 1 "$client_ip"
        )
        ;;
      *)
        echo "mobile continuity remote mode must be native or docker" >&2
        return 1
        ;;
    esac
  else
    if ! docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null \
        | grep -Fxq true
    then
      echo "mobile continuity fixture container is not running" >&2
      return 1
    fi
    command=(
      docker exec "$container"
      stdbuf -oL ping -n -i 0.2 -W 1 "$client_ip"
    )
  fi
  mkdir -p "$(dirname "$output")"
  : >"$output"
  python3 "$ROOT/scripts/mobile-underlay-local-timestamp.py" \
    "$output" -- "${command[@]}" &
  MOBILE_CONTINUITY_PID="$!"
  sleep 0.5
  if ! kill -0 "$MOBILE_CONTINUITY_PID" 2>/dev/null; then
    wait "$MOBILE_CONTINUITY_PID" 2>/dev/null || true
    MOBILE_CONTINUITY_PID=""
    echo "mobile continuity probe stopped before the first underlay switch" >&2
    return 1
  fi
}

mobile_continuity_stop() {
  if [[ -n "$MOBILE_CONTINUITY_PID" ]]; then
    kill "$MOBILE_CONTINUITY_PID" 2>/dev/null || true
    wait "$MOBILE_CONTINUITY_PID" 2>/dev/null || true
    MOBILE_CONTINUITY_PID=""
  fi
}

mobile_continuity_reply_count_after() {
  local output="$1" timestamp_ms="$2"
  python3 - "$output" "$timestamp_ms" <<'PY'
import re
import sys

path, threshold_raw = sys.argv[1:]
threshold = int(threshold_raw)
pattern = re.compile(
    r"^\[(\d+)(?:\.(\d+))?\].*bytes from .*icmp_seq[= ]\d+"
)
count = 0
try:
    lines = open(path, encoding="utf-8", errors="replace")
except OSError:
    print(0)
    raise SystemExit(0)
with lines:
    for line in lines:
        match = pattern.search(line)
        if not match:
            continue
        fraction = (match.group(2) or "")[:3].ljust(3, "0")
        timestamp = int(match.group(1)) * 1_000 + int(fraction or "0")
        if timestamp >= threshold:
            count += 1
print(count)
PY
}

mobile_continuity_wait_for_reply_count_after() {
  local output="$1" timestamp_ms="$2" required="$3" timeout_ms="$4"
  local deadline_ms count now_ms
  deadline_ms=$(($(mobile_underlay_now_ms) + timeout_ms))
  while true; do
    count="$(mobile_continuity_reply_count_after "$output" "$timestamp_ms")"
    if [[ "$count" =~ ^[0-9]+$ ]] && (( count >= required )); then
      return 0
    fi
    now_ms="$(mobile_underlay_now_ms)"
    if (( now_ms > deadline_ms )); then
      echo "continuous WireGuard payload produced only $count/$required fresh replies" >&2
      return 1
    fi
    sleep 0.05
  done
}

mobile_continuity_validate() {
  local root="$1" output="$2" markers="$3" summary="$4" platform="$5"
  local max_recovery_ms="$6"
  python3 "$root/scripts/validate-mobile-underlay-continuity.py" \
    "$output" "$markers" "$summary" "$platform" "$max_recovery_ms"
}
