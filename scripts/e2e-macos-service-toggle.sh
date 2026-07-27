#!/usr/bin/env bash
# Click the shipped macOS app's VPN toggle with no service installed, observe
# the real Authorization Services prompt, cancel it, and prove no install ran.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT_DIR="${ARTIFACT_ROOT:-$ROOT/artifacts/macos-service-toggle}"
DATA_ROOT="$ARTIFACT_DIR/app-data"
ADMIN_DATA_DIR="$DATA_ROOT/admin"
JOINER_DATA_DIR="$DATA_ROOT/joiner"
RESULT="$ARTIFACT_DIR/fixture.json"
APP_LOG="$ARTIFACT_DIR/app.log"
APP_PATH="${NVPN_MACOS_APP_PATH:-}"
FIXTURE="${NVPN_DESKTOP_SERVICE_TOGGLE_FIXTURE:-}"
DRIVER="${NVPN_DESKTOP_SERVICE_TOGGLE_DRIVER:-}"
VM_IMPORT_ONLY="${NVPN_MACOS_VM_IMPORT_ONLY:-0}"
TIMEOUT_SECS="${NVPN_DESKTOP_SERVICE_TOGGLE_TIMEOUT_SECS:-30}"
app_pid=""

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "macOS service-toggle UI e2e requires macOS." >&2
  exit 2
fi
ulimit -n "${NVPN_MACOS_OPEN_FILES_LIMIT:-8192}"
if [[ -z "$DRIVER" ]]; then
  case "$VM_IMPORT_ONLY" in
    1|true|TRUE|True|yes|YES|Yes|on|ON|On)
      echo "VM import-only macOS service toggle requires NVPN_DESKTOP_SERVICE_TOGGLE_DRIVER." >&2
      exit 2
      ;;
  esac
  DRIVER="$ROOT/scripts/macos-service-toggle-ax.swift"
fi
if [[ ! -x "$DRIVER" ]]; then
  echo "macOS service-toggle AX driver is missing: $DRIVER" >&2
  exit 1
fi
if ! "$DRIVER" --check-accessibility >/dev/null; then
  echo "macOS service-toggle UI e2e requires Accessibility permission for the invoking terminal." >&2
  exit 1
fi

stop_app() {
  if [[ -n "$app_pid" ]] && kill -0 "$app_pid" >/dev/null 2>&1; then
    kill "$app_pid" >/dev/null 2>&1 || true
    wait "$app_pid" >/dev/null 2>&1 || true
  fi
  app_pid=""
}
trap stop_app EXIT

rm -rf "$DATA_ROOT"
mkdir -p "$ARTIFACT_DIR" "$DATA_ROOT"
rm -f "$RESULT" "$APP_LOG" "$ARTIFACT_DIR"/*.png

if [[ -z "$APP_PATH" ]]; then
  case "$VM_IMPORT_ONLY" in
    1|true|TRUE|True|yes|YES|Yes|on|ON|On)
      echo "VM import-only macOS service toggle requires NVPN_MACOS_APP_PATH." >&2
      exit 2
      ;;
  esac
  NVPN_MACOS_RUST_PROFILE=release \
    NVPN_MACOS_XCODE_CONFIGURATION=Release \
    "$ROOT/scripts/macos-build" macos-build
  APP_PATH="$(
    NVPN_MACOS_XCODE_CONFIGURATION=Release \
      "$ROOT/scripts/build-output-path" --raw
  )"
fi
if [[ ! -d "$APP_PATH" ]]; then
  echo "macOS release app not found: $APP_PATH" >&2
  exit 1
fi
codesign --verify --deep --strict "$APP_PATH"

executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP_PATH/Contents/Info.plist")"
APP_EXE="$APP_PATH/Contents/MacOS/$executable"
NVPN="$(find "$APP_PATH/Contents" -type f -name nvpn -perm -111 -print -quit)"
if [[ -z "$NVPN" ]]; then
  echo "macOS release app has no bundled nvpn executable: $APP_PATH" >&2
  exit 1
fi
if pgrep -f "$APP_EXE" >/dev/null 2>&1; then
  echo "Close the existing $APP_PATH instance before the isolated UI e2e." >&2
  exit 1
fi

service_status() {
  "$NVPN" service status --json --skip-binary-version \
    --config "$ADMIN_DATA_DIR/config.toml"
}

status_before="$(service_status)"
python3 - "$status_before" <<'PY'
import json, sys
status = json.loads(sys.argv[1])
if status.get("installed") or status.get("running"):
    raise SystemExit("macOS service-toggle e2e requires the machine-global nvpn service to be absent")
PY

if [[ -z "$FIXTURE" ]]; then
  case "$VM_IMPORT_ONLY" in
    1|true|TRUE|True|yes|YES|Yes|on|ON|On)
      echo "VM import-only macOS service toggle requires NVPN_DESKTOP_SERVICE_TOGGLE_FIXTURE." >&2
      exit 2
      ;;
  esac
  HOST_TARGET="${NVPN_MACOS_HOST_TARGET:-$(rustc -vV | awk '/host:/ {print $2}')}"
  FIXTURE="$ROOT/macos/.build/cargo-target/$HOST_TARGET/release/examples/desktop_manual_join_e2e_fixture"
fi
case "$VM_IMPORT_ONLY:${NVPN_DESKTOP_SERVICE_TOGGLE_SKIP_FIXTURE_BUILD:-0}" in
  1:*|true:*|TRUE:*|True:*|yes:*|YES:*|Yes:*|on:*|ON:*|On:*|*:1|*:true|*:TRUE|*:True|*:yes|*:YES|*:Yes|*:on|*:ON|*:On)
    [[ -x "$FIXTURE" ]] || {
      echo "Prebuilt macOS service-toggle fixture is missing: $FIXTURE" >&2
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
"$FIXTURE" prepare \
  --admin-data-dir "$ADMIN_DATA_DIR" \
  --joiner-data-dir "$JOINER_DATA_DIR" \
  --result "$RESULT"

open -n -F \
  --env "NVPN_APP_DATA_DIR=$ADMIN_DATA_DIR" \
  --env "NVPN_CLI_PATH=$NVPN" \
  --stdout "$APP_LOG" \
  --stderr "$APP_LOG" \
  "$APP_PATH"

deadline=$((SECONDS + TIMEOUT_SECS))
while ((SECONDS < deadline)); do
  app_pid="$(pgrep -f "$APP_EXE" | tail -n 1 || true)"
  if [[ -n "$app_pid" ]] && kill -0 "$app_pid" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done
if [[ -z "$app_pid" ]] || ! kill -0 "$app_pid" >/dev/null 2>&1; then
  echo "macOS release app exited before the VPN toggle could be tested." >&2
  tail -n 120 "$APP_LOG" >&2 || true
  exit 1
fi

"$DRIVER" \
  "$app_pid" "$executable"

status_after="$(service_status)"
python3 - "$status_before" "$status_after" <<'PY'
import json, sys
before, after = (json.loads(value) for value in sys.argv[1:])
for key in ("installed", "loaded", "running", "binary_path"):
    if after.get(key) != before.get(key):
        raise SystemExit(f"macOS service state changed after cancelled prompt: {key}")
if after.get("installed") or after.get("running"):
    raise SystemExit("cancelled macOS prompt installed or started the nvpn service")
PY

if ! screencapture -x "$ARTIFACT_DIR/window-after-cancel.png"; then
  echo "macOS UI screenshot unavailable; continuing with AX and service-state evidence." >&2
fi
stop_app

echo "MACOS_SERVICE_TOGGLE_AUTHORIZATION_PROMPT_OK"
