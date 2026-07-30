#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT_ROOT="${ARTIFACT_ROOT:-$ROOT/artifacts}"
FIXTURE_DIR="$ARTIFACT_ROOT/update-fixtures/cli"
INSTALL_DIR="$ARTIFACT_ROOT/update-downloads/cli"
TAG="${NVPN_UPDATE_E2E_TAG:-v999.0.0}"

case "$(uname -s):$(uname -m)" in
  Darwin:arm64)
    TARGET="aarch64-apple-darwin"
    ;;
  Linux:x86_64)
    TARGET="x86_64-unknown-linux-musl"
    ;;
  Linux:aarch64|Linux:arm64)
    TARGET="aarch64-unknown-linux-musl"
    ;;
  *)
    echo "CLI update e2e is unsupported on $(uname -s):$(uname -m)" >&2
    exit 1
    ;;
esac

ASSET_NAME="nvpn-${TAG}-${TARGET}.tar.gz"
ASSET_PATH="$FIXTURE_DIR/$ASSET_NAME"
MANIFEST_PATH="$FIXTURE_DIR/release.json"
INSTALL_PATH="$INSTALL_DIR/nvpn"
VERIFY_DIR="$INSTALL_DIR/verify"

rm -rf "$FIXTURE_DIR" "$INSTALL_DIR"
mkdir -p "$FIXTURE_DIR/archive/bin" "$INSTALL_DIR"

cat >"$FIXTURE_DIR/archive/bin/nvpn" <<'SH'
#!/bin/sh
echo nostr vpn cli update fixture
SH
chmod +x "$FIXTURE_DIR/archive/bin/nvpn"
tar -czf "$ASSET_PATH" -C "$FIXTURE_DIR/archive" .

node - "$MANIFEST_PATH" "$TAG" "$ASSET_NAME" <<'NODE'
const fs = require('fs');
const [manifestPath, tag, assetName] = process.argv.slice(2);
fs.writeFileSync(manifestPath, JSON.stringify({
  tag,
  assets: [{ name: assetName, path: assetName }],
}, null, 2));
NODE

MANIFEST_URL="$(
  node -e 'const { pathToFileURL } = require("url"); console.log(pathToFileURL(process.argv[1]).href)' "$MANIFEST_PATH"
)"

cd "$ROOT"

CHECK_OUTPUT="$(
  NVPN_UPDATE_MANIFEST_URL="$MANIFEST_URL" \
    cargo run --quiet -p nvpn -- update --check
)"
if ! grep -Fq "update available:" <<<"$CHECK_OUTPUT"; then
  echo "CLI update e2e failed: update check did not report an available update" >&2
  echo "$CHECK_OUTPUT" >&2
  exit 1
fi
if ! grep -Fq "asset=$ASSET_NAME" <<<"$CHECK_OUTPUT"; then
  echo "CLI update e2e failed: update check selected the wrong asset" >&2
  echo "$CHECK_OUTPUT" >&2
  exit 1
fi

DOWNLOAD_OUTPUT="$(
  NVPN_UPDATE_MANIFEST_URL="$MANIFEST_URL" \
    cargo run --quiet -p nvpn -- update --force --download-only --download-dir "$INSTALL_DIR"
)"
if ! grep -Fq "downloaded $ASSET_NAME" <<<"$DOWNLOAD_OUTPUT"; then
  echo "CLI update e2e failed: download-only did not report the expected asset" >&2
  echo "$DOWNLOAD_OUTPUT" >&2
  exit 1
fi
if ! grep -Fq "verified=false" <<<"$DOWNLOAD_OUTPUT"; then
  echo "CLI update e2e failed: fixture should remain unverified" >&2
  echo "$DOWNLOAD_OUTPUT" >&2
  exit 1
fi
DOWNLOADED_ARCHIVE="$INSTALL_DIR/$ASSET_NAME"
if [[ ! -f "$DOWNLOADED_ARCHIVE" ]]; then
  echo "CLI update e2e failed: downloaded archive is missing" >&2
  echo "$DOWNLOAD_OUTPUT" >&2
  exit 1
fi

mkdir -p "$VERIFY_DIR"
tar -xzf "$DOWNLOADED_ARCHIVE" -C "$VERIFY_DIR"
VERIFY_BINARY="$VERIFY_DIR/bin/nvpn"
if [[ ! -x "$VERIFY_BINARY" ]]; then
  echo "CLI update e2e failed: downloaded fixture is not executable" >&2
  exit 1
fi

set +e
INSTALL_OUTPUT="$(
  NVPN_UPDATE_MANIFEST_URL="$MANIFEST_URL" \
    cargo run --quiet -p nvpn -- update --force --path "$INSTALL_PATH" 2>&1
)"
INSTALL_STATUS=$?
set -e
if [[ "$INSTALL_STATUS" -eq 0 ]]; then
  echo "CLI update e2e failed: unverified fixture install unexpectedly succeeded" >&2
  echo "$INSTALL_OUTPUT" >&2
  exit 1
fi
if ! grep -Fq "refusing to install unverified update" <<<"$INSTALL_OUTPUT"; then
  echo "CLI update e2e failed: install refusal did not mention verification" >&2
  echo "$INSTALL_OUTPUT" >&2
  exit 1
fi

RUN_OUTPUT="$("$VERIFY_BINARY")"
if [[ "$RUN_OUTPUT" != "nostr vpn cli update fixture" ]]; then
  echo "CLI update e2e failed: downloaded fixture produced unexpected output" >&2
  echo "$RUN_OUTPUT" >&2
  exit 1
fi

echo "CLI_UPDATE_E2E_OK"
echo "Downloaded fixture: $DOWNLOADED_ARCHIVE"
