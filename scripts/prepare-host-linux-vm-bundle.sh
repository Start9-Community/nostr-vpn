#!/usr/bin/env bash
# Build/cache the exact Ubuntu 24.04 x86_64 artifacts on the controlling Mac.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck disable=SC1091
source "$ROOT/scripts/release_common.sh"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib-mobile-release-join-artifacts.sh"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib-host-linux-builder-isolation.sh"

load_release_env "$ROOT"
[[ "$(uname -s)" == "Darwin" ]] || {
  echo "Linux VM release artifacts must be built on the controlling Mac" >&2
  exit 2
}
command -v docker >/dev/null 2>&1 || {
  echo "Linux VM release artifacts require Docker on the controlling Mac" >&2
  exit 2
}

APP_GIT_SHA="$(git -C "$ROOT" rev-parse HEAD)"
APP_GIT_TREE="$(git -C "$ROOT" rev-parse 'HEAD^{tree}')"
APP_GIT_STATUS="$(git -C "$ROOT" status --porcelain --untracked-files=all)"
EXPECTED_APP_GIT_SHA="${NVPN_EXPECTED_APP_GIT_SHA:-$APP_GIT_SHA}"
[[ "$EXPECTED_APP_GIT_SHA" =~ ^[0-9a-f]{40}$ \
  && "$APP_GIT_SHA" == "$EXPECTED_APP_GIT_SHA" ]] || {
  echo "Host Linux VM bundle app commit differs from the exact candidate" >&2
  exit 2
}
[[ -z "$APP_GIT_STATUS" ]] || {
  echo "Host Linux VM bundle refuses a dirty app checkout" >&2
  exit 2
}
if [[ -n "${NVPN_EXPECTED_APP_GIT_TREE:-}" \
  && "$APP_GIT_TREE" != "$NVPN_EXPECTED_APP_GIT_TREE" ]]
then
  echo "Host Linux VM bundle app tree differs from the exact candidate" >&2
  exit 2
