#!/usr/bin/env bash
# Push the exact working tree to an isolated private checkout on the Linux VM.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SSH_HOST="${NVPN_UBUNTU_SSH_HOST:-${1:-}}"
GUEST_SRC_ROOT="${NVPN_UBUNTU_GUEST_SRC_ROOT:-src}"
GUEST_REPO="$GUEST_SRC_ROOT/nostr-vpn-release-gate"
GUEST_BARE="$GUEST_SRC_ROOT/nostr-vpn-release-gate.git"
REMOTE_REF="${NVPN_UBUNTU_GIT_REF:-refs/heads/codex/ubuntu-vm-sync}"
[[ -n "$SSH_HOST" ]] || {
  echo "set NVPN_UBUNTU_SSH_HOST or pass the Linux VM SSH target" >&2
  exit 2
}
if [[ "$GUEST_SRC_ROOT" != /* ]]; then
  remote_home="$(ssh -o BatchMode=yes "$SSH_HOST" 'printf %s "$HOME"')"
  GUEST_SRC_ROOT="$remote_home/$GUEST_SRC_ROOT"
  GUEST_REPO="$GUEST_SRC_ROOT/nostr-vpn-release-gate"
  GUEST_BARE="$GUEST_SRC_ROOT/nostr-vpn-release-gate.git"
fi

make_sync_commit() {
  local git_dir tmp_index tree
  git_dir="$(git -C "$ROOT" rev-parse --path-format=absolute --git-dir)"
  tmp_index="$(mktemp "$git_dir/ubuntu-vm-index.XXXXXX")"
  (
    export GIT_INDEX_FILE="$tmp_index"
    git -C "$ROOT" read-tree HEAD
    git -C "$ROOT" add -A
    tree="$(git -C "$ROOT" write-tree)"
    printf 'Temporary Ubuntu VM sync\n' | git -C "$ROOT" commit-tree "$tree"
  )
  rm -f "$tmp_index"
}

ssh -o BatchMode=yes "$SSH_HOST" \
  "mkdir -p '$GUEST_SRC_ROOT'; test -d '$GUEST_BARE' || git init --bare '$GUEST_BARE'"
if [[ -z "$(git -C "$ROOT" status --porcelain)" ]]; then
  sync_commit="$(git -C "$ROOT" rev-parse HEAD)"
else
  sync_commit="$(make_sync_commit)"
fi
GIT_SSH_COMMAND="ssh -o BatchMode=yes" \
  git -C "$ROOT" push --force "$SSH_HOST:$GUEST_BARE" "$sync_commit:$REMOTE_REF"
ssh -o BatchMode=yes "$SSH_HOST" "
  set -e
  if [ ! -d '$GUEST_REPO/.git' ]; then
    rm -rf '$GUEST_REPO'
    git clone '$GUEST_BARE' '$GUEST_REPO'
  fi
  # This checkout is release-gate scratch space. A prior interrupted build can
  # update generated lockfiles, so clear tracked scratch changes before moving
  # to the exact candidate ref.
  git -C '$GUEST_REPO' reset --hard HEAD
  git -C '$GUEST_REPO' remote set-url origin '$GUEST_BARE'
  git -C '$GUEST_REPO' fetch origin '$REMOTE_REF'
  git -C '$GUEST_REPO' checkout -B '${REMOTE_REF#refs/heads/}' FETCH_HEAD
  git -C '$GUEST_REPO' reset --hard FETCH_HEAD
  git -C '$GUEST_REPO' clean -ffd -e target/ -e linux/target/ -e artifacts/
"
echo "UBUNTU_VM_GIT_SYNC_OK nostr-vpn"
