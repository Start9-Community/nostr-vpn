#!/usr/bin/env bash
# Adversarially prove that a dpkg purge failure cannot skip restoration of the
# Ubuntu VM's pre-gate package-owned files.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLEANUP="$ROOT/scripts/ubuntu-vm-exact-deb-cleanup.sh"
[[ -x "$CLEANUP" ]] || {
  echo "Ubuntu exact-package cleanup script is not executable." >&2
  exit 1
}
command -v docker >/dev/null 2>&1 || {
  echo "Ubuntu exact-package cleanup harness requires Docker." >&2
  exit 2
}

docker run --rm \
  --interactive \
  --platform linux/amd64 \
  --volume "$CLEANUP:/cleanup.sh:ro" \
  ubuntu:24.04 \
  bash -se <<'CONTAINER'
set -euo pipefail
remote_dir=/tmp/nvpn-linux-vm-release.cleanup-adversarial
mkdir -p \
  /shim \
  "$remote_dir/package-root/usr/bin" \
  "$remote_dir/preexisting-root/usr/bin" \
  "$remote_dir/preexisting-dpkg-info"

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'while [[ "${1:-}" == "-n" ]]; do shift; done' \
  'exec "$@"' \
  >/shim/sudo
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'if [[ "${1:-}" == "--purge" && "${2:-}" == "nostr-vpn" ]]; then' \
  '  echo "injected purge failure" >&2' \
  '  exit 42' \
  'fi' \
  'exec /usr/bin/dpkg "$@"' \
  >/shim/dpkg
chmod 0755 /shim/sudo /shim/dpkg

printf 'old-pre-gate-app\n' >/usr/bin/nostr-vpn
chmod 0755 /usr/bin/nostr-vpn
cp -a /usr/bin/nostr-vpn \
  "$remote_dir/preexisting-root/usr/bin/nostr-vpn"
printf '/usr/bin/nostr-vpn\n' >"$remote_dir/preexisting-paths.txt"
metadata="$(stat -c '%F|%a|%u|%g|%s' /usr/bin/nostr-vpn)"
digest="$(sha256sum /usr/bin/nostr-vpn | awk '{ print $1 }')"
printf '/usr/bin/nostr-vpn|%s|sha256:%s\n' "$metadata" "$digest" \
  >"$remote_dir/preexisting-manifest.txt"

printf 'old-orphan-info\n' \
  >"$remote_dir/preexisting-dpkg-info/nostr-vpn.list"
printf 'candidate-info\n' >/var/lib/dpkg/info/nostr-vpn.list
printf 'candidate-package-app\n' >/usr/bin/nostr-vpn
chmod 0755 /usr/bin/nostr-vpn
printf 'candidate-package-app\n' \
  >"$remote_dir/package-root/usr/bin/nostr-vpn"
chmod 0755 "$remote_dir/package-root/usr/bin/nostr-vpn"
touch "$remote_dir/.nvpn-deb-installed"

set +e
PATH="/shim:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  bash /cleanup.sh "$remote_dir"
status="$?"
set -e
[[ "$status" != 0 ]]
grep -Fxq old-pre-gate-app /usr/bin/nostr-vpn
grep -Fxq old-orphan-info /var/lib/dpkg/info/nostr-vpn.list
cmp -s \
  "$remote_dir/preexisting-manifest.txt" \
  "$remote_dir/restored-manifest.txt"
echo UBUNTU_EXACT_DEB_PURGE_FAILURE_RESTORE_OK
CONTAINER
