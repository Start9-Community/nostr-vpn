#!/usr/bin/env bash
# Remove the exact Debian-package gate candidate and restore every pre-gate
# package-owned path after dpkg has serialized and purged the package.
set -uo pipefail

remote_dir="${1:-}"
serialized_dpkg="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ubuntu-vm-serialized-dpkg.sh"
[[ -x "$serialized_dpkg" ]] || {
  echo "Ubuntu serialized dpkg helper is unavailable." >&2
  exit 2
}
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
marker="$remote_dir/.nvpn-deb-installed"
[[ -f "$marker" && ! -L "$marker" ]] || exit 0
phase="$(cat "$marker")"
case "$phase" in
  ""|copying|installing|installed|cleaning) ;;
  *)
    echo "Ubuntu exact-package cleanup lifecycle phase is invalid." >&2
    exit 2
    ;;
esac
write_phase() {
  local next_phase="$1"
  local phase_temp
  phase_temp="$(mktemp "$remote_dir/.nvpn-deb-phase.XXXXXX")" || return 1
  if ! printf '%s\n' "$next_phase" >"$phase_temp" \
    || ! chmod 0400 "$phase_temp" \
    || ! mv "$phase_temp" "$marker"
  then
    rm -f "$phase_temp"
    return 1
  fi
  return 0
}

cleanup_status=0
pre_status="$(
  dpkg-query -W -f='${db:Status-Status}' nostr-vpn 2>/dev/null || true
)"
if [[ "$phase" == "copying" ]]; then
  [[ -z "$pre_status" ]] || {
    echo "Copying-phase import does not own the present package state." >&2
    exit 2
  }
  exit 0
fi
write_phase cleaning || {
  echo "Could not journal Ubuntu exact-package cleanup." >&2
  exit 2
}
if ! "$serialized_dpkg" purge >/dev/null; then
  echo "dpkg could not serialize and purge the exact nVPN gate package." >&2
  exit 1
fi
post_purge_status="$(
  dpkg-query -W -f='${db:Status-Status}' nostr-vpn 2>/dev/null || true
)"
if [[ -n "$post_purge_status" ]]; then
  echo "nostr-vpn dpkg state remained after purge: $post_purge_status" >&2
  exit 1
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
    if sudo -n test ! -e "$relative" && sudo -n test ! -L "$relative"; then
      continue
    fi
    if ! sudo -n find "$relative" -maxdepth 0 \
      \( -type f -o -type l \) -delete
    then
      if sudo -n test ! -e "$relative" && sudo -n test ! -L "$relative"; then
        continue
      fi
      echo "Could not remove candidate package path: $relative" >&2
      cleanup_status=1
    elif sudo -n test -e "$relative" || sudo -n test -L "$relative"; then
      echo "Unexpected candidate package path type: $relative" >&2
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
preexisting_paths="$remote_dir/preexisting-paths.txt"
if [[ -d "$preexisting_root" && ! -L "$preexisting_root" ]]; then
  if [[ -f "$preexisting_paths" && ! -L "$preexisting_paths" ]]; then
    while IFS= read -r candidate; do
      [[ "$candidate" == /* && "$candidate" != "/" ]] || {
        echo "Unsafe pre-gate package path during restoration." >&2
        cleanup_status=1
        continue
      }
      source_path="$preexisting_root$candidate"
      [[ -f "$source_path" || -L "$source_path" ]] || {
        echo "Pre-gate package path backup is missing: $candidate" >&2
        cleanup_status=1
        continue
      }
      if sudo -n test -e "$candidate" || sudo -n test -L "$candidate"; then
        echo "Refusing to overwrite a surviving package path: $candidate" >&2
        cleanup_status=1
        continue
      fi
      if ! sudo -n cp -a -- "$source_path" "$candidate"; then
        echo "Could not restore pre-gate package path: $candidate" >&2
        cleanup_status=1
      fi
    done <"$preexisting_paths"
  else
    echo "Pre-gate package path list is missing." >&2
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
  while IFS= read -r -d '' source_path; do
    [[ -f "$source_path" || -L "$source_path" ]] || {
      echo "Pre-gate dpkg info backup contains an unsafe type." >&2
      cleanup_status=1
      continue
    }
    info_name="${source_path##*/}"
    case "$info_name" in
      nostr-vpn.*|nostr-vpn:*.*) ;;
      *)
        echo "Pre-gate dpkg info backup contains an unsafe name." >&2
        cleanup_status=1
        continue
        ;;
    esac
    target_path="/var/lib/dpkg/info/$info_name"
    if sudo -n test -e "$target_path" || sudo -n test -L "$target_path"; then
      echo "Refusing to overwrite surviving dpkg info: $info_name" >&2
      cleanup_status=1
      continue
    fi
    if ! sudo -n cp -a -- "$source_path" "$target_path"; then
      echo "Could not restore pre-gate dpkg info: $info_name" >&2
      cleanup_status=1
    fi
  done < <(find "$preexisting_info" -mindepth 1 -maxdepth 1 -print0)
else
  echo "Pre-gate dpkg info backup is missing." >&2
  cleanup_status=1
fi

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
