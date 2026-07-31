#!/usr/bin/env bash

# Validate pre-captured `ss -H -lunp` output without inspecting or mutating the
# host. The caller is responsible for filtering ss to the expected UDP port.
nvpn_require_single_udp_listener() {
  local rows="$1"
  local expected_device="$2"
  local expected_port="$3"
  local expected_pid="$4"
  local row_count row endpoint_suffix

  [[ -n "$expected_device" ]] || {
    echo "UDP listener audit requires an expected device" >&2
    return 2
  }
  [[ "$expected_port" =~ ^[1-9][0-9]*$ ]] || {
    echo "UDP listener audit requires a numeric nonzero port" >&2
    return 2
  }
  [[ "$expected_pid" =~ ^[1-9][0-9]*$ ]] || {
    echo "UDP listener audit requires a numeric nonzero daemon PID" >&2
    return 2
  }

  row_count="$(printf '%s\n' "$rows" | awk 'NF { count += 1 } END { print count + 0 }')"
  if [[ "$row_count" != "1" ]]; then
    printf 'expected exactly one UDP listener row, found %s\n' "$row_count" >&2
    return 1
  fi
  row="$(printf '%s\n' "$rows" | awk 'NF { print; exit }')"
  endpoint_suffix="%$expected_device:$expected_port"
  if ! printf '%s\n' "$row" | awk -v suffix="$endpoint_suffix" '
    {
      matches = 0
      for (field = 1; field <= NF; field += 1) {
        if (length($field) >= length(suffix) && substr($field, length($field) - length(suffix) + 1) == suffix) {
          matches += 1
        }
      }
    }
    END { exit !(matches == 1) }
  '; then
    printf 'UDP listener is not bound to exact device/port %s\n' \
      "$endpoint_suffix" >&2
    return 1
  fi
  if ! printf '%s\n' "$row" | awk -v expected_pid="$expected_pid" '
    {
      remaining = $0
      while (match(remaining, /pid=[0-9]+/)) {
        pid = substr(remaining, RSTART + 4, RLENGTH - 4)
        seen += 1
        if (pid != expected_pid) {
          foreign = 1
        }
        remaining = substr(remaining, RSTART + RLENGTH)
      }
    }
    END { exit !(seen > 0 && !foreign) }
  '; then
    printf 'UDP listener is not owned exclusively by expected daemon PID %s\n' \
      "$expected_pid" >&2
    return 1
  fi

  printf '%s\n' "$row"
}

# Validate the named dual-family FIPS listener set used by the macOS/Vader
# gate: exactly one IPv4 and one IPv6 wildcard on the same device/port, both
# owned exclusively by the expected daemon.
nvpn_require_dual_family_udp_listeners() {
  local rows="$1" expected_device="$2" expected_port="$3" expected_pid="$4"
  local row row_count endpoint_suffix

  row_count="$(printf '%s\n' "$rows" | awk 'NF { count += 1 } END { print count + 0 }')"
  [[ "$row_count" == "2" ]] || {
    printf 'expected exactly two dual-family UDP listener rows, found %s\n' \
      "$row_count" >&2
    return 1
  }
  endpoint_suffix="%$expected_device:$expected_port"

  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    nvpn_require_single_udp_listener \
      "$row" "$expected_device" "$expected_port" "$expected_pid" \
      >/dev/null || return
  done <<<"$rows"

  if ! printf '%s\n' "$rows" | awk -v suffix="$endpoint_suffix" '
    {
      for (field = 1; field <= NF; field += 1) {
        if (length($field) >= length(suffix) && substr($field, length($field) - length(suffix) + 1) == suffix) {
          address = substr($field, 1, length($field) - length(suffix))
          ipv4 += address == "0.0.0.0"
          ipv6 += address == "[::]"
        }
      }
    }
    END { exit !(ipv4 == 1 && ipv6 == 1) }
  '; then
    echo "dual-family UDP listeners must be one IPv4 and one IPv6 wildcard" >&2
    return 1
  fi

  printf '%s\n' "$rows" | awk 'NF'
}
