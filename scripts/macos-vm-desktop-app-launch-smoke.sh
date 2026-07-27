#!/usr/bin/env bash
# Verify and launch the host-built, imported macOS app inside the disposable VM.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib-macos-vm-imported-release.sh"
SSH_HOST="${NVPN_MACOS_SSH_HOST:-${1:-}}"
GUEST_SRC_ROOT="${NVPN_MACOS_GUEST_SRC_ROOT:-src}"
GUEST_REPO="$GUEST_SRC_ROOT/nostr-vpn"
LOCAL_ARTIFACT_DIR="${ARTIFACT_ROOT:-$ROOT/artifacts}"
[[ -n "$SSH_HOST" ]] || {
  echo "set NVPN_MACOS_SSH_HOST or pass the macOS VM SSH target" >&2
  exit 2
}

macos_vm_prepare_or_verify_imported_release "$ROOT" "$SSH_HOST"
package="$(macos_vm_imported_release_package "$GUEST_REPO")"
remote_env=(
  NVPN_MACOS_VM_IMPORT_ONLY=1
  "NVPN_MACOS_APP_PATH=$package/Nostr VPN.app"
  NVPN_MACOS_APP_SMOKE_BUILD=0
  "NVPN_MACOS_APP_IDLE_CPU_GATE=${NVPN_MACOS_APP_IDLE_CPU_GATE:-${NVPN_IDLE_CPU_GATE:-1}}"
  "NVPN_MACOS_APP_IDLE_CPU_MAX_PERCENT=${NVPN_MACOS_APP_IDLE_CPU_MAX_PERCENT:-${NVPN_IDLE_CPU_MAX_PERCENT:-5}}"
  "NVPN_MACOS_APP_IDLE_CPU_SAMPLE_SECONDS=${NVPN_MACOS_APP_IDLE_CPU_SAMPLE_SECONDS:-${NVPN_IDLE_CPU_SAMPLE_SECONDS:-10}}"
  "NVPN_MACOS_APP_IDLE_CPU_SETTLE_SECONDS=${NVPN_MACOS_APP_IDLE_CPU_SETTLE_SECONDS:-${NVPN_IDLE_CPU_SETTLE_SECONDS:-15}}"
)
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
