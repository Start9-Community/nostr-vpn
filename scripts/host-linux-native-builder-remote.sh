#!/usr/bin/env bash
# Execute the canonical Linux release build on an explicitly selected native
# x86_64 Linux Docker host. Stdout is reserved for one exact output tar.
set -euo pipefail

usage() {
  echo "usage: $0 REMOTE_ROOT APP_BUNDLE_SHA APP_SHA APP_TREE FIPS_BUNDLE_SHA FIPS_SHA FIPS_TREE RUST_TOOLCHAIN CACHE_ID TARGET_GENERATION TARGET_VOLUME CONTAINER_NAME ROOT_REALIZED_LOCK LINUX_REALIZED_LOCK SOURCE_DATE_EPOCH DOCKERFILE_SHA PAYLOAD_SHA" >&2
  exit 2
}

[[ "$#" == 17 ]] || usage
REMOTE_ROOT="$1"
APP_BUNDLE_SHA256="$2"
APP_GIT_SHA="$3"
APP_GIT_TREE="$4"
FIPS_BUNDLE_SHA256="$5"
FIPS_GIT_SHA="$6"
FIPS_GIT_TREE="$7"
RUST_TOOLCHAIN="$8"
BUILD_CACHE_ID="$9"
TARGET_CACHE_GENERATION="${10}"
TARGET_VOLUME_NAME="${11}"
CONTAINER_NAME="${12}"
ROOT_REALIZED_CARGO_LOCK_SHA256="${13}"
LINUX_REALIZED_CARGO_LOCK_SHA256="${14}"
SOURCE_DATE_EPOCH="${15}"
EXPECTED_DOCKERFILE_SHA256="${16}"
EXPECTED_PAYLOAD_SHA256="${17}"

[[ "$REMOTE_ROOT" \
  =~ ^/tmp/nvpn-linux-native-builder\.[A-Za-z0-9]{6}$ ]] || {
  echo "remote native builder received an unsafe root" >&2
  exit 2
}
[[ -d "$REMOTE_ROOT" && -O "$REMOTE_ROOT" && ! -L "$REMOTE_ROOT" ]] || {
  echo "remote native builder root is not a private owned directory" >&2
  exit 2
}
[[ "$(stat -c '%a' "$REMOTE_ROOT")" == "700" ]] || {
  echo "remote native builder root must have mode 0700" >&2
  exit 2
}
for value in \
  "$APP_BUNDLE_SHA256" \
  "$APP_GIT_SHA" \
  "$APP_GIT_TREE" \
  "$FIPS_BUNDLE_SHA256" \
  "$FIPS_GIT_SHA" \
  "$FIPS_GIT_TREE" \
  "$BUILD_CACHE_ID" \
  "$ROOT_REALIZED_CARGO_LOCK_SHA256" \
  "$LINUX_REALIZED_CARGO_LOCK_SHA256" \
  "$EXPECTED_DOCKERFILE_SHA256" \
  "$EXPECTED_PAYLOAD_SHA256"
do
  [[ "$value" =~ ^[0-9a-f]+$ ]] || {
    echo "remote native builder received malformed provenance" >&2
    exit 2
  }
done
[[ "${#APP_BUNDLE_SHA256}" == 64 \
  && "${#APP_GIT_SHA}" == 40 \
  && "${#APP_GIT_TREE}" == 40 \
  && "${#FIPS_BUNDLE_SHA256}" == 64 \
  && "${#FIPS_GIT_SHA}" == 40 \
  && "${#FIPS_GIT_TREE}" == 40 \
  && "${#BUILD_CACHE_ID}" == 64 \
  && "${#ROOT_REALIZED_CARGO_LOCK_SHA256}" == 64 \
  && "${#LINUX_REALIZED_CARGO_LOCK_SHA256}" == 64 \
  && "${#EXPECTED_DOCKERFILE_SHA256}" == 64 \
  && "${#EXPECTED_PAYLOAD_SHA256}" == 64 ]] || {
  echo "remote native builder received wrong-length provenance" >&2
  exit 2
}
[[ "$RUST_TOOLCHAIN" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ \
  && "$SOURCE_DATE_EPOCH" =~ ^[1-9][0-9]*$ \
  && "$TARGET_CACHE_GENERATION" =~ ^[0-9A-Za-z._-]+$ \
  && "$TARGET_VOLUME_NAME" =~ ^nvpn-linux-target-[0-9a-f]{24}$ \
  && "$CONTAINER_NAME" =~ ^nvpn-linux-bundle-[0-9a-f]{24}$ ]] || {
  echo "remote native builder received malformed build identity" >&2
  exit 2
}

