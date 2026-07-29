#!/usr/bin/env bash
# Build, execute, and immutably cache the exact ARMv6 static-musl release CLI.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck disable=SC1091
source "$ROOT/scripts/release_common.sh"
# shellcheck disable=SC1091
source "$ROOT/scripts/mobile_env.sh"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib-mobile-release-join-artifacts.sh"

load_release_env "$ROOT"
load_mobile_env "$ROOT"

TARGET="arm-unknown-linux-musleabihf"
ARCHIVE_NAME="nvpn-$TARGET.tar.gz"
HELPER="$ROOT/scripts/linux_armv6_release_artifact.py"
BUILDER="$ROOT/scripts/build-nvpn-armv6-musl"
DEFAULT_BUILDER_IMAGE="messense/rust-musl-cross:arm-musleabihf"
BUILDER_IMAGE="$(
  printf '%s' \
    "${NVPN_ARMV6_MUSL_IMAGE:-${NVPN_LINUX_MUSL_IMAGE:-$DEFAULT_BUILDER_IMAGE}}"
)"
REQUIRE_SMOKE=0
case "${NVPN_RELEASE_GATE_LINUX_ARMV6_ARTIFACT:-0}" in
  required) REQUIRE_SMOKE=1 ;;
  *)
    if bool_is_true "${NVPN_RELEASE_GATE_LINUX_ARMV6_ARTIFACT:-0}"; then
      REQUIRE_SMOKE=1
    fi
    ;;
esac
[[ "$(uname -s)" == "Darwin" ]] || {
  echo "Sealed Linux ARMv6 release artifacts must be orchestrated by the controlling Mac" >&2
  exit 2
}
if [[ "$REQUIRE_SMOKE" -eq 1 && "$BUILDER_IMAGE" != "$DEFAULT_BUILDER_IMAGE" ]]; then
  echo "Required Linux ARMv6 releases use only the canonical public builder image" >&2
  exit 2
fi
SMOKE_HOST="${NVPN_LINUX_ARMV6_SMOKE_HOST:-}"
if [[ "$REQUIRE_SMOKE" -eq 1 && -z "$SMOKE_HOST" ]]; then
  echo "Sealed Linux ARMv6 release evidence requires NVPN_LINUX_ARMV6_SMOKE_HOST" >&2
  exit 2
fi
if [[ -n "$SMOKE_HOST" \
  && ( "$SMOKE_HOST" == -* || ! "$SMOKE_HOST" =~ ^[A-Za-z0-9_.@-]+$ ) ]]
then
  echo "NVPN_LINUX_ARMV6_SMOKE_HOST is not a safe SSH host alias" >&2
  exit 2
fi
[[ -x "$BUILDER" && -f "$HELPER" && ! -L "$BUILDER" && ! -L "$HELPER" ]] || {
  echo "Sealed Linux ARMv6 release builder/verifier is missing" >&2
  exit 2
}
command -v docker >/dev/null 2>&1 || {
  echo "Sealed Linux ARMv6 release building requires Docker" >&2
  exit 2
}

APP_GIT_SHA="$(git -C "$ROOT" rev-parse HEAD)"
APP_GIT_TREE="$(git -C "$ROOT" rev-parse 'HEAD^{tree}')"
[[ "${NVPN_EXPECTED_APP_GIT_SHA:-}" =~ ^[0-9a-f]{40}$ \
  && "$APP_GIT_SHA" == "$NVPN_EXPECTED_APP_GIT_SHA" ]] || {
  echo "Linux ARMv6 artifact app commit differs from the exact release candidate" >&2
  exit 2
}
[[ "${NVPN_EXPECTED_APP_GIT_TREE:-}" =~ ^[0-9a-f]{40}$ \
  && "$APP_GIT_TREE" == "$NVPN_EXPECTED_APP_GIT_TREE" ]] || {
  echo "Linux ARMv6 artifact app tree differs from the exact release candidate" >&2
  exit 2
}
assert_release_checkout_state \
  "$ROOT" "$APP_GIT_SHA" "$APP_GIT_TREE" \
  "Linux ARMv6 Release artifact" || exit 2
[[ -z "$(git -C "$ROOT" status --porcelain --untracked-files=all)" ]] || {
  echo "Linux ARMv6 artifact refuses a dirty app checkout" >&2
  exit 2
}

