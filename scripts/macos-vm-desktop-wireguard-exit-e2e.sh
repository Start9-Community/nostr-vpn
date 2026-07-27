#!/usr/bin/env bash
# Run the scoped native WireGuard exit self-test only inside the disposable
# macOS VM. The release gate must never mutate the developer host's routes.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib-macos-vm-imported-release.sh"
SSH_HOST="${NVPN_MACOS_SSH_HOST:-${1:-}}"
GUEST_SRC_ROOT="${NVPN_MACOS_GUEST_SRC_ROOT:-src}"
GUEST_REPO="$GUEST_SRC_ROOT/nostr-vpn"
[[ -n "$SSH_HOST" ]] || {
  echo "set NVPN_MACOS_SSH_HOST or pass the macOS VM SSH target" >&2
  exit 2
}

macos_vm_prepare_or_verify_imported_release "$ROOT" "$SSH_HOST"
package="$(macos_vm_imported_release_package "$GUEST_REPO")"
remote_env=(
  NVPN_MACOS_VM_IMPORT_ONLY=1
  "NVPN_WG_EXIT_HOST_BINARY=$package/Nostr VPN.app/Contents/Resources/nvpn"
)
remote_command="cd '$GUEST_REPO' && env"
for assignment in "${remote_env[@]}"; do
  remote_command+=" '$assignment'"
done
remote_command+=" ./scripts/e2e-wireguard-exit-host.sh"

ssh -o BatchMode=yes "$SSH_HOST" "$remote_command"
echo "MACOS_VM_WIREGUARD_EXIT_E2E_OK"
