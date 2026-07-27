#!/usr/bin/env bash
# Real Linux VM network-change gate. The virtualization host creates a
# transient second NAT/NIC and physically cuts/restores the original link.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HYPERVISOR_SSH="${NVPN_DESKTOP_UNDERLAY_HYPERVISOR_SSH:?set NVPN_DESKTOP_UNDERLAY_HYPERVISOR_SSH}"
VM_NAME="${NVPN_LINUX_UNDERLAY_VM_NAME:-${NVPN_UBUNTU_VM_NAME:-}}"
[[ -n "$VM_NAME" ]] || {
  echo "set NVPN_LINUX_UNDERLAY_VM_NAME" >&2
  exit 2
}
LINUX_SSH="${NVPN_UBUNTU_SSH_HOST:?set NVPN_UBUNTU_SSH_HOST}"
PRIMARY_PROXY="${NVPN_UBUNTU_SSH_PROXY_COMMAND:-}"
LINUX_JUMP="${NVPN_UBUNTU_SSH_JUMP:-}"
GUEST_SRC_ROOT="${NVPN_LINUX_UNDERLAY_GUEST_SRC_ROOT:-src/nvpn-desktop-underlay/linux-target}"
GUEST_REPO="$GUEST_SRC_ROOT/nostr-vpn-release-gate"
GUEST_BINARY="$GUEST_REPO/target/release/nvpn"
LOCAL_FIPS_REPO="${NVPN_FIPS_REPO_PATH:-}"
EXPECTED_FIPS_REV="${NVPN_EXPECTED_FIPS_REV:-}"
FIPS_SOURCE_REVISION=""
GUEST_FIPS_REPO="$GUEST_SRC_ROOT/fips-release-gate"
HYPERVISOR_SRC_ROOT="${NVPN_LINUX_UNDERLAY_HYPERVISOR_SRC_ROOT:-src/nvpn-desktop-underlay/linux-peer}"
HYPERVISOR_REPO="$HYPERVISOR_SRC_ROOT/nostr-vpn-release-gate"
HYPERVISOR_BINARY="$HYPERVISOR_REPO/target/release/nvpn"
HYPERVISOR_FIPS_REPO="$HYPERVISOR_SRC_ROOT/fips-release-gate"
RECOVERY_DEADLINE_MS="${NVPN_DESKTOP_UNDERLAY_RECOVERY_DEADLINE_MS:-4000}"
NETWORK_ID="${NVPN_LINUX_UNDERLAY_NETWORK_ID:-desktop-underlay-linux-release-gate}"
SECONDARY_GATEWAY="${NVPN_LINUX_UNDERLAY_SECONDARY_GATEWAY:-172.31.254.1}"
SECONDARY_ADDRESS="${NVPN_LINUX_UNDERLAY_SECONDARY_ADDRESS:-172.31.254.10}"
SECONDARY_NETMASK="${NVPN_LINUX_UNDERLAY_SECONDARY_NETMASK:-255.255.255.0}"
SECONDARY_PREFIX="${NVPN_LINUX_UNDERLAY_SECONDARY_PREFIX:-24}"
FIXTURE_DNS_NAME="${NVPN_DESKTOP_UNDERLAY_FIXTURE_DNS_NAME:-underlay-gate.nvpn.test}"
PROBE_URL="${NVPN_DESKTOP_UNDERLAY_PROBE_URL:-https://example.com/}"
RUN_TOKEN="linux-$$-$RANDOM"
NETWORK_NAME="nvpn-underlay-$RUN_TOKEN"
PEER_STATE_DIR="/tmp/nvpn-underlay-peer-$RUN_TOKEN"
GUEST_STATE_DIR="/tmp/nvpn-underlay-target-$RUN_TOKEN"
PEER_TUN_IFACE="nvup${RANDOM}"
TARGET_TUN_IFACE="nvut${RANDOM}"
PEER_LISTEN_PORT="$((48000 + RANDOM % 1000))"
TARGET_LISTEN_PORT="$((49000 + RANDOM % 1000))"
WG_LISTEN_PORT="$((50000 + RANDOM % 1000))"
WG_PEER_IFACE="nvwg${RANDOM}"
WG_CLIENT_ADDRESS="${NVPN_LINUX_UNDERLAY_WG_CLIENT_ADDRESS:-10.232.0.2/32}"
WG_SERVER_ADDRESS="${NVPN_LINUX_UNDERLAY_WG_SERVER_ADDRESS:-10.232.0.1/24}"
COUNTER_CHAIN="nvu-$((RANDOM % 100000))"
PEER_NETNS="nvl$((RANDOM % 100000))"
PEER_HOST_VETH="nvlh$((RANDOM % 100000))"
PEER_NS_VETH="nvln0"
PEER_NAMESPACE_HOST_ADDRESS="${NVPN_LINUX_UNDERLAY_PEER_NAMESPACE_HOST_ADDRESS:-10.231.254.1}"
PEER_ENDPOINT_HOST="${NVPN_LINUX_UNDERLAY_PEER_NAMESPACE_ADDRESS:-10.231.254.2}"
PEER_NAMESPACE_PREFIX="${NVPN_LINUX_UNDERLAY_PEER_NAMESPACE_PREFIX:-30}"
PEER_FORWARD_CHAIN="nvf$((RANDOM % 100000))"
PEER_NAT_CHAIN="nvn$((RANDOM % 100000))"
ARTIFACT_DIR="${NVPN_LINUX_UNDERLAY_ARTIFACT_DIR:-$ROOT/artifacts/desktop-underlay/linux-$RUN_TOKEN}"
SECONDARY_MAC=""
PRIMARY_MAC=""
PRIMARY_IFACE=""
PRIMARY_SOURCE=""
PRIMARY_ADDRESS=""
HYPERVISOR_UPLINK=""
SECONDARY_PROXY=""
LINUX_RUN_PID=""
GUEST_BINARY_COPY_TMP=""
NETWORK_CREATED=0
NIC_ATTACHED=0
PEER_INITIALIZED=0
PEER_NAMESPACE_ATTEMPTED=0
TARGET_NPUB=""
TARGET_TUNNEL_IP=""
TARGET_PRIMARY_IFACE=""
TARGET_SECONDARY_IFACE=""
TARGET_PRIMARY_GATEWAY=""
TARGET_PRIMARY_ADDRESS=""
TARGET_WG_PUBLIC_KEY=""
WG_SERVER_PUBLIC_KEY=""
WG_ENDPOINT=""

mkdir -p "$ARTIFACT_DIR"