package_version_from_manifest() {
  local manifest="$1" section="$2"
  awk -v wanted="$section" '
    $0 == wanted { package = 1; next }
    package && /^\[/ { exit }
    package && /^version = "/ {
      value = $0
      sub(/^version = "/, "", value)
      sub(/".*$/, "", value)
      print value
      exit
    }
  ' "$manifest"
}

APP_VERSION="$(package_version_from_manifest "$ROOT/Cargo.toml" "[workspace.package]")"
[[ "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]] || {
  echo "Linux ARMv6 artifact could not derive the app version" >&2
  exit 2
}
if [[ -n "${NVPN_APP_VERSION_NAME:-}" && "$NVPN_APP_VERSION_NAME" != "$APP_VERSION" ]]; then
  echo "Linux ARMv6 artifact app version differs from the release environment" >&2
  exit 2
fi

release_join_require_clean_fips
release_join_assert_fips_unchanged
if [[ -n "${NVPN_EXPECTED_FIPS_VERSION:-}" \
  && "$RELEASE_JOIN_FIPS_VERSION" != "$NVPN_EXPECTED_FIPS_VERSION" ]]
then
  echo "Linux ARMv6 artifact FIPS version differs from the release environment" >&2
  exit 2
fi
SOURCE_DATE_EPOCH="$(git -C "$ROOT" log -1 --format=%ct "$APP_GIT_SHA")"
[[ "$SOURCE_DATE_EPOCH" =~ ^[0-9]+$ ]] || {
  echo "Linux ARMv6 artifact could not derive SOURCE_DATE_EPOCH" >&2
  exit 2
}
export SOURCE_DATE_EPOCH
pin_exact_release_build_git_sha \
  "$ROOT" "$APP_GIT_SHA" "Linux ARMv6 Release artifact"

CACHE_ROOT="$(
  printf '%s' \
    "${NVPN_LINUX_ARMV6_ARTIFACT_CACHE_DIR:-${ARTIFACT_ROOT:-$ROOT/artifacts}/linux-armv6-release}"
)"
mkdir -p "$CACHE_ROOT"
CACHE_ROOT="$(cd "$CACHE_ROOT" && pwd)"
TEMP_DIR=""
REMOTE_DIR=""
REMOTE_CLEANUP_HOST=""
BUILD_LOCK=""
DOCKER_CONFIG_DIR=""
BUILDER_IMAGE_ID=""

cleanup() {
  local status="$?"
  trap - EXIT
  if [[ -n "$REMOTE_DIR" && -n "$REMOTE_CLEANUP_HOST" ]]; then
    ssh -o BatchMode=yes -o ConnectTimeout=15 \
      -o ServerAliveInterval=10 -o ServerAliveCountMax=3 \
      "$REMOTE_CLEANUP_HOST" \
      "rm -rf -- '$REMOTE_DIR'" >/dev/null 2>&1 || true
  fi
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
    chmod -R u+w "$TEMP_DIR" >/dev/null 2>&1 || true
    rm -rf "$TEMP_DIR"
  fi
  if [[ -n "$DOCKER_CONFIG_DIR" && -d "$DOCKER_CONFIG_DIR" ]]; then
    rm -rf "$DOCKER_CONFIG_DIR"
  fi
  exit "$status"
}
trap cleanup EXIT

resolve_builder_image_id() {
  local exact_image_id
  if [[ "$BUILDER_IMAGE" == "$DEFAULT_BUILDER_IMAGE" ]]; then
    DOCKER_CONFIG_DIR="$(mktemp -d "$CACHE_ROOT/.docker-public.XXXXXX")"
    docker --config "$DOCKER_CONFIG_DIR" pull "$BUILDER_IMAGE" >&2
    exact_image_id="$(
      docker --config "$DOCKER_CONFIG_DIR" image inspect \
        --format '{{.Id}}' "$BUILDER_IMAGE" | sed -n '1p'
    )"
    rm -rf "$DOCKER_CONFIG_DIR"
    DOCKER_CONFIG_DIR=""
  else
    exact_image_id="$(
      docker image inspect --format '{{.Id}}' "$BUILDER_IMAGE" 2>/dev/null \
        | sed -n '1p'
    )"
    if [[ -z "$exact_image_id" ]]; then
      docker pull "$BUILDER_IMAGE" >&2
      exact_image_id="$(
        docker image inspect --format '{{.Id}}' "$BUILDER_IMAGE" \
          | sed -n '1p'
      )"
    fi
  fi
  [[ "$exact_image_id" =~ ^sha256:[0-9a-f]{64}$ ]] || {
    echo "Docker returned an invalid ARMv6 builder image ID" >&2
    return 2
  }
  BUILDER_IMAGE_ID="$exact_image_id"
}

