#!/usr/bin/env bash
# Hold the isolated Ubuntu release-import lock until the controlling host
# closes stdin. An SSH disconnect also closes stdin and releases flock.
set -euo pipefail

lock_root="$HOME/.cache/nostr-vpn-release-gate"
mkdir -p "$lock_root"
chmod 0700 "$lock_root"
[[ -d "$lock_root" && ! -L "$lock_root" \
  && "$(stat -c '%u' "$lock_root")" == "$(id -u)" \
  && "$(stat -c '%a' "$lock_root")" == "700" ]]
exec 9>"$lock_root/ubuntu-import.lock"
flock -w 30 9
echo UBUNTU_IMPORT_LIFECYCLE_LOCK_READY
IFS= read -r -n 1 _ || true
