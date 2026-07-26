#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MOBILE_IOS_APP_READY=0
MOBILE_ANDROID_APP_READY=0
cd "$ROOT_DIR"

source "$ROOT_DIR/scripts/release_common.sh"
source "$ROOT_DIR/scripts/lib-release-gate-timeout.sh"
source "$ROOT_DIR/scripts/lib-release-gate-parallel.sh"
source "$ROOT_DIR/scripts/mobile_env.sh"
load_mobile_env "$ROOT_DIR"
enable_deterministic_build_env "$ROOT_DIR"

export NVPN_IDLE_CPU_GATE="${NVPN_RELEASE_GATE_IDLE_CPU:-${NVPN_IDLE_CPU_GATE:-1}}"
export NVPN_IDLE_CPU_MAX_PERCENT="${NVPN_RELEASE_GATE_IDLE_CPU_MAX_PERCENT:-${NVPN_IDLE_CPU_MAX_PERCENT:-2}}"
export NVPN_IDLE_CPU_SAMPLE_SECONDS="${NVPN_RELEASE_GATE_IDLE_CPU_SAMPLE_SECONDS:-${NVPN_IDLE_CPU_SAMPLE_SECONDS:-60}}"
export NVPN_IDLE_CPU_SETTLE_SECONDS="${NVPN_RELEASE_GATE_IDLE_CPU_SETTLE_SECONDS:-${NVPN_IDLE_CPU_SETTLE_SECONDS:-15}}"
# The Android VPN fixture maintains the two production bootstrap adjacencies,
# unlike the foreground/UI idle gates. Keep a separate bound for that active
# encrypted overlay while retaining the packet/TUN correctness probe below.
ANDROID_ACTIVE_OVERLAY_IDLE_CPU_MAX_PERCENT="${NVPN_ANDROID_ACTIVE_OVERLAY_IDLE_CPU_MAX_PERCENT:-4}"

MACOS_WG_EXIT_TIMEOUT_SECS="${NVPN_RELEASE_GATE_MACOS_WG_EXIT_TIMEOUT_SECS:-300}"
WINDOWS_WG_EXIT_TIMEOUT_SECS="${NVPN_RELEASE_GATE_WINDOWS_WG_EXIT_TIMEOUT_SECS:-1800}"
LINUX_GUI_SMOKE_TIMEOUT_SECS="${NVPN_RELEASE_GATE_LINUX_GUI_SMOKE_TIMEOUT_SECS:-1800}"
MACOS_GUI_SMOKE_TIMEOUT_SECS="${NVPN_RELEASE_GATE_MACOS_GUI_SMOKE_TIMEOUT_SECS:-900}"
MACOS_DAEMON_IDLE_CPU_TIMEOUT_SECS="${NVPN_RELEASE_GATE_MACOS_DAEMON_IDLE_CPU_TIMEOUT_SECS:-600}"
WINDOWS_GUI_SMOKE_TIMEOUT_SECS="${NVPN_RELEASE_GATE_WINDOWS_GUI_SMOKE_TIMEOUT_SECS:-1800}"
DESKTOP_MANUAL_JOIN_UI_TIMEOUT_SECS="${NVPN_RELEASE_GATE_DESKTOP_MANUAL_JOIN_UI_TIMEOUT_SECS:-1800}"
DESKTOP_SERVICE_TOGGLE_TIMEOUT_SECS="${NVPN_RELEASE_GATE_DESKTOP_SERVICE_TOGGLE_TIMEOUT_SECS:-1800}"
MOBILE_GUI_SMOKE_TIMEOUT_SECS="${NVPN_RELEASE_GATE_MOBILE_GUI_SMOKE_TIMEOUT_SECS:-1800}"
ANDROID_LEGACY_REPLACEMENT_TIMEOUT_SECS="${NVPN_RELEASE_GATE_ANDROID_LEGACY_REPLACEMENT_TIMEOUT_SECS:-600}"
IOS_TUNNEL_IDLE_CPU_TIMEOUT_SECS="${NVPN_RELEASE_GATE_IOS_TUNNEL_IDLE_CPU_TIMEOUT_SECS:-180}"
MOBILE_WG_EXIT_TIMEOUT_SECS="${NVPN_RELEASE_GATE_MOBILE_WG_EXIT_TIMEOUT_SECS:-3600}"
MOBILE_JOIN_E2E_TIMEOUT_SECS="${NVPN_RELEASE_GATE_MOBILE_JOIN_E2E_TIMEOUT_SECS:-1800}"
RELEASE_GATE_TARGET_SECS="${NVPN_RELEASE_GATE_TARGET_SECS:-1800}"

release_cargo_config_args=()
release_cargo_config_backup=""
release_cargo_config_existed=0
release_cargo_config_path="$ROOT_DIR/.cargo/config.toml"
release_cargo_lock_args=(--locked)
release_cargo_lock_backup=""
release_cargo_wrapper_dir=""
release_fips_path=""
release_cargo_lock_original_sha256=""
release_cargo_manifest_original_sha256=""

restore_release_cargo_lock() {
  local cleanup_failed=0
  if [[ -n "$release_cargo_manifest_original_sha256" \
    && "$(release_file_sha256 "$ROOT_DIR/Cargo.toml")" \
      != "$release_cargo_manifest_original_sha256" ]]
  then
    echo "Release gate Cargo.toml changed during the local-FIPS session." >&2
    cleanup_failed=1
  fi
  if [[ -n "${NVPN_LOCAL_FIPS_SESSION_CARGO_LOCK_SHA256:-}" \
    && "$(release_file_sha256 "$ROOT_DIR/Cargo.lock")" \
      != "$NVPN_LOCAL_FIPS_SESSION_CARGO_LOCK_SHA256" ]]
  then
    echo "Release gate Cargo.lock changed after local-FIPS preparation." >&2
    cleanup_failed=1
  fi
  if [[ -n "$release_cargo_config_backup" ]]; then
    if [[ "$release_cargo_config_existed" == "1" ]]; then
      cp "$release_cargo_config_backup" "$release_cargo_config_path" \
        || cleanup_failed=1
    else
      rm -f "$release_cargo_config_path" || cleanup_failed=1
    fi
    rm -f "$release_cargo_config_backup" || cleanup_failed=1
    release_cargo_config_backup=""
  fi
  if [[ -n "$release_cargo_lock_backup" ]]; then
    cp "$release_cargo_lock_backup" "$ROOT_DIR/Cargo.lock" \
      || cleanup_failed=1
    rm -f "$release_cargo_lock_backup" || cleanup_failed=1
    release_cargo_lock_backup=""
  fi
  if [[ -n "$release_cargo_wrapper_dir" ]]; then
    rm -rf "$release_cargo_wrapper_dir" || cleanup_failed=1
    release_cargo_wrapper_dir=""
  fi
  if [[ -n "$release_cargo_manifest_original_sha256" \
    && "$(release_file_sha256 "$ROOT_DIR/Cargo.toml")" \
      != "$release_cargo_manifest_original_sha256" ]]
  then
    echo "Release gate failed to restore the original Cargo.toml." >&2
    cleanup_failed=1
  fi
  if [[ -n "$release_cargo_lock_original_sha256" \
    && "$(release_file_sha256 "$ROOT_DIR/Cargo.lock")" \
      != "$release_cargo_lock_original_sha256" ]]
  then
    echo "Release gate failed to restore the original Cargo.lock." >&2
    cleanup_failed=1
  fi
  unset NVPN_LOCAL_FIPS_PATCH_PRECONFIGURED
  unset NVPN_LOCAL_FIPS_SESSION_CARGO_TOML_SHA256
  unset NVPN_LOCAL_FIPS_SESSION_CARGO_LOCK_SHA256
  unset NVPN_LOCAL_FIPS_SESSION_FIPS_PATH_SHA256
  unset NVPN_LOCAL_FIPS_SESSION_FIPS_HEAD
  unset NVPN_LOCAL_FIPS_SESSION_FIPS_TREE
  return "$cleanup_failed"
}