cache_dir_for_image() {
  local exact_image_id="$1" smoke_policy="$2" key
  key="$(
    printf '%s\n' \
      "sealed-linux-armv6-v1" \
      "$APP_GIT_SHA" "$APP_GIT_TREE" "$APP_VERSION" \
      "$RELEASE_JOIN_FIPS_SHA" "$RELEASE_JOIN_FIPS_TREE" \
      "$RELEASE_JOIN_FIPS_VERSION" "$TARGET" "$BUILDER_IMAGE" \
      "$exact_image_id" "$SOURCE_DATE_EPOCH" "$smoke_policy" \
      | shasum -a 256 | awk '{ print $1 }'
  )"
  printf '%s/%s-%s\n' \
    "$CACHE_ROOT" "${APP_GIT_SHA:0:12}" "${key:0:40}"
}

verify_dir() {
  local directory="$1" exact_image_id="$2"
  local smoke_args=()
  if [[ -n "$SMOKE_HOST" ]]; then
    smoke_args+=(--require-smoke)
  fi
  python3 "$HELPER" verify \
    --directory "$directory" \
    --app-sha "$APP_GIT_SHA" \
    --app-tree "$APP_GIT_TREE" \
    --app-version "$APP_VERSION" \
    --fips-sha "$RELEASE_JOIN_FIPS_SHA" \
    --fips-tree "$RELEASE_JOIN_FIPS_TREE" \
    --fips-version "$RELEASE_JOIN_FIPS_VERSION" \
    --builder-image "$BUILDER_IMAGE" \
    --builder-image-id "$exact_image_id" \
    --epoch "$SOURCE_DATE_EPOCH" \
    "${smoke_args[@]}"
}

run_remote_smoke() {
  local binary="$1" output="$2"
  local binary_sha remote_sha host_arch version_json verbose_version
  local remote_root="${NVPN_LINUX_ARMV6_SMOKE_REMOTE_ROOT:-/tmp}"
  [[ -n "$SMOKE_HOST" ]] || return 0
  [[ "$remote_root" =~ ^/[A-Za-z0-9_./-]*$ \
    && "$remote_root" != "/" \
    && "$remote_root" != *"/../"* \
    && "$remote_root" != *"/.." ]] || {
    echo "NVPN_LINUX_ARMV6_SMOKE_REMOTE_ROOT is not a safe absolute path" >&2
    return 2
  }
  binary_sha="$(release_file_sha256 "$binary")"
  REMOTE_DIR="${remote_root%/}/nvpn-armv6-smoke-${APP_GIT_SHA:0:12}-$$"
  REMOTE_CLEANUP_HOST="$SMOKE_HOST"
  ssh -o BatchMode=yes -o ConnectTimeout=15 \
    -o ServerAliveInterval=10 -o ServerAliveCountMax=3 \
    "$SMOKE_HOST" \
    "umask 077; mkdir '$REMOTE_DIR'"
  scp -q -o BatchMode=yes -o ConnectTimeout=15 \
    "$binary" "$SMOKE_HOST:$REMOTE_DIR/nvpn"
  ssh -o BatchMode=yes -o ConnectTimeout=15 \
    -o ServerAliveInterval=10 -o ServerAliveCountMax=3 \
    "$SMOKE_HOST" "chmod 0555 '$REMOTE_DIR/nvpn'"
  host_arch="$(
    ssh -o BatchMode=yes -o ConnectTimeout=15 \
      -o ServerAliveInterval=10 -o ServerAliveCountMax=3 \
      "$SMOKE_HOST" "uname -m" | tr -d '\r\n'
  )"
  [[ "$host_arch" == "armv6l" ]] || {
    echo "Linux ARMv6 smoke host architecture is $host_arch, not armv6l" >&2
    return 1
  }
  remote_sha="$(
    ssh -o BatchMode=yes -o ConnectTimeout=15 \
      -o ServerAliveInterval=10 -o ServerAliveCountMax=3 \
      "$SMOKE_HOST" \
      "sha256sum '$REMOTE_DIR/nvpn' | awk '{print \$1}'" \
      | tr -d '\r\n'
  )"
  [[ "$remote_sha" == "$binary_sha" ]] || {
    echo "Linux ARMv6 remote binary SHA-256 differs from the sealed binary" >&2
    return 1
  }
  version_json="$TEMP_DIR/armv6-version.json"
  verbose_version="$TEMP_DIR/armv6-version-verbose.txt"
  ssh -o BatchMode=yes -o ConnectTimeout=15 \
    -o ServerAliveInterval=10 -o ServerAliveCountMax=3 \
    "$SMOKE_HOST" "'$REMOTE_DIR/nvpn' version --json" >"$version_json"
  ssh -o BatchMode=yes -o ConnectTimeout=15 \
    -o ServerAliveInterval=10 -o ServerAliveCountMax=3 \
    "$SMOKE_HOST" "'$REMOTE_DIR/nvpn' version --verbose" >"$verbose_version"
  ssh -o BatchMode=yes -o ConnectTimeout=15 \
    -o ServerAliveInterval=10 -o ServerAliveCountMax=3 \
    "$SMOKE_HOST" \
    "rm -rf -- '$REMOTE_DIR'; test ! -e '$REMOTE_DIR'"
  REMOTE_DIR=""
  REMOTE_CLEANUP_HOST=""
  python3 "$HELPER" write-smoke \
    --version-json "$version_json" \
    --verbose-version "$verbose_version" \
    --output "$output" \
    --host-architecture "$host_arch" \
    --remote-sha "$remote_sha" \
    --binary-sha "$binary_sha" \
    --app-version "$APP_VERSION" \
    --fips-version "$RELEASE_JOIN_FIPS_VERSION" \
    --fips-sha "$RELEASE_JOIN_FIPS_SHA"
}