source "$ROOT/scripts/linux-vm-desktop-underlay-change-e2e.lib.sh"
current_tree() {
  local repo="${1:-$ROOT}"
  local git_dir tmp_index tree
  git_dir="$(git -C "$repo" rev-parse --path-format=absolute --git-dir)"
  tmp_index="$(mktemp "$git_dir/desktop-underlay-linux-index.XXXXXX")"
  (
    export GIT_INDEX_FILE="$tmp_index"
    git -C "$repo" read-tree HEAD
    git -C "$repo" add -A
    git -C "$repo" write-tree
  )
  rm -f "$tmp_index"
}

resolve_expected_fips_revision() {
  local local_revision
  if [[ -n "$LOCAL_FIPS_REPO" ]]; then
    [[ -z "$(git -C "$LOCAL_FIPS_REPO" status --porcelain --untracked-files=all)" ]] \
      || fail "the exact FIPS release-gate checkout must be committed and clean"
    local_revision="$(git -C "$LOCAL_FIPS_REPO" rev-parse HEAD)"
    if [[ -n "$EXPECTED_FIPS_REV" \
      && "$local_revision" != "$EXPECTED_FIPS_REV"* \
      && "$EXPECTED_FIPS_REV" != "$local_revision"* ]]
    then
      fail "NVPN_EXPECTED_FIPS_REV differs from the local FIPS candidate"
    fi
    FIPS_SOURCE_REVISION="$local_revision"
    EXPECTED_FIPS_REV="${local_revision:0:10}"
  else
    EXPECTED_FIPS_REV="${EXPECTED_FIPS_REV:0:10}"
  fi
  [[ "$EXPECTED_FIPS_REV" =~ ^[0-9a-f]{10}$ ]] \
    || fail "set NVPN_EXPECTED_FIPS_REV to the intended FIPS Git revision"
}

