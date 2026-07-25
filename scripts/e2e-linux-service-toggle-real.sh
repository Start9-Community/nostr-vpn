#!/usr/bin/env bash
# Run only on an isolated/native Linux host with nvpn.service absent. Clicks
# the shipped GTK switch, observes and cancels the real PolicyKit prompt, and
# proves the system service remains absent.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT_ROOT="${ARTIFACT_ROOT:-$ROOT/artifacts/linux-service-toggle-real}"
DATA_ROOT="$ARTIFACT_ROOT/app-data"
ADMIN_DATA_DIR="$DATA_ROOT/admin"
JOINER_DATA_DIR="$DATA_ROOT/joiner"
RESULT="$ARTIFACT_ROOT/fixture.json"
APP_LOG="$ARTIFACT_ROOT/app.log"
POLKIT_LOG="$ARTIFACT_ROOT/polkit-agent.log"
TIMEOUT_SECS="${NVPN_DESKTOP_SERVICE_TOGGLE_TIMEOUT_SECS:-30}"
LINUX_CARGO_TARGET_DIR="${NVPN_LINUX_CARGO_TARGET_DIR:-$ROOT/linux/target}"
FIXTURE="${NVPN_LINUX_FIXTURE_PATH:-$LINUX_CARGO_TARGET_DIR/debug/examples/desktop_manual_join_e2e_fixture}"
NVPN="${NVPN_LINUX_NVPN_PATH:-$LINUX_CARGO_TARGET_DIR/debug/nvpn}"
APP="${NVPN_LINUX_APP_PATH:-$LINUX_CARGO_TARGET_DIR/debug/nostr-vpn}"
app_pid=""
agent_pid=""

if [[ -z "${DISPLAY:-}" ]]; then
  exec xvfb-run -a dbus-run-session -- "$0"
fi

for command in python3 xdotool systemctl; do
  command -v "$command" >/dev/null 2>&1 \
    || { echo "real Linux service-toggle e2e requires $command" >&2; exit 2; }
done
POLKIT_AGENT=""
for candidate in \
  /usr/lib/policykit-1-gnome/polkit-gnome-authentication-agent-1 \
  /usr/libexec/polkit-gnome-authentication-agent-1; do
  if [[ -x "$candidate" ]]; then
    POLKIT_AGENT="$candidate"
    break
  fi
done
[[ -n "$POLKIT_AGENT" ]] \
  || { echo "real Linux service-toggle e2e requires a graphical PolicyKit agent" >&2; exit 2; }
for executable in "$FIXTURE" "$NVPN" "$APP"; do
  [[ -x "$executable" ]] \
    || { echo "real Linux service-toggle executable is missing: $executable" >&2; exit 2; }
done

service_snapshot() {
  systemctl show nvpn.service \
    --property=LoadState,ActiveState,SubState,UnitFileState \
    --no-pager 2>/dev/null || true
}

service_before="$(service_snapshot)"
if grep -Eq '^(LoadState=loaded|ActiveState=active|SubState=running)$' <<<"$service_before"; then
  echo "real Linux service-toggle e2e requires nvpn.service to be absent" >&2
  exit 2
fi

cleanup() {
  if [[ -n "$app_pid" ]] && kill -0 "$app_pid" >/dev/null 2>&1; then
    kill -- "-$app_pid" >/dev/null 2>&1 || kill "$app_pid" >/dev/null 2>&1 || true
    wait "$app_pid" >/dev/null 2>&1 || true
  fi
  if [[ -n "$agent_pid" ]] && kill -0 "$agent_pid" >/dev/null 2>&1; then
    kill "$agent_pid" >/dev/null 2>&1 || true
    wait "$agent_pid" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

rm -rf "$DATA_ROOT"
mkdir -p "$ARTIFACT_ROOT" "$DATA_ROOT"
rm -f "$RESULT" "$APP_LOG" "$POLKIT_LOG" "$ARTIFACT_ROOT"/*.png
"$FIXTURE" prepare \
  --admin-data-dir "$ADMIN_DATA_DIR" \
  --joiner-data-dir "$JOINER_DATA_DIR" \
  --result "$RESULT"

"$POLKIT_AGENT" >"$POLKIT_LOG" 2>&1 &
agent_pid=$!
sleep 0.5
NVPN_APP_DATA_DIR="$ADMIN_DATA_DIR" \
  NVPN_CLI_PATH="$NVPN" \
  GTK_A11Y=atspi \
  NO_AT_BRIDGE=0 \
  setsid "$APP" >"$APP_LOG" 2>&1 &
app_pid=$!

window_id=""
deadline=$((SECONDS + TIMEOUT_SECS))
while ((SECONDS < deadline)); do
  window_id="$(
    xdotool search --onlyvisible --pid "$app_pid" --name "^Nostr VPN$" \
      2>/dev/null | head -n 1 || true
  )"
  [[ -n "$window_id" ]] && break
  if ! kill -0 "$app_pid" >/dev/null 2>&1; then
    echo "real Linux app exited before creating its window" >&2
    tail -n 120 "$APP_LOG" >&2 || true
    exit 1
  fi
  sleep 0.1
done
[[ -n "$window_id" ]] || { echo "real Linux app window did not appear" >&2; exit 1; }

python3 "$ROOT/scripts/desktop-service-toggle-atspi.py" \
  --pid "$app_pid" \
  --window-id "$window_id"

auth_window=""
deadline=$((SECONDS + TIMEOUT_SECS))
while ((SECONDS < deadline)); do
  auth_window="$(
    xdotool search --onlyvisible \
      --name "Authentication Required|Authenticate" 2>/dev/null \
      | head -n 1 || true
  )"
  [[ -n "$auth_window" ]] && break
  sleep 0.1
done
[[ -n "$auth_window" ]] \
  || { echo "real GTK VPN toggle did not open a PolicyKit prompt" >&2; exit 1; }

if command -v import >/dev/null 2>&1; then
  import -window "$auth_window" "$ARTIFACT_ROOT/authentication-prompt.png" || true
fi
xdotool windowfocus --sync "$auth_window"
xdotool key --clearmodifiers Escape

deadline=$((SECONDS + 5))
while ((SECONDS < deadline)); do
  if ! xdotool search --onlyvisible \
    --name "Authentication Required|Authenticate" >/dev/null 2>&1
  then
    break
  fi
  sleep 0.1
done
if xdotool search --onlyvisible \
  --name "Authentication Required|Authenticate" >/dev/null 2>&1
then
  echo "PolicyKit prompt remained visible after cancellation" >&2
  exit 1
fi

service_after="$(service_snapshot)"
[[ "$service_after" == "$service_before" ]] \
  || { echo "cancelled real Linux prompt changed nvpn.service state" >&2; exit 1; }
echo "LINUX_SERVICE_TOGGLE_POLICYKIT_PROMPT_OK"