SMOKE_POLICY="no-smoke-v1"
if [[ -n "$SMOKE_HOST" ]]; then
  SMOKE_POLICY="real-armv6-smoke-v1"
fi
resolve_builder_image_id
ARTIFACT_DIR="$(cache_dir_for_image "$BUILDER_IMAGE_ID" "$SMOKE_POLICY")"
if [[ -e "$ARTIFACT_DIR" ]]; then
  verify_dir "$ARTIFACT_DIR" "$BUILDER_IMAGE_ID"
  if [[ -n "$SMOKE_HOST" ]]; then
    TEMP_DIR="$(mktemp -d "$CACHE_ROOT/.armv6-cache-smoke.XXXXXX")"
    python3 "$HELPER" extract \
      --archive "$ARTIFACT_DIR/$ARCHIVE_NAME" \
      --output "$TEMP_DIR/nvpn" \
      --epoch "$SOURCE_DATE_EPOCH"
    run_remote_smoke "$TEMP_DIR/nvpn" "$TEMP_DIR/smoke.json"
    python3 "$HELPER" verify \
      --directory "$ARTIFACT_DIR" \
      --app-sha "$APP_GIT_SHA" \
      --app-tree "$APP_GIT_TREE" \
      --app-version "$APP_VERSION" \
      --fips-sha "$RELEASE_JOIN_FIPS_SHA" \
      --fips-tree "$RELEASE_JOIN_FIPS_TREE" \
      --fips-version "$RELEASE_JOIN_FIPS_VERSION" \
      --builder-image "$BUILDER_IMAGE" \
      --builder-image-id "$BUILDER_IMAGE_ID" \
      --epoch "$SOURCE_DATE_EPOCH" \
      --require-smoke \
      --smoke-copy "$TEMP_DIR/smoke.json"
    rm -rf "$TEMP_DIR"
    TEMP_DIR=""
  fi
  release_join_assert_app_unchanged "$APP_GIT_SHA" "$APP_GIT_TREE"
  release_join_assert_fips_unchanged
  printf '%s\n' "$ARTIFACT_DIR"
  exit 0
fi

