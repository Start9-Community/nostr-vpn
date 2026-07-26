#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REMOTE_NATIVE="$ROOT/scripts/mobile-wireguard-exit-remote-native.sh"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib-mobile-wireguard-fixture.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/nvpn-wg-cleanup-harness.XXXXXX")"
REMOTE_STATE="$(mktemp -d /tmp/nvpn-mobile-wg-exit.cleanup-harness.XXXXXX)"
CALLS="$TMP_ROOT/calls"
trap 'rm -rf "$TMP_ROOT" "$REMOTE_STATE" "${LEASE_A:-}" "${LEASE_B:-}" "${LEASE_C:-}" "${LEASE_HUP:-}"' EXIT

mobile_wg_remote_close_control() {
  printf 'close\n' >>"$CALLS"
}

mobile_wg_fixture_docker() {
  printf 'docker %s\n' "$*" >>"$CALLS"
  case "$1 $2" in
    "container inspect"|"image inspect") return 1 ;;
    *) return 0 ;;
  esac
}

mobile_wg_remote_exec() {
  printf 'remote %s\n' "$*" >>"$CALLS"
  return 0
}

MOBILE_WG_FIXTURE_STARTED=1
MOBILE_WG_FIXTURE_REMOTE_MODE=docker
MOBILE_WG_FIXTURE_REMOTE_IMAGE_BUILT=1
MOBILE_WG_FIXTURE_REMOTE_DIR=/tmp/nvpn-mobile-wg-exit.success
mobile_wg_fixture_cleanup fixture image
[[ "$MOBILE_WG_FIXTURE_STARTED" -eq 0 ]]
[[ "$MOBILE_WG_FIXTURE_REMOTE_IMAGE_BUILT" -eq 0 ]]
[[ -z "$MOBILE_WG_FIXTURE_REMOTE_DIR" ]]
for expected in \
  'docker rm -f fixture' \
  'docker container inspect fixture' \
  'docker image rm image' \
  'docker image inspect image' \
  'remote test ! -e /tmp/nvpn-mobile-wg-exit.success' \
  close
do
  grep -Fqx "$expected" "$CALLS"
done

: >"$CALLS"
mobile_wg_fixture_docker() {
  printf 'docker %s\n' "$*" >>"$CALLS"
  case "$1 $2" in
    "container inspect") return 0 ;;
    "image inspect") return 255 ;;
    *) return 0 ;;
  esac
}
mobile_wg_remote_exec() {
  printf 'remote %s\n' "$*" >>"$CALLS"
  [[ "$1" != "test" ]]
}
MOBILE_WG_FIXTURE_STARTED=1
MOBILE_WG_FIXTURE_REMOTE_MODE=docker
MOBILE_WG_FIXTURE_REMOTE_IMAGE_BUILT=1
MOBILE_WG_FIXTURE_REMOTE_DIR=/tmp/nvpn-mobile-wg-exit.failure
if mobile_wg_fixture_cleanup fixture image >/dev/null 2>&1; then
  echo "fixture cleanup accepted retained resources" >&2
  exit 1
fi
[[ "$MOBILE_WG_FIXTURE_STARTED" -eq 1 ]]
[[ "$MOBILE_WG_FIXTURE_REMOTE_IMAGE_BUILT" -eq 1 ]]
[[ "$MOBILE_WG_FIXTURE_REMOTE_DIR" == /tmp/nvpn-mobile-wg-exit.failure ]]
grep -Fqx 'docker image rm image' "$CALLS"
grep -Fqx \
  'remote test ! -e /tmp/nvpn-mobile-wg-exit.failure/fixture/server.key' \
  "$CALLS"
grep -Fqx close "$CALLS"

