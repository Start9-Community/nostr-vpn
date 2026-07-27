#!/usr/bin/env bash
# Source contract for the production-path desktop underlay gates. The actual
# packet/DNS assertions run on the real VMs; this keeps publication from
# silently replacing them with a mock, a link simulation, or an optional lane.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE_GATE="$ROOT/scripts/release-gate.sh"
LOCAL_RELEASE="$ROOT/scripts/local-release.mjs"
WINDOWS_HOST_ENTRY="$ROOT/scripts/windows-vm-desktop-underlay-change-e2e.sh"
WINDOWS_HOST_LIB="$ROOT/scripts/windows-vm-desktop-underlay-change-e2e.lib.sh"
WINDOWS_GUEST_ENTRY="$ROOT/scripts/desktop-windows-underlay-change-e2e.ps1"
WINDOWS_GUEST_LIB="$ROOT/scripts/desktop-windows-underlay-change-e2e.lib.ps1"
LINUX_HOST_ENTRY="$ROOT/scripts/linux-vm-desktop-underlay-change-e2e.sh"
LINUX_HOST_LIB="$ROOT/scripts/linux-vm-desktop-underlay-change-e2e.lib.sh"
LINUX_GUEST="$ROOT/scripts/desktop-linux-underlay-change-e2e.sh"
PEER="$ROOT/scripts/desktop-linux-underlay-peer-e2e.sh"
LISTENER_AUDIT="$ROOT/scripts/lib-desktop-linux-listener-audit.sh"
MACOS_WIREGUARD="$ROOT/scripts/macos-vm-desktop-wireguard-exit-e2e.sh"
MACOS_NETWORK_GUEST="$ROOT/scripts/e2e-macos-release-network.sh"
MACOS_APP="$ROOT/scripts/macos-vm-desktop-app-launch-smoke.sh"
MACOS_IDLE="$ROOT/scripts/macos-vm-desktop-daemon-idle-e2e.sh"
LINUX_SYNC="$ROOT/scripts/ubuntu-vm-git-sync.sh"
WINDOWS_SYNC="$ROOT/scripts/windows-vm-git-sync.sh"
COMBINED_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nvpn-underlay-contract.XXXXXX")"
trap 'rm -rf "$COMBINED_DIR"' EXIT
WINDOWS_HOST="$COMBINED_DIR/windows-host.sh"
WINDOWS_GUEST="$COMBINED_DIR/windows-guest.ps1"
LINUX_HOST="$COMBINED_DIR/linux-host.sh"
cat "$WINDOWS_HOST_ENTRY" "$WINDOWS_HOST_LIB" >"$WINDOWS_HOST"
cat "$WINDOWS_GUEST_ENTRY" "$WINDOWS_GUEST_LIB" >"$WINDOWS_GUEST"
cat "$LINUX_HOST_ENTRY" "$LINUX_HOST_LIB" >"$LINUX_HOST"

fail() {
  echo "desktop underlay source contract failed: $*" >&2
  exit 1
}

require_tokens() {
  local file="$1" label="$2" token
  shift 2
  for token in "$@"; do
    grep -Fq "$token" "$file" \
      || fail "$(basename "$file") lacks $label: $token"
  done
}

reject_listener_fixture() {
  local label="$1"
  shift
  if nvpn_require_single_udp_listener "$@" >/dev/null 2>&1; then
    fail "$label passed the listener audit"
  fi
}

[[ -f "$LISTENER_AUDIT" ]] || fail "Linux UDP listener audit helper is missing"
source "$LISTENER_AUDIT"

for script in \
  "$WINDOWS_HOST_ENTRY" "$LINUX_HOST_ENTRY" "$LINUX_GUEST" "$PEER" \
  "$MACOS_WIREGUARD" "$MACOS_NETWORK_GUEST" "$MACOS_APP" "$MACOS_IDLE"
do
  [[ -x "$script" ]] || fail "$(basename "$script") is missing or not executable"
done
for helper in "$WINDOWS_HOST_LIB" "$WINDOWS_GUEST_LIB" "$LINUX_HOST_LIB"; do
  [[ -f "$helper" ]] || fail "$(basename "$helper") is missing"
done
[[ -f "$WINDOWS_GUEST_ENTRY" ]] || fail "Windows guest runner is missing"
require_tokens "$WINDOWS_HOST_ENTRY" "helper module" \
  'windows-vm-desktop-underlay-change-e2e.lib.sh'