fi
APP_VERSION="$(
  awk '
    $0 == "[workspace.package]" { package = 1; next }
    package && /^\[/ { exit }
    package && /^version = "/ {
      value = $0
      sub(/^version = "/, "", value)
      sub(/".*$/, "", value)
      print value
      exit
    }
  ' "$ROOT/Cargo.toml"
)"
[[ "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]] || {
  echo "Host Linux VM bundle could not derive the app version" >&2
  exit 2
}
ROOT_CARGO_LOCK_SHA256="$(shasum -a 256 "$ROOT/Cargo.lock" | awk '{ print $1 }')"
LINUX_CARGO_LOCK_SHA256="$(
  shasum -a 256 "$ROOT/linux/Cargo.lock" | awk '{ print $1 }'
)"
[[ "$ROOT_CARGO_LOCK_SHA256" =~ ^[0-9a-f]{64}$ \
  && "$LINUX_CARGO_LOCK_SHA256" =~ ^[0-9a-f]{64}$ ]] || {
  echo "Host Linux VM bundle could not hash the committed Cargo lockfiles" >&2
  exit 2
}

release_join_require_clean_fips
release_join_assert_fips_unchanged
TARGET="x86_64-unknown-linux-gnu"
DOCKER_PLATFORM="linux/amd64"
CONTAINER_BASE="ubuntu:24.04"
RUST_TOOLCHAIN="${NVPN_HOST_LINUX_VM_RUST_TOOLCHAIN:-1.95.0}"
[[ "$RUST_TOOLCHAIN" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "Host Linux VM bundle Rust toolchain must be an exact stable version" >&2
  exit 2
}
SOURCE_DATE_EPOCH="$(git -C "$ROOT" log -1 --format=%ct "$APP_GIT_SHA")"
export SOURCE_DATE_EPOCH

CACHE_ROOT="${NVPN_HOST_LINUX_VM_BUNDLE_CACHE_DIR:-${ARTIFACT_ROOT:-$ROOT/artifacts}/host-linux-vm-bundle}"
mkdir -p "$CACHE_ROOT"
CACHE_ROOT="$(cd "$CACHE_ROOT" && pwd)"
HOST_BUILD_LOCK="$CACHE_ROOT/.host-linux-vm-bundle.lock"
CARGO_DEB_VERSION="3.7.0"
MUSL_TARGET="x86_64-unknown-linux-musl"
CACHE_KEY="$APP_GIT_SHA-$RELEASE_JOIN_FIPS_SHA-$TARGET-ubuntu24.04-rust$RUST_TOOLCHAIN-cargo-deb$CARGO_DEB_VERSION-package3"
BUNDLE_DIR="$CACHE_ROOT/$CACHE_KEY"
RECEIPT="$BUNDLE_DIR/receipt.json"
TARGET_CACHE_GENERATION="serialized-v2-rust${RUST_TOOLCHAIN//./-}"
TARGET_CACHE_ROOT="$CACHE_ROOT/build-cache/$TARGET_CACHE_GENERATION"
BUILD_CACHE_ID="$(
  printf '%s' "$CACHE_ROOT" | shasum -a 256 | awk '{ print $1 }'
)"
VERIFIER="$ROOT/scripts/verify-host-linux-vm-bundle.py"
PATCH_LOCK_VERIFIER="$ROOT/scripts/verify-cargo-path-patch-lock.py"
[[ -x "$PATCH_LOCK_VERIFIER" ]] || {
  echo "Host Linux VM bundle exact FIPS lock verifier is missing" >&2
  exit 2
}
FIPS_PATCH_PACKAGES=()
while IFS= read -r package; do
  FIPS_PATCH_PACKAGES+=("$package")
done < <(
  python3 "$PATCH_LOCK_VERIFIER" \
    --manifest-specs "$NVPN_FIPS_REPO_PATH"
)
[[ "${#FIPS_PATCH_PACKAGES[@]}" == 3 ]] || {
  echo "Host Linux VM bundle lacks the three exact FIPS patch packages" >&2
  exit 2
}
ROOT_REALIZED_CARGO_LOCK_SHA256="$(
  python3 "$PATCH_LOCK_VERIFIER" \
    --expected-sha256 "$ROOT/Cargo.lock" "${FIPS_PATCH_PACKAGES[@]}"
)"
LINUX_REALIZED_CARGO_LOCK_SHA256="$(
  python3 "$PATCH_LOCK_VERIFIER" \
    --expected-sha256 "$ROOT/linux/Cargo.lock" "${FIPS_PATCH_PACKAGES[@]}"
)"
TEMP_DIR=""
CONTAINER_NAME="nvpn-linux-bundle-${BUILD_CACHE_ID:0:24}"
HOST_BUILD_LOCK_HELD=0

cleanup() {
  local status="$?" cleanup_failed=0
  trap - EXIT HUP INT TERM
  if [[ "$HOST_BUILD_LOCK_HELD" == "1" ]]; then
    host_linux_builder_stop_container \
      "$CONTAINER_NAME" "$BUILD_CACHE_ID" \
      || cleanup_failed=1
  fi
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
    find "$TEMP_DIR" -xdev -depth -mindepth 1 -delete || cleanup_failed=1
    rmdir "$TEMP_DIR" || cleanup_failed=1
  fi
  if [[ "$status" -eq 0 && "$cleanup_failed" -ne 0 ]]; then
    status=1
  fi
  exit "$status"
}

terminate() {
  local status="$1"
  if [[ "$HOST_BUILD_LOCK_HELD" == "1" ]]; then
    host_linux_builder_stop_container \
      "$CONTAINER_NAME" "$BUILD_CACHE_ID" || true
  fi
  exit "$status"
}

trap cleanup EXIT
trap 'terminate 129' HUP
trap 'terminate 130' INT
trap 'terminate 143' TERM