: >"$CALLS"
mobile_wg_remote_native() {
  printf 'native %s\n' "$*" >>"$CALLS"
  if [[ "$1" == "clean" ]]; then
    return 1
  fi
}
MOBILE_WG_FIXTURE_STARTED=1
MOBILE_WG_FIXTURE_REMOTE_MODE=native
MOBILE_WG_FIXTURE_REMOTE_IMAGE_BUILT=0
MOBILE_WG_FIXTURE_REMOTE_INTERFACE=nwg53000
MOBILE_WG_FIXTURE_REMOTE_NFT_TABLE=nvpnwg53000
MOBILE_WG_FIXTURE_REMOTE_DIR=/tmp/nvpn-mobile-wg-exit.native
if mobile_wg_fixture_cleanup fixture image >/dev/null 2>&1; then
  echo "native fixture cleanup accepted a retained firewall rule" >&2
  exit 1
fi
[[ "$MOBILE_WG_FIXTURE_STARTED" -eq 1 ]]
[[ "$MOBILE_WG_FIXTURE_REMOTE_DIR" == /tmp/nvpn-mobile-wg-exit.native ]]
grep -Fqx 'native stop' "$CALLS"
grep -Fqx 'native clean' "$CALLS"
grep -Fqx \
  'remote test ! -e /tmp/nvpn-mobile-wg-exit.native/fixture/server.key' \
  "$CALLS"
grep -Fqx close "$CALLS"

MOCK_BIN="$TMP_ROOT/bin"
mkdir -p "$MOCK_BIN"
cat >"$MOCK_BIN/nft" <<'SH'
#!/usr/bin/env bash
if [[ -n "${NFT_CALLS:-}" ]]; then
  printf '%s\n' "$*" >>"$NFT_CALLS"
fi
if [[ "$*" == "delete rule ip6 filter INPUT handle 42" ]]; then
  if [[ "${MOCK_NFT_MODE:-retained}" == "owned" \
    && -f "${NFT_RULE_STATE:-}" ]]
  then
    rm -f "$NFT_RULE_STATE"
    exit 0
  fi
  exit 1
fi
if [[ "$*" == "-a list chain ip6 filter INPUT" ]]; then
  if [[ "${MOCK_NFT_MODE:-retained}" == "handle-reused" ]]; then
    printf '%s\n' \
      'udp dport 22 accept comment "unrelated-host-rule" # handle 42'
  elif [[ "${MOCK_NFT_MODE:-retained}" != "owned" \
    || -f "${NFT_RULE_STATE:-}" ]]
  then
    printf '%s\n' \
      'udp dport 55999 accept comment "nvpn-mobile-nwg55999-input-v6" # handle 42'
  fi
  exit 0
fi
if [[ "$*" == "-a list ruleset" ]]; then
  if [[ "${MOCK_NFT_MODE:-retained}" == "handle-reused" ]]; then
    printf '%s\n' \
      'udp dport 22 accept comment "unrelated-host-rule" # handle 42'
  elif [[ "${MOCK_NFT_MODE:-retained}" != "owned" \
    || -f "${NFT_RULE_STATE:-}" ]]
  then
    printf '%s\n' \
      'udp dport 55999 accept comment "nvpn-mobile-nwg55999-input-v6" # handle 42'
  fi
  exit 0
fi
if [[ "$*" == "list table inet nvpnwg55999" ]]; then
  exit 1
fi
exit 1
SH
cat >"$MOCK_BIN/ip" <<'SH'
#!/usr/bin/env bash
if [[ -n "${MOCK_IP_STATE_DIR:-}" && "$1 $2" == "link show" ]]; then
  [[ -f "$MOCK_IP_STATE_DIR/$3" ]]
  exit
fi
if [[ -n "${MOCK_IP_STATE_DIR:-}" && "$1 $2" == "link delete" ]]; then
  rm -f "$MOCK_IP_STATE_DIR/$3"
  exit
fi
exit 1
SH
cat >"$MOCK_BIN/flock" <<'PY'
#!/usr/bin/env python3
import fcntl
import sys

operation, raw_fd = sys.argv[1:]
fd = int(raw_fd)
if operation == "-x":
    fcntl.flock(fd, fcntl.LOCK_EX)
