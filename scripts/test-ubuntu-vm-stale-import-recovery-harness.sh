#!/usr/bin/env bash
# Exercise stale Ubuntu import recovery with a real dpkg package and the exact
# production recovery/cleanup scripts.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RECOVERY="$ROOT/scripts/ubuntu-vm-recover-stale-import.sh"
CLEANUP="$ROOT/scripts/ubuntu-vm-exact-deb-cleanup.sh"
IMPORT_LIB="$ROOT/scripts/lib-ubuntu-vm-imported-release.sh"
LOCK_HOLDER="$ROOT/scripts/ubuntu-vm-import-lock-holder.sh"
[[ -x "$RECOVERY" && -x "$CLEANUP" && -f "$IMPORT_LIB" \
  && -x "$LOCK_HOLDER" ]] || {
  echo "Ubuntu stale import recovery harness scripts are unavailable." >&2
  exit 1
}
command -v docker >/dev/null 2>&1 || {
  echo "Ubuntu stale import recovery harness requires Docker." >&2
  exit 2
}

docker run --rm \
  --interactive \
  --platform linux/amd64 \
  --volume "$RECOVERY:/repo/scripts/ubuntu-vm-recover-stale-import.sh:ro" \
  --volume "$CLEANUP:/repo/scripts/ubuntu-vm-exact-deb-cleanup.sh:ro" \
  --volume "$IMPORT_LIB:/repo/scripts/lib-ubuntu-vm-imported-release.sh:ro" \
  --volume "$LOCK_HOLDER:/repo/scripts/ubuntu-vm-import-lock-holder.sh:ro" \
  ubuntu:24.04 \
  bash -se <<'CONTAINER'
set -euo pipefail
apt-get update >/dev/null
DEBIAN_FRONTEND=noninteractive \
  apt-get install -y --no-install-recommends jq >/dev/null
mkdir -p /shim /tmp/home
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'while [[ "${1:-}" == "-n" ]]; do shift; done' \
  'if [[ "${INJECT_PURGE_FAILURE:-0}" == "1" \' \
  '  && "${1:-}" == "dpkg" && "${2:-}" == "--purge" ]]; then' \
  '  exit 42' \
  'fi' \
  'exec "$@"' \
  >/shim/sudo
chmod 0755 /shim/sudo
export HOME=/tmp/home
export PATH="/shim:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

(
  # shellcheck disable=SC1091
  source /repo/scripts/lib-ubuntu-vm-imported-release.sh
  SSH_HOST=local
  GUEST_REPO=/repo
  ubuntu_vm_import_ssh_command() {
    NVPN_UBUNTU_IMPORT_SSH=(env HOME=/tmp/home)
  }
  ubuntu_vm_acquire_import_lock
  [[ -n "$NVPN_UBUNTU_IMPORT_LOCK_PID" ]]
  if flock -n \
    /tmp/home/.cache/nostr-vpn-release-gate/ubuntu-import.lock true
  then
    echo "second import acquired the held lifecycle lock" >&2
    exit 1
  fi
  ubuntu_vm_release_import_lock
  flock -n \
    /tmp/home/.cache/nostr-vpn-release-gate/ubuntu-import.lock true

  ubuntu_vm_acquire_import_lock
  killed_holder="$NVPN_UBUNTU_IMPORT_LOCK_PID"
  kill -s TERM "$killed_holder"
  set +e
  wait "$killed_holder"
  set -e
  set +e
  ubuntu_vm_recover_stale_imported_release_bundle
  recovery_status="$?"
  set -e
  [[ "$recovery_status" != 0 ]]
  exec 8>&-
  rm -rf "$NVPN_UBUNTU_IMPORT_LOCK_TEMP"
  NVPN_UBUNTU_IMPORT_LOCK_PID=""
  NVPN_UBUNTU_IMPORT_LOCK_TEMP=""
  flock -n \
    /tmp/home/.cache/nostr-vpn-release-gate/ubuntu-import.lock true
)
echo UBUNTU_IMPORT_LIFECYCLE_LOCK_OK