require_tokens "$WINDOWS_GUEST_ENTRY" "helper module" \
  'desktop-windows-underlay-change-e2e.lib.ps1'
require_tokens "$LINUX_HOST_ENTRY" "helper module" \
  'linux-vm-desktop-underlay-change-e2e.lib.sh'
require_tokens "$LINUX_SYNC" "isolated exact-source sync support" \
  'NVPN_UBUNTU_LOCAL_REPO_PATH' \
  'NVPN_UBUNTU_SSH_JUMP' \
  'NVPN_UBUNTU_SSH_PROXY_COMMAND' \
  'NVPN_UBUNTU_GUEST_REPO_NAME' \
  'NVPN_UBUNTU_REPO_LABEL'
require_tokens "$WINDOWS_SYNC" "isolated exact-FIPS sync support" \
  'NVPN_WINDOWS_GUEST_FIPS_REPO_PATH' \
  'NVPN_WINDOWS_FIPS_GIT_BARE_PATH'

listener_fixture_device="nvln0"
listener_fixture_port="45820"
listener_fixture_pid="4242"
listener_fixture_row='UNCONN 0 0 0.0.0.0%nvln0:45820 0.0.0.0:* users:(("nvpn",pid=4242,fd=11))'
validated_listener="$(
  nvpn_require_single_udp_listener \
    "$listener_fixture_row" \
    "$listener_fixture_device" \
    "$listener_fixture_port" \
    "$listener_fixture_pid"
)" || fail "valid exact-device daemon listener fixture was rejected"
[[ "$validated_listener" == "$listener_fixture_row" ]] \
  || fail "listener helper did not return the exact validated row"
reuseport_compatible_rows="$listener_fixture_row"$'\n''UNCONN 0 0 0.0.0.0%nvln0:45820 0.0.0.0:* users:(("nvpn",pid=4242,fd=12))'
reject_listener_fixture "duplicate SO_REUSEPORT-compatible rows" \
  "$reuseport_compatible_rows" "$listener_fixture_device" \
  "$listener_fixture_port" "$listener_fixture_pid"
reject_listener_fixture "listener on the wrong device" \
  "$listener_fixture_row" wrong0 "$listener_fixture_port" "$listener_fixture_pid"
reject_listener_fixture "listener owned by a PID prefix" \
  "$listener_fixture_row" "$listener_fixture_device" "$listener_fixture_port" 424
shared_listener_row='UNCONN 0 0 0.0.0.0%nvln0:45820 0.0.0.0:* users:(("other",pid=9999,fd=3),("nvpn",pid=4242,fd=11))'
reject_listener_fixture "listener row shared with a foreign PID" \
  "$shared_listener_row" "$listener_fixture_device" \
  "$listener_fixture_port" "$listener_fixture_pid"
require_tokens "$PEER" "listener ownership integration" \
  'lib-desktop-linux-listener-audit.sh' \
  'nvpn_require_single_udp_listener' \
  '"$STATE_DIR/peer-process.pid"'

for host_gate in "$WINDOWS_HOST" "$LINUX_HOST"; do
  require_tokens "$host_gate" "real topology/cleanup evidence" \
    'virsh net-create' \
    'virsh attach-interface' \
    'virsh detach-interface' \
    'virsh domif-setlink' \
    'set_primary_link down' \
    'set_primary_link up' \
    'assert_peer_recovered_from_source' \
    'peer_command wireguard-audit' \
    'wireguard-underlay.pcap.txt' \
    'wireguard_endpoint_route' \
    'audit_hypervisor_cleanup' \
    'trap cleanup EXIT INT TERM'
  grep -Fq 'RECOVERY_DEADLINE_MS="${NVPN_DESKTOP_UNDERLAY_RECOVERY_DEADLINE_MS:-4000}"' \
    "$host_gate" \
    || fail "$(basename "$host_gate") does not enforce the four-second bound"
  grep -Fq "current_tree" "$host_gate" \
    || fail "$(basename "$host_gate") does not snapshot the exact candidate tree"
  grep -Fq 'tree differs from the release-gate tree' "$host_gate" \
    || fail "$(basename "$host_gate") does not reject a mismatched candidate tree"
  if grep -Eq '\b(networksetup|scutil|route -n add|ifconfig en[0-9])\b' "$host_gate"; then
    fail "$(basename "$host_gate") can mutate the controlling Mac network"
  fi
  grep -Fq 'date +%s.%N; virsh domif-setlink' "$host_gate" \
    || fail "$(basename "$host_gate") starts its four-second clock after virsh returns"