verify_bundle() {
  [[ -x "$VERIFIER" && -d "$BUNDLE_DIR" && -f "$RECEIPT" ]] || return 1
  python3 "$VERIFIER" \
    "$BUNDLE_DIR" \
    "$RECEIPT" \
    "$APP_GIT_SHA" \
    "$APP_GIT_TREE" \
    "$APP_VERSION" \
    "$RELEASE_JOIN_FIPS_SHA" \
    "$RELEASE_JOIN_FIPS_TREE" \
    "$RELEASE_JOIN_FIPS_VERSION" \
    "$ROOT_CARGO_LOCK_SHA256" \
    "$ROOT_REALIZED_CARGO_LOCK_SHA256" \
    "$LINUX_CARGO_LOCK_SHA256" \
    "$LINUX_REALIZED_CARGO_LOCK_SHA256" \
    "$TARGET" \
    "${FIPS_PATCH_PACKAGES[@]}" \
    >/dev/null
}

if verify_bundle; then
  printf '%s\n' "$BUNDLE_DIR"
  exit 0
fi

[[ -x /usr/bin/lockf ]] || {
  echo "Host Linux VM bundle builder requires macOS /usr/bin/lockf." >&2
  exit 2
}
exec 9>"$HOST_BUILD_LOCK"
chmod 0600 "$HOST_BUILD_LOCK"
/usr/bin/lockf 9
HOST_BUILD_LOCK_HELD=1

# A second process can finish the exact bundle while this process waits for
# the kernel lock. Re-verify under the lock before spending any build work.
if verify_bundle; then
  printf '%s\n' "$BUNDLE_DIR"
  exit 0
fi

# A SIGKILL cannot run a shell trap. The kernel lock is still released, so
# remove any daemon-owned container carrying this cache identity before the
# persistent targets can be mounted by the next build.
host_linux_builder_stop_container "$CONTAINER_NAME" "$BUILD_CACHE_ID"

TEMP_DIR="$(mktemp -d "$CACHE_ROOT/.host-linux-vm-bundle.XXXXXX")"
mkdir -p \
  "$TEMP_DIR/source" \
  "$TEMP_DIR/output" \
  "$TEMP_DIR/final" \
  "$CACHE_ROOT/build-cache/cargo-home" \
  "$TARGET_CACHE_ROOT/root-target"
git clone --no-hardlinks --quiet "$ROOT" "$TEMP_DIR/source/app"
git -C "$TEMP_DIR/source/app" checkout --detach --quiet "$APP_GIT_SHA"
git -C "$TEMP_DIR/source/app" clean -ffd >/dev/null
git clone --no-hardlinks --quiet "$NVPN_FIPS_REPO_PATH" "$TEMP_DIR/source/fips"
git -C "$TEMP_DIR/source/fips" checkout --detach --quiet "$RELEASE_JOIN_FIPS_SHA"
git -C "$TEMP_DIR/source/fips" clean -ffd >/dev/null
[[ -z "$(git -C "$TEMP_DIR/source/app" status --porcelain --untracked-files=all)" \
  && "$(git -C "$TEMP_DIR/source/app" rev-parse HEAD)" == "$APP_GIT_SHA" \
  && "$(git -C "$TEMP_DIR/source/app" rev-parse 'HEAD^{tree}')" == "$APP_GIT_TREE" ]]
[[ -z "$(git -C "$TEMP_DIR/source/fips" status --porcelain --untracked-files=all)" \
  && "$(git -C "$TEMP_DIR/source/fips" rev-parse HEAD)" == "$RELEASE_JOIN_FIPS_SHA" \
  && "$(git -C "$TEMP_DIR/source/fips" rev-parse 'HEAD^{tree}')" == "$RELEASE_JOIN_FIPS_TREE" ]]
[[ "$(shasum -a 256 "$TEMP_DIR/source/app/Cargo.lock" | awk '{ print $1 }')" \
  == "$ROOT_CARGO_LOCK_SHA256" ]]
[[ "$(shasum -a 256 "$TEMP_DIR/source/app/linux/Cargo.lock" | awk '{ print $1 }')" \
  == "$LINUX_CARGO_LOCK_SHA256" ]]

IMAGE_TAG="nostr-vpn-linux-vm-gate:ubuntu24.04-rust${RUST_TOOLCHAIN//./-}"
docker build \
  --platform "$DOCKER_PLATFORM" \
  --build-arg "RUST_TOOLCHAIN=$RUST_TOOLCHAIN" \
  --file "$ROOT/Dockerfile.linux-vm-gate" \
  --tag "$IMAGE_TAG" \
  "$ROOT" \
  >"$TEMP_DIR/docker-build.log"

