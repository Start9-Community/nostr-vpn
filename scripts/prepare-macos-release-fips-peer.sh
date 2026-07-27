#!/usr/bin/env bash
# Build/cache the exact Linux peer used by the macos-utm Release roaming gate.
# This runs on the host Mac. The exclusive VM lane only verifies and imports
# the resulting immutable x86_64-musl artifact.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck disable=SC1091
source "$ROOT/scripts/release_common.sh"
# shellcheck disable=SC1091
source "$ROOT/scripts/mobile_env.sh"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib-mobile-release-join-artifacts.sh"

load_release_env "$ROOT"
load_mobile_env "$ROOT"
[[ "$(uname -s)" == "Darwin" ]] || {
  echo "macOS roaming peer artifact must be built on the host Mac" >&2
  exit 2
}
release_join_require_clean_fips

APP_GIT_SHA="$(git -C "$ROOT" rev-parse HEAD)"
APP_GIT_TREE="$(git -C "$ROOT" rev-parse HEAD^{tree})"
release_join_assert_app_unchanged "$APP_GIT_SHA" "$APP_GIT_TREE"

TARGET=x86_64-unknown-linux-musl
CACHE_ROOT="$(
  cd "${NVPN_MACOS_FIPS_PEER_CACHE_DIR:-${ARTIFACT_ROOT:-$ROOT/artifacts}/macos-release-fips-peer}" \
    2>/dev/null && pwd
)" || {
  CACHE_ROOT="${NVPN_MACOS_FIPS_PEER_CACHE_DIR:-${ARTIFACT_ROOT:-$ROOT/artifacts}/macos-release-fips-peer}"
  mkdir -p "$CACHE_ROOT"
  CACHE_ROOT="$(cd "$CACHE_ROOT" && pwd)"
}
CACHE_KEY="$APP_GIT_SHA-$RELEASE_JOIN_FIPS_SHA-$TARGET"
ARTIFACT_DIR="$CACHE_ROOT/$CACHE_KEY"
BINARY="$ARTIFACT_DIR/nvpn"
RECEIPT="$ARTIFACT_DIR/receipt.json"
TEMP_DIR=""

cleanup() {
  local status="$?"
  trap - EXIT
  if [[ -n "$TEMP_DIR" ]]; then
    rm -rf "$TEMP_DIR"
  fi
  exit "$status"
}
trap cleanup EXIT

verify_artifact() {
  [[ -x "$BINARY" && -f "$RECEIPT" ]] || return 1
  file "$BINARY" | grep -Eq 'ELF 64-bit.*x86-64' || return 1
  python3 - \
    "$RECEIPT" \
    "$BINARY" \
    "$APP_GIT_SHA" \
    "$APP_GIT_TREE" \
    "$RELEASE_JOIN_FIPS_SHA" \
    "$RELEASE_JOIN_FIPS_TREE" \
    "$RELEASE_JOIN_FIPS_VERSION" \
    "$TARGET" <<'PY'
import hashlib
import json
import pathlib
import sys

(
    receipt_path,
    binary_path,
    app_sha,
    app_tree,
    fips_sha,
    fips_tree,
    fips_version,
    target,
) = sys.argv[1:]
binary = pathlib.Path(binary_path)
with open(receipt_path, encoding="utf-8") as handle:
    receipt = json.load(handle)
expected = {
    "schema": 1,
    "builtOnHostMac": True,
    "builtOnRemoteVm": False,
    "appGitSha": app_sha,
    "appGitTree": app_tree,
    "fipsGitSha": fips_sha,
    "fipsGitTree": fips_tree,
    "fipsVersion": fips_version,
    "target": target,
    "binarySize": binary.stat().st_size,
}
for key, value in expected.items():
    if receipt.get(key) != value:
        raise SystemExit(f"cached FIPS peer receipt mismatch for {key}")
digest = hashlib.sha256(binary.read_bytes()).hexdigest()
if receipt.get("binarySha256") != digest:
    raise SystemExit("cached FIPS peer SHA-256 mismatch")
PY
}

