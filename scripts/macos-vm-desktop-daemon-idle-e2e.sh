#!/usr/bin/env bash
# Run the launchd/VPN/idle-CPU service proof only inside the disposable macOS
# VM so the release gate cannot install a daemon or routes on its host.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SSH_HOST="${NVPN_MACOS_SSH_HOST:-${1:-}}"
GUEST_SRC_ROOT="${NVPN_MACOS_GUEST_SRC_ROOT:-src}"
GUEST_REPO="$GUEST_SRC_ROOT/nostr-vpn"
REMOTE_RESULT="$GUEST_REPO/artifacts/macos-daemon-idle-cpu.json"
LOCAL_RESULT="${ARTIFACT_ROOT:-$ROOT/artifacts}/macos-daemon-idle-cpu.json"
[[ -n "$SSH_HOST" ]] || {
  echo "set NVPN_MACOS_SSH_HOST or pass the macOS VM SSH target" >&2
  exit 2
}

case "${NVPN_MACOS_SKIP_GIT_SYNC:-0}" in
  1|true|TRUE|True|yes|YES|Yes|on|ON|On) ;;
  *) "$ROOT/scripts/macos-vm-git-sync.sh" "$SSH_HOST" ;;
esac

remote_env=(
  NVPN_RUN_MACOS_SERVICE_E2E=1
  NVPN_MACOS_DAEMON_IDLE_CPU_RESULT="$REMOTE_RESULT"
  NVPN_MACOS_DAEMON_IDLE_CPU_MAX_PERCENT="${NVPN_MACOS_DAEMON_IDLE_CPU_MAX_PERCENT:-${NVPN_IDLE_CPU_MAX_PERCENT:-2}}"
  NVPN_MACOS_DAEMON_IDLE_CPU_SAMPLE_SECONDS="${NVPN_MACOS_DAEMON_IDLE_CPU_SAMPLE_SECONDS:-${NVPN_IDLE_CPU_SAMPLE_SECONDS:-60}}"
  NVPN_MACOS_DAEMON_IDLE_CPU_SETTLE_SECONDS="${NVPN_MACOS_DAEMON_IDLE_CPU_SETTLE_SECONDS:-${NVPN_IDLE_CPU_SETTLE_SECONDS:-15}}"
)
if [[ -n "${NVPN_FIPS_REPO_PATH:-}" ]]; then
  remote_env+=(NVPN_FIPS_REPO_PATH="$GUEST_SRC_ROOT/fips")
fi
remote_command="cd '$GUEST_REPO' && mkdir -p artifacts && env"
for assignment in "${remote_env[@]}"; do
  remote_command+=" '$assignment'"
done
remote_command+=" ./scripts/e2e-macos-service.sh"

ssh -o BatchMode=yes "$SSH_HOST" "$remote_command"
mkdir -p "$(dirname "$LOCAL_RESULT")"
scp -q "$SSH_HOST:$REMOTE_RESULT" "$LOCAL_RESULT"
echo "MACOS_VM_DAEMON_IDLE_CPU_E2E_OK"
