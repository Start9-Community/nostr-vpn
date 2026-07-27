#!/usr/bin/env bash
# Shared transport/guest/peer helpers for the Linux dual-NIC gate.
# This file is sourced after the orchestrator initializes its run-scoped state.

fail() {
  echo "Linux VM underlay network-change e2e failed: $*" >&2
  exit 1
}
validate_simple_value() {
  local label="$1"
  local value="$2"
  if [[ -z "$value" || "$value" =~ [[:space:]\'\"\;\&\|\`\\] ]]; then
    fail "$label contains unsupported shell characters"
  fi
}

for pair in \
  "hypervisor SSH:$HYPERVISOR_SSH" \
  "VM name:$VM_NAME" \
  "Linux SSH:$LINUX_SSH" \
  "network ID:$NETWORK_ID" \
  "guest source root:$GUEST_SRC_ROOT"
do
  validate_simple_value "${pair%%:*}" "${pair#*:}"
done

for command in git ssh jq awk; do
  command -v "$command" >/dev/null 2>&1 \
    || fail "required command is missing: $command"
done

primary_ssh_command() {
  LINUX_PRIMARY_SSH=(ssh -o BatchMode=yes -o ConnectTimeout=10)
  if [[ -n "$PRIMARY_PROXY" ]]; then
    LINUX_PRIMARY_SSH+=(-o "ProxyCommand=$PRIMARY_PROXY")
  elif [[ -n "$LINUX_JUMP" ]]; then
    LINUX_PRIMARY_SSH+=(-J "$LINUX_JUMP")
  fi
  LINUX_PRIMARY_SSH+=("$LINUX_SSH")
}

secondary_ssh_command() {
  LINUX_SECONDARY_SSH=(
    ssh
    -o BatchMode=yes
    -o ConnectTimeout=10
    -o "ProxyCommand=$SECONDARY_PROXY"
    "$LINUX_SSH"
  )
}

run_primary() {
  primary_ssh_command
  "${LINUX_PRIMARY_SSH[@]}" "$@"
}

run_secondary() {
  secondary_ssh_command
  "${LINUX_SECONDARY_SSH[@]}" "$@"
}

run_guest_primary() {
  local action="$1"
  shift
  primary_ssh_command
  "${LINUX_PRIMARY_SSH[@]}" sudo -n env \
    "NVPN_UNDERLAY_BINARY=$GUEST_BINARY" \
    "NVPN_UNDERLAY_STATE_DIR=$GUEST_STATE_DIR" \
    "NVPN_UNDERLAY_PRIMARY_MAC=$PRIMARY_MAC" \
    "NVPN_UNDERLAY_SECONDARY_MAC=$SECONDARY_MAC" \
    "NVPN_UNDERLAY_SECONDARY_ADDRESS=$SECONDARY_ADDRESS" \
    "NVPN_UNDERLAY_SECONDARY_PREFIX=$SECONDARY_PREFIX" \
    "NVPN_UNDERLAY_SECONDARY_GATEWAY=$SECONDARY_GATEWAY" \
    "NVPN_UNDERLAY_NETWORK_ID=$NETWORK_ID" \
    "NVPN_UNDERLAY_FIXTURE_DNS_NAME=$FIXTURE_DNS_NAME" \
    "NVPN_UNDERLAY_PROBE_URL=$PROBE_URL" \
    "NVPN_UNDERLAY_TUN_IFACE=$TARGET_TUN_IFACE" \
    "NVPN_UNDERLAY_RECOVERY_DEADLINE_MS=$RECOVERY_DEADLINE_MS" \
    "NVPN_UNDERLAY_EXPECTED_FIPS_REV=$EXPECTED_FIPS_REV" \
    "$@" \
    "$GUEST_REPO/scripts/desktop-linux-underlay-change-e2e.sh" "$action"
}

run_guest_secondary() {
  local action="$1"
  shift
  secondary_ssh_command
  "${LINUX_SECONDARY_SSH[@]}" sudo -n env \
    "NVPN_UNDERLAY_BINARY=$GUEST_BINARY" \
    "NVPN_UNDERLAY_STATE_DIR=$GUEST_STATE_DIR" \
    "NVPN_UNDERLAY_PRIMARY_MAC=$PRIMARY_MAC" \
    "NVPN_UNDERLAY_SECONDARY_MAC=$SECONDARY_MAC" \
    "NVPN_UNDERLAY_SECONDARY_ADDRESS=$SECONDARY_ADDRESS" \
    "NVPN_UNDERLAY_SECONDARY_PREFIX=$SECONDARY_PREFIX" \
    "NVPN_UNDERLAY_SECONDARY_GATEWAY=$SECONDARY_GATEWAY" \
    "NVPN_UNDERLAY_NETWORK_ID=$NETWORK_ID" \
    "NVPN_UNDERLAY_FIXTURE_DNS_NAME=$FIXTURE_DNS_NAME" \
    "NVPN_UNDERLAY_PROBE_URL=$PROBE_URL" \
    "NVPN_UNDERLAY_TUN_IFACE=$TARGET_TUN_IFACE" \
    "NVPN_UNDERLAY_RECOVERY_DEADLINE_MS=$RECOVERY_DEADLINE_MS" \
    "NVPN_UNDERLAY_EXPECTED_FIPS_REV=$EXPECTED_FIPS_REV" \
    "$@" \
    "$GUEST_REPO/scripts/desktop-linux-underlay-change-e2e.sh" "$action"
}

guest_marker_exists() {
  run_secondary sudo -n test -e "$GUEST_STATE_DIR/$1" >/dev/null 2>&1
}

wait_for_guest_marker() {
  local name="$1"
  local timeout_secs="${2:-30}"
  local started="$SECONDS"
  while ((SECONDS - started < timeout_secs)); do
    if guest_marker_exists "$name"; then
      return 0
    fi
    if [[ -n "$LINUX_RUN_PID" ]] && ! kill -0 "$LINUX_RUN_PID" 2>/dev/null; then
      wait "$LINUX_RUN_PID" || true
      tail -n 160 "$ARTIFACT_DIR/linux-run.log" >&2 || true
      fail "Linux guest runner exited before $name"
    fi
    sleep 0.1
  done
  tail -n 160 "$ARTIFACT_DIR/linux-run.log" >&2 || true
  fail "timed out waiting for Linux guest marker $name"
}

signal_guest() {
  run_secondary sudo -n touch "$GUEST_STATE_DIR/$1"
}

peer_command() {
  local action="$1"
  shift
  local -a peer_env
  peer_env=(
    "NVPN_UNDERLAY_PEER_BINARY=$HYPERVISOR_BINARY" \
    "NVPN_UNDERLAY_PEER_STATE_DIR=$PEER_STATE_DIR" \
    "NVPN_UNDERLAY_NETWORK_ID=$NETWORK_ID" \
    "NVPN_UNDERLAY_PEER_TUN_IFACE=$PEER_TUN_IFACE" \
    "NVPN_UNDERLAY_PEER_LISTEN_PORT=$PEER_LISTEN_PORT" \
    "NVPN_UNDERLAY_FIXTURE_DNS_NAME=$FIXTURE_DNS_NAME" \
    "NVPN_UNDERLAY_DNS_COUNTER_CHAIN=$COUNTER_CHAIN" \
    "NVPN_UNDERLAY_PEER_NETNS=$PEER_NETNS" \
    "NVPN_UNDERLAY_PEER_HOST_VETH=$PEER_HOST_VETH" \
    "NVPN_UNDERLAY_PEER_NS_VETH=$PEER_NS_VETH" \
    "NVPN_UNDERLAY_PEER_HOST_ADDRESS=$PEER_NAMESPACE_HOST_ADDRESS" \
    "NVPN_UNDERLAY_PEER_ADDRESS=$PEER_ENDPOINT_HOST" \
    "NVPN_UNDERLAY_PEER_PREFIX=$PEER_NAMESPACE_PREFIX" \
    "NVPN_UNDERLAY_PEER_UPLINK=$HYPERVISOR_UPLINK" \
    "NVPN_UNDERLAY_PEER_FORWARD_CHAIN=$PEER_FORWARD_CHAIN" \
    "NVPN_UNDERLAY_PEER_NAT_CHAIN=$PEER_NAT_CHAIN" \
    "NVPN_UNDERLAY_TARGET_PRIMARY_ADDRESS=$PRIMARY_ADDRESS" \
    "NVPN_UNDERLAY_TARGET_SECONDARY_ADDRESS=$SECONDARY_ADDRESS" \
    "NVPN_UNDERLAY_TARGET_LISTEN_PORT=$TARGET_LISTEN_PORT"
    "NVPN_UNDERLAY_WG_LISTEN_PORT=$WG_LISTEN_PORT"
    "NVPN_UNDERLAY_WG_PEER_IFACE=$WG_PEER_IFACE"
    "NVPN_UNDERLAY_WG_CLIENT_ADDRESS=$WG_CLIENT_ADDRESS"
    "NVPN_UNDERLAY_WG_SERVER_ADDRESS=$WG_SERVER_ADDRESS"
    "NVPN_UNDERLAY_EXPECTED_FIPS_REV=$EXPECTED_FIPS_REV"
  )
  case "$action" in
    namespace-setup|namespace-cleanup|namespace-audit)
      ssh -o BatchMode=yes "$HYPERVISOR_SSH" \
        sudo -n env "${peer_env[@]}" "$@" \
        "$HYPERVISOR_REPO/scripts/desktop-linux-underlay-peer-e2e.sh" "$action"
      ;;
    *)
      ssh -o BatchMode=yes "$HYPERVISOR_SSH" \
        sudo -n ip netns exec "$PEER_NETNS" env "${peer_env[@]}" "$@" \
        "$HYPERVISOR_REPO/scripts/desktop-linux-underlay-peer-e2e.sh" "$action"
      ;;
  esac
}