docker run --rm \
  --name "$CONTAINER_NAME" \
  --label "to.nostrvpn.release-builder=host-linux-vm-bundle" \
  --label "to.nostrvpn.release-builder-cache=$BUILD_CACHE_ID" \
  --interactive \
  --platform "$DOCKER_PLATFORM" \
  --volume "$TEMP_DIR/source/app:/workspace/app" \
  --volume "$TEMP_DIR/source/fips:/workspace/fips:ro" \
  --volume "$TEMP_DIR/output:/output" \
  --volume "$CACHE_ROOT/build-cache/cargo-home:/cargo-home" \
  --volume "$TARGET_CACHE_ROOT/root-target:/target-root" \
  --env CARGO_HOME=/cargo-home \
  --env CARGO_INCREMENTAL=0 \
  --env "NVPN_BUILD_GIT_SHA=$APP_GIT_SHA" \
  --env "EXPECTED_ROOT_REALIZED_CARGO_LOCK_SHA256=$ROOT_REALIZED_CARGO_LOCK_SHA256" \
  --env "EXPECTED_LINUX_REALIZED_CARGO_LOCK_SHA256=$LINUX_REALIZED_CARGO_LOCK_SHA256" \
  --env "SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH" \
  --env TZ=UTC \
  --env LC_ALL=C.UTF-8 \
  "$IMAGE_TAG" \
  bash -se <<'CONTAINER'
set -euo pipefail
cd /workspace/app
fips_config=(
  --config 'patch.crates-io.fips-core.path="/workspace/fips/crates/fips-core"'
  --config 'patch.crates-io.fips-endpoint.path="/workspace/fips/crates/fips-endpoint"'
  --config 'patch.crates-io.fips-identity.path="/workspace/fips/crates/fips-identity"'
)
lock_verifier=/workspace/app/scripts/verify-cargo-path-patch-lock.py
fips_packages=()
while IFS= read -r package; do
  fips_packages+=("$package")
done < <(python3 "$lock_verifier" --manifest-specs /workspace/fips)
[[ "${#fips_packages[@]}" == 3 ]]

export CARGO_TARGET_DIR=/target-root
cp Cargo.lock /output/root-Cargo.lock.committed
cargo "${fips_config[@]}" metadata --format-version 1 >/dev/null
python3 "$lock_verifier" \
  --validate /output/root-Cargo.lock.committed Cargo.lock \
  "${fips_packages[@]}" \
  > /output/root-realized-cargo-lock-sha256.txt
grep -Fx "$EXPECTED_ROOT_REALIZED_CARGO_LOCK_SHA256" \
  /output/root-realized-cargo-lock-sha256.txt
cargo "${fips_config[@]}" metadata --locked --format-version 1 --no-deps \
  >/dev/null
cargo "${fips_config[@]}" build --locked --release -p nvpn
cargo "${fips_config[@]}" build --locked --release \
  --target x86_64-unknown-linux-musl \
  -p nvpn
cargo "${fips_config[@]}" build --locked --release \
  -p nostr-vpn-core --example desktop_manual_join_e2e_fixture

cd /workspace/app/linux
export CARGO_TARGET_DIR=/target-root
cp Cargo.lock /output/linux-Cargo.lock.committed
cargo "${fips_config[@]}" metadata --format-version 1 >/dev/null
python3 "$lock_verifier" \
  --validate /output/linux-Cargo.lock.committed Cargo.lock \
  "${fips_packages[@]}" \
  > /output/linux-realized-cargo-lock-sha256.txt
grep -Fx "$EXPECTED_LINUX_REALIZED_CARGO_LOCK_SHA256" \
  /output/linux-realized-cargo-lock-sha256.txt
cargo "${fips_config[@]}" metadata --locked --format-version 1 --no-deps \
  >/dev/null
cargo "${fips_config[@]}" build --locked --release

install -m 0555 /target-root/release/nvpn /output/nvpn
install -m 0555 \
  /target-root/release/examples/desktop_manual_join_e2e_fixture \
  /output/desktop_manual_join_e2e_fixture
