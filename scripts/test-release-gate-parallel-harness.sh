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

if ! stdin_probe_output="$(
  printf 'controller-sentinel\n' \
    | /bin/bash -c '
        set -euo pipefail
        root_dir="$1"
        log_dir="$2"
        source "$root_dir/scripts/lib-release-gate-parallel.sh"
        trap "release_gate_parallel_cancel_all" EXIT
        release_gate_parallel_init "$log_dir"
        lane_reads_stdin() {
          local value
          if IFS= read -r value; then
            printf "lane read controller input: %s\n" "$value"
            return 1
          fi
          printf "lane stdin reached EOF\n"
        }
        release_gate_parallel_start "stdin isolation" lane_reads_stdin >/dev/null
        lane="$RELEASE_GATE_PARALLEL_LAST_INDEX"
        release_gate_parallel_wait "$lane"
      ' _ "$ROOT_DIR" "$tmp/stdin-logs" 2>&1
)"; then
  fail "parallel lane inherited controller stdin: $stdin_probe_output"
fi
[[ "$stdin_probe_output" == *"lane stdin reached EOF"* ]] \
  || fail "parallel stdin probe did not observe EOF"

if ! (
  ps() {
    printf '424242 S\n'
    awk 'BEGIN { for (row = 0; row < 100000; row += 1) print "1 S" }'
  }
  release_gate_parallel_group_alive 424242
); then
  fail "process-group probe stopped reading ps output under pipefail"
fi

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

lane_fails_before_followup() {
  lane_fails
  : >"$tmp/continued-after-failure"
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

collect_peer() {
  local complete_marker="$1"
  sleep 1
  printf 'independent lane completed\n'
  : >"$complete_marker"
}

release_gate_parallel_start \
  "independent collection peer" collect_peer "$tmp/collect-complete"
collect_peer_index="$RELEASE_GATE_PARALLEL_LAST_INDEX"
release_gate_parallel_start "collected group failure" lane_fails_before_followup
collected_failure="$RELEASE_GATE_PARALLEL_LAST_INDEX"
set +e
release_gate_parallel_wait_group \
  "$collect_peer_index" "$collected_failure" >/dev/null 2>&1
status=$?
set -e
[[ "$status" == "7" ]] \
  || fail "parallel group returned $status instead of the collected failure"
[[ -f "$tmp/collect-complete" ]] \
  || fail "a failed lane cancelled its independent peer"
[[ ! -e "$tmp/continued-after-failure" ]] \
  || fail "a collected lane continued after its first failure"
[[ -z "${RELEASE_GATE_PARALLEL_PIDS[$collect_peer_index]:-}" ]] \
  || fail "parallel group did not reap its completed peer"
grep -Fq 'independent lane completed' \
  "${RELEASE_GATE_PARALLEL_LOGS[$collect_peer_index]}" \
  || fail "independent peer log was not preserved"

successful_orphan_lane() {
  local ready_marker="$1"
  local child_pid_file="$2"
  local term_marker="$3"
  (
    trap 'printf "term received\n" >"$term_marker"' TERM
    : >"$ready_marker"
    while :; do
      sleep 10 || true
    done
  ) &
  printf '%s\n' "$!" >"$child_pid_file"
  for _ in $(seq 1 50); do
    [[ -f "$ready_marker" ]] && return 0
    sleep 0.02
  done
  return 1
}

release_gate_parallel_start \
  "successful lane with orphan" \
  successful_orphan_lane \
  "$tmp/successful-orphan-ready" \
  "$tmp/successful-orphan-child.pid" \
  "$tmp/successful-orphan-term"
successful_orphan="$RELEASE_GATE_PARALLEL_LAST_INDEX"
successful_orphan_pgid="${RELEASE_GATE_PARALLEL_PGIDS[$successful_orphan]}"
for _ in $(seq 1 50); do
  [[ -s "$tmp/successful-orphan-child.pid" \
    && -f "$tmp/successful-orphan-ready" ]] && break
  sleep 0.02
done
[[ -s "$tmp/successful-orphan-child.pid" \
  && -f "$tmp/successful-orphan-ready" ]] \
  || fail "successful orphan fixture did not start its descendant"
successful_orphan_child="$(<"$tmp/successful-orphan-child.pid")"
release_gate_parallel_pid_live_in_group \
  "$successful_orphan_child" "$successful_orphan_pgid" \
  || fail "successful orphan escaped its lane process group"
set +e
release_gate_parallel_wait "$successful_orphan" >/dev/null 2>&1
status=$?
set -e
[[ "$status" == "1" ]] \
  || fail "successful lane with an orphan returned $status instead of failing closed"
[[ -f "$tmp/successful-orphan-term" ]] \
  || fail "successful lane orphan did not receive TERM before escalation"
if release_gate_parallel_pid_live_in_group \
  "$successful_orphan_child" "$successful_orphan_pgid"
then
  fail "successful lane orphan survived TERM/KILL cleanup"
fi
if release_gate_parallel_group_alive "$successful_orphan_pgid"; then
  fail "successful lane orphan process group survived cleanup"
fi
[[ -z "${RELEASE_GATE_PARALLEL_PIDS[$successful_orphan]:-}" \
  && -z "${RELEASE_GATE_PARALLEL_PGIDS[$successful_orphan]:-}" ]] \
  || fail "successful lane orphan wrapper/process group was not reaped"

release_gate_parallel_wait_group \
  || fail "empty parallel group did not complete successfully"

set +e
fully_drained_output="$(
  /bin/bash -c '
    set -euo pipefail
    root_dir="$1"
    log_dir="$2"
    source "$root_dir/scripts/lib-release-gate-parallel.sh"
    release_gate_parallel_init "$log_dir"
    release_gate_parallel_start "fully drained first lane" true >/dev/null
    first="$RELEASE_GATE_PARALLEL_LAST_INDEX"
    release_gate_parallel_start "fully drained second lane" true >/dev/null
    second="$RELEASE_GATE_PARALLEL_LAST_INDEX"
    release_gate_parallel_wait_group "$first" "$second" >/dev/null
    printf "fully drained join passed\n"
  ' _ "$ROOT_DIR" "$tmp/fully-drained-logs" 2>&1
)"
fully_drained_status=$?
set -e
[[ "$fully_drained_status" == "0" ]] \
  || fail "fully drained parallel group failed under nounset: $fully_drained_output"
