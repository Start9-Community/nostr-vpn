#!/usr/bin/env bash
# macOS VM half of the Release desktop <-> mobile manual-join gate.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT_DIR="${NVPN_MACOS_RELEASE_JOIN_ARTIFACT_DIR:-$ROOT/artifacts/macos-release-mobile-join}"
APP_PATH="$ROOT/dist/macos/Nostr VPN.app"
APP_EXE="$APP_PATH/Contents/MacOS/Nostr VPN"
FIPS_PATH="${NVPN_FIPS_REPO_PATH:-$ROOT/../fips}"
EXPECTED_FIPS="${NVPN_EXPECTED_FIPS_GIT_SHA:-}"
APP_LOG="$ARTIFACT_DIR/app.log"
APP_PID=""

mkdir -p "$ARTIFACT_DIR"

stop_app() {
  if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" >/dev/null 2>&1; then
    kill "$APP_PID" >/dev/null 2>&1 || true
    wait "$APP_PID" >/dev/null 2>&1 || true
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

launch_app() {
  load_app
  pkill -x "Nostr VPN" >/dev/null 2>&1 || true
  sleep 0.25
  (
    unset NVPN_FIPS_REPO_PATH NVPN_EXPECTED_FIPS_GIT_SHA
    exec "$APP_EXE"
  ) >>"$APP_LOG" 2>&1 &
  APP_PID=$!
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
  /usr/bin/swift "$ROOT/scripts/desktop-manual-join-ax.swift" \
    "$APP_PID" "$phase" "$value1" "$value2" "Nostr VPN"
  stop_app
}

run_driver_hold() {
  local phase="$1" value1="$2" value2="$3"
  launch_app
  /usr/bin/swift "$ROOT/scripts/desktop-manual-join-ax.swift" \
    "$APP_PID" "$phase" "$value1" "$value2" "Nostr VPN"
  echo "NVPN_RELEASE_JOIN_MARKER NVPN_MACOS_RELEASE_APP_HOLDING=1"
  sleep "${NVPN_MACOS_RELEASE_JOIN_HOLD_SECS:-20}"
  stop_app
}

prepare() {
  [[ -f "$FIPS_PATH/crates/fips-core/Cargo.toml" ]] || {
    echo "macOS Release join gate requires synced FIPS source" >&2
    return 1
  }
  local fips_sha fips_tree app_sha app_tree team
  fips_sha="$(git -C "$FIPS_PATH" rev-parse HEAD)"
  fips_tree="$(git -C "$FIPS_PATH" rev-parse HEAD^{tree})"
  [[ -z "$(git -C "$FIPS_PATH" status --porcelain)" ]] || {
    echo "macOS Release join gate refuses dirty FIPS source" >&2
    return 1
  }
  [[ -z "$EXPECTED_FIPS" || "$fips_sha" == "$EXPECTED_FIPS" ]] || {
    echo "macOS Release join FIPS mismatch" >&2
    return 1
  }
  app_sha="$(git -C "$ROOT" rev-parse HEAD)"
  app_tree="$(git -C "$ROOT" rev-parse HEAD^{tree})"
  NVPN_FIPS_REPO_PATH="$FIPS_PATH" \
    NVPN_MACOS_RUST_PROFILE=release \
    NVPN_MACOS_XCODE_CONFIGURATION=Release \
    NVPN_MACOS_REQUIRE_SIGNING=1 \
    "$ROOT/scripts/macos-build" macos-app >/dev/null
  load_app
  team="$(
    codesign -dvv "$APP_PATH" 2>&1 \
      | sed -n 's/^TeamIdentifier=//p' \
      | head -n 1
  )"
  [[ -n "$team" && "$team" != not\ set ]] || {
    echo "macOS Release app is not signed by a distribution team" >&2
    return 1
  }
  python3 - \
    "$APP_PATH" "$ARTIFACT_DIR/artifact.json" \
    "$app_sha" "$app_tree" "$fips_sha" "$fips_tree" "$team" <<'PY'
import hashlib
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
output = pathlib.Path(sys.argv[2])
app, app_tree, fips, fips_tree, team = sys.argv[3:]
files = []
for path in sorted(item for item in root.rglob("*") if item.is_file()):
    files.append(
        {
            "path": str(path.relative_to(root)),
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "size": path.stat().st_size,
        }
    )
canonical = json.dumps(files, separators=(",", ":"), sort_keys=True).encode()
receipt = {
    "artifact": "signed macOS Release app",
    "bundleManifestSha256": hashlib.sha256(canonical).hexdigest(),
    "appGitSha": app,
    "appGitTree": app_tree,
    "fipsGitSha": fips,
    "fipsGitTree": fips_tree,
    "signingTeam": team,
    "configuration": "Release",
    "appLaunchArgumentsOrEnvironment": False,
    "privateAppStateRead": False,
}
output.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
  echo "NVPN_RELEASE_JOIN_MARKER NVPN_MACOS_RELEASE_ARTIFACT_READY=1"
}

case "${1:-}" in
  prepare)
    prepare
    ;;
  create-admin)
    [[ $# == 2 ]] || { echo "usage: $0 create-admin <network-name>" >&2; exit 2; }
    run_driver release-create-admin "$2" _
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
    pkill -x "Nostr VPN" >/dev/null 2>&1 || true
    ;;
  *)
    echo "usage: $0 <prepare|create-admin|manual-join|admin-add|verify|cleanup>" >&2
    exit 2
    ;;
esac
