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
CLI="$APP_PATH/Contents/Resources/nvpn"
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
CONFIG_DIR="$HOME/Library/Application Support/nvpn"
CONFIG="$CONFIG_DIR/config.toml"
JOIN_OUTBOX="$CONFIG.join-roster-outbox"
DAEMON_LOG="$CONFIG_DIR/daemon.log"
TEST_STATE_DIR="$ARTIFACT_DIR/test-profile"
TEST_STATE_BACKUP="$TEST_STATE_DIR/prior"
TEST_STATE_ACTIVE="$TEST_STATE_DIR/active"
TEST_SERVICE_OWNED="$TEST_STATE_DIR/service-owned"
PROFILE_STATE_NAMES=(
  config.toml
  .config.toml.nostr-secret-key.secret
  config.toml.join-roster-outbox
  signed-rosters.json
  daemon.log
  daemon.recent-peers.json
  daemon.state.json
  daemon.pid
  daemon.control
  daemon.control.ready
  daemon.control.result.json
  config.pending.toml
  daemon.cleanup.json
  control-pubsub-events.json
  control-pubsub-outbox
)

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
  [[ -x "$APP_EXE" && -x "$CLI" ]] || {
    echo "Signed macOS Release app is missing: $APP_PATH" >&2
    return 1
  }
  codesign --verify --deep --strict "$APP_PATH"
}

assert_service_ready() {
  local expected_hash service_json runtime_json
  expected_hash="$(shasum -a 256 "$CLI" | awk '{ print $1 }')"
  local deadline=$((SECONDS + 15))
  while ((SECONDS < deadline)); do
    service_json="$(
      "$CLI" service status --json --skip-binary-version \
        --config "$CONFIG" 2>/dev/null || true
    )"
    if python3 - "$service_json" "$expected_hash" <<'PY'
import hashlib
import json
import pathlib
import sys

try:
    value = json.loads(sys.argv[1])
    binary = pathlib.Path(value["binary_path"])
    observed = hashlib.sha256(binary.read_bytes()).hexdigest()
except Exception:
    raise SystemExit(1)
if not (
    value.get("installed") is True
    and value.get("loaded") is True
    and value.get("running") is True
    and isinstance(value.get("pid"), int)
    and value["pid"] > 1
    and observed == sys.argv[2]
):
    raise SystemExit(1)
PY
    then
      runtime_json="$(
        "$CLI" status --json --discover-secs 0 --config "$CONFIG" \
          2>/dev/null || true
      )"
      if python3 - "$runtime_json" <<'PY'
import json
import sys
try:
    value = json.loads(sys.argv[1])
except Exception:
    raise SystemExit(1)
raise SystemExit(0 if value.get("daemon", {}).get("running") is True else 1)
PY
      then
        echo "NVPN_RELEASE_JOIN_MARKER NVPN_MACOS_RELEASE_SERVICE_READY=1"
        return 0
      fi
    fi
    sleep 0.2
  done
  echo "macOS Release join shipped service did not become ready" >&2
  "$CLI" service status --json --config "$CONFIG" >&2 || true
  tail -n 120 "$DAEMON_LOG" >&2 2>/dev/null || true
  return 1
}

assert_fips_ready() {
  assert_service_ready >/dev/null
  local runtime_json deadline=$((SECONDS + 15))
  while ((SECONDS < deadline)); do
    runtime_json="$(
      "$CLI" status --json --discover-secs 0 --config "$CONFIG" \
        2>/dev/null || true
    )"
    if python3 - "$runtime_json" <<'PY'
import json
import sys
try:
    daemon = json.loads(sys.argv[1]).get("daemon", {})
    state = daemon.get("state") or {}
except Exception:
    raise SystemExit(1)
raise SystemExit(
    0 if daemon.get("running") is True and state.get("mesh_ready") is True else 1
)
PY
    then
      echo "NVPN_RELEASE_JOIN_MARKER NVPN_MACOS_RELEASE_FIPS_READY=1"
      return 0
    fi
    sleep 0.2
  done
  echo "macOS Release join daemon/FIPS session did not become ready" >&2
  printf '%s\n' "$runtime_json" >&2
  tail -n 120 "$DAEMON_LOG" >&2 2>/dev/null || true
  return 1
}

restore_test_profile() {
  [[ -e "$TEST_STATE_ACTIVE" || -e "$TEST_SERVICE_OWNED" ]] || return 0
  stop_app
  if [[ -e "$TEST_SERVICE_OWNED" ]]; then
    sudo -n "$CLI" service uninstall --config "$CONFIG" >/dev/null
  fi
  local name path
  for name in "${PROFILE_STATE_NAMES[@]}"; do
    path="$CONFIG_DIR/$name"
    rm -rf "$path"
    if [[ -e "$TEST_STATE_BACKUP/$name" ]]; then
      mkdir -p "$(dirname "$path")"
      mv "$TEST_STATE_BACKUP/$name" "$path"
    fi
  done
  rm -rf "$TEST_STATE_DIR"
}

service_preflight() {
  verify_import
  [[ ! -e "$TEST_STATE_ACTIVE" ]] || {
    echo "macOS Release join test profile is already active" >&2
    return 1
  }
  local status name path
  status="$(
    "$CLI" service status --json --skip-binary-version --config "$CONFIG" \
      2>/dev/null || true
  )"
  python3 - "$status" <<'PY'
import json
import sys
try:
    value = json.loads(sys.argv[1])
except Exception:
    raise SystemExit("could not verify the empty macOS service slot")
