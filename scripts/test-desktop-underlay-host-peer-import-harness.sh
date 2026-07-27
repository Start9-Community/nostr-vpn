#!/usr/bin/env bash
# Contract/adversarial checks for host-built desktop-underlay peer imports.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT/scripts/lib-desktop-underlay-host-peer.sh"
VERIFIER="$ROOT/scripts/verify-host-linux-peer-artifact.py"
WINDOWS="$ROOT/scripts/windows-vm-desktop-underlay-change-e2e.sh"
LINUX="$ROOT/scripts/linux-vm-desktop-underlay-change-e2e.sh"
WINDOWS_LIB="$ROOT/scripts/windows-vm-desktop-underlay-change-e2e.lib.sh"
LINUX_LIB="$ROOT/scripts/linux-vm-desktop-underlay-change-e2e.lib.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/nvpn-underlay-peer-import.XXXXXX")"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

fail() {
  echo "desktop underlay host-peer import contract failed: $*" >&2
  exit 1
}

require_tokens() {
  local path="$1" label="$2"
  shift 2
  local token
  for token in "$@"; do
    grep -Fq -- "$token" "$path" \
      || fail "$label is missing: $token"
  done
}

for path in "$HELPER" "$WINDOWS" "$LINUX" "$WINDOWS_LIB" "$LINUX_LIB"; do
  bash -n "$path"
done
PYTHONPYCACHEPREFIX="$TMP_ROOT/pycache" python3 -m py_compile "$VERIFIER"

require_tokens "$HELPER" "shared host-peer importer" \
  '[[ "$(uname -s)" == "Darwin" ]]' \
  'desktop_underlay_app_version' \
  '$0 == "[workspace.package]"' \
  'prepare-macos-release-fips-peer.sh' \
  'verify-host-linux-peer-artifact.py' \
  'mktemp -d /tmp/nvpn-desktop-underlay-peer.XXXXXX' \
  'host-peer-local-receipt.json' \
  'host-peer-import-receipt.txt' \
  'desktop-linux-underlay-peer-e2e.sh.copy' \
  'lib-desktop-linux-listener-audit.sh.copy' \
  'peerRunnerSha256=' \
  'listenerAuditSha256=' \
  'DESKTOP_UNDERLAY_HOST_PEER_RUNNER=' \
  'builtOnRemoteVm' \
  '[[ "$short_version" == "nvpn $app_version" ]]' \
  'grep -Fq "(rev ${fips_sha:0:10})"' \
  'desktop_underlay_cleanup_host_peer' \
  'test ! -e "$remote_dir"'

workspace_manifest="$TMP_ROOT/Cargo.toml"
cat >"$workspace_manifest" <<'TOML'
[workspace]
members = []

[workspace.package]
version = "4.1.5"
edition = "2024"
TOML
# shellcheck disable=SC1090
source "$HELPER"
[[ "$(desktop_underlay_app_version "$workspace_manifest")" == "4.1.5" ]] \
  || fail "shared host-peer importer cannot derive the workspace package version"

for forbidden in \
  'cargo build' \
  'cargo check' \
  'cargo run' \
  'rustc ' \
  'gcc ' \
  'clang ' \
  'apt-get ' \
  'dnf '
do
  if grep -Fq "$forbidden" "$HELPER"; then
    fail "Vader host-peer importer can compile or install: $forbidden"
  fi
done

for controller in "$WINDOWS" "$LINUX"; do
  require_tokens "$controller" "desktop underlay controller" \
    'source "$ROOT/scripts/lib-desktop-underlay-host-peer.sh"' \
    'HYPERVISOR_BINARY=""' \
    'desktop_underlay_import_host_peer' \
    'desktop_underlay_cleanup_host_peer'
  if grep -Fq 'peer-build.log' "$controller"; then
    fail "$controller still has a Vader peer-build lane"
  fi
  if grep -Fq 'HYPERVISOR_REPO/target/release/nvpn' "$controller"; then
    fail "$controller still selects a Vader-built peer binary"
  fi
done

if grep -Eq 'HYPERVISOR_(SRC_ROOT|REPO)' "$WINDOWS_LIB" "$LINUX_LIB"; then
  fail "desktop underlay helper still requires the removed Vader source checkout"
fi
for controller_lib in "$WINDOWS_LIB" "$LINUX_LIB"; do
  require_tokens "$controller_lib" "imported peer fixture ownership" \
    '"$DESKTOP_UNDERLAY_HOST_PEER_RUNNER" "$action"'
done

