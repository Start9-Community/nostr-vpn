#!/usr/bin/env bash
# Contract/adversarial checks for host-built desktop-underlay peer imports.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT/scripts/lib-desktop-underlay-host-peer.sh"
VERIFIER="$ROOT/scripts/verify-host-linux-peer-artifact.py"
WINDOWS="$ROOT/scripts/windows-vm-desktop-underlay-change-e2e.sh"
LINUX="$ROOT/scripts/linux-vm-desktop-underlay-change-e2e.sh"
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

for path in "$HELPER" "$WINDOWS" "$LINUX"; do
  bash -n "$path"
done
PYTHONPYCACHEPREFIX="$TMP_ROOT/pycache" python3 -m py_compile "$VERIFIER"

require_tokens "$HELPER" "shared host-peer importer" \
  '[[ "$(uname -s)" == "Darwin" ]]' \
  'prepare-macos-release-fips-peer.sh' \
  'verify-host-linux-peer-artifact.py' \
  'mktemp -d /tmp/nvpn-desktop-underlay-peer.XXXXXX' \
  'host-peer-local-receipt.json' \
  'host-peer-import-receipt.txt' \
  'builtOnRemoteVm' \
  '[[ "$short_version" == "nvpn $app_version" ]]' \
  'grep -Fq "(rev ${fips_sha:0:10})"' \
  'desktop_underlay_cleanup_host_peer' \
  'test ! -e "$remote_dir"'

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

require_tokens "$WINDOWS" "Windows native build ownership" \
  'windows-build.ps1 -Configuration Release -DaemonOnly' \
  'native Windows Release build failed'
require_tokens "$LINUX" "Linux exact host artifact reuse" \
  '"${primary_scp[@]}" "$DESKTOP_UNDERLAY_HOST_PEER_BINARY"' \
  'Linux target and imported peer binary SHA-256 receipts differ'

binary="$TMP_ROOT/nvpn"
receipt="$TMP_ROOT/receipt.json"
cp /bin/echo "$binary"
chmod 0555 "$binary"
app_sha="$(printf 'a%.0s' {1..40})"
app_tree="$(printf 'b%.0s' {1..40})"
fips_sha="$(printf 'c%.0s' {1..40})"
fips_tree="$(printf 'd%.0s' {1..40})"
fips_version="0.4.44"
target="x86_64-unknown-linux-musl"

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
