#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SSH_HOST="${NVPN_MACOS_SSH_HOST:-${1:-}}"
GUEST_SRC_ROOT="${NVPN_MACOS_GUEST_SRC_ROOT:-src}"
GUEST_REPO="$GUEST_SRC_ROOT/nostr-vpn"
LOCAL_ARTIFACT_DIR="${ARTIFACT_ROOT:-$ROOT/artifacts}/macos-manual-join-ui"
[[ -n "$SSH_HOST" ]] || {
  echo "set NVPN_MACOS_SSH_HOST or pass the macOS VM SSH target" >&2
  exit 2
}

case "${NVPN_MACOS_SKIP_GIT_SYNC:-0}" in
  1|true|TRUE|True|yes|YES|Yes|on|ON|On) ;;
  *) "$ROOT/scripts/macos-vm-git-sync.sh" "$SSH_HOST" ;;
esac

if [[ -n "${NVPN_FIPS_REPO_PATH:-}" ]]; then
  remote_command="cd '$GUEST_REPO' && env NVPN_FIPS_REPO_PATH='$GUEST_SRC_ROOT/fips' ./scripts/e2e-macos-manual-join-ui.sh"
else
  remote_command="cd '$GUEST_REPO' && ./scripts/e2e-macos-manual-join-ui.sh"
fi
ssh -o BatchMode=yes "$SSH_HOST" "$remote_command"

mkdir -p "$LOCAL_ARTIFACT_DIR"
scp -q "$SSH_HOST:$GUEST_REPO/artifacts/macos-manual-join-ui/result.json" \
  "$LOCAL_ARTIFACT_DIR/result.json"
for artifact in joiner.png admin.png app.log; do
  scp -q "$SSH_HOST:$GUEST_REPO/artifacts/macos-manual-join-ui/$artifact" \
    "$LOCAL_ARTIFACT_DIR/$artifact" 2>/dev/null || true
done
echo "MACOS_VM_DESKTOP_MANUAL_JOIN_UI_E2E_OK"