# Source both controller libraries under nounset without the deleted
# HYPERVISOR_SRC_ROOT. This catches stale top-level expansions that bash -n
# cannot see.
(
  set -euo pipefail
  HYPERVISOR_SSH=fake-vader
  VM_NAME=fake-windows
  WINDOWS_SSH=fake-windows
  NETWORK_ID=fake-network
  source "$WINDOWS_LIB"
)
(
  set -euo pipefail
  HYPERVISOR_SSH=fake-vader
  VM_NAME=fake-linux
  LINUX_SSH=fake-linux
  NETWORK_ID=fake-network
  GUEST_SRC_ROOT=fake-linux-source
  source "$LINUX_LIB"
)

require_tokens "$WINDOWS" "Windows native build ownership" \
  'windows-build.ps1 -Configuration Release -DaemonOnly' \
  'native Windows Release build failed'
require_tokens "$LINUX" "Linux exact host artifact reuse" \
  'TARGET_RELEASE_BINARY="$TARGET_RELEASE_BUNDLE/nvpn"' \
  'host-built Linux release bundle receipt differs' \
  '"${primary_scp[@]}" "$TARGET_RELEASE_BINARY"' \
  'Linux target differs from the exact host-built release CLI' \
  'Linux fixture peer differs from its exact host-built receipt' \
  'tested-artifact-receipt.json' \
  'tested-artifact.json'

binary="$TMP_ROOT/nvpn"
receipt="$TMP_ROOT/receipt.json"
cp /bin/echo "$binary"
chmod 0555 "$binary"
app_sha="$(printf 'a%.0s' {1..40})"
app_tree="$(printf 'b%.0s' {1..40})"
fips_sha="$(printf 'c%.0s' {1..40})"
fips_tree="$(printf 'd%.0s' {1..40})"
fips_version="0.4.45"
target="x86_64-unknown-linux-musl"

# Exercise the shared helper in the exact `helper || status=$?` context used by
# both real controllers. Bash disables implicit errexit inside a function in
# that context, so every security-sensitive command must return explicitly.
fake_root="$TMP_ROOT/fake-app"
fake_artifacts="$TMP_ROOT/fake-artifacts"
fake_binary="$fake_root/peer/nvpn"
mkdir -p "$fake_root/scripts" "$fake_root/peer" "$fake_artifacts"
printf '%s\n' \
  '[package]' \
  'name = "fake-nvpn"' \
  'version = "4.1.5"' \
  >"$fake_root/Cargo.toml"
{
  printf '%s\n' 'release_join_require_clean_fips() {'
  printf '  RELEASE_JOIN_FIPS_SHA=%q\n' "$fips_sha"
  printf '  RELEASE_JOIN_FIPS_TREE=%q\n' "$fips_tree"
  printf '  RELEASE_JOIN_FIPS_VERSION=%q\n' "$fips_version"
  printf '%s\n' '  return 0' '}'
} >"$fake_root/scripts/lib-mobile-release-join-artifacts.sh"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'if [[ "${FAKE_PREPARE_MODE:-ok}" == "fail" ]]; then exit 42; fi' \
  'printf "%s\n" "$FAKE_PEER_BINARY"' \
  >"$fake_root/scripts/prepare-macos-release-fips-peer.sh"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'exit "${FAKE_VERIFY_STATUS:-0}"' \
  >"$fake_root/scripts/verify-host-linux-peer-artifact.py"
printf '%s\n' '#!/bin/sh' 'exit 0' >"$fake_binary"
printf '%s\n' '{}' >"$fake_root/peer/receipt.json"
chmod 0755 \
  "$fake_root/scripts/prepare-macos-release-fips-peer.sh" \
  "$fake_root/scripts/verify-host-linux-peer-artifact.py"
chmod 0555 "$fake_binary"
git -C "$fake_root" init -q
git -C "$fake_root" add -A
git -C "$fake_root" \
  -c user.name=Gate \
  -c user.email=gate.invalid \
  commit -qm fixture
fake_sha="$(git -C "$fake_root" rev-parse HEAD)"