elif operation == "-u":
    fcntl.flock(fd, fcntl.LOCK_UN)
else:
    raise SystemExit(2)
PY
chmod +x "$MOCK_BIN/nft" "$MOCK_BIN/ip" "$MOCK_BIN/flock"
REMOTE_RUNNER="$MOCK_BIN/remote-native-action"
cat >"$REMOTE_RUNNER" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
set --
# shellcheck disable=SC1090
source "$REMOTE_NATIVE_FOR_HARNESS"
ip_forward_lock="$IP_FORWARD_LOCK_FOR_HARNESS"
ip_forward_state="$IP_FORWARD_STATE_FOR_HARNESS"
ip_forward_leases="$ip_forward_state/leases"
ip_forward_original="$ip_forward_state/original"
ip_forward_sysctl="$IP_FORWARD_SYSCTL_FOR_HARNESS"
if [[ "${SLOW_IP_FORWARD_WRITE_FOR_HARNESS:-0}" == "1" ]]; then
  write_ip_forwarding() {
    local value="$1" current
    [[ "$value" == "0" || "$value" == "1" ]] || return 1
    sleep 0.05
    printf '%s\n' "$value" >"$ip_forward_sysctl" || return 1
    current="$(read_ip_forwarding)" || return 1
    [[ "$current" == "$value" ]]
  }
fi
case "$REMOTE_NATIVE_ACTION" in
  clean) assert_fixture_clean ;;
  stop) stop_fixture ;;
  lease-acquire) acquire_ip_forward_lease ;;
  lease-stop) release_ip_forward_lease_and_delete_interface ;;
  lease-clean) ip_forward_lease_clean ;;
  lease-hup-wait)
    install_fixture_cleanup_trap
    acquire_ip_forward_lease
    printf '%s\n' "$$" >"$HUP_READY_FOR_HARNESS"
    while :; do :; done
    ;;
  *) exit 2 ;;
esac
SH
chmod +x "$REMOTE_RUNNER"
IP_FORWARD_LOCK="$TMP_ROOT/ip-forward.lock"
IP_FORWARD_STATE="$TMP_ROOT/ip-forward-state"
IP_FORWARD_SYSCTL="$TMP_ROOT/ip-forward"
printf '0\n' >"$IP_FORWARD_SYSCTL"
printf 'ip6\tfilter\tINPUT\t42\tnvpn-mobile-nwg55999-input-v6\n' \
  >"$REMOTE_STATE/system-firewall-rules.tsv"
if env \
    PATH="$MOCK_BIN:/usr/bin:/bin" \
    REMOTE_NATIVE_FOR_HARNESS="$REMOTE_NATIVE" \
    REMOTE_NATIVE_ACTION=clean \
    IP_FORWARD_LOCK_FOR_HARNESS="$IP_FORWARD_LOCK" \
    IP_FORWARD_STATE_FOR_HARNESS="$IP_FORWARD_STATE" \
    IP_FORWARD_SYSCTL_FOR_HARNESS="$IP_FORWARD_SYSCTL" \
    NVPN_MOBILE_WG_REMOTE_STATE_DIR="$REMOTE_STATE" \
    NVPN_MOBILE_WG_REMOTE_INTERFACE=nwg55999 \
    NVPN_MOBILE_WG_REMOTE_NFT_TABLE=nvpnwg55999 \
    NVPN_MOBILE_WG_REMOTE_ENDPOINT_FAMILY=ipv6 \
    NVPN_MOBILE_WG_LISTEN_PORT=55999 \
    "$REMOTE_RUNNER" >/dev/null 2>&1
then
  echo "remote native clean accepted a retained host firewall rule" >&2
  exit 1
fi
[[ -f "$REMOTE_STATE/system-firewall-rules.tsv" ]] || {
  echo "remote native clean discarded the retained firewall receipt" >&2
  exit 1
}

