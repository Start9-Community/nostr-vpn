#!/usr/bin/env bash
# Clicks the real GTK VPN switch with a missing-service state and verifies the
# production app requests PolicyKit elevation. The elevated fixture command is
# inert, so this cannot modify the host's installed service.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT_ROOT="${ARTIFACT_ROOT:-$ROOT/artifacts/linux-service-toggle}"
DATA_DIR="$ARTIFACT_ROOT/app-data"
RESULT="$ARTIFACT_ROOT/fixture.json"
FAKE_NVPN="$ARTIFACT_ROOT/nvpn-e2e"

if [[ -z "${DISPLAY:-}" ]]; then
  exec xvfb-run -a dbus-run-session -- "$0"
fi

for command in cargo xdotool; do
  command -v "$command" >/dev/null 2>&1 \
    || { echo "linux service-toggle E2E requires $command" >&2; exit 2; }
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
  || { echo "linux service-toggle E2E requires a graphical PolicyKit agent" >&2; exit 2; }

mkdir -p "$ARTIFACT_ROOT"
rm -rf "$DATA_DIR"
rm -f "$RESULT"

cargo build -q -p nostr-vpn-app-core --example desktop_roster_e2e_fixture
CARGO_TARGET="$(cargo metadata --no-deps --format-version 1 \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])')"
FIXTURE="$CARGO_TARGET/debug/examples/desktop_roster_e2e_fixture"
"$FIXTURE" prepare --data-dir "$DATA_DIR" --result "$RESULT"

LINUX_CARGO_TARGET_DIR="${NVPN_LINUX_CARGO_TARGET_DIR:-$ROOT/linux/target}"
(cd "$ROOT/linux" && CARGO_TARGET_DIR="$LINUX_CARGO_TARGET_DIR" cargo build -q)
LINUX_TARGET="$(cd "$ROOT/linux" && CARGO_TARGET_DIR="$LINUX_CARGO_TARGET_DIR" \
  cargo metadata --no-deps --format-version 1 \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])')"
APP_EXE="$LINUX_TARGET/debug/nostr-vpn"

cat >"$FAKE_NVPN" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "version" && "${2:-}" == "--json" ]]; then
  printf '%s\n' '{"version":"4.1.4"}'
  exit 0
fi
if [[ "${1:-}" == "service" && "${2:-}" == "status" ]]; then
  printf '%s\n' '{"supported":true,"installed":false,"disabled":false,"loaded":false,"running":false,"pid":null,"label":"fi.siriusbusiness.nvpn.e2e","binary_version":""}'
  exit 0
fi
if [[ "${1:-}" == "status" ]]; then
  printf '%s\n' '{"daemon":{"running":false,"state":null}}'
  exit 0
fi
if [[ "${1:-}" == "service" && "${2:-}" == "install" ]]; then
  exit 0
fi
exit 1
SH
chmod +x "$FAKE_NVPN"

service_before="$(systemctl show nvpn.service --property=LoadState,ActiveState --value 2>/dev/null || true)"
"$POLKIT_AGENT" >"$ARTIFACT_ROOT/polkit-agent.log" 2>&1 &
agent_pid=$!
sleep 0.5
NVPN_APP_DATA_DIR="$DATA_DIR" \
NVPN_CLI_PATH="$FAKE_NVPN" \
XDG_DATA_HOME="$ARTIFACT_ROOT/xdg-data" \
setsid "$APP_EXE" >"$ARTIFACT_ROOT/app.log" 2>&1 &
app_pid=$!

cleanup() {
  if kill -0 "$app_pid" >/dev/null 2>&1; then
    kill -- "-$app_pid" >/dev/null 2>&1 || true
    wait "$app_pid" >/dev/null 2>&1 || true
  fi
  if kill -0 "$agent_pid" >/dev/null 2>&1; then
    kill "$agent_pid" >/dev/null 2>&1 || true
    wait "$agent_pid" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

window=""
for _ in $(seq 1 80); do
  window="$(xdotool search --onlyvisible --name '^Nostr VPN$' 2>/dev/null | head -n 1 || true)"
  [[ -n "$window" ]] && break
  sleep 0.25
done
[[ -n "$window" ]] || { echo "real GTK window did not appear" >&2; exit 1; }

geometry="$(xdotool getwindowgeometry --shell "$window")"
width="$(printf '%s\n' "$geometry" | sed -n 's/^WIDTH=//p')"
printf '%s\n' "$geometry"
if command -v import >/dev/null 2>&1; then
  import -window "$window" "$ARTIFACT_ROOT/window.png"
fi
[[ "$width" =~ ^[0-9]+$ ]] || { echo "could not read GTK window geometry" >&2; exit 1; }
# The VPN switch is the first header-bar control from the right, before the
# standard minimize/maximize/close controls.
xdotool windowfocus --sync "$window"
xdotool mousemove --window "$window" "$((width - 149))" 28 \
  mousedown 1 sleep 0.2 mouseup 1
sleep 0.5
if command -v import >/dev/null 2>&1; then
  import -window "$window" "$ARTIFACT_ROOT/window-after-toggle.png"
fi

auth_window=""
for _ in $(seq 1 80); do
  auth_window="$(xdotool search --onlyvisible \
    --name 'Authentication Required|Authenticate' 2>/dev/null | head -n 1 || true)"
  [[ -n "$auth_window" ]] && break
  sleep 0.25
done
[[ -n "$auth_window" ]] \
  || { echo "GTK VPN toggle did not open a PolicyKit authentication prompt" >&2; exit 1; }
if command -v import >/dev/null 2>&1; then
  import -window "$auth_window" "$ARTIFACT_ROOT/authentication-prompt.png"
fi

service_after="$(systemctl show nvpn.service --property=LoadState,ActiveState --value 2>/dev/null || true)"
[[ "$service_after" == "$service_before" ]] \
  || { echo "service-toggle E2E unexpectedly changed the host service state" >&2; exit 1; }

echo "LINUX_SERVICE_TOGGLE_POLICYKIT_PROMPT_OK"
