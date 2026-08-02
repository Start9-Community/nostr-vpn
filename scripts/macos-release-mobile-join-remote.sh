#!/usr/bin/env bash
# macOS VM half of the Release desktop <-> mobile manual-join gate.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib-macos-release-app-ownership.sh"
ARTIFACT_DIR="${NVPN_MACOS_RELEASE_JOIN_ARTIFACT_DIR:-$ROOT/artifacts/macos-release-mobile-join}"
PACKAGE="$ARTIFACT_DIR/imported"
APP_PATH="$PACKAGE/Nostr VPN.app"
APP_EXE="$APP_PATH/Contents/MacOS/Nostr VPN"
MANUAL_JOIN_FIXTURE="$PACKAGE/fixtures/desktop_manual_join_e2e_fixture"
MANUAL_JOIN_DRIVER="$PACKAGE/drivers/desktop-manual-join-ax"
SERVICE_TOGGLE_DRIVER="$PACKAGE/drivers/macos-service-toggle-ax"
FIPS_PATH="${NVPN_FIPS_REPO_PATH:-$ROOT/../fips}"
ARCHIVE="$ARTIFACT_DIR/macos-release-gate.zip"
RECEIPT="$ARTIFACT_DIR/artifact.json"
EXPECTED_APP="${NVPN_EXPECTED_APP_GIT_SHA:-}"
EXPECTED_APP_TREE="${NVPN_EXPECTED_APP_GIT_TREE:-}"
EXPECTED_FIPS="${NVPN_EXPECTED_FIPS_GIT_SHA:-}"
EXPECTED_FIPS_TREE="${NVPN_EXPECTED_FIPS_GIT_TREE:-}"
EXPECTED_FIPS_VERSION="${NVPN_EXPECTED_FIPS_VERSION:-}"
EXPECTED_SIGNING_IDENTITY="${NVPN_EXPECTED_MACOS_SIGNING_IDENTITY_SHA1:-}"
EXPECTED_SIGNING_TEAM="${NVPN_EXPECTED_MACOS_SIGNING_TEAM_ID:-}"
EXPECTED_SIGNER_CERT_SHA256="${NVPN_EXPECTED_MACOS_SIGNER_CERT_SHA256:-}"
APP_LOG="$ARTIFACT_DIR/app.log"
APP_PID=""
MACOS_RELEASE_APP_STATE_DIR="$ARTIFACT_DIR/app-ownership"
MACOS_RELEASE_APP_INSTALLED_EXE="/Applications/Nostr VPN.app/Contents/MacOS/Nostr VPN"
MACOS_RELEASE_APP_GATE_EXE="$APP_EXE"
MACOS_RELEASE_APP_PROCESS_NAME="Nostr VPN"
OWNED_PID_FILE="$MACOS_RELEASE_APP_STATE_DIR/imported.pid"

mkdir -p "$ARTIFACT_DIR"

stop_app() {
  if [[ -n "$APP_PID" ]]; then
    if kill -0 "$APP_PID" >/dev/null 2>&1; then
      macos_release_app_stop_pid "$APP_PID" "$APP_EXE"
    fi
    rm -f "$OWNED_PID_FILE"
  fi
  APP_PID=""
}
trap stop_app EXIT

load_app() {
  [[ -x "$APP_EXE" ]] || {
    echo "Signed macOS Release app is missing: $APP_PATH" >&2
    return 1
  }
  codesign --verify --deep --strict "$APP_PATH"
}

verify_import() {
  [[ -s "$ARCHIVE" && -s "$RECEIPT" && -d "$PACKAGE" ]] || {
    echo "Host-built macOS Release gate package is incomplete" >&2
    return 1
  }
  python3 "$ROOT/scripts/macos_release_join_artifact.py" validate \
    --receipt "$RECEIPT" \
    --package "$PACKAGE" \
    --app "$APP_PATH" \
    --archive "$ARCHIVE" \
    --manual-join-fixture "$MANUAL_JOIN_FIXTURE" \
    --manual-join-driver "$MANUAL_JOIN_DRIVER" \
    --service-toggle-driver "$SERVICE_TOGGLE_DRIVER" \
    --app-root "$ROOT" \
    --fips-root "$FIPS_PATH" \
    --expected-app-head "$EXPECTED_APP" \
    --expected-app-tree "$EXPECTED_APP_TREE" \
    --expected-fips-head "$EXPECTED_FIPS" \
    --expected-fips-tree "$EXPECTED_FIPS_TREE" \
    --expected-fips-version "$EXPECTED_FIPS_VERSION" \
    --expected-team "$EXPECTED_SIGNING_TEAM" \
    --expected-identity-sha1 "$EXPECTED_SIGNING_IDENTITY" \
    --expected-signer-sha256 "$EXPECTED_SIGNER_CERT_SHA256" \
    --verification-output "$ARTIFACT_DIR/verification.json"
  load_app
}