done

for guest_gate in "$WINDOWS_GUEST" "$LINUX_GUEST"; do
  for dns_case in automatic cloudflare quad9 custom through-exit; do
    grep -Fq "$dns_case" "$guest_gate" \
      || fail "$(basename "$guest_gate") omits the $dns_case DNS setting"
  done
  require_tokens "$guest_gate" "production recovery evidence" \
    'daemon' \
    'underlay carrier(s) rebound' \
    'exit-node-leak-protection' \
    'wireguard-exit-config-file' \
    'wireguard-exit-enabled' \
    'wireguard_payload_successes_after' \
    'wireguard_endpoint_route' \
    'wireguard_interface_removed' \
    'wireguard_endpoint_route_removed' \
    'select-direct' \
    'verified_https'
done
grep -Fq '(Get-RebindReceiptCount) -eq ($rebindBefore + 1)' "$WINDOWS_GUEST" \
  || fail "Windows guest does not require exactly one rebind per physical switch"
grep -Fq '$(rebind_count) == rebind_before + 1' "$LINUX_GUEST" \
  || fail "Linux guest does not require exactly one rebind per physical switch"
for host_gate in "$WINDOWS_HOST" "$LINUX_HOST"; do
  [[ "$(grep -Fc '.rebind_receipts_after == (.rebind_receipts_before + 1)' "$host_gate")" -eq 2 ]] \
    || fail "$(basename "$host_gate") does not independently require one rebind for both switches"
done

require_tokens "$WINDOWS_GUEST" "PID-bound continuous payload" \
  'Get-DaemonPid' '[Net.NetworkInformation.Ping]::new()'
require_tokens "$LINUX_GUEST" "PID-bound continuous payload" \
  'daemon_pid()' 'ping -D -n -i 0.1'
require_tokens "$PEER" "reverse payload and physical source capture" \
  'ping -D -n -i 0.1' 'tcpdump -n -tt -l -i any'
require_tokens "$PEER" "WireGuard/DNS responder evidence" \
  'ip link add dev "$WG_IFACE" type wireguard' \
  'allowed-ips "$WG_CLIENT_ADDRESS"' \
  '"udp port $WG_LISTEN_PORT"' \
  'wireguard-underlay.pcap.txt' \
  'wg show "$WG_IFACE" latest-handshakes' \
  'wg show "$WG_IFACE" transfer' \
  'iptables -t mangle -I PREROUTING' \
  'fixture_dns='
require_tokens "$WINDOWS_HOST" "provenance/diagnostic evidence" \
  'manifest_path) -replace' 'collect_failure_artifacts'
require_tokens "$WINDOWS_GUEST" "failed-readiness diagnostics" \
  'last-condition-error.txt'
require_tokens "$WINDOWS_HOST" "isolated peer namespace lifecycle" \
  'peer_command namespace-setup' \
  'ip netns exec "$PEER_NETNS"' \
  'peer_command listener-audit' \
  'peer_command namespace-cleanup'
require_tokens "$WINDOWS_GUEST" "independent cleanup evidence" \
  '"Watchdog"' \
  'WatchdogTimeoutSeconds' \
  'Invoke-IsolatedNetworkCleanup' \
  "WireGuardTunnel$" \
  '"WireGuardProbe"' \
  'Test-WireGuardHandshake' \
  'Assert-WireGuardEndpointRoute'
for evidence in \
  '.wireguard_endpoint_route.interface_index == $interface_index' \
  '.wireguard_endpoint_route.next_hop == $gateway' \
  '.wireguard_endpoint_route.source_address == $source'
do
  [[ "$(grep -Fc "$evidence" "$WINDOWS_HOST")" -eq 2 ]] \
    || fail "Windows host does not verify both complete endpoint-route tuples: $evidence"
done
require_tokens "$WINDOWS_GUEST" "stable monotonic recovery receipt" \
  'route_usable_unix_milliseconds' \
  'route_usable_monotonic_milliseconds' \
  'source_address = [string]$routeDecision.source_address' \
  'if ($elapsed -gt $RecoveryDeadlineMilliseconds)'