install_release_cargo_wrapper() {
  if ((${#release_cargo_config_args[@]} == 0)) || [[ -n "$release_cargo_wrapper_dir" ]]; then
    return
  fi

  local real_cargo
  real_cargo="$(command -v cargo)"
  release_cargo_wrapper_dir="$(mktemp -d "${TMPDIR:-/tmp}/nvpn-release-gate-cargo.XXXXXX")"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'exec %q' "$real_cargo"
    printf ' %q' "${release_cargo_config_args[@]}"
    printf ' "$@"\n'
  } >"$release_cargo_wrapper_dir/cargo"
  chmod +x "$release_cargo_wrapper_dir/cargo"
  export PATH="$release_cargo_wrapper_dir:$PATH"
}

toml_string() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

install_release_cargo_config() {
  if ((${#release_cargo_config_args[@]} == 0)) || [[ -n "$release_cargo_config_backup" ]]; then
    return
  fi

  mkdir -p "$(dirname "$release_cargo_config_path")"
  release_cargo_config_backup="$(mktemp "${TMPDIR:-/tmp}/nvpn-release-gate-cargo-config.XXXXXX")"
  if [[ -f "$release_cargo_config_path" ]]; then
    release_cargo_config_existed=1
    cp "$release_cargo_config_path" "$release_cargo_config_backup"
  else
    release_cargo_config_existed=0
    : >"$release_cargo_config_backup"
  fi

  cat >"$release_cargo_config_path" <<EOF
[patch.crates-io]
fips-core = { path = $(toml_string "$release_fips_path/crates/fips-core") }
fips-endpoint = { path = $(toml_string "$release_fips_path/crates/fips-endpoint") }
fips-identity = { path = $(toml_string "$release_fips_path/crates/fips-identity") }
EOF
}

prepare_release_cargo_config() {
  if [[ -z "${NVPN_FIPS_REPO_PATH:-}" ]]; then
    return
  fi

  local fips_path="$NVPN_FIPS_REPO_PATH"
  local fips_head fips_tree
  if [[ ! -d "$fips_path" ]]; then
    echo "NVPN_FIPS_REPO_PATH does not exist: $fips_path" >&2
    exit 2
  fi
  fips_path="$(cd "$fips_path" && pwd -P)"
  release_fips_path="$fips_path"
  release_cargo_lock_original_sha256="$(release_file_sha256 "$ROOT_DIR/Cargo.lock")"
  release_cargo_manifest_original_sha256="$(release_file_sha256 "$ROOT_DIR/Cargo.toml")"
  for crate in fips-core fips-endpoint fips-identity; do
    if [[ ! -f "$fips_path/crates/$crate/Cargo.toml" ]]; then
      echo "NVPN_FIPS_REPO_PATH is missing crates/$crate/Cargo.toml: $fips_path" >&2
      exit 2
    fi
  done
  fips_head="$(git -C "$fips_path" rev-parse HEAD)" || {
    echo "NVPN_FIPS_REPO_PATH must be an exact Git checkout." >&2
    exit 2
  }
  require_exact_release_fips_revision "$fips_head" || exit 2
  fips_tree="$(git -C "$fips_path" rev-parse 'HEAD^{tree}')" || exit 2
  [[ -z "$(git -C "$fips_path" status --porcelain --untracked-files=all)" ]] || {
    echo "Release gate refuses a dirty local FIPS checkout." >&2
    exit 2
  }
  export NVPN_LOCAL_FIPS_SESSION_FIPS_HEAD="$fips_head"
  export NVPN_LOCAL_FIPS_SESSION_FIPS_TREE="$fips_tree"
  export NVPN_LOCAL_FIPS_SESSION_FIPS_PATH_SHA256="$(
    printf '%s' "$fips_path" | shasum -a 256 | awk '{print tolower($1)}'
  )"

  release_cargo_config_args+=(
    --config "patch.crates-io.fips-core.path=\"$fips_path/crates/fips-core\""
    --config "patch.crates-io.fips-endpoint.path=\"$fips_path/crates/fips-endpoint\""
    --config "patch.crates-io.fips-identity.path=\"$fips_path/crates/fips-identity\""
  )
  echo "Using local FIPS crates from $fips_path"
  case "${NVPN_PATCH_LOCAL_FIPS:-1}" in
    1|true|TRUE|True|yes|YES|Yes|on|ON|On)
      export NVPN_PATCH_LOCAL_FIPS=1
      echo "Using local FIPS crates in Docker e2e builds."
      ;;
    *)
      cat >&2 <<EOF
NVPN_FIPS_REPO_PATH requires NVPN_PATCH_LOCAL_FIPS=1 during the release gate so
Docker e2e builds test the same local FIPS crates as host Cargo.
EOF
      exit 2
      ;;
  esac
  install_release_cargo_config
  install_release_cargo_wrapper
  # Child mobile builders inherit the immutable Cargo patch above. Tell their
  # standalone local-FIPS helper not to append/restore the shared root manifest
  # while the Android and iOS physical lanes run concurrently.
  export NVPN_LOCAL_FIPS_PATCH_PRECONFIGURED=1

  release_cargo_lock_backup="$(mktemp "${TMPDIR:-/tmp}/nvpn-release-gate-Cargo.lock.XXXXXX")"
  cp "$ROOT_DIR/Cargo.lock" "$release_cargo_lock_backup"
  if release_cargo metadata --locked --format-version=1 >/dev/null 2>/dev/null; then
    export NVPN_LOCAL_FIPS_SESSION_CARGO_TOML_SHA256="$release_cargo_manifest_original_sha256"
    export NVPN_LOCAL_FIPS_SESSION_CARGO_LOCK_SHA256="$(
      release_file_sha256 "$ROOT_DIR/Cargo.lock"
    )"
    echo "Local FIPS crates satisfy existing Cargo.lock; skipping temporary lock refresh."
    return
  fi

  echo "Preparing temporary Cargo.lock for local FIPS path patches."
  release_cargo metadata --format-version=1 >/dev/null
  if ! release_cargo metadata --offline --format-version=1 >/dev/null; then
    cat >&2 <<EOF
Local FIPS crates do not satisfy Cargo.lock after a temporary metadata refresh.
Publish/update the FIPS crate versions and update nvpn's dependency/lock before
running the release gate with NVPN_FIPS_REPO_PATH.
EOF
    exit 2
  fi
  release_cargo_lock_args=(--offline)
  export NVPN_LOCAL_FIPS_SESSION_CARGO_TOML_SHA256="$release_cargo_manifest_original_sha256"
  export NVPN_LOCAL_FIPS_SESSION_CARGO_LOCK_SHA256="$(
    release_file_sha256 "$ROOT_DIR/Cargo.lock"
  )"
  echo "Using offline Cargo resolution for local FIPS path patches."
}

run_local_fips_regression_tests() {
  if [[ -z "$release_fips_path" ]]; then
    return
  fi

  (
    cd "$release_fips_path"
    cargo test -p fips-core overlay_adverts -- --nocapture
    cargo test -p fips-core update_peers -- --nocapture
    cargo test -p fips-core test_reply_learned_moves_configured_static_direct_peer_when_session_degraded -- --nocapture
    cargo test -p fips-core traversal_path_liveness_keeps_mobile_safe_floor -- --nocapture
    cargo test -p fips-core poll_nostr_discovery_configured_only_drops_nonconfigured_handoff -- --nocapture
    cargo test -p fips-core fresh_control_with_unreturned_endpoint_data_blocks_direct_without_known_fallback -- --nocapture
    cargo test -p fips-core outbound_fmp_send_does_not_refresh_direct_path_liveness -- --nocapture
    cargo test -p fips-core \
      proto::lookup::tests::initiate_reply_learned_keeps_configured_transit_inside_fanout_budget \
      -- --exact --nocapture
    cargo test -p fips-core \
      proto::lookup::tests::forward_reply_learned_keeps_configured_transit_inside_fanout_budget \
      -- --exact --nocapture
    cargo test -p fips-core \
      --test public_websocket_transit \
      persistent_two_seed_websocket_transit_survives_client_churn \
      -- --exact --nocapture
  )
}