exec 3>&1
exec 1>&2
CONTAINER_OWNED=0
OWNER_CONTAINER_OWNED=0
OWNER_CONTAINER_NAME="${CONTAINER_NAME}-owner"

cleanup() {
  local status="$?" cleanup_failed=0
  trap - EXIT HUP INT TERM
  if [[ "$CONTAINER_OWNED" == "1" \
    && -f "$REMOTE_ROOT/app/scripts/lib-host-linux-builder-isolation.sh" ]]
  then
    # shellcheck disable=SC1091
    source "$REMOTE_ROOT/app/scripts/lib-host-linux-builder-isolation.sh"
    if [[ "$OWNER_CONTAINER_OWNED" == "1" ]]; then
      host_linux_builder_stop_container \
        "$OWNER_CONTAINER_NAME" "$BUILD_CACHE_ID" || cleanup_failed=1
    fi
    host_linux_builder_stop_container \
      "$CONTAINER_NAME" "$BUILD_CACHE_ID" || cleanup_failed=1
  fi
  if [[ -d "$REMOTE_ROOT" && ! -L "$REMOTE_ROOT" ]]; then
    find "$REMOTE_ROOT" -xdev -depth -mindepth 1 -delete \
      || cleanup_failed=1
    rmdir "$REMOTE_ROOT" || cleanup_failed=1
  fi
  if [[ "$status" -eq 0 && "$cleanup_failed" -ne 0 ]]; then
    status=1
  fi
  exit "$status"
}
trap cleanup EXIT HUP INT TERM

[[ "$(uname -s)" == "Linux" && "$(uname -m)" == "x86_64" ]] || {
  echo "remote native builder requires Linux x86_64" >&2
  exit 2
}
for command in docker flock git python3 sha256sum tar; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "remote native builder lacks $command" >&2
    exit 2
  }
done
[[ -z "${DOCKER_HOST:-}" && -z "${DOCKER_CONTEXT:-}" ]] || {
  echo "remote native builder refuses an overridden Docker daemon" >&2
  exit 2
}
DOCKER_ENDPOINT="$(
  docker context inspect \
    --format '{{.Endpoints.docker.Host}}' "$(docker context show)"
)"
[[ "$DOCKER_ENDPOINT" == unix://* ]] || {
  echo "remote native builder requires a local Unix Docker daemon" >&2
  exit 2
}
DOCKER_SERVER_PLATFORM="$(
  docker info --format '{{.OSType}}/{{.Architecture}}'
)"
[[ "$DOCKER_SERVER_PLATFORM" == "linux/x86_64" \
  || "$DOCKER_SERVER_PLATFORM" == "linux/amd64" ]] || {
  echo "remote native builder requires a Linux x86_64 Docker daemon" >&2
  exit 2
}
BUILDER_UID="$(id -u)"
BUILDER_GID="$(id -g)"
[[ "$BUILDER_UID" =~ ^[0-9]+$ && "$BUILDER_GID" =~ ^[0-9]+$ ]] || {
  echo "remote native builder could not derive its numeric identity" >&2
  exit 2
}

APP_BUNDLE="$REMOTE_ROOT/app.bundle"
FIPS_BUNDLE="$REMOTE_ROOT/fips.bundle"
for bundle in "$APP_BUNDLE" "$FIPS_BUNDLE"; do
  [[ -f "$bundle" && -O "$bundle" && ! -L "$bundle" ]] || {
    echo "remote native builder source bundle is unsafe" >&2
    exit 2
  }
  chmod 0400 "$bundle"
done
[[ "$(sha256sum "$APP_BUNDLE" | awk '{print $1}')" \
  == "$APP_BUNDLE_SHA256" ]]
[[ "$(sha256sum "$FIPS_BUNDLE" | awk '{print $1}')" \
  == "$FIPS_BUNDLE_SHA256" ]]

git clone --no-hardlinks --quiet "$APP_BUNDLE" "$REMOTE_ROOT/app"
git -C "$REMOTE_ROOT/app" checkout --detach --quiet "$APP_GIT_SHA"
git -C "$REMOTE_ROOT/app" clean -ffd >/dev/null
git clone --no-hardlinks --quiet "$FIPS_BUNDLE" "$REMOTE_ROOT/fips"
git -C "$REMOTE_ROOT/fips" checkout --detach --quiet "$FIPS_GIT_SHA"
git -C "$REMOTE_ROOT/fips" clean -ffd >/dev/null
[[ "$(git -C "$REMOTE_ROOT/app" rev-parse HEAD)" == "$APP_GIT_SHA" \
  && "$(git -C "$REMOTE_ROOT/app" rev-parse 'HEAD^{tree}')" == "$APP_GIT_TREE" \
  && -z "$(git -C "$REMOTE_ROOT/app" status --porcelain --untracked-files=all)" ]]