if value.get("installed") or value.get("running"):
    raise SystemExit("macOS Release join requires an empty service slot")
PY
  mkdir -p "$TEST_STATE_BACKUP" "$CONFIG_DIR"
  for name in "${PROFILE_STATE_NAMES[@]}"; do
    path="$CONFIG_DIR/$name"
    [[ ! -L "$path" ]] || {
      echo "refusing symlinked macOS profile state: $path" >&2
      return 1
    }
  done
  : >"$TEST_STATE_ACTIVE"
  for name in "${PROFILE_STATE_NAMES[@]}"; do
    path="$CONFIG_DIR/$name"
    [[ ! -e "$path" ]] || mv "$path" "$TEST_STATE_BACKUP/$name"
  done
  "$CLI" init --config "$CONFIG" --force >/dev/null
  : >"$TEST_SERVICE_OWNED"
  if ! sudo -n "$CLI" service install --force --config "$CONFIG" >/dev/null; then
    restore_test_profile
    return 1
  fi
  assert_service_ready
}

observe_delivery() {
  local recipient="$1" duration="$2"
  [[ "$duration" =~ ^[1-9][0-9]*$ && "$duration" -le 40 ]] || {
    echo "delivery observer duration must be 1..40 seconds" >&2
    return 2
  }
  assert_fips_ready >/dev/null
  python3 - "$JOIN_OUTBOX" "$DAEMON_LOG" "$recipient" "$duration" <<'PY'
import hashlib
import json
import pathlib
import sys
import time

outbox = pathlib.Path(sys.argv[1])
daemon_log = pathlib.Path(sys.argv[2])
recipient = sys.argv[3]
duration = int(sys.argv[4])
baseline = {path.name for path in outbox.glob("*.json")} if outbox.is_dir() else set()
log_offset = daemon_log.stat().st_size if daemon_log.is_file() else 0
seen = {}
deadline = time.monotonic() + duration
gone_samples = 0
while time.monotonic() < deadline:
    matching_now = set()
    for path in outbox.glob("*.json") if outbox.is_dir() else ():
        if path.name in baseline:
            continue
        try:
            value = json.loads(path.read_text(encoding="utf-8"))
        except Exception:
            continue
        if value.get("recipient_npub") != recipient:
            continue
        key = hashlib.sha256(path.name.encode()).hexdigest()
        matching_now.add(key)
        entry = seen.setdefault(
            key,
            {"maxAttempts": 0, "lastAttemptAt": 0, "consumed": False},
        )
        entry["maxAttempts"] = max(entry["maxAttempts"], int(value.get("attempts", 0)))
        entry["lastAttemptAt"] = max(entry["lastAttemptAt"], int(value.get("last_attempt_at", 0)))
    if seen and not matching_now:
        gone_samples += 1
        if gone_samples >= 5:
            break
    else:
        gone_samples = 0
    time.sleep(0.01)
for key, entry in seen.items():
    entry["consumed"] = not any(
        hashlib.sha256(path.name.encode()).hexdigest() == key
        for path in (outbox.glob("*.json") if outbox.is_dir() else ())
    )
result = {
    "schema": 1,
    "recipientSha256": hashlib.sha256(recipient.encode()).hexdigest(),
    "baselineItemCount": len(baseline),
    "observedNewItems": len(seen),
    "deliveryAttempts": sorted(entry["maxAttempts"] for entry in seen.values()),
    "items": sorted(seen.values(), key=lambda entry: entry["lastAttemptAt"]),
}
print(json.dumps(result, sort_keys=True))
if daemon_log.is_file():
    with daemon_log.open("rb") as handle:
        handle.seek(log_offset)
        sys.stderr.buffer.write(handle.read())
if not seen:
    raise SystemExit("no new recipient-bound join outbox item was observed")
PY
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
  restore_test_profile
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
    assert_fips_ready
    ;;
  joiner-id)
    [[ $# == 1 ]] || { echo "usage: $0 joiner-id" >&2; exit 2; }
    run_driver release-joiner-id _ _
    ;;
  manual-join)
    [[ $# == 3 ]] || { echo "usage: $0 manual-join <admin-npub> <network-id>" >&2; exit 2; }
    assert_fips_ready
    run_driver release-manual-join "$2" "$3"
    ;;
  admin-add)
    [[ $# == 3 ]] || { echo "usage: $0 admin-add <joiner-npub> <alias>" >&2; exit 2; }
    assert_fips_ready
    run_driver_hold release-admin-add "$2" "$3"
    ;;
  verify)
    [[ $# == 2 ]] || { echo "usage: $0 verify <participant-npub>" >&2; exit 2; }
    run_driver release-verify "$2" _
    ;;
  service-preflight)
    [[ $# == 1 ]] || { echo "usage: $0 service-preflight" >&2; exit 2; }
    service_preflight
    ;;
  assert-fips-ready)
    [[ $# == 1 ]] || { echo "usage: $0 assert-fips-ready" >&2; exit 2; }
    assert_fips_ready
    ;;
  observe-delivery)
    [[ $# == 3 ]] || { echo "usage: $0 observe-delivery <recipient-npub> <seconds>" >&2; exit 2; }
    observe_delivery "$2" "$3"
    ;;
  cleanup)
    restore_test_profile
    macos_release_app_restore
    ;;
  *)
    echo "usage: $0 <stage|prepare|verify-import|service-preflight|assert-fips-ready|observe-delivery|create-admin|joiner-id|manual-join|admin-add|verify|cleanup>" >&2
    exit 2
    ;;
esac
