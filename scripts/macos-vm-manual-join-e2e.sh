#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib-macos-vm-imported-release.sh"
SSH_HOST="${NVPN_MACOS_SSH_HOST:-${1:-}}"
GUEST_SRC_ROOT="${NVPN_MACOS_GUEST_SRC_ROOT:-src}"
GUEST_REPO="$GUEST_SRC_ROOT/nostr-vpn"
LOCAL_ARTIFACT_DIR="${ARTIFACT_ROOT:-$ROOT/artifacts}/macos-manual-join-ui"
[[ -n "$SSH_HOST" ]] || {
  echo "set NVPN_MACOS_SSH_HOST or pass the macOS VM SSH target" >&2
  exit 2
}

macos_vm_prepare_or_verify_imported_release "$ROOT" "$SSH_HOST"
package="$(macos_vm_imported_release_package "$GUEST_REPO")"
remote_command="cd '$GUEST_REPO' && env"
remote_command+=" 'NVPN_MACOS_VM_IMPORT_ONLY=1'"
remote_command+=" 'NVPN_MACOS_APP_PATH=$package/Nostr VPN.app'"
remote_command+=" 'NVPN_DESKTOP_MANUAL_JOIN_FIXTURE=$package/fixtures/desktop_manual_join_e2e_fixture'"
remote_command+=" 'NVPN_DESKTOP_MANUAL_JOIN_DRIVER=$package/drivers/desktop-manual-join-ax'"
remote_command+=" ./scripts/e2e-macos-manual-join-ui.sh"
ssh -o BatchMode=yes "$SSH_HOST" "$remote_command"

mkdir -p "$LOCAL_ARTIFACT_DIR"
scp -q "$SSH_HOST:$GUEST_REPO/artifacts/macos-manual-join-ui/result.json" \
  "$LOCAL_ARTIFACT_DIR/result.json"
for artifact in joiner.png admin.png app.log; do
  scp -q "$SSH_HOST:$GUEST_REPO/artifacts/macos-manual-join-ui/$artifact" \
    "$LOCAL_ARTIFACT_DIR/$artifact" 2>/dev/null || true
done
echo "MACOS_VM_DESKTOP_MANUAL_JOIN_UI_E2E_OK"
