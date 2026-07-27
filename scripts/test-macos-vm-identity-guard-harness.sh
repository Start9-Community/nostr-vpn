#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/nvpn-macos-vm-identity.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

cat >"$WORK/bin/ioreg" <<'SH'
#!/usr/bin/env bash
printf '    "IOPlatformUUID" = "%s"\n' "$FAKE_LOCAL_UUID"
SH
cat >"$WORK/bin/ssh" <<'SH'
#!/usr/bin/env bash
[[ "${FAKE_SSH_FAIL:-0}" != 1 ]] || exit 255
printf '    "IOPlatformUUID" = "%s"\n' "$FAKE_REMOTE_UUID"
SH
chmod +x "$WORK/bin/ioreg" "$WORK/bin/ssh"
export PATH="$WORK/bin:$PATH"

# shellcheck disable=SC1091
source "$ROOT/scripts/lib-macos-vm-identity.sh"

export FAKE_LOCAL_UUID="11111111-1111-1111-1111-111111111111"
export FAKE_REMOTE_UUID="22222222-2222-2222-2222-222222222222"
NVPN_EXPECTED_MACOS_VM_IDENTITY_SHA256="$(
  macos_vm_identity_sha256 "$FAKE_REMOTE_UUID"
)"
export NVPN_EXPECTED_MACOS_VM_IDENTITY_SHA256
macos_vm_require_isolated_target "macos-test"

FAKE_REMOTE_UUID="33333333-3333-3333-3333-333333333333"
export FAKE_REMOTE_UUID
if macos_vm_require_isolated_target "macos-test" >/dev/null 2>&1; then
  echo "macOS VM guard cached a retargeted SSH alias" >&2
  exit 1
fi

FAKE_REMOTE_UUID="22222222-2222-2222-2222-222222222222"
NVPN_EXPECTED_MACOS_VM_IDENTITY_SHA256="$(
  macos_vm_identity_sha256 "33333333-3333-3333-3333-333333333333"
)"
export FAKE_REMOTE_UUID NVPN_EXPECTED_MACOS_VM_IDENTITY_SHA256
if macos_vm_require_isolated_target "macos-test" >/dev/null 2>&1; then
  echo "macOS VM guard accepted the wrong pinned guest" >&2
  exit 1
fi

FAKE_REMOTE_UUID="$FAKE_LOCAL_UUID"
NVPN_EXPECTED_MACOS_VM_IDENTITY_SHA256="$(
  macos_vm_identity_sha256 "$FAKE_REMOTE_UUID"
)"
export FAKE_REMOTE_UUID NVPN_EXPECTED_MACOS_VM_IDENTITY_SHA256
if macos_vm_require_isolated_target "macos-test" >/dev/null 2>&1; then
  echo "macOS VM guard accepted the current Mac" >&2
  exit 1
fi

FAKE_REMOTE_UUID="22222222-2222-2222-2222-222222222222"
unset NVPN_EXPECTED_MACOS_VM_IDENTITY_SHA256
export FAKE_REMOTE_UUID
if macos_vm_require_isolated_target "macos-test" >/dev/null 2>&1; then
  echo "macOS VM guard accepted an unpinned target" >&2
  exit 1
fi

if grep -Fq "MACOS_VM_VERIFIED_" "$ROOT/scripts/lib-macos-vm-identity.sh"; then
  echo "macOS VM guard retains a bypassable alias cache" >&2
  exit 1
fi

for file in \
  scripts/release-gate.sh \
  scripts/lib-macos-vm-imported-release.sh \
  scripts/macos-vm-git-sync.sh \
  scripts/macos-vm-release-exit-dns-ui-e2e.sh \
  scripts/macos-vm-desktop-wireguard-exit-e2e.sh \
  scripts/macos-vm-release-mobile-join-e2e.sh
do
  grep -Fq "macos_vm_require_isolated_target" "$ROOT/$file" || {
    echo "$file does not enforce the macOS VM identity guard" >&2
    exit 1
  }
done

echo "macOS VM identity guard harness passed"