make_owned_fixture() {
  local remote_dir="$1"
  local package_build="$2"
  local package_root="$remote_dir/package-root"
  rm -rf "$remote_dir" "$package_build"
  mkdir -m 0700 "$remote_dir"
  mkdir -p \
    "$package_build/DEBIAN" \
    "$package_build/usr/bin" \
    "$package_root" \
    "$remote_dir/preexisting-root" \
    "$remote_dir/preexisting-dpkg-info"
  printf '%s\n' \
    'Package: nostr-vpn' \
    'Version: 4.1.5-1' \
    'Architecture: amd64' \
    'Maintainer: Test <test@example.invalid>' \
    'Description: exact stale import recovery fixture' \
    >"$package_build/DEBIAN/control"
  printf 'fixture-app\n' >"$package_build/usr/bin/nostr-vpn"
  printf 'fixture-cli\n' >"$package_build/usr/bin/nvpn"
  chmod 0755 \
    "$package_build/usr/bin/nostr-vpn" \
    "$package_build/usr/bin/nvpn"
  (
    cd "$package_build"
    md5sum usr/bin/nostr-vpn usr/bin/nvpn
  ) >"$package_build/DEBIAN/md5sums"
  dpkg-deb --build "$package_build" "$remote_dir/nostr-vpn.deb" >/dev/null
  dpkg-deb -x "$remote_dir/nostr-vpn.deb" "$package_root"
  : >"$remote_dir/preexisting-paths.txt"
  : >"$remote_dir/preexisting-manifest.txt"
  dpkg --install "$remote_dir/nostr-vpn.deb" >/dev/null

  local app_hash cli_hash deb_hash deb_size
  app_hash="$(sha256sum /usr/bin/nostr-vpn | awk '{ print $1 }')"
  cli_hash="$(sha256sum /usr/bin/nvpn | awk '{ print $1 }')"
  deb_hash="$(sha256sum "$remote_dir/nostr-vpn.deb" | awk '{ print $1 }')"
  deb_size="$(stat -c '%s' "$remote_dir/nostr-vpn.deb")"
  jq -n \
    --arg app_hash "$app_hash" \
    --arg cli_hash "$cli_hash" \
    --arg deb_hash "$deb_hash" \
    --argjson app_size "$(stat -c '%s' /usr/bin/nostr-vpn)" \
    --argjson cli_size "$(stat -c '%s' /usr/bin/nvpn)" \
    --argjson deb_size "$deb_size" \
    '{
      schema: 2,
      appGitSha: ("a" * 40),
      appGitTree: ("b" * 40),
      fipsGitSha: ("c" * 40),
      fipsGitTree: ("d" * 40),
      appVersion: "4.1.5",
      artifacts: {
        app: {sha256: $app_hash, size: $app_size},
        cli: {sha256: $cli_hash, size: $cli_size},
        debianPackage: {sha256: $deb_hash, size: $deb_size}
      }
    }' >"$remote_dir/receipt.json"
  local bundle_hash
  bundle_hash="$(sha256sum "$remote_dir/receipt.json" | awk '{ print $1 }')"
  jq -n \
    --arg app_hash "$app_hash" \
    --arg cli_hash "$cli_hash" \
    --arg deb_hash "$deb_hash" \
    --arg bundle_hash "$bundle_hash" \
    --argjson deb_size "$deb_size" \
    '{
      schema: 2,
      artifactType: "exact Debian package installed on Ubuntu VM",
      appGitSha: ("a" * 40),
      appGitTree: ("b" * 40),
      fipsGitSha: ("c" * 40),
      fipsGitTree: ("d" * 40),
      appVersion: "4.1.5",
      package: "nostr-vpn",
      packageArchitecture: "amd64",
      packageInstalledByDpkg: true,
      installedStatus: "installed",
      installedAppPath: "/usr/bin/nostr-vpn",
      installedCliPath: "/usr/bin/nvpn",
      debSha256: $deb_hash,
      debSize: $deb_size,
      installedAppSha256: $app_hash,
      installedCliSha256: $cli_hash,
      bundleReceiptSha256: $bundle_hash
    }' >"$remote_dir/debian-package-install.json"
  touch "$remote_dir/.nvpn-deb-installed"
}

bash /repo/scripts/ubuntu-vm-recover-stale-import.sh \
  | grep -Fx UBUNTU_STALE_IMPORT_RECOVERY_CLEAN

unmarked=/tmp/nvpn-linux-vm-release.unmarked
mkdir -m 0700 "$unmarked"
printf 'preserve-me\n' >"$unmarked/evidence"
bash /repo/scripts/ubuntu-vm-recover-stale-import.sh \
  | grep -Fx UBUNTU_STALE_IMPORT_RECOVERY_CLEAN
grep -Fxq preserve-me "$unmarked/evidence"

copying=/tmp/nvpn-linux-vm-release.copying
mkdir -m 0700 "$copying"
printf 'partial-copy\n' >"$copying/artifact.copy"
printf 'copying\n' >"$copying/.nvpn-deb-installed"
bash /repo/scripts/ubuntu-vm-recover-stale-import.sh \
  | grep -Fx UBUNTU_STALE_IMPORT_RECOVERY_OK
[[ ! -e "$copying" ]]

remote_dir=/tmp/nvpn-linux-vm-release.valid
package_build=/tmp/nostr-vpn-package-valid
make_owned_fixture "$remote_dir" "$package_build"
bash /repo/scripts/ubuntu-vm-recover-stale-import.sh \
  | grep -Fx UBUNTU_STALE_IMPORT_RECOVERY_OK
