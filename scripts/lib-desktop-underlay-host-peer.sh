#!/usr/bin/env bash
# Shared import-only Linux peer lifecycle for physical desktop underlay gates.
# The caller supplies ROOT, HYPERVISOR_SSH, ARTIFACT_DIR and fail().

DESKTOP_UNDERLAY_HOST_PEER_BINARY=""
DESKTOP_UNDERLAY_HOST_PEER_SHA256=""
DESKTOP_UNDERLAY_HOST_PEER_SIZE=""
DESKTOP_UNDERLAY_HOST_PEER_REMOTE_DIR=""
DESKTOP_UNDERLAY_HOST_PEER_IMPORTED=0

desktop_underlay_import_host_peer() {
  : "${ROOT:?desktop underlay host-peer import requires ROOT}"
  : "${HYPERVISOR_SSH:?desktop underlay host-peer import requires HYPERVISOR_SSH}"
  : "${ARTIFACT_DIR:?desktop underlay host-peer import requires ARTIFACT_DIR}"
  [[ "$(uname -s)" == "Darwin" ]] \
    || fail "desktop underlay Linux peer must be built on the host Mac"
  [[ "${NVPN_EXPECTED_APP_GIT_SHA:-}" =~ ^[0-9a-f]{40}$ ]] \
    || fail "desktop underlay host-peer import requires exact NVPN_EXPECTED_APP_GIT_SHA"

  local app_sha app_tree app_version
  local fips_sha fips_tree fips_version target receipt
  local remote_dir
  app_sha="$(git -C "$ROOT" rev-parse HEAD)"
  app_tree="$(git -C "$ROOT" rev-parse 'HEAD^{tree}')"
  [[ "$app_sha" == "$NVPN_EXPECTED_APP_GIT_SHA" ]] \
    || fail "desktop underlay app checkout differs from NVPN_EXPECTED_APP_GIT_SHA"
  [[ -z "$(git -C "$ROOT" status --porcelain --untracked-files=all)" ]] \
    || fail "desktop underlay host-peer import refuses a dirty app checkout"
  app_version="$(
    awk '
      $0 == "[package]" { package = 1; next }
      package && /^\[/ { exit }
      package && /^version = "/ {
        value = $0
        sub(/^version = "/, "", value)
        sub(/".*$/, "", value)
        print value
        exit
      }
    ' "$ROOT/Cargo.toml"
  )"
  [[ "$app_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]] \
    || fail "desktop underlay host-peer import could not derive app version"

  # This establishes exact FIPS SHA/tree/version globals and independently
  # rejects a dirty or unexpected FIPS checkout before the host build/cache.
  source "$ROOT/scripts/lib-mobile-release-join-artifacts.sh"
  release_join_require_clean_fips
  fips_sha="$RELEASE_JOIN_FIPS_SHA"
  fips_tree="$RELEASE_JOIN_FIPS_TREE"
  fips_version="$RELEASE_JOIN_FIPS_VERSION"
  target="x86_64-unknown-linux-musl"

  DESKTOP_UNDERLAY_HOST_PEER_BINARY="$(
    "$ROOT/scripts/prepare-macos-release-fips-peer.sh"
  )"
  [[ "$DESKTOP_UNDERLAY_HOST_PEER_BINARY" == /* \
    && -x "$DESKTOP_UNDERLAY_HOST_PEER_BINARY" ]]
  receipt="$(dirname "$DESKTOP_UNDERLAY_HOST_PEER_BINARY")/receipt.json"
  python3 "$ROOT/scripts/verify-host-linux-peer-artifact.py" \
    "$receipt" \
    "$DESKTOP_UNDERLAY_HOST_PEER_BINARY" \
    "$app_sha" \
    "$app_tree" \
    "$fips_sha" \
    "$fips_tree" \
    "$fips_version" \
    "$target"
  file "$DESKTOP_UNDERLAY_HOST_PEER_BINARY" \
    | grep -Eq 'ELF 64-bit.*x86-64' \
    || fail "host-built desktop underlay peer is not x86_64 ELF"

  DESKTOP_UNDERLAY_HOST_PEER_SHA256="$(
    shasum -a 256 "$DESKTOP_UNDERLAY_HOST_PEER_BINARY" | awk '{ print $1 }'
  )"
  DESKTOP_UNDERLAY_HOST_PEER_SIZE="$(
    stat -f '%z' "$DESKTOP_UNDERLAY_HOST_PEER_BINARY"
  )"
  [[ "$DESKTOP_UNDERLAY_HOST_PEER_SHA256" =~ ^[0-9a-f]{64}$ \
    && "$DESKTOP_UNDERLAY_HOST_PEER_SIZE" =~ ^[1-9][0-9]*$ ]] \
    || fail "host-built desktop underlay peer has invalid byte receipts"

  mkdir -p "$ARTIFACT_DIR"
  cp "$receipt" "$ARTIFACT_DIR/host-peer-local-receipt.json"

  remote_dir="$(
    ssh -o BatchMode=yes -o ConnectTimeout=10 "$HYPERVISOR_SSH" \
      mktemp -d /tmp/nvpn-desktop-underlay-peer.XXXXXX
  )"
  case "$remote_dir" in
    /tmp/nvpn-desktop-underlay-peer.*) ;;
    *) fail "Vader returned an unsafe desktop-underlay peer directory" ;;
  esac
  DESKTOP_UNDERLAY_HOST_PEER_REMOTE_DIR="$remote_dir"

  scp -q -o BatchMode=yes -o ConnectTimeout=10 \
    "$DESKTOP_UNDERLAY_HOST_PEER_BINARY" \
    "$HYPERVISOR_SSH:$remote_dir/nvpn.copy"
  scp -q -o BatchMode=yes -o ConnectTimeout=10 \
    "$receipt" \
    "$HYPERVISOR_SSH:$remote_dir/receipt.json.copy"

  ssh -o BatchMode=yes "$HYPERVISOR_SSH" bash -s -- \
    "$remote_dir" \
    "$DESKTOP_UNDERLAY_HOST_PEER_SHA256" \
    "$DESKTOP_UNDERLAY_HOST_PEER_SIZE" \
    "$app_sha" \
    "$app_tree" \
    "$fips_sha" \
    "$fips_tree" \
    "$fips_version" \
    "$target" \
    "$app_version" \
    >"$ARTIFACT_DIR/host-peer-remote-version.txt" <<'SH'
set -euo pipefail
remote_dir="$1"
expected_sha="$2"
expected_size="$3"
app_sha="$4"
app_tree="$5"
fips_sha="$6"
fips_tree="$7"
fips_version="$8"
target="$9"
app_version="${10}"
case "$remote_dir" in
  /tmp/nvpn-desktop-underlay-peer.*) ;;
  *) exit 2 ;;
esac
[[ -d "$remote_dir" && -O "$remote_dir" && ! -L "$remote_dir" ]]
chmod 0700 "$remote_dir"
chmod 0500 "$remote_dir/nvpn.copy"
chmod 0400 "$remote_dir/receipt.json.copy"
[[ "$(sha256sum "$remote_dir/nvpn.copy" | awk '{ print $1 }')" == "$expected_sha" ]]
[[ "$(stat -c '%s' "$remote_dir/nvpn.copy")" == "$expected_size" ]]
file "$remote_dir/nvpn.copy" | grep -Eq 'ELF 64-bit.*x86-64'
jq -e \
  --arg app_sha "$app_sha" \
  --arg app_tree "$app_tree" \
  --arg fips_sha "$fips_sha" \
  --arg fips_tree "$fips_tree" \
  --arg fips_version "$fips_version" \
  --arg target "$target" \
  --arg binary_sha "$expected_sha" \
  --argjson binary_size "$expected_size" \
  '.schema == 1
    and .builtOnHostMac == true
    and .builtOnRemoteVm == false
    and .appGitSha == $app_sha
    and .appGitTree == $app_tree
    and .fipsGitSha == $fips_sha
    and .fipsGitTree == $fips_tree
    and .fipsVersion == $fips_version
    and .target == $target
    and .binarySha256 == $binary_sha
    and .binarySize == $binary_size' \
  "$remote_dir/receipt.json.copy" >/dev/null
mv "$remote_dir/nvpn.copy" "$remote_dir/nvpn"
mv "$remote_dir/receipt.json.copy" "$remote_dir/receipt.json"
short_version="$("$remote_dir/nvpn" --version)"
[[ "$short_version" == "nvpn $app_version" ]]
verbose_version="$("$remote_dir/nvpn" version --verbose)"
printf '%s\n' "$verbose_version" | grep -Fq "(rev ${fips_sha:0:10})"
printf '%s\n%s\n' "$short_version" "$verbose_version"
SH
  HYPERVISOR_BINARY="$remote_dir/nvpn"
  DESKTOP_UNDERLAY_HOST_PEER_IMPORTED=1
  {
    printf 'builtOnHostMac=true\n'
    printf 'builtOnRemoteVm=false\n'
    printf 'appVersion=%s\n' "$app_version"
    printf 'appGitSha=%s\n' "$app_sha"
    printf 'appGitTree=%s\n' "$app_tree"
    printf 'fipsGitSha=%s\n' "$fips_sha"
    printf 'fipsGitTree=%s\n' "$fips_tree"
    printf 'fipsVersion=%s\n' "$fips_version"
    printf 'target=%s\n' "$target"
    printf 'binarySha256=%s\n' "$DESKTOP_UNDERLAY_HOST_PEER_SHA256"
    printf 'binarySize=%s\n' "$DESKTOP_UNDERLAY_HOST_PEER_SIZE"
    printf 'remoteBinary=%s\n' "$HYPERVISOR_BINARY"
  } >"$ARTIFACT_DIR/host-peer-import-receipt.txt"
}

desktop_underlay_cleanup_host_peer() {
  local remote_dir="${DESKTOP_UNDERLAY_HOST_PEER_REMOTE_DIR:-}"
  [[ -n "$remote_dir" ]] || return 0
  case "$remote_dir" in
    /tmp/nvpn-desktop-underlay-peer.*) ;;
    *)
      echo "refusing unsafe desktop-underlay peer cleanup path: $remote_dir" >&2
      return 1
      ;;
  esac
  ssh -o BatchMode=yes "$HYPERVISOR_SSH" bash -s -- "$remote_dir" <<'SH'
set -euo pipefail
remote_dir="$1"
case "$remote_dir" in
  /tmp/nvpn-desktop-underlay-peer.*) ;;
  *) exit 2 ;;
esac
find "$remote_dir" -xdev -depth -mindepth 1 -delete
rmdir "$remote_dir"
test ! -e "$remote_dir"
SH
  mkdir -p "$ARTIFACT_DIR"
  printf 'remote_artifact_removed=true\n' \
    >"$ARTIFACT_DIR/host-peer-cleanup-audit.txt"
  DESKTOP_UNDERLAY_HOST_PEER_REMOTE_DIR=""
  DESKTOP_UNDERLAY_HOST_PEER_IMPORTED=0
  HYPERVISOR_BINARY=""
}