[[ "$fully_drained_output" == *"fully drained join passed"* ]] \
  || fail "fully drained parallel group did not finish its join"

release_gate="$ROOT_DIR/scripts/release-gate.sh"
grep -Fq 'release_gate_parallel_cancel_all || cleanup_failed=1' "$release_gate" \
  || fail "release cleanup ignores a surviving parallel process group"
grep -Fq 'release_gate_cleanup_private_build_dirs || cleanup_failed=1' "$release_gate" \
  || fail "release cleanup does not sweep private builds after lane reaping"
grep -Fq 'for path in "$result_dir"/.desktop-private-*' "$release_gate" \
  || fail "release cleanup does not scope private build cleanup to the exact join directory"
required_modes_lib="$ROOT_DIR/scripts/lib-release-gate-required-modes.sh"
[[ -f "$required_modes_lib" ]] \
  || fail "release gate has no final-release required-mode policy"
# shellcheck disable=SC1090
source "$required_modes_lib"
complete_network_modes=(
  NVPN_RELEASE_GATE_WINDOWS_WG_EXIT_E2E
  NVPN_RELEASE_GATE_WINDOWS_UNDERLAY_NETWORK_CHANGE_E2E
  NVPN_RELEASE_GATE_MACOS_WG_EXIT_E2E
  NVPN_RELEASE_GATE_LINUX_UNDERLAY_NETWORK_CHANGE_E2E
  NVPN_RELEASE_GATE_MOBILE_WG_EXIT_E2E
  NVPN_RELEASE_GATE_MOBILE_UNDERLAY_E2E
)
for name in "${complete_network_modes[@]}"; do
  unset "$name"
