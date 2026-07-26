#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/lib-release-gate-parallel.sh"

fail() {
  printf 'release gate parallel harness failed: %s\n' "$*" >&2
  exit 1
}

tmp="$(mktemp -d "${TMPDIR:-/tmp}/nvpn-release-gate-parallel.XXXXXX")"
trap 'release_gate_parallel_cancel_all; rm -rf "$tmp"' EXIT
release_gate_parallel_init "$tmp/logs"

lane_waits_for_peer() {
  local peer_marker="$1"
  local own_marker="$2"
  local end=$(( $(date +%s) + 5 ))
  : >"$own_marker"
  while [[ ! -f "$peer_marker" && "$(date +%s)" -le "$end" ]]; do
    sleep 0.05
  done
  [[ -f "$peer_marker" ]]
  printf 'saw peer lane\n'
}

release_gate_parallel_start "first lane" lane_waits_for_peer "$tmp/second" "$tmp/first"
first="$RELEASE_GATE_PARALLEL_LAST_INDEX"
release_gate_parallel_start "second lane" lane_waits_for_peer "$tmp/first" "$tmp/second"
second="$RELEASE_GATE_PARALLEL_LAST_INDEX"
release_gate_parallel_wait "$first" >/dev/null
release_gate_parallel_wait "$second" >/dev/null
grep -Fq 'saw peer lane' "$tmp/logs/first-lane-0.log" \
  || fail "first lane did not run concurrently"
grep -Fq 'saw peer lane' "$tmp/logs/second-lane-1.log" \
  || fail "second lane did not run concurrently"

lane_fails() {
  printf 'intentional lane failure\n'
  return 7
}

release_gate_parallel_start "failing lane" lane_fails
failing="$RELEASE_GATE_PARALLEL_LAST_INDEX"
set +e
release_gate_parallel_wait "$failing" >/dev/null 2>&1
status=$?
set -e
[[ "$status" == "7" ]] || fail "failing lane returned $status instead of 7"
grep -Fq 'intentional lane failure' "$tmp/logs/failing-lane-2.log" \
  || fail "failing lane log was not preserved"

slow_lane() {
  local ready_marker="$1"
  trap 'printf "slow lane cancelled\n"; exit 0' TERM
  printf 'slow lane started\n'
  : >"$ready_marker"
  sleep 10
}

release_gate_parallel_start "slow cancellation peer" slow_lane "$tmp/slow-ready"
slow="$RELEASE_GATE_PARALLEL_LAST_INDEX"
slow_log="${RELEASE_GATE_PARALLEL_LOGS[$slow]}"
for _ in $(seq 1 50); do
  [[ -f "$tmp/slow-ready" ]] && break
  sleep 0.02
done
[[ -f "$tmp/slow-ready" ]] || fail "slow cancellation peer did not start"
release_gate_parallel_start "fast group failure" lane_fails
fast_failure="$RELEASE_GATE_PARALLEL_LAST_INDEX"
group_started="$(date +%s)"
set +e
release_gate_parallel_wait_group "$slow" "$fast_failure" >/dev/null 2>&1
status=$?
set -e
group_elapsed=$(( $(date +%s) - group_started ))
[[ "$status" == "7" ]] \
  || fail "parallel group returned $status instead of the early lane failure"
(( group_elapsed < 5 )) \
  || fail "parallel group waited ${group_elapsed}s behind an earlier slow lane"
[[ -z "${RELEASE_GATE_PARALLEL_PIDS[$slow]:-}" ]] \
  || fail "parallel group did not reap its cancelled peer"
grep -Fq 'slow lane started' "$slow_log" \
  || fail "cancelled peer log was not preserved"

release_gate="$ROOT_DIR/scripts/release-gate.sh"
grep -Fq 'node scripts/sync-versions.mjs --check' "$release_gate" \
  || fail "release gate mutates generated versions before candidate snapshot"
if grep -Fxq '  node scripts/sync-versions.mjs' "$release_gate"; then
  fail "release gate still rewrites generated versions during preflight"
fi
grep -Fq 'release_gate_parallel_start "Windows platform"' "$release_gate" \
  || fail "release gate does not dispatch the remote Windows lane"