[[ "$(git -C "$REMOTE_ROOT/fips" rev-parse HEAD)" == "$FIPS_GIT_SHA" \
  && "$(git -C "$REMOTE_ROOT/fips" rev-parse 'HEAD^{tree}')" == "$FIPS_GIT_TREE" \
  && -z "$(git -C "$REMOTE_ROOT/fips" status --porcelain --untracked-files=all)" ]]

DOCKERFILE="$REMOTE_ROOT/app/Dockerfile.linux-vm-gate"
PAYLOAD="$REMOTE_ROOT/app/scripts/build-host-linux-vm-bundle-in-container.sh"
[[ -f "$DOCKERFILE" && ! -L "$DOCKERFILE" \
  && -x "$PAYLOAD" && ! -L "$PAYLOAD" ]]
[[ "$(sha256sum "$DOCKERFILE" | awk '{print $1}')" \
  == "$EXPECTED_DOCKERFILE_SHA256" ]]
[[ "$(sha256sum "$PAYLOAD" | awk '{print $1}')" \
  == "$EXPECTED_PAYLOAD_SHA256" ]]

STATE_ROOT="${XDG_CACHE_HOME:-$HOME/.cache}/nostr-vpn-linux-release-builder"
mkdir -p "$STATE_ROOT/cargo-home"
[[ -d "$STATE_ROOT" && ! -L "$STATE_ROOT" \
  && -d "$STATE_ROOT/cargo-home" && ! -L "$STATE_ROOT/cargo-home" ]]
chmod 0700 "$STATE_ROOT" "$STATE_ROOT/cargo-home"
exec 9>"$STATE_ROOT/builder.lock"
chmod 0600 "$STATE_ROOT/builder.lock"
flock 9

# shellcheck disable=SC1091
source "$REMOTE_ROOT/app/scripts/lib-host-linux-builder-isolation.sh"
host_linux_builder_stop_container "$CONTAINER_NAME" "$BUILD_CACHE_ID"
host_linux_builder_stop_container "$OWNER_CONTAINER_NAME" "$BUILD_CACHE_ID"
host_linux_builder_ensure_target_volume \
  "$TARGET_VOLUME_NAME" "$BUILD_CACHE_ID" "$TARGET_CACHE_GENERATION"
CONTAINER_OWNED=1

mkdir -m 0700 "$REMOTE_ROOT/output"
mkdir -m 0700 "$REMOTE_ROOT/docker-context"
IMAGE_TAG="nostr-vpn-linux-vm-gate:ubuntu24.04-rust${RUST_TOOLCHAIN//./-}-${BUILD_CACHE_ID:0:12}"
docker build \
  --platform linux/amd64 \
  --build-arg "RUST_TOOLCHAIN=$RUST_TOOLCHAIN" \
  --file "$DOCKERFILE" \
  --tag "$IMAGE_TAG" \
  "$REMOTE_ROOT/docker-context"
CONTAINER_IMAGE_ID="$(
  docker image inspect --format '{{.Id}}' "$IMAGE_TAG"
)"
[[ "$CONTAINER_IMAGE_ID" =~ ^sha256:[0-9a-f]{64}$ ]]

# A named Docker volume is root-owned when first created. Give the serialized
# build identity ownership before dropping privileges. The root-owned marker
# makes the recursive migration a one-time operation for this exact cache,
# generation, uid, and gid; subsequent builds only validate it.
OWNER_CONTAINER_OWNED=1
docker run --rm \
  --name "$OWNER_CONTAINER_NAME" \
  --label "to.nostrvpn.release-builder=host-linux-vm-bundle" \
  --label "to.nostrvpn.release-builder-cache=$BUILD_CACHE_ID" \
  --platform linux/amd64 \
  --volume "$TARGET_VOLUME_NAME:/target-root" \
  "$CONTAINER_IMAGE_ID" \
  sh -ceu '
    marker=/target-root/.nvpn-release-builder-owner
    expected="$1:$2:$3:$4"
    if [ -e "$marker" ] || [ -L "$marker" ]; then
      [ -f "$marker" ] && [ ! -L "$marker" ]
      [ "$(cat "$marker")" = "$expected" ]
      [ "$(stat -c "%u:%g:%a" "$marker")" = "0:0:444" ]
      [ "$(stat -c "%u:%g" /target-root)" = "$1:$2" ]
      exit 0
    fi
    chown -R "$1:$2" /target-root
    temporary="$marker.tmp"
    rm -f "$temporary"
    printf "%s\n" "$expected" >"$temporary"
    chown 0:0 "$temporary"
    chmod 0444 "$temporary"
    mv -T "$temporary" "$marker"
  ' sh \
  "$BUILDER_UID" "$BUILDER_GID" \
  "$BUILD_CACHE_ID" "$TARGET_CACHE_GENERATION"
