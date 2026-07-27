#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib-macos-vm-imported-release.sh"
SSH_HOST="${NVPN_MACOS_SSH_HOST:-${1:-}}"
GUEST_SRC_ROOT="${NVPN_MACOS_GUEST_SRC_ROOT:-src}"
GUEST_REPO="$GUEST_SRC_ROOT/nostr-vpn"
LOCAL_ARTIFACT_DIR="${ARTIFACT_ROOT:-$ROOT/artifacts}/macos-service-toggle"
[[ -n "$SSH_HOST" ]] || {
  echo "set NVPN_MACOS_SSH_HOST or pass the macOS VM SSH target" >&2
  exit 2
}

macos_vm_prepare_or_verify_imported_release "$ROOT" "$SSH_HOST"
package="$(macos_vm_imported_release_package "$GUEST_REPO")"
remote_command="cd '$GUEST_REPO' && env"
remote_command+=" 'NVPN_MACOS_VM_IMPORT_ONLY=1'"
remote_command+=" 'NVPN_MACOS_APP_PATH=$package/Nostr VPN.app'"
remote_command+=" 'NVPN_DESKTOP_SERVICE_TOGGLE_FIXTURE=$package/fixtures/desktop_manual_join_e2e_fixture'"
remote_command+=" 'NVPN_DESKTOP_SERVICE_TOGGLE_DRIVER=$package/drivers/macos-service-toggle-ax'"
remote_command+=" ./scripts/e2e-macos-service-toggle.sh"
ssh -o BatchMode=yes "$SSH_HOST" "$remote_command"

mkdir -p "$LOCAL_ARTIFACT_DIR"
for artifact in fixture.json window-after-cancel.png app.log; do
  scp -q "$SSH_HOST:$GUEST_REPO/artifacts/macos-service-toggle/$artifact" \
    "$LOCAL_ARTIFACT_DIR/$artifact" 2>/dev/null || true
done
echo "MACOS_VM_SERVICE_TOGGLE_E2E_OK"