candidate_preflight_line="$(
  grep -n '^  run_release_gate_candidate_preflight$' "$release_gate" \
    | cut -d: -f1 || true
)"
windows_dispatch_line="$(
  grep -n 'release_gate_parallel_start "Windows platform"' "$release_gate" \
    | tail -1 | cut -d: -f1 || true
)"
static_preflight_line="$(
  grep -n '^  run_release_gate_static_preflight$' "$release_gate" \
    | cut -d: -f1 || true
)"
[[ -n "$candidate_preflight_line" \
  && -n "$windows_dispatch_line" \
  && -n "$static_preflight_line" ]] \
  || fail "release gate preflight/remote overlap markers are incomplete"
(( candidate_preflight_line < windows_dispatch_line \
  && windows_dispatch_line < static_preflight_line )) \
  || fail "remote platform lanes do not overlap the non-mutating static preflight"
grep -Fq 'release_gate_parallel_start "Docker node image build"' "$release_gate" \
  || fail "release gate does not overlap the reusable Docker build with host validation"
grep -Fq '"Android compile, unit tests, and lint"' "$release_gate" \
  || fail "release gate does not dispatch Android static validation"
grep -Fq ':app:lintDebug' "$release_gate" \
  || fail "release gate does not run Android lint"
grep -Fq ':app:testDebugUnitTest' "$release_gate" \
  || fail "release gate does not run Android unit tests"
grep -Fq 'release_gate_parallel_wait "$android_static_lane"' "$release_gate" \
  || fail "release gate does not join Android static validation"
grep -Fq ':app:lintRelease' "$ROOT_DIR/.github/workflows/release.yml" \
  || fail "hosted Android release build does not run release lint"
grep -Fq 'export NVPN_E2E_SKIP_NODE_BUILD=1' "$release_gate" \
  || fail "release gate does not reuse its prebuilt Docker node image"
grep -Fq 'cache_to:' "$ROOT_DIR/docker-compose.e2e.yml" \
  || fail "shared Docker node image does not persist reusable cache metadata"
grep -Fq 'type=local,src=${NVPN_E2E_BUILDX_CACHE_DIR:-.buildx-cache/e2e-node}' "$ROOT_DIR/docker-compose.e2e.yml" \
  || fail "shared Docker node image does not import its local BuildKit cache"
grep -Fq 'type=local,dest=${NVPN_E2E_BUILDX_CACHE_DIR:-.buildx-cache/e2e-node},mode=max' "$ROOT_DIR/docker-compose.e2e.yml" \
  || fail "shared Docker node image does not export a complete local BuildKit cache"
grep -Fq 'cache_to:' "$ROOT_DIR/linux/docker-compose.yml" \
  || fail "Linux GUI image does not persist reusable cache metadata"
grep -Fq 'type=local,src=${NVPN_LINUX_BUILDX_CACHE_DIR:-../.buildx-cache/linux-gui}' "$ROOT_DIR/linux/docker-compose.yml" \
  || fail "Linux GUI image does not import its local BuildKit cache"
grep -Fq 'type=local,dest=${NVPN_LINUX_BUILDX_CACHE_DIR:-../.buildx-cache/linux-gui},mode=max' "$ROOT_DIR/linux/docker-compose.yml" \
  || fail "Linux GUI image does not export a complete local BuildKit cache"
grep -Fq 'test -f /tmp/nostr-vpn-dev-ready' "$ROOT_DIR/tools/run-linux" \
  || fail "Linux GUI runner can race the container desktop initializer"
grep -Fq 'touch /tmp/nostr-vpn-dev-ready' "$ROOT_DIR/linux/scripts/dev-entrypoint.sh" \
  || fail "Linux GUI container does not publish completed desktop initialization"

docker_wait_line="$(grep -n 'release_gate_parallel_wait "$docker_build_lane"' "$release_gate" | cut -d: -f1)"
signal_line="$(grep -n '^  run_docker_signal_gates$' "$release_gate" | cut -d: -f1)"
functional_line="$(grep -n '^  run_docker_isolated_functional_gates$' "$release_gate" | cut -d: -f1)"
perf_line="$(grep -n '^  run_docker_perf_gate$' "$release_gate" | cut -d: -f1)"
[[ -n "$docker_wait_line" && -n "$signal_line" && -n "$functional_line" && -n "$perf_line" ]] \
  || fail "release gate serial phase markers are incomplete"