python3 - "$WINDOWS_GUEST" <<'PY'
import pathlib
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
observe = text[text.index("function Observe-Recovery {"):text.index("function Run-DnsSettingCase {")]
checkpoint = observe.index("Assert-SessionContinuity")
recovered = observe.index("$recoveredMonotonicMilliseconds = [Environment]::TickCount64")
if recovered <= checkpoint:
    raise SystemExit("Windows recovery clock stops before session/DNS/HTTPS/route assertions")
PY
[[ "$(grep -Fc 'assert_peer_recovered_from_source "$cut"' "$WINDOWS_HOST")" -eq 2 ]] \
  || fail "Windows peer evidence is not clocked from each hypervisor link cut"
grep -Fq 'wait_for_guest_marker ready 35' "$WINDOWS_HOST" \
  || fail "Windows runtime readiness still has an unreasonable host-side wait"
if grep -Fq '90000' "$WINDOWS_GUEST" \
  || grep -Fq '120000' "$WINDOWS_GUEST" \
  || grep -Fq 'wait_for_guest_marker ready 120' "$WINDOWS_HOST"
then
  fail "Windows runtime readiness retains a 90/120-second fallback window"
fi
require_tokens "$WINDOWS_HOST" "exact provenance/parallel-build contract" \
  'the exact FIPS release-gate checkout must be committed and clean' \
  'checkout --detach' \
  'target-version.txt' \
  'peer-version.txt' \
  'wait "$windows_build_pid"' \
  'wait "$peer_build_pid"'

require_tokens "$RELEASE_GATE" "real auto-discoverable underlay lane" \
  'windows-vm-desktop-underlay-change-e2e.sh' \
  'linux-vm-desktop-underlay-change-e2e.sh' \
  'NVPN_RELEASE_GATE_WINDOWS_UNDERLAY_NETWORK_CHANGE_E2E:-auto' \
  'NVPN_RELEASE_GATE_LINUX_UNDERLAY_NETWORK_CHANGE_E2E:-auto'
require_tokens "$LOCAL_RELEASE" "mandatory publication lane" \
  "NVPN_RELEASE_GATE_WINDOWS_UNDERLAY_NETWORK_CHANGE_E2E: '1'" \
  "NVPN_RELEASE_GATE_LINUX_UNDERLAY_NETWORK_CHANGE_E2E: '1'" \
  "NVPN_RELEASE_GATE_MACOS_WG_EXIT_E2E: '1'" \
  "NVPN_RELEASE_GATE_MACOS_GUI_SMOKE: '1'" \
  "NVPN_RELEASE_GATE_MACOS_DAEMON_IDLE_CPU: '1'"
require_tokens "$RELEASE_GATE" "isolated macOS network/service lanes" \
  'macos-vm-desktop-wireguard-exit-e2e.sh' \
  'macos-vm-desktop-app-launch-smoke.sh' \
  'macos-vm-desktop-daemon-idle-e2e.sh'
require_tokens "$MACOS_WIREGUARD" "real imported macOS network gate" \
  'lib-macos-vm-imported-release.sh' \
  'lib-mobile-wireguard-fixture.sh' \
  'macos_vm_prepare_or_verify_imported_release' \
  'NVPN_MACOS_VM_IMPORT_ONLY=1' \
  'NVPN_E2E_BINARY=' \
  './scripts/e2e-macos-release-network.sh' \
  'mobile_wg_fixture_wg_bytes' \
  'mobile_wg_fixture_forward_packets' \
  'mobile_wg_fixture_dns_count' \
  'mobile_wg_fixture_doh_count' \
  'mobile_wg_fixture_cleanup'
for dns_case in \
  automatic-profile cloudflare-doh quad9-doh custom-doh through-exit
do
  grep -Fq "$dns_case" "$MACOS_WIREGUARD" \
    || fail "macOS host gate omits the $dns_case real resolver case"
done
require_tokens "$MACOS_NETWORK_GUEST" "production macOS transition evidence" \
  'NVPN_MACOS_VM_IMPORT_ONLY' \
  'codesign --verify --strict' \
  'wireguard-exit-config-file' \
  'wireguard-exit-enabled' \
  'exit-dns-mode' \
  'exit-dns-doh-provider' \
  'exit-dns-custom-doh-url' \
  'exit-dns-custom-doh-bootstrap-ips' \
  'exit-dns-through-exit-servers' \
  '/etc/resolver/nvpn-secure-dns' \
  'scutil --dns' \
  'networksetup -setnetworkserviceenabled' \
  'Ethernet' \
  'Roaming Underlay' \
  'NVPN_MACOS_UNDERLAY_RECOVERY_DEADLINE_MS:-4000' \
  'FIPS underlay carrier(s) rebound' \
  'runtime_wireguard_state_is false true' \
  'runtime_wireguard_state_is false false' \
  'select-direct' \
  'direct_source_ip' \
  'endpoint_route_interface' \
  'MACOS_RELEASE_NETWORK_DIRECT_OK'