rm -f "$REMOTE_STATE/system-firewall-rules.tsv"
if env \
    PATH="$MOCK_BIN:/usr/bin:/bin" \
    REMOTE_NATIVE_FOR_HARNESS="$REMOTE_NATIVE" \
    REMOTE_NATIVE_ACTION=clean \
    IP_FORWARD_LOCK_FOR_HARNESS="$IP_FORWARD_LOCK" \
    IP_FORWARD_STATE_FOR_HARNESS="$IP_FORWARD_STATE" \
    IP_FORWARD_SYSCTL_FOR_HARNESS="$IP_FORWARD_SYSCTL" \
    NVPN_MOBILE_WG_REMOTE_STATE_DIR="$REMOTE_STATE" \
    NVPN_MOBILE_WG_REMOTE_INTERFACE=nwg55999 \
    NVPN_MOBILE_WG_REMOTE_NFT_TABLE=nvpnwg55999 \
    NVPN_MOBILE_WG_REMOTE_ENDPOINT_FAMILY=ipv6 \
    NVPN_MOBILE_WG_LISTEN_PORT=55999 \
    "$REMOTE_RUNNER" >/dev/null 2>&1
then
  echo "remote native clean accepted an unrecorded host firewall rule" >&2
  exit 1
fi

: >"$CALLS"
printf 'ip6\tfilter\tINPUT\t42\tnvpn-mobile-nwg55999-input-v6\n' \
  >"$REMOTE_STATE/system-firewall-rules.tsv"
if ! env \
    PATH="$MOCK_BIN:/usr/bin:/bin" \
    MOCK_NFT_MODE=handle-reused \
    NFT_CALLS="$CALLS" \
    REMOTE_NATIVE_FOR_HARNESS="$REMOTE_NATIVE" \
    REMOTE_NATIVE_ACTION=stop \
    IP_FORWARD_LOCK_FOR_HARNESS="$IP_FORWARD_LOCK" \
    IP_FORWARD_STATE_FOR_HARNESS="$IP_FORWARD_STATE" \
    IP_FORWARD_SYSCTL_FOR_HARNESS="$IP_FORWARD_SYSCTL" \
    NVPN_MOBILE_WG_REMOTE_STATE_DIR="$REMOTE_STATE" \
    NVPN_MOBILE_WG_REMOTE_INTERFACE=nwg55999 \
    NVPN_MOBILE_WG_REMOTE_NFT_TABLE=nvpnwg55999 \
    NVPN_MOBILE_WG_REMOTE_ENDPOINT_FAMILY=ipv6 \
    NVPN_MOBILE_WG_LISTEN_PORT=55999 \
    "$REMOTE_RUNNER"
then
  echo "remote native cleanup rejected safe firewall handle reuse" >&2
  exit 1
fi
if grep -Fq 'delete rule ip6 filter INPUT handle 42' "$CALLS"; then
  echo "remote native cleanup deleted a reused unrelated firewall handle" >&2
  exit 1
fi
[[ ! -f "$REMOTE_STATE/system-firewall-rules.tsv" ]] || {
  echo "remote native cleanup retained a stale receipt after safe handle reuse" >&2
  exit 1
}

: >"$CALLS"
RULE_STATE="$TMP_ROOT/owned-rule"
touch "$RULE_STATE"
printf 'ip6\tfilter\tINPUT\t42\tnvpn-mobile-nwg55999-input-v6\n' \
  >"$REMOTE_STATE/system-firewall-rules.tsv"
