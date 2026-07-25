#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SSH_HOST="${NVPN_MACOS_SSH_HOST:-${1:-}}"
GUEST_SRC_ROOT="${NVPN_MACOS_GUEST_SRC_ROOT:-src}"
GUEST_REPO="$GUEST_SRC_ROOT/nostr-vpn"
LOCAL_ARTIFACT_DIR="${ARTIFACT_ROOT:-$ROOT/artifacts}/macos-service-toggle"
[[ -n "$SSH_HOST" ]] || {
  echo "set NVPN_MACOS_SSH_HOST or pass the macOS VM SSH target" >&2
  exit 2
}

case "${NVPN_MACOS_SKIP_GIT_SYNC:-0}" in
  1|true|TRUE|True|yes|YES|Yes|on|ON|On) ;;
  *) "$ROOT/scripts/macos-vm-git-sync.sh" "$SSH_HOST" ;;
esac

remote_env=(
  NVPN_MACOS_XCODE_CONFIGURATION=Release
)
if [[ -n "${NVPN_FIPS_REPO_PATH:-}" ]]; then
  remote_env+=(NVPN_FIPS_REPO_PATH="$GUEST_SRC_ROOT/fips")
fi

remote_command="cd '$GUEST_REPO' && "
case "${NVPN_MACOS_SERVICE_TOGGLE_REUSE_BUILD:-0}" in
  1|true|TRUE|True|yes|YES|Yes|on|ON|On)
    remote_command+="app_path=\"\$(NVPN_MACOS_XCODE_CONFIGURATION=Release ./scripts/build-output-path --raw)\" && env"
    remote_env+=(NVPN_DESKTOP_SERVICE_TOGGLE_SKIP_FIXTURE_BUILD=1)
    reuse_app_path=' NVPN_MACOS_APP_PATH="$app_path"'
    ;;
  *)
    remote_command+="env"
    reuse_app_path=""
    ;;
esac
for assignment in "${remote_env[@]}"; do
  remote_command+=" '$assignment'"
done
remote_command+="$reuse_app_path ./scripts/e2e-macos-service-toggle.sh"
ssh -o BatchMode=yes "$SSH_HOST" "$remote_command"

mkdir -p "$LOCAL_ARTIFACT_DIR"
for artifact in fixture.json window-after-cancel.png app.log; do
  scp -q "$SSH_HOST:$GUEST_REPO/artifacts/macos-service-toggle/$artifact" \
    "$LOCAL_ARTIFACT_DIR/$artifact" 2>/dev/null || true
done
echo "MACOS_VM_SERVICE_TOGGLE_E2E_OK"
