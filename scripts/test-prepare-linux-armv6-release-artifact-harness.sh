#!/usr/bin/env bash
# Focused fake-tool policy/shape coverage for the sealed ARMv6 artifact lane.
set -euo pipefail

SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/nvpn-armv6-artifact-harness.XXXXXX")"
cleanup() {
  chmod -R u+w "$WORK" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
APP="$WORK/app"
FIPS="$WORK/fips"
TOOLS="$WORK/tools"
STATE="$WORK/state"
CACHE="$WORK/cache"
mkdir -p "$APP/scripts" "$FIPS/crates/fips-core" "$TOOLS" "$STATE" "$CACHE"

cp "$SOURCE_ROOT/scripts/prepare-linux-armv6-release-artifact.sh" "$APP/scripts/"
cp "$SOURCE_ROOT/scripts/linux_armv6_release_artifact.py" "$APP/scripts/"
cp "$SOURCE_ROOT/scripts/release_common.sh" "$APP/scripts/"
cp "$SOURCE_ROOT/scripts/mobile_env.sh" "$APP/scripts/"
cp "$SOURCE_ROOT/scripts/lib-mobile-release-join-artifacts.sh" "$APP/scripts/"

cat >"$APP/Cargo.toml" <<'EOF'
[workspace]
members = []

[workspace.package]
version = "4.1.5"
EOF
cat >"$APP/.gitignore" <<'EOF'
.env.mobile.local
EOF
cat >"$APP/scripts/build-nvpn-armv6-musl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
for override in \
  NVPN_NOSTR_PUBSUB_REPO_PATH \
  NVPN_CASHU_SERVICE_REPO_PATH \
  NVPN_CDK_SPILMAN_REPO_PATH \
  NVPN_CASHU_SPILMAN_REPO_PATH
do
  [[ -z "${!override+x}" ]] || {
    echo "ARMv6 builder inherited unrelated patch override $override" >&2
    exit 1
  }
done
target=arm-unknown-linux-musleabihf
output="$NVPN_ARMV6_TARGET_DIR/$target/release/nvpn"
mkdir -p "$(dirname "$output")"
count=0
[[ ! -f "$FAKE_STATE/build-count" ]] || count="$(cat "$FAKE_STATE/build-count")"
printf '%s\n' "$((count + 1))" >"$FAKE_STATE/build-count"
printf '%s\n' \
  "target=$target" \
  "output=$output" \
  "fips=$NVPN_FIPS_REPO_PATH" \
  "image=$NVPN_ARMV6_MUSL_IMAGE" \
  >"$FAKE_STATE/builder-shape"
python3 - "$output" <<'PY'
import pathlib
import struct
import sys

value = bytearray(52)
value[:7] = b"\x7fELF\x01\x01\x01"
struct.pack_into("<H", value, 16, 2)
struct.pack_into("<H", value, 18, 40)
struct.pack_into("<I", value, 20, 1)
struct.pack_into("<I", value, 36, 0x05000400)
struct.pack_into("<H", value, 40, 52)
path = pathlib.Path(sys.argv[1])
path.write_bytes(value)
path.chmod(0o755)
PY
printf '%s\n' "$output"
EOF
chmod 755 "$APP/scripts/"*

cat >"$FIPS/crates/fips-core/Cargo.toml" <<'EOF'
[package]
name = "fips-core"
version = "0.4.45"
EOF
git -C "$FIPS" init -q
git -C "$FIPS" add .
git -C "$FIPS" -c user.name=test -c user.email=test@example.invalid commit -qm fips
FIPS_SHA="$(git -C "$FIPS" rev-parse HEAD)"

git -C "$APP" init -q
git -C "$APP" add .
git -C "$APP" -c user.name=test -c user.email=test@example.invalid commit -qm app
APP_SHA="$(git -C "$APP" rev-parse HEAD)"
APP_TREE="$(git -C "$APP" rev-parse 'HEAD^{tree}')"

cat >"$TOOLS/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
  *" pull "*) exit 0 ;;
  *" image inspect "*)
    printf '%s\n' "sha256:$(printf 'a%.0s' {1..64})"
    ;;
  *) exit 1 ;;
