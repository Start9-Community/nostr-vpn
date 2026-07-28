#!/usr/bin/env bash
# Drive both shipped GTK manual-join roles, then prove the queued signed roster
# crosses the deployed public FIPS transit service and is durably acknowledged.
set -euo pipefail

ROOT_DIR="$(
  cd "${NVPN_REPO_ROOT:-$(dirname "${BASH_SOURCE[0]}")/../..}"
  pwd -P
)"
LINUX_DIR="$ROOT_DIR/linux"
ARTIFACT_DIR="${ARTIFACT_ROOT:-$ROOT_DIR/artifacts/linux-manual-join-ui}"
E2E_ROOT="/tmp/nostr-vpn-linux-manual-join-ui"
ADMIN_DATA_DIR="$E2E_ROOT/admin"
JOINER_DATA_DIR="$E2E_ROOT/joiner"
RESULT="$ARTIFACT_DIR/result.json"
APP_LOG="$ARTIFACT_DIR/app.log"
TIMEOUT_SECS="${NVPN_DESKTOP_MANUAL_JOIN_TIMEOUT_SECS:-20}"
RUNTIME_TIMEOUT_SECS="${NVPN_DESKTOP_MANUAL_JOIN_RUNTIME_TIMEOUT_SECS:-20}"
LINUX_CARGO_TARGET_DIR="${NVPN_LINUX_CARGO_TARGET_DIR:-$LINUX_DIR/target}"
ROOT_CARGO_TARGET_DIR="${NVPN_ROOT_CARGO_TARGET_DIR:-$LINUX_CARGO_TARGET_DIR}"
FIXTURE="${NVPN_LINUX_FIXTURE_PATH:-$ROOT_CARGO_TARGET_DIR/debug/examples/desktop_manual_join_e2e_fixture}"
NVPN="${NVPN_LINUX_NVPN_PATH:-$ROOT_CARGO_TARGET_DIR/debug/nvpn}"
APP="${NVPN_LINUX_APP_PATH:-$LINUX_CARGO_TARGET_DIR/debug/nostr-vpn}"
EXPLICIT_ARTIFACT_COUNT=0
[[ -z "${NVPN_LINUX_FIXTURE_PATH:-}" ]] || ((EXPLICIT_ARTIFACT_COUNT += 1))
[[ -z "${NVPN_LINUX_NVPN_PATH:-}" ]] || ((EXPLICIT_ARTIFACT_COUNT += 1))
[[ -z "${NVPN_LINUX_APP_PATH:-}" ]] || ((EXPLICIT_ARTIFACT_COUNT += 1))
[[ "$EXPLICIT_ARTIFACT_COUNT" == 0 || "$EXPLICIT_ARTIFACT_COUNT" == 3 ]] || {
  echo "Set all three explicit Linux app, CLI, and fixture paths together." >&2
  exit 2
}
cargo_config_args=()
app_pid=""
window_id=""
runtime_started_ms=""
delivery_started_ms=""
runtime_deadline_seconds=""

if [[ -n "${NVPN_FIPS_REPO_PATH:-}" ]]; then
  cargo_config_args+=(
    --config "patch.crates-io.fips-core.path=\"$NVPN_FIPS_REPO_PATH/crates/fips-core\""
    --config "patch.crates-io.fips-endpoint.path=\"$NVPN_FIPS_REPO_PATH/crates/fips-endpoint\""
    --config "patch.crates-io.fips-identity.path=\"$NVPN_FIPS_REPO_PATH/crates/fips-identity\""
  )
fi

