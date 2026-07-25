#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/release_common.sh"

fail() {
  printf 'release_common env test failed: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  local actual="$1"
  local expected="$2"
  local label="$3"
  [[ "$actual" == "$expected" ]] || fail "$label: expected '$expected', got '$actual'"
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

export HOME="$tmp_dir/home"
mkdir -p "$HOME"
mkdir -p "$tmp_dir/asc/private_keys"
: >"$tmp_dir/asc/private_keys/AuthKey_TESTKEY123.p8"
printf '%s\n' "test-issuer-id" >"$tmp_dir/asc/issuer.txt"

cat >"$tmp_dir/release.env" <<'EOF'
RELEASE_COMMON_BASE=base
RELEASE_COMMON_PRESET=from-file
NVPN_DEFAULT_IOS_BUNDLE_ID=com.example.default
EOF

cat >"$tmp_dir/.env.release.local" <<EOF
NVPN_ASC_ROOT=$tmp_dir/asc
MACOS_SIGNING_IDENTITY=Developer ID Application: Example (TEAMID)
QUOTED_RELEASE_COMMON_VALUE="quoted value"
export EXPORTED_RELEASE_COMMON_VALUE=exported
HOME_EXPANDED_PATH=\$HOME/private
BRACED_HOME_EXPANDED_PATH=\${HOME}/private
TILDE_EXPANDED_PATH=~/private
INVALID-KEY=ignored
EOF

export RELEASE_COMMON_PRESET=from-shell
load_release_env "$tmp_dir"
load_appstoreconnect_defaults

assert_eq "${RELEASE_COMMON_BASE:-}" "base" "loads release.env"
assert_eq "${RELEASE_COMMON_PRESET:-}" "from-shell" "keeps shell env precedence"
assert_eq "${MACOS_SIGNING_IDENTITY:-}" "Developer ID Application: Example (TEAMID)" "loads unquoted dotenv value"
assert_eq "${QUOTED_RELEASE_COMMON_VALUE:-}" "quoted value" "strips simple quotes"
assert_eq "${EXPORTED_RELEASE_COMMON_VALUE:-}" "exported" "loads export-prefixed dotenv value"
assert_eq "${HOME_EXPANDED_PATH:-}" "$HOME/private" "expands dollar HOME path prefix"
assert_eq "${BRACED_HOME_EXPANDED_PATH:-}" "$HOME/private" "expands braced HOME path prefix"
assert_eq "${TILDE_EXPANDED_PATH:-}" "$HOME/private" "expands tilde path prefix"
assert_eq "${NVPN_DEFAULT_IOS_BUNDLE_ID:-}" "com.example.default" "loads default bundle id from env file"
env | grep -q '^INVALID-KEY=' && fail "invalid env key was exported"
assert_eq "${NVPN_ASC_AUTH_KEY_PATH:-}" "$tmp_dir/asc/private_keys/AuthKey_TESTKEY123.p8" "derives ASC key path"
assert_eq "${NVPN_ASC_AUTH_KEY_ID:-}" "TESTKEY123" "derives ASC key id"
assert_eq "${NVPN_ASC_AUTH_KEY_ISSUER_ID:-}" "test-issuer-id" "loads ASC issuer id"

mkdir -p "$tmp_dir/repo/ios"
cat >"$tmp_dir/repo/Cargo.toml" <<'EOF'
[workspace.package]
version = "4.1.4"
EOF
printf '%s\n' "4001006" >"$tmp_dir/repo/ios/app-store-build-number"

unset NVPN_APP_VERSION_NAME
unset NVPN_APP_VERSION_CODE
unset NVPN_APP_VERSION_CODE_MANUAL
unset NVPN_IOS_BUILD_NUMBER
unset NVPN_IOS_RELEASE_TAG
resolve_shared_build_metadata "$tmp_dir/repo"
assert_eq "${NVPN_APP_VERSION_NAME:-}" "4.1.4" "loads shared marketing version from Cargo"
assert_eq "${NVPN_APP_VERSION_CODE:-}" "4001004" "keeps generic derived build number unchanged"

unset NVPN_APP_VERSION_CODE
resolve_ios_build_metadata "$tmp_dir/repo"

assert_eq "${NVPN_APP_VERSION_NAME:-}" "4.1.4" "keeps iOS marketing version from Cargo"
assert_eq "${NVPN_APP_VERSION_CODE:-}" "4001006" "loads tracked iOS App Store build number"
assert_eq "${NVPN_IOS_BUILD_NUMBER:-}" "4001006" "exports resolved iOS build number"
assert_eq "${NVPN_IOS_RELEASE_TAG:-}" "v4.1.4+4001006" "derives corrected iOS release tag"

unset NVPN_APP_VERSION_CODE
export NVPN_IOS_BUILD_NUMBER=4001007
resolve_ios_build_metadata "$tmp_dir/repo"
assert_eq "${NVPN_APP_VERSION_CODE:-}" "4001007" "allows an explicit iOS build-number override"
assert_eq "${NVPN_IOS_RELEASE_TAG:-}" "v4.1.4+4001007" "updates release tag for explicit build"

if (
  unset NVPN_APP_VERSION_CODE
  export NVPN_IOS_BUILD_NUMBER=invalid
  resolve_ios_build_metadata "$tmp_dir/repo"
); then
  fail "accepted an invalid iOS build number"
fi

printf 'release_common env test passed\n'