esac
EOF
cat >"$TOOLS/scp" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
previous=""
source_path=""
for argument in "$@"; do
  source_path="$previous"
  previous="$argument"
done
shasum -a 256 "$source_path" | awk '{print $1}' >"$FAKE_STATE/remote-sha"
printf '%s\n' "scp $*" >>"$FAKE_STATE/transport-log"
EOF
cat >"$TOOLS/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
command="${!#}"
printf '%s\n' "$command" >>"$FAKE_STATE/transport-log"
case "$command" in
  "uname -m")
    printf '%s\n' "${FAKE_REMOTE_ARCH:-armv6l}"
    ;;
  *"sha256sum "*)
    cat "$FAKE_STATE/remote-sha"
    ;;
  *" version --json")
    printf '%s\n' \
      '{"version":"4.1.5","fips_core_version":"0.4.45 (rev '"${FAKE_FIPS_SHA:0:10}"')"}'
    ;;
  *" version --verbose")
    printf '%s\n' \
      "4.1.5" \
      "fips_core_version: 0.4.45 (rev ${FAKE_FIPS_SHA:0:10})"
    ;;
esac
EOF
chmod 755 "$TOOLS/"*

write_env() {
  local path="$1" app_sha="$2" fips_sha="$3" include_host="$4"
  {
    printf 'NVPN_EXPECTED_APP_GIT_SHA=%s\n' "$app_sha"
    printf 'NVPN_EXPECTED_APP_GIT_TREE=%s\n' "$APP_TREE"
    printf 'NVPN_FIPS_REPO_PATH=%s\n' "$FIPS"
    printf 'NVPN_EXPECTED_FIPS_GIT_SHA=%s\n' "$fips_sha"
    printf 'NVPN_EXPECTED_FIPS_VERSION=0.4.45\n'
    printf 'NVPN_LINUX_ARMV6_ARTIFACT_CACHE_DIR=%s\n' "$CACHE"
    if [[ "$include_host" == yes ]]; then
      printf 'NVPN_LINUX_ARMV6_SMOKE_HOST=zero\n'
    else
      printf 'NVPN_LINUX_ARMV6_SMOKE_HOST=\n'
    fi
  } >"$path"
}

ENV_OK="$WORK/release.env"
ENV_NO_HOST="$WORK/no-host.env"
ENV_BAD_FIPS="$WORK/bad-fips.env"
write_env "$ENV_OK" "$APP_SHA" "$FIPS_SHA" yes
write_env "$ENV_NO_HOST" "$APP_SHA" "$FIPS_SHA" no
write_env "$ENV_BAD_FIPS" "$APP_SHA" "$(printf 'b%.0s' {1..40})" yes

run_lane() {
  env \
    PATH="$TOOLS:$PATH" \
    FAKE_STATE="$STATE" \
    FAKE_FIPS_SHA="$FIPS_SHA" \
    NVPN_RELEASE_GATE_LINUX_ARMV6_ARTIFACT=required \
    NVPN_MOBILE_ENV_FILE="$1" \
    "$APP/scripts/prepare-linux-armv6-release-artifact.sh"
}

if run_lane "$ENV_NO_HOST" >"$WORK/out" 2>"$WORK/error"; then
  echo "required ARMv6 evidence accepted a missing smoke host" >&2
  exit 1
fi
grep -q 'requires NVPN_LINUX_ARMV6_SMOKE_HOST' "$WORK/error"
[[ ! -f "$STATE/build-count" ]]

