#!/usr/bin/env bash
# Run the scoped native WireGuard exit self-test only inside the disposable
# macOS VM. The release gate must never mutate the developer host's routes.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SSH_HOST="${NVPN_MACOS_SSH_HOST:-${1:-}}"
GUEST_SRC_ROOT="${NVPN_MACOS_GUEST_SRC_ROOT:-src}"
GUEST_REPO="$GUEST_SRC_ROOT/nostr-vpn"
[[ -n "$SSH_HOST" ]] || {
  echo "set NVPN_MACOS_SSH_HOST or pass the macOS VM SSH target" >&2
  exit 2
}

case "${NVPN_MACOS_SKIP_GIT_SYNC:-0}" in
  1|true|TRUE|True|yes|YES|Yes|on|ON|On) ;;
  *) "$ROOT/scripts/macos-vm-git-sync.sh" "$SSH_HOST" ;;
esac

remote_env=(NVPN_WG_EXIT_HOST_PROFILE=release)
if [[ -n "${NVPN_FIPS_REPO_PATH:-}" ]]; then
  remote_env+=(NVPN_FIPS_REPO_PATH="$GUEST_SRC_ROOT/fips")
fi
remote_command="cd '$GUEST_REPO' && env"
for assignment in "${remote_env[@]}"; do
  remote_command+=" '$assignment'"
done
remote_command+=" ./scripts/e2e-wireguard-exit-host.sh"

ssh -o BatchMode=yes "$SSH_HOST" "$remote_command"
echo "MACOS_VM_WIREGUARD_EXIT_E2E_OK"