done
NVPN_RELEASE_GATE_REQUIRE_COMPLETE=0
release_gate_enforce_complete_real_network_modes
for name in "${complete_network_modes[@]}"; do
  [[ -z "${!name:-}" ]] \
    || fail "developer release gate unexpectedly forced $name"
done
NVPN_RELEASE_GATE_REQUIRE_COMPLETE=1
for name in "${complete_network_modes[@]}"; do
  printf -v "$name" '%s' auto
  export "$name"
done
release_gate_enforce_complete_real_network_modes
for name in "${complete_network_modes[@]}"; do
  [[ "${!name:-}" == required ]] \
    || fail "complete release gate did not force $name to required"
done
NVPN_RELEASE_GATE_MOBILE_UNDERLAY_E2E=0
if release_gate_enforce_complete_real_network_modes >/dev/null 2>&1; then
  fail "complete release gate accepted an explicitly disabled real network mode"
fi
NVPN_RELEASE_GATE_MOBILE_UNDERLAY_E2E=required

grep -Fq 'node scripts/sync-versions.mjs --check' "$release_gate" \
  || fail "release gate mutates generated versions before candidate snapshot"
grep -Fq 'release_gate_enforce_complete_real_network_modes' "$release_gate" \
  || fail "release gate does not enforce final real-network modes"
local_release="$ROOT_DIR/scripts/local-release.mjs"
grep -Fq "NVPN_RELEASE_GATE_REQUIRE_COMPLETE: '1'" "$local_release" \
  || fail "full local release does not fail closed on real-network auto modes"
if grep -Fxq '  node scripts/sync-versions.mjs' "$release_gate"; then
  fail "release gate still rewrites generated versions during preflight"
fi
grep -Fq 'release_gate_parallel_start "Windows platform"' "$release_gate" \
  || fail "release gate does not dispatch the remote Windows lane"
candidate_preflight_line="$(
  grep -n '^  run_release_gate_candidate_preflight$' "$release_gate" \
    | cut -d: -f1 || true
)"
candidate_linux_gui_harness_line="$(
  grep -n '^  ./scripts/test-linux-gui-e2e-lockfile-harness.sh$' \
    "$release_gate" | cut -d: -f1 || true
)"
candidate_source_line_gate="$(
  grep -n '^  ./scripts/check-source-file-lines.sh$' \
    "$release_gate" | cut -d: -f1 || true
)"
candidate_preflight_end_line="$(
  awk '
    $0 == "run_release_gate_candidate_preflight() {" {
      in_candidate_preflight = 1
      next
    }
    in_candidate_preflight && /^}$/ {
      print NR
      exit
    }
  ' "$release_gate"
)"
windows_preparation_line="$(
  grep -n '"Windows platform preparation"' "$release_gate" \
    | tail -1 | cut -d: -f1 || true
)"
windows_dispatch_line="$(
  grep -n 'release_gate_parallel_start "Windows platform"' "$release_gate" \
    | tail -1 | cut -d: -f1 || true
)"
host_validation_dispatch_line="$(
  grep -n '"Host static and Rust validation"' "$release_gate" \
    | tail -1 | cut -d: -f1 || true
)"
[[ -n "$candidate_preflight_line" \
  && -n "$candidate_linux_gui_harness_line" \
  && -n "$candidate_source_line_gate" \
  && -n "$candidate_preflight_end_line" \
  && -n "$windows_preparation_line" \
  && -n "$windows_dispatch_line" \
  && -n "$host_validation_dispatch_line" ]] \
  || fail "release gate preflight/remote overlap markers are incomplete"