env \
  PATH="$MOCK_BIN:/usr/bin:/bin" \
  MOCK_NFT_MODE=owned \
  NFT_CALLS="$CALLS" \
  NFT_RULE_STATE="$RULE_STATE" \
  REMOTE_NATIVE_FOR_HARNESS="$REMOTE_NATIVE" \
  REMOTE_NATIVE_ACTION=stop \
  IP_FORWARD_LOCK_FOR_HARNESS="$IP_FORWARD_LOCK" \
  IP_FORWARD_STATE_FOR_HARNESS="$IP_FORWARD_STATE" \
  IP_FORWARD_SYSCTL_FOR_HARNESS="$IP_FORWARD_SYSCTL" \
  NVPN_MOBILE_WG_REMOTE_STATE_DIR="$REMOTE_STATE" \
  NVPN_MOBILE_WG_REMOTE_INTERFACE=nwg55999 \
  NVPN_MOBILE_WG_REMOTE_NFT_TABLE=nvpnwg55999 \
  NVPN_MOBILE_WG_REMOTE_ENDPOINT_FAMILY=ipv6 \
  NVPN_MOBILE_WG_LISTEN_PORT=55999 \
  "$REMOTE_RUNNER"
grep -Fqx 'delete rule ip6 filter INPUT handle 42' "$CALLS"
[[ ! -e "$RULE_STATE" \
  && ! -e "$REMOTE_STATE/system-firewall-rules.tsv" ]] || {
  echo "remote native cleanup did not remove its owned firewall rule" >&2
  exit 1
}

printf '999999\n' >"$REMOTE_STATE/dnsmasq.pid"
env \
  PATH="$MOCK_BIN:/usr/bin:/bin" \
  MOCK_NFT_MODE=handle-reused \
  REMOTE_NATIVE_FOR_HARNESS="$REMOTE_NATIVE" \
  REMOTE_NATIVE_ACTION=clean \
  IP_FORWARD_LOCK_FOR_HARNESS="$IP_FORWARD_LOCK" \
  IP_FORWARD_STATE_FOR_HARNESS="$IP_FORWARD_STATE" \
  IP_FORWARD_SYSCTL_FOR_HARNESS="$IP_FORWARD_SYSCTL" \
  NVPN_MOBILE_WG_REMOTE_STATE_DIR="$REMOTE_STATE" \
  NVPN_MOBILE_WG_REMOTE_INTERFACE=nwg55999 \
  NVPN_MOBILE_WG_REMOTE_NFT_TABLE=nvpnwg55999 \
  NVPN_MOBILE_WG_REMOTE_ENDPOINT_FAMILY=ipv6 \
  NVPN_MOBILE_WG_LISTEN_PORT=55999 \
  "$REMOTE_RUNNER"

LEASE_A="$(mktemp -d /tmp/nvpn-mobile-wg-exit.lease-a.XXXXXX)"
LEASE_B="$(mktemp -d /tmp/nvpn-mobile-wg-exit.lease-b.XXXXXX)"
LEASE_C="$(mktemp -d /tmp/nvpn-mobile-wg-exit.lease-c.XXXXXX)"
LEASE_HUP="$(mktemp -d /tmp/nvpn-mobile-wg-exit.lease-hup.XXXXXX)"
MOCK_IP_STATE="$TMP_ROOT/interfaces"
mkdir -p "$MOCK_IP_STATE"

run_lease_action() {
  local lease_action="$1" lease_state="$2" lease_interface="$3"
  local slow_write="${4:-0}"
  env \
    PATH="$MOCK_BIN:/usr/bin:/bin" \
    MOCK_IP_STATE_DIR="$MOCK_IP_STATE" \
    REMOTE_NATIVE_FOR_HARNESS="$REMOTE_NATIVE" \
    REMOTE_NATIVE_ACTION="$lease_action" \
    SLOW_IP_FORWARD_WRITE_FOR_HARNESS="$slow_write" \
    HUP_READY_FOR_HARNESS="${HUP_READY_FOR_HARNESS:-}" \
    IP_FORWARD_LOCK_FOR_HARNESS="$IP_FORWARD_LOCK" \
    IP_FORWARD_STATE_FOR_HARNESS="$IP_FORWARD_STATE" \
    IP_FORWARD_SYSCTL_FOR_HARNESS="$IP_FORWARD_SYSCTL" \
    NVPN_MOBILE_WG_REMOTE_STATE_DIR="$lease_state" \
    NVPN_MOBILE_WG_REMOTE_INTERFACE="$lease_interface" \
    NVPN_MOBILE_WG_REMOTE_NFT_TABLE="nvpn$lease_interface" \
    NVPN_MOBILE_WG_REMOTE_ENDPOINT_FAMILY=ipv6 \
    bash "$REMOTE_RUNNER"
}