release_cargo() {
  if ((${#release_cargo_config_args[@]})); then
    cargo "${release_cargo_config_args[@]}" "$@"
  else
    cargo "$@"
  fi
}

release_cargo_test_filter() (
  set -o pipefail
  local package="$1"
  local filter="$2"
  local output
  output="$(mktemp "${TMPDIR:-/tmp}/nvpn-release-gate-test.XXXXXX")"
  if ! release_cargo test "${release_cargo_lock_args[@]}" -p "$package" "$filter" 2>&1 \
    | tee "$output"; then
    rm -f "$output"
    return 1
  fi
  if ! grep -E "^test .*${filter} .*\\.\\.\\. ok$" "$output" >/dev/null; then
    printf 'Release gate test selector matched no passing test: %s (%s)\n' \
      "$filter" "$package" >&2
    rm -f "$output"
    return 1
  fi
  rm -f "$output"
)

run_release_gate_candidate_preflight() {
  if ! command -v rg >/dev/null 2>&1; then
    echo "Release gate requires ripgrep (rg) for source contract harnesses." >&2
    return 1
  fi
  node scripts/sync-versions.mjs --check
}

run_release_gate_static_preflight() {
  npm ci
  npm run check
  npm run build
  node --test scripts/local-release.test.mjs scripts/startos-release.test.mjs
  python3 scripts/test_appstore_draft_metadata.py
  if [[ "$(uname -s)" == "Darwin" ]]; then
    ./scripts/test-ios-appstore-policy.sh
  else
    echo "Skipping iOS App Store binary-policy gate on this non-Apple host."
  fi
  ./scripts/check-source-file-lines.sh
  ./scripts/test-release-gate-parallel-harness.sh
  ./scripts/test-local-fips-workspace-harness.sh
  ./scripts/test-idle-cpu-gate-harness.sh
  ./scripts/test-mobile-physical-device-selection-harness.sh
  ./scripts/test-mobile-ios-vpn-cleanup-harness.sh
  ./scripts/test-mobile-wireguard-exit-dns-harness.sh
  ./scripts/test-mobile-wireguard-fixture-cleanup-harness.sh
  ./scripts/test-mobile-release-provenance-harness.sh
  ./scripts/test-mobile-underlay-change-harness.sh
  ./scripts/test-mobile-release-join-gate-harness.sh
  ./scripts/test-macos-sdk-compat-harness.sh
  cargo fmt --check
}

run_rust_validation_lane() {
  ./scripts/security-audit-rust.sh
  run_local_fips_regression_tests
  release_cargo clippy "${release_cargo_lock_args[@]}" --workspace --all-targets -- -D warnings
  export RUST_MIN_STACK="${RUST_MIN_STACK:-8388608}"
  # This fixture contains a strict end-to-end latency assertion. Keep it out of
  # the workspace suite while the cold Docker image may be compiling, then run
  # and measure it once after joining that build below.
  release_cargo test "${release_cargo_lock_args[@]}" --workspace -- \
    --test-threads=1 \
    --skip websocket_seed_router_delivers_join_roster_to_guest_without_preconfigured_admin \
    --skip websocket_seed_router_retries_durable_join_receipt_after_first_route_failure \
    --skip websocket_seed_router_delivers_durable_join_receipt_after_tunnel_restart \
    --skip desktop_mobile_manual_join_desktop_admin_to_mobile_joiner \
    --skip desktop_mobile_manual_join_mobile_admin_to_desktop_joiner
  # Mobile VPN basics run without requiring a device/emulator: join over FIPS,
  # MagicDNS from TUN, exit DNS policy, and Android WG socket startup ordering.
  release_cargo_test_filter nostr-vpn-app-core mobile_join_request_sends_and_records_over_real_fips_endpoint
  # Cross the desktop-daemon/mobile-tunnel boundary with each side acting as
  # admin once. Both paths require the joiner to persist the exact signed roster
  # before acknowledging it, and the sender must consume its durable outbox.
  release_cargo_test_filter nostr-vpn-app-core desktop_mobile_manual_join_desktop_admin_to_mobile_joiner
  release_cargo_test_filter nostr-vpn-app-core desktop_mobile_manual_join_mobile_admin_to_desktop_joiner
  ./scripts/e2e-manual-join-cli.sh
  release_cargo_test_filter nostr-vpn-app-core mobile_magic_dns_answers_peer_name_from_tun_packet
  release_cargo_test_filter nostr-vpn-app-core mobile_config_wireguard_exit_keeps_local_stub_and_uses_profile_dns_only_while_active
  release_cargo_test_filter nostr-vpn-core exit_dns_supported_policy_matrix_selects_exact_resolver
  release_cargo_test_filter nostr-vpn-app-core settings_patch_validates_exit_dns_atomically_and_exposes_saved_policy
  release_cargo_test_filter nostr-vpn-app-core settings_patch_persists_every_exit_dns_option
  release_cargo_test_filter nostr-vpn-app-core mobile_wireguard_start_returns_before_handshake_watchdog
  release_cargo_test_filter nostr-vpn-app-core mobile_fips_exit_node_routes_default_traffic_to_selected_member
  # Shared userspace WG dataplane, including the mpsc channel path used by
  # Android VpnService and iOS NEPacketTunnelProvider.
  release_cargo_test_filter nostr-vpn-core channels_round_trip_plaintext_packets_against_paired_responder
  ./scripts/e2e-update-cli.sh
}

run_android_static_validation_lane() {
  command -v gradle >/dev/null 2>&1 || {
    echo "Android static validation requires Gradle on PATH." >&2
    return 1
  }
  # Kotlin compilation, unit tests, and Android lint do not need to rebuild the
  # Rust shared library. Keep this lane independent from Cargo so it can overlap
  # the longer Rust validation lane without sharing build outputs.
  gradle -p android \
    :app:lintDebug \
    :app:testDebugUnitTest \
    -x buildRustArm64
}

windows_ssh_command() {
  local host="$1"
  WINDOWS_SSH_CMD=(ssh -o BatchMode=yes -o ConnectTimeout=5)
  if [[ -n "${NVPN_WINDOWS_SSH_PROXY_COMMAND:-}" ]]; then
    WINDOWS_SSH_CMD+=(-o "ProxyCommand=${NVPN_WINDOWS_SSH_PROXY_COMMAND}")
  elif [[ -n "${NVPN_WINDOWS_SSH_JUMP:-}" ]]; then
    WINDOWS_SSH_CMD+=(-J "$NVPN_WINDOWS_SSH_JUMP")
  fi
  WINDOWS_SSH_CMD+=("$host")
}

windows_vm_reachable() {
  local host="$1"
  [[ -n "$host" ]] || return 1
  windows_ssh_command "$host"
  "${WINDOWS_SSH_CMD[@]}" hostname >/dev/null 2>&1
}

run_auto_windows_vm_app_smoke() {
  local host="${NVPN_WINDOWS_SSH_HOST:-}"
  if windows_vm_reachable "$host"; then
    release_gate_run_with_timeout "Windows VM app launch smoke" "$WINDOWS_GUI_SMOKE_TIMEOUT_SECS" \
      ./scripts/windows-vm-app-launch-smoke.sh "$host"
  else
    echo "Skipping Windows VM app launch smoke because ssh $host is unreachable."
  fi
}

run_auto_windows_vm_wireguard_exit_e2e() {
  local host="${NVPN_WINDOWS_SSH_HOST:-}"
  if windows_vm_reachable "$host"; then
    release_gate_run_with_timeout "Windows WG exit e2e" "$WINDOWS_WG_EXIT_TIMEOUT_SECS" \
      ./scripts/windows-vm-wireguard-exit-e2e.sh "$host"
  else
    echo "Skipping Windows WG exit e2e because ssh $host is unreachable."
  fi
}

run_auto_windows_vm_manual_join_ui_e2e() {
  local host="${NVPN_WINDOWS_SSH_HOST:-}"
  if windows_vm_reachable "$host"; then
    release_gate_run_with_timeout "Windows manual-join UI e2e" \
      "$DESKTOP_MANUAL_JOIN_UI_TIMEOUT_SECS" \
      ./scripts/windows-vm-manual-join-e2e.sh "$host"
  else
    echo "Skipping Windows manual-join UI e2e because ssh $host is unreachable."
  fi
}

run_auto_windows_vm_service_toggle_e2e() {
  local host="${NVPN_WINDOWS_SSH_HOST:-}"
  if windows_vm_reachable "$host"; then
    release_gate_run_with_timeout "Windows service-toggle UAC e2e" \
      "$DESKTOP_SERVICE_TOGGLE_TIMEOUT_SECS" \
      ./scripts/windows-vm-service-toggle-e2e.sh "$host"
  else
    echo "Skipping Windows service-toggle UAC e2e because ssh $host is unreachable."
  fi
}

release_gate_mode_disabled() {
  case "${1:-}" in
    0|false|FALSE|False|no|NO|No|off|OFF|Off) return 0 ;;
    *) return 1 ;;
  esac
}

windows_platform_lane_requested() {
  ! release_gate_mode_disabled "${NVPN_RELEASE_GATE_WINDOWS_WG_EXIT_E2E:-auto}" \
    || ! release_gate_mode_disabled "${NVPN_RELEASE_GATE_WINDOWS_GUI_SMOKE:-auto}" \
    || ! release_gate_mode_disabled "${NVPN_RELEASE_GATE_WINDOWS_MANUAL_JOIN_UI_E2E:-required}" \
    || ! release_gate_mode_disabled "${NVPN_RELEASE_GATE_WINDOWS_SERVICE_TOGGLE_E2E:-required}"
}

prepare_windows_platform_lane_sync() {
  WINDOWS_LANE_PRE_SYNCED=0
  windows_platform_lane_requested || return 0

  local host="${NVPN_WINDOWS_SSH_HOST:-}"
  if windows_vm_reachable "$host"; then
    ./scripts/windows-vm-git-sync.sh "$host"
    WINDOWS_LANE_PRE_SYNCED=1
  fi
}

run_windows_wireguard_exit_gate() {
  case "${NVPN_RELEASE_GATE_WINDOWS_WG_EXIT_E2E:-auto}" in
    0|false|FALSE|False|no|NO|No|off|OFF|Off)
      echo "Skipping Windows WG exit e2e because NVPN_RELEASE_GATE_WINDOWS_WG_EXIT_E2E=${NVPN_RELEASE_GATE_WINDOWS_WG_EXIT_E2E}"
      ;;
    1|true|TRUE|True|yes|YES|Yes|on|ON|On|windows-vm)
      release_gate_run_with_timeout "Windows WG exit e2e" "$WINDOWS_WG_EXIT_TIMEOUT_SECS" \
        ./scripts/windows-vm-wireguard-exit-e2e.sh "${NVPN_WINDOWS_SSH_HOST:-}"
      ;;
    auto|AUTO|Auto|"")
      run_auto_windows_vm_wireguard_exit_e2e
      ;;
    *)
      echo "Unsupported NVPN_RELEASE_GATE_WINDOWS_WG_EXIT_E2E=${NVPN_RELEASE_GATE_WINDOWS_WG_EXIT_E2E}" >&2
      return 2
      ;;
  esac
}

run_windows_app_launch_gate() {
  local mode="${NVPN_RELEASE_GATE_WINDOWS_GUI_SMOKE:-auto}"
  case "$mode" in
    0|false|FALSE|False|no|NO|No|off|OFF|Off)
      echo "Skipping Windows app launch smoke because NVPN_RELEASE_GATE_WINDOWS_GUI_SMOKE=$mode"
      ;;
    1|true|TRUE|True|yes|YES|Yes|on|ON|On|windows-vm)
      release_gate_run_with_timeout "Windows VM app launch smoke" "$WINDOWS_GUI_SMOKE_TIMEOUT_SECS" \
        ./scripts/windows-vm-app-launch-smoke.sh "${NVPN_WINDOWS_SSH_HOST:-}"
      ;;
    auto|AUTO|Auto|"")
      run_auto_windows_vm_app_smoke
      ;;
    *)
      echo "Unsupported NVPN_RELEASE_GATE_WINDOWS_GUI_SMOKE=$mode" >&2
      return 2
      ;;
  esac
}

run_windows_manual_join_ui_gate() {
  local mode="${NVPN_RELEASE_GATE_WINDOWS_MANUAL_JOIN_UI_E2E:-required}"
  local host="${NVPN_WINDOWS_SSH_HOST:-}"
  case "$mode" in
    0|false|FALSE|False|no|NO|No|off|OFF|Off)
      echo "Skipping Windows manual-join UI e2e because NVPN_RELEASE_GATE_WINDOWS_MANUAL_JOIN_UI_E2E=$mode"
      ;;
    1|true|TRUE|True|yes|YES|Yes|on|ON|On|windows-vm|required)
      windows_vm_reachable "$host" \
        || { echo "Required Windows manual-join UI VM is unreachable: $host" >&2; return 1; }
      release_gate_run_with_timeout "Windows manual-join UI e2e" \
        "$DESKTOP_MANUAL_JOIN_UI_TIMEOUT_SECS" \
        ./scripts/windows-vm-manual-join-e2e.sh "$host"
      ;;
    auto|AUTO|Auto|"")
      run_auto_windows_vm_manual_join_ui_e2e
      ;;
    *)
      echo "Unsupported NVPN_RELEASE_GATE_WINDOWS_MANUAL_JOIN_UI_E2E=$mode" >&2
      return 2
      ;;
  esac
}

run_windows_service_toggle_gate() {
  local mode="${NVPN_RELEASE_GATE_WINDOWS_SERVICE_TOGGLE_E2E:-required}"
  local host="${NVPN_WINDOWS_SSH_HOST:-}"
  case "$mode" in
    0|false|FALSE|False|no|NO|No|off|OFF|Off)
      echo "Skipping Windows service-toggle UAC e2e because NVPN_RELEASE_GATE_WINDOWS_SERVICE_TOGGLE_E2E=$mode"
      ;;
    1|true|TRUE|True|yes|YES|Yes|on|ON|On|windows-vm|required)
      windows_vm_reachable "$host" \
        || { echo "Required Windows service-toggle VM is unreachable: $host" >&2; return 1; }
      release_gate_run_with_timeout "Windows service-toggle UAC e2e" \
        "$DESKTOP_SERVICE_TOGGLE_TIMEOUT_SECS" \
        ./scripts/windows-vm-service-toggle-e2e.sh "$host"
      ;;
    auto|AUTO|Auto|"")
      run_auto_windows_vm_service_toggle_e2e
      ;;
    *)
      echo "Unsupported NVPN_RELEASE_GATE_WINDOWS_SERVICE_TOGGLE_E2E=$mode" >&2
      return 2
      ;;
  esac
}