platform_preparation_wait_line="$(
  grep -nF 'release_gate_parallel_wait_group "${platform_preparation_lanes[@]}"' \
    "$release_gate" | cut -d: -f1 || true
)"
local_fips_preparation_line="$(
  grep -n '^  prepare_release_cargo_config$' "$release_gate" \
    | cut -d: -f1 || true
)"
[[ -n "$platform_preparation_wait_line" \
  && -n "$local_fips_preparation_line" ]] \
  || fail "release gate local-FIPS ordering markers are incomplete"
(( candidate_preflight_line < windows_preparation_line \
  && candidate_linux_gui_harness_line < candidate_preflight_end_line \
  && candidate_source_line_gate < candidate_preflight_end_line \
  && windows_preparation_line < platform_preparation_wait_line \
  && platform_preparation_wait_line < local_fips_preparation_line \
  && local_fips_preparation_line < windows_dispatch_line \
  && windows_dispatch_line < host_validation_dispatch_line )) \
  || fail "source preparation/static Cargo checks are not isolated around FIPS realization"
grep -Fq 'kotlin.project.persistent.dir=' "$release_gate" \
  || fail "Android static lane leaves Kotlin persistent state in the candidate"
grep -Fxq 'android/.kotlin/' "$ROOT_DIR/.gitignore" \
  || fail "Kotlin project state is not ignored"
android_static_dispatch_line="$(
  grep -n '"Android compile, unit tests, and lint"' "$release_gate" \
    | tail -1 | cut -d: -f1 || true
)"
docker_build_dispatch_line="$(
  grep -n 'release_gate_parallel_start "Docker node image build"' \
    "$release_gate" | tail -1 | cut -d: -f1 || true
)"
[[ -n "$android_static_dispatch_line" \
  && -n "$docker_build_dispatch_line" ]] \
  || fail "post-FIPS independent lane markers are incomplete"
(( local_fips_preparation_line < android_static_dispatch_line \
  && android_static_dispatch_line < host_validation_dispatch_line \
  && local_fips_preparation_line < docker_build_dispatch_line \
  && docker_build_dispatch_line < host_validation_dispatch_line )) \
  || fail "independent Android/Docker work does not overlap stable-session static checks"
preparation_receipt_writes="$(
  grep -A1 'write_platform_preparation_receipt \\' "$release_gate"
)"
for preparation_receipt in \
  WINDOWS_PLATFORM_PREPARATION_RECEIPT \
  MACOS_PLATFORM_PREPARATION_RECEIPT \
  LINUX_PLATFORM_PREPARATION_RECEIPT
do
  grep -Fq "\"\$$preparation_receipt\"" <<<"$preparation_receipt_writes" \
    || fail "$preparation_receipt is not written after successful preparation"
  grep -Fq "if [[ -e \"\$$preparation_receipt\" ]]; then" "$release_gate" \
    || fail "$preparation_receipt is not required before reusing prepared state"
done
for prepared_flag in \
  WINDOWS_LANE_PRE_SYNCED \
  MACOS_PLATFORM_LANE_PRE_SYNCED \
  LINUX_PLATFORM_LANE_PRE_SYNCED
do
  grep -Fq "export $prepared_flag=0" "$release_gate" \
    || fail "$prepared_flag can inherit stale prepared state"
done
grep -Fq 'platform_preparation_receipt_valid \' "$release_gate" \
  || fail "platform preparation receipts are not tied to the exact candidate"
grep -Fq 'if [[ -e "$HOST_LINUX_VM_BUNDLE_PATH_RECEIPT" ]]; then' "$release_gate" \
  || fail "Linux bundle state is loaded without a successful bundle receipt"
grep -Fq 'release_gate_parallel_start "Docker node image build"' "$release_gate" \
  || fail "release gate does not overlap the reusable Docker build with host validation"
grep -Fq \
  'release_gate_parallel_start "Host static and Rust validation" run_host_validation_lane' \
  "$release_gate" \
  || fail "host validation is not a fail-fast collected parallel lane"