for forbidden in \
  'cargo build' \
  'xcodebuild' \
  'macos-build' \
  'codesign --force' \
  '/usr/bin/swift' \
  'swift -e' \
  'swiftc'
do
  if grep -Fq "$forbidden" "$MACOS_NETWORK_GUEST"; then
    fail "macOS guest network path can build/sign in the VM: $forbidden"
  fi
done
if grep -Fq './scripts/e2e-wireguard-exit-host.sh' "$MACOS_WIREGUARD"; then
  fail "macOS release network gate still uses the scoped-host self-test"
fi
for forbidden_host_path in \
  './scripts/e2e-wireguard-exit-host.sh' \
  './scripts/macos-app-launch-smoke.sh' \
  './scripts/e2e-macos-service.sh'
do
  if grep -Fq "$forbidden_host_path" "$RELEASE_GATE"; then
    fail "release gate can mutate its macOS host: $forbidden_host_path"
  fi
done

python3 - "$RELEASE_GATE" <<'PY'
import pathlib
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
linux_start = text.index("run_linux_exclusive_desktop_gates() {")
windows_start = text.index("run_windows_exclusive_desktop_gates() {")
macos_start = text.index("run_macos_exclusive_desktop_gates() {")
serial_end = text.index("\nrelease_gate_perf_output_dir() {", macos_start)
linux = text[linux_start:windows_start]
windows = text[windows_start:macos_start]
macos = text[macos_start:serial_end]
if "run_linux_platform_lane" in linux:
    raise SystemExit("exclusive Linux underlay tail still performs build/UI prep")
if "run_linux_underlay_network_change_gate" not in linux:
    raise SystemExit("exclusive Linux tail omits the underlay timing gate")
if "run_windows_platform_lane" in windows:
    raise SystemExit("exclusive Windows network tail still performs build/UI prep")
windows_order = [
    windows.index("run_windows_wireguard_exit_gate"),
    windows.index("run_windows_underlay_network_change_gate"),
]
if windows_order != sorted(windows_order):
    raise SystemExit("Windows WireGuard proof does not precede underlay timing")
if "run_macos_platform_lane" in macos:
    raise SystemExit("exclusive macOS network tail still performs build/UI prep")
if "run_wireguard_exit_platform_gates" not in macos:
    raise SystemExit("exclusive macOS network tail omits its WireGuard proof")

main_start = text.index("main() {")
main_end = text.rindex('\nmain "$@"')
main = text[main_start:main_end]
prep = [
    '"Windows platform"',
    '"macOS platform UI"',
    '"Linux platform UI"',
]
prep_positions = [main.index(item) for item in prep]
static_preflight = main.index("run_release_gate_static_preflight")
if any(position >= static_preflight for position in prep_positions):
    raise SystemExit("an isolated desktop prep lane starts after static preflight")

joins = [
    'release_gate_parallel_wait "$windows_lane"',
    'release_gate_parallel_wait "$linux_platform_lane"',
    'release_gate_parallel_wait "$macos_platform_lane"',
]
join_positions = [main.index(item) for item in joins]
order = [
    "run_desktop_app_launch_smokes",
    "run_linux_exclusive_desktop_gates",
    "run_windows_exclusive_desktop_gates",
    "run_macos_exclusive_desktop_gates",
    "run_mobile_qr_join_latency_gate",
    "run_public_fips_transit_gate",
    "run_docker_signal_gates",
    "run_docker_isolated_functional_gates",
    "run_docker_perf_gate",
    "./scripts/release-gate-host-pair-latency.sh",
    "./scripts/release-gate-host-pair-loaded-latency.sh",
    "run_macos_daemon_idle_cpu_gate",
    "run_mobile_idle_cpu_gates",
    "run_android_legacy_replacement_gate",
    "run_mobile_wireguard_exit_gates",
    "run_mobile_underlay_change_gates",
    "run_mobile_join_e2e_gate",
]
positions = [main.index(item) for item in order]
if max(join_positions) >= positions[0] or positions != sorted(positions):
    raise SystemExit("exclusive desktop/device/measurement tail is out of order")