run_windows_platform_lane() {
  prepare_windows_platform_lane_sync
  if [[ "${WINDOWS_LANE_PRE_SYNCED:-0}" == "1" ]]; then
    export NVPN_WINDOWS_SKIP_GIT_SYNC=1
  fi
  run_windows_wireguard_exit_gate
  run_windows_app_launch_gate
  run_windows_manual_join_ui_gate
  if ! release_gate_mode_disabled \
    "${NVPN_RELEASE_GATE_WINDOWS_MANUAL_JOIN_UI_E2E:-required}"
  then
    export NVPN_WINDOWS_SERVICE_TOGGLE_SKIP_BUILD=1
  fi
  run_windows_service_toggle_gate
}

macos_vm_reachable() {
  [[ -n "${NVPN_MACOS_SSH_HOST:-}" ]] || return 1
  ssh -o BatchMode=yes -o ConnectTimeout=5 \
    "$NVPN_MACOS_SSH_HOST" hostname >/dev/null 2>&1
}

macos_platform_lane_requested() {
  ! release_gate_mode_disabled "${NVPN_RELEASE_GATE_MACOS_MANUAL_JOIN_UI_E2E:-required}" \
    || ! release_gate_mode_disabled "${NVPN_RELEASE_GATE_MACOS_SERVICE_TOGGLE_E2E:-required}"
}

prepare_macos_platform_lane_sync() {
  MACOS_PLATFORM_LANE_PRE_SYNCED=0
  macos_platform_lane_requested || return 0
  if macos_vm_reachable; then
    if [[ -n "${NVPN_FIPS_REPO_PATH:-}" ]]; then
      NVPN_MACOS_SYNC_PATH_DEPS=1 \
        ./scripts/macos-vm-git-sync.sh "${NVPN_MACOS_SSH_HOST:-}"
    else
      ./scripts/macos-vm-git-sync.sh "${NVPN_MACOS_SSH_HOST:-}"
    fi
    MACOS_PLATFORM_LANE_PRE_SYNCED=1
  fi
}

run_macos_manual_join_ui_gate() {
  local mode="${NVPN_RELEASE_GATE_MACOS_MANUAL_JOIN_UI_E2E:-required}"
  if [[ "${MACOS_PLATFORM_LANE_PRE_SYNCED:-0}" == "1" ]]; then
    export NVPN_MACOS_SKIP_GIT_SYNC=1
  fi
  case "$mode" in
    0|false|FALSE|False|no|NO|No|off|OFF|Off)
      echo "Skipping macOS manual-join UI e2e because NVPN_RELEASE_GATE_MACOS_MANUAL_JOIN_UI_E2E=$mode"
      ;;
    1|true|TRUE|True|yes|YES|Yes|on|ON|On|macos-vm|required)
      macos_vm_reachable \
        || { echo "Required macOS manual-join UI VM is unreachable." >&2; return 1; }
      release_gate_run_with_timeout "macOS manual-join UI e2e" \
        "$DESKTOP_MANUAL_JOIN_UI_TIMEOUT_SECS" \
        ./scripts/macos-vm-manual-join-e2e.sh "${NVPN_MACOS_SSH_HOST:-}"
      ;;
    local)
      release_gate_run_with_timeout "macOS manual-join UI e2e" \
        "$DESKTOP_MANUAL_JOIN_UI_TIMEOUT_SECS" \
        ./scripts/e2e-macos-manual-join-ui.sh
      ;;
    auto|AUTO|Auto|"")
      if macos_vm_reachable; then
        release_gate_run_with_timeout "macOS manual-join UI e2e" \
          "$DESKTOP_MANUAL_JOIN_UI_TIMEOUT_SECS" \
          ./scripts/macos-vm-manual-join-e2e.sh "${NVPN_MACOS_SSH_HOST:-}"
      else
        echo "Skipping macOS manual-join UI e2e because its isolated VM is unreachable."
      fi
      ;;
    *)
      echo "Unsupported NVPN_RELEASE_GATE_MACOS_MANUAL_JOIN_UI_E2E=$mode" >&2
      return 2
      ;;
  esac
}

run_macos_service_toggle_gate() {
  local mode="${NVPN_RELEASE_GATE_MACOS_SERVICE_TOGGLE_E2E:-required}"
  if [[ "${MACOS_PLATFORM_LANE_PRE_SYNCED:-0}" == "1" ]]; then
    export NVPN_MACOS_SKIP_GIT_SYNC=1
  fi
  case "$mode" in
    0|false|FALSE|False|no|NO|No|off|OFF|Off)
      echo "Skipping macOS service-toggle Authorization e2e because NVPN_RELEASE_GATE_MACOS_SERVICE_TOGGLE_E2E=$mode"
      ;;
    1|true|TRUE|True|yes|YES|Yes|on|ON|On|macos-vm|required)
      macos_vm_reachable \
        || { echo "Required macOS service-toggle VM is unreachable." >&2; return 1; }
      release_gate_run_with_timeout "macOS service-toggle Authorization e2e" \
        "$DESKTOP_SERVICE_TOGGLE_TIMEOUT_SECS" \
        ./scripts/macos-vm-service-toggle-e2e.sh "${NVPN_MACOS_SSH_HOST:-}"
      ;;
    auto|AUTO|Auto|"")
      if macos_vm_reachable; then
        release_gate_run_with_timeout "macOS service-toggle Authorization e2e" \
          "$DESKTOP_SERVICE_TOGGLE_TIMEOUT_SECS" \
          ./scripts/macos-vm-service-toggle-e2e.sh "${NVPN_MACOS_SSH_HOST:-}"
      else
        echo "Skipping macOS service-toggle Authorization e2e because its isolated VM is unreachable."
      fi
      ;;
    *)
      echo "Unsupported NVPN_RELEASE_GATE_MACOS_SERVICE_TOGGLE_E2E=$mode" >&2
      return 2
      ;;
  esac
}

run_macos_platform_lane() {
  prepare_macos_platform_lane_sync
  run_macos_manual_join_ui_gate
  if ! release_gate_mode_disabled \
    "${NVPN_RELEASE_GATE_MACOS_MANUAL_JOIN_UI_E2E:-required}"
  then
    export NVPN_MACOS_SERVICE_TOGGLE_REUSE_BUILD=1
  fi
  run_macos_service_toggle_gate
}

ubuntu_vm_reachable() {
  [[ -n "${NVPN_UBUNTU_SSH_HOST:-}" ]] || return 1
  ssh -o BatchMode=yes -o ConnectTimeout=5 \
    "$NVPN_UBUNTU_SSH_HOST" hostname >/dev/null 2>&1
}

linux_platform_lane_requested() {
  ! release_gate_mode_disabled "${NVPN_RELEASE_GATE_LINUX_MANUAL_JOIN_UI_E2E:-required}" \
    || ! release_gate_mode_disabled "${NVPN_RELEASE_GATE_LINUX_SERVICE_TOGGLE_E2E:-required}"
}

prepare_linux_platform_lane_sync() {
  LINUX_PLATFORM_LANE_PRE_SYNCED=0
  linux_platform_lane_requested || return 0
  if ubuntu_vm_reachable; then
    ./scripts/ubuntu-vm-git-sync.sh \
      "${NVPN_UBUNTU_SSH_HOST:-}"
    LINUX_PLATFORM_LANE_PRE_SYNCED=1
  fi
}

run_linux_manual_join_ui_gate() {
  local mode="${NVPN_RELEASE_GATE_LINUX_MANUAL_JOIN_UI_E2E:-required}"
  local host="${NVPN_UBUNTU_SSH_HOST:-}"
  if [[ "${LINUX_PLATFORM_LANE_PRE_SYNCED:-0}" == "1" ]]; then
    export NVPN_UBUNTU_SKIP_GIT_SYNC=1
  fi
  case "$mode" in
    0|false|FALSE|False|no|NO|No|off|OFF|Off)
      echo "Skipping Linux manual-join UI e2e because NVPN_RELEASE_GATE_LINUX_MANUAL_JOIN_UI_E2E=$mode"
      ;;
    1|true|TRUE|True|yes|YES|Yes|on|ON|On|ubuntu-vm|required)
      ubuntu_vm_reachable \
        || { echo "Required Linux manual-join UI VM is unreachable: $host" >&2; return 1; }
      release_gate_run_with_timeout "Linux manual-join UI e2e" \
        "$DESKTOP_MANUAL_JOIN_UI_TIMEOUT_SECS" \
        ./scripts/ubuntu-vm-manual-join-e2e.sh "$host"
      ;;
    auto|AUTO|Auto|"")
      if ubuntu_vm_reachable; then
        release_gate_run_with_timeout "Linux manual-join UI e2e" \
          "$DESKTOP_MANUAL_JOIN_UI_TIMEOUT_SECS" \
          ./scripts/ubuntu-vm-manual-join-e2e.sh "$host"
      else
        echo "Skipping Linux manual-join UI e2e because its isolated VM is unreachable."
      fi
      ;;
    *)
      echo "Unsupported NVPN_RELEASE_GATE_LINUX_MANUAL_JOIN_UI_E2E=$mode" >&2
      return 2
      ;;
  esac
}