(
  set -euo pipefail
  ROOT="$fake_root"
  HYPERVISOR_SSH=fake-vader
  ARTIFACT_DIR="$fake_artifacts"
  NVPN_EXPECTED_APP_GIT_SHA="$fake_sha"
  FAKE_PEER_BINARY="$fake_binary"
  export NVPN_EXPECTED_APP_GIT_SHA FAKE_PEER_BINARY

  uname() {
    printf '%s\n' Darwin
  }
  file() {
    printf '%s\n' "$1: ELF 64-bit LSB executable, x86-64"
  }
  shasum() {
    printf '%064d  %s\n' 0 "${*: -1}"
  }
  stat() {
    printf '%s\n' 123
  }
  scp() {
    return "${FAKE_SCP_STATUS:-0}"
  }
  ssh() {
    if [[ "$*" == *'mktemp -d /tmp/nvpn-desktop-underlay-peer.XXXXXX'* ]]; then
      printf '%s\n' /tmp/nvpn-desktop-underlay-peer.failure-injection
      return 0
    fi
    return "${FAKE_SSH_STATUS:-0}"
  }

  source "$HELPER"

  expect_import_failure() {
    local status=0
    DESKTOP_UNDERLAY_HOST_PEER_BINARY=""
    DESKTOP_UNDERLAY_HOST_PEER_REMOTE_DIR=""
    DESKTOP_UNDERLAY_HOST_PEER_IMPORTED=0
    rm -f "$ARTIFACT_DIR/host-peer-import-receipt.txt"
    desktop_underlay_import_host_peer >/dev/null 2>&1 || status="$?"
    [[ "$status" -ne 0 ]] \
      || fail "host-peer importer swallowed an injected command failure"
    [[ "$DESKTOP_UNDERLAY_HOST_PEER_IMPORTED" -eq 0 ]] \
      || fail "failed host-peer import was marked complete"
    [[ ! -e "$ARTIFACT_DIR/host-peer-import-receipt.txt" ]] \
      || fail "failed host-peer import wrote a success receipt"
  }

  FAKE_PREPARE_MODE=fail
  FAKE_VERIFY_STATUS=0
  FAKE_SCP_STATUS=0
  FAKE_SSH_STATUS=0
  export FAKE_PREPARE_MODE FAKE_VERIFY_STATUS FAKE_SCP_STATUS FAKE_SSH_STATUS
  expect_import_failure

  FAKE_PREPARE_MODE=ok
  FAKE_VERIFY_STATUS=73
  export FAKE_PREPARE_MODE FAKE_VERIFY_STATUS
  expect_import_failure

  FAKE_VERIFY_STATUS=0
  FAKE_SCP_STATUS=74
  export FAKE_VERIFY_STATUS FAKE_SCP_STATUS
  expect_import_failure

  FAKE_SCP_STATUS=0
  FAKE_SSH_STATUS=75
  export FAKE_SCP_STATUS FAKE_SSH_STATUS
  expect_import_failure

  DESKTOP_UNDERLAY_HOST_PEER_REMOTE_DIR=/tmp/nvpn-desktop-underlay-peer.cleanup-failure
  rm -f "$ARTIFACT_DIR/host-peer-cleanup-audit.txt"
  cleanup_status=0
  desktop_underlay_cleanup_host_peer >/dev/null 2>&1 \
    || cleanup_status="$?"
  [[ "$cleanup_status" -ne 0 ]] \
    || fail "host-peer cleanup swallowed an injected SSH failure"
  [[ "$DESKTOP_UNDERLAY_HOST_PEER_REMOTE_DIR" == \
    /tmp/nvpn-desktop-underlay-peer.cleanup-failure ]] \
    || fail "failed host-peer cleanup discarded retry state"
  [[ ! -e "$ARTIFACT_DIR/host-peer-cleanup-audit.txt" ]] \
    || fail "failed host-peer cleanup wrote a false removal audit"
)

python3 - \
  "$receipt" "$binary" \
  "$app_sha" "$app_tree" \
  "$fips_sha" "$fips_tree" \
  "$fips_version" "$target" <<'PY'
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
pathlib.Path(receipt_path).write_text(
    json.dumps(payload, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY

verify=(
  python3 "$VERIFIER"
  "$receipt" "$binary"
  "$app_sha" "$app_tree"
  "$fips_sha" "$fips_tree"
  "$fips_version" "$target"
)
"${verify[@]}"

bad_receipt="$TMP_ROOT/bad-receipt.json"
python3 - "$receipt" "$bad_receipt" <<'PY'
import json
import pathlib
import sys

source, destination = sys.argv[1:]
payload = json.loads(pathlib.Path(source).read_text(encoding="utf-8"))
payload["builtOnRemoteVm"] = True
pathlib.Path(destination).write_text(json.dumps(payload), encoding="utf-8")
PY
if python3 "$VERIFIER" \
  "$bad_receipt" "$binary" \
  "$app_sha" "$app_tree" \
  "$fips_sha" "$fips_tree" \
  "$fips_version" "$target" >/dev/null 2>&1
then
  fail "receipt verifier accepted a remote-built peer"
fi

chmod u+w "$binary"
printf 'tamper' >>"$binary"
chmod 0555 "$binary"
if "${verify[@]}" >/dev/null 2>&1; then
  fail "receipt verifier accepted mutated binary bytes"
fi

echo "DESKTOP_UNDERLAY_HOST_PEER_IMPORT_HARNESS_OK"
