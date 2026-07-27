#!/usr/bin/env bash
# Build on the host, import to the isolated macOS VM, and drive every Exit DNS public UI.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/release_common.sh"
# shellcheck disable=SC1091
source "$ROOT/scripts/mobile_env.sh"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib-mobile-release-join-artifacts.sh"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib-macos-vm-imported-release.sh"

load_release_env "$ROOT"
load_env_file_defaults "${NVPN_ZAPSTORE_ENV_FILE:-$ROOT/.env.zapstore.local}"
load_mobile_env "$ROOT"

MAC_HOST="${NVPN_MACOS_SSH_HOST:-${1:-}}"
[[ -n "$MAC_HOST" ]] || {
  echo "Set NVPN_MACOS_SSH_HOST or pass the isolated macOS VM SSH target." >&2
  exit 2
}
macos_vm_require_isolated_target "$MAC_HOST"
GUEST_SRC_ROOT="${NVPN_MACOS_GUEST_SRC_ROOT:-src}"
GUEST_REPO="$GUEST_SRC_ROOT/nostr-vpn"
REMOTE_SCRIPT="./scripts/macos-release-exit-dns-ui-remote.sh"
RESULT_DIR="${NVPN_DESKTOP_DNS_UI_ARTIFACT_DIR:-$ROOT/artifacts/desktop-dns-ui/macos}"
IMPORT_RESULT="$RESULT_DIR/import"
PRIVATE_DIR="$RESULT_DIR/.private-$$"
HOST_DRIVER="$PRIVATE_DIR/macos-exit-dns-ax"
HOST_DRIVER_RECEIPT="$PRIVATE_DIR/driver-receipt.json"
PUBLICATION_APP="$IMPORT_RESULT/macos/publication/Nostr VPN.app"
APP_RECEIPT="$IMPORT_RESULT/macos/artifact.json"
IMPORT_VERIFICATION="$IMPORT_RESULT/macos/verification.json"

MACOS_SIGNING_IDENTITY="$(
  printf '%s' "${MACOS_SIGNING_IDENTITY:-}" \
    | tr -d ':[:space:]' \
    | tr '[:lower:]' '[:upper:]'
)"
EXPECTED_TEAM="${NVPN_EXPECTED_MACOS_SIGNING_TEAM_ID:-${NVPN_IOS_TEAM_ID:-}}"
EXPECTED_SIGNER="$(
  printf '%s' "${NVPN_EXPECTED_MACOS_SIGNER_CERT_SHA256:-}" \
    | tr -d ':[:space:]' \
    | tr '[:upper:]' '[:lower:]'
)"
[[ "$MACOS_SIGNING_IDENTITY" =~ ^[0-9A-F]{40}$ ]] || {
  echo "Set MACOS_SIGNING_IDENTITY to the exact Developer ID certificate SHA-1" >&2
  exit 2
}
[[ "$EXPECTED_TEAM" =~ ^[A-Z0-9]{10}$ ]] || {
  echo "Set NVPN_IOS_TEAM_ID or NVPN_EXPECTED_MACOS_SIGNING_TEAM_ID" >&2
  exit 2
}
if [[ -z "$EXPECTED_SIGNER" ]]; then
  EXPECTED_SIGNER="$(
    python3 "$ROOT/scripts/macos_release_join_artifact.py" \
      resolve-certificate --identity-sha1 "$MACOS_SIGNING_IDENTITY"
  )"
fi
[[ "$EXPECTED_SIGNER" =~ ^[0-9a-f]{64}$ ]] || {
  echo "Set NVPN_EXPECTED_MACOS_SIGNER_CERT_SHA256" >&2
  exit 2
}

mkdir -p "$PRIVATE_DIR"
chmod 700 "$PRIVATE_DIR"
release_join_require_clean_fips
APP_GIT_SHA="$(git -C "$ROOT" rev-parse HEAD)"
APP_GIT_TREE="$(git -C "$ROOT" rev-parse HEAD^{tree})"
release_join_assert_app_unchanged "$APP_GIT_SHA" "$APP_GIT_TREE"

remote() {
  local action="$1"
  local command
  printf -v command \
    'cd %q && env NVPN_FIPS_REPO_PATH=%q NVPN_EXPECTED_APP_GIT_SHA=%q NVPN_EXPECTED_APP_GIT_TREE=%q NVPN_EXPECTED_FIPS_GIT_SHA=%q NVPN_EXPECTED_FIPS_GIT_TREE=%q NVPN_EXPECTED_FIPS_VERSION=%q NVPN_EXPECTED_MACOS_SIGNING_IDENTITY_SHA1=%q NVPN_EXPECTED_MACOS_SIGNING_TEAM_ID=%q NVPN_EXPECTED_MACOS_SIGNER_CERT_SHA256=%q %q %q' \
    "$GUEST_REPO" \
    "../fips" \
    "$APP_GIT_SHA" \
    "$APP_GIT_TREE" \
    "$RELEASE_JOIN_FIPS_SHA" \
    "$RELEASE_JOIN_FIPS_TREE" \
    "$RELEASE_JOIN_FIPS_VERSION" \
    "$MACOS_SIGNING_IDENTITY" \
    "$EXPECTED_TEAM" \
    "$EXPECTED_SIGNER" \
    "$REMOTE_SCRIPT" \
    "$action"
  ssh -o BatchMode=yes "$MAC_HOST" "$command"
}