run_linux_service_toggle_gate() {
  local mode="${NVPN_RELEASE_GATE_LINUX_SERVICE_TOGGLE_E2E:-required}"
  local host="${NVPN_UBUNTU_SSH_HOST:-}"
  if [[ "${LINUX_PLATFORM_LANE_PRE_SYNCED:-0}" == "1" ]]; then
    export NVPN_UBUNTU_SKIP_GIT_SYNC=1
  fi
  case "$mode" in
    0|false|FALSE|False|no|NO|No|off|OFF|Off)
      echo "Skipping Linux service-toggle PolicyKit e2e because NVPN_RELEASE_GATE_LINUX_SERVICE_TOGGLE_E2E=$mode"
      ;;
    1|true|TRUE|True|yes|YES|Yes|on|ON|On|ubuntu-vm|required)
      ubuntu_vm_reachable \
        || { echo "Required Linux service-toggle VM is unreachable: $host" >&2; return 1; }
      release_gate_run_with_timeout "Linux service-toggle PolicyKit e2e" \
        "$DESKTOP_SERVICE_TOGGLE_TIMEOUT_SECS" \
        ./scripts/ubuntu-vm-service-toggle-e2e.sh "$host"
      ;;
    auto|AUTO|Auto|"")
      if ubuntu_vm_reachable; then
        release_gate_run_with_timeout "Linux service-toggle PolicyKit e2e" \
          "$DESKTOP_SERVICE_TOGGLE_TIMEOUT_SECS" \
          ./scripts/ubuntu-vm-service-toggle-e2e.sh "$host"
      else
        echo "Skipping Linux service-toggle PolicyKit e2e because its isolated VM is unreachable."
      fi
      ;;
    *)
      echo "Unsupported NVPN_RELEASE_GATE_LINUX_SERVICE_TOGGLE_E2E=$mode" >&2
      return 2
      ;;
  esac
}

run_linux_platform_lane() {
  prepare_linux_platform_lane_sync
  run_linux_manual_join_ui_gate
  if ! release_gate_mode_disabled \
    "${NVPN_RELEASE_GATE_LINUX_MANUAL_JOIN_UI_E2E:-required}"
  then
    export NVPN_UBUNTU_SKIP_BUILD=1
  fi
  run_linux_service_toggle_gate
}

release_gate_perf_output_dir() {
  if [[ -n "${NVPN_RELEASE_GATE_PERF_OUTPUT_DIR:-}" ]]; then
    printf '%s\n' "$NVPN_RELEASE_GATE_PERF_OUTPUT_DIR"
  elif [[ -n "${NVPN_PERF_OUTPUT_DIR:-}" ]]; then
    printf '%s\n' "$NVPN_PERF_OUTPUT_DIR"
  else
    printf '%s/artifacts/release-gate-nvpn-fips-perf-%s\n' \
      "$ROOT_DIR" "$(date -u +%Y%m%dT%H%M%SZ)"
  fi
}

run_wireguard_exit_platform_gates() {
  case "${NVPN_RELEASE_GATE_MACOS_WG_EXIT_E2E:-auto}" in
    0|false|FALSE|False|no|NO|No|off|OFF|Off)
      echo "Skipping macOS WG exit e2e because NVPN_RELEASE_GATE_MACOS_WG_EXIT_E2E=${NVPN_RELEASE_GATE_MACOS_WG_EXIT_E2E}"
      ;;
    1|true|TRUE|True|yes|YES|Yes|on|ON|On)
      release_gate_run_with_timeout "macOS WG exit e2e" "$MACOS_WG_EXIT_TIMEOUT_SECS" \
        ./scripts/e2e-wireguard-exit-host.sh
      ;;
    auto|AUTO|Auto|"")
      if [[ "$(uname -s)" == "Darwin" ]]; then
        if [[ "${EUID:-$(id -u)}" == "0" ]]; then
          release_gate_run_with_timeout "macOS WG exit e2e" "$MACOS_WG_EXIT_TIMEOUT_SECS" \
            ./scripts/e2e-wireguard-exit-host.sh
        else
          echo "Skipping macOS WG exit e2e in auto mode because privileged access is not predeclared."
          echo "Set NVPN_RELEASE_GATE_MACOS_WG_EXIT_E2E=1 to run the exact sudo-scoped test command."
        fi
      else
        echo "Skipping macOS WG exit e2e on this host."
      fi
      ;;
    *)
      echo "Unsupported NVPN_RELEASE_GATE_MACOS_WG_EXIT_E2E=${NVPN_RELEASE_GATE_MACOS_WG_EXIT_E2E}" >&2
      exit 2
      ;;
  esac

}

run_desktop_app_launch_smokes() {
  local linux_gui_smoke_default=1
  case "${NVPN_RELEASE_GATE_DOCKER_E2E:-1}" in
    0|false|FALSE|False|no|NO|No|off|OFF|Off)
      linux_gui_smoke_default=0
      ;;
  esac

  local linux_gui_smoke="${NVPN_RELEASE_GATE_LINUX_GUI_SMOKE:-$linux_gui_smoke_default}"
  case "$linux_gui_smoke" in
    0|false|FALSE|False|no|NO|No|off|OFF|Off)
      echo "Skipping Linux GUI launch smoke because NVPN_RELEASE_GATE_LINUX_GUI_SMOKE=$linux_gui_smoke"
      ;;
    *)
      if [[ -n "$release_fips_path" ]]; then
        release_gate_run_with_timeout "Linux GUI launch smoke" "$LINUX_GUI_SMOKE_TIMEOUT_SECS" \
          env NVPN_LINUX_NONINTERACTIVE=1 NVPN_LINUX_FIPS_REPO_PATH="$release_fips_path" \
          ./tools/run-linux env NVPN_PATCH_LOCAL_FIPS=1 NVPN_FIPS_REPO_PATH=/workspace/fips ./scripts/e2e-smoke.sh
      else
        release_gate_run_with_timeout "Linux GUI launch smoke" "$LINUX_GUI_SMOKE_TIMEOUT_SECS" \
          env NVPN_LINUX_NONINTERACTIVE=1 ./tools/run-linux ./scripts/e2e-smoke.sh
      fi
      ;;
  esac

  local macos_gui_smoke="${NVPN_RELEASE_GATE_MACOS_GUI_SMOKE:-auto}"
  case "$macos_gui_smoke" in
    0|false|FALSE|False|no|NO|No|off|OFF|Off)
      echo "Skipping macOS app launch smoke because NVPN_RELEASE_GATE_MACOS_GUI_SMOKE=$macos_gui_smoke"
      ;;
    1|true|TRUE|True|yes|YES|Yes|on|ON|On)
      release_gate_run_with_timeout "macOS app launch smoke" "$MACOS_GUI_SMOKE_TIMEOUT_SECS" \
        env NVPN_MACOS_RUST_PROFILE=release NVPN_MACOS_XCODE_CONFIGURATION=Release \
        ./scripts/macos-app-launch-smoke.sh
      ;;
    auto|AUTO|Auto|"")
      if [[ "$(uname -s)" == "Darwin" && -d "$ROOT_DIR/macos/Sources" ]]; then
        release_gate_run_with_timeout "macOS app launch smoke" "$MACOS_GUI_SMOKE_TIMEOUT_SECS" \
          env NVPN_MACOS_RUST_PROFILE=release NVPN_MACOS_XCODE_CONFIGURATION=Release \
          ./scripts/macos-app-launch-smoke.sh
      else
        echo "Skipping macOS app launch smoke on this host."
      fi
      ;;
    *)
      echo "Unsupported NVPN_RELEASE_GATE_MACOS_GUI_SMOKE=$macos_gui_smoke" >&2
      exit 2
      ;;
  esac

}

run_macos_daemon_idle_cpu_gate() {
  if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "Skipping macOS daemon idle CPU gate on this host."
    return
  fi
  local mode="${NVPN_RELEASE_GATE_MACOS_DAEMON_IDLE_CPU:-auto}"
  case "$mode" in
    0|false|FALSE|False|no|NO|No|off|OFF|Off)
      echo "Skipping macOS daemon idle CPU gate because NVPN_RELEASE_GATE_MACOS_DAEMON_IDLE_CPU=$mode"
      return
      ;;
    1|true|TRUE|True|yes|YES|Yes|on|ON|On)
      ;;
    auto|AUTO|Auto|"")
      if [[ "${EUID:-$(id -u)}" != "0" && "${CI:-}" != "true" ]]; then
        echo "Skipping isolated macOS service E2E on this developer host; run it on a root-capable macOS gate host."
        return
      fi
      ;;
    *)
      echo "Unsupported NVPN_RELEASE_GATE_MACOS_DAEMON_IDLE_CPU=$mode" >&2
      return 2
      ;;
  esac
  release_gate_run_with_timeout "macOS daemon idle CPU" "$MACOS_DAEMON_IDLE_CPU_TIMEOUT_SECS" \
    env NVPN_RUN_MACOS_SERVICE_E2E=1 ./scripts/e2e-macos-service.sh
}

release_gate_has_physical_ios_device() {
  local requested="${NVPN_IOS_DEVICE:-${NVPN_IOS_DEVICE_ID:-}}"
  [[ "$(uname -s)" == "Darwin" ]] || return 1
  if [[ -n "$requested" ]]; then
    xcrun devicectl device info details \
      --device "$requested" \
      --timeout 5 \
      --quiet >/dev/null 2>&1
    return
  fi
  xcrun xcdevice list --timeout 5 2>/dev/null | python3 -c '
import json
import sys

devices = json.load(sys.stdin)
raise SystemExit(
    0 if any(
        item.get("available") is True
        and item.get("simulator") is False
        and item.get("platform") == "com.apple.platform.iphoneos"
        for item in devices
    ) else 1
)
'
}

release_gate_select_android_idle_serial() {
  if [[ -n "${NVPN_ANDROID_SERIAL:-${ANDROID_SERIAL:-}}" ]]; then
    printf '%s\n' "${NVPN_ANDROID_SERIAL:-${ANDROID_SERIAL:-}}"
    return
  fi

  # Full release gates already require the physical Android device for the
  # exit and join lanes. Prefer it for the idle sample too: unrelated projects
  # commonly create and destroy default-port emulators, which can terminate a
  # healthy VPN process halfway through the measurement. Keep an emulator as
  # the explicit last choice for developer hosts without a phone attached.
  adb devices 2>/dev/null | awk '
    NR > 1 && $2 == "device" {
      if (first == "") first = $1
      if ($1 !~ /^emulator-/) {
        print $1
        selected = 1
        exit
      }
    }
    END { if (!selected && first != "") print first }
  '
}