if any(position >= positions[0] for position in join_positions):
    raise SystemExit("a desktop prep lane is not joined before exclusive network gates")
for mobile_contract in (
    "test-mobile-release-provenance-harness.sh",
    "test-mobile-release-artifact-reuse-harness.sh",
    "test-mobile-underlay-change-harness.sh",
):
    if mobile_contract not in text:
        raise SystemExit(f"current mobile release contract was dropped: {mobile_contract}")
for receipt in (
    "NVPN_MOBILE_ANDROID_RELEASE_RECEIPT",
    "NVPN_MOBILE_IOS_RELEASE_RECEIPT",
):
    if receipt not in main:
        raise SystemExit(f"mobile exact-artifact receipt setup was dropped: {receipt}")
for forbidden in (
    "./scripts/e2e-wireguard-exit-host.sh",
    "./scripts/macos-app-launch-smoke.sh",
    "./scripts/e2e-macos-service.sh",
):
    if forbidden in main:
        raise SystemExit(f"release main retains forbidden host/concurrent path: {forbidden}")
PY

grep -Fq 'src/nvpn-desktop-underlay/windows-peer' "$WINDOWS_HOST" \
  || fail "Windows and Linux peer builds are not resource-isolated"
grep -Fq 'src/nvpn-desktop-underlay/linux-peer' "$LINUX_HOST" \
  || fail "Windows and Linux peer builds are not resource-isolated"
grep -Fq 'NVPN_UBUNTU_SSH_HOST="$HYPERVISOR_SSH"' "$LINUX_HOST" \
  || fail "Linux peer sync can inherit the guest SSH target instead of the hypervisor"
if grep -Fq 'lock_args=()' "$LINUX_HOST"; then
  fail "Linux exact-FIPS builds can silently rewrite the candidate dependency graph"
fi
grep -Fq 'update --offline -p fips-core -p fips-endpoint -p fips-identity' "$LINUX_HOST" \
  || fail "Linux exact-FIPS builds do not update only the patched FIPS lock entries"
grep -Fq "checkout --detach '\$FIPS_SOURCE_REVISION'" "$LINUX_HOST" \
  || fail "Linux exact-FIPS build does not preserve the selected source revision"
for evidence in \
  'peer-build.log' \
  'target-linux-check.log' \
  'linux-build-abi.txt' \
  'linux-binary-sha256.txt' \
  'wait "$peer_build_pid"' \
  'wait "$target_check_pid"'
do
  grep -Fq "$evidence" "$LINUX_HOST" \
    || fail "Linux native build and target check/copy contract is missing: $evidence"
done
grep -Fq '[[ "$target_abi" == "$peer_abi" ]]' "$LINUX_HOST" \
  || fail "Linux binary copy does not require identical OS, architecture, and glibc"
grep -Fq '[[ "$source_sha" == "$target_sha" && "$source_sha" == "$peer_sha" ]]' "$LINUX_HOST" \
  || fail "Linux copied production binaries are not SHA-256 identical"
for evidence in \
  'peer_command namespace-setup' \
  'ip netns exec "$PEER_NETNS"' \
  'peer_command listener-audit' \
  'peer_command namespace-cleanup'
do
  grep -Fq "$evidence" "$LINUX_HOST" \
    || fail "Linux peer does not use the isolated production-binding namespace: $evidence"
done
for evidence in \
  'ip netns add "$PEER_NETNS"' \
  'ip link add "$PEER_HOST_VETH" type veth' \
  'iptables -t nat -I POSTROUTING 1 -j "$PEER_NAT_CHAIN"' \
  'iptables -I FORWARD 1 -j "$PEER_FORWARD_CHAIN"' \
  'MASQUERADE' \
  'listener-audit'
do
  grep -Fq "$evidence" "$PEER" \
    || fail "peer fixture lacks namespace routing/binding evidence: $evidence"
done
grep -Fq 'wait_for_guest_marker ready 35' "$LINUX_HOST" \
  || fail "Linux runtime readiness still has an unreasonable host-side wait"
grep -Fq 'for _ in $(seq 1 300)' "$PEER" \
  || fail "peer readiness is not bounded to thirty seconds"
if grep -Fq 'for _ in $(seq 1 900)' "$PEER" \
  || grep -Fq 'SECONDS + 90' "$LINUX_GUEST" \
  || grep -Fq 'wait_for_guest_marker ready 120' "$LINUX_HOST"