install -m 0555 /target-root/release/nostr-vpn /output/nostr-vpn
install -m 0555 \
  /target-root/x86_64-unknown-linux-musl/release/nvpn \
  /output/nvpn-x86_64-unknown-linux-musl
file \
  /output/nvpn \
  /output/desktop_manual_join_e2e_fixture \
  /output/nostr-vpn \
  /output/nvpn-x86_64-unknown-linux-musl \
  > /output/file.txt
for artifact in \
  nvpn \
  desktop_manual_join_e2e_fixture \
  nostr-vpn \
  nvpn-x86_64-unknown-linux-musl
do
  grep -F "$artifact" /output/file.txt | grep -Eq 'ELF 64-bit.*x86-64'
done
grep -F 'nvpn-x86_64-unknown-linux-musl' /output/file.txt \
  | grep -Eq 'statically linked|static-pie linked'
/output/nvpn --version > /output/cli-short-version.txt
/output/nvpn version --verbose > /output/cli-verbose-version.txt
/output/nvpn-x86_64-unknown-linux-musl --version \
  > /output/musl-cli-short-version.txt
/output/nvpn-x86_64-unknown-linux-musl version --verbose \
  > /output/musl-cli-verbose-version.txt

# Package the already-built, exact glibc binaries. cargo-deb's default strip
# step would create different payload bytes, so it is explicitly disabled.
mkdir -p /workspace/app/target/release /workspace/app/linux/target/release
install -m 0555 /output/nvpn /workspace/app/target/release/nvpn
install -m 0555 /output/nostr-vpn \
  /workspace/app/linux/target/release/nostr-vpn
cd /workspace/app/linux
unset CARGO_TARGET_DIR
rm -rf target/debian
cargo deb --no-build --no-strip
deb="$(find target/debian -maxdepth 1 -type f -name '*.deb' -print)"
[[ "$(printf '%s\n' "$deb" | sed '/^$/d' | wc -l)" == "1" ]]
install -m 0444 "$deb" /output/nostr-vpn.deb
rm -rf /output/deb-root
mkdir -p /output/deb-root
dpkg-deb -x /output/nostr-vpn.deb /output/deb-root
cmp -s /output/deb-root/usr/bin/nostr-vpn /output/nostr-vpn
cmp -s /output/deb-root/usr/bin/nvpn /output/nvpn
[[ "$(dpkg-deb -f /output/nostr-vpn.deb Package)" == "nostr-vpn" ]]
[[ "$(dpkg-deb -f /output/nostr-vpn.deb Architecture)" == "amd64" ]]
dpkg-deb -f /output/nostr-vpn.deb Version > /output/deb-version.txt

archive_root=/output/archive-root
rm -rf "$archive_root"
mkdir -p "$archive_root/nvpn"
install -m 0555 /output/nvpn-x86_64-unknown-linux-musl \
  "$archive_root/nvpn/nvpn"
printf '%s\n' \
  '#!/bin/bash' \
  'set -e' \
  'install -d "${1:-/usr/local/bin}"' \
  'install -m 755 nvpn "${1:-/usr/local/bin}/"' \
  >"$archive_root/nvpn/install.sh"
chmod 0555 "$archive_root/nvpn/install.sh"
printf '%s\n' 'nvpn - FIPS private mesh CLI' \
  >"$archive_root/nvpn/README.txt"
find "$archive_root" -exec touch -h -d "@${SOURCE_DATE_EPOCH}" {} +
tar \
  --sort=name \
  --format=ustar \
  --owner=0 \
  --group=0 \
  --numeric-owner \
  --mtime="@${SOURCE_DATE_EPOCH}" \
  -cf /output/nvpn-x86_64-unknown-linux-musl.tar \
  -C "$archive_root" \
  nvpn/README.txt nvpn/install.sh nvpn/nvpn
gzip -n -f /output/nvpn-x86_64-unknown-linux-musl.tar
tar -xOf /output/nvpn-x86_64-unknown-linux-musl.tar.gz nvpn/nvpn \
  | cmp -s - /output/nvpn-x86_64-unknown-linux-musl
rm -rf "$archive_root" /output/deb-root
rustc --version > /output/rustc-version.txt
cargo --version > /output/cargo-version.txt
CONTAINER