[[ ! -e "$remote_dir" ]]
grep -Fxq preserve-me "$unmarked/evidence"
[[ -z "$(dpkg-query -W -f='${db:Status-Status}' nostr-vpn 2>/dev/null || true)" ]]

make_owned_fixture "$remote_dir" "$package_build"
dpkg --purge nostr-vpn >/dev/null
printf 'installing\n' >"$remote_dir/.nvpn-deb-installed"
bash /repo/scripts/ubuntu-vm-recover-stale-import.sh \
  | grep -Fx UBUNTU_STALE_IMPORT_RECOVERY_OK
[[ ! -e "$remote_dir" ]]

make_owned_fixture "$remote_dir" "$package_build"
dpkg --purge nostr-vpn >/dev/null
dpkg --unpack "$remote_dir/nostr-vpn.deb" >/dev/null
printf 'installing\n' >"$remote_dir/.nvpn-deb-installed"
bash /repo/scripts/ubuntu-vm-recover-stale-import.sh \
  | grep -Fx UBUNTU_STALE_IMPORT_RECOVERY_OK
[[ ! -e "$remote_dir" ]]

make_owned_fixture "$remote_dir" "$package_build"
dpkg --purge nostr-vpn >/dev/null
printf 'cleaning\n' >"$remote_dir/.nvpn-deb-installed"
bash /repo/scripts/ubuntu-vm-recover-stale-import.sh \
  | grep -Fx UBUNTU_STALE_IMPORT_RECOVERY_OK
[[ ! -e "$remote_dir" ]]

make_owned_fixture "$remote_dir" "$package_build"
rm "$remote_dir/.nvpn-deb-installed"
set +e
bash /repo/scripts/ubuntu-vm-recover-stale-import.sh
status=$?
set -e
[[ "$status" != 0 ]]
[[ "$(dpkg-query -W -f='${db:Status-Status}' nostr-vpn)" == "installed" ]]
dpkg --purge nostr-vpn >/dev/null
rm -rf "$remote_dir" "$package_build"

make_owned_fixture "$remote_dir" "$package_build"
second=/tmp/nvpn-linux-vm-release.second
mkdir -m 0700 "$second"
touch "$second/.nvpn-deb-installed"
set +e
bash /repo/scripts/ubuntu-vm-recover-stale-import.sh
status=$?
set -e
[[ "$status" != 0 ]]
[[ "$(dpkg-query -W -f='${db:Status-Status}' nostr-vpn)" == "installed" ]]
rm -rf "$second"

mkdir -p "$remote_dir/package-root/etc"
printf 'injected-delete-target\n' \
  >"$remote_dir/package-root/etc/nvpn-injected"
set +e
bash /repo/scripts/ubuntu-vm-recover-stale-import.sh
status=$?
set -e
[[ "$status" != 0 ]]
[[ -f "$remote_dir/.nvpn-deb-installed" ]]
[[ "$(dpkg-query -W -f='${db:Status-Status}' nostr-vpn)" == "installed" ]]
rm -rf "$remote_dir/package-root/etc"

mkdir -p "$remote_dir/preexisting-root/etc"
set +e
bash /repo/scripts/ubuntu-vm-recover-stale-import.sh
status=$?
set -e
[[ "$status" != 0 ]]
[[ -d "$remote_dir/preexisting-root/etc" ]]
[[ "$(dpkg-query -W -f='${db:Status-Status}' nostr-vpn)" == "installed" ]]
rmdir "$remote_dir/preexisting-root/etc"

printf 'tampered-cli\n' >/usr/bin/nvpn
set +e
bash /repo/scripts/ubuntu-vm-recover-stale-import.sh
status=$?
set -e
[[ "$status" != 0 ]]
[[ -f "$remote_dir/.nvpn-deb-installed" ]]
[[ "$(dpkg-query -W -f='${db:Status-Status}' nostr-vpn)" == "installed" ]]
dpkg --purge nostr-vpn >/dev/null
rm -rf "$remote_dir" "$package_build"

unsafe_target=/tmp/nvpn-release-unsafe-target
mkdir "$unsafe_target"
touch "$unsafe_target/.nvpn-deb-installed"
ln -s "$unsafe_target" "$remote_dir"
set +e
bash /repo/scripts/ubuntu-vm-recover-stale-import.sh
status=$?
set -e
[[ "$status" != 0 ]]
[[ -L "$remote_dir" ]]
rm "$remote_dir"
rm -rf "$unsafe_target" "$unmarked"

echo UBUNTU_STALE_IMPORT_RECOVERY_HARNESS_OK
CONTAINER