launch_app() {
  verify_import
  macos_release_app_acquire
  [[ ! -f "$OWNED_PID_FILE" ]] || {
    echo "a previous imported app launch is still owned" >&2
    return 1
  }
  (
    exec /usr/bin/env -i \
      HOME="$HOME" \
      USER="${USER:-dev}" \
      LOGNAME="${LOGNAME:-${USER:-dev}}" \
      PATH=/usr/bin:/bin:/usr/sbin:/sbin \
      TMPDIR="${TMPDIR:-/tmp}" \
      LANG="${LANG:-en_US.UTF-8}" \
      "$APP_EXE"
  ) >>"$APP_LOG" 2>&1 &
  APP_PID=$!
  printf '%s\n' "$APP_PID" >"$OWNED_PID_FILE.tmp"
  mv "$OWNED_PID_FILE.tmp" "$OWNED_PID_FILE"
  local deadline=$((SECONDS + 10))
  while ((SECONDS < deadline)); do
    kill -0 "$APP_PID" >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  return 1
}

run_driver() {
  local phase="$1" value1="$2" value2="$3"
  launch_app
  "$MANUAL_JOIN_DRIVER" \
    "$APP_PID" "$phase" "$value1" "$value2" "Nostr VPN"
  stop_app
}

run_driver_hold() {
  local phase="$1" value1="$2" value2="$3"
  launch_app
  "$MANUAL_JOIN_DRIVER" \
    "$APP_PID" "$phase" "$value1" "$value2" "Nostr VPN"
  echo "NVPN_RELEASE_JOIN_MARKER NVPN_MACOS_RELEASE_APP_HOLDING=1"
  sleep "${NVPN_MACOS_RELEASE_JOIN_HOLD_SECS:-20}"
  stop_app
}

stage() {
  stop_app
  macos_release_app_restore
  rm -rf "$ARTIFACT_DIR"
  mkdir -p "$ARTIFACT_DIR"
}

prepare() {
  local import_dir="$ARTIFACT_DIR/import"
  [[ -s "$ARCHIVE" && -s "$RECEIPT" ]] || {
    echo "Host-built macOS Release app archive or receipt is missing" >&2
    return 1
  }
  rm -rf "$import_dir" "$PACKAGE"
  mkdir -p "$import_dir"
  ditto -x -k "$ARCHIVE" "$import_dir"
  [[ -d "$import_dir/package/Nostr VPN.app" \
    && -x "$import_dir/package/fixtures/desktop_manual_join_e2e_fixture" \
    && -x "$import_dir/package/drivers/desktop-manual-join-ax" \
    && -x "$import_dir/package/drivers/macos-service-toggle-ax" \
    && "$(find "$import_dir" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" == 1 ]] || {
    echo "Imported macOS Release archive has an unexpected root layout" >&2
    return 1
  }
  mv "$import_dir/package" "$PACKAGE"
  rmdir "$import_dir"
  verify_import
  echo "NVPN_RELEASE_JOIN_MARKER NVPN_MACOS_RELEASE_ARTIFACT_READY=1"
}

case "${1:-}" in
  stage)
    stage
    ;;
  prepare)
    prepare
    ;;
  verify-import)
    verify_import
    echo "NVPN_RELEASE_JOIN_MARKER NVPN_MACOS_RELEASE_ARTIFACT_VERIFIED=1"
    ;;
  create-admin)
    [[ $# == 2 ]] || { echo "usage: $0 create-admin <network-name>" >&2; exit 2; }
    run_driver release-create-admin "$2" _
    ;;
  joiner-id)
    [[ $# == 1 ]] || { echo "usage: $0 joiner-id" >&2; exit 2; }
    run_driver release-joiner-id _ _
    ;;
  manual-join)
    [[ $# == 3 ]] || { echo "usage: $0 manual-join <admin-npub> <network-id>" >&2; exit 2; }
    run_driver release-manual-join "$2" "$3"
    ;;
  admin-add)
    [[ $# == 3 ]] || { echo "usage: $0 admin-add <joiner-npub> <alias>" >&2; exit 2; }
    run_driver_hold release-admin-add "$2" "$3"
    ;;
  verify)
    [[ $# == 2 ]] || { echo "usage: $0 verify <participant-npub>" >&2; exit 2; }
    run_driver release-verify "$2" _
    ;;
  cleanup)
    macos_release_app_restore
    ;;
  *)
    echo "usage: $0 <stage|prepare|verify-import|create-admin|joiner-id|manual-join|admin-add|verify|cleanup>" >&2
    exit 2
    ;;
esac