host_validation_body="$(
  sed -n '/^run_host_validation_lane() {$/,/^}$/p' "$release_gate"
)"
[[ "$host_validation_body" == *$'  run_release_gate_static_preflight\n  run_rust_validation_lane'* ]] \
  || fail "host validation does not stop before Rust when static checks fail"
if grep -Fq 'run_release_gate_static_preflight ||' "$release_gate"; then
  fail "host static preflight still runs in a conditional that disables errexit"
fi
if grep -Fq 'run_rust_validation_lane ||' "$release_gate" \
  || grep -Fq 'host_validation_status' "$release_gate"
then
  fail "host validation still bypasses fail-fast lane status propagation"
fi
grep -Fq '"Android compile, unit tests, and lint"' "$release_gate" \
  || fail "release gate does not dispatch Android static validation"
grep -Fq ':app:lintDebug' "$release_gate" \
  || fail "release gate does not run Android lint"
grep -Fq ':app:testDebugUnitTest' "$release_gate" \
  || fail "release gate does not run Android unit tests"
grep -Fq 'concurrent_validation_lanes+=("$RELEASE_GATE_PARALLEL_LAST_INDEX")' \
  "$release_gate" \
  || fail "release gate does not collect Android/platform validation"
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

docker_wait_line="$(
  grep -nF 'release_gate_parallel_wait_group "${concurrent_validation_lanes[@]}"' \
    "$release_gate" | cut -d: -f1
)"
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
  || fail "parallel Docker lanes are not joined as one collected result set"
grep -Fq 'NVPN_WG_EXIT_USERSPACE_INTERNET_SUBNET' "$release_gate" \
  || fail "parallel userspace WireGuard fixture has no isolated subnet"
selector_function="$tmp/release-gate-test-selector.sh"
sed -n '/^release_gate_cargo_test_filter() (/ , /^)/p' \
  "$release_gate" >"$selector_function"
# shellcheck disable=SC1090
source "$selector_function"
zero_match_output="$tmp/zero-match.log"
if release_gate_cargo_test_filter fips-core stale_selector \
  printf '%s\n' 'running 0 tests' \
  'test result: ok. 0 passed; 0 failed; 0 ignored; 0 measured' \
  >"$zero_match_output" 2>&1
then
  fail "focused release-gate tests can pass with an empty selector"
fi
grep -Fq 'Release gate test selector matched no passing test: stale_selector (fips-core)' \
  "$zero_match_output" \
  || fail "zero-match FIPS selector did not explain its failure"
release_gate_cargo_test_filter fips-core current_regression \
  printf '%s\n' 'running 1 test' \
  'test module::current_regression ... ok' \
  'test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured' \
  >/dev/null \
  || fail "focused release-gate selector rejected a matching passing test"
grep -Fq 'fresh_control_with_unreturned_endpoint_data_keeps_direct_without_fallback_peer' \
  "$release_gate" \
  || fail "release gate does not run the current no-fallback direct-path regression"
if grep -Fq 'fresh_control_with_unreturned_endpoint_data_blocks_direct_without_known_fallback' \
  "$release_gate"
then
  fail "release gate still selects the removed pre-packet-mover regression name"
fi
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
windows_mobile_join_line="$(
  grep -n '^  run_windows_release_mobile_join_e2e_gate$' \
    "$release_gate" | cut -d: -f1
)"
linux_mobile_join_line="$(
  grep -n '^  run_linux_release_mobile_join_e2e_gate$' \
    "$release_gate" | cut -d: -f1
)"
macos_vm_join_line="$(
  grep -nF '  release_gate_parallel_wait_group "${concurrent_validation_lanes[@]}"' \
    "$release_gate" | cut -d: -f1 || true
)"
[[ -n "$mobile_join_line" \
  && -n "$windows_mobile_join_line" \
  && -n "$linux_mobile_join_line" \
  && -n "$macos_vm_join_line" ]] \
  || fail "serialized physical desktop/mobile lane markers are incomplete"