host_linux_builder_stop_container "$OWNER_CONTAINER_NAME" "$BUILD_CACHE_ID"
OWNER_CONTAINER_OWNED=0

docker run --rm \
  --name "$CONTAINER_NAME" \
  --label "to.nostrvpn.release-builder=host-linux-vm-bundle" \
  --label "to.nostrvpn.release-builder-cache=$BUILD_CACHE_ID" \
  --platform linux/amd64 \
  --user "$BUILDER_UID:$BUILDER_GID" \
  --volume "$REMOTE_ROOT/app:/workspace/app" \
  --volume "$REMOTE_ROOT/fips:/workspace/fips:ro" \
  --volume "$REMOTE_ROOT/output:/output" \
  --volume "$STATE_ROOT/cargo-home:/cargo-home" \
  --volume "$TARGET_VOLUME_NAME:/target-root" \
  --env CARGO_HOME=/cargo-home \
  --env HOME=/cargo-home \
  --env CARGO_INCREMENTAL=0 \
  --env "NVPN_BUILD_GIT_SHA=$APP_GIT_SHA" \
  --env "EXPECTED_ROOT_REALIZED_CARGO_LOCK_SHA256=$ROOT_REALIZED_CARGO_LOCK_SHA256" \
  --env "EXPECTED_LINUX_REALIZED_CARGO_LOCK_SHA256=$LINUX_REALIZED_CARGO_LOCK_SHA256" \
  --env "SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH" \
  --env TZ=UTC \
  --env LC_ALL=C.UTF-8 \
  "$CONTAINER_IMAGE_ID" \
  /workspace/app/scripts/build-host-linux-vm-bundle-in-container.sh
host_linux_builder_stop_container "$CONTAINER_NAME" "$BUILD_CACHE_ID"
CONTAINER_OWNED=0

[[ "$(<"$REMOTE_ROOT/output/root-realized-cargo-lock-sha256.txt")" \
  == "$ROOT_REALIZED_CARGO_LOCK_SHA256" ]]
[[ "$(<"$REMOTE_ROOT/output/linux-realized-cargo-lock-sha256.txt")" \
  == "$LINUX_REALIZED_CARGO_LOCK_SHA256" ]]
python3 - \
  "$REMOTE_ROOT/output/builder-provenance.json" \
  "$CONTAINER_IMAGE_ID" \
  "$EXPECTED_DOCKERFILE_SHA256" \
  "$EXPECTED_PAYLOAD_SHA256" <<'PY'
import json
import os
import pathlib
import sys

output, image_id, dockerfile_sha, payload_sha = sys.argv[1:]
path = pathlib.Path(output)
descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
    json.dump(
        {
            "schema": 1,
            "builderMode": "remote-native",
            "builderHostOs": "Linux",
            "builderHostArchitecture": "x86_64",
            "containerImageId": image_id,
            "dockerfileSha256": dockerfile_sha,
            "containerPayloadSha256": payload_sha,
        },
        handle,
        indent=2,
        sort_keys=True,
    )
    handle.write("\n")
    handle.flush()
    os.fsync(handle.fileno())
PY

output_files=(
  builder-provenance.json
  cargo-version.txt
  cli-short-version.txt
  cli-verbose-version.txt
  deb-version.txt
  desktop_manual_join_e2e_fixture
  file.txt
  linux-Cargo.lock.committed
  linux-realized-cargo-lock-sha256.txt
  musl-cli-short-version.txt
  musl-cli-verbose-version.txt
  nostr-vpn
  nostr-vpn.deb
  nvpn
  nvpn-x86_64-unknown-linux-musl
  nvpn-x86_64-unknown-linux-musl.tar.gz
  root-Cargo.lock.committed
  root-realized-cargo-lock-sha256.txt
  rustc-version.txt
)
[[ "$(find "$REMOTE_ROOT/output" -mindepth 1 -maxdepth 1 -print | wc -l)" \
  == "${#output_files[@]}" ]]
for name in "${output_files[@]}"; do
  [[ -f "$REMOTE_ROOT/output/$name" \
    && ! -L "$REMOTE_ROOT/output/$name" ]]
done
tar --format=ustar -cf - -C "$REMOTE_ROOT/output" "${output_files[@]}" >&3