sync_and_build_candidates() {
  local expected_tree target_tree hypervisor_tree
  local expected_fips_tree="" target_fips_tree="" hypervisor_fips_tree=""
  expected_tree="$(current_tree)"
  {
    printf 'nvpn_base_commit=%s\n' "$(git -C "$ROOT" rev-parse HEAD)"
    printf 'nvpn_tree=%s\n' "$expected_tree"
    printf 'fips_commit=%s\n' "$FIPS_SOURCE_REVISION"
    if [[ -n "$LOCAL_FIPS_REPO" ]]; then
      printf 'fips_tree=%s\n' "$(current_tree "$LOCAL_FIPS_REPO")"
    fi
  } >"$ARTIFACT_DIR/source-provenance.txt"
  env NVPN_UBUNTU_GUEST_SRC_ROOT="$GUEST_SRC_ROOT" \
    "$ROOT/scripts/ubuntu-vm-git-sync.sh" "$LINUX_SSH"
  env \
    NVPN_UBUNTU_SSH_HOST="$HYPERVISOR_SSH" \
    NVPN_UBUNTU_SSH_PROXY_COMMAND= \
    NVPN_UBUNTU_SSH_JUMP= \
    NVPN_UBUNTU_GUEST_SRC_ROOT="$HYPERVISOR_SRC_ROOT" \
    "$ROOT/scripts/ubuntu-vm-git-sync.sh" "$HYPERVISOR_SSH"

  if [[ -n "$LOCAL_FIPS_REPO" ]]; then
    for crate in fips-core fips-endpoint fips-identity; do
      [[ -f "$LOCAL_FIPS_REPO/crates/$crate/Cargo.toml" ]] \
        || fail "NVPN_FIPS_REPO_PATH is missing crates/$crate/Cargo.toml"
    done
    expected_fips_tree="$(current_tree "$LOCAL_FIPS_REPO")"
    env \
      NVPN_UBUNTU_LOCAL_REPO_PATH="$LOCAL_FIPS_REPO" \
      NVPN_UBUNTU_GUEST_SRC_ROOT="$GUEST_SRC_ROOT" \
      NVPN_UBUNTU_GUEST_REPO_NAME=fips-release-gate \
      NVPN_UBUNTU_REPO_LABEL=fips \
      NVPN_UBUNTU_GIT_REF=refs/heads/codex/ubuntu-vm-fips-sync \
      "$ROOT/scripts/ubuntu-vm-git-sync.sh" "$LINUX_SSH"
    env \
      NVPN_UBUNTU_SSH_HOST="$HYPERVISOR_SSH" \
      NVPN_UBUNTU_SSH_PROXY_COMMAND= \
      NVPN_UBUNTU_SSH_JUMP= \
      NVPN_UBUNTU_LOCAL_REPO_PATH="$LOCAL_FIPS_REPO" \
      NVPN_UBUNTU_GUEST_SRC_ROOT="$HYPERVISOR_SRC_ROOT" \
      NVPN_UBUNTU_GUEST_REPO_NAME=fips-release-gate \
      NVPN_UBUNTU_REPO_LABEL=fips \
      NVPN_UBUNTU_GIT_REF=refs/heads/codex/ubuntu-vm-fips-sync \
      "$ROOT/scripts/ubuntu-vm-git-sync.sh" "$HYPERVISOR_SSH"
    run_primary \
      "git -C '$GUEST_FIPS_REPO' checkout --detach '$FIPS_SOURCE_REVISION' >/dev/null"
    ssh -o BatchMode=yes "$HYPERVISOR_SSH" \
      "git -C '$HYPERVISOR_FIPS_REPO' checkout --detach '$FIPS_SOURCE_REVISION' >/dev/null"
  fi

  target_tree="$(run_primary "git -C '$GUEST_REPO' rev-parse 'HEAD^{tree}'")"
  hypervisor_tree="$(ssh -o BatchMode=yes "$HYPERVISOR_SSH" \
    "git -C '$HYPERVISOR_REPO' rev-parse 'HEAD^{tree}'")"
  [[ "$target_tree" == "$expected_tree" ]] \
    || fail "Linux target tree differs from the release-gate tree"
  [[ "$hypervisor_tree" == "$expected_tree" ]] \
    || fail "Linux peer tree differs from the release-gate tree"
  if [[ -n "$LOCAL_FIPS_REPO" ]]; then
    target_fips_tree="$(run_primary \
      "git -C '$GUEST_FIPS_REPO' rev-parse 'HEAD^{tree}'")"
    hypervisor_fips_tree="$(ssh -o BatchMode=yes "$HYPERVISOR_SSH" \
      "git -C '$HYPERVISOR_FIPS_REPO' rev-parse 'HEAD^{tree}'")"
    [[ "$target_fips_tree" == "$expected_fips_tree" ]] \
      || fail "Linux target FIPS tree differs from the local release-gate tree"
    [[ "$hypervisor_fips_tree" == "$expected_fips_tree" ]] \
      || fail "Linux peer FIPS tree differs from the local release-gate tree"
  fi

  local target_abi peer_abi
  target_abi="$(run_primary \
    '. /etc/os-release; printf "%s|%s|%s|%s|%s\n" "$ID" "$VERSION_ID" "$(uname -m)" "$(getconf GNU_LIBC_VERSION)" "$(rustc -vV | sed -n "s/^host: //p")"')"
  peer_abi="$(ssh -o BatchMode=yes "$HYPERVISOR_SSH" \
    '. /etc/os-release; printf "%s|%s|%s|%s|%s\n" "$ID" "$VERSION_ID" "$(uname -m)" "$(getconf GNU_LIBC_VERSION)" "$(rustc -vV | sed -n "s/^host: //p")"')"
  [[ "$target_abi" == "$peer_abi" ]] \
    || fail "Linux target and peer OS, architecture, or glibc differ"
  {
    printf 'target=%s\n' "$target_abi"
    printf 'peer=%s\n' "$peer_abi"
  } >"$ARTIFACT_DIR/linux-build-abi.txt"

  ssh -o BatchMode=yes "$HYPERVISOR_SSH" bash -s -- \
    "$HYPERVISOR_REPO" \
    "$([[ -n "$LOCAL_FIPS_REPO" ]] && echo "$HYPERVISOR_FIPS_REPO" || true)" \
    >"$ARTIFACT_DIR/peer-build.log" 2>&1 <<'SH' &
set -euo pipefail
repo="$1"
fips="${2:-}"
cd "$repo"
cargo_args=()
lock_args=(--locked)
if [[ -n "$fips" ]]; then
  [[ "$fips" == /* ]] || fips="$HOME/$fips"
  cargo_args=(
    --config "patch.crates-io.fips-core.path='$fips/crates/fips-core'"
    --config "patch.crates-io.fips-endpoint.path='$fips/crates/fips-endpoint'"
    --config "patch.crates-io.fips-identity.path='$fips/crates/fips-identity'"
  )
  cargo "${cargo_args[@]}" update --offline -p fips-core -p fips-endpoint -p fips-identity
  cargo "${cargo_args[@]}" metadata "${lock_args[@]}" --offline --format-version 1 \
    | jq -e --arg root "$fips/" '
        [.packages[]
          | select(.name == "fips-core" or .name == "fips-endpoint")
          | .manifest_path
          | startswith($root)]
        | length == 2 and all
      ' >/dev/null
fi
cargo "${cargo_args[@]}" build "${lock_args[@]}" --release -p nvpn
SH
  local peer_build_pid="$!"

  primary_ssh_command
  "${LINUX_PRIMARY_SSH[@]}" bash -s -- \
    "$GUEST_REPO" "$([[ -n "$LOCAL_FIPS_REPO" ]] && echo "$GUEST_FIPS_REPO" || true)" \
    >"$ARTIFACT_DIR/target-linux-check.log" 2>&1 <<'SH' &
set -euo pipefail
repo="$1"
fips="${2:-}"
cd "$repo/linux"
cargo_args=()
if [[ -n "$fips" ]]; then
  [[ "$fips" == /* ]] || fips="$HOME/$fips"
  cargo_args=(
    --config "patch.crates-io.fips-core.path='$fips/crates/fips-core'"
    --config "patch.crates-io.fips-endpoint.path='$fips/crates/fips-endpoint'"
    --config "patch.crates-io.fips-identity.path='$fips/crates/fips-identity'"
  )
  cargo "${cargo_args[@]}" update --offline -p fips-core -p fips-endpoint -p fips-identity
fi
cargo "${cargo_args[@]}" check --locked --offline
SH
  local target_check_pid="$!"
  local peer_build_status=0
  local target_check_status=0
  wait "$peer_build_pid" || peer_build_status="$?"
  wait "$target_check_pid" || target_check_status="$?"
  if [[ "$peer_build_status" != "0" || "$target_check_status" != "0" ]]; then
    echo "Linux peer build status: $peer_build_status" >&2
    tail -n 120 "$ARTIFACT_DIR/peer-build.log" >&2 || true
    echo "Linux target GTK check status: $target_check_status" >&2
    tail -n 120 "$ARTIFACT_DIR/target-linux-check.log" >&2 || true
    fail "parallel Linux candidate build/check failed"
  fi

  local copied_binary="$ARTIFACT_DIR/nvpn-linux-release"
  GUEST_BINARY_COPY_TMP="$GUEST_BINARY.copy-$RUN_TOKEN"
  scp -q -o BatchMode=yes \
    "$HYPERVISOR_SSH:$HYPERVISOR_BINARY" "$copied_binary"
  local -a primary_scp
  primary_scp=(scp -q -o BatchMode=yes -o ConnectTimeout=10)
  if [[ -n "$PRIMARY_PROXY" ]]; then
    primary_scp+=(-o "ProxyCommand=$PRIMARY_PROXY")
  elif [[ -n "$LINUX_JUMP" ]]; then
    primary_scp+=(-J "$LINUX_JUMP")
  fi
  "${primary_scp[@]}" "$copied_binary" "$LINUX_SSH:$GUEST_BINARY_COPY_TMP"
  run_primary \
    "chmod 0755 '$GUEST_BINARY_COPY_TMP' && mv -f '$GUEST_BINARY_COPY_TMP' '$GUEST_BINARY'"
  GUEST_BINARY_COPY_TMP=""

  local source_sha target_sha peer_sha
  source_sha="$(shasum -a 256 "$copied_binary" | awk '{ print $1 }')"
  target_sha="$(run_primary "sha256sum '$GUEST_BINARY' | cut -d ' ' -f1")"
  peer_sha="$(ssh -o BatchMode=yes "$HYPERVISOR_SSH" \
    "sha256sum '$HYPERVISOR_BINARY' | cut -d ' ' -f1")"
  [[ "$source_sha" == "$target_sha" && "$source_sha" == "$peer_sha" ]] \
    || fail "Linux target and peer production binary SHA-256 receipts differ"
  {
    printf 'source=%s\n' "$source_sha"
    printf 'target=%s\n' "$target_sha"
    printf 'peer=%s\n' "$peer_sha"
  } >"$ARTIFACT_DIR/linux-binary-sha256.txt"
  rm -f "$copied_binary"
}

capture_version_receipts() {
  local target_version peer_version expected
  expected="(rev $EXPECTED_FIPS_REV)"
  target_version="$(run_primary "$GUEST_BINARY version --verbose")"
  peer_version="$(ssh -o BatchMode=yes "$HYPERVISOR_SSH" \
    "$HYPERVISOR_BINARY version --verbose")"
  grep -Fq "$expected" <<<"$target_version" \
    || fail "Linux target binary does not contain the expected FIPS revision"
  grep -Fq "$expected" <<<"$peer_version" \
    || fail "Linux peer binary does not contain the expected FIPS revision"
  printf '%s\n' "$target_version" >"$ARTIFACT_DIR/target-version.txt"
  printf '%s\n' "$peer_version" >"$ARTIFACT_DIR/peer-version.txt"
}

random_mac() {
  local octets
  octets="$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
  printf '52:54:00:%s:%s:%s\n' \
    "${octets:0:2}" "${octets:2:2}" "${octets:4:2}"
}

discover_primary_interface() {
  local row_count rows
  rows="$(ssh -o BatchMode=yes "$HYPERVISOR_SSH" \
    "virsh domiflist '$VM_NAME' | awk '\$2 == \"network\" { print \$1 \"|\" \$3 \"|\" \$5 }'")"
  row_count="$(grep -c . <<<"$rows" || true)"
  [[ "$row_count" == "1" ]] \
    || fail "Linux VM must begin with exactly one libvirt network interface"
  IFS='|' read -r PRIMARY_IFACE PRIMARY_SOURCE PRIMARY_MAC <<<"$rows"
  [[ -n "$PRIMARY_IFACE" && -n "$PRIMARY_SOURCE" && -n "$PRIMARY_MAC" ]]

  PRIMARY_ADDRESS="$(ssh -o BatchMode=yes "$HYPERVISOR_SSH" \
    "virsh domifaddr '$VM_NAME' --source lease | awk '\$2 == \"$PRIMARY_MAC\" && \$3 == \"ipv4\" { sub(/\\/.*/, \"\", \$4); print \$4; exit }'")"
  [[ -n "$PRIMARY_ADDRESS" ]] \
    || fail "could not resolve the Linux VM primary address from libvirt"
  HYPERVISOR_UPLINK="$(ssh -o BatchMode=yes "$HYPERVISOR_SSH" \
    "ip -4 route get 1.1.1.1 | awk '{ for (i = 1; i <= NF; i++) if (\$i == \"dev\") { print \$(i + 1); exit } }'")"
  [[ -n "$HYPERVISOR_UPLINK" ]] \
    || fail "could not resolve the hypervisor physical uplink"
}

attach_secondary_network() {
  SECONDARY_MAC="$(random_mac)"
  ssh -o BatchMode=yes "$HYPERVISOR_SSH" bash -s -- \
    "$VM_NAME" "$NETWORK_NAME" "$SECONDARY_GATEWAY" "$SECONDARY_NETMASK" "$SECONDARY_MAC" <<'SH'
set -euo pipefail
vm="$1"
network="$2"
gateway="$3"
netmask="$4"
mac="$5"
xml="$(mktemp)"
created=0
cleanup_remote() {
  status="$?"
  rm -f "$xml"
  if [[ "$status" -ne 0 && "$created" == "1" ]]; then
    virsh net-destroy "$network" >/dev/null 2>&1 || true
  fi
  exit "$status"
}
trap cleanup_remote EXIT
! virsh net-info "$network" >/dev/null 2>&1
! ip -4 route | grep -Fq "$gateway"
cat >"$xml" <<EOF
<network>
  <name>$network</name>
  <forward mode='nat'/>
  <ip address='$gateway' netmask='$netmask'/>
</network>
EOF
virsh net-create "$xml" >/dev/null
created=1
virsh attach-interface \
  --domain "$vm" \
  --type network \
  --source "$network" \
  --model virtio \
  --mac "$mac" \
  --live >/dev/null
SH
  NETWORK_CREATED=1
  NIC_ATTACHED=1
  SECONDARY_PROXY="ssh -o BatchMode=yes $HYPERVISOR_SSH -W $SECONDARY_ADDRESS:22"
}

wait_for_secondary_adapter() {
  local started="$SECONDS"
  while ((SECONDS - started < 30)); do
    if run_primary \
      "test \"\$(cat /sys/class/net/*/address | grep -Fxc '$SECONDARY_MAC')\" = 1" \
      >/dev/null 2>&1
    then
      return 0
    fi
    sleep 0.25
  done
  fail "Linux did not enumerate the transient second NIC"
}

wait_for_primary_guest() {
  local started="$SECONDS"
  while ((SECONDS - started < 30)); do
    if run_primary true >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

parse_key_value() {
  local key="$1"
  awk -F= -v key="$key" '$1 == key { value = substr($0, length(key) + 2) } END { print value }'
}

guest_initialize() {
  local output json
  output="$(run_guest_primary initialize \
    "NVPN_UNDERLAY_SECONDARY_ADDRESS=$SECONDARY_ADDRESS" \
    "NVPN_UNDERLAY_SECONDARY_PREFIX=$SECONDARY_PREFIX" \
    "NVPN_UNDERLAY_SECONDARY_GATEWAY=$SECONDARY_GATEWAY")"
  json="$(awk '/^\{.*\}$/ { value = $0 } END { print value }' <<<"$output")"
  [[ -n "$json" ]] || {
    printf '%s\n' "$output" >&2
    fail "Linux initialization did not return its identity receipt"
  }
  jq -e . <<<"$json" >/dev/null \
    || fail "Linux initialization returned invalid JSON"
  TARGET_NPUB="$(jq -r '.npub // empty' <<<"$json")"
  TARGET_TUNNEL_IP="$(jq -r '.tunnel_ip // empty' <<<"$json")"
  TARGET_PRIMARY_IFACE="$(jq -r '.primary_interface // empty' <<<"$json")"
  TARGET_SECONDARY_IFACE="$(jq -r '.secondary_interface // empty' <<<"$json")"
  TARGET_PRIMARY_GATEWAY="$(jq -r '.primary_gateway // empty' <<<"$json")"
  TARGET_PRIMARY_ADDRESS="$(jq -r '.primary_address // empty' <<<"$json")"
  TARGET_WG_PUBLIC_KEY="$(jq -r '.wireguard_public_key // empty' <<<"$json")"
  [[ -n "$TARGET_NPUB" \
    && -n "$TARGET_TUNNEL_IP" \
    && -n "$TARGET_PRIMARY_GATEWAY" \
    && -n "$TARGET_PRIMARY_ADDRESS" \
    && -n "$TARGET_WG_PUBLIC_KEY" ]]
  run_primary sudo -n cat "$GUEST_STATE_DIR/platform-network-monitor-probe.log" \
    >"$ARTIFACT_DIR/platform-network-monitor-probe.log"
  grep -Fq 'daemon: platform network change event; sampling physical route' \
    "$ARTIFACT_DIR/platform-network-monitor-probe.log" \
    || fail "production Linux netlink monitor probe receipt is missing"

  for _ in $(seq 1 40); do
    if secondary_ssh_command \
      && "${LINUX_SECONDARY_SSH[@]}" hostname >/dev/null 2>&1
    then
      return 0
    fi
    sleep 0.25
  done
  fail "Linux second NIC is configured but SSH cannot reach it out of band"
}

initialize_and_start_peer() {
  local output wg_output
  PEER_NAMESPACE_ATTEMPTED=1
  peer_command namespace-setup
  PEER_INITIALIZED=1
  output="$(peer_command initialize)"
  PEER_NPUB="$(parse_key_value npub <<<"$output")"
  PEER_TUNNEL_IP="$(parse_key_value tunnel_ip <<<"$output")"
  [[ -n "$PEER_NPUB" && -n "$PEER_TUNNEL_IP" ]]
  PEER_ENDPOINT="$PEER_ENDPOINT_HOST:$PEER_LISTEN_PORT"
  peer_command start \
    "NVPN_UNDERLAY_PEER_PUBLIC_ENDPOINT=$PEER_ENDPOINT" \
    "NVPN_UNDERLAY_TARGET_NPUB=$TARGET_NPUB"
  wg_output="$(peer_command wireguard-setup \
    "NVPN_UNDERLAY_WG_TARGET_PUBLIC_KEY=$TARGET_WG_PUBLIC_KEY")"
  WG_SERVER_PUBLIC_KEY="$(parse_key_value wireguard_public_key <<<"$wg_output")"
  WG_ENDPOINT="$(parse_key_value wireguard_endpoint <<<"$wg_output")"
  [[ -n "$WG_SERVER_PUBLIC_KEY" && -n "$WG_ENDPOINT" ]]
  peer_command listener-audit >"$ARTIFACT_DIR/peer-listener.txt"
  peer_command services \
    "NVPN_UNDERLAY_TARGET_TUNNEL_IP=$TARGET_TUNNEL_IP"
}

start_linux_runner() {
  (
    run_guest_secondary run \
      "NVPN_UNDERLAY_PEER_NPUB=$PEER_NPUB" \
      "NVPN_UNDERLAY_PEER_ENDPOINT=$PEER_ENDPOINT" \
      "NVPN_UNDERLAY_PEER_TUNNEL_IP=$PEER_TUNNEL_IP" \
      "NVPN_UNDERLAY_LISTEN_PORT=$TARGET_LISTEN_PORT" \
      "NVPN_UNDERLAY_WG_PEER_PUBLIC_KEY=$WG_SERVER_PUBLIC_KEY" \
      "NVPN_UNDERLAY_WG_ENDPOINT=$WG_ENDPOINT" \
      "NVPN_UNDERLAY_WG_CLIENT_ADDRESS=$WG_CLIENT_ADDRESS"
  ) >"$ARTIFACT_DIR/linux-run.log" 2>&1 &
  LINUX_RUN_PID="$!"
  wait_for_guest_marker ready 35
  guest_receipt secondary-underlay-ready.json \
    >"$ARTIFACT_DIR/secondary-underlay-ready.json"
  jq -e '
    .carrier == true
    and .active_profile == true
    and .default_route == true
  ' "$ARTIFACT_DIR/secondary-underlay-ready.json" >/dev/null
  peer_command wait-ready >"$ARTIFACT_DIR/peer-ready.json"
  jq -e . "$ARTIFACT_DIR/peer-ready.json" >/dev/null
}

set_primary_link() {
  local state="$1"
  ssh -o BatchMode=yes "$HYPERVISOR_SSH" \
    "date +%s.%N; virsh domif-setlink '$VM_NAME' '$PRIMARY_IFACE' '$state' >/dev/null"
}

assert_peer_recovered_from_source() {
  local cut_timestamp="$1"
  local expected_source="$2"
  local label="$3"
  ssh -o BatchMode=yes "$HYPERVISOR_SSH" bash -s -- \
    "$PEER_STATE_DIR" "$cut_timestamp" "$expected_source" \
    "$((RECOVERY_DEADLINE_MS / 1000))" "$label" <<'SH'
set -euo pipefail
state="$1"
cut="$2"
source_ip="$3"
deadline="$4"
label="$5"
end="$(awk -v cut="$cut" -v deadline="$deadline" 'BEGIN { print cut + deadline }')"
while :; do
  fips_underlay_at="$(awk -v cut="$cut" -v ip="$source_ip" '
    $1 + 0 >= cut && index($0, "IP " ip ".") { print $1; exit }
  ' "$state/fips-underlay.pcap.txt" 2>/dev/null || true)"
  wireguard_underlay_at="$(awk -v cut="$cut" -v ip="$source_ip" '
    $1 + 0 >= cut && index($0, "IP " ip ".") { print $1; exit }
  ' "$state/wireguard-underlay.pcap.txt" 2>/dev/null || true)"
  reverse_at="$(awk -v underlay="$fips_underlay_at" '
    /^\[[0-9]/ {
      timestamp = $1
      gsub(/^\[/, "", timestamp)
      gsub(/\]$/, "", timestamp)
      if (underlay != "" && timestamp + 0 >= underlay && /bytes from/) {
        print timestamp
        exit
      }
    }
  ' "$state/peer-payload.log" 2>/dev/null || true)"
  if [[ -n "$fips_underlay_at" \
    && -n "$wireguard_underlay_at" \
    && -n "$reverse_at" ]]
  then
    awk -v cut="$cut" -v at="$fips_underlay_at" -v deadline="$deadline" \
      'BEGIN { if (at - cut > deadline) exit 1 }'
    awk -v cut="$cut" -v at="$wireguard_underlay_at" -v deadline="$deadline" \
      'BEGIN { if (at - cut > deadline) exit 1 }'
    awk -v underlay="$fips_underlay_at" -v at="$reverse_at" -v deadline="$deadline" \
      'BEGIN { if (at - underlay > deadline) exit 1 }'
    awk -v cut="$cut" -v at="$reverse_at" -v deadline="$deadline" \
      'BEGIN { if (at - cut > deadline) exit 1 }'
    printf '%s_fips_expected_source_after_cut_seconds=%.3f\n' "$label" \
      "$(awk -v cut="$cut" -v at="$fips_underlay_at" 'BEGIN { print at - cut }')"
    printf '%s_wireguard_expected_source_after_cut_seconds=%.3f\n' "$label" \
      "$(awk -v cut="$cut" -v at="$wireguard_underlay_at" 'BEGIN { print at - cut }')"
    printf '%s_reverse_payload_after_expected_source_seconds=%.3f\n' "$label" \
      "$(awk -v underlay="$fips_underlay_at" -v at="$reverse_at" \
        'BEGIN { print at - underlay }')"
    exit 0
  fi
  awk -v now="$(date +%s.%N)" -v end="$end" \
    'BEGIN { exit !(now < end) }' || break
  sleep 0.05
done
echo "$label did not produce new-source FIPS/WireGuard traffic and reverse payload within ${deadline}s" >&2
exit 1
SH
}

guest_receipt() {
  run_secondary sudo -n cat "$GUEST_STATE_DIR/$1"
}

run_underlay_switches() {
  local cut receipt
  signal_guest arm-secondary
  wait_for_guest_marker armed-secondary 30
  cut="$(set_primary_link down)"
  printf '%s\n' "$cut" >"$ARTIFACT_DIR/secondary-link-cut-unix-seconds.txt"
  wait_for_guest_marker secondary.receipt.json 25
  receipt="$(guest_receipt secondary.receipt.json)"
  receipt="$(jq --argjson link_changed "$cut" \
    '. + {host_link_change_unix_seconds: $link_changed}' <<<"$receipt")"
  jq -e \
    --argjson deadline "$RECOVERY_DEADLINE_MS" \
    --arg interface "$TARGET_SECONDARY_IFACE" \
    --arg gateway "$SECONDARY_GATEWAY" \
    --arg source "$SECONDARY_ADDRESS" \
    '.recovery_milliseconds <= $deadline
      and .route_usable_monotonic_milliseconds > 0
      and .recovered_monotonic_milliseconds
        >= .route_usable_monotonic_milliseconds
      and .payload_successes_after > .payload_successes_before
      and .wireguard_payload_successes_after
        > .wireguard_payload_successes_before
      and (.wireguard_endpoint_route | length) == 1
      and .wireguard_endpoint_route[0].dev == $interface
      and .wireguard_endpoint_route[0].gateway == $gateway
      and .wireguard_endpoint_route[0].prefsrc == $source
      and .rebind_receipts_after == (.rebind_receipts_before + 1)' \
    <<<"$receipt" >/dev/null
  printf '%s\n' "$receipt" >"$ARTIFACT_DIR/secondary-receipt.json"
  jq -e . "$ARTIFACT_DIR/secondary-receipt.json" >/dev/null
  assert_peer_recovered_from_source "$cut" "$SECONDARY_ADDRESS" secondary \
    | tee "$ARTIFACT_DIR/secondary-peer-recovery.txt"

  signal_guest arm-primary
  wait_for_guest_marker armed-primary 30
  cut="$(set_primary_link up)"
  printf '%s\n' "$cut" >"$ARTIFACT_DIR/primary-link-cut-unix-seconds.txt"
  wait_for_guest_marker primary.receipt.json 25
  receipt="$(guest_receipt primary.receipt.json)"
  receipt="$(jq --argjson link_changed "$cut" \
    '. + {host_link_change_unix_seconds: $link_changed}' <<<"$receipt")"
  jq -e \
    --argjson deadline "$RECOVERY_DEADLINE_MS" \
    --arg interface "$TARGET_PRIMARY_IFACE" \
    --arg gateway "$TARGET_PRIMARY_GATEWAY" \
    --arg source "$TARGET_PRIMARY_ADDRESS" \
    '.recovery_milliseconds <= $deadline
      and .route_usable_monotonic_milliseconds > 0
      and .recovered_monotonic_milliseconds
        >= .route_usable_monotonic_milliseconds
      and .payload_successes_after > .payload_successes_before
      and .wireguard_payload_successes_after
        > .wireguard_payload_successes_before
      and (.wireguard_endpoint_route | length) == 1
      and .wireguard_endpoint_route[0].dev == $interface
      and .wireguard_endpoint_route[0].gateway == $gateway
      and .wireguard_endpoint_route[0].prefsrc == $source
      and .rebind_receipts_after == (.rebind_receipts_before + 1)' \
    <<<"$receipt" >/dev/null
  printf '%s\n' "$receipt" >"$ARTIFACT_DIR/primary-receipt.json"
  jq -e . "$ARTIFACT_DIR/primary-receipt.json" >/dev/null
  assert_peer_recovered_from_source "$cut" "$PRIMARY_ADDRESS" primary \
    | tee "$ARTIFACT_DIR/primary-peer-recovery.txt"
  peer_command wireguard-audit >"$ARTIFACT_DIR/wireguard-responder-audit.txt"
}

counter_value() {
  local key="$1"
  parse_key_value "$key"
}

run_dns_case() {
  local name="$1"
  local counter="$2"
  local before after
  before="$(peer_command counters)"
  signal_guest "dns-$name.go"
  wait_for_guest_marker "dns-$name.receipt" 30
  after="$(peer_command counters)"
  (( $(counter_value "$counter" <<<"$after") > $(counter_value "$counter" <<<"$before") )) \
    || fail "$name did not create a real $counter resolver flow through the exit"
  {
    printf 'case=%s\n' "$name"
    printf 'before_%s=%s\n' "$counter" "$(counter_value "$counter" <<<"$before")"
    printf 'after_%s=%s\n' "$counter" "$(counter_value "$counter" <<<"$after")"
  } >>"$ARTIFACT_DIR/dns-matrix.txt"
}

run_dns_matrix_and_direct_restore() {
  run_dns_case automatic cloudflare
  run_dns_case cloudflare cloudflare
  run_dns_case quad9 quad9
  run_dns_case custom cloudflare
  run_dns_case through-exit fixture_dns

  signal_guest select-direct
  wait_for_guest_marker direct.receipt.json 30
  wait_for_guest_marker done 10
  guest_receipt direct.receipt.json >"$ARTIFACT_DIR/direct-receipt.json"
  jq -e . "$ARTIFACT_DIR/direct-receipt.json" >/dev/null
  jq -e '
    .wireguard_interface_removed == true
    and .wireguard_endpoint_route_removed == true
    and .wireguard_policy_rule_removed == true
    and .wireguard_policy_table_empty == true
    and .verified_https == true
  ' "$ARTIFACT_DIR/direct-receipt.json" >/dev/null
  wait "$LINUX_RUN_PID"
  LINUX_RUN_PID=""
}

run_cleanup_fault_regression() {
  run_guest_primary cleanup-fault \
    "NVPN_UNDERLAY_PEER_NPUB=$PEER_NPUB" \
    "NVPN_UNDERLAY_PEER_ENDPOINT=$PEER_ENDPOINT" \
    "NVPN_UNDERLAY_PEER_TUNNEL_IP=$PEER_TUNNEL_IP" \
    "NVPN_UNDERLAY_LISTEN_PORT=$TARGET_LISTEN_PORT" \
    "NVPN_UNDERLAY_WG_PEER_PUBLIC_KEY=$WG_SERVER_PUBLIC_KEY" \
    "NVPN_UNDERLAY_WG_ENDPOINT=$WG_ENDPOINT" \
    "NVPN_UNDERLAY_WG_CLIENT_ADDRESS=$WG_CLIENT_ADDRESS" \
    >"$ARTIFACT_DIR/cleanup-fault.log"
  run_primary sudo -n cat "$GUEST_STATE_DIR/cleanup-fault.receipt.json" \
    >"$ARTIFACT_DIR/cleanup-fault-receipt.json"
  jq -e '
      .xtables_retries_exhausted == true
      and .normal_stop_failed == true
      and .physical_network_restored_before_repair == true
      and .repair_transitioned_to_disconnected == true
    ' "$ARTIFACT_DIR/cleanup-fault-receipt.json" >/dev/null
}

capture_remote_state() {
  local captured=0
  mkdir -p "$ARTIFACT_DIR/guest-state" "$ARTIFACT_DIR/peer-state"
  if [[ -n "$SECONDARY_PROXY" ]] \
    && run_primary sudo -n test -d "$GUEST_STATE_DIR" >/dev/null 2>&1
  then
    primary_ssh_command
    "${LINUX_PRIMARY_SSH[@]}" \
      "sudo -n tar --ignore-failed-read -C '$GUEST_STATE_DIR' -cf - \
        identity.json daemon.state.json daemon.stderr.log daemon.stdout.log \
        payload.log platform-network-monitor-probe.log signed-rosters.json \
        secondary-underlay-ready.json secondary.nm-uuid \
        secondary.receipt.json primary.receipt.json direct.receipt.json" \
      | tar -C "$ARTIFACT_DIR/guest-state" -xf -
    captured=1
  fi
  if [[ "$PEER_INITIALIZED" == "1" ]] \
    && ssh -o BatchMode=yes "$HYPERVISOR_SSH" \
      "sudo -n test -d '$PEER_STATE_DIR'" >/dev/null 2>&1
  then
    ssh -o BatchMode=yes "$HYPERVISOR_SSH" \
      "sudo -n tar --ignore-failed-read -C '$PEER_STATE_DIR' -cf - \
        daemon.state.json daemon.stderr.log daemon.stdout.log signed-rosters.json \
        dns.log dnsmasq.log fips-underlay.pcap.txt wireguard-underlay.pcap.txt \
        peer-payload.log tcpdump.log wg-tcpdump.log" \
      | tar -C "$ARTIFACT_DIR/peer-state" -xf -
    captured=1
  fi
  find "$ARTIFACT_DIR/guest-state" "$ARTIFACT_DIR/peer-state" \
    -type f \( -iname '*secret*' -o -name 'config.toml' \) -delete
  [[ "$captured" == "1" ]] || return 0
  echo "REMOTE_RUNTIME_EVIDENCE_CAPTURED" \
    >"$ARTIFACT_DIR/runtime-evidence-capture.txt"
}

audit_guest_cleanup() {
  run_primary sudo -n bash -s -- \
    "$GUEST_BINARY" "$GUEST_STATE_DIR" "$TARGET_TUN_IFACE" \
    "$PRIMARY_MAC" "$SECONDARY_MAC" "$PROBE_URL" <<'SH'
set -euo pipefail
binary="$1"
state="$2"
tun="$3"
primary_mac="${4,,}"
secondary_mac="${5,,}"
url="$6"
interface_for_mac() {
  local wanted="$1"
  local path
  for path in /sys/class/net/*/address; do
    [[ "$(<"$path")" == "$wanted" ]] && basename "$(dirname "$path")"
  done
  return 0
}
primary="$(interface_for_mac "$primary_mac")"
secondary="$(interface_for_mac "$secondary_mac")"
profile_uuid="$(cat "$state/secondary.nm-uuid" 2>/dev/null || true)"
profile_name="$(cat "$state/secondary.nm-name" 2>/dev/null || true)"
cleanup_state() {
  rm -rf "$state"
}
trap cleanup_state EXIT
[[ -n "$primary" ]] || {
  echo "Linux guest cleanup audit failed: original physical interface is missing" >&2
  exit 1
}
[[ -z "$secondary" ]] || {
  echo "Linux guest cleanup audit failed: transient physical interface remains" >&2
  exit 1
}
"$binary" stop --config "$state/config.toml" --timeout-secs 5 --force >/dev/null
! pgrep -a -x nvpn 2>/dev/null | grep -Fq -- "--config $state/config.toml" \
  || { echo "Linux guest cleanup audit failed: nvpn process remains" >&2; exit 1; }
! ip link show dev "$tun" >/dev/null 2>&1 \
  || { echo "Linux guest cleanup audit failed: nvpn tunnel remains" >&2; exit 1; }
! resolvectl dns "$tun" 2>/dev/null | grep -Fq 127.0.0.1 \
  || { echo "Linux guest cleanup audit failed: nvpn DNS remains" >&2; exit 1; }
if [[ -n "$profile_uuid" ]]; then
  ! nmcli -t -f UUID connection show | grep -Fxq "$profile_uuid" \
    || {
      echo "Linux guest cleanup audit failed: transient NetworkManager profile remains" >&2
      exit 1
    }
fi
if [[ -n "$profile_name" ]]; then
  ! nmcli -t -f NAME connection show | grep -Fxq "$profile_name" \
    || {
      echo "Linux guest cleanup audit failed: transient NetworkManager profile name remains" >&2
      exit 1
    }
fi
deadline=$((SECONDS + 15))
while ((SECONDS < deadline)); do
  [[ "$(ip -j -4 route get 1.1.1.1 | jq -r '.[0].dev')" == "$primary" ]] && break
  sleep 0.1
done
[[ "$(ip -j -4 route get 1.1.1.1 | jq -r '.[0].dev')" == "$primary" ]] \
  || { echo "Linux guest cleanup audit failed: native default route was not restored" >&2; exit 1; }
host="${url#*://}"
host="${host%%/*}"
getent ahostsv4 "${host%%:*}" >/dev/null \
  || { echo "Linux guest cleanup audit failed: native DNS was not restored" >&2; exit 1; }
curl -4 --fail --silent --show-error --max-time 8 --output /dev/null "$url" \
  || { echo "Linux guest cleanup audit failed: native HTTPS was not restored" >&2; exit 1; }
[[ ! -e "$state/emergency-repair-invoked" ]] \
  || { echo "Linux guest cleanup audit failed: emergency repair was invoked" >&2; exit 1; }
rm -rf "$state"
[[ ! -e "$state" ]]
trap - EXIT
echo "LINUX_GUEST_CLEANUP_AUDIT_OK"
SH
}

audit_hypervisor_cleanup() {
  ssh -o BatchMode=yes "$HYPERVISOR_SSH" bash -s -- \
    "$VM_NAME" "$NETWORK_NAME" "$PRIMARY_IFACE" "$PRIMARY_MAC" \
    "$PEER_TUN_IFACE" "$PEER_STATE_DIR" "$COUNTER_CHAIN" \
    "$PEER_NETNS" "$PEER_HOST_VETH" "$PEER_ENDPOINT_HOST" \
    "$PEER_NAMESPACE_PREFIX" "$PEER_FORWARD_CHAIN" "$PEER_NAT_CHAIN" <<'SH'
set -euo pipefail
vm="$1"
network="$2"
primary_iface="$3"
primary_mac="$4"
peer_tun="$5"
peer_state="$6"
counter_chain="$7"
peer_netns="$8"
peer_host_veth="$9"
peer_address="${10}"
peer_prefix="${11}"
forward_chain="${12}"
nat_chain="${13}"
fail() {
  echo "Linux hypervisor cleanup audit failed: $*" >&2
  exit 1
}
rows="$(virsh domiflist "$vm" | awk '$2 == "network" { print $1 "|" $5 }')"
[[ "$(grep -c . <<<"$rows" || true)" == "1" ]] \
  || fail "VM does not have exactly its original NIC"
[[ "$rows" == "$primary_iface|$primary_mac" ]] \
  || fail "VM NIC identity differs from the original"
[[ "$(virsh domif-getlink "$vm" "$primary_iface" | awk '{ print $NF }')" == "up" ]] \
  || fail "VM primary link was not restored"
! virsh net-info "$network" >/dev/null 2>&1 \
  || fail "transient libvirt network remains"
! ip link show dev "$peer_tun" >/dev/null 2>&1 \
  || fail "peer tunnel remains"
! sudo -n test -e "$peer_state" \
  || fail "peer state directory remains"
! sudo -n iptables -t mangle -S "$counter_chain" >/dev/null 2>&1 \
  || fail "peer DNS counter chain remains"
! sudo -n ip netns list | awk '{ print $1 }' | grep -Fxq "$peer_netns" \
  || fail "peer namespace remains"
! ip link show dev "$peer_host_veth" >/dev/null 2>&1 \
  || fail "peer namespace veth remains"
! ip -4 route show exact "$peer_address/$peer_prefix" | grep -q . \
  || fail "peer namespace route remains"
! sudo -n iptables -S "$forward_chain" >/dev/null 2>&1 \
  || fail "peer forwarding chain remains"
! sudo -n iptables -t nat -S "$nat_chain" >/dev/null 2>&1 \
  || fail "peer NAT chain remains"
! pgrep -a -x nvpn 2>/dev/null | grep -Fq -- "--config $peer_state/config.toml" \
  || fail "peer process remains"
echo "LINUX_HYPERVISOR_CLEANUP_AUDIT_OK"
SH
}

cleanup() {
  local status="$?"
  local cleanup_failed=0
  trap - EXIT INT TERM
  set +e
  if [[ -n "$PRIMARY_IFACE" ]]; then
    ssh -o BatchMode=yes "$HYPERVISOR_SSH" \
      "virsh domif-setlink '$VM_NAME' '$PRIMARY_IFACE' up" >/dev/null 2>&1 \
      || cleanup_failed=1
  fi
  if [[ "$NIC_ATTACHED" == "1" ]]; then
    wait_for_primary_guest || cleanup_failed=1
  fi
  if [[ -n "$GUEST_BINARY_COPY_TMP" ]]; then
    run_primary "rm -f '$GUEST_BINARY_COPY_TMP'" >/dev/null 2>&1 || cleanup_failed=1
  fi
  capture_remote_state || cleanup_failed=1
  if [[ "$NIC_ATTACHED" == "1" ]]; then
    run_guest_primary cleanup >/dev/null 2>&1 || cleanup_failed=1
  fi
  if [[ -n "$LINUX_RUN_PID" ]]; then
    kill "$LINUX_RUN_PID" >/dev/null 2>&1 || true
    wait "$LINUX_RUN_PID" >/dev/null 2>&1 || true
  fi
  if [[ "$PEER_INITIALIZED" == "1" ]]; then
    peer_command cleanup >/dev/null 2>&1 || cleanup_failed=1
  fi
  if [[ "$PEER_NAMESPACE_ATTEMPTED" == "1" ]]; then
    peer_command namespace-cleanup >/dev/null 2>&1 || cleanup_failed=1
    peer_command namespace-audit >"$ARTIFACT_DIR/peer-namespace-cleanup-audit.txt" 2>&1 \
      || cleanup_failed=1
  fi
  if [[ "$NIC_ATTACHED" == "1" && -n "$SECONDARY_MAC" ]]; then
    ssh -o BatchMode=yes "$HYPERVISOR_SSH" \
      "virsh detach-interface --domain '$VM_NAME' --type network --mac '$SECONDARY_MAC' --live" \
      >/dev/null 2>&1 || cleanup_failed=1
  fi
  if [[ "$NETWORK_CREATED" == "1" ]]; then
    ssh -o BatchMode=yes "$HYPERVISOR_SSH" \
      "virsh net-destroy '$NETWORK_NAME'" >/dev/null 2>&1 || cleanup_failed=1
  fi
  if [[ "$NIC_ATTACHED" == "1" ]]; then
    wait_for_primary_guest || cleanup_failed=1
    audit_guest_cleanup >"$ARTIFACT_DIR/guest-cleanup-audit.txt" 2>&1 \
      || cleanup_failed=1
    audit_hypervisor_cleanup >"$ARTIFACT_DIR/hypervisor-cleanup-audit.txt" 2>&1 \
      || cleanup_failed=1
  fi
  if [[ "$cleanup_failed" == "1" ]]; then
    echo "Linux underlay cleanup audit failed; inspect $ARTIFACT_DIR" >&2
    status=1
  fi
  exit "$status"
}
trap cleanup EXIT INT TERM

resolve_expected_fips_revision
sync_and_build_candidates
capture_version_receipts
discover_primary_interface
attach_secondary_network
wait_for_secondary_adapter
guest_initialize
initialize_and_start_peer
start_linux_runner
run_underlay_switches
run_dns_matrix_and_direct_restore
run_cleanup_fault_regression

echo "LINUX_UNDERLAY_NETWORK_CHANGE_E2E_OK"
echo "artifacts=$ARTIFACT_DIR"