export NVPN_ARMV6_MUSL_IMAGE=example.invalid/private-builder:latest
if run_lane "$ENV_OK" >"$WORK/out" 2>"$WORK/error"; then
  echo "required ARMv6 evidence accepted a non-canonical builder image" >&2
  exit 1
fi
unset NVPN_ARMV6_MUSL_IMAGE
grep -q 'canonical public builder image' "$WORK/error"

touch "$APP/untracked"
if run_lane "$ENV_OK" >"$WORK/out" 2>"$WORK/error"; then
  echo "ARMv6 artifact lane accepted a dirty app checkout" >&2
  exit 1
fi
grep -q 'dirty' "$WORK/error"
rm "$APP/untracked"

if run_lane "$ENV_BAD_FIPS" >"$WORK/out" 2>"$WORK/error"; then
  echo "ARMv6 artifact lane accepted the wrong FIPS revision" >&2
  exit 1
fi
grep -q 'FIPS mismatch' "$WORK/error"

export NVPN_NOSTR_PUBSUB_REPO_PATH="$WORK/unrelated-nostr"
export NVPN_CASHU_SERVICE_REPO_PATH="$WORK/unrelated-cashu"
export NVPN_CDK_SPILMAN_REPO_PATH="$WORK/unrelated-spilman"
export NVPN_CASHU_SPILMAN_REPO_PATH="$WORK/unrelated-spilman-alias"
ARTIFACT_DIR="$(run_lane "$ENV_OK")"
unset NVPN_NOSTR_PUBSUB_REPO_PATH
unset NVPN_CASHU_SERVICE_REPO_PATH
unset NVPN_CDK_SPILMAN_REPO_PATH
unset NVPN_CASHU_SPILMAN_REPO_PATH
[[ "$ARTIFACT_DIR" == "$CACHE/"* && "$ARTIFACT_DIR" == "$(cd "$ARTIFACT_DIR" && pwd)" ]]
[[ "$(cat "$STATE/build-count")" == 1 ]]
grep -q '^target=arm-unknown-linux-musleabihf$' "$STATE/builder-shape"
grep -q "/arm-unknown-linux-musleabihf/release/nvpn$" "$STATE/builder-shape"
grep -q "^fips=$FIPS$" "$STATE/builder-shape"
grep -q "^image=sha256:$(printf 'a%.0s' {1..64})$" "$STATE/builder-shape"
python3 - "$ARTIFACT_DIR/receipt.json" "$APP_SHA" "$APP_TREE" "$FIPS_SHA" <<'PY'
import json
import pathlib
import sys

path, app_sha, app_tree, fips_sha = sys.argv[1:]
value = json.loads(pathlib.Path(path).read_text())
assert value["schema"] == 1
assert value["artifactType"] == "sealed Linux ARMv6 static-musl CLI"
assert value["appGitSha"] == app_sha
assert value["appGitTree"] == app_tree
assert value["appVersion"] == "4.1.5"
assert value["fipsGitSha"] == fips_sha
assert value["fipsVersion"] == "0.4.45"
assert value["target"] == "arm-unknown-linux-musleabihf"
assert value["fleetArch"] == "armv6"
assert value["archive"]["file"] == "nvpn-arm-unknown-linux-musleabihf.tar.gz"
assert value["archive"]["members"] == [
    "nvpn/README.txt", "nvpn/install.sh", "nvpn/nvpn"
]
assert value["binary"]["member"] == "nvpn/nvpn"
assert value["smoke"]["realChecks"] is True
assert value["smoke"]["mocked"] is False
assert value["smoke"]["installPerformed"] is False
assert value["smoke"]["networkMutated"] is False
assert value["smoke"]["hostArchitecture"] == "armv6l"
assert value["smoke"]["cleaned"] is True
PY
tar -tzf "$ARTIFACT_DIR/nvpn-arm-unknown-linux-musleabihf.tar.gz" \
  >"$WORK/members"