BUILD_LOCK="$CACHE_ROOT/.armv6-release-build.lock"
[[ -x /usr/bin/lockf ]] || {
  echo "Sealed Linux ARMv6 release building requires macOS lockf" >&2
  exit 2
}
exec 8>"$BUILD_LOCK"
chmod 0600 "$BUILD_LOCK"
/usr/bin/lockf 8
TEMP_DIR="$(mktemp -d "$CACHE_ROOT/.armv6-release.XXXXXX")"
mkdir -p "$TEMP_DIR/work" "$TEMP_DIR/target" "$TEMP_DIR/final"
BUILD_OUTPUT="$TEMP_DIR/build-output.txt"
BUILD_LOG="$TEMP_DIR/build.log"
if ! env \
  -u NVPN_NOSTR_PUBSUB_REPO_PATH \
  -u NVPN_CASHU_SERVICE_REPO_PATH \
  -u NVPN_CDK_SPILMAN_REPO_PATH \
  -u NVPN_CASHU_SPILMAN_REPO_PATH \
  NVPN_FIPS_REPO_PATH="$NVPN_FIPS_REPO_PATH" \
  NVPN_EXPECTED_FIPS_GIT_SHA="$RELEASE_JOIN_FIPS_SHA" \
  NVPN_BUILD_GIT_SHA="$APP_GIT_SHA" \
  NVPN_ARMV6_MUSL_IMAGE="$BUILDER_IMAGE_ID" \
  NVPN_ARMV6_BUILD_ROOT="$TEMP_DIR/work" \
  NVPN_ARMV6_TARGET_DIR="$TEMP_DIR/target" \
  NVPN_ARMV6_KEEP_WORK=0 \
  "$BUILDER" >"$BUILD_OUTPUT" 2>"$BUILD_LOG"
then
  tail -n 120 "$BUILD_LOG" >&2 || true
  exit 1
fi
BUILT_BINARY="$(tail -n 1 "$BUILD_OUTPUT")"
EXPECTED_BINARY="$TEMP_DIR/target/$TARGET/release/nvpn"
[[ "$BUILT_BINARY" == "$EXPECTED_BINARY" \
  && -x "$BUILT_BINARY" && -f "$BUILT_BINARY" && ! -L "$BUILT_BINARY" ]] || {
  echo "ARMv6 builder returned an unexpected output path" >&2
  exit 1
}
ARTIFACT_DIR="$(cache_dir_for_image "$BUILDER_IMAGE_ID" "$SMOKE_POLICY")"
if [[ -e "$ARTIFACT_DIR" ]]; then
  echo "Immutable ARMv6 cache destination appeared during the build" >&2
  exit 1
fi

python3 "$HELPER" package \
  --binary "$BUILT_BINARY" \
  --archive "$TEMP_DIR/final/$ARCHIVE_NAME" \
  --epoch "$SOURCE_DATE_EPOCH"
SMOKE_ARGS=()
if [[ -n "$SMOKE_HOST" ]]; then
  run_remote_smoke "$BUILT_BINARY" "$TEMP_DIR/smoke.json"
  SMOKE_ARGS=(--smoke "$TEMP_DIR/smoke.json")
fi
python3 "$HELPER" write-receipt \
  --archive "$TEMP_DIR/final/$ARCHIVE_NAME" \
  --receipt "$TEMP_DIR/final/receipt.json" \
  --app-sha "$APP_GIT_SHA" \
  --app-tree "$APP_GIT_TREE" \
  --app-version "$APP_VERSION" \
  --fips-sha "$RELEASE_JOIN_FIPS_SHA" \
  --fips-tree "$RELEASE_JOIN_FIPS_TREE" \
  --fips-version "$RELEASE_JOIN_FIPS_VERSION" \
  --builder-image "$BUILDER_IMAGE" \
  --builder-image-id "$BUILDER_IMAGE_ID" \
  --epoch "$SOURCE_DATE_EPOCH" \
  "${SMOKE_ARGS[@]}"
chmod 0444 "$TEMP_DIR/final/$ARCHIVE_NAME" "$TEMP_DIR/final/receipt.json"
verify_dir "$TEMP_DIR/final" "$BUILDER_IMAGE_ID"
release_join_assert_app_unchanged "$APP_GIT_SHA" "$APP_GIT_TREE"
release_join_assert_fips_unchanged

mv "$TEMP_DIR/final" "$ARTIFACT_DIR"
chmod 0555 "$ARTIFACT_DIR"
rm -rf "$TEMP_DIR"
TEMP_DIR=""
printf '%s\n' "$ARTIFACT_DIR"