[[ "$(shasum -a 256 "$TEMP_DIR/source/app/Cargo.lock" | awk '{ print $1 }')" \
  == "$ROOT_REALIZED_CARGO_LOCK_SHA256" ]]
[[ "$(shasum -a 256 "$TEMP_DIR/source/app/linux/Cargo.lock" | awk '{ print $1 }')" \
  == "$LINUX_REALIZED_CARGO_LOCK_SHA256" ]]
[[ "$(<"$TEMP_DIR/output/root-realized-cargo-lock-sha256.txt")" \
  == "$ROOT_REALIZED_CARGO_LOCK_SHA256" ]]
[[ "$(<"$TEMP_DIR/output/linux-realized-cargo-lock-sha256.txt")" \
  == "$LINUX_REALIZED_CARGO_LOCK_SHA256" ]]
for artifact in \
  nvpn \
  desktop_manual_join_e2e_fixture \
  nostr-vpn \
  nvpn-x86_64-unknown-linux-musl
do
  install -m 0555 "$TEMP_DIR/output/$artifact" "$TEMP_DIR/final/$artifact"
done
for artifact in nostr-vpn.deb nvpn-x86_64-unknown-linux-musl.tar.gz; do
  install -m 0444 "$TEMP_DIR/output/$artifact" "$TEMP_DIR/final/$artifact"
done
python3 - \
  "$TEMP_DIR/final/receipt.json" \
  "$TEMP_DIR/final" \
  "$APP_GIT_SHA" \
  "$APP_GIT_TREE" \
  "$APP_VERSION" \
  "$RELEASE_JOIN_FIPS_SHA" \
  "$RELEASE_JOIN_FIPS_TREE" \
  "$RELEASE_JOIN_FIPS_VERSION" \
  "$ROOT_CARGO_LOCK_SHA256" \
  "$ROOT_REALIZED_CARGO_LOCK_SHA256" \
  "$LINUX_CARGO_LOCK_SHA256" \
  "$LINUX_REALIZED_CARGO_LOCK_SHA256" \
  "$TARGET" \
  "${FIPS_PATCH_PACKAGES[@]}" \
  "$SOURCE_DATE_EPOCH" \
  "$TEMP_DIR/output/cli-short-version.txt" \
  "$TEMP_DIR/output/cli-verbose-version.txt" \
  "$TEMP_DIR/output/rustc-version.txt" \
  "$TEMP_DIR/output/cargo-version.txt" \
  "$TEMP_DIR/output/musl-cli-short-version.txt" \
  "$TEMP_DIR/output/musl-cli-verbose-version.txt" \
  "$TEMP_DIR/output/deb-version.txt" <<'PY'
import hashlib
import json
import pathlib
import sys

(
    receipt_arg,
    bundle_arg,
    app_sha,
    app_tree,
    app_version,
    fips_sha,
    fips_tree,
    fips_version,
    root_cargo_lock_sha256,
    root_realized_cargo_lock_sha256,
    linux_cargo_lock_sha256,
    linux_realized_cargo_lock_sha256,
    target,
    fips_core_patch_spec,
    fips_endpoint_patch_spec,
    fips_identity_patch_spec,
    source_epoch,
    cli_short_arg,
    cli_verbose_arg,
    rustc_arg,
    cargo_arg,
    musl_cli_short_arg,
    musl_cli_verbose_arg,
    deb_version_arg,
) = sys.argv[1:]
bundle = pathlib.Path(bundle_arg)
fips_patch_packages = dict(
    spec.split("=", 1)
    for spec in (
        fips_core_patch_spec,
        fips_endpoint_patch_spec,
        fips_identity_patch_spec,
    )
)
if set(fips_patch_packages) != {
    "fips-core",
    "fips-endpoint",
    "fips-identity",
}:
    raise SystemExit("unexpected exact FIPS patched lock package set")
