#!/usr/bin/env bash
# Build and launch the macOS app only inside the disposable VM.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SSH_HOST="${NVPN_MACOS_SSH_HOST:-${1:-}}"
GUEST_SRC_ROOT="${NVPN_MACOS_GUEST_SRC_ROOT:-src}"
GUEST_REPO="$GUEST_SRC_ROOT/nostr-vpn"
LOCAL_ARTIFACT_DIR="${ARTIFACT_ROOT:-$ROOT/artifacts}"
[[ -n "$SSH_HOST" ]] || {
  echo "set NVPN_MACOS_SSH_HOST or pass the macOS VM SSH target" >&2
  exit 2
}

case "${NVPN_MACOS_SKIP_GIT_SYNC:-0}" in
  1|true|TRUE|True|yes|YES|Yes|on|ON|On) ;;
  *) "$ROOT/scripts/macos-vm-git-sync.sh" "$SSH_HOST" ;;
esac

remote_env=(
  NVPN_MACOS_RUST_PROFILE=release
  NVPN_MACOS_XCODE_CONFIGURATION=Release
)
if [[ -n "${NVPN_FIPS_REPO_PATH:-}" ]]; then
  remote_env+=(NVPN_FIPS_REPO_PATH="$GUEST_SRC_ROOT/fips")
fi
remote_command="cd '$GUEST_REPO' && env"
for assignment in "${remote_env[@]}"; do
  remote_command+=" '$assignment'"
done
remote_command+=" ./scripts/macos-app-launch-smoke.sh"

ssh -o BatchMode=yes "$SSH_HOST" "$remote_command"
mkdir -p "$LOCAL_ARTIFACT_DIR"
for artifact in \
  macos-app-launch-smoke.json \
  macos-app-idle-cpu.json \
  macos-app-launch-smoke.log
do
  scp -q "$SSH_HOST:$GUEST_REPO/artifacts/$artifact" \
    "$LOCAL_ARTIFACT_DIR/$artifact" 2>/dev/null || true
done
echo "MACOS_VM_APP_LAUNCH_SMOKE_OK"
