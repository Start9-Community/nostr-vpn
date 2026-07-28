#!/usr/bin/env bash
# Recover only an exact, receipt-bound Debian package left by an interrupted
# nVPN release gate on its isolated Ubuntu VM.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLEANUP="$ROOT/scripts/ubuntu-vm-exact-deb-cleanup.sh"

fail() {
  echo "Ubuntu stale import recovery failed: $*" >&2
  exit 1
}

remove_import_dir() {
  local path="$1"
  [[ "$path" == /tmp/nvpn-linux-vm-release.* \
    && -d "$path" && ! -L "$path" ]] \
    || fail "refusing unsafe import directory removal: $path"
  find "$path" -xdev -depth -mindepth 1 -delete
  rmdir "$path"
  [[ ! -e "$path" && ! -L "$path" ]] \
    || fail "import directory survived removal: $path"
}

write_package_manifest() {
  local root="$1"
  local output="$2"
  (
    cd "$root"
    while IFS= read -r -d '' relative; do
      relative="${relative#./}"
      [[ "$relative" != *$'\n'* ]] \
        || fail "package payload contains a newline in its path"
      if [[ -L "$relative" ]]; then
        printf '%s|link|%s|%s\n' \
          "$relative" \
          "$(stat -c '%a' "$relative")" \
          "$(readlink "$relative")"
      else
        printf '%s|file|%s|%s|%s\n' \
          "$relative" \
          "$(stat -c '%a' "$relative")" \
          "$(stat -c '%s' "$relative")" \
          "$(sha256sum "$relative" | awk '{ print $1 }')"
      fi
    done < <(
      find . -mindepth 1 \( -type f -o -type l \) -print0 | sort -z
    )
  ) >"$output"
}

[[ -x "$CLEANUP" ]] || fail "exact Debian cleanup script is unavailable"
command -v flock >/dev/null 2>&1 || fail "flock is unavailable"
command -v jq >/dev/null 2>&1 || fail "jq is unavailable"

if [[ "${NVPN_UBUNTU_IMPORT_LOCK_HELD:-0}" != "1" ]]; then
  lock_root="$HOME/.cache/nostr-vpn-release-gate"
  mkdir -p "$lock_root"
  chmod 0700 "$lock_root"
  exec 9>"$lock_root/ubuntu-import.lock"
  flock -w 30 9 || fail "could not acquire the Ubuntu import recovery lock"
fi

current_uid="$(id -u)"
shopt -s nullglob
candidate_dirs=(/tmp/nvpn-linux-vm-release.*)
marked_dirs=()
for path in "${candidate_dirs[@]}"; do
  if [[ -e "$path/.nvpn-deb-installed" \
    || -L "$path/.nvpn-deb-installed" ]]
  then
    [[ -d "$path" && ! -L "$path" ]] \
      || fail "marked import path is not a real directory: $path"
    [[ "$(stat -c '%u' "$path")" == "$current_uid" ]] \
      || fail "marked import directory has the wrong owner: $path"
    [[ "$(stat -c '%a' "$path")" == "700" ]] \
      || fail "marked import directory has the wrong mode: $path"
    [[ -f "$path/.nvpn-deb-installed" \
      && ! -L "$path/.nvpn-deb-installed" ]] \
      || fail "candidate ownership marker is not a regular file: $path"
    marked_dirs+=("$path")
  fi
done

