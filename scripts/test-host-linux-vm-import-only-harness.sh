#!/usr/bin/env bash
# Source and receipt contract for host-built/import-only native Linux VM gates.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREPARER="$ROOT/scripts/prepare-host-linux-vm-bundle.sh"
VERIFIER="$ROOT/scripts/verify-host-linux-vm-bundle.py"
PATCH_LOCK_VERIFIER="$ROOT/scripts/verify-cargo-path-patch-lock.py"
IMPORT_LIB="$ROOT/scripts/lib-ubuntu-vm-imported-release.sh"
MANUAL="$ROOT/scripts/ubuntu-vm-manual-join-e2e.sh"
SERVICE="$ROOT/scripts/ubuntu-vm-service-toggle-e2e.sh"
UNDERLAY="$ROOT/scripts/linux-vm-desktop-underlay-change-e2e.sh"
MANUAL_GUEST="$ROOT/linux/scripts/e2e-manual-join-ui.sh"
RELEASE_GATE="$ROOT/scripts/release-gate.sh"
DOCKERFILE="$ROOT/Dockerfile.linux-vm-gate"
CLEANUP="$ROOT/scripts/ubuntu-vm-exact-deb-cleanup.sh"
CLEANUP_HARNESS="$ROOT/scripts/test-ubuntu-vm-exact-deb-cleanup-harness.sh"
ISOLATION_LIB="$ROOT/scripts/lib-host-linux-builder-isolation.sh"
ISOLATION_HARNESS="$ROOT/scripts/test-host-linux-builder-isolation-harness.sh"

fail() {
  echo "host Linux VM import-only contract failed: $*" >&2
  exit 1
}

require_tokens() {
  local file="$1" label="$2" token
  shift 2
  for token in "$@"; do
    grep -Fq -- "$token" "$file" \
      || fail "$(basename "$file") lacks $label: $token"
  done
}

for executable in \
  "$PREPARER" \
  "$VERIFIER" \
  "$PATCH_LOCK_VERIFIER" \
  "$MANUAL" \
  "$SERVICE" \
  "$UNDERLAY" \
  "$CLEANUP" \
  "$CLEANUP_HARNESS" \
  "$ISOLATION_HARNESS"
do
  [[ -x "$executable" ]] || fail "$(basename "$executable") is not executable"
done
[[ -f "$IMPORT_LIB" && -f "$DOCKERFILE" && -f "$ISOLATION_LIB" ]] \
  || fail "shared import/build-isolation helper or Ubuntu builder image is missing"
require_tokens "$PATCH_LOCK_VERIFIER" "fail-closed FIPS patch lock delta" \
  'REGISTRY_SOURCE' \
  'committed lock has duplicate target package' \
  'realized lock differs by more than exact target ' \
  '"--manifest-specs"' \
  '"--expected-sha256"' \
  '"--validate"'

require_tokens "$DOCKERFILE" "pinned Ubuntu host build environment" \
  'FROM ubuntu:24.04' \
  'ARG RUST_TOOLCHAIN=1.95.0' \
  'libadwaita-1-dev' \
  'libgtk-4-dev' \
  'musl-tools' \
  'cargo install cargo-deb --version 3.7.0 --locked'