run_mobile_idle_cpu_gates() {
  case "$NVPN_IDLE_CPU_GATE" in
    0|false|FALSE|False|no|NO|No|off|OFF|Off)
      echo "Skipping mobile idle CPU gates because NVPN_IDLE_CPU_GATE=$NVPN_IDLE_CPU_GATE"
      return
      ;;
  esac

  if [[ "$(uname -s)" == "Darwin" ]]; then
    release_gate_run_with_timeout "iOS simulator idle CPU smoke" "$MOBILE_GUI_SMOKE_TIMEOUT_SECS" \
      env NVPN_IOS_RUST_PROFILE=release ./scripts/mobile-ios-smoke.sh simulator
  else
    echo "Skipping iOS simulator idle CPU smoke on this host."
  fi

  if command -v adb >/dev/null 2>&1 \
    && adb devices 2>/dev/null | awk 'NR > 1 && $2 == "device" { found = 1 } END { exit !found }'; then
    local android_idle_serial
    android_idle_serial="$(release_gate_select_android_idle_serial)"
    [[ -n "$android_idle_serial" ]] || {
      echo "Android idle CPU smoke could not select an online device." >&2
      return 1
    }
    release_gate_run_with_timeout "Android idle CPU smoke" "$MOBILE_GUI_SMOKE_TIMEOUT_SECS" \
      env NVPN_ANDROID_DEBUG_RELEASE_SIGNING=1 \
      NVPN_ANDROID_SERIAL="$android_idle_serial" \
      NVPN_IDLE_CPU_MAX_PERCENT="$ANDROID_ACTIVE_OVERLAY_IDLE_CPU_MAX_PERCENT" \
      ./scripts/mobile-android-smoke.sh --vpn-cycle --create-network --accept-vpn-dialog
    MOBILE_ANDROID_APP_READY=1
  else
    echo "Skipping Android idle CPU smoke because no adb device is online."
  fi

  local ios_device="${NVPN_IOS_DEVICE:-${NVPN_IOS_DEVICE_ID:-}}"
  local ios_smoke_command=(./scripts/mobile-ios-smoke.sh device)
  if [[ -n "$ios_device" ]]; then
    ios_smoke_command+=(--device "$ios_device")
  fi
  ios_smoke_command+=(--install --create-network --vpn-cycle)
  if release_gate_has_physical_ios_device || [[ -n "$ios_device" ]]; then
    release_gate_run_with_timeout "iOS packet tunnel idle CPU" "$IOS_TUNNEL_IDLE_CPU_TIMEOUT_SECS" \
      env \
        NVPN_IOS_RUST_PROFILE=release \
        NVPN_IOS_IDLE_CPU_MAX_PERCENT="${NVPN_IOS_PACKET_TUNNEL_IDLE_CPU_MAX_PERCENT:-$NVPN_IDLE_CPU_MAX_PERCENT}" \
        NVPN_IOS_IDLE_CPU_SETTLE_SECONDS="${NVPN_IOS_PACKET_TUNNEL_IDLE_CPU_SETTLE_SECONDS:-15}" \
        NVPN_IOS_IDLE_CPU_SAMPLE_SECONDS="${NVPN_IOS_PACKET_TUNNEL_IDLE_CPU_SAMPLE_SECONDS:-60}" \
        "${ios_smoke_command[@]}"
    MOBILE_IOS_APP_READY=1
  else
    echo "Skipping iOS packet tunnel idle CPU gate because no physical device is online."
  fi
}

run_mobile_wireguard_exit_gates() {
  local mode="${NVPN_RELEASE_GATE_MOBILE_WG_EXIT_E2E:-auto}"
  local remote_native=0
  if [[ -n "${NVPN_MOBILE_WG_EXIT_FIXTURE_SSH_HOST:-}" \
    && "${NVPN_MOBILE_WG_EXIT_REMOTE_MODE:-native}" == "native" ]]
  then
    remote_native=1
  fi
  case "$mode" in
    0|false|FALSE|False|no|NO|No|off|OFF|Off)
      echo "Skipping mobile WireGuard exit e2e because NVPN_RELEASE_GATE_MOBILE_WG_EXIT_E2E=$mode"
      return
      ;;
    1|true|TRUE|True|yes|YES|Yes|on|ON|On)
      ;;
    auto|AUTO|Auto|"")
      if [[ "$(uname -s)" != "Darwin" ]] \
        || { [[ "$remote_native" -eq 0 ]] \
          && ! command -v docker >/dev/null 2>&1; } \
        || ! command -v wg >/dev/null 2>&1 \
        || ! command -v adb >/dev/null 2>&1 \
        || ! adb devices 2>/dev/null | awk 'NR > 1 && $2 == "device" && $1 !~ /^emulator-/ { found = 1 } END { exit !found }' \
        || ! release_gate_has_physical_ios_device
      then
        echo "Skipping mobile WireGuard exit e2e because both physical mobile devices and the local fixture tools are not available."
        return
      fi
      ;;
    *)
      echo "Unsupported NVPN_RELEASE_GATE_MOBILE_WG_EXIT_E2E=$mode" >&2
      exit 2
      ;;
  esac

  local image="${NVPN_MOBILE_WG_EXIT_IMAGE:-nostr-vpn-mobile-wireguard-exit-e2e}"
  local image_ready=0
  if [[ "$remote_native" -eq 0 ]]; then
    docker build -q \
      -f "$ROOT_DIR/Dockerfile.mobile-wireguard-exit-e2e" \
      -t "$image" \
      "$ROOT_DIR" >/dev/null
    image_ready=1
  fi

  local port_base="$((53000 + $$ % 1000 * 2))"
  local lanes=()
  release_gate_parallel_start \
    "Android physical WireGuard exit and DNS" \
    release_gate_run_with_timeout \
    "Android physical WireGuard exit and DNS" \
    "$MOBILE_WG_EXIT_TIMEOUT_SECS" \
    env \
      NVPN_IDLE_CPU_GATE=0 \
      NVPN_MOBILE_WG_EXIT_LIFECYCLE_GATE=0 \
      NVPN_MOBILE_WG_EXIT_IMAGE_READY="$image_ready" \
      NVPN_MOBILE_WG_EXIT_IMAGE="$image" \
      NVPN_MOBILE_WG_EXIT_CONTAINER="nostr-vpn-mobile-wg-release-android-$$" \
      NVPN_MOBILE_WG_EXIT_HOST_PORT="$port_base" \
      NVPN_MOBILE_WG_EXIT_SERVER_IP=10.99.77.1 \
      NVPN_MOBILE_WG_EXIT_CLIENT_IP=10.99.77.2 \
      NVPN_ANDROID_DEBUG_RELEASE_SIGNING=1 \
      NVPN_ANDROID_IDLE_CPU_MAX_PERCENT="$ANDROID_ACTIVE_OVERLAY_IDLE_CPU_MAX_PERCENT" \
      NVPN_MOBILE_WG_EXIT_INSTALL_ANDROID="$((1 - MOBILE_ANDROID_APP_READY))" \
      ./scripts/mobile-wireguard-exit-e2e.sh android
  lanes+=("$RELEASE_GATE_PARALLEL_LAST_INDEX")

  release_gate_parallel_start \
    "iOS physical WireGuard exit and DNS" \
    release_gate_run_with_timeout \
    "iOS physical WireGuard exit and DNS" \
    "$MOBILE_WG_EXIT_TIMEOUT_SECS" \
    env \
      NVPN_IDLE_CPU_GATE=0 \
      NVPN_MOBILE_WG_EXIT_LIFECYCLE_GATE=0 \
      NVPN_MOBILE_WG_EXIT_IMAGE_READY="$image_ready" \
      NVPN_MOBILE_WG_EXIT_IMAGE="$image" \
      NVPN_MOBILE_WG_EXIT_CONTAINER="nostr-vpn-mobile-wg-release-ios-$$" \
      NVPN_MOBILE_WG_EXIT_HOST_PORT="$((port_base + 1))" \
      NVPN_MOBILE_WG_EXIT_SERVER_IP=10.99.78.1 \
      NVPN_MOBILE_WG_EXIT_CLIENT_IP=10.99.78.2 \
      NVPN_MOBILE_WG_EXIT_INSTALL_IOS="$((1 - MOBILE_IOS_APP_READY))" \
      ./scripts/mobile-wireguard-exit-e2e.sh ios
  lanes+=("$RELEASE_GATE_PARALLEL_LAST_INDEX")

  release_gate_parallel_wait_group "${lanes[@]}"
  MOBILE_ANDROID_APP_READY=1
  MOBILE_IOS_APP_READY=1
}

