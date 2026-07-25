#!/usr/bin/env bash
# Drives the real desktop shell through its debug deep-link boundary, then
# verifies the production app core persisted the accepted mobile join request.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT_ROOT="${ARTIFACT_ROOT:-$ROOT/artifacts/desktop-roster-e2e}"
DATA_DIR="$ARTIFACT_ROOT/app-data"
RESULT="$ARTIFACT_ROOT/result.json"
APP_LOG="$ARTIFACT_ROOT/app.log"
READY_FILE="$ARTIFACT_ROOT/app-ready"
FAKE_NVPN="$ARTIFACT_ROOT/nvpn-e2e"
TIMEOUT_SECS="${NVPN_DESKTOP_ROSTER_E2E_TIMEOUT_SECS:-30}"
ROOT_CARGO_TARGET_DIR="${NVPN_ROOT_CARGO_TARGET_DIR:-${CARGO_TARGET_DIR:-$ROOT/target}}"
LINUX_CARGO_TARGET_DIR="${NVPN_LINUX_CARGO_TARGET_DIR:-$ROOT/linux/target}"

mkdir -p "$ARTIFACT_ROOT"
rm -rf "$DATA_DIR"
rm -f "$RESULT" "$APP_LOG" "$READY_FILE"

CARGO_TARGET_DIR="$ROOT_CARGO_TARGET_DIR" \
  cargo build -q -p nostr-vpn-app-core --example desktop_roster_e2e_fixture
CARGO_TARGET="$(CARGO_TARGET_DIR="$ROOT_CARGO_TARGET_DIR" \
  cargo metadata --no-deps --format-version 1 \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])')"
FIXTURE="$CARGO_TARGET/debug/examples/desktop_roster_e2e_fixture"
"$FIXTURE" prepare --data-dir "$DATA_DIR" --result "$RESULT"
DEBUG_URL="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["debugUrl"])' "$RESULT")"

cat >"$FAKE_NVPN" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
  echo "nvpn 0.0.0-e2e"
  exit 0
fi
# The roster action must persist even when no system daemon belongs to this
# isolated fixture. Returning unavailable also ensures this test cannot mutate
# the host's real daemon configuration.
exit 1
SH
chmod +x "$FAKE_NVPN"

case "$(uname -s)" in
  Darwin)
    launch_with_open=1
    APP_PATH="${NVPN_MACOS_APP_PATH:-}"
    if [[ -z "$APP_PATH" ]]; then
      "$ROOT/scripts/macos-build" macos-build
      APP_PATH="$("$ROOT/scripts/build-output-path" --raw)"
    fi
    isolated_app="$ARTIFACT_ROOT/Nostr VPN Roster E2E.app"
    rm -rf "$isolated_app"
    ditto "$APP_PATH" "$isolated_app"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier fi.siriusbusiness.nvpn.roster-e2e' \
      "$isolated_app/Contents/Info.plist"
    codesign --force --deep --sign - "$isolated_app" >/dev/null
    APP_PATH="$isolated_app"
    executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP_PATH/Contents/Info.plist")"
    APP_EXE="$APP_PATH/Contents/MacOS/$executable"
    ;;
  Linux)
    launch_with_open=0
    (cd "$ROOT/linux" && CARGO_TARGET_DIR="$LINUX_CARGO_TARGET_DIR" cargo build -q)
    LINUX_TARGET="$(cd "$ROOT/linux" && CARGO_TARGET_DIR="$LINUX_CARGO_TARGET_DIR" \
      cargo metadata --no-deps --format-version 1 \
      | python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])')"
    APP_EXE="$LINUX_TARGET/debug/nostr-vpn"
    ;;
  *)
    echo "desktop roster e2e supports macOS and Linux; use scripts/e2e-desktop-roster-join.ps1 on Windows" >&2
    exit 2
    ;;
esac

if [[ "$launch_with_open" == "1" ]]; then
  open -n -F \
    --env "NVPN_APP_DATA_DIR=$DATA_DIR" \
    --env "NVPN_CLI_PATH=$FAKE_NVPN" \
    --env "NVPN_ROSTER_E2E_READY_PATH=$READY_FILE" \
    --stdout "$APP_LOG" \
    --stderr "$APP_LOG" \
    "$APP_PATH"
  app_pid=""
  for _ in $(seq 1 40); do
    app_pid="$(pgrep -f "$APP_EXE" | tail -n 1 || true)"
    [[ -n "$app_pid" ]] && break
    sleep 0.25
  done
  if [[ -z "$app_pid" ]]; then
    echo "desktop roster e2e failed: macOS app process did not launch" >&2
    exit 1
  fi
  for _ in $(seq 1 40); do
    [[ -f "$READY_FILE" ]] && break
    sleep 0.25
  done
  if [[ ! -f "$READY_FILE" ]]; then
    echo "desktop roster e2e failed: macOS GUI did not create its main window" >&2
    exit 1
  fi
  # Deliver the link to the already-running app through LaunchServices. This
  # exercises NSApplicationDelegate's open-URLs callback rather than the
  # command-line/single-instance forwarding path used on Linux and Windows.
  open -a "$APP_PATH" "$DEBUG_URL"
else
  NVPN_APP_DATA_DIR="$DATA_DIR" \
  NVPN_CLI_PATH="$FAKE_NVPN" \
  NVPN_ROSTER_E2E_READY_PATH="$READY_FILE" \
  XDG_DATA_HOME="$ARTIFACT_ROOT/xdg-data" \
  "$APP_EXE" "$DEBUG_URL" >"$APP_LOG" 2>&1 &
  app_pid=$!
fi

cleanup() {
  if kill -0 "$app_pid" >/dev/null 2>&1; then
    kill "$app_pid" >/dev/null 2>&1 || true
    wait "$app_pid" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

deadline=$((SECONDS + TIMEOUT_SECS))
while ((SECONDS < deadline)); do
  if "$FIXTURE" verify --data-dir "$DATA_DIR" --result "$RESULT" >/dev/null 2>&1; then
    echo "DESKTOP_ROSTER_JOIN_E2E_OK"
    echo "Result: $RESULT"
    exit 0
  fi
  if ! kill -0 "$app_pid" >/dev/null 2>&1; then
    echo "desktop roster e2e failed: app exited before accepting the join request" >&2
    tail -n 120 "$APP_LOG" >&2 || true
    exit 1
  fi
  sleep 0.25
done

echo "desktop roster e2e failed: GUI did not persist the accepted device within ${TIMEOUT_SECS}s" >&2
tail -n 120 "$APP_LOG" >&2 || true
exit 1
