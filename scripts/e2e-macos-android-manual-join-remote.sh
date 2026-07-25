#!/usr/bin/env bash
# Remote macOS half of the physical macOS <-> Android manual-join gate.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST_TARGET="${NVPN_MACOS_HOST_TARGET:-$(rustc -vV | awk '/host:/ {print $2}')}"
ARTIFACT_DIR="${NVPN_MACOS_ANDROID_JOIN_ARTIFACT_DIR:-$ROOT/artifacts/macos-android-manual-join}"
DATA_ROOT="$ARTIFACT_DIR/app-data"
ADMIN_DATA_DIR="$DATA_ROOT/admin"
JOINER_DATA_DIR="$DATA_ROOT/joiner"
RESULT="$ARTIFACT_DIR/desktop-fixture.json"
WAIT_SECS="${NVPN_DESKTOP_MOBILE_JOIN_WAIT_SECS:-15}"
APP_PATH="${NVPN_MACOS_APP_PATH:-}"
app_pid=""

case "$(uname -s)" in
  Darwin) ;;
  *) echo "physical macOS/Android join remote requires macOS" >&2; exit 2 ;;
esac
ulimit -n "${NVPN_MACOS_OPEN_FILES_LIMIT:-8192}"

load_candidate() {
  if [[ -z "$APP_PATH" ]]; then
    APP_PATH="$("$ROOT/scripts/build-output-path" --raw)"
  fi
  [[ -d "$APP_PATH" ]] || {
    echo "macOS candidate app is missing: $APP_PATH" >&2
    return 1
  }
  executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' \
    "$APP_PATH/Contents/Info.plist")"
  APP_EXE="$APP_PATH/Contents/MacOS/$executable"
  NVPN="$(find "$APP_PATH/Contents" -type f -name nvpn -perm -111 -print -quit)"
  [[ -x "$APP_EXE" && -x "$NVPN" ]] || {
    echo "macOS candidate app or bundled nvpn is not executable" >&2
    return 1
  }
  FIXTURE="$ROOT/macos/.build/cargo-target/$HOST_TARGET/release/examples/desktop_manual_join_e2e_fixture"
}

stop_app() {
  if [[ -n "$app_pid" ]] && kill -0 "$app_pid" >/dev/null 2>&1; then
    kill "$app_pid" >/dev/null 2>&1 || true
    wait "$app_pid" >/dev/null 2>&1 || true
  fi
  app_pid=""
}
trap stop_app EXIT

data_dir_for_role() {
  case "$1" in
    admin) printf '%s\n' "$ADMIN_DATA_DIR" ;;
    joiner) printf '%s\n' "$JOINER_DATA_DIR" ;;
    *) echo "role must be admin or joiner" >&2; return 2 ;;
  esac
}

service_uninstall() {
  local data_dir config
  data_dir="$(data_dir_for_role "$1")"
  config="$data_dir/config.toml"
  [[ -x "${NVPN:-}" && -f "$config" ]] || return 0
  sudo -n "$NVPN" service uninstall --config "$config" >/dev/null 2>&1 || true
}

service_install() {
  local role="$1" data_dir config deadline status_json
  data_dir="$(data_dir_for_role "$role")"
  config="$data_dir/config.toml"
  service_uninstall "$role"
  sudo -n "$NVPN" service install --force --config "$config" >/dev/null
  deadline=$((SECONDS + WAIT_SECS))
  while ((SECONDS < deadline)); do
    status_json="$(
      "$NVPN" service status --json --skip-binary-version \
        --config "$config" 2>/dev/null || true
    )"
    if python3 - "$status_json" <<'PY'
import json, sys
try:
    state = json.loads(sys.argv[1])
except Exception:
    raise SystemExit(1)
raise SystemExit(0 if state.get("installed") and state.get("running") else 1)
PY
    then
      return 0
    fi
    sleep 0.25
  done
  echo "isolated macOS $role service did not start" >&2
  return 1
}

service_running() {
  local role="$1" data_dir config status_json
  data_dir="$(data_dir_for_role "$role")"
  config="$data_dir/config.toml"
  status_json="$(
    "$NVPN" service status --json --skip-binary-version \
      --config "$config" 2>/dev/null || true
  )"
  python3 - "$status_json" <<'PY'
import json, sys
try:
    state = json.loads(sys.argv[1])
except Exception:
    raise SystemExit(1)
raise SystemExit(0 if state.get("installed") and state.get("running") else 1)
PY
}

ensure_service_running() {
  service_running "$1" || service_install "$1"
}

drive_ui() {
  local role="$1" value1="$2" value2="$3" data_dir log
  data_dir="$(data_dir_for_role "$role")"
  log="$ARTIFACT_DIR/$role-app.log"
  stop_app
  NVPN_APP_DATA_DIR="$data_dir" \
    NVPN_CLI_PATH="$NVPN" \
    "$APP_EXE" >"$log" 2>&1 &
  app_pid=$!
  /usr/bin/swift "$ROOT/scripts/desktop-manual-join-ax.swift" \
    "$app_pid" "$role" "$value1" "$value2" "$executable"
}

verify_joiner_config() {
  local mesh="$1" admin="$2"
  "$FIXTURE" verify-physical-joiner \
    --admin-data-dir "$ADMIN_DATA_DIR" \
    --joiner-data-dir "$JOINER_DATA_DIR" \
    --result "$RESULT" \
    --mesh-network-id "$mesh" \
    --admin-npub "$admin"
}

