#!/usr/bin/env bash
# Prove that loading a frozen product checkout cannot replace harness identity.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib-ubuntu-vm-imported-release.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/nvpn-import-env-isolation.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
release_root="$tmp/product"
bundle="$tmp/bundle"
mkdir -p "$release_root/scripts" "$bundle"

cat >"$release_root/scripts/release_common.sh" <<'SH'
load_release_env() {
  APP_GIT_SHA=product-sha
  APP_GIT_TREE=product-tree
}
assert_release_checkout_state() { return 0; }
SH
cat >"$release_root/scripts/lib-mobile-release-join-artifacts.sh" <<'SH'
release_join_require_clean_fips() { return 1; }
SH
cat >"$bundle/receipt.json" <<'JSON'
{
  "appGitSha": "product-sha",
  "appGitTree": "product-tree",
  "appVersion": "test",
  "fipsGitSha": "fips-sha",
  "fipsGitTree": "fips-tree",
  "fipsVersion": "test",
  "builderMode": "test"
}
JSON

APP_GIT_SHA=harness-sha
APP_GIT_TREE=harness-tree
export SSH_HOST=unused
export GUEST_REPO=unused
export NVPN_RELEASE_APP_REPO_PATH="$release_root"
export NVPN_HOST_LINUX_VM_BUNDLE_DIR="$bundle"

if ubuntu_vm_import_release_bundle >/dev/null 2>&1; then
  echo "fixture unexpectedly passed the intentional FIPS stop" >&2
  exit 1
fi
[[ "$APP_GIT_SHA" == harness-sha && "$APP_GIT_TREE" == harness-tree ]] || {
  echo "product release environment replaced harness identity" >&2
  exit 1
}

echo UBUNTU_VM_IMPORT_ENV_ISOLATION_OK