(( macos_vm_join_line < mobile_join_line \
  && mobile_join_line < windows_mobile_join_line \
  && windows_mobile_join_line < linux_mobile_join_line )) \
  || fail "physical desktop/mobile gate is not serialized after phone lanes and macOS VM UI work"
for platform_join in \
  windows-vm-release-mobile-join-e2e.sh \
  ubuntu-vm-release-mobile-join-e2e.sh
do
  grep -Fq "$platform_join" "$release_gate" \
    || fail "release gate omits exact signed public-UI lane $platform_join"
done
grep -Fq 'NVPN_RELEASE_JOIN_ANDROID_INSTALL_RECEIPT=' "$release_gate" \
  || fail "Windows/Pixel join does not reuse the exact physical Android install receipt"
grep -Fq 'NVPN_RELEASE_JOIN_ANDROID_RECEIPT=' "$release_gate" \
  || fail "desktop/Pixel join does not bind the sealed Android receipt"
grep -Fq 'NVPN_RELEASE_JOIN_ANDROID_FIPS_METADATA_RECEIPT=' "$release_gate" \
  || fail "desktop/Pixel join does not bind Android FIPS provenance"
grep -Fq 'NVPN_RELEASE_JOIN_REUSE_ARTIFACTS=1' "$release_gate" \
  || fail "Linux/Pixel join does not reuse the exact physical Android artifact"
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
  invocation_line="$(
    grep -n "      ${preparation}$" "$release_gate" \
      | tail -1 | cut -d: -f1 || true
  )"
  [[ -n "$definition_line" && -n "$invocation_line" ]] \
    || fail "$preparation is not dispatched in a parallel preparation lane"
done
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
windows_display_wake="$ROOT_DIR/scripts/windows-vm-wake-display.sh"
for windows_ui_wrapper in \
  "$ROOT_DIR/scripts/windows-vm-manual-join-e2e.sh" \
  "$ROOT_DIR/scripts/windows-vm-service-toggle-e2e.sh"
do
  grep -Fq '"$ROOT/scripts/windows-vm-wake-display.sh"' "$windows_ui_wrapper" \
    || fail "$(basename "$windows_ui_wrapper") does not wake the real VM display"
done
grep -Fq 'virsh send-key "$vm" KEY_LEFTSHIFT' "$windows_display_wake" \
  || fail "Windows VM display wake does not inject a real console input event"
windows_manual_join="$ROOT_DIR/scripts/e2e-windows-manual-join-ui.ps1"
grep -Fq 'SetThreadExecutionState(2147483651)' "$windows_manual_join" \
  || fail "Windows manual-join evidence does not hold the interactive display awake"
grep -Fq '$PaintSample = $Bitmap.GetPixel(' "$windows_manual_join" \
  || fail "Windows manual-join evidence accepts an unpainted blank WPF frame"
windows_service_toggle="$ROOT_DIR/scripts/e2e-windows-service-toggle.ps1"
grep -Fq 'CopyFromScreen' "$windows_service_toggle" \
  || fail "Windows service-toggle evidence does not capture the visible app window"
if grep -Fq 'PrintWindow' "$windows_service_toggle"; then
  fail "Windows service-toggle evidence uses PrintWindow, which omits WebView content"
fi
python3 - "$windows_service_toggle" <<'PY'
import pathlib
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
toggle = text.index("$Toggle = $null")
foreground = text.index("[NvpnServiceToggleInput]::SetForegroundWindow(")
capture = text.index("$ScreenshotGraphics.CopyFromScreen(")
if toggle > foreground:
    raise SystemExit(
        "Windows service-toggle evidence is captured before the real toggle is ready"
    )
if foreground > capture:
    raise SystemExit(
        "Windows service-toggle evidence is captured before foregrounding the real app"
    )
if "for ($ScreenshotAttempt = 1;" not in text:
    raise SystemExit(
        "Windows service-toggle evidence does not retry transient desktop-capture failures"
    )
