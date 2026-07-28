#!/usr/bin/env bash
# Drive both sides of manual join through the release macOS UI.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib-macos-owned-test-app.sh"
ARTIFACT_DIR="${ARTIFACT_ROOT:-$ROOT/artifacts/macos-manual-join-ui}"
E2E_ROOT="$ARTIFACT_DIR/app-data"
ADMIN_DATA_DIR="$E2E_ROOT/admin"
JOINER_DATA_DIR="$E2E_ROOT/joiner"
RESULT="$ARTIFACT_DIR/result.json"
APP_LOG="$ARTIFACT_DIR/app.log"
TIMEOUT_SECS="${NVPN_DESKTOP_MANUAL_JOIN_TIMEOUT_SECS:-20}"
APP_PATH="${NVPN_MACOS_APP_PATH:-}"
FIXTURE="${NVPN_DESKTOP_MANUAL_JOIN_FIXTURE:-}"
DRIVER="${NVPN_DESKTOP_MANUAL_JOIN_DRIVER:-}"
VM_IMPORT_ONLY="${NVPN_MACOS_VM_IMPORT_ONLY:-0}"
app_pid=""
APP_EXE=""

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "macOS manual-join UI e2e requires macOS." >&2
  exit 2
fi
ulimit -n "${NVPN_MACOS_OPEN_FILES_LIMIT:-8192}"
if [[ -z "$DRIVER" ]]; then
  case "$VM_IMPORT_ONLY" in
    1|true|TRUE|True|yes|YES|Yes|on|ON|On)
      echo "VM import-only macOS manual join requires NVPN_DESKTOP_MANUAL_JOIN_DRIVER." >&2
      exit 2
      ;;
  esac
  DRIVER="$ROOT/scripts/desktop-manual-join-ax.swift"
fi
if [[ ! -x "$DRIVER" ]]; then
  echo "macOS manual-join AX driver is missing: $DRIVER" >&2
  exit 1
fi
if ! "$DRIVER" --check-accessibility >/dev/null; then
  echo "macOS manual-join UI e2e requires Accessibility permission for the invoking terminal." >&2
  exit 1
fi

stop_app() {
  if [[ -n "$app_pid" ]] && kill -0 "$app_pid" >/dev/null 2>&1; then
    kill "$app_pid" >/dev/null 2>&1 || true
    wait "$app_pid" >/dev/null 2>&1 || true
  fi
  app_pid=""
  case "$VM_IMPORT_ONLY" in
    1|true|TRUE|True|yes|YES|Yes|on|ON|On)
      [[ -z "$APP_EXE" ]] || macos_stop_exact_test_app "$APP_EXE"
      ;;
  esac
}
trap stop_app EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