assert_forwarding_lease_invariant() {
  local before after leases=""
  before="$(<"$IP_FORWARD_SYSCTL")"
  if [[ -d "$IP_FORWARD_STATE/leases" ]]; then
    leases="$(
      find "$IP_FORWARD_STATE/leases" -maxdepth 1 -type f -size +0c \
        -print 2>/dev/null || true
    )"
  fi
  after="$(<"$IP_FORWARD_SYSCTL")"
  if [[ "$before" == "0" && "$after" == "0" && -n "$leases" ]]; then
    echo "IPv4 forwarding was restored while a fixture lease remained" >&2
    return 1
  fi
}

wait_for_lease_jobs() {
  local first_pid="$1" second_pid="$2" failed=0
  while kill -0 "$first_pid" 2>/dev/null \
    || kill -0 "$second_pid" 2>/dev/null
  do
    assert_forwarding_lease_invariant || failed=1
    sleep 0.01
  done
  wait "$first_pid" || failed=1
  wait "$second_pid" || failed=1
  assert_forwarding_lease_invariant || failed=1
  return "$failed"
}

assert_zero_leases_and_original() {
  local expected="$1"
  [[ "$(<"$IP_FORWARD_SYSCTL")" == "$expected" \
    && ! -e "$IP_FORWARD_STATE" ]] || {
    echo "IPv4 forwarding lease state did not restore its original value" >&2
    return 1
  }
}

# Both mobile lanes acquire distinct leases concurrently. Stopping either
# owner must leave forwarding enabled until the last owner releases.
printf '0\n' >"$IP_FORWARD_SYSCTL"
touch "$MOCK_IP_STATE/nwg56001" "$MOCK_IP_STATE/nwg56002"
run_lease_action lease-acquire "$LEASE_A" nwg56001 1 &
lease_a_pid=$!
run_lease_action lease-acquire "$LEASE_B" nwg56002 1 &
lease_b_pid=$!
wait_for_lease_jobs "$lease_a_pid" "$lease_b_pid"
[[ "$(<"$IP_FORWARD_SYSCTL")" == "1" \
  && "$(<"$IP_FORWARD_STATE/leases/nwg56001")" == "$LEASE_A" \
  && "$(<"$IP_FORWARD_STATE/leases/nwg56002")" == "$LEASE_B" ]]
run_lease_action lease-stop "$LEASE_A" nwg56001
[[ "$(<"$IP_FORWARD_SYSCTL")" == "1" \
  && ! -e "$IP_FORWARD_STATE/leases/nwg56001" \
  && -f "$IP_FORWARD_STATE/leases/nwg56002" ]]
run_lease_action lease-stop "$LEASE_B" nwg56002
assert_zero_leases_and_original 0

# Reverse stop order and preserve an originally-enabled host value.
printf '1\n' >"$IP_FORWARD_SYSCTL"
touch "$MOCK_IP_STATE/nwg56001" "$MOCK_IP_STATE/nwg56002"
run_lease_action lease-acquire "$LEASE_A" nwg56001 1 &
lease_a_pid=$!
run_lease_action lease-acquire "$LEASE_B" nwg56002 1 &
lease_b_pid=$!
wait_for_lease_jobs "$lease_a_pid" "$lease_b_pid"
run_lease_action lease-stop "$LEASE_B" nwg56002
[[ "$(<"$IP_FORWARD_SYSCTL")" == "1" \
  && -f "$IP_FORWARD_STATE/leases/nwg56001" \
  && ! -e "$IP_FORWARD_STATE/leases/nwg56002" ]]