then
  fail "Linux runtime readiness retains a 90/120-second fallback window"
fi
grep -Fq 'initial_route=' "$LINUX_GUEST" \
  || fail "Linux initial readiness timeout does not report its last route condition"
grep -Fq 'tail -n 80 "$STATE_DIR/daemon.stderr.log"' "$LINUX_GUEST" \
  || fail "Linux initial readiness timeout does not report its daemon log"
grep -Fq '.status_source == "daemon"' "$PEER" \
  || fail "peer readiness does not parse daemon state semantically"
grep -Fq '.daemon.state.connected_peer_count >= 1' "$PEER" \
  || fail "peer readiness can pass without a real connected session"
grep -Fq 'jq -e . "$ARTIFACT_DIR/peer-ready.json"' "$LINUX_HOST" \
  || fail "Linux gate does not reject a contaminated peer status receipt"
for receipt in \
  peer-ready.json secondary-receipt.json primary-receipt.json direct-receipt.json
do
  grep -Fq "jq -e . \"\$ARTIFACT_DIR/$receipt\"" "$LINUX_HOST" \
    || fail "Linux gate does not validate JSON receipt: $receipt"
done
grep -Fq 'version --verbose' "$LINUX_HOST" \
  || fail "Linux gate does not capture immutable target/peer version receipts"
grep -Fq 'NVPN_UNDERLAY_EXPECTED_FIPS_REV' "$LINUX_GUEST" \
  || fail "Linux target runtime does not assert the expected FIPS revision"
grep -Fq 'NVPN_UNDERLAY_EXPECTED_FIPS_REV' "$PEER" \
  || fail "Linux peer runtime does not assert the expected FIPS revision"
for value in \
  NVPN_UNDERLAY_SECONDARY_ADDRESS \
  NVPN_UNDERLAY_SECONDARY_PREFIX \
  NVPN_UNDERLAY_SECONDARY_GATEWAY