require_tokens "$PREPARER" "clean exact cached Mac bundle" \
  '[[ "$(uname -s)" == "Darwin" ]]' \
  'status --porcelain --untracked-files=all' \
  'release_join_require_clean_fips' \
  'CACHE_KEY="$APP_GIT_SHA-$RELEASE_JOIN_FIPS_SHA-$TARGET-ubuntu24.04-rust$RUST_TOOLCHAIN-cargo-deb$CARGO_DEB_VERSION-package3"' \
  'HOST_BUILD_LOCK="$CACHE_ROOT/.host-linux-vm-bundle.lock"' \
  'HOST_BUILD_LOCK_HELD=0' \
  'exec 9>"$HOST_BUILD_LOCK"' \
  '/usr/bin/lockf 9' \
  'HOST_BUILD_LOCK_HELD=1' \
  'if [[ "$HOST_BUILD_LOCK_HELD" == "1" ]]; then' \
  'if verify_bundle; then' \
  'Dockerfile.linux-vm-gate' \
  'verify-cargo-path-patch-lock.py' \
  '--manifest-specs "$NVPN_FIPS_REPO_PATH"' \
  '--validate /output/root-Cargo.lock.committed Cargo.lock' \
  '--validate /output/linux-Cargo.lock.committed Cargo.lock' \
  'TARGET_CACHE_GENERATION="serialized-v2-rust${RUST_TOOLCHAIN//./-}"' \
  '"$TARGET_CACHE_ROOT/root-target:/target-root"' \
  '--name "$CONTAINER_NAME"' \
  '--label "to.nostrvpn.release-builder-cache=$BUILD_CACHE_ID"' \
  'host_linux_builder_stop_container "$CONTAINER_NAME" "$BUILD_CACHE_ID"' \
  'host_linux_builder_stop_container \' \
  '  --interactive \' \
  '  --platform "$DOCKER_PLATFORM" \' \
  'dockerPlatform": "linux/amd64"' \
  'containerBase": "ubuntu:24.04"' \
  '"builtOnHostMac": True' \
  '"builtOnRemoteVm": False' \
  '"rootCargoLockSha256": root_cargo_lock_sha256' \
  '"rootRealizedCargoLockSha256": root_realized_cargo_lock_sha256' \
  '"linuxCargoLockSha256": linux_cargo_lock_sha256' \
  '"linuxRealizedCargoLockSha256": linux_realized_cargo_lock_sha256' \
  '"fipsPatchedLockPackages": fips_patch_packages' \
  'metadata --format-version 1 >/dev/null' \
  'metadata --locked --format-version 1 --no-deps' \
  '/target-root/release/nvpn' \
  '/target-root/x86_64-unknown-linux-musl/release/nvpn' \
  '/target-root/release/examples/desktop_manual_join_e2e_fixture' \
  '/target-root/release/nostr-vpn' \
  'cargo deb --no-build --no-strip' \
  '/output/nostr-vpn.deb' \
  '/output/nvpn-x86_64-unknown-linux-musl.tar.gz' \
  'verify-host-linux-vm-bundle.py'
if grep -Fq '"$CACHE_ROOT/build-cache/root-target:/target-root"' "$PREPARER" \
  || grep -Fq '"$CACHE_ROOT/build-cache/linux-target:/target-linux"' "$PREPARER"
then
  fail "host Linux builder still uses the unversioned, unserialized Cargo targets"
fi
if grep -Fq '/target-linux' "$PREPARER"; then
  fail "host Linux builder still recompiles GTK dependencies in a second target"
fi
if grep -Fq 'CONTAINER_CID_FILE' "$PREPARER"; then
  fail "host Linux builder has two competing identities for its deterministic container"
fi
python3 - "$PREPARER" <<'PY'
import pathlib
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
initial_verify = text.index("if verify_bundle; then")
lock_unowned = text.index("HOST_BUILD_LOCK_HELD=0")
lock_open = text.index('exec 9>"$HOST_BUILD_LOCK"')
lock_acquire = text.index("/usr/bin/lockf 9")
lock_owned = text.index("HOST_BUILD_LOCK_HELD=1")
second_verify = text.index("if verify_bundle; then", initial_verify + 1)
temp_create = text.index('TEMP_DIR="$(mktemp -d')
if not (
    lock_unowned
    < initial_verify
    < lock_open
    < lock_acquire
    < lock_owned
    < second_verify
    < temp_create
):
    raise SystemExit(
        "host Linux builder does not re-verify the bundle under its kernel lock"
    )
if text.count('if [[ "$HOST_BUILD_LOCK_HELD" == "1" ]]; then') < 2:
    raise SystemExit(
        "pre-lock cleanup can remove the authoritative builder container"
    )
container_create = text.index('--name "$CONTAINER_NAME"')
container_cleanup = text.index("host_linux_builder_stop_container", second_verify)
if not container_cleanup < container_create:
    raise SystemExit(
        "host Linux builder does not install server-side container cleanup before run"
    )