(( docker_wait_line < signal_line && signal_line < functional_line && functional_line < perf_line )) \
  || fail "release gate does not join builds and functional lanes before performance phases"
grep -Fq 'release_gate_parallel_start "Docker NAT-safe MTU"' "$release_gate" \
  || fail "release gate does not dispatch the isolated NAT functional lane"
grep -Fq 'release_gate_parallel_start "Docker kernel WireGuard exit"' "$release_gate" \
  || fail "release gate does not dispatch the isolated kernel WireGuard lane"
grep -Fq 'release_gate_parallel_start "Docker userspace WireGuard exit"' "$release_gate" \
  || fail "release gate does not dispatch the isolated userspace WireGuard lane"
grep -Fq 'release_gate_parallel_wait_group "${lanes[@]}"' "$release_gate" \
  || fail "parallel Docker lane failures wait behind earlier slow lanes"
grep -Fq 'NVPN_WG_EXIT_USERSPACE_INTERNET_SUBNET' "$release_gate" \
  || fail "parallel userspace WireGuard fixture has no isolated subnet"
grep -Fq 'Release gate test selector matched no passing test' "$release_gate" \
  || fail "focused release-gate tests can pass with an empty selector"
grep -Fq -- '--skip websocket_seed_router_delivers_join_roster_to_guest_without_preconfigured_admin' "$release_gate" \
  || fail "the strict QR-join latency gate still runs during the cold Docker build"
for durable_receipt_test in \
  websocket_seed_router_retries_durable_join_receipt_after_first_route_failure \
  websocket_seed_router_delivers_durable_join_receipt_after_tunnel_restart
do
  grep -Fq -- "--skip $durable_receipt_test" "$release_gate" \
    || fail "$durable_receipt_test still runs during the contended cold workspace suite"
  [[ "$(grep -Fc "$durable_receipt_test" "$release_gate")" -ge 2 ]] \
    || fail "$durable_receipt_test is skipped but not rerun in the strict serial lane"
done
grep -Fq 'desktop_mobile_manual_join_desktop_admin_to_mobile_joiner' "$release_gate" \
  || fail "release gate does not prove desktop-admin to mobile-joiner delivery"
grep -Fq 'desktop_mobile_manual_join_mobile_admin_to_desktop_joiner' "$release_gate" \
  || fail "release gate does not prove mobile-admin to desktop-joiner delivery"
grep -Fq 'e2e-manual-join-cli.sh' "$release_gate" \
  || fail "release gate does not execute both real CLI manual-join commands"
grep -Fq 'windows-vm-manual-join-e2e.sh' "$release_gate" \
  || fail "release gate does not drive shipped Windows manual-join controls"
grep -Fq 'macos-vm-manual-join-e2e.sh' "$release_gate" \
  || fail "release gate does not drive shipped macOS manual-join controls"
grep -Fq 'ubuntu-vm-manual-join-e2e.sh' "$release_gate" \
  || fail "release gate does not drive shipped Linux manual-join controls"
grep -Fq 'NVPN_RELEASE_GATE_MOBILE_JOIN_E2E:-required' "$release_gate" \
  || fail "signed Release cross-platform join is not required by default"
grep -Fq 'NVPN_RELEASE_JOIN_DESKTOP_MOBILE=1' "$release_gate" \
  || fail "signed Release join omits desktop/mobile role coverage"
mobile_join_line="$(grep -n '^  run_mobile_join_e2e_gate$' "$release_gate" | cut -d: -f1)"
macos_vm_join_line="$(
  grep -nF '    release_gate_parallel_wait "$macos_platform_lane"' \
    "$release_gate" | cut -d: -f1 || true
)"
[[ -n "$mobile_join_line" && -n "$macos_vm_join_line" ]] \
  || fail "serialized physical desktop/mobile lane markers are incomplete"