do
  [[ "$(grep -Fc "\"$value=" "$LINUX_HOST")" -ge 2 ]] \
    || fail "Linux primary/secondary guest actions do not both receive $value"
done
grep -Fq '"$SECONDARY_ADDRESS" "$SECONDARY_GATEWAY"' "$LINUX_GUEST" \
  || fail "Linux run action does not require the initialized secondary values"
grep -Fq 'nmcli device set "$secondary_iface" managed no' "$LINUX_GUEST" \
  || fail "NetworkManager can erase the real secondary underlay during the gate"
if grep -Fq 'SECONDS + 120' "$LINUX_GUEST"; then
  fail "Linux guest retains an unbounded internal marker wait"
fi
grep -Fq "virsh domif-getlink \"\$vm\" \"\$primary_iface\" | awk '{ print \$NF }'" \
  "$LINUX_HOST" \
  || fail "Linux cleanup audit compares the unparsed virsh link row"
grep -Fq 'capture_remote_state' "$LINUX_HOST" \
  || fail "Linux failure cleanup does not preserve guest and peer evidence"
if grep -Fq "tar --ignore-failed-read -C '\$GUEST_STATE_DIR' -cf - ." "$LINUX_HOST" \
  || grep -Fq "tar --ignore-failed-read -C '\$PEER_STATE_DIR' -cf - ." "$LINUX_HOST"
then
  fail "Linux failure artifacts can copy secret sidecars or raw configs"
fi
grep -Fq -- "-iname '*secret*' -o -name 'config.toml'" "$LINUX_HOST" \
  || fail "Linux artifact collection lacks a defensive secret/config exclusion"
if grep -Eq 'Copy-Item.+StateDir|Get-ChildItem.+StateDir' "$WINDOWS_HOST"; then
  fail "Windows failure artifacts can copy the raw state directory"
fi
grep -Fq 'last_route=' "$LINUX_GUEST" \
  || fail "Linux recovery failure omits its last route condition"
grep -Fq 'physical_default_route_dev()' "$LINUX_GUEST" \
  || fail "Linux recovery clock does not wait for a usable OS underlay route"
grep -Fq 'route_usable_monotonic_milliseconds' "$LINUX_HOST" \
  || fail "Linux host does not enforce the guest monotonic recovery receipt"
grep -Fq 'route_usable_monotonic_milliseconds' "$LINUX_GUEST" \
  || fail "Linux guest recovery does not use its own monotonic clock"
grep -Fq '10#$nanoseconds / 1000000' "$LINUX_GUEST" \
  || fail "Linux guest Unix-millisecond evidence is not portable across date implementations"
if grep -Fq 'date +%s%3N' "$LINUX_GUEST"; then
  fail "Linux guest relies on unsupported date field-width semantics for milliseconds"
fi
final_status_line="$(grep -n '&& assert_same_daemon_ready "$expected_pid"' "$LINUX_GUEST" | cut -d: -f1)"
final_clock_line="$(grep -n 'now="$(monotonic_milliseconds)"' "$LINUX_GUEST" | tail -n 1 | cut -d: -f1)"
receipt_clock_line="$(grep -n 'recovered_monotonic="$now"' "$LINUX_GUEST" | cut -d: -f1)"
[[ -n "$final_status_line" && -n "$final_clock_line" && -n "$receipt_clock_line" ]] \
  || fail "Linux guest recovery receipt lacks final post-predicate monotonic evidence"
((final_status_line < final_clock_line && final_clock_line < receipt_clock_line)) \
  || fail "Linux guest samples its recovery receipt before the final success predicate"
grep -Fq 'if ((elapsed <= RECOVERY_DEADLINE_MS)); then' "$LINUX_GUEST" \
  || fail "Linux guest does not re-enforce the deadline after final success predicates"
[[ "$(grep -Fc 'assert_peer_recovered_from_source "$cut"' "$LINUX_HOST")" -eq 2 ]] \
  || fail "Linux peer evidence is not clocked from each hypervisor link cut"
for evidence in \
  '.wireguard_endpoint_route[0].dev == $interface' \
  '.wireguard_endpoint_route[0].gateway == $gateway' \
  '.wireguard_endpoint_route[0].prefsrc == $source'
do
  [[ "$(grep -Fc "$evidence" "$LINUX_HOST")" -eq 2 ]] \
    || fail "Linux host does not verify both complete endpoint-route tuples: $evidence"
done
for host_gate in "$WINDOWS_HOST" "$LINUX_HOST"; do
  if grep -Fq 'route_usable_unix_milliseconds / 1000' "$host_gate"; then
    fail "$(basename "$host_gate") compares guest and hypervisor wall clocks"
  fi
  grep -Fq 'expected_source_after_cut_seconds' "$host_gate" \
    || fail "$(basename "$host_gate") lacks same-clock expected-source timing"
  grep -Fq 'fips_expected_source_after_cut_seconds' "$host_gate" \
    || fail "$(basename "$host_gate") lacks physical FIPS source timing"
  grep -Fq 'wireguard_expected_source_after_cut_seconds' "$host_gate" \
    || fail "$(basename "$host_gate") lacks physical WireGuard source timing"
  grep -Fq 'reverse_payload_after_expected_source_seconds' "$host_gate" \
    || fail "$(basename "$host_gate") lacks same-clock reverse-payload timing"
  grep -Fq 'while :; do' "$host_gate" \
    || fail "$(basename "$host_gate") can skip already-recorded boundary evidence"
  grep -Fq 'at - cut > deadline' "$host_gate" \
    || fail "$(basename "$host_gate") does not keep reverse payload inside the total bound"
done
grep -Fq 'last_rebind_receipts=' "$LINUX_GUEST" \
  || fail "Linux recovery failure omits its rebind evidence"
grep -Fq '172.31.253.1' "$WINDOWS_HOST" \
  || fail "Windows transient network has no isolated subnet"
grep -Fq '172.31.254.1' "$LINUX_HOST" \
  || fail "Linux transient network has no isolated subnet"

python3 - "$WINDOWS_HOST" "$WINDOWS_GUEST" "$LINUX_HOST" "$LINUX_GUEST" "$PEER" <<'PY'
import pathlib
import re
import sys

private = re.compile(
    r"\b(?:vader|win11-dev|ubuntu-dev|macos-utm)\b"
    r"|192\.168\.122\.[0-9]+"
    r"|/(?:Users|home)/[A-Za-z0-9._-]+/"
)
for name in sys.argv[1:]:
    text = pathlib.Path(name).read_text(encoding="utf-8")
    if match := private.search(text):
        raise SystemExit(
            f"{pathlib.Path(name).name} embeds private infrastructure near offset {match.start()}"
        )
PY

echo "DESKTOP_UNDERLAY_NETWORK_CHANGE_SOURCE_CONTRACT_OK"