stale_cleanup = text.index(
    'host_linux_builder_stop_container "$CONTAINER_NAME" "$BUILD_CACHE_ID"',
    second_verify,
)
target_mount = text.index('"$TARGET_CACHE_ROOT/root-target:/target-root"')
if not stale_cleanup < target_mount:
    raise SystemExit(
        "host Linux builder can mount its persistent target cache before stale "
        "server-side builders are removed"
    )
if text.count("export CARGO_TARGET_DIR=/target-root") != 2:
    raise SystemExit(
        "root and GTK builds do not share the one serialized native target"
    )
PY
require_tokens "$ISOLATION_LIB" "validated exact-container cleanup" \
  'to.nostrvpn.release-builder' \
  'to.nostrvpn.release-builder-cache' \
  'Refusing to remove mismatched Linux builder container' \
  'docker rm --force "$container_id"' \
  'docker container inspect'
"$ISOLATION_HARNESS"
require_tokens "$VERIFIER" "hash/size/version/source receipt validation" \
  '"builtOnHostMac": True' \
  '"builtOnRemoteVm": False' \
  '"dockerPlatform": "linux/amd64"' \
  '"containerBase": "ubuntu:24.04"' \
  '"rootCargoLockSha256": root_cargo_lock_sha256' \
  '"rootRealizedCargoLockSha256": root_realized_cargo_lock_sha256' \
  '"linuxCargoLockSha256": linux_cargo_lock_sha256' \
  '"linuxRealizedCargoLockSha256": linux_realized_cargo_lock_sha256' \
  '"fipsPatchedLockPackages": fips_patch_packages' \
  'little-endian x86_64 ELF64 executable' \
  'SHA-256 differs from receipt' \
  'size differs from receipt' \
  'CLI verbose version differs from exact FIPS revision'