cleanup() {
  local status=$?
  trap - EXIT
  remote cleanup >/dev/null 2>&1 || status=1
  rm -rf "$PRIVATE_DIR"
  exit "$status"
}
trap cleanup EXIT

rm -rf "$RESULT_DIR"
mkdir -p "$PRIVATE_DIR" "$IMPORT_RESULT"
chmod 700 "$PRIVATE_DIR"

# The shared importer builds the signed Release app on this host and copies
# that exact bundle to the VM. It never builds application code on the VM.
NVPN_MACOS_IMPORTED_RELEASE_ARTIFACT_READY=0 \
NVPN_RELEASE_JOIN_RESULT_DIR="$IMPORT_RESULT" \
  macos_vm_prepare_or_verify_imported_release "$ROOT" "$MAC_HOST"

for path in "$PUBLICATION_APP" "$APP_RECEIPT" "$IMPORT_VERIFICATION"; do
  [[ -e "$path" ]] || {
    echo "host-built imported Release evidence is missing: $path" >&2
    exit 1
  }
done

xcrun swiftc -O \
  -framework AppKit \
  -framework ApplicationServices \
  -framework Foundation \
  -o "$HOST_DRIVER" \
  "$ROOT/scripts/macos-exit-dns-ax.swift"
codesign --force --timestamp --options runtime \
  --identifier desktop-manual-join-ax \
  --sign "$MACOS_SIGNING_IDENTITY" \
  "$HOST_DRIVER"
codesign --verify --strict "$HOST_DRIVER"

python3 "$ROOT/scripts/macos_exit_dns_ui_receipt.py" create-driver \
  --output "$HOST_DRIVER_RECEIPT" \
  --driver "$HOST_DRIVER" \
  --driver-source "$ROOT/scripts/macos-exit-dns-ax.swift" \
  --app "$PUBLICATION_APP" \
  --app-receipt "$APP_RECEIPT" \
  --app-root "$ROOT" \
  --expected-app-head "$APP_GIT_SHA" \
  --expected-app-tree "$APP_GIT_TREE" \
  --expected-team "$EXPECTED_TEAM" \
  --expected-identity-sha1 "$MACOS_SIGNING_IDENTITY" \
  --expected-signer-sha256 "$EXPECTED_SIGNER"

remote stage
scp -q "$HOST_DRIVER" \
  "$MAC_HOST:$GUEST_REPO/artifacts/macos-exit-dns-ui/support/"
scp -q "$HOST_DRIVER_RECEIPT" \
  "$MAC_HOST:$GUEST_REPO/artifacts/macos-exit-dns-ui/driver-receipt.json"
remote run | tee "$RESULT_DIR/vm-run.log"

mkdir -p "$RESULT_DIR/cases" "$RESULT_DIR/observations"
scp -q \
  "$MAC_HOST:$GUEST_REPO/artifacts/macos-exit-dns-ui/results/*.json" \
  "$RESULT_DIR/cases/"
scp -q \
  "$MAC_HOST:$GUEST_REPO/artifacts/macos-exit-dns-ui/observations/*.json" \
  "$RESULT_DIR/observations/"
scp -q \
  "$MAC_HOST:$GUEST_REPO/artifacts/macos-exit-dns-ui/driver-verification.json" \
  "$RESULT_DIR/driver-verification.json"
scp -q \
  "$MAC_HOST:$GUEST_REPO/artifacts/macos-exit-dns-ui/restoration.json" \
  "$RESULT_DIR/restoration.json"
cp "$APP_RECEIPT" "$RESULT_DIR/app-artifact.json"
cp "$IMPORT_VERIFICATION" "$RESULT_DIR/import-verification.json"
cp "$HOST_DRIVER_RECEIPT" "$RESULT_DIR/driver-receipt.json"

python3 "$ROOT/scripts/macos_exit_dns_ui_receipt.py" create-summary \
  --case-dir "$RESULT_DIR/cases" \
  --app-receipt "$RESULT_DIR/app-artifact.json" \
  --driver-receipt "$RESULT_DIR/driver-receipt.json" \
  --import-verification "$RESULT_DIR/import-verification.json" \
  --driver-verification "$RESULT_DIR/driver-verification.json" \
  --restoration-receipt "$RESULT_DIR/restoration.json" \
  --output "$RESULT_DIR/summary.json"

release_join_assert_app_unchanged "$APP_GIT_SHA" "$APP_GIT_TREE"
release_join_assert_fips_unchanged
echo "MACOS_VM_RELEASE_EXIT_DNS_UI_E2E_OK"