run_lease_action lease-stop "$LEASE_A" nwg56001
assert_zero_leases_and_original 1

# Interleave the last owner's stop with a new fixture start. The flock covers
# lease release through interface deletion, so either ordering leaves the new
# owner valid and forwarding enabled without a lease-plus-zero observation.
printf '0\n' >"$IP_FORWARD_SYSCTL"
touch "$MOCK_IP_STATE/nwg56001" "$MOCK_IP_STATE/nwg56003"
run_lease_action lease-acquire "$LEASE_A" nwg56001
run_lease_action lease-stop "$LEASE_A" nwg56001 1 &
lease_a_pid=$!
run_lease_action lease-acquire "$LEASE_C" nwg56003 1 &
lease_c_pid=$!
wait_for_lease_jobs "$lease_a_pid" "$lease_c_pid"
[[ "$(<"$IP_FORWARD_SYSCTL")" == "1" \
  && ! -e "$IP_FORWARD_STATE/leases/nwg56001" \
  && "$(<"$IP_FORWARD_STATE/leases/nwg56003")" == "$LEASE_C" \
  && ! -e "$MOCK_IP_STATE/nwg56001" \
  && -e "$MOCK_IP_STATE/nwg56003" ]]
run_lease_action lease-stop "$LEASE_C" nwg56003
assert_zero_leases_and_original 0

# A lease whose validated owner/interface relationship no longer exists is
# retained for diagnosis; a new lane must not silently prune or replace it.
mkdir -p "$IP_FORWARD_STATE/leases"
printf '0\n' >"$IP_FORWARD_STATE/original"
printf '1\n' >"$IP_FORWARD_SYSCTL"
printf '%s\n' "$LEASE_A" >"$IP_FORWARD_STATE/leases/nwg56001"
rm -f "$MOCK_IP_STATE/nwg56001"
touch "$MOCK_IP_STATE/nwg56002"
if run_lease_action lease-acquire "$LEASE_B" nwg56002 >/dev/null 2>&1; then
  echo "IPv4 forwarding lease accepted stale shared state" >&2
  exit 1
fi
[[ "$(<"$IP_FORWARD_STATE/leases/nwg56001")" == "$LEASE_A" \
  && ! -e "$IP_FORWARD_STATE/leases/nwg56002" \
  && "$(<"$IP_FORWARD_SYSCTL")" == "1" ]]
rm -rf "$IP_FORWARD_STATE"

# SSH commonly terminates the remote process with SIGHUP. Exercise the exact
# production trap and prove it releases the lease and deletes its interface.
printf '0\n' >"$IP_FORWARD_SYSCTL"
touch "$MOCK_IP_STATE/nwg56004"
HUP_READY="$TMP_ROOT/hup-ready"
HUP_READY_FOR_HARNESS="$HUP_READY" \
  run_lease_action lease-hup-wait "$LEASE_HUP" nwg56004 &
hup_pid=$!
for _ in $(seq 1 200); do
  [[ -f "$HUP_READY" ]] && break
  kill -0 "$hup_pid" 2>/dev/null || break
  sleep 0.01
done
[[ -f "$HUP_READY" ]] || {
  echo "SIGHUP cleanup fixture did not acquire its forwarding lease" >&2
  kill "$hup_pid" 2>/dev/null || true
  wait "$hup_pid" 2>/dev/null || true
  exit 1
}
hup_target="$(<"$HUP_READY")"
[[ "$hup_target" =~ ^[1-9][0-9]*$ ]]
kill -HUP "$hup_target"
set +e
wait "$hup_pid"
hup_status=$?
set -e
[[ "$hup_status" -ne 0 \
  && ! -e "$MOCK_IP_STATE/nwg56004" ]]
assert_zero_leases_and_original 0

echo "mobile WireGuard fixture cleanup harness passed"