(( macos_vm_join_line < mobile_join_line )) \
  || fail "physical desktop/mobile gate is not serialized after phone lanes and macOS VM UI work"
if grep -Fq 'run_desktop_mobile_manual_join_e2e_gate' "$release_gate" \
  || [[ -e "$ROOT_DIR/scripts/macos-vm-android-manual-join-e2e.sh" ]] \
  || [[ -e "$ROOT_DIR/scripts/e2e-macos-android-manual-join-remote.sh" ]]
then
  fail "superseded private-state desktop/mobile join path remains"
fi
for macos_native_gate in \
  "$ROOT_DIR/scripts/e2e-macos-manual-join-ui.sh" \
  "$ROOT_DIR/scripts/e2e-macos-service-toggle.sh"
do
  grep -Fq 'cargo-target/$HOST_TARGET/release/examples/desktop_manual_join_e2e_fixture' \
    "$macos_native_gate" \
    || fail "$(basename "$macos_native_gate") duplicates the macOS Cargo dependency graph"
  grep -Fq -- '--target "$HOST_TARGET"' "$macos_native_gate" \
    || fail "$(basename "$macos_native_gate") does not reuse the target-specific macOS build"
  grep -Fq -- '-p nostr-vpn-core' "$macos_native_gate" \
    || fail "$(basename "$macos_native_gate") builds the manual-join fixture from the wrong package"
done
grep -Fq 'release_gate_parallel_start "macOS platform UI"' "$release_gate" \
  || fail "isolated macOS UI work does not overlap the host validation lane"
grep -Fq 'release_gate_parallel_start "Linux platform UI"' "$release_gate" \
  || fail "isolated Linux UI work does not overlap the host validation lane"
for preparation in \
  prepare_windows_platform_lane_sync \
  prepare_macos_platform_lane_sync \
  prepare_linux_platform_lane_sync
do
  definition_line="$(grep -n "^${preparation}()" "$release_gate" | cut -d: -f1)"
  invocation_line="$(grep -n "^  ${preparation}$" "$release_gate" | cut -d: -f1)"
  [[ -n "$definition_line" && -n "$invocation_line" ]] \
    || fail "$preparation is not invoked inside its parallel platform lane"
done
main_line="$(grep -n '^main()' "$release_gate" | cut -d: -f1)"
if tail -n "+$main_line" "$release_gate" \
  | grep -Eq '^  prepare_(windows|macos|linux)_platform_lane_sync$'
then
  fail "remote platform syncs still serialize in main before lane dispatch"
fi
for platform in WINDOWS MACOS LINUX; do
  grep -Fq "NVPN_RELEASE_GATE_${platform}_MANUAL_JOIN_UI_E2E:-required" "$release_gate" \
    || fail "$platform manual-join native UI gate is not required by default"
  grep -Fq "NVPN_RELEASE_GATE_${platform}_SERVICE_TOGGLE_E2E:-required" "$release_gate" \
    || fail "$platform service-toggle native UI gate is not required by default"
done
hosted_release_workflow="$ROOT_DIR/.github/workflows/release.yml"
for platform in WINDOWS MACOS LINUX; do
  grep -Fq "NVPN_RELEASE_GATE_${platform}_MANUAL_JOIN_UI_E2E: '0'" \
    "$hosted_release_workflow" \
    || fail "hosted release verifier still requires the private $platform manual-join VM"
  grep -Fq "NVPN_RELEASE_GATE_${platform}_SERVICE_TOGGLE_E2E: '0'" \
    "$hosted_release_workflow" \
    || fail "hosted release verifier still requires the private $platform service-toggle VM"
done
grep -Fq 'windows-vm-service-toggle-e2e.sh' "$release_gate" \
  || fail "release gate does not drive the real Windows UAC service prompt"
grep -Fq 'macos-vm-service-toggle-e2e.sh' "$release_gate" \
  || fail "release gate does not drive the real macOS Authorization service prompt"
grep -Fq 'ubuntu-vm-service-toggle-e2e.sh' "$release_gate" \
  || fail "release gate does not drive the real Linux PolicyKit service prompt"
