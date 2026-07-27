#!/usr/bin/env bash
# Remove the exact Debian-package gate candidate and restore every pre-gate
# package-owned path even when dpkg itself reports a purge failure.
set -uo pipefail

remote_dir="${1:-}"
case "$remote_dir" in
  /tmp/nvpn-linux-vm-release.*) ;;
  *)
    echo "Refusing unsafe Ubuntu exact-package cleanup path: $remote_dir" >&2
    exit 2
    ;;
esac
[[ -d "$remote_dir" && ! -L "$remote_dir" ]] || {
  echo "Ubuntu exact-package cleanup directory is missing." >&2
  exit 2
}
[[ -f "$remote_dir/.nvpn-deb-installed" ]] || exit 0

cleanup_status=0
if ! sudo -n dpkg --purge nostr-vpn >/dev/null; then
  echo "dpkg could not purge the exact nVPN gate package." >&2
  cleanup_status=1
fi

# A failed/partial purge must not prevent restoration. Remove only regular
# files and symlinks that the candidate package owned; never remove shared
# parent directories.
package_root="$remote_dir/package-root"
if [[ -d "$package_root" && ! -L "$package_root" ]]; then
  while IFS= read -r -d '' candidate; do
    relative="${candidate#"$package_root"}"
    if [[ "$relative" != /* || "$relative" == "/" ]]; then
      echo "Unsafe Debian package path during cleanup: $candidate" >&2
      cleanup_status=1
      continue
    fi
    if ! sudo -n find "$relative" -maxdepth 0 \
      \( -type f -o -type l \) -delete
    then
      echo "Could not remove candidate package path: $relative" >&2
      cleanup_status=1
    fi
  done < <(
    find "$package_root" -mindepth 1 \( -type f -o -type l \) -print0
  )
else
  echo "Exact Debian package extraction tree is missing during cleanup." >&2
  cleanup_status=1
fi

preexisting_root="$remote_dir/preexisting-root"
if [[ -d "$preexisting_root" && ! -L "$preexisting_root" ]]; then
  if ! sudo -n cp -a "$preexisting_root/." /; then
    echo "Could not restore pre-gate package-owned paths." >&2
    cleanup_status=1
  fi
else
  echo "Pre-gate package path backup is missing." >&2
  cleanup_status=1
fi

if ! sudo -n find /var/lib/dpkg/info -maxdepth 1 \
  \( -name 'nostr-vpn.*' -o -name 'nostr-vpn:*.*' \) -delete
then
  echo "Could not clear candidate dpkg info files." >&2
  cleanup_status=1
fi
preexisting_info="$remote_dir/preexisting-dpkg-info"
if [[ -d "$preexisting_info" && ! -L "$preexisting_info" ]]; then
  if find "$preexisting_info" -mindepth 1 -print -quit | grep -q .; then
    if ! sudo -n cp -a "$preexisting_info/." /var/lib/dpkg/info/; then
      echo "Could not restore pre-gate dpkg info files." >&2
      cleanup_status=1
    fi
  fi
else
  echo "Pre-gate dpkg info backup is missing." >&2
  cleanup_status=1
fi

preexisting_paths="$remote_dir/preexisting-paths.txt"
preexisting_manifest="$remote_dir/preexisting-manifest.txt"
restored_manifest="$remote_dir/restored-manifest.txt"
if [[ -f "$preexisting_paths" && -f "$preexisting_manifest" ]]; then
  : >"$restored_manifest"
  while IFS= read -r candidate; do
    if [[ ! -e "$candidate" && ! -L "$candidate" ]]; then
      printf 'missing|%s\n' "$candidate" >>"$restored_manifest"
      cleanup_status=1
      continue
    fi
    metadata="$(stat -c '%F|%a|%u|%g|%s' "$candidate")"
    if [[ -L "$candidate" ]]; then
      digest="link:$(readlink "$candidate")"
    else
      digest="sha256:$(sha256sum "$candidate" | awk '{ print $1 }')"
    fi
    printf '%s|%s|%s\n' "$candidate" "$metadata" "$digest" \
      >>"$restored_manifest"
  done <"$preexisting_paths"
  if ! cmp -s "$preexisting_manifest" "$restored_manifest"; then
    echo "Pre-gate package-owned paths were not restored byte-for-byte." >&2
    cleanup_status=1
  fi
else
  echo "Pre-gate path manifest is missing." >&2
  cleanup_status=1
fi

post_status="$(
  dpkg-query -W -f='${db:Status-Status}' nostr-vpn 2>/dev/null || true
)"
if [[ -n "$post_status" ]]; then
  echo "nostr-vpn dpkg state remained after cleanup: $post_status" >&2
  cleanup_status=1
fi

exit "$cleanup_status"