names = {
    "app": "nostr-vpn",
    "cli": "nvpn",
    "manualJoinFixture": "desktop_manual_join_e2e_fixture",
    "muslCli": "nvpn-x86_64-unknown-linux-musl",
    "debianPackage": "nostr-vpn.deb",
    "muslCliArchive": "nvpn-x86_64-unknown-linux-musl.tar.gz",
}
artifacts = {}
for label, name in names.items():
    path = bundle / name
    digest = hashlib.sha256()
    with path.open("rb") as artifact:
        for chunk in iter(lambda: artifact.read(1024 * 1024), b""):
            digest.update(chunk)
    artifacts[label] = {
        "file": name,
        "sha256": digest.hexdigest(),
        "size": path.stat().st_size,
    }
payload = {
    "schema": 1,
    "builtOnHostMac": True,
    "builtOnRemoteVm": False,
    "appGitSha": app_sha,
    "appGitTree": app_tree,
    "appVersion": app_version,
    "fipsGitSha": fips_sha,
    "fipsGitTree": fips_tree,
    "fipsVersion": fips_version,
    "rootCargoLockSha256": root_cargo_lock_sha256,
    "rootRealizedCargoLockSha256": root_realized_cargo_lock_sha256,
    "linuxCargoLockSha256": linux_cargo_lock_sha256,
    "linuxRealizedCargoLockSha256": linux_realized_cargo_lock_sha256,
    "fipsPatchedLockPackages": fips_patch_packages,
    "target": target,
    "dockerPlatform": "linux/amd64",
    "containerBase": "ubuntu:24.04",
    "sourceDateEpoch": int(source_epoch),
    "rustcVersion": pathlib.Path(rustc_arg).read_text(encoding="utf-8").strip(),
    "cargoVersion": pathlib.Path(cargo_arg).read_text(encoding="utf-8").strip(),
    "cliShortVersion": pathlib.Path(cli_short_arg).read_text(encoding="utf-8").strip(),
    "cliVerboseVersion": pathlib.Path(cli_verbose_arg).read_text(encoding="utf-8").strip(),
    "muslCliShortVersion": pathlib.Path(musl_cli_short_arg).read_text(
        encoding="utf-8"
    ).strip(),
    "muslCliVerboseVersion": pathlib.Path(musl_cli_verbose_arg).read_text(
        encoding="utf-8"
    ).strip(),
    "debianPackage": {
        "package": "nostr-vpn",
        "version": pathlib.Path(deb_version_arg).read_text(
            encoding="utf-8"
        ).strip(),
        "architecture": "amd64",
        "appPath": "usr/bin/nostr-vpn",
        "cliPath": "usr/bin/nvpn",
    },
    "muslTarget": "x86_64-unknown-linux-musl",
    "cargoDebVersion": "3.7.0",
    "artifacts": artifacts,
}
pathlib.Path(receipt_arg).write_text(
    json.dumps(payload, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY

python3 "$VERIFIER" \
  "$TEMP_DIR/final" \
  "$TEMP_DIR/final/receipt.json" \
  "$APP_GIT_SHA" \
  "$APP_GIT_TREE" \
  "$APP_VERSION" \
  "$RELEASE_JOIN_FIPS_SHA" \
  "$RELEASE_JOIN_FIPS_TREE" \
  "$RELEASE_JOIN_FIPS_VERSION" \
  "$ROOT_CARGO_LOCK_SHA256" \
  "$ROOT_REALIZED_CARGO_LOCK_SHA256" \
  "$LINUX_CARGO_LOCK_SHA256" \
  "$LINUX_REALIZED_CARGO_LOCK_SHA256" \
  "$TARGET" \
  "${FIPS_PATCH_PACKAGES[@]}" \
  >/dev/null
release_join_assert_app_unchanged "$APP_GIT_SHA" "$APP_GIT_TREE"
release_join_assert_fips_unchanged

if [[ -d "$BUNDLE_DIR" ]]; then
  find "$BUNDLE_DIR" -xdev -depth -mindepth 1 -delete
  rmdir "$BUNDLE_DIR"
fi
mv "$TEMP_DIR/final" "$BUNDLE_DIR"
find "$TEMP_DIR" -xdev -depth -mindepth 1 -delete
rmdir "$TEMP_DIR"
TEMP_DIR=""
verify_bundle
printf '%s\n' "$BUNDLE_DIR"