run_mobile_underlay_change_gates() {
  local mode="${NVPN_RELEASE_GATE_MOBILE_UNDERLAY_E2E:-auto}"
  local managed_ap_configured=0
  if [[ -n "${NVPN_ANDROID_UNDERLAY_MANAGED_AP_SSH_HOST:-}" \
    && -n "${NVPN_ANDROID_UNDERLAY_MANAGED_AP_INTERFACE:-}" ]]
  then
    managed_ap_configured=1
  fi
  case "$mode" in
    0|false|FALSE|False|no|NO|No|off|OFF|Off)
      echo "Skipping physical mobile underlay-change e2e because NVPN_RELEASE_GATE_MOBILE_UNDERLAY_E2E=$mode"
      return
      ;;
    1|true|TRUE|True|yes|YES|Yes|on|ON|On)
      ;;
    auto|AUTO|Auto|"")
      if [[ -z "${NVPN_MOBILE_WG_EXIT_HOST_IP:-}" ]] \
        || { [[ "$managed_ap_configured" -eq 0 ]] \
          && { [[ -z "${NVPN_ANDROID_UNDERLAY_HOME_SSID:-}" ]] \
            || [[ -z "${NVPN_ANDROID_UNDERLAY_HOME_SECURITY:-}" ]] \
            || [[ -z "${NVPN_ANDROID_UNDERLAY_ALTERNATE_SSID:-}" ]] \
            || [[ -z "${NVPN_ANDROID_UNDERLAY_ALTERNATE_SECURITY:-}" ]]; }; }
      then
        echo "Skipping physical mobile underlay-change e2e because its env-only two-network fixture is not configured."
        return
      fi
      ;;
    *)
      echo "Unsupported NVPN_RELEASE_GATE_MOBILE_UNDERLAY_E2E=$mode" >&2
      return 2
      ;;
  esac
  local remote_native=0
  if [[ -n "${NVPN_MOBILE_WG_EXIT_FIXTURE_SSH_HOST:-}" \
    && "${NVPN_MOBILE_WG_EXIT_REMOTE_MODE:-native}" == "native" ]]
  then
    remote_native=1
  fi
  if [[ "$(uname -s)" != "Darwin" ]] \
    || ! command -v wg >/dev/null 2>&1 \
    || ! command -v adb >/dev/null 2>&1 \
    || ! adb devices 2>/dev/null | awk '
      NR > 1 && $2 == "device" && $1 !~ /^emulator-/ { found = 1 }
      END { exit !found }
    ' \
    || ! release_gate_has_physical_ios_device
  then
    echo "Physical mobile underlay-change e2e requires both unlocked phones, WireGuard tools, and adb." >&2
    return 1
  fi
  if [[ "$remote_native" -eq 0 ]] && ! command -v docker >/dev/null 2>&1; then
    echo "Physical mobile underlay-change local/Docker fixture requires Docker." >&2
    return 1
  fi

  local image="${NVPN_MOBILE_WG_EXIT_IMAGE:-nostr-vpn-mobile-wireguard-exit-e2e}"
  local image_ready=0
  if [[ "$remote_native" -eq 0 ]]; then
    docker build -q \
      -f "$ROOT_DIR/Dockerfile.mobile-wireguard-exit-e2e" \
      -t "$image" \
      "$ROOT_DIR" >/dev/null
    image_ready=1
  fi
  local port_base="$((55000 + $$ % 500 * 2))"

  # Keep both physical-device switches serial and isolated from all other phone
  # lanes. The iOS lane controls the Pixel hotspot only after the Android DUT
  # lane has completed.
  release_gate_run_with_timeout \
    "Android physical Wi-Fi underlay change" \
    "$MOBILE_WG_EXIT_TIMEOUT_SECS" \
    env \
      NVPN_IDLE_CPU_GATE=0 \
      NVPN_MOBILE_WG_EXIT_DNS_CASES=automatic-profile \
      NVPN_MOBILE_WG_EXIT_LIFECYCLE_GATE=1 \
      NVPN_MOBILE_WG_EXIT_UNDERLAY_CHANGE_GATE=1 \
      NVPN_MOBILE_WG_EXIT_IMAGE_READY="$image_ready" \
      NVPN_MOBILE_WG_EXIT_IMAGE="$image" \
      NVPN_MOBILE_WG_EXIT_CONTAINER="nostr-vpn-mobile-underlay-android-$$" \
      NVPN_MOBILE_WG_EXIT_HOST_PORT="$port_base" \
      NVPN_MOBILE_WG_EXIT_SERVER_IP=10.99.79.1 \
      NVPN_MOBILE_WG_EXIT_CLIENT_IP=10.99.79.2 \
      NVPN_ANDROID_DEBUG_RELEASE_SIGNING=1 \
      NVPN_MOBILE_WG_EXIT_REUSE_ANDROID_BUILD=1 \
      NVPN_MOBILE_WG_EXIT_INSTALL_ANDROID="$((1 - MOBILE_ANDROID_APP_READY))" \
      ./scripts/mobile-wireguard-exit-e2e.sh android
  MOBILE_ANDROID_APP_READY=1

  release_gate_run_with_timeout \
    "iOS physical Wi-Fi/Pixel-hotspot underlay change" \
    "$MOBILE_WG_EXIT_TIMEOUT_SECS" \
    env \
      NVPN_IDLE_CPU_GATE=0 \
      NVPN_MOBILE_WG_EXIT_DNS_CASES=automatic-profile \
      NVPN_MOBILE_WG_EXIT_LIFECYCLE_GATE=1 \
      NVPN_MOBILE_WG_EXIT_UNDERLAY_CHANGE_GATE=1 \
      NVPN_MOBILE_WG_EXIT_IMAGE_READY="$image_ready" \
      NVPN_MOBILE_WG_EXIT_IMAGE="$image" \
      NVPN_MOBILE_WG_EXIT_CONTAINER="nostr-vpn-mobile-underlay-ios-$$" \
      NVPN_MOBILE_WG_EXIT_HOST_PORT="$((port_base + 1))" \
      NVPN_MOBILE_WG_EXIT_SERVER_IP=10.99.80.1 \
      NVPN_MOBILE_WG_EXIT_CLIENT_IP=10.99.80.2 \
      NVPN_MOBILE_WG_EXIT_REUSE_IOS_BUILD=1 \
      NVPN_MOBILE_WG_EXIT_INSTALL_IOS="$((1 - MOBILE_IOS_APP_READY))" \
      ./scripts/mobile-wireguard-exit-e2e.sh ios
  MOBILE_IOS_APP_READY=1
}

run_android_legacy_replacement_gate() {
  local mode="${NVPN_RELEASE_GATE_ANDROID_LEGACY_REPLACEMENT_E2E:-auto}"
  case "$mode" in
    0|false|FALSE|False|no|NO|No|off|OFF|Off)
      echo "Skipping Android legacy-package replacement e2e because NVPN_RELEASE_GATE_ANDROID_LEGACY_REPLACEMENT_E2E=$mode"
      return
      ;;
    1|true|TRUE|True|yes|YES|Yes|on|ON|On)
      ;;
    auto|AUTO|Auto|"")
      if ! command -v adb >/dev/null 2>&1 \
        || ! adb devices 2>/dev/null | awk '
          NR > 1 && $2 == "device" && $1 !~ /^emulator-/ { found = 1 }
          END { exit !found }
        '
      then
        echo "Skipping Android legacy-package replacement e2e because no physical device is online."
        return
      fi
      ;;
    *)
      echo "Unsupported NVPN_RELEASE_GATE_ANDROID_LEGACY_REPLACEMENT_E2E=$mode" >&2
      return 2
      ;;
  esac

  release_gate_run_with_timeout \
    "Android legacy-package replacement e2e" \
    "$ANDROID_LEGACY_REPLACEMENT_TIMEOUT_SECS" \
    env NVPN_ANDROID_DEBUG_RELEASE_SIGNING=1 \
    NVPN_ANDROID_LEGACY_REUSE_CANONICAL_APK="$MOBILE_ANDROID_APP_READY" \
    ./scripts/mobile-android-legacy-replacement-e2e.sh
  MOBILE_ANDROID_APP_READY=1
}

run_mobile_join_e2e_gate() {
  local mode="${NVPN_RELEASE_GATE_MOBILE_JOIN_E2E:-required}"
  case "$mode" in
    0|false|FALSE|False|no|NO|No|off|OFF|Off)
      echo "Skipping signed Release cross-platform join e2e because NVPN_RELEASE_GATE_MOBILE_JOIN_E2E=$mode"
      return
      ;;
    1|true|TRUE|True|yes|YES|Yes|on|ON|On|required)
      [[ "$(uname -s)" == "Darwin" ]] \
        || { echo "Required signed Release join gate needs macOS/Xcode." >&2; return 1; }
      command -v adb >/dev/null 2>&1 \
        || { echo "Required signed Release join gate needs adb." >&2; return 1; }
      adb devices 2>/dev/null | awk \
        'NR > 1 && $2 == "device" && $1 !~ /^emulator-/ { found = 1 } END { exit !found }' \
        || { echo "Required signed Release join gate needs a physical Android phone." >&2; return 1; }
      release_gate_has_physical_ios_device \
        || { echo "Required signed Release join gate needs a physical iPhone." >&2; return 1; }
      macos_vm_reachable \
        || { echo "Required signed Release join gate needs the macOS VM." >&2; return 1; }
      ;;
    auto|AUTO|Auto|"")
      if [[ "$(uname -s)" != "Darwin" ]] \
        || ! command -v adb >/dev/null 2>&1 \
        || ! adb devices 2>/dev/null | awk 'NR > 1 && $2 == "device" && $1 !~ /^emulator-/ { found = 1 } END { exit !found }' \
        || ! release_gate_has_physical_ios_device \
        || ! macos_vm_reachable
      then
        echo "Skipping signed Release cross-platform join e2e because its phones or macOS VM are unavailable."
        return
      fi
      ;;
    *)
      echo "Unsupported NVPN_RELEASE_GATE_MOBILE_JOIN_E2E=$mode" >&2
      exit 2
      ;;
  esac

  release_gate_run_with_timeout \
    "Signed Release public-UI cross-platform join e2e" \
    "$MOBILE_JOIN_E2E_TIMEOUT_SECS" \
    env NVPN_RELEASE_JOIN_ALLOW_DEVICE_RESET=YES \
    NVPN_RELEASE_JOIN_DESKTOP_MOBILE=1 \
    ./scripts/mobile-release-join-e2e.sh
  MOBILE_ANDROID_APP_READY=1
  MOBILE_IOS_APP_READY=1
}

docker_release_gates_enabled() {
  ! release_gate_mode_disabled "${NVPN_RELEASE_GATE_DOCKER_E2E:-1}"
}

build_release_gate_docker_node_image() {
  docker compose \
    -p nostr-vpn-release-gate-image \
    -f "$ROOT_DIR/docker-compose.e2e.yml" \
    build node-a
}

run_docker_signal_gates() {
  if ! docker_release_gates_enabled; then
    echo "Skipping Docker e2e because NVPN_RELEASE_GATE_DOCKER_E2E=${NVPN_RELEASE_GATE_DOCKER_E2E}"
    return
  fi

  # The standalone topology test keeps its longer soak default. The release
  # gate needs a short continuity assertion here because roaming, loaded
  # liveness, and idle CPU each get dedicated longer measurements below.
  NVPN_E2E_CONTINUITY_SECS="${NVPN_RELEASE_GATE_CONTINUITY_SECS:-15}" \
    NVPN_FIPS_NOSTR_DISCOVERY_POLICY="${NVPN_FIPS_ROUTED_UDP_DISCOVERY_POLICY:-open}" \
    ./scripts/e2e-fips-routed-udp-docker.sh
  NVPN_FIPS_NOSTR_DISCOVERY_POLICY="${NVPN_FIPS_NOSTR_DISCOVERY_POLICY:-configured_only}" \
    ./scripts/e2e-fips-roaming-docker.sh
}