verify_admin_config() {
  local participant="$1"
  "$FIXTURE" verify-physical-admin \
    --admin-data-dir "$ADMIN_DATA_DIR" \
    --joiner-data-dir "$JOINER_DATA_DIR" \
    --result "$RESULT" \
    --participant-npub "$participant"
}

case "${1:-}" in
  prepare)
    case "${NVPN_MACOS_ANDROID_JOIN_SKIP_BUILD:-0}" in
      1|true|TRUE|True|yes|YES|Yes|on|ON|On) ;;
      *)
        NVPN_MACOS_RUST_PROFILE=release \
          NVPN_MACOS_XCODE_CONFIGURATION=Release \
          "$ROOT/scripts/macos-build" macos-build
        CARGO_TARGET_DIR="$ROOT/macos/.build/cargo-target" \
          cargo build -q --release --target "$HOST_TARGET" -p nostr-vpn-core \
            --example desktop_manual_join_e2e_fixture
        ;;
    esac
    load_candidate
    service_uninstall admin
    service_uninstall joiner
    rm -rf "$DATA_ROOT"
    mkdir -p "$ARTIFACT_DIR" "$DATA_ROOT"
    "$FIXTURE" prepare \
      --admin-data-dir "$ADMIN_DATA_DIR" \
      --joiner-data-dir "$JOINER_DATA_DIR" \
      --result "$RESULT"
    cat "$RESULT"
    ;;
  admin-add)
    [[ $# == 3 ]] || { echo "usage: $0 admin-add <Android npub> <alias>" >&2; exit 2; }
    load_candidate
    ensure_service_running admin
    drive_ui admin "$2" "$3"
    deadline=$((SECONDS + WAIT_SECS))
    while ((SECONDS < deadline)); do
      if verify_admin_config "$2" >/dev/null 2>&1; then
        stop_app
        echo "MACOS_PHYSICAL_ANDROID_ADMIN_UI_ADD_OK"
        exit 0
      fi
      sleep 0.25
    done
    verify_admin_config "$2"
    ;;
  joiner-manual)
    [[ $# == 3 ]] || { echo "usage: $0 joiner-manual <Android admin npub> <mesh ID>" >&2; exit 2; }
    load_candidate
    service_install joiner
    drive_ui joiner "$2" "$3"
    deadline=$((SECONDS + WAIT_SECS))
    while ((SECONDS < deadline)); do
      if grep -Fq "network_id = \"$3\"" "$JOINER_DATA_DIR/config.toml"; then
        stop_app
        echo "MACOS_PHYSICAL_ANDROID_JOINER_UI_SUBMIT_OK"
        exit 0
      fi
      sleep 0.25
    done
    echo "macOS manual-join UI did not persist the Android network" >&2
    exit 1
    ;;
  wait-joiner-receipt)
    [[ $# == 3 ]] || { echo "usage: $0 wait-joiner-receipt <mesh ID> <Android admin npub>" >&2; exit 2; }
    load_candidate
    deadline=$((SECONDS + WAIT_SECS))
    while ((SECONDS < deadline)); do
      if verify_joiner_config "$2" "$3" >/dev/null 2>&1; then
        echo "MACOS_PHYSICAL_ANDROID_DURABLE_ROSTER_RECEIPT_OK"
        exit 0
      fi
      sleep 0.25
    done
    verify_joiner_config "$2" "$3"
    ;;
  start)
    [[ $# == 2 ]] || { echo "usage: $0 start <admin|joiner>" >&2; exit 2; }
    load_candidate
    ensure_service_running "$2"
    role_name="$(printf '%s' "$2" | tr '[:lower:]' '[:upper:]')"
    echo "MACOS_PHYSICAL_ANDROID_${role_name}_SERVICE_READY_OK"
    ;;
  wait-admin-ack)
    [[ $# == 2 ]] || { echo "usage: $0 wait-admin-ack <Android npub>" >&2; exit 2; }
    load_candidate
    deadline=$((SECONDS + WAIT_SECS))
    while ((SECONDS < deadline)); do
      if verify_admin_config "$2" >/dev/null 2>&1 \
        && ! find "$ADMIN_DATA_DIR/config.toml.join-roster-outbox" \
          -type f -name '*.json' -print -quit 2>/dev/null | grep -q .
      then
        echo "MACOS_PHYSICAL_ANDROID_DURABLE_ACK_OK"
        exit 0
      fi
      sleep 0.25
    done
    echo "macOS admin retained an unacknowledged physical Android roster delivery" >&2
    exit 1
    ;;
  verify-joined-ui)
    load_candidate
    data_dir="$(data_dir_for_role joiner)"
    NVPN_APP_DATA_DIR="$data_dir" NVPN_CLI_PATH="$NVPN" \
      "$APP_EXE" >"$ARTIFACT_DIR/joiner-joined-app.log" 2>&1 &
    app_pid=$!
    /usr/bin/swift "$ROOT/scripts/desktop-manual-join-ax.swift" \
      "$app_pid" joined _ _ "$executable"
    stop_app
    echo "MACOS_PHYSICAL_ANDROID_JOINED_UI_TRANSITION_OK"
    ;;
  stop)
    [[ $# == 2 ]] || { echo "usage: $0 stop <admin|joiner>" >&2; exit 2; }
    load_candidate
    service_uninstall "$2"
    ;;
  cleanup)
    load_candidate
    service_uninstall admin
    service_uninstall joiner
    stop_app
    echo "MACOS_PHYSICAL_ANDROID_JOIN_CLEAN_OK"
    ;;
  *)
    echo "usage: $0 <prepare|start|admin-add|joiner-manual|wait-joiner-receipt|wait-admin-ack|verify-joined-ui|stop|cleanup>" >&2
    exit 2
    ;;
esac
