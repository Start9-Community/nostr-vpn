#!/usr/bin/env bash
# Import and drive both shipped GTK manual-join roles on an isolated Linux VM.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SSH_HOST="${NVPN_UBUNTU_SSH_HOST:-${1:-}}"
GUEST_SRC_ROOT="${NVPN_UBUNTU_GUEST_SRC_ROOT:-src}"
GUEST_REPO="$GUEST_SRC_ROOT/nostr-vpn-release-gate"
[[ -n "$SSH_HOST" ]] || {
  echo "set NVPN_UBUNTU_SSH_HOST or pass the Linux VM SSH target" >&2
  exit 2
}

# shellcheck disable=SC1091
source "$ROOT/scripts/lib-ubuntu-vm-imported-release.sh"
export NVPN_UBUNTU_IMPORT_EVIDENCE_DIR="$ROOT/artifacts/ubuntu-vm-import/manual-join"

cleanup() {
  local status="$?"
  trap - EXIT
  if ! ubuntu_vm_cleanup_imported_release_bundle; then
    status=1
  fi
  exit "$status"
}
trap cleanup EXIT

case "${NVPN_UBUNTU_SKIP_GIT_SYNC:-0}" in
  1|true|TRUE|True|yes|YES|Yes|on|ON|On) ;;
  *) "$ROOT/scripts/ubuntu-vm-git-sync.sh" "$SSH_HOST" ;;
esac
ubuntu_vm_import_release_bundle
ubuntu_vm_import_ssh_command

"${NVPN_UBUNTU_IMPORT_SSH[@]}" bash -s -- \
  "$GUEST_REPO" \
  "$NVPN_UBUNTU_IMPORTED_APP" \
  "$NVPN_UBUNTU_IMPORTED_CLI" \
  "$NVPN_UBUNTU_IMPORTED_FIXTURE" <<'GUEST'
set -euo pipefail
repo="$1"
app="$2"
cli="$3"
fixture="$4"
cd "$repo"
env \
  NVPN_REPO_ROOT="$repo" \
  NVPN_LINUX_APP_PATH="$app" \
  NVPN_LINUX_NVPN_PATH="$cli" \
  NVPN_LINUX_FIXTURE_PATH="$fixture" \
  xvfb-run -a dbus-run-session -- ./linux/scripts/e2e-manual-join-ui.sh
python3 - <<'PY'
import json
from pathlib import Path

artifact = Path("artifacts/linux-manual-join-ui")
result = json.loads((artifact / "result.json").read_text(encoding="utf-8"))
required = {
    "phase": "runtime-verified",
    "exactSignedRosterDurablyApplied": True,
    "adminOutboxConsumedByExactJoinRosterAck": True,
    "publicFipsCrossSeedRouteOnly": True,
}
for key, expected in required.items():
    if result.get(key) != expected:
        raise SystemExit(f"Linux manual-join result lacks {key}={expected!r}")
for name in (
    "admin-daemon.log",
    "joiner-daemon.log",
    "admin-status.json",
    "joiner-status.json",
    "timings.json",
):
    if not (artifact / name).is_file():
        raise SystemExit(f"Linux manual-join artifact missing: {name}")
PY
GUEST

echo "UBUNTU_VM_DESKTOP_MANUAL_JOIN_UI_E2E_OK"