if "SetThreadExecutionState(2147483651)" not in text:
    raise SystemExit(
        "Windows service-toggle evidence does not hold the interactive display"
    )
if "$Screenshot.GetPixel(" not in text:
    raise SystemExit(
        "Windows service-toggle evidence accepts an unpainted blank WPF frame"
    )
if "SetCursorPos" not in text or "mouse_event(2" not in text or "mouse_event(4" not in text:
    raise SystemExit(
        "Windows service-toggle gate does not click the shipped control asynchronously"
    )
if "$Invoke.Invoke()" in text:
    raise SystemExit(
        "Windows service-toggle gate blocks inside InvokePattern while UAC is visible"
    )
PY
grep -Fq 'macos-vm-service-toggle-e2e.sh' "$release_gate" \
  || fail "release gate does not drive the real macOS Authorization service prompt"
grep -Fq 'ubuntu-vm-service-toggle-e2e.sh' "$release_gate" \
  || fail "release gate does not drive the real Linux PolicyKit service prompt"
grep -Fq 'e2e-linux-service-toggle-real.sh' \
  "$ROOT_DIR/scripts/ubuntu-vm-service-toggle-e2e.sh" \
  || fail "Linux VM service gate does not invoke the real PolicyKit fixture"
grep -Fq 'test-host-linux-vm-import-only-harness.sh' "$release_gate" \
  || fail "release gate omits the Linux host-build/import-only source contract"
for linux_vm_gate in \
  "$ROOT_DIR/scripts/ubuntu-vm-manual-join-e2e.sh" \
  "$ROOT_DIR/scripts/ubuntu-vm-service-toggle-e2e.sh"
do
  grep -Fq 'lib-ubuntu-vm-imported-release.sh' "$linux_vm_gate" \
    || fail "$(basename "$linux_vm_gate") does not use the shared immutable import"
  grep -Fq 'NVPN_LINUX_APP_PATH="$app"' "$linux_vm_gate" \
    || fail "$(basename "$linux_vm_gate") does not execute the imported GTK app"
  grep -Fq 'NVPN_LINUX_NVPN_PATH="$cli"' "$linux_vm_gate" \
    || fail "$(basename "$linux_vm_gate") does not execute the imported CLI"
  grep -Fq 'NVPN_LINUX_FIXTURE_PATH="$fixture"' "$linux_vm_gate" \
    || fail "$(basename "$linux_vm_gate") does not execute the imported fixture"
  if grep -Eq '(^|[[:space:]])(cargo|rustc)([[:space:]]|$)' "$linux_vm_gate"; then
    fail "$(basename "$linux_vm_gate") can compile on the Ubuntu VM"
  fi
done
grep -Fq './scripts/prepare-host-linux-vm-bundle.sh' "$release_gate" \
  || fail "Linux platform lane does not prepare its immutable bundle on the host"
grep -Fq 'export NVPN_HOST_LINUX_VM_BUNDLE_DIR' "$release_gate" \
  || fail "Linux manual-join and service gates cannot reuse one host bundle"
if grep -Fq './scripts/e2e-linux-service-toggle.sh' "$release_gate"; then
  fail "fake Linux service-toggle fixture can satisfy the release gate"
fi
python3 - \
  "$release_gate" \
  "$ROOT_DIR/scripts/ubuntu-vm-git-sync.sh" \
  "$ROOT_DIR/scripts/ubuntu-vm-manual-join-e2e.sh" \
  "$ROOT_DIR/scripts/ubuntu-vm-service-toggle-e2e.sh" \
  "$ROOT_DIR/scripts/lib-ubuntu-vm-imported-release.sh" \
  "$ROOT_DIR/scripts/prepare-host-linux-vm-bundle.sh" \
  "$ROOT_DIR/scripts/macos-vm-git-sync.sh" \
  "$ROOT_DIR/scripts/macos-vm-manual-join-e2e.sh" \
  "$ROOT_DIR/scripts/macos-vm-service-toggle-e2e.sh" \
  "$ROOT_DIR/scripts/windows-vm-manual-join-e2e.sh" \
  "$ROOT_DIR/scripts/windows-vm-service-toggle-e2e.sh" \
  "$ROOT_DIR/scripts/windows-vm-wake-display.sh" <<'PY'
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
[[ "$(grep -Fc 'NVPN_MOBILE_WG_EXIT_HTTP_PROBE_PORT="$port_base"' "$release_gate")" -eq 2 ]] \
  || fail "Android physical lanes do not isolate their remote HTTP probe ports"