package_status="$(
  dpkg-query -W -f='${db:Status-Status}' nostr-vpn 2>/dev/null || true
)"
if ((${#marked_dirs[@]} == 0)); then
  [[ -z "$package_status" ]] \
    || fail "unmarked nostr-vpn package state is present: $package_status"
  echo "UBUNTU_STALE_IMPORT_RECOVERY_CLEAN"
  exit 0
fi
(( ${#marked_dirs[@]} == 1 )) \
  || fail "multiple marked nVPN import directories are present"

stale_dir="${marked_dirs[0]}"
phase="$(cat "$stale_dir/.nvpn-deb-installed")"
case "$phase" in
  "") phase="legacy-installed" ;;
  copying|installing|installed|cleaning) ;;
  *) fail "marked import has an unknown lifecycle phase" ;;
esac
if [[ "$phase" == "copying" ]]; then
  [[ -z "$package_status" ]] \
    || fail "copying import does not own package state: $package_status"
  remove_import_dir "$stale_dir"
  echo "UBUNTU_STALE_IMPORT_RECOVERY_OK"
  exit 0
fi

bundle_receipt="$stale_dir/receipt.json"
install_receipt="$stale_dir/debian-package-install.json"
deb="$stale_dir/nostr-vpn.deb"
for path in \
  "$bundle_receipt" \
  "$install_receipt" \
  "$deb" \
  "$stale_dir/preexisting-paths.txt" \
  "$stale_dir/preexisting-manifest.txt"
do
  [[ -f "$path" && ! -L "$path" ]] \
    || fail "marked import evidence is missing or unsafe: $path"
done
for path in \
  "$stale_dir/package-root" \
  "$stale_dir/preexisting-root" \
  "$stale_dir/preexisting-dpkg-info"
do
  [[ -d "$path" && ! -L "$path" ]] \
    || fail "marked import evidence directory is missing or unsafe: $path"
done

jq -e --slurpfile bundle "$bundle_receipt" '
  $bundle[0] as $b
  | .schema == 2
    and .artifactType == "exact Debian package installed on Ubuntu VM"
    and .appGitSha == $b.appGitSha
    and .appGitTree == $b.appGitTree
    and .fipsGitSha == $b.fipsGitSha
    and .fipsGitTree == $b.fipsGitTree
    and .appVersion == $b.appVersion
    and .package == "nostr-vpn"
    and .packageArchitecture == "amd64"
    and .packageInstalledByDpkg == true
    and .installedStatus == "installed"
    and .installedAppPath == "/usr/bin/nostr-vpn"
    and .installedCliPath == "/usr/bin/nvpn"
    and .debSha256 == $b.artifacts.debianPackage.sha256
    and .debSize == $b.artifacts.debianPackage.size
    and .installedAppSha256 == $b.artifacts.app.sha256
    and .installedCliSha256 == $b.artifacts.cli.sha256
' "$install_receipt" >/dev/null \
  || fail "install receipt does not match its exact bundle receipt"

[[ "$(jq -er '.schema' "$bundle_receipt")" == "2" ]] \
  || fail "bundle receipt schema is invalid"
app_version="$(jq -er '.appVersion' "$bundle_receipt")"
deb_hash="$(jq -er '.artifacts.debianPackage.sha256' "$bundle_receipt")"
deb_size="$(jq -er '.artifacts.debianPackage.size' "$bundle_receipt")"
app_hash="$(jq -er '.artifacts.app.sha256' "$bundle_receipt")"
cli_hash="$(jq -er '.artifacts.cli.sha256' "$bundle_receipt")"
bundle_hash="$(jq -er '.bundleReceiptSha256' "$install_receipt")"
app_size="$(jq -er '.artifacts.app.size' "$bundle_receipt")"
cli_size="$(jq -er '.artifacts.cli.size' "$bundle_receipt")"

[[ "$bundle_hash" == "$(sha256sum "$bundle_receipt" | awk '{ print $1 }')" ]] \
  || fail "bundle receipt hash does not match the install receipt"
[[ "$deb_hash" == "$(sha256sum "$deb" | awk '{ print $1 }')" \
  && "$deb_size" == "$(stat -c '%s' "$deb")" ]] \
  || fail "stale Debian package bytes do not match the receipt"
[[ "$(dpkg-deb -f "$deb" Package)" == "nostr-vpn" \
  && "$(dpkg-deb -f "$deb" Version)" == "$app_version-1" \
  && "$(dpkg-deb -f "$deb" Architecture)" == "amd64" ]] \
  || fail "stale Debian package metadata does not match the receipt"

verification_root="$(mktemp -d /tmp/nvpn-linux-vm-recovery-verify.XXXXXX)"
trap 'rm -rf "$verification_root"' EXIT
dpkg-deb -x "$deb" "$verification_root/extracted"
dpkg-deb -e "$deb" "$verification_root/control"
write_package_manifest \
  "$stale_dir/package-root" "$verification_root/captured.manifest"
write_package_manifest \
  "$verification_root/extracted" "$verification_root/deb.manifest"
cmp -s \
  "$verification_root/captured.manifest" "$verification_root/deb.manifest" \
  || fail "captured package tree differs from the exact stale Debian package"

find "$verification_root/control" -mindepth 1 -maxdepth 1 \
  -printf '%f\n' | LC_ALL=C sort >"$verification_root/control-files"
control_shape="$(cat "$verification_root/control-files")"
case "$control_shape" in
  "control"|$'control\nmd5sums') ;;
  *) fail "automatic recovery refuses Debian maintainer scripts" ;;
esac
(
  cd "$verification_root/extracted"
  while IFS= read -r -d '' relative; do
    relative="${relative#./}"
    md5sum "$relative"
  done < <(find . -mindepth 1 -type f -print0 | sort -z)
) | LC_ALL=C sort >"$verification_root/expected-md5sums"
if [[ -f "$verification_root/control/md5sums" ]]; then
  LC_ALL=C sort "$verification_root/control/md5sums" \
    >"$verification_root/control-md5sums"
  cmp -s \
    "$verification_root/expected-md5sums" \
    "$verification_root/control-md5sums" \
    || fail "Debian control checksums differ from the exact payload"
fi
(
  cd "$verification_root/extracted"
  find . -mindepth 1 -printf '/%P\n'
) | LC_ALL=C sort -u >"$verification_root/deb-paths"

package_root="$stale_dir/package-root"
while IFS= read -r -d '' candidate; do
  relative="${candidate#"$package_root"}"
  [[ "$relative" == /* && "$relative" != "/" ]] \
    || fail "captured package payload has an unsafe path"
  if [[ -e "$relative" || -L "$relative" ]]; then
    if [[ -L "$candidate" ]]; then
      [[ -L "$relative" \
        && "$(readlink "$relative")" == "$(readlink "$candidate")" ]] \
        || fail "live package symlink differs from the exact payload: $relative"
    else
      [[ -f "$relative" && ! -L "$relative" \
        && "$(stat -c '%a' "$relative")" == "$(stat -c '%a' "$candidate")" ]] \
        || fail "live package file type or mode differs: $relative"
      cmp -s "$candidate" "$relative" \
        || fail "live package file bytes differ: $relative"
    fi
  fi
done < <(
  find "$package_root" -mindepth 1 \( -type f -o -type l \) -print0
)

find /var/lib/dpkg/info -mindepth 1 -maxdepth 1 \
  \( -name 'nostr-vpn.*' -o -name 'nostr-vpn:*.*' \) \
  -printf '%f\n' | LC_ALL=C sort >"$verification_root/installed-info-files"
printf 'nostr-vpn.list\nnostr-vpn.md5sums\n' \
  >"$verification_root/expected-info-files"
while IFS= read -r info_name; do
  case "$info_name" in
    nostr-vpn.list|nostr-vpn.md5sums) ;;
    *) fail "installed dpkg info set has an unsafe file: $info_name" ;;
  esac
done <"$verification_root/installed-info-files"
if [[ -f /var/lib/dpkg/info/nostr-vpn.md5sums ]]; then
  LC_ALL=C sort /var/lib/dpkg/info/nostr-vpn.md5sums \
    >"$verification_root/installed-md5sums"
  cmp -s \
    "$verification_root/expected-md5sums" \
    "$verification_root/installed-md5sums" \
    || fail "installed dpkg checksums differ from the exact Debian package"
fi
if [[ -f /var/lib/dpkg/info/nostr-vpn.list ]]; then
  awk '$0 != "/." && $0 != ""' /var/lib/dpkg/info/nostr-vpn.list \
    | LC_ALL=C sort -u >"$verification_root/installed-paths"
  comm -23 \
    "$verification_root/installed-paths" \
    "$verification_root/deb-paths" \
    >"$verification_root/unexpected-installed-paths"
  [[ ! -s "$verification_root/unexpected-installed-paths" ]] \
    || fail "installed dpkg path list escapes the exact Debian package"
fi
[[ ! -s "$stale_dir/preexisting-paths.txt" \
  && ! -s "$stale_dir/preexisting-manifest.txt" ]] \
  || fail "automatic recovery requires an empty preexisting path journal"
if find "$stale_dir/preexisting-root" -mindepth 1 -print -quit \
    | grep -q . \
  || find "$stale_dir/preexisting-dpkg-info" -mindepth 1 -print -quit \
    | grep -q .
then
  fail "automatic recovery requires empty preexisting backup trees"
fi

installed_metadata="$(
  dpkg-query -W -f='${db:Status-Status}|${Version}|${Architecture}' \
    nostr-vpn 2>/dev/null || true
)"
if [[ -n "$installed_metadata" ]]; then
  [[ "$installed_metadata" == *"|$app_version-1|amd64" ]] \
    || fail "Debian metadata differs from the exact stale package"
  case "${installed_metadata%%|*}" in
    config-files|half-installed|unpacked|half-configured|\
triggers-awaited|triggers-pending|installed) ;;
    *) fail "Debian package is in an unknown recovery state" ;;
  esac
fi
if [[ "$phase" == "installed" || "$phase" == "legacy-installed" ]]; then
  [[ "$installed_metadata" == "installed|$app_version-1|amd64" ]] \
    || fail "installed lifecycle phase lacks its exact package"
fi
if [[ "$installed_metadata" == "installed|$app_version-1|amd64" ]]; then
  [[ "$(dpkg-query -S /usr/bin/nostr-vpn)" \
      == "nostr-vpn: /usr/bin/nostr-vpn" \
    && "$(dpkg-query -S /usr/bin/nvpn)" == "nostr-vpn: /usr/bin/nvpn" ]] \
    || fail "installed binary ownership does not belong to nostr-vpn"
  for path in /usr/bin/nostr-vpn /usr/bin/nvpn; do
    [[ -f "$path" && ! -L "$path" ]] \
      || fail "receipt-owned binary is missing or unsafe: $path"
  done
  [[ "$(sha256sum /usr/bin/nostr-vpn | awk '{ print $1 }')" == "$app_hash" \
    && "$(stat -c '%s' /usr/bin/nostr-vpn)" == "$app_size" ]] \
    || fail "installed app bytes do not match the stale receipt"
  [[ "$(sha256sum /usr/bin/nvpn | awk '{ print $1 }')" == "$cli_hash" \
    && "$(stat -c '%s' /usr/bin/nvpn)" == "$cli_size" ]] \
    || fail "installed CLI bytes do not match the stale receipt"
  cmp -s \
    "$verification_root/installed-info-files" \
    "$verification_root/expected-info-files" \
    || fail "installed dpkg info set differs from the exact package"
  dpkg-query -L nostr-vpn | awk '$0 != "/."' | LC_ALL=C sort -u \
    >"$verification_root/installed-paths"
  cmp -s \
    "$verification_root/deb-paths" "$verification_root/installed-paths" \
    || fail "installed dpkg path list differs from the exact Debian package"
fi

bash "$CLEANUP" "$stale_dir" \
  || fail "exact Debian cleanup failed; preserving recovery evidence"
post_status="$(
  dpkg-query -W -f='${db:Status-Status}' nostr-vpn 2>/dev/null || true
)"
[[ -z "$post_status" ]] \
  || fail "nostr-vpn package state survived exact recovery: $post_status"

rm -rf "$verification_root"
trap - EXIT
remove_import_dir "$stale_dir"
for path in /tmp/nvpn-linux-vm-release.*; do
  if [[ -e "$path/.nvpn-deb-installed" \
    || -L "$path/.nvpn-deb-installed" ]]
  then
    fail "marked Ubuntu import directory survived exact recovery: $path"
  fi
done
echo "UBUNTU_STALE_IMPORT_RECOVERY_OK"