diff -u - "$WORK/members" <<'EOF'
nvpn/README.txt
nvpn/install.sh
nvpn/nvpn
EOF
grep -q "rm -rf -- '/tmp/nvpn-armv6-smoke-" "$STATE/transport-log"
EPOCH="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sourceDateEpoch"])' \
  "$ARTIFACT_DIR/receipt.json")"
python3 "$APP/scripts/linux_armv6_release_artifact.py" extract \
  --archive "$ARTIFACT_DIR/nvpn-arm-unknown-linux-musleabihf.tar.gz" \
  --output "$WORK/extracted-nvpn" \
  --epoch "$EPOCH"
python3 "$APP/scripts/linux_armv6_release_artifact.py" package \
  --binary "$WORK/extracted-nvpn" \
  --archive "$WORK/rebuilt.tar.gz" \
  --epoch "$EPOCH"
cmp "$ARTIFACT_DIR/nvpn-arm-unknown-linux-musleabihf.tar.gz" "$WORK/rebuilt.tar.gz"
for bad_flags in 0x04000400 0x05000000; do
  cp "$WORK/extracted-nvpn" "$WORK/bad-elf"
  chmod u+w "$WORK/bad-elf"
  python3 - "$WORK/bad-elf" "$bad_flags" <<'PY'
import pathlib
import struct
import sys

path = pathlib.Path(sys.argv[1])
value = bytearray(path.read_bytes())
struct.pack_into("<I", value, 36, int(sys.argv[2], 16))
path.write_bytes(value)
PY
  if python3 "$APP/scripts/linux_armv6_release_artifact.py" package \
    --binary "$WORK/bad-elf" \
    --archive "$WORK/bad-elf.tar.gz" \
    --epoch "$EPOCH" >"$WORK/out" 2>"$WORK/error"
  then
    echo "ARMv6 artifact verifier accepted invalid ELF flags $bad_flags" >&2
    exit 1
  fi
done

RECEIPT_SHA="$(shasum -a 256 "$ARTIFACT_DIR/receipt.json" | awk '{print $1}')"
[[ "$(run_lane "$ENV_OK")" == "$ARTIFACT_DIR" ]]
[[ "$(cat "$STATE/build-count")" == 1 ]]
[[ "$(shasum -a 256 "$ARTIFACT_DIR/receipt.json" | awk '{print $1}')" == "$RECEIPT_SHA" ]]
export FAKE_REMOTE_ARCH=x86_64
if run_lane "$ENV_OK" >"$WORK/out" 2>"$WORK/error"; then
  echo "ARMv6 artifact lane accepted a non-ARMv6 execution host" >&2
  exit 1
fi
unset FAKE_REMOTE_ARCH
grep -q 'not armv6l' "$WORK/error"
[[ "$(cat "$STATE/build-count")" == 1 ]]

chmod 0755 "$ARTIFACT_DIR"
chmod 0644 "$ARTIFACT_DIR/nvpn-arm-unknown-linux-musleabihf.tar.gz"
printf 'tamper' >>"$ARTIFACT_DIR/nvpn-arm-unknown-linux-musleabihf.tar.gz"
chmod 0444 "$ARTIFACT_DIR/nvpn-arm-unknown-linux-musleabihf.tar.gz"
chmod 0555 "$ARTIFACT_DIR"
if run_lane "$ENV_OK" >"$WORK/out" 2>"$WORK/error"; then
  echo "ARMv6 artifact lane accepted a tampered immutable cache entry" >&2
  exit 1
fi
grep -Eq 'archive|gzip|tar' "$WORK/error"
[[ "$(cat "$STATE/build-count")" == 1 ]]

/bin/bash -n "$SOURCE_ROOT/scripts/prepare-linux-armv6-release-artifact.sh"
python3 -m py_compile "$SOURCE_ROOT/scripts/linux_armv6_release_artifact.py"
printf '%s\n' "sealed Linux ARMv6 artifact harness passed"