grep -Fq 'e2e-linux-service-toggle-real.sh' \
  "$ROOT_DIR/scripts/ubuntu-vm-service-toggle-e2e.sh" \
  || fail "Linux VM service gate does not invoke the real PolicyKit fixture"
if grep -Fq './scripts/e2e-linux-service-toggle.sh' "$release_gate"; then
  fail "fake Linux service-toggle fixture can satisfy the release gate"
fi
python3 - \
  "$release_gate" \
  "$ROOT_DIR/scripts/ubuntu-vm-git-sync.sh" \
  "$ROOT_DIR/scripts/ubuntu-vm-manual-join-e2e.sh" \
  "$ROOT_DIR/scripts/ubuntu-vm-service-toggle-e2e.sh" \
  "$ROOT_DIR/scripts/macos-vm-git-sync.sh" \
  "$ROOT_DIR/scripts/macos-vm-manual-join-e2e.sh" \
  "$ROOT_DIR/scripts/macos-vm-service-toggle-e2e.sh" \
  "$ROOT_DIR/scripts/windows-vm-manual-join-e2e.sh" \
  "$ROOT_DIR/scripts/windows-vm-service-toggle-e2e.sh" <<'PY'
import pathlib
import re
import sys

unsafe = re.compile(
    r"\$\{NVPN_(?:WINDOWS|MACOS|UBUNTU)_SSH_HOST:-[A-Za-z0-9]"
    r"|/(?:Users|home)/[A-Za-z0-9._-]+/"
)
for name in sys.argv[1:]:
    text = pathlib.Path(name).read_text(encoding="utf-8")
    if match := unsafe.search(text):
        raise SystemExit(
            f"native platform gate script contains a private default or absolute guest path: "
            f"{pathlib.Path(name).name}:{match.start()}"
        )
PY
if grep -Fq 'test-manual-join-platform-contract.sh' "$release_gate"; then
  fail "release gate still substitutes source grep for native manual-join UI execution"
fi
grep -Fq 'e2e-web-startos-manual-join-docker.sh' "$release_gate" \
  || fail "release gate does not execute the real web/StartOS manual-join runtime gate"
web_startos_join_gate="$ROOT_DIR/scripts/e2e-web-startos-manual-join-docker.sh"
[[ -x "$web_startos_join_gate" ]] \
  || fail "real web/StartOS manual-join runtime gate is missing or not executable"
for evidence in \
  'desktop_manual_join_e2e_fixture' \
  'capture-delivery' \
  'verify-runtime' \
  'manual-join-runtime.spec.ts'
do
  grep -Fq "$evidence" "$web_startos_join_gate" \
    || fail "web/StartOS manual-join gate lacks production evidence: $evidence"
done
grep -Fq 'dockerfile: '\''./umbrel/Dockerfile'\''' \
  "$ROOT_DIR/startos/manifest/index.ts" \
  || fail "StartOS no longer packages the exact web image exercised by the runtime gate"
grep -Fq './scripts/test-mobile-wireguard-exit-dns-harness.sh' "$release_gate" \
  || fail "release gate does not enforce the physical mobile exit/DNS source contract"
grep -Fq 'NVPN_RELEASE_GATE_QR_JOIN_LATENCY' "$release_gate" \
  || fail "the strict QR-join latency gate cannot be scoped to calibrated hosts"
grep -Fq 'public_transit_routes_fips_control_by_npub_without_direct_peer_config' "$release_gate" \
  || fail "release gate does not execute the real cross-seed public FIPS transit probe"
grep -Fq -- '--ignored' "$release_gate" \
  || fail "release gate does not opt into the deployed public FIPS transit probe"
grep -Fq 'NVPN_RELEASE_GATE_TARGET_SECS:-1800' "$release_gate" \
  || fail "release gate has no explicit 30-minute wall-clock target"
grep -Fq 'NVPN_E2E_DIRECT_RECOVERY_SECS:-20' "$ROOT_DIR/scripts/e2e-fips-roaming-docker.sh" \
  || fail "FIPS direct recovery can wait longer than the verified 20-second gate"
