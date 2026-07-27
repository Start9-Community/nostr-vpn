#!/usr/bin/env bash
# Build or launch a macOS app bundle and verify it survives startup.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT_ROOT="${ARTIFACT_ROOT:-$ROOT/artifacts}"
APP_PATH="${NVPN_MACOS_APP_PATH:-${1:-}}"
VM_IMPORT_ONLY="${NVPN_MACOS_VM_IMPORT_ONLY:-0}"
STARTUP_TIMEOUT_SECONDS="${NVPN_MACOS_APP_SMOKE_STARTUP_TIMEOUT_SECONDS:-30}"
ALIVE_SECONDS="${NVPN_MACOS_APP_SMOKE_ALIVE_SECONDS:-5}"
RESULT_PATH="$ARTIFACT_ROOT/macos-app-launch-smoke.json"
IDLE_CPU_RESULT_PATH="$ARTIFACT_ROOT/macos-app-idle-cpu.json"
LOG_PATH="$ARTIFACT_ROOT/macos-app-launch-smoke.log"
IDLE_CPU_GATE="${NVPN_MACOS_APP_IDLE_CPU_GATE:-${NVPN_IDLE_CPU_GATE:-1}}"
IDLE_CPU_MAX_PERCENT="${NVPN_MACOS_APP_IDLE_CPU_MAX_PERCENT:-${NVPN_IDLE_CPU_MAX_PERCENT:-5}}"
IDLE_CPU_SAMPLE_SECONDS="${NVPN_MACOS_APP_IDLE_CPU_SAMPLE_SECONDS:-${NVPN_IDLE_CPU_SAMPLE_SECONDS:-10}}"
IDLE_CPU_SETTLE_SECONDS="${NVPN_MACOS_APP_IDLE_CPU_SETTLE_SECONDS:-${NVPN_IDLE_CPU_SETTLE_SECONDS:-15}}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "macOS app launch smoke requires macOS." >&2
  exit 1
fi

mkdir -p "$ARTIFACT_ROOT"

if [[ -z "$APP_PATH" ]]; then
  case "$VM_IMPORT_ONLY" in
    1|true|TRUE|True|yes|YES|Yes|on|ON|On)
      echo "VM import-only app smoke requires NVPN_MACOS_APP_PATH and NVPN_MACOS_APP_SMOKE_BUILD=0." >&2
      exit 2
      ;;
  esac
  case "${NVPN_MACOS_APP_SMOKE_BUILD:-1}" in
    0|false|FALSE|False|no|NO|No|off|OFF|Off)
      echo "Set NVPN_MACOS_APP_PATH or pass a .app path when NVPN_MACOS_APP_SMOKE_BUILD=0." >&2
      exit 2
      ;;
    *)
      "$ROOT/scripts/macos-build" macos-build
      APP_PATH="$("$ROOT/scripts/build-output-path" --raw)"
      ;;
  esac
fi

case "$VM_IMPORT_ONLY:${NVPN_MACOS_APP_SMOKE_BUILD:-1}" in
  1:0|true:0|TRUE:0|True:0|yes:0|YES:0|Yes:0|on:0|ON:0|On:0) ;;
  1:*|true:*|TRUE:*|True:*|yes:*|YES:*|Yes:*|on:*|ON:*|On:*)
    echo "VM import-only app smoke requires NVPN_MACOS_APP_SMOKE_BUILD=0." >&2
    exit 2
    ;;
esac

if [[ ! -d "$APP_PATH" ]]; then
  echo "macOS app bundle not found: $APP_PATH" >&2
  exit 1
fi
codesign --verify --deep --strict "$APP_PATH"

executable="$(
  /usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP_PATH/Contents/Info.plist" 2>/dev/null \
    || basename "$APP_PATH" .app
)"

app_pids() {
  pgrep -x "$executable" 2>/dev/null || pgrep -f "$APP_PATH/Contents/MacOS/$executable" 2>/dev/null || true
}

write_result() {
  local ok="$1"
  local error="${2:-}"
  local pid="${3:-}"
  local idle_cpu_result=""
  case "$IDLE_CPU_GATE" in
    0|false|FALSE|False|no|NO|No|off|OFF|Off)
      ;;
    *)
      idle_cpu_result="$IDLE_CPU_RESULT_PATH"
      ;;
  esac
  cat >"$RESULT_PATH" <<JSON
{
  "ok": $ok,
  "appPath": "$APP_PATH",
  "executable": "$executable",
  "processId": "$pid",
  "idleCpuResult": "$idle_cpu_result",
  "error": "$error",
  "generatedAt": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
JSON
}

capture_logs() {
  log show --style compact --last 2m --predicate "process == \"$executable\"" >"$LOG_PATH" 2>&1 || true
}

if pids="$(app_pids)" && [[ -n "$pids" ]]; then
  kill $pids >/dev/null 2>&1 || true
  sleep 1
fi

touch "$APP_PATH"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f -R -trusted "$APP_PATH" >/dev/null 2>&1 || true

open -n "$APP_PATH"

pid=""
deadline=$((SECONDS + STARTUP_TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  pid="$(app_pids | head -n 1 || true)"
  if [[ -n "$pid" ]]; then
    break
  fi
  sleep 0.5
done

if [[ -z "$pid" ]]; then
  capture_logs
  write_result false "macOS app did not create a process within ${STARTUP_TIMEOUT_SECONDS}s"
  echo "macOS app launch smoke failed: no process appeared for $APP_PATH" >&2
  tail -n 80 "$LOG_PATH" >&2 || true
  exit 1
fi

alive_until=$((SECONDS + ALIVE_SECONDS))
while (( SECONDS < alive_until )); do
  if ! kill -0 "$pid" >/dev/null 2>&1; then
    capture_logs
    write_result false "macOS app exited during startup" "$pid"
    echo "macOS app launch smoke failed: process $pid exited during startup." >&2
    tail -n 80 "$LOG_PATH" >&2 || true
    exit 1
  fi
  sleep 0.5
done

case "$IDLE_CPU_GATE" in
  0|false|FALSE|False|no|NO|No|off|OFF|Off)
    echo "Skipping macOS app idle CPU gate because NVPN_MACOS_APP_IDLE_CPU_GATE=$IDLE_CPU_GATE"
    ;;
  *)
    "$ROOT/scripts/idle-cpu-gate.py" host-pid \
      --pid "$pid" \
      --label "macOS app" \
      --artifact "$IDLE_CPU_RESULT_PATH" \
      --max-percent "$IDLE_CPU_MAX_PERCENT" \
      --sample-seconds "$IDLE_CPU_SAMPLE_SECONDS" \
      --settle-seconds "$IDLE_CPU_SETTLE_SECONDS"
    ;;
esac

write_result true "" "$pid"
kill "$pid" >/dev/null 2>&1 || true
echo "MACOS_APP_LAUNCH_SMOKE_OK"
echo "Result: $RESULT_PATH"
