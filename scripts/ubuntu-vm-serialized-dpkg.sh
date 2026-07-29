#!/usr/bin/env bash
# Run one exact dpkg transaction while respecting a concurrent apt/dpkg owner.
# Only the well-defined lock-contention failure is retried; every package or
# maintainer-script failure is returned immediately.
set -euo pipefail

ACTION="${1:-}"
if (($# > 0)); then
  shift
fi
case "$ACTION" in
  install)
    [[ "$#" == 1 ]] || {
      echo "usage: $0 install /tmp/nvpn-linux-vm-release.*/nostr-vpn.deb" >&2
      exit 2
    }
    PACKAGE="$1"
    case "$PACKAGE" in
      /tmp/nvpn-linux-vm-release.*/nostr-vpn.deb) ;;
      *)
        echo "refusing unsafe Ubuntu nVPN package path: $PACKAGE" >&2
        exit 2
        ;;
    esac
    [[ -f "$PACKAGE" && ! -L "$PACKAGE" ]] || {
      echo "Ubuntu nVPN package is not a regular file: $PACKAGE" >&2
      exit 2
    }
    DPKG_ARGS=(--install "$PACKAGE")
    ;;
  purge)
    [[ "$#" == 0 ]] || {
      echo "usage: $0 purge" >&2
      exit 2
    }
    DPKG_ARGS=(--purge nostr-vpn)
    ;;
  *)
    echo "usage: $0 install PACKAGE | purge" >&2
    exit 2
    ;;
esac

ERROR_FILE="$(mktemp "${TMPDIR:-/tmp}/nvpn-dpkg-error.XXXXXX")"
cleanup() {
  rm -f "$ERROR_FILE"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

deadline=$((SECONDS + 300))
while true; do
  : >"$ERROR_FILE"
  if LC_ALL=C sudo -n dpkg "${DPKG_ARGS[@]}" 2>"$ERROR_FILE"; then
    break
  fi
  first_line="$(sed -n '1p' "$ERROR_FILE")"
  if ! grep -Eq \
    '^dpkg: error: dpkg (frontend |database )?lock was locked by .+ process with pid [1-9][0-9]*$' \
    <<<"$first_line"
  then
    cat "$ERROR_FILE" >&2
    exit 1
  fi
  if ((SECONDS >= deadline)); then
    cat "$ERROR_FILE" >&2
    echo "timed out waiting for the Ubuntu package-manager lock" >&2
    exit 1
  fi
  sleep 0.2
done
