#!/usr/bin/env bash
# Self-test lockfile hygiene for direct mobile platform build entry points.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

fail() {
  printf 'mobile platform tools self-test failed: %s\n' "$*" >&2
  exit 1
}

make_fips_fixture() {
  local dir="$1"
  local crate
  for crate in fips-core fips-endpoint fips-identity; do
    mkdir -p "$dir/crates/$crate"
    printf '[package]\nname = "%s"\nversion = "0.0.0"\n' "$crate" \
      >"$dir/crates/$crate/Cargo.toml"
  done
  git -C "$dir" init -q
  git -C "$dir" add .
  git -C "$dir" \
    -c user.name=Harness -c user.email=harness.invalid commit -qm fixture
}

assert_failed_run_restores_lock() {
  local label="$1"
  shift
  local lock_snapshot manifest_snapshot out rc
  lock_snapshot="$(mktemp)"
  manifest_snapshot="$(mktemp)"
  cp -p "$ROOT/Cargo.lock" "$lock_snapshot"
  cp -p "$ROOT/Cargo.toml" "$manifest_snapshot"

  set +e
  out="$("$@" 2>&1)"
  rc=$?
  set -e

  if (( rc == 0 )); then
    rm -f "$lock_snapshot" "$manifest_snapshot"
    printf '%s\n' "$out" >&2
    fail "$label unexpectedly passed"
  fi
  if ! cmp -s "$lock_snapshot" "$ROOT/Cargo.lock"; then
    cp -p "$lock_snapshot" "$ROOT/Cargo.lock"
    rm -f "$lock_snapshot" "$manifest_snapshot"
    printf '%s\n' "$out" >&2
    fail "$label left Cargo.lock modified"
  fi
  if ! cmp -s "$manifest_snapshot" "$ROOT/Cargo.toml"; then
    cp -p "$manifest_snapshot" "$ROOT/Cargo.toml"
    rm -f "$lock_snapshot" "$manifest_snapshot"
    printf '%s\n' "$out" >&2
    fail "$label left Cargo.toml modified"
  fi
  rm -f "$lock_snapshot" "$manifest_snapshot"
  grep -Fq 'restored Cargo.lock after local-FIPS cargo run' <<<"$out" \
    || fail "$label did not report Cargo.lock restore"
  if grep -Fq 'restored Cargo.toml after local-FIPS cargo run' <<<"$out"; then
    fail "$label still mutates the shared Cargo.toml"
  fi
}

test_run_ios_restores_lock_after_failed_local_fips_cargo() {
  local dir stubbin fips
  dir="$(mktemp -d)"
  stubbin="$dir/bin"
  fips="$dir/fips"
  mkdir -p "$stubbin" "$dir/xcode/Toolchains/XcodeDefault.xctoolchain/usr/bin" "$dir/sdk"
  make_fips_fixture "$fips"

  cat >"$stubbin/xcode-select" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == "-p" ]] || exit 2
printf '%s\n' "$NVPN_TEST_XCODE_ROOT"
EOF
  cat >"$stubbin/xcrun" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--sdk" && "${3:-}" == "--show-sdk-path" ]]; then
  printf '%s/%s\n' "$NVPN_TEST_SDK_ROOT" "$2"
  exit 0
fi
exit 2
EOF
cat >"$stubbin/cargo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" \
  | grep -Fq "patch.crates-io.fips-core.path=\"$NVPN_TEST_FIPS_REPO_PATH/crates/fips-core\""
printf '\n# mutated by fake iOS cargo\n' >> "$NVPN_TEST_CARGO_LOCK"
exit 42
EOF
  chmod +x "$stubbin/xcode-select" "$stubbin/xcrun" "$stubbin/cargo"

  assert_failed_run_restores_lock \
    "run-ios local-FIPS cargo failure" \
    env \
      PATH="$stubbin:$PATH" \
      NVPN_TEST_XCODE_ROOT="$dir/xcode" \
      NVPN_TEST_SDK_ROOT="$dir/sdk" \
      NVPN_TEST_CARGO_LOCK="$ROOT/Cargo.lock" \
      NVPN_TEST_CARGO_MANIFEST="$ROOT/Cargo.toml" \
      NVPN_TEST_FIPS_REPO_PATH="$fips" \
      NVPN_FIPS_REPO_PATH="$fips" \
      "$ROOT/tools/run-ios" rust

  rm -rf "$dir"
}

test_run_android_restores_lock_after_failed_local_fips_gradle() {
  local dir stubbin fips
  dir="$(mktemp -d)"
  stubbin="$dir/bin"
  fips="$dir/fips"
  mkdir -p "$stubbin"
  make_fips_fixture "$fips"

  cat >"$stubbin/cargo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" \
  | grep -Fq "patch.crates-io.fips-core.path=\"$NVPN_TEST_FIPS_REPO_PATH/crates/fips-core\""
printf '\n# mutated by fake Android cargo\n' >> "$NVPN_TEST_CARGO_LOCK"
exit 42
EOF
  cat >"$stubbin/gradle" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cargo metadata
exit 43
EOF
  chmod +x "$stubbin/cargo" "$stubbin/gradle"

  assert_failed_run_restores_lock \
    "run-android local-FIPS Gradle failure" \
    env \
      PATH="$stubbin:$PATH" \
      HOME="$dir/home" \
      NVPN_TEST_CARGO_LOCK="$ROOT/Cargo.lock" \
      NVPN_TEST_CARGO_MANIFEST="$ROOT/Cargo.toml" \
      NVPN_TEST_FIPS_REPO_PATH="$fips" \
      NVPN_FIPS_REPO_PATH="$fips" \
      "$ROOT/tools/run-android" build

  rm -rf "$dir"
}

test_run_ios_restores_lock_after_failed_local_fips_cargo
test_run_android_restores_lock_after_failed_local_fips_gradle

printf 'mobile platform tools self-test passed\n'