run_mobile_qr_join_latency_gate() {
  if release_gate_mode_disabled "${NVPN_RELEASE_GATE_QR_JOIN_LATENCY:-1}"; then
    echo "Skipping mobile QR-join latency gate on this uncalibrated host."
    return 0
  fi
  # These real public-WebSocket tests use timing ceilings and intentionally
  # interrupt/restart a tunnel. Run them together only after build contention
  # has ended so their delivery and durable-retry measurements remain useful.
  release_cargo_test_filter nostr-vpn-app-core \
    websocket_seed_router_delivers_join_roster_to_guest_without_preconfigured_admin
  release_cargo_test_filter nostr-vpn-app-core \
    websocket_seed_router_retries_durable_join_receipt_after_first_route_failure
  release_cargo_test_filter nostr-vpn-app-core \
    websocket_seed_router_delivers_durable_join_receipt_after_tunnel_restart
}

run_public_fips_transit_gate() {
  release_cargo test "${release_cargo_lock_args[@]}" \
    -p nostr-vpn-core \
    --test fips_public_transit \
    public_transit_routes_fips_control_by_npub_without_direct_peer_config \
    -- \
    --ignored \
    --test-threads=1
}

run_userspace_wireguard_exit_docker_gate() {
  # The kernel and userspace fixtures use the same Compose topology. Give the
  # userspace copy its own benchmark-network subnets so Docker can create both
  # projects concurrently without overlapping IPAM pools.
  env \
    NVPN_WG_EXIT_INTERNET_SUBNET="${NVPN_WG_EXIT_USERSPACE_INTERNET_SUBNET:-198.19.243.0/24}" \
    NVPN_WG_EXIT_PUBLIC_SUBNET="${NVPN_WG_EXIT_USERSPACE_PUBLIC_SUBNET:-198.19.244.0/24}" \
    NVPN_WG_EXIT_UPSTREAM_IP="${NVPN_WG_EXIT_USERSPACE_UPSTREAM_IP:-198.19.243.20}" \
    NVPN_WG_EXIT_UPSTREAM_PUBLIC_IP="${NVPN_WG_EXIT_USERSPACE_UPSTREAM_PUBLIC_IP:-198.19.244.20}" \
    NVPN_WG_EXIT_NODE_A_IP="${NVPN_WG_EXIT_USERSPACE_NODE_A_IP:-198.19.243.10}" \
    NVPN_WG_EXIT_NODE_B_IP="${NVPN_WG_EXIT_USERSPACE_NODE_B_IP:-198.19.243.11}" \
    NVPN_WG_EXIT_TARGET_IP="${NVPN_WG_EXIT_USERSPACE_TARGET_IP:-198.19.244.100}" \
    ./scripts/e2e-wireguard-exit-userspace-docker.sh
}

run_docker_isolated_functional_gates() {
  docker_release_gates_enabled || return 0

  local lanes=()
  release_gate_parallel_start "Docker NAT-safe MTU" \
    env NVPN_E2E_CONTINUITY_SECS="${NVPN_RELEASE_GATE_CONTINUITY_SECS:-15}" \
    NVPN_FIPS_NOSTR_DISCOVERY_POLICY="${NVPN_FIPS_NOSTR_DISCOVERY_POLICY:-configured_only}" \
    ./scripts/e2e-fips-nat-safe-mtu-docker.sh
  lanes+=("$RELEASE_GATE_PARALLEL_LAST_INDEX")

  release_gate_parallel_start "Docker kernel WireGuard exit" \
    ./scripts/e2e-wireguard-exit-docker.sh
  lanes+=("$RELEASE_GATE_PARALLEL_LAST_INDEX")

  release_gate_parallel_start "Docker userspace WireGuard exit" \
    run_userspace_wireguard_exit_docker_gate
  lanes+=("$RELEASE_GATE_PARALLEL_LAST_INDEX")

  release_gate_parallel_start "Web/StartOS real manual join" \
    ./scripts/e2e-web-startos-manual-join-docker.sh
  lanes+=("$RELEASE_GATE_PARALLEL_LAST_INDEX")

  release_gate_parallel_wait_group "${lanes[@]}"
}

run_docker_perf_gate() {
  docker_release_gates_enabled || return 0
  case "${NVPN_RELEASE_GATE_PERF_E2E:-1}" in
    0|false|FALSE|False|no|NO|No|off|OFF|Off)
      echo "Skipping Docker perf regression e2e because NVPN_RELEASE_GATE_PERF_E2E=${NVPN_RELEASE_GATE_PERF_E2E}"
      ;;
    *)
      local perf_output_dir
      perf_output_dir="$(release_gate_perf_output_dir)"
      echo "Writing Docker nvpn+FIPS perf artifacts to $perf_output_dir"
      NVPN_FIPS_NOSTR_DISCOVERY_POLICY="${NVPN_FIPS_NOSTR_DISCOVERY_POLICY:-configured_only}" \
        NVPN_PERF_OUTPUT_DIR="$perf_output_dir" \
        ./scripts/e2e-fips-perf-regression-docker.sh
      ;;
  esac
}

release_gate_cleanup() {
  local status="$?" cleanup_failed=0
  trap - EXIT
  release_gate_parallel_cancel_all
  restore_release_cargo_lock || cleanup_failed=1
  if [[ "$status" -eq 0 && "$cleanup_failed" -ne 0 ]]; then
    status=1
  fi
  exit "$status"
}

main() {
  local started_at
  started_at="$(date +%s)"
  local log_dir="${NVPN_RELEASE_GATE_LOG_DIR:-$ROOT_DIR/artifacts/release-gate-logs/$(date -u +%Y%m%dT%H%M%SZ)}"
  release_gate_parallel_init "$log_dir"
  trap release_gate_cleanup EXIT

  # Validate generated version metadata before any remote lane snapshots the
  # candidate. The remaining preflight leaves tracked source unchanged and can
  # overlap work on resource-isolated remote hosts.
  run_release_gate_candidate_preflight

  local windows_lane=""
  if windows_platform_lane_requested; then
    release_gate_parallel_start "Windows platform" run_windows_platform_lane
    windows_lane="$RELEASE_GATE_PARALLEL_LAST_INDEX"
  fi

  local macos_platform_lane=""
  if macos_platform_lane_requested; then
    release_gate_parallel_start "macOS platform UI" run_macos_platform_lane
    macos_platform_lane="$RELEASE_GATE_PARALLEL_LAST_INDEX"
  fi

  local linux_platform_lane=""
  if linux_platform_lane_requested; then
    release_gate_parallel_start "Linux platform UI" run_linux_platform_lane
    linux_platform_lane="$RELEASE_GATE_PARALLEL_LAST_INDEX"
  fi

  run_release_gate_static_preflight

  release_gate_parallel_start \
    "Android compile, unit tests, and lint" \
    run_android_static_validation_lane
  local android_static_lane="$RELEASE_GATE_PARALLEL_LAST_INDEX"

  prepare_release_cargo_config

  # The remote Windows lane and the shared Docker image build do not consume
  # measurement devices. Build them alongside host Rust validation, then join
  # the image before any Docker functional/performance test starts.
  local docker_build_lane=""
  if docker_release_gates_enabled; then
    export NVPN_E2E_NODE_IMAGE="${NVPN_RELEASE_GATE_E2E_NODE_IMAGE:-${NVPN_E2E_NODE_IMAGE:-nostr-vpn-e2e-node}}"
    export NVPN_EXIT_NODE_E2E_IMAGE="$NVPN_E2E_NODE_IMAGE"
    release_gate_parallel_start "Docker node image build" build_release_gate_docker_node_image
    docker_build_lane="$RELEASE_GATE_PARALLEL_LAST_INDEX"
  fi

  run_rust_validation_lane
  release_gate_parallel_wait "$android_static_lane"

  if [[ -n "$docker_build_lane" ]]; then
    release_gate_parallel_wait "$docker_build_lane"
    export NVPN_E2E_SKIP_NODE_BUILD=1
    export NVPN_PERF_SKIP_BUILD=1
  fi

  run_mobile_qr_join_latency_gate
  run_public_fips_transit_gate

  # Routed idle CPU and roaming remain serial. The remaining functional Docker
  # projects have isolated names/subnets and no timing assertions, so overlap
  # them and join before throughput or any host/device measurement begins.
  run_docker_signal_gates
  run_docker_isolated_functional_gates
  run_docker_perf_gate
  ./scripts/release-gate-host-pair-latency.sh
  ./scripts/release-gate-host-pair-loaded-latency.sh
  run_wireguard_exit_platform_gates
  run_desktop_app_launch_smokes
  run_macos_daemon_idle_cpu_gate
  run_mobile_idle_cpu_gates
  run_android_legacy_replacement_gate
  run_mobile_wireguard_exit_gates
  run_mobile_underlay_change_gates

  # The signed Release join lane covers both mobile role directions, both
  # manual role directions, and desktop/mobile manual join. It shares the
  # isolated macOS VM with its platform lane, so join that lane first.
  if [[ -n "$macos_platform_lane" ]]; then
    release_gate_parallel_wait "$macos_platform_lane"
    macos_platform_lane=""
  fi
  run_mobile_join_e2e_gate

  if [[ -n "$windows_lane" ]]; then
    release_gate_parallel_wait "$windows_lane"
  fi
  if [[ -n "$linux_platform_lane" ]]; then
    release_gate_parallel_wait "$linux_platform_lane"
  fi

  local elapsed target_status
  elapsed="$(( $(date +%s) - started_at ))"
  if (( elapsed <= RELEASE_GATE_TARGET_SECS )); then
    target_status="met"
  else
    target_status="missed"
  fi
  python3 - "$log_dir/release-gate-summary.json" "$elapsed" \
    "$RELEASE_GATE_TARGET_SECS" "$target_status" <<'PY'
import json, sys

path, elapsed, target, status = sys.argv[1:]
with open(path, "w", encoding="utf-8") as fh:
    json.dump({
        "elapsedSeconds": int(elapsed),
        "targetSeconds": int(target),
        "targetStatus": status,
    }, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
  printf 'Release gate passed in %ss; %ss target %s. Lane logs and summary: %s\n' \
    "$elapsed" "$RELEASE_GATE_TARGET_SECS" "$target_status" "$log_dir"
}

main "$@"
