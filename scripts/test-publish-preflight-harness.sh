#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PUBLISHER="$ROOT/scripts/publish.sh"

fail() {
  printf 'publish preflight harness failed: %s\n' "$*" >&2
  exit 1
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

if grep -Fq 'import tomllib' "$PUBLISHER"; then
  fail "credential preflight requires Python 3.11 tomllib"
fi
if grep -Fq 'url = "https://crates.io/api/v1/me"' "$PUBLISHER"; then
  fail "credential preflight uses the website-only /api/v1/me endpoint"
fi

awk '
  /^preflight_crates_io_credentials\(\) \{/ {
    emit = 1
  }
  /^publish_crate\(\) \{/ {
    exit
  }
  emit {
    print
  }
' "$PUBLISHER" >"$tmp_dir/preflight-function.sh"
grep -Fq 'preflight_crates_io_credentials()' "$tmp_dir/preflight-function.sh" \
  || fail "could not extract credential preflight function"

mkdir -p "$tmp_dir/bin" "$tmp_dir/cargo-home"
cat >"$tmp_dir/bin/cargo" <<'EOF'
#!/bin/bash
set -euo pipefail
[[ "$*" == owner\ --list\ --registry\ crates-io\ * ]] || {
  echo "unexpected cargo arguments" >&2
  exit 64
}
[[ "$*" != *" --token "* ]] || {
  echo "credential leaked onto the command line" >&2
  exit 65
}
printf '%s\n' "$*" >>"$NVPN_TEST_CARGO_LOG"
[[ -n "${CARGO_REGISTRY_TOKEN:-}" || -s "${CARGO_HOME}/credentials.toml" ]] || {
  echo "no token found, please run cargo login" >&2
  exit 101
}
case "${NVPN_TEST_CARGO_MODE:-success}" in
  success)
    printf '%s\n' 'release-owner'
    ;;
  rejected)
    echo "registry query failed" >&2
    exit 101
    ;;
  *)
    echo "unknown test mode" >&2
    exit 66
    ;;
esac
EOF
chmod +x "$tmp_dir/bin/cargo"

cat >"$tmp_dir/cargo-home/credentials.toml" <<'EOF'
[registry]
token = "test-token-from-credentials"
EOF

run_preflight() {
  local mode="$1"
  env -u CARGO_REGISTRY_TOKEN \
    PATH="$tmp_dir/bin:/usr/bin:/bin" \
    CARGO_HOME="$tmp_dir/cargo-home" \
    NVPN_TEST_CARGO_LOG="$tmp_dir/cargo.log" \
    NVPN_TEST_CARGO_MODE="$mode" \
    bash -c '
      source "$1"
      ALL_CRATES=(nostr-vpn-core nostr-vpn-wintun nvpn)
      preflight_crates_io_credentials
    ' bash "$tmp_dir/preflight-function.sh"
}

: >"$tmp_dir/cargo.log"
run_preflight success
[[ "$(wc -l <"$tmp_dir/cargo.log" | tr -d ' ')" == 3 ]] \
  || fail "did not resolve the credential for every publishable crate"
for crate in nostr-vpn-core nostr-vpn-wintun nvpn; do
  grep -Fxq "owner --list --registry crates-io ${crate}" "$tmp_dir/cargo.log" \
    || fail "did not use Cargo's read-only owner query for $crate"
done

if run_preflight rejected >"$tmp_dir/rejected.out" 2>&1; then
  fail "accepted a failed Cargo credential query"
fi

mkdir -p "$tmp_dir/empty-cargo-home"
if env -u CARGO_REGISTRY_TOKEN \
  PATH="$tmp_dir/bin:/usr/bin:/bin" \
  CARGO_HOME="$tmp_dir/empty-cargo-home" \
  NVPN_TEST_CARGO_LOG="$tmp_dir/cargo.log" \
  bash -c '
    source "$1"
    ALL_CRATES=(nostr-vpn-core)
    preflight_crates_io_credentials
  ' bash "$tmp_dir/preflight-function.sh" >"$tmp_dir/missing.out" 2>&1
then
  fail "accepted a missing Cargo credential"
fi
grep -Fq 'Cargo could not resolve crates.io credentials' "$tmp_dir/missing.out" \
  || fail "missing credential error is not actionable"

printf 'publish preflight harness passed\n'
