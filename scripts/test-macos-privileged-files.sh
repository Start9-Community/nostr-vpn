#!/usr/bin/env bash
# Exercise the production file publisher with inert fixtures, without building
# the dataplane or touching launchd / any installed helper. --root also checks
# ownership and dropped-privilege access (sudo is used only for the test runner).
set -euo pipefail

[[ "$(uname -s)" == Darwin ]] || { echo 'macOS fixtures only'; exit 0; }
[[ $# == 0 || ( $# == 1 && $1 == --root ) ]] || {
  echo 'Usage: test-macos-privileged-files.sh [--root]' >&2
  exit 2
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$ROOT/work"
FIXTURE_PROJECT="$(mktemp -d "$ROOT/work/privileged-files.XXXXXX")"
trap 'rm -rf "$FIXTURE_PROJECT"' EXIT

python3 - "$ROOT" "$FIXTURE_PROJECT" <<'PY'
import json
import pathlib
import sys
root, project = map(pathlib.Path, sys.argv[1:])
test = root / 'crates/nostr-vpn-cli/tests/macos_privileged_files.rs'
(project / 'Cargo.toml').write_text('''[package]
name = "nvpn-privileged-files-fixtures"
version = "0.0.0"
edition = "2024"
[workspace]
[dependencies]
anyhow = "1"
libc = "0.2"
rand = "0.9"
[[test]]
name = "macos_privileged_files"
path = ''' + json.dumps(str(test)) + '\n')
PY

TEST_RESULT=0
cargo test --offline --manifest-path "$FIXTURE_PROJECT/Cargo.toml" \
  --target-dir "$ROOT/work/privileged-files-target" --message-format=json \
  -- --nocapture > "$FIXTURE_PROJECT/build.jsonl" || TEST_RESULT=$?
python3 - "$FIXTURE_PROJECT/build.jsonl" <<'PY'
import json, sys
for line in open(sys.argv[1]):
    if not line.startswith('{'):
        print(line, end='')
    else:
        item = json.loads(line)
        if item.get('reason') == 'compiler-message':
            print(item['message'].get('rendered') or item['message']['message'])
PY
[[ "$TEST_RESULT" == 0 ]] || exit "$TEST_RESULT"

if [[ ${1:-} == --root ]]; then
  TEST_BINARY="$(python3 - "$FIXTURE_PROJECT/build.jsonl" <<'PY'
import json, sys
for line in open(sys.argv[1]):
    if not line.startswith('{'):
        continue
    item = json.loads(line)
    if item.get('reason') == 'compiler-artifact' and item.get('executable'):
        print(item['executable'])
PY
)"
  [[ -x "$TEST_BINARY" ]]
  sudo "$TEST_BINARY" --ignored --nocapture --test-threads=1
fi