require_tokens "$IMPORT_LIB" "unique verified VM import lifecycle" \
  'prepare-host-linux-vm-bundle.sh' \
  '--manifest-specs "$NVPN_FIPS_REPO_PATH"' \
  'mktemp -d /tmp/nvpn-linux-vm-release.XXXXXX' \
  'sha256sum "$package_root/usr/bin/nostr-vpn"' \
  'sha256sum "$package_root/usr/bin/nvpn"' \
  'sha256sum "$remote_dir/desktop_manual_join_e2e_fixture.copy"' \
  'sha256sum "$remote_dir/nostr-vpn.deb.copy"' \
  'sha256sum "$remote_dir/nvpn-x86_64-unknown-linux-musl.copy"' \
  'sudo -n dpkg --install "$remote_dir/nostr-vpn.deb.copy"' \
  'NVPN_UBUNTU_IMPORTED_APP="/usr/bin/nostr-vpn"' \
  'NVPN_UBUNTU_IMPORTED_CLI="/usr/bin/nvpn"' \
  'debian-package-install.json' \
  'ubuntu-vm-exact-deb-cleanup.sh' \
  'stat -c '\''%s'\''' \
  'sha256sum "$guest_repo/Cargo.lock"' \
  'sha256sum "$guest_repo/linux/Cargo.lock"' \
  '.rootCargoLockSha256 == $root_lock_sha' \
  '.rootRealizedCargoLockSha256 == $root_realized_lock_sha' \
  '.linuxCargoLockSha256 == $linux_lock_sha' \
  '.linuxRealizedCargoLockSha256 == $linux_realized_lock_sha' \
  '.fipsPatchedLockPackages == {' \
  '.builtOnHostMac == true' \
  '.builtOnRemoteVm == false' \
  'remoteSourceTreeVerified=true' \
  'remoteArtifactHashesVerified=true' \
  'remoteArtifactSizesVerified=true' \
  'remoteArtifactVersionsVerified=true' \
  'find "$remote_dir" -xdev -depth -mindepth 1 -delete' \
  'remoteArtifactRemoved=true'
require_tokens "$CLEANUP" "always-attempt transactional Debian cleanup" \
  'if ! sudo -n dpkg --purge nostr-vpn' \
  'cleanup_status=1' \
  'Remove only regular' \
  'sudo -n cp -a "$preexisting_root/." /' \
  'Pre-gate package-owned paths were not restored byte-for-byte.' \
  'exit "$cleanup_status"'
for wrapper in "$MANUAL" "$SERVICE"; do
  require_tokens "$wrapper" "shared direct-artifact import" \
    'lib-ubuntu-vm-imported-release.sh' \
    'ubuntu_vm_import_release_bundle' \
    'ubuntu_vm_cleanup_imported_release_bundle' \
    'NVPN_LINUX_APP_PATH="$app"' \
    'NVPN_LINUX_NVPN_PATH="$cli"' \
    'NVPN_LINUX_FIXTURE_PATH="$fixture"'
done
require_tokens "$MANUAL_GUEST" "explicit immutable artifact paths" \
  'NVPN_LINUX_APP_PATH' \
  'NVPN_LINUX_NVPN_PATH' \
  'NVPN_LINUX_FIXTURE_PATH' \
  'Set all three explicit Linux app, CLI, and fixture paths together.'
require_tokens "$RELEASE_GATE" "one cached bundle shared by both UI gates" \
  'prepare_host_linux_vm_bundle_and_record' \
  './scripts/prepare-host-linux-vm-bundle.sh' \
  'HOST_LINUX_VM_BUNDLE_PATH_RECEIPT' \
  'load_host_linux_vm_bundle_path_receipt' \
  'export NVPN_HOST_LINUX_VM_BUNDLE_DIR' \
  'run_linux_manual_join_ui_gate' \
  'run_linux_service_toggle_gate' \
  'run_linux_exclusive_desktop_gates'
if grep -Fq 'NVPN_UBUNTU_SKIP_BUILD' "$RELEASE_GATE"; then
  fail "release gate still coordinates reuse through a VM build switch"
fi

for vm_wrapper in "$MANUAL" "$SERVICE" "$UNDERLAY"; do
  if grep -Eq '(^|[[:space:]])(cargo|rustc)([[:space:]]|$)' "$vm_wrapper"; then
    fail "$(basename "$vm_wrapper") can invoke a compiler on a remote machine"
  fi
done
if grep -Eq 'cargo .*update|cargo "\\$\\{fips_config\\[@\\]\\}" update' "$PREPARER"; then
  fail "host Linux builder can rewrite the committed dependency locks"
fi
for wrapper in "$MANUAL" "$SERVICE"; do
  if grep -Eq 'CARGO_TARGET_DIR|NVPN_UBUNTU_SKIP_BUILD|linux/target|target/(debug|release)' \
    "$wrapper"
  then
    fail "$(basename "$wrapper") can consume an in-VM build tree"
  fi
done

"$CLEANUP_HARNESS" \
  | grep -Fq UBUNTU_EXACT_DEB_PURGE_FAILURE_RESTORE_OK

tmp="$(mktemp -d "${TMPDIR:-/tmp}/nvpn-host-linux-bundle-contract.XXXXXX")"
backup="$(mktemp -d "${TMPDIR:-/tmp}/nvpn-host-linux-bundle-backup.XXXXXX")"
trap 'rm -rf "$tmp" "$backup"' EXIT
app_sha="$(printf 'a%.0s' {1..40})"
app_tree="$(printf 'b%.0s' {1..40})"
fips_sha="$(printf 'c%.0s' {1..40})"
fips_tree="$(printf 'd%.0s' {1..40})"
root_lock_sha="$(printf 'e%.0s' {1..64})"
linux_lock_sha="$(printf 'f%.0s' {1..64})"
root_realized_lock_sha="$(printf '1%.0s' {1..64})"
linux_realized_lock_sha="$(printf '2%.0s' {1..64})"
app_version="4.1.5"
fips_version="0.4.45"

lock_test="$backup/lock-adversary"
mkdir -p "$lock_test"
python3 - "$lock_test" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
source = 'source = "registry+https://github.com/rust-lang/crates.io-index"\n'


def package(name: str, version: str, checksum: str, patched: bool) -> str:
    result = f'[[package]]\nname = "{name}"\nversion = "{version}"\n'
    if not patched:
        result += source + f'checksum = "{checksum}"\n'
    return result + 'dependencies = ["stable"]\n\n'


targets = (
    ("fips-core", "0.4.45", "a" * 64),
    ("fips-endpoint", "0.4.45", "b" * 64),
    ("fips-identity", "0.3.2", "c" * 64),
)
unrelated = ("unrelated", "1.0.0", "d" * 64)
prefix = "version = 4\n\n"
committed = prefix + "".join(
    package(name, version, checksum, False)
    for name, version, checksum in (*targets, unrelated)
)
realized = prefix + "".join(
    package(name, version, checksum, True)
    for name, version, checksum in targets
) + package(*unrelated, False)
partial = prefix + package(*targets[0], True) + "".join(
    package(name, version, checksum, False)
    for name, version, checksum in (*targets[1:], unrelated)
)
extra = realized.replace(source, "", 1)
dependency = realized.replace(
    'dependencies = ["stable"]', 'dependencies = ["changed"]', 1
)
version = realized.replace(
    'name = "fips-identity"\nversion = "0.3.2"',
    'name = "fips-identity"\nversion = "0.3.3"',
)
wrong_version = committed.replace(
    'name = "fips-identity"\nversion = "0.3.2"',
    'name = "fips-identity"\nversion = "0.3.3"',
)
for name, value in (
    ("committed.lock", committed),
    ("realized.lock", realized),
    ("partial.lock", partial),
    ("extra.lock", extra),
    ("dependency.lock", dependency),
    ("version.lock", version),
    ("wrong-version.lock", wrong_version),
):
    (root / name).write_text(value, encoding="utf-8")
PY
patch_specs=(
  fips-core=0.4.45
  fips-endpoint=0.4.45
  fips-identity=0.3.2
)
expected_patch_sha="$(
  python3 "$PATCH_LOCK_VERIFIER" \
    --expected-sha256 "$lock_test/committed.lock" "${patch_specs[@]}"
)"
[[ "$(
  python3 "$PATCH_LOCK_VERIFIER" \
    --validate "$lock_test/committed.lock" "$lock_test/realized.lock" \
    "${patch_specs[@]}"
)" == "$expected_patch_sha" ]] \
  || fail "exact FIPS patch lock verifier rejected the canonical delta"
for adversary in partial.lock extra.lock dependency.lock version.lock; do
  if python3 "$PATCH_LOCK_VERIFIER" \
    --validate "$lock_test/committed.lock" "$lock_test/$adversary" \
    "${patch_specs[@]}" >/dev/null 2>&1
  then
    fail "exact FIPS patch lock verifier accepted $adversary"
  fi
done
if python3 "$PATCH_LOCK_VERIFIER" \
  --expected-sha256 "$lock_test/wrong-version.lock" "${patch_specs[@]}" \
  >/dev/null 2>&1
then
  fail "exact FIPS patch lock verifier accepted the wrong package version"
fi

python3 - \
  "$tmp" "$app_sha" "$app_tree" "$app_version" \
  "$fips_sha" "$fips_tree" "$fips_version" \
  "$root_lock_sha" "$root_realized_lock_sha" \
  "$linux_lock_sha" "$linux_realized_lock_sha" \
  "${patch_specs[@]}" <<'PY'
import hashlib
import io
import json
import os
import pathlib
import sys
import tarfile

root = pathlib.Path(sys.argv[1])
(
    app_sha,
    app_tree,
    app_version,
    fips_sha,
    fips_tree,
    fips_version,
    root_lock_sha,
    root_realized_lock_sha,
    linux_lock_sha,
    linux_realized_lock_sha,
    fips_core_patch_spec,
    fips_endpoint_patch_spec,
    fips_identity_patch_spec,
) = sys.argv[2:]
fips_patch_packages = dict(
    spec.split("=", 1)
    for spec in (
        fips_core_patch_spec,
        fips_endpoint_patch_spec,
        fips_identity_patch_spec,
    )
)
executables = {
    "app": "nostr-vpn",
    "cli": "nvpn",
    "manualJoinFixture": "desktop_manual_join_e2e_fixture",
    "muslCli": "nvpn-x86_64-unknown-linux-musl",
}
artifacts = {}
for index, (label, name) in enumerate(executables.items(), start=1):
    raw = bytearray(64)
    raw[:6] = b"\x7fELF\x02\x01"
    raw[18:20] = (62).to_bytes(2, "little")
    raw[32] = index
    path = root / name
    path.write_bytes(raw)
    path.chmod(0o555)
    artifacts[label] = {
        "file": name,
        "sha256": hashlib.sha256(raw).hexdigest(),
        "size": len(raw),
    }
deb = root / "nostr-vpn.deb"
deb.write_bytes(b"!<arch>\n" + b"synthetic-debian-package")
deb.chmod(0o444)
artifacts["debianPackage"] = {
    "file": deb.name,
    "sha256": hashlib.sha256(deb.read_bytes()).hexdigest(),
    "size": deb.stat().st_size,
}
archive_path = root / "nvpn-x86_64-unknown-linux-musl.tar.gz"
with tarfile.open(archive_path, "w:gz") as archive:
    for name, raw, mode in (
        ("nvpn/README.txt", b"nvpn test\n", 0o444),
        ("nvpn/install.sh", b"#!/bin/sh\n", 0o555),
        (
            "nvpn/nvpn",
            (root / executables["muslCli"]).read_bytes(),
            0o555,
        ),
    ):
        info = tarfile.TarInfo(name)
        info.size = len(raw)
        info.mode = mode
        archive.addfile(info, io.BytesIO(raw))
archive_path.chmod(0o444)
artifacts["muslCliArchive"] = {
    "file": archive_path.name,
    "sha256": hashlib.sha256(archive_path.read_bytes()).hexdigest(),
    "size": archive_path.stat().st_size,
}
receipt = {
    "schema": 1,
    "builtOnHostMac": True,
    "builtOnRemoteVm": False,
    "appGitSha": app_sha,
    "appGitTree": app_tree,
    "appVersion": app_version,
    "fipsGitSha": fips_sha,
    "fipsGitTree": fips_tree,
    "fipsVersion": fips_version,
    "rootCargoLockSha256": root_lock_sha,
    "rootRealizedCargoLockSha256": root_realized_lock_sha,
    "linuxCargoLockSha256": linux_lock_sha,
    "linuxRealizedCargoLockSha256": linux_realized_lock_sha,
    "fipsPatchedLockPackages": fips_patch_packages,
    "target": "x86_64-unknown-linux-gnu",
    "dockerPlatform": "linux/amd64",
    "containerBase": "ubuntu:24.04",
    "sourceDateEpoch": 1,
    "rustcVersion": "rustc test",
    "cargoVersion": "cargo test",
    "cliShortVersion": f"nvpn {app_version}",
    "cliVerboseVersion": f"fips_core: {fips_version} (rev {fips_sha[:10]})",
    "muslCliShortVersion": f"nvpn {app_version}",
    "muslCliVerboseVersion":
        f"fips_core: {fips_version} (rev {fips_sha[:10]})",
    "muslTarget": "x86_64-unknown-linux-musl",
    "cargoDebVersion": "3.7.0",
    "debianPackage": {
        "package": "nostr-vpn",
        "version": app_version,
        "architecture": "amd64",
        "appPath": "usr/bin/nostr-vpn",
        "cliPath": "usr/bin/nvpn",
    },
    "artifacts": artifacts,
}
(root / "receipt.json").write_text(
    json.dumps(receipt, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY
python3 "$VERIFIER" \
  "$tmp" "$tmp/receipt.json" \
  "$app_sha" "$app_tree" "$app_version" \
  "$fips_sha" "$fips_tree" "$fips_version" \
  "$root_lock_sha" "$root_realized_lock_sha" \
  "$linux_lock_sha" "$linux_realized_lock_sha" \
  x86_64-unknown-linux-gnu "${patch_specs[@]}" \
  | grep -Fq HOST_LINUX_VM_BUNDLE_VERIFIED

cp "$tmp/receipt.json" "$backup/receipt-before-realized-lock-adversary.json"
python3 - "$tmp/receipt.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
receipt = json.loads(path.read_text(encoding="utf-8"))
receipt["rootRealizedCargoLockSha256"] = "0" * 64
path.write_text(
    json.dumps(receipt, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY
if python3 "$VERIFIER" \
  "$tmp" "$tmp/receipt.json" \
  "$app_sha" "$app_tree" "$app_version" \
  "$fips_sha" "$fips_tree" "$fips_version" \
  "$root_lock_sha" "$root_realized_lock_sha" \
  "$linux_lock_sha" "$linux_realized_lock_sha" \
  x86_64-unknown-linux-gnu "${patch_specs[@]}" \
  >/dev/null 2>&1
then
  fail "bundle verifier accepted a mutated realized lock hash"
fi
mv "$backup/receipt-before-realized-lock-adversary.json" \
  "$tmp/receipt.json"

# A correctly hashed archive is still invalid if a glibc executable is put
# behind the public musl filename. This is the regression that allowed an
# earlier release path to mislabel the gate bundle's glibc CLI as static musl.
cp "$tmp/receipt.json" "$backup/receipt.json"
cp "$tmp/nvpn-x86_64-unknown-linux-musl.tar.gz" "$backup/archive.tar.gz"
chmod u+w "$tmp/nvpn-x86_64-unknown-linux-musl.tar.gz"
python3 - \
  "$tmp/receipt.json" \
  "$tmp/nvpn-x86_64-unknown-linux-musl.tar.gz" \
  "$tmp/nvpn" <<'PY'
import hashlib
import io
import json
import pathlib
import sys
import tarfile

receipt_path = pathlib.Path(sys.argv[1])
archive_path = pathlib.Path(sys.argv[2])
wrong_cli = pathlib.Path(sys.argv[3]).read_bytes()
with tarfile.open(archive_path, "w:gz") as archive:
    for name, raw, mode in (
        ("nvpn/README.txt", b"nvpn test\n", 0o444),
        ("nvpn/install.sh", b"#!/bin/sh\n", 0o555),
        ("nvpn/nvpn", wrong_cli, 0o555),
    ):
        info = tarfile.TarInfo(name)
        info.size = len(raw)
        info.mode = mode
        archive.addfile(info, io.BytesIO(raw))
receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
entry = receipt["artifacts"]["muslCliArchive"]
entry["sha256"] = hashlib.sha256(archive_path.read_bytes()).hexdigest()
entry["size"] = archive_path.stat().st_size
receipt_path.write_text(
    json.dumps(receipt, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY
if python3 "$VERIFIER" \
  "$tmp" "$tmp/receipt.json" \
  "$app_sha" "$app_tree" "$app_version" \
  "$fips_sha" "$fips_tree" "$fips_version" \
  "$root_lock_sha" "$root_realized_lock_sha" \
  "$linux_lock_sha" "$linux_realized_lock_sha" \
  x86_64-unknown-linux-gnu "${patch_specs[@]}" \
  >/dev/null 2>&1
then
  fail "bundle verifier accepted a glibc CLI mislabeled as static musl"
fi
mv "$backup/receipt.json" "$tmp/receipt.json"
mv "$backup/archive.tar.gz" \
  "$tmp/nvpn-x86_64-unknown-linux-musl.tar.gz"

chmod u+w "$tmp/nvpn"
printf x >>"$tmp/nvpn"
if python3 "$VERIFIER" \
  "$tmp" "$tmp/receipt.json" \
  "$app_sha" "$app_tree" "$app_version" \
  "$fips_sha" "$fips_tree" "$fips_version" \
  "$root_lock_sha" "$root_realized_lock_sha" \
  "$linux_lock_sha" "$linux_realized_lock_sha" \
  x86_64-unknown-linux-gnu "${patch_specs[@]}" \
  >/dev/null 2>&1
then
  fail "bundle verifier accepted a post-receipt CLI mutation"
fi

echo "HOST_LINUX_VM_IMPORT_ONLY_CONTRACT_OK"