cargo_run() {
  if ((${#cargo_config_args[@]})); then
    cargo "${cargo_config_args[@]}" "$@"
  else
    cargo "$@"
  fi
}

fixture_args=(
  --admin-data-dir "$ADMIN_DATA_DIR"
  --joiner-data-dir "$JOINER_DATA_DIR"
  --result "$RESULT"
)

stop_app() {
  if [[ -n "$app_pid" ]] && kill -0 "$app_pid" >/dev/null 2>&1; then
    kill "$app_pid" >/dev/null 2>&1 || true
    wait "$app_pid" >/dev/null 2>&1 || true
  fi
  app_pid=""
  window_id=""
  # A manual join starts the real approval transport. Stop only daemons whose
  # command line names one of this fixture's isolated config directories.
  pkill -f "nvpn.*$E2E_ROOT" >/dev/null 2>&1 || true
}

stop_runtime() {
  if [[ -x "${NVPN:-}" ]]; then
    sudo -n "$NVPN" stop --force --timeout-secs 5 \
      --config "$ADMIN_DATA_DIR/config.toml" >/dev/null 2>&1 || true
    sudo -n "$NVPN" stop --force --timeout-secs 5 \
      --config "$JOINER_DATA_DIR/config.toml" >/dev/null 2>&1 || true
  fi
}

cleanup() {
  stop_app
  stop_runtime
}
trap cleanup EXIT

rm -rf "$E2E_ROOT"
mkdir -p "$ARTIFACT_DIR" "$E2E_ROOT"
rm -f "$RESULT" "$APP_LOG" "$ARTIFACT_DIR"/*.png

cd "$ROOT_DIR"

sudo -n true >/dev/null 2>&1 || {
  echo "Linux real manual-join runtime gate requires passwordless sudo on the isolated VM." >&2
  exit 1
}

snapshot_default_route() {
  ip -j route show default | jq -S .
}

snapshot_dns() {
  if command -v resolvectl >/dev/null 2>&1 && resolvectl dns >/dev/null 2>&1; then
    # Ignore address-only tunnel links that have no resolver assignment.
    resolvectl dns |
      awk -F': ' 'NF >= 2 && length($2) > 0 { print }' |
      sort
  else
    cat /etc/resolv.conf
  fi
}

assert_direct_internet() {
  curl --fail --silent --show-error --max-time 8 \
    --output /dev/null https://connectivitycheck.gstatic.com/generate_204
}

now_millis() {
  python3 -c 'import time; print(time.time_ns() // 1_000_000)'
}

snapshot_default_route >"$ARTIFACT_DIR/default-route-before.json"
snapshot_dns >"$ARTIFACT_DIR/dns-before.txt"
assert_direct_internet

case "$EXPLICIT_ARTIFACT_COUNT:${NVPN_DESKTOP_MANUAL_JOIN_SKIP_BUILD:-0}" in
  3:*)
    for executable in "$FIXTURE" "$NVPN" "$APP"; do
      [[ -x "$executable" ]] || {
        echo "Imported Linux manual-join executable is missing: $executable" >&2
        exit 1
      }
    done
    ;;
  0:1|0:true|0:TRUE|0:True|0:yes|0:YES|0:Yes|0:on|0:ON|0:On)
    for executable in "$FIXTURE" "$NVPN" "$APP"; do
      [[ -x "$executable" ]] || {
        echo "Prebuilt Linux manual-join executable is missing: $executable" >&2
        exit 1
      }
    done
    ;;
  0:*)
    CARGO_TARGET_DIR="$ROOT_CARGO_TARGET_DIR" \
      cargo_run build -q -p nvpn
    CARGO_TARGET_DIR="$ROOT_CARGO_TARGET_DIR" \
      cargo_run build -q -p nostr-vpn-core \
        --example desktop_manual_join_e2e_fixture
    cd "$LINUX_DIR"
    CARGO_TARGET_DIR="$LINUX_CARGO_TARGET_DIR" cargo_run build -q
    ;;
esac
"$FIXTURE" prepare "${fixture_args[@]}"

read_metadata() {
  python3 - "$RESULT" "$1" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))[sys.argv[2]])
PY
}

ADMIN_NPUB="$(read_metadata adminNpub)"
JOINER_NPUB="$(read_metadata joinerNpub)"
MESH_NETWORK_ID="$(read_metadata meshNetworkId)"
JOINER_ALIAS="$(read_metadata joinerAlias)"

export DISPLAY="${DISPLAY:-:99}"
export GDK_BACKEND="${GDK_BACKEND:-x11}"
export GTK_A11Y=atspi
export NO_AT_BRIDGE=0

wait_for_window() {
  local deadline=$((SECONDS + TIMEOUT_SECS))
  while ((SECONDS < deadline)); do
    window_id="$(
      xdotool search --onlyvisible --pid "$app_pid" --name "^Nostr VPN$" \
        2>/dev/null | head -n 1 || true
    )"
    if [[ -n "$window_id" ]]; then
      return 0
    fi
    if ! kill -0 "$app_pid" >/dev/null 2>&1; then
      echo "Linux manual-join UI app exited before showing a window." >&2
      tail -n 120 "$APP_LOG" >&2 || true
      return 1
    fi
    sleep 0.1
  done
  echo "Linux manual-join UI window did not appear within ${TIMEOUT_SECS}s." >&2
  return 1
}

wait_for_fixture() {
  local command="$1"
  local label="$2"
  local deadline=$((SECONDS + TIMEOUT_SECS))
  while ((SECONDS < deadline)); do
    if "$FIXTURE" "$command" "${fixture_args[@]}" >/dev/null 2>&1; then
      return 0
    fi
    if ! kill -0 "$app_pid" >/dev/null 2>&1; then
      echo "Linux app exited before persisting the $label manual-join action." >&2
      tail -n 120 "$APP_LOG" >&2 || true
      return 1
    fi
    sleep 0.1
  done
  "$FIXTURE" "$command" "${fixture_args[@]}"
  echo "Linux UI did not persist the $label manual-join action within ${TIMEOUT_SECS}s." >&2
  return 1
}

wait_for_seed() {
  local data_dir="$1"
  local expected_seed="$2"
  local expected_url="$3"
  local label="$4"
  local status_file="$ARTIFACT_DIR/$label-status.json"
  local deadline="${runtime_deadline_seconds:-$((SECONDS + RUNTIME_TIMEOUT_SECS))}"
  while ((SECONDS < deadline)); do
    if sudo -n "$NVPN" status --json --discover-secs 0 \
      --config "$data_dir/config.toml" >"$status_file.tmp" 2>/dev/null \
      && jq -e \
        --arg seed "$expected_seed" \
        --arg address "websocket:$expected_url" \
        '
          .status_source == "daemon"
          and .daemon.running == true
          and .daemon.state.vpn_enabled == true
          and .daemon.state.vpn_active == true
          and (.daemon.state.fips_other_peer_count >= 1)
          and any(.daemon.state.fips_endpoint_peers[]?;
            .npub == $seed
            and any(.addresses[]?; .addr == $address))
        ' "$status_file.tmp" >/dev/null
    then
      mv "$status_file.tmp" "$status_file"
      return 0
    fi
    sleep 0.1
  done
  sudo -n "$NVPN" status --json --discover-secs 0 \
    --config "$data_dir/config.toml" >"$status_file" 2>&1 || true
  echo "$label did not authenticate its expected public FIPS seed within ${RUNTIME_TIMEOUT_SECS}s." >&2
  cat "$status_file" >&2
  return 1
}

start_runtime() {
  local data_dir="$1"
  local iface="$2"
  sudo -n "$NVPN" start --daemon --connect \
    --iface "$iface" \
    --config "$data_dir/config.toml"
}

wait_for_runtime_delivery() {
  local deadline="${runtime_deadline_seconds:-$((SECONDS + RUNTIME_TIMEOUT_SECS))}"
  while ((SECONDS < deadline)); do
    if sudo -n "$FIXTURE" verify-runtime "${fixture_args[@]}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  sudo -n "$FIXTURE" verify-runtime "${fixture_args[@]}"
  echo "Linux signed roster was not durably applied and acknowledged within ${RUNTIME_TIMEOUT_SECS}s." >&2
  return 1
}

launch_app() {
  local data_dir="$1"
  NVPN_APP_DATA_DIR="$data_dir" \
    NVPN_CLI_PATH="$NVPN" \
    "$APP" >>"$APP_LOG" 2>&1 &
  app_pid=$!
  wait_for_window
}

launch_app "$JOINER_DATA_DIR"
python3 "$ROOT_DIR/scripts/desktop-manual-join-atspi.py" joiner \
  --pid "$app_pid" \
  --window-id "$window_id" \
  --admin-npub "$ADMIN_NPUB" \
  --mesh-network-id "$MESH_NETWORK_ID"
wait_for_fixture verify-joiner joiner
import -window root "$ARTIFACT_DIR/joiner.png"
stop_app

launch_app "$ADMIN_DATA_DIR"
python3 "$ROOT_DIR/scripts/desktop-manual-join-atspi.py" admin \
  --pid "$app_pid" \
  --window-id "$window_id" \
  --joiner-npub "$JOINER_NPUB" \
  --joiner-alias "$JOINER_ALIAS"
wait_for_fixture verify-admin admin
import -window root "$ARTIFACT_DIR/admin.png"
"$FIXTURE" capture-delivery "${fixture_args[@]}"
stop_app

ADMIN_SEED_NPUB="$(read_metadata adminSeedNpub)"
ADMIN_SEED_URL="$(read_metadata adminSeedUrl)"
JOINER_SEED_NPUB="$(read_metadata joinerSeedNpub)"
JOINER_SEED_URL="$(read_metadata joinerSeedUrl)"
JOINER_HEX="$(read_metadata joinerHex)"

stop_runtime
runtime_started_ms="$(now_millis)"
runtime_deadline_seconds=$((SECONDS + RUNTIME_TIMEOUT_SECS))
start_runtime "$JOINER_DATA_DIR" "nvpnmj-joiner"

delivery_started_ms="$(now_millis)"
start_runtime "$ADMIN_DATA_DIR" "nvpnmj-admin"
# Both sides authenticate to different public seeds concurrently. The admin's
# durable outbox safely retains the delivery until the joiner route is ready.
wait_for_seed "$JOINER_DATA_DIR" "$JOINER_SEED_NPUB" "$JOINER_SEED_URL" joiner
wait_for_seed "$ADMIN_DATA_DIR" "$ADMIN_SEED_NPUB" "$ADMIN_SEED_URL" admin
wait_for_runtime_delivery
delivery_finished_ms="$(now_millis)"
runtime_elapsed_ms=$((delivery_finished_ms - runtime_started_ms))
runtime_ceiling_ms=$((RUNTIME_TIMEOUT_SECS * 1000))
if ((runtime_elapsed_ms > runtime_ceiling_ms)); then
  echo "Linux real manual join took ${runtime_elapsed_ms}ms; ceiling is ${runtime_ceiling_ms}ms." >&2
  exit 1
fi

sudo -n "$NVPN" status --json --discover-secs 0 \
  --config "$ADMIN_DATA_DIR/config.toml" >"$ARTIFACT_DIR/admin-status.json"
sudo -n "$NVPN" status --json --discover-secs 0 \
  --config "$JOINER_DATA_DIR/config.toml" >"$ARTIFACT_DIR/joiner-status.json"
sudo -n grep -Fq \
  "delivered and applied one signed join roster over FIPS-TCP to $JOINER_HEX" \
  "$ADMIN_DATA_DIR/daemon.log" || {
    echo "Linux admin daemon log lacks the real durable FIPS-TCP delivery receipt." >&2
    sudo -n tail -n 160 "$ADMIN_DATA_DIR/daemon.log" >&2 || true
    exit 1
  }
snapshot_default_route >"$ARTIFACT_DIR/default-route-active.json"
snapshot_dns >"$ARTIFACT_DIR/dns-active.txt"
cmp -s "$ARTIFACT_DIR/default-route-before.json" "$ARTIFACT_DIR/default-route-active.json" || {
  echo "Linux manual join changed the device's default route in Direct mode." >&2
  diff -u "$ARTIFACT_DIR/default-route-before.json" \
    "$ARTIFACT_DIR/default-route-active.json" >&2 || true
  exit 1
}
cmp -s "$ARTIFACT_DIR/dns-before.txt" "$ARTIFACT_DIR/dns-active.txt" || {
  echo "Linux manual join changed device DNS in Direct mode." >&2
  diff -u "$ARTIFACT_DIR/dns-before.txt" "$ARTIFACT_DIR/dns-active.txt" >&2 || true
  exit 1
}
assert_direct_internet

stop_runtime
snapshot_default_route >"$ARTIFACT_DIR/default-route-after.json"
snapshot_dns >"$ARTIFACT_DIR/dns-after.txt"
cmp -s "$ARTIFACT_DIR/default-route-before.json" "$ARTIFACT_DIR/default-route-after.json"
cmp -s "$ARTIFACT_DIR/dns-before.txt" "$ARTIFACT_DIR/dns-after.txt"
assert_direct_internet
for iface in nvpnmj-joiner nvpnmj-admin; do
  if ip link show "$iface" >/dev/null 2>&1; then
    echo "Linux manual-join cleanup left tunnel interface $iface behind." >&2
    exit 1
  fi
done
if sudo -n pgrep -af nvpn | grep -F -- "$ADMIN_DATA_DIR/config.toml" >/dev/null \
  || sudo -n pgrep -af nvpn | grep -F -- "$JOINER_DATA_DIR/config.toml" >/dev/null
then
  echo "Linux manual-join cleanup left an isolated nvpn daemon running." >&2
  sudo -n pgrep -af nvpn >&2 || true
  exit 1
fi

sudo -n install -m 0644 "$ADMIN_DATA_DIR/daemon.log" \
  "$ARTIFACT_DIR/admin-daemon.log"
sudo -n install -m 0644 "$JOINER_DATA_DIR/daemon.log" \
  "$ARTIFACT_DIR/joiner-daemon.log"
python3 - "$ARTIFACT_DIR/timings.json" \
  "$runtime_started_ms" "$delivery_started_ms" "$delivery_finished_ms" \
  "$runtime_ceiling_ms" <<'PY'
import json
import sys

runtime_started, delivery_started, delivery_finished, ceiling = map(int, sys.argv[2:])
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(
        {
            "runtimeStartToDurableAckMs": delivery_finished - runtime_started,
            "adminStartToDurableAckMs": delivery_finished - delivery_started,
            "ceilingMs": ceiling,
        },
        handle,
        indent=2,
    )
    handle.write("\n")
PY

echo "LINUX_DESKTOP_MANUAL_JOIN_UI_E2E_OK"
echo "Result: $RESULT"