rm -rf "$E2E_ROOT"
mkdir -p "$ARTIFACT_DIR" "$E2E_ROOT"
rm -f "$RESULT" "$APP_LOG" "$ARTIFACT_DIR"/*.png

if [[ -z "$APP_PATH" ]]; then
  case "$VM_IMPORT_ONLY" in
    1|true|TRUE|True|yes|YES|Yes|on|ON|On)
      echo "VM import-only macOS manual join requires NVPN_MACOS_APP_PATH." >&2
      exit 2
      ;;
  esac
  NVPN_MACOS_RUST_PROFILE=release \
    NVPN_MACOS_XCODE_CONFIGURATION=Release \
    "$ROOT/scripts/macos-build" macos-build
  APP_PATH="$("$ROOT/scripts/build-output-path" --raw)"
fi
if [[ ! -d "$APP_PATH" ]]; then
  echo "macOS release app not found: $APP_PATH" >&2
  exit 1
fi
APP_PATH="$(cd "$(dirname "$APP_PATH")" && pwd -P)/$(basename "$APP_PATH")"
codesign --verify --deep --strict "$APP_PATH"

executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP_PATH/Contents/Info.plist")"
APP_EXE="$APP_PATH/Contents/MacOS/$executable"
NVPN="$(find "$APP_PATH/Contents" -type f -name nvpn -perm -111 -print -quit)"
if [[ -z "$NVPN" ]]; then
  echo "macOS release app has no bundled nvpn executable: $APP_PATH" >&2
  exit 1
fi
existing_app_pids="$(macos_exact_executable_pids "$APP_EXE")"
if [[ -n "$existing_app_pids" ]]; then
  case "$VM_IMPORT_ONLY" in
    1|true|TRUE|True|yes|YES|Yes|on|ON|On)
      macos_stop_exact_test_app "$APP_EXE" || {
        echo "Could not stop the stale imported $APP_PATH instance." >&2
        exit 1
      }
      ;;
    *)
      echo "Close the existing $APP_PATH instance before the isolated UI e2e." >&2
      exit 1
      ;;
  esac
fi

# A macOS background service is machine-global, while this test intentionally
# uses two isolated configs. Refuse to touch a machine with that service active;
# the release gate runs this on its clean macOS VM.
service_json="$(
  "$NVPN" service status --json --skip-binary-version \
    --config "$JOINER_DATA_DIR/config.toml" 2>/dev/null || true
)"
if ! python3 - "$service_json" <<'PY'
import json, sys
try:
    value = json.loads(sys.argv[1])
except Exception:
    raise SystemExit(1)
raise SystemExit(1 if value.get("installed") or value.get("running") else 0)
PY
then
  echo "Refusing macOS manual-join UI e2e because the machine-global nvpn service is installed or its status could not be verified." >&2
  exit 1
fi

if [[ -z "$FIXTURE" ]]; then
  case "$VM_IMPORT_ONLY" in
    1|true|TRUE|True|yes|YES|Yes|on|ON|On)
      echo "VM import-only macOS manual join requires NVPN_DESKTOP_MANUAL_JOIN_FIXTURE." >&2
      exit 2
      ;;
  esac
  HOST_TARGET="${NVPN_MACOS_HOST_TARGET:-$(rustc -vV | awk '/host:/ {print $2}')}"
  FIXTURE="$ROOT/macos/.build/cargo-target/$HOST_TARGET/release/examples/desktop_manual_join_e2e_fixture"
fi
case "$VM_IMPORT_ONLY:${NVPN_DESKTOP_MANUAL_JOIN_SKIP_FIXTURE_BUILD:-0}" in
  1:*|true:*|TRUE:*|True:*|yes:*|YES:*|Yes:*|on:*|ON:*|On:*|*:1|*:true|*:TRUE|*:True|*:yes|*:YES|*:Yes|*:on|*:ON|*:On)
    [[ -x "$FIXTURE" ]] || {
      echo "Prebuilt macOS manual-join fixture is missing: $FIXTURE" >&2
      exit 1
    }
    ;;
  *)
    CARGO_TARGET_DIR="$ROOT/macos/.build/cargo-target" \
      cargo build -q --release --target "$HOST_TARGET" -p nostr-vpn-core \
        --example desktop_manual_join_e2e_fixture
    ;;
esac
case "$VM_IMPORT_ONLY" in
  1|true|TRUE|True|yes|YES|Yes|on|ON|On)
    codesign --verify --strict "$FIXTURE"
    codesign --verify --strict "$DRIVER"
    ;;
esac
fixture_args=(
  --admin-data-dir "$ADMIN_DATA_DIR"
  --joiner-data-dir "$JOINER_DATA_DIR"
  --result "$RESULT"
)
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

wait_for_fixture() {
  local command="$1"
  local label="$2"
  local deadline=$((SECONDS + TIMEOUT_SECS))
  while ((SECONDS < deadline)); do
    if "$FIXTURE" "$command" "${fixture_args[@]}" >/dev/null 2>&1; then
      return 0
    fi
    if ! kill -0 "$app_pid" >/dev/null 2>&1; then
      echo "macOS app exited before persisting the $label manual-join action." >&2
      tail -n 120 "$APP_LOG" >&2 || true
      return 1
    fi
    sleep 0.1
  done
  "$FIXTURE" "$command" "${fixture_args[@]}"
  echo "macOS UI did not persist the $label manual-join action within ${TIMEOUT_SECS}s." >&2
  return 1
}

launch_app() {
  local data_dir="$1"
  case "$VM_IMPORT_ONLY" in
    1|true|TRUE|True|yes|YES|Yes|on|ON|On)
      # Launch through LaunchServices so SwiftUI materializes the initial
      # WindowGroup in the active GUI session. Executing the bundle binary
      # directly over SSH starts the process and menu bar but no app window.
      open -n -F \
        --env "NVPN_APP_DATA_DIR=$data_dir" \
        --env "NVPN_CLI_PATH=$NVPN" \
        --stdout "$APP_LOG" \
        --stderr "$APP_LOG" \
        "$APP_PATH"
      ;;
    *)
      NVPN_APP_DATA_DIR="$data_dir" \
        NVPN_CLI_PATH="$NVPN" \
        "$APP_EXE" >>"$APP_LOG" 2>&1 &
      app_pid=$!
      ;;
  esac
  local deadline=$((SECONDS + TIMEOUT_SECS))
  while ((SECONDS < deadline)); do
    case "$VM_IMPORT_ONLY" in
      1|true|TRUE|True|yes|YES|Yes|on|ON|On)
        app_pid="$(macos_exact_executable_pids "$APP_EXE" | tail -n 1)"
        ;;
    esac
    if [[ -n "$app_pid" ]] && kill -0 "$app_pid" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  echo "macOS release app did not launch within ${TIMEOUT_SECS}s." >&2
  return 1
}

launch_app "$JOINER_DATA_DIR"
"$DRIVER" \
  "$app_pid" joiner "$ADMIN_NPUB" "$MESH_NETWORK_ID" "$executable"
wait_for_fixture verify-joiner joiner
if ! screencapture -x "$ARTIFACT_DIR/joiner.png"; then
  echo "macOS UI screenshot unavailable; continuing with AX and persisted-state evidence." >&2
fi
stop_app

launch_app "$ADMIN_DATA_DIR"
"$DRIVER" \
  "$app_pid" admin "$JOINER_NPUB" "$JOINER_ALIAS" "$executable"
wait_for_fixture verify-admin admin
if ! screencapture -x "$ARTIFACT_DIR/admin.png"; then
  echo "macOS UI screenshot unavailable; continuing with AX and persisted-state evidence." >&2
fi
"$FIXTURE" verify "${fixture_args[@]}"
stop_app

echo "MACOS_DESKTOP_MANUAL_JOIN_UI_E2E_OK"
echo "Result: $RESULT"
