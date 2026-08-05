#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
source "$ROOT_DIR/scripts/lib-release-gate-parallel.sh"
run_node_contracts() {
  node --test scripts/*.test.mjs
  python3 scripts/test_appstore_draft_metadata.py
}
run_contract_batch() {
  for contract in "$@"; do "$contract"; done
}
log_dir="$(mktemp -d "${TMPDIR:-/tmp}/nvpn-release-tooling-contracts.XXXXXX")"
trap 'release_gate_parallel_cancel_all; rm -rf "$log_dir"' EXIT
release_gate_parallel_init "$log_dir"
lanes=()
start_lane() {
  release_gate_parallel_start "$@"
  lanes+=("$RELEASE_GATE_PARALLEL_LAST_INDEX")
}
start_lane "Node release contracts" run_node_contracts
start_lane "release and Windows contracts" run_contract_batch \
  scripts/test-{publish-preflight,build-nvpn-linux-musl-docker-config,windows-installer-migration,windows-wireguard-exit-fixture,android-aab-derived-release,macos-vm-identity-guard}-harness.sh
start_lane "mobile contracts" run_contract_batch \
  scripts/test-mobile-{physical-device-selection,ios-vpn-cleanup,android-release-cleanup,wireguard-exit-dns,wireguard-fixture-cleanup,release-provenance,release-artifact-reuse,underlay-change,release-join-gate}-harness.sh \
  scripts/test-{ios-vpn-desired-state,ios-packet-tunnel-replacement}.sh
start_lane "Apple and desktop contracts" run_contract_batch \
  scripts/test-{macos-vm-import-only,desktop-network-handoff,desktop-dns-ui-evidence,desktop-underlay-host-peer-import,macos-release-fips-roaming,ios-frozen-archive,macos-sdk-compat}-harness.sh
start_lane "Linux import contracts" run_contract_batch \
  scripts/test-host-linux-vm-import-only-harness.sh
foreground_status=0
for contract in \
  scripts/test-{release-gate-parallel,local-fips-workspace,idle-cpu-gate}-harness.sh
do
  "$contract" || {
    contract_status="$?"
    ((foreground_status != 0)) || foreground_status="$contract_status"
  }
done
parallel_status=0
release_gate_parallel_wait_group "${lanes[@]}" || parallel_status="$?"
trap - EXIT
rm -rf "$log_dir"
((foreground_status == 0)) || exit "$foreground_status"
exit "$parallel_status"
