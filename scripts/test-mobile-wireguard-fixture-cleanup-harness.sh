#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib-mobile-wireguard-fixture.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/nvpn-wg-cleanup-harness.XXXXXX")"
CALLS="$TMP_ROOT/calls"
trap 'rm -rf "$TMP_ROOT"' EXIT

mobile_wg_remote_close_control() {
  printf 'close\n' >>"$CALLS"
}

mobile_wg_fixture_docker() {
  printf 'docker %s\n' "$*" >>"$CALLS"
  case "$1 $2" in
    "container inspect"|"image inspect") return 1 ;;
    *) return 0 ;;
  esac
}

mobile_wg_remote_exec() {
  printf 'remote %s\n' "$*" >>"$CALLS"
  return 0
}

MOBILE_WG_FIXTURE_STARTED=1
MOBILE_WG_FIXTURE_REMOTE_MODE=docker
MOBILE_WG_FIXTURE_REMOTE_IMAGE_BUILT=1
MOBILE_WG_FIXTURE_REMOTE_DIR=/tmp/nvpn-mobile-wg-exit.success
mobile_wg_fixture_cleanup fixture image
[[ "$MOBILE_WG_FIXTURE_STARTED" -eq 0 ]]
[[ "$MOBILE_WG_FIXTURE_REMOTE_IMAGE_BUILT" -eq 0 ]]
[[ -z "$MOBILE_WG_FIXTURE_REMOTE_DIR" ]]
for expected in \
  'docker rm -f fixture' \
  'docker container inspect fixture' \
  'docker image rm image' \
  'docker image inspect image' \
  'remote test ! -e /tmp/nvpn-mobile-wg-exit.success' \
  close
do
  grep -Fqx "$expected" "$CALLS"
done

: >"$CALLS"
mobile_wg_fixture_docker() {
  printf 'docker %s\n' "$*" >>"$CALLS"
  case "$1 $2" in
    "container inspect") return 0 ;;
    "image inspect") return 255 ;;
    *) return 0 ;;
  esac
}
mobile_wg_remote_exec() {
  printf 'remote %s\n' "$*" >>"$CALLS"
  [[ "$1" != "test" ]]
}
MOBILE_WG_FIXTURE_STARTED=1
MOBILE_WG_FIXTURE_REMOTE_MODE=docker
MOBILE_WG_FIXTURE_REMOTE_IMAGE_BUILT=1
MOBILE_WG_FIXTURE_REMOTE_DIR=/tmp/nvpn-mobile-wg-exit.failure
if mobile_wg_fixture_cleanup fixture image >/dev/null 2>&1; then
  echo "fixture cleanup accepted retained resources" >&2
  exit 1
fi
[[ "$MOBILE_WG_FIXTURE_STARTED" -eq 1 ]]
[[ "$MOBILE_WG_FIXTURE_REMOTE_IMAGE_BUILT" -eq 1 ]]
[[ "$MOBILE_WG_FIXTURE_REMOTE_DIR" == /tmp/nvpn-mobile-wg-exit.failure ]]
grep -Fqx 'docker image rm image' "$CALLS"
grep -Fqx \
  'remote test ! -e /tmp/nvpn-mobile-wg-exit.failure/fixture/server.key' \
  "$CALLS"
grep -Fqx close "$CALLS"

: >"$CALLS"
mobile_wg_remote_native() {
  printf 'native %s\n' "$*" >>"$CALLS"
}
mobile_wg_remote_exec() {
  printf 'remote %s\n' "$*" >>"$CALLS"
  if [[ "$1" == "sudo" && "$2" == "-n" && "$3" == "sh" ]]; then
    return 1
  fi
  return 0
}
MOBILE_WG_FIXTURE_STARTED=1
MOBILE_WG_FIXTURE_REMOTE_MODE=native
MOBILE_WG_FIXTURE_REMOTE_IMAGE_BUILT=0
MOBILE_WG_FIXTURE_REMOTE_INTERFACE=nwg53000
MOBILE_WG_FIXTURE_REMOTE_NFT_TABLE=nvpnwg53000
MOBILE_WG_FIXTURE_REMOTE_DIR=/tmp/nvpn-mobile-wg-exit.native
if mobile_wg_fixture_cleanup fixture image >/dev/null 2>&1; then
  echo "native fixture cleanup accepted a retained interface" >&2
  exit 1
fi
[[ "$MOBILE_WG_FIXTURE_STARTED" -eq 1 ]]
[[ "$MOBILE_WG_FIXTURE_REMOTE_DIR" == /tmp/nvpn-mobile-wg-exit.native ]]
grep -Fqx 'native stop' "$CALLS"
grep -Fq 'ip link show' "$CALLS"
grep -Fqx \
  'remote test ! -e /tmp/nvpn-mobile-wg-exit.native/fixture/server.key' \
  "$CALLS"
grep -Fqx close "$CALLS"

echo "mobile WireGuard fixture cleanup harness passed"