grep -Fq 'NVPN_MOBILE_WG_EXIT_INSTALL_IOS="$((1 - MOBILE_IOS_APP_READY))"' "$release_gate" \
  || fail "release gate rebuilds the same physical iOS app for the exit lane"
grep -Fq 'NVPN_MOBILE_WG_EXIT_INSTALL_ANDROID="$((1 - MOBILE_ANDROID_APP_READY))"' "$release_gate" \
  || fail "release gate rebuilds the same canonical Android app for the exit lane"
grep -Fq 'release_gate_parallel_start \' "$release_gate" \
  && grep -Fq '"Android physical WireGuard exit and DNS"' "$release_gate" \
  || fail "release gate does not dispatch the physical Android exit lane"
grep -Fq '"iOS physical WireGuard exit and DNS"' "$release_gate" \
  || fail "release gate does not dispatch the physical iOS exit lane"
mobile_exit_gate_body="$(
  sed -n '/^run_mobile_wireguard_exit_gates() {$/,/^}$/p' "$release_gate"
)"
grep -Fq 'local remote_native=0' <<<"$mobile_exit_gate_body" \
  && grep -Fq '[[ "$remote_native" -eq 0 ]]' <<<"$mobile_exit_gate_body" \
  && grep -Fq 'local image_ready=0' <<<"$mobile_exit_gate_body" \
  && grep -Fq 'NVPN_MOBILE_WG_EXIT_IMAGE_READY="$image_ready"' \
    <<<"$mobile_exit_gate_body" \
  || fail "parallel mobile exit lanes do not isolate remote-native fixture setup"
if grep -Fq 'NVPN_MOBILE_WG_EXIT_IMAGE_READY=1' <<<"$mobile_exit_gate_body"; then
  fail "remote-native mobile exit lanes still claim a prebuilt Docker fixture"
fi
grep -Fq 'NVPN_MOBILE_WG_EXIT_CONTAINER="nostr-vpn-mobile-wg-release-android-$$"' "$release_gate" \
  || fail "parallel Android exit lane has no isolated Docker fixture"
grep -Fq 'NVPN_MOBILE_WG_EXIT_CONTAINER="nostr-vpn-mobile-wg-release-ios-$$"' "$release_gate" \
  || fail "parallel iOS exit lane has no isolated Docker fixture"
grep -Fq 'NVPN_MOBILE_WG_EXIT_SERVER_IP=10.99.78.1' "$release_gate" \
  || fail "parallel iOS exit lane shares the Android tunnel subnet"
grep -Fq 'NVPN_MOBILE_WG_EXIT_HOST_PORT="$((port_base + 1))"' "$release_gate" \
  || fail "parallel mobile exit lanes share a host UDP port"
if grep -Fq 'signed-debug' "$release_gate"; then
  fail "signed Release join lane can select a debug Android artifact"
fi
grep -Fq 'NVPN_RELEASE_JOIN_ALLOW_DEVICE_RESET=YES' "$release_gate" \
  || fail "signed Release join lane does not opt into its explicit physical reset"
grep -Fq 'NVPN_IDLE_CPU_GATE=0' "$release_gate" \
  || fail "mobile WireGuard exit lane repeats the dedicated physical idle CPU samples"
grep -Fq 'NVPN_MOBILE_WG_EXIT_LIFECYCLE_GATE=0' "$release_gate" \
  || fail "mobile WireGuard exit lane repeats the dedicated physical lifecycle checks"
if grep -Fq 'NVPN_IDLE_CPU_GATE=0' "$ROOT_DIR/scripts/mobile-wireguard-exit-e2e.sh"; then
  fail "standalone mobile WireGuard exit e2e disables its idle CPU coverage"
fi
if grep -Fq 'NVPN_MOBILE_WG_EXIT_LIFECYCLE_GATE=0' \
  "$ROOT_DIR/scripts/mobile-wireguard-exit-e2e.sh"
then
  fail "standalone mobile WireGuard exit e2e disables its lifecycle coverage"
fi
if grep -Eq '(windows_platform_lane_requested|docker_release_gates_enabled) \|\| return$' "$release_gate"; then
  fail "a disabled optional lane returns failure under set -e"
fi

printf 'release gate parallel harness passed\n'