if verify_artifact; then
  printf '%s\n' "$BINARY"
  exit 0
fi

TEMP_DIR="$(mktemp -d "$CACHE_ROOT/.macos-fips-peer.XXXXXX")"
mkdir -p "$TEMP_DIR/work" "$TEMP_DIR/target" "$TEMP_DIR/final"
BUILD_OUTPUT="$TEMP_DIR/build-output.txt"
BUILD_LOG="$TEMP_DIR/final/host-build.log"
if ! env \
  NVPN_FIPS_REPO_PATH="$NVPN_FIPS_REPO_PATH" \
  NVPN_LINUX_MUSL_BUILD_ROOT="$TEMP_DIR/work" \
  NVPN_LINUX_MUSL_TARGET_DIR="$TEMP_DIR/target" \
  "$ROOT/scripts/build-nvpn-linux-musl" "$TARGET" \
  >"$BUILD_OUTPUT" 2>"$BUILD_LOG"
then
  tail -n 120 "$BUILD_LOG" >&2 || true
  exit 1
fi
BUILT_BINARY="$(tail -n 1 "$BUILD_OUTPUT")"
[[ "$BUILT_BINARY" == "$TEMP_DIR/target/$TARGET/release/nvpn" \
  && -x "$BUILT_BINARY" ]] || {
  echo "host Linux peer build returned an unexpected output path" >&2
  exit 1
}
file "$BUILT_BINARY" | grep -Eq 'ELF 64-bit.*x86-64' || {
  echo "host Linux peer build did not produce x86_64 ELF" >&2
  exit 1
}
cp "$BUILT_BINARY" "$TEMP_DIR/final/nvpn"
chmod 0555 "$TEMP_DIR/final/nvpn"

python3 - \
  "$TEMP_DIR/final/receipt.json" \
  "$TEMP_DIR/final/nvpn" \
  "$APP_GIT_SHA" \
  "$APP_GIT_TREE" \
  "$RELEASE_JOIN_FIPS_SHA" \
  "$RELEASE_JOIN_FIPS_TREE" \
  "$RELEASE_JOIN_FIPS_VERSION" \
  "$TARGET" <<'PY'
import hashlib
import json
import pathlib
import sys

(
    receipt_path,
    binary_path,
    app_sha,
    app_tree,
    fips_sha,
    fips_tree,
    fips_version,
    target,
) = sys.argv[1:]
binary = pathlib.Path(binary_path)
payload = {
    "schema": 1,
    "builtOnHostMac": True,
    "builtOnRemoteVm": False,
    "appGitSha": app_sha,
    "appGitTree": app_tree,
    "fipsGitSha": fips_sha,
    "fipsGitTree": fips_tree,
    "fipsVersion": fips_version,
    "target": target,
    "binarySha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
    "binarySize": binary.stat().st_size,
}
with open(receipt_path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY

release_join_assert_app_unchanged "$APP_GIT_SHA" "$APP_GIT_TREE"
[[ "$(git -C "$NVPN_FIPS_REPO_PATH" rev-parse HEAD)" == "$RELEASE_JOIN_FIPS_SHA" \
  && "$(git -C "$NVPN_FIPS_REPO_PATH" rev-parse HEAD^{tree})" == "$RELEASE_JOIN_FIPS_TREE" \
  && -z "$(git -C "$NVPN_FIPS_REPO_PATH" status --porcelain --untracked-files=all)" ]] \
  || {
    echo "FIPS source changed during host Linux peer build" >&2
    exit 1
  }

rm -rf "$ARTIFACT_DIR"
mv "$TEMP_DIR/final" "$ARTIFACT_DIR"
rm -rf "$TEMP_DIR"
TEMP_DIR=""
verify_artifact
printf '%s\n' "$BINARY"