[[ "$(grep -Fc 'NVPN_MOBILE_WG_EXIT_HTTP_PROBE_PORT="$((port_base + 1))"' "$release_gate")" -eq 2 ]] \
  || fail "iOS physical lanes do not isolate their remote HTTP probe ports"
grep -Fq 'remote fixture HTTP probe TCP port is already occupied' \
  "$ROOT_DIR/scripts/lib-mobile-wireguard-fixture.sh" \
  || fail "remote native fixture does not fail before mutating on an occupied HTTP port"
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
grep -Fq 'NVPN_MOBILE_WG_EXIT_SERVER_IP=10.99.77.1' <<<"$mobile_exit_gate_body" \
  && grep -Fq 'NVPN_MOBILE_WG_EXIT_CLIENT_IP=10.99.77.2' \
    <<<"$mobile_exit_gate_body" \
  && grep -Fq 'NVPN_MOBILE_WG_EXIT_THROUGH_DNS_IP=10.99.77.53' \
    <<<"$mobile_exit_gate_body" \
  || fail "parallel Android exit lane has no isolated tunnel address pair"
grep -Fq 'NVPN_MOBILE_WG_EXIT_SERVER_IP=10.99.78.1' <<<"$mobile_exit_gate_body" \
  && grep -Fq 'NVPN_MOBILE_WG_EXIT_CLIENT_IP=10.99.78.2' \
    <<<"$mobile_exit_gate_body" \
  && grep -Fq 'NVPN_MOBILE_WG_EXIT_THROUGH_DNS_IP=10.99.78.53' \
    <<<"$mobile_exit_gate_body" \
  || fail "parallel iOS exit lane shares the Android tunnel address pair"
grep -Fq 'NVPN_MOBILE_WG_EXIT_SERVER_IP=10.99.79.1' "$release_gate" \
  && grep -Fq 'NVPN_MOBILE_WG_EXIT_CLIENT_IP=10.99.79.2' "$release_gate" \
  && grep -Fq 'NVPN_MOBILE_WG_EXIT_THROUGH_DNS_IP=10.99.79.53' "$release_gate" \
  || fail "Android underlay lane has an invalid tunnel/DNS address tuple"
grep -Fq 'NVPN_MOBILE_WG_EXIT_SERVER_IP=10.99.80.1' "$release_gate" \
  && grep -Fq 'NVPN_MOBILE_WG_EXIT_CLIENT_IP=10.99.80.2' "$release_gate" \
  && grep -Fq 'NVPN_MOBILE_WG_EXIT_THROUGH_DNS_IP=10.99.80.53' "$release_gate" \
  || fail "iOS underlay lane has an invalid tunnel/DNS address tuple"
grep -Fq 'NVPN_MOBILE_WG_EXIT_HOST_PORT="$port_base"' <<<"$mobile_exit_gate_body" \
  && grep -Fq 'NVPN_MOBILE_WG_EXIT_HOST_PORT="$((port_base + 1))"' \
    <<<"$mobile_exit_gate_body" \
  || fail "parallel mobile exit lanes share a WireGuard endpoint port"
if grep -Fq 'signed-debug' "$release_gate"; then
  fail "signed Release join lane can select a debug Android artifact"
fi
grep -Fq 'NVPN_RELEASE_JOIN_ALLOW_ANDROID_DATA_CLEAR=YES' "$release_gate" \
  || fail "signed Release join lane does not opt into Android app-data clearing"
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
