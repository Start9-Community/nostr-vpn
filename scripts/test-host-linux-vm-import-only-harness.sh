#!/usr/bin/env bash
# Source and receipt contract for exact/import-only native Linux VM gates.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREPARER="$ROOT/scripts/prepare-host-linux-vm-bundle.sh"
VERIFIER="$ROOT/scripts/verify-host-linux-vm-bundle.py"
PATCH_LOCK_VERIFIER="$ROOT/scripts/verify-cargo-path-patch-lock.py"
IMPORT_LIB="$ROOT/scripts/lib-ubuntu-vm-imported-release.sh"
MANUAL="$ROOT/scripts/ubuntu-vm-manual-join-e2e.sh"
SERVICE="$ROOT/scripts/ubuntu-vm-service-toggle-e2e.sh"
UNDERLAY="$ROOT/scripts/linux-vm-desktop-underlay-change-e2e.sh"
RELEASE_JOIN="$ROOT/scripts/ubuntu-vm-release-mobile-join-e2e.sh"
RELEASE_JOIN_GUEST="$ROOT/scripts/linux-release-mobile-join-remote.sh"
MANUAL_GUEST="$ROOT/linux/scripts/e2e-manual-join-ui.sh"
RELEASE_GATE="$ROOT/scripts/release-gate.sh"
DOCKERFILE="$ROOT/Dockerfile.linux-vm-gate"
CLEANUP="$ROOT/scripts/ubuntu-vm-exact-deb-cleanup.sh"
SERIALIZED_DPKG="$ROOT/scripts/ubuntu-vm-serialized-dpkg.sh"
CLEANUP_HARNESS="$ROOT/scripts/test-ubuntu-vm-exact-deb-cleanup-harness.sh"
RECOVERY="$ROOT/scripts/ubuntu-vm-recover-stale-import.sh"
RECOVERY_HARNESS="$ROOT/scripts/test-ubuntu-vm-stale-import-recovery-harness.sh"
JOIN_SERVICE_CLEANUP_HARNESS="$ROOT/scripts/test-linux-release-mobile-join-service-cleanup-harness.sh"
IMPORT_LOCK_HOLDER="$ROOT/scripts/ubuntu-vm-import-lock-holder.sh"
ISOLATION_LIB="$ROOT/scripts/lib-host-linux-builder-isolation.sh"
ISOLATION_HARNESS="$ROOT/scripts/test-host-linux-builder-isolation-harness.sh"
CONTAINER_PAYLOAD="$ROOT/scripts/build-host-linux-vm-bundle-in-container.sh"
NATIVE_BUILDER_LIB="$ROOT/scripts/lib-host-linux-native-builder.sh"
REMOTE_BUILDER="$ROOT/scripts/host-linux-native-builder-remote.sh"
CARGO_CACHE_VERIFIER="$ROOT/scripts/host_linux_cargo_archive_cache.py"
SOURCE_AUDITOR="$ROOT/scripts/verify_host_linux_build_source.py"
PACKAGE_VERIFIER="$ROOT/scripts/host_linux_package_content.py"

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
  "$RELEASE_JOIN" \
  "$RELEASE_JOIN_GUEST" \
  "$CLEANUP" \
  "$SERIALIZED_DPKG" \
  "$CLEANUP_HARNESS" \
  "$RECOVERY" \
  "$RECOVERY_HARNESS" \
  "$JOIN_SERVICE_CLEANUP_HARNESS" \
  "$IMPORT_LOCK_HOLDER" \
  "$ISOLATION_HARNESS" \
  "$CONTAINER_PAYLOAD" \
  "$REMOTE_BUILDER" \
  "$CARGO_CACHE_VERIFIER" \
  "$SOURCE_AUDITOR" \
  "$PACKAGE_VERIFIER"
do
  [[ -x "$executable" ]] || fail "$(basename "$executable") is not executable"
done
[[ -f "$IMPORT_LIB" && -f "$DOCKERFILE" && -f "$ISOLATION_LIB" \
  && -f "$NATIVE_BUILDER_LIB" ]] \
  || fail "shared import/build-isolation helper or Ubuntu builder image is missing"
require_tokens "$RELEASE_JOIN" "concurrent desktop-admin acceptance timing" \
  'DESKTOP_ADMIN_DEADLINE_HOST_MS' \
  'release_join_observe_until_ms' \
  'linux_admin_desktop_visible' \
  'linux_admin_pixel_visible' \
  'DESKTOP_ACCEPTED_HOST_MS' \
  'PIXEL_ACCEPTED_HOST_MS'
require_tokens "$RELEASE_JOIN" "two-phase Pixel-admin coordination" \
  'marker_value "$RESULT_DIR/desktop-joiner-bootstrap.json" joinerNpub' \
  'release_join_android_manual_admin_prepare "$DESKTOP_JOINER_NPUB"' \
  'release_join_android_manual_admin_submit "$DESKTOP_JOINER_NPUB"'
require_tokens "$ROOT/scripts/desktop-mobile-manual-join-atspi.py" \
  "Bootstrap joiner identity preflight" \
  'self.evidence["joinerNpub"] = read_npub('
[[ "$(sed -n \
  '/# Imported Linux desktop admin -> physical Pixel joiner\./,/# Physical Pixel admin -> imported Linux desktop joiner\./p' \
  "$RELEASE_JOIN" | grep -Fc 'release_join_observe_until_ms')" -eq 2 ]] \
  || fail "Linux desktop and Pixel acceptance are not observed independently"
require_tokens "$PATCH_LOCK_VERIFIER" "fail-closed FIPS patch lock delta" \
  'REGISTRY_SOURCE' \
  'committed lock has duplicate target package' \
  'realized lock differs by more than exact target ' \
  '"--manifest-specs"' \
  '"--expected-sha256"' \
  '"--materialize"' \
  '"--validate"'

require_tokens "$DOCKERFILE" "pinned Ubuntu host build environment" \
  'FROM ubuntu:24.04' \
  'ARG RUST_TOOLCHAIN=1.95.0' \
  'libadwaita-1-dev' \
  'libgtk-4-dev' \
  'musl-tools' \
  'cargo install cargo-deb --version 3.7.0 --locked'
require_tokens "$PREPARER" "clean exact cached Linux bundle" \
  'NVPN_HOST_LINUX_VM_BUILDER_MODE' \
  'local-docker Linux release building requires a native x86_64 Mac' \
  '[[ "$(uname -s)" == "Darwin" ]]' \
  'source "$ROOT/scripts/mobile_env.sh"' \
  'load_mobile_env "$ROOT"' \
  'status --porcelain --untracked-files=all' \
  'release_join_require_clean_fips' \
  'host_linux_native_builder_configured' \
  'remote-native)' \
  'CACHE_KEY="$APP_GIT_SHA-$RELEASE_JOIN_FIPS_SHA-$TARGET-ubuntu24.04-rust$RUST_TOOLCHAIN-cargo-deb$CARGO_DEB_VERSION-package5-$BUILDER_MODE"' \
  'HOST_BUILD_LOCK="$CACHE_ROOT/.host-linux-vm-bundle.lock"' \
  'HOST_BUILD_LOCK_HELD=0' \
  'exec 9>"$HOST_BUILD_LOCK"' \
  '/usr/bin/lockf 9' \
  'HOST_BUILD_LOCK_HELD=1' \
  '&& "$HOST_BUILD_LOCK_HELD" == "1" ]]' \
  'if verify_bundle; then' \
  'Dockerfile.linux-vm-gate' \
  'verify-cargo-path-patch-lock.py' \
  '--manifest-specs "$NVPN_FIPS_REPO_PATH"' \
  'TARGET_CACHE_GENERATION="fresh-docker-volume-v5-rust${RUST_TOOLCHAIN//./-}"' \
  'TARGET_VOLUME_NAME="nvpn-linux-target-${TARGET_VOLUME_ID:0:24}"' \
  'host_linux_builder_create_fresh_target_volume' \
  'host_linux_builder_remove_target_volume' \
  '"$TARGET_VOLUME_NAME:/target-root"' \
  '--name "$CONTAINER_NAME"' \
  '--label "to.nostrvpn.release-builder-cache=$BUILD_CACHE_ID"' \
  'host_linux_builder_stop_container "$CONTAINER_NAME" "$BUILD_CACHE_ID"' \
  'host_linux_builder_stop_container \' \
  '  --platform "$DOCKER_PLATFORM" \' \
  'dockerPlatform": "linux/amd64"' \
  'containerBase": "ubuntu:24.04"' \
  '"schema": 2' \
  '"builderMode": builder_mode' \
  '"builtOnHostMac": built_on_host_mac' \
  '"builtOnRemoteVm": built_on_remote_vm' \
  '"dockerfileSha256": builder["dockerfileSha256"]' \
  '"containerPayloadSha256": builder["containerPayloadSha256"]' \
  '"rootCargoLockSha256": root_cargo_lock_sha256' \
  '"rootRealizedCargoLockSha256": root_realized_cargo_lock_sha256' \
  '"linuxCargoLockSha256": linux_cargo_lock_sha256' \
  '"linuxRealizedCargoLockSha256": linux_realized_cargo_lock_sha256' \
  '"fipsPatchedLockPackages": fips_patch_packages' \
  'host_linux_native_builder_run \' \
  '/workspace/app/scripts/build-host-linux-vm-bundle-in-container.sh' \
  'verify-host-linux-vm-bundle.py'
require_tokens "$RELEASE_JOIN" "exact installed Release join paths" \
  'source "$ROOT/scripts/lib-mobile-release-join-ui.sh"' \
  '"$NVPN_UBUNTU_IMPORTED_APP"' \
  '"$NVPN_UBUNTU_IMPORTED_CLI"' \
  '"$NVPN_UBUNTU_IMPORTED_PACKAGE_RECEIPT"'
require_tokens "$RELEASE_JOIN_GUEST" "DEB-installed binary verification" \
  '[[ "$APP" == /usr/bin/nostr-vpn' \
  '&& "$CLI" == /usr/bin/nvpn' \
  '.packageInstalledByDpkg == true' \
  '.installedAppSha256 == $app_hash' \
  '.installedCliSha256 == $cli_hash' \
  '"$(sha256sum "$APP"' \
  '"$(sha256sum "$CLI"'
require_tokens "$RELEASE_JOIN_GUEST" "exact service lifecycle" \
  'InstallService' \
  'requires an empty service slot' \
  'sudo -n "$CLI" service install --force --config "$CONFIG"' \
  '.running and .label == "nvpn.service"' \
  'sha256sum "$SERVICE_BINARY"' \
  '&& assert_service_ready; then' \
  'sudo -n "$CLI" service uninstall --config "$CONFIG"' \
  'sudo -n find "$SERVICE_BINARY" -maxdepth 0 -type f -delete'
python3 - "$RELEASE_JOIN" <<'PY'
import pathlib
import sys

host = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")

admin = host[
    host.index("# Imported Linux desktop admin -> physical Pixel joiner.") :
    host.index("# Physical Pixel admin -> imported Linux desktop joiner.")
]
joiner = host[
    host.index("# Physical Pixel admin -> imported Linux desktop joiner.") :
    host.index("release_join_assert_one_android_package")
]
checks = (
    (admin, 'remote CreateAdmin', 'remote InstallService'),
    (admin, 'remote InstallService', 'release_join_android_manual_submit'),
    (joiner, 'remote Bootstrap', 'remote InstallService'),
    (joiner, 'remote InstallService', 'release_join_android_create_admin'),
)
if any(text.index(left) >= text.index(right) for text, left, right in checks):
    raise SystemExit("Linux Release join service lifecycle is out of order")
for install in ('desktop-admin-service.log', 'desktop-joiner-service.log'):
    install_index = host.index(f'remote InstallService >"$RESULT_DIR/{install}"')
    last_arm = host.rfind('service_cleanup_armed=1', 0, install_index)
    last_disarm = host.rfind('service_cleanup_armed=0', 0, install_index)
    if last_arm < last_disarm:
        raise SystemExit("Linux Release join service cleanup is armed after mutation")
PY
require_tokens "$CONTAINER_PAYLOAD" "one canonical container build payload" \
  'host_linux_cargo_archive_cache.py' \
  'CARGO_NET_OFFLINE=true' \
  '--frozen' \
  '--validate /output/root-Cargo.lock.committed Cargo.lock' \
  '--validate /output/linux-Cargo.lock.committed Cargo.lock' \
  'metadata --format-version 1 >/dev/null' \
  'fetch --locked' \
  '/target-root/release/nvpn' \
  '/target-root/x86_64-unknown-linux-musl/release/nvpn' \
  '/target-root/release/examples/desktop_manual_join_e2e_fixture' \
  '/target-root/release/nostr-vpn' \
  'O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW' \
  'cargo deb --frozen --offline --no-build --no-strip' \
  'packaging-only Cargo config changed' \
  '/output/nostr-vpn.deb' \
  '/output/nvpn-x86_64-unknown-linux-musl.tar.gz'
if grep -Eq 'TARGET_CACHE_ROOT|build-cache/(root|linux)-target|/target-linux' "$PREPARER"; then
  fail "host Linux builder still uses a Docker Desktop bind-mounted Cargo target"
fi
if grep -Fq 'CONTAINER_CID_FILE' "$PREPARER"; then
  fail "host Linux builder has two competing identities for its deterministic container"
fi
python3 - "$PREPARER" "$CONTAINER_PAYLOAD" <<'PY'
import pathlib
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
payload = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
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
volume_ensure = text.index(
    "host_linux_builder_create_fresh_target_volume", second_verify
)
target_mount = text.index('"$TARGET_VOLUME_NAME:/target-root"')
if not stale_cleanup < target_mount:
    raise SystemExit(
        "host Linux builder can mount its persistent target cache before stale "
        "server-side builders are removed"
    )
if not stale_cleanup < volume_ensure < target_mount:
    raise SystemExit(
        "host Linux builder does not validate its native target volume before use"
    )
if payload.count("export CARGO_TARGET_DIR=/target-root") != 1:
    raise SystemExit(
        "canonical payload does not bind every build to the fresh native target"
    )
if "realize" not in payload or "build" not in payload or "--frozen" not in payload:
    raise SystemExit("canonical payload does not split fetch from frozen build")
PY
require_tokens "$ISOLATION_LIB" "validated exact-container cleanup" \
  'to.nostrvpn.release-builder' \
  'to.nostrvpn.release-builder-cache' \
  'Refusing to remove mismatched Linux builder container' \
  'docker rm --force "$container_id"' \
  'docker container inspect' \
  'host_linux_builder_create_fresh_target_volume' \
  'host_linux_builder_remove_target_volume' \
  'to.nostrvpn.release-builder-generation' \
  'Refusing mismatched Linux builder target volume' \
  "'{{ .Driver }}'" \
  "'{{ .Mountpoint }}'" \
  '"$driver" == "local"' \
  'docker volume inspect'
"$ISOLATION_HARNESS"
require_tokens "$NATIVE_BUILDER_LIB" "fail-closed Mac orchestration" \
  'NVPN_HOST_LINUX_VM_NATIVE_BUILDER_HOST' \
  'NVPN_HOST_LINUX_VM_NATIVE_BUILDER_JUMP' \
  'NVPN_HOST_LINUX_VM_NATIVE_BUILDER_PROXY_COMMAND' \
  'StrictHostKeyChecking=yes' \
  'git -C "$temp_dir/source/app" bundle create "$app_bundle" HEAD' \
  'git -C "$temp_dir/source/fips" bundle create "$fips_bundle" HEAD' \
  'git bundle verify "$app_bundle"' \
  'mktemp -d "$runs/nvpn-linux-native-builder.XXXXXX"' \
  '.cache/nostr-vpn-linux-release-builder/runs' \
  'sha256sum "$driver"' \
  'host_linux_native_builder_extract_output' \
  'member.issym()' \
  'member.islnk()' \
  'os.O_EXCL | os.O_NOFOLLOW' \
  'Remote native Linux builder did not clean its temporary root'
require_tokens "$REMOTE_BUILDER" "exact native remote build and cleanup" \
  '[[ "$(uname -s)" == "Linux" && "$(uname -m)" == "x86_64" ]]' \
  'sha256sum "$APP_BUNDLE"' \
  'sha256sum "$FIPS_BUNDLE"' \
  'git -C "$REMOTE_ROOT/app" clean -ffdx' \
  'git -C "$REMOTE_ROOT/fips" clean -ffdx' \
  'cat-file blob' \
  'python3 "$SOURCE_AUDITOR" --exact' \
  'EXPECTED_DOCKERFILE_SHA256' \
  'EXPECTED_PAYLOAD_SHA256' \
  '[[ -z "${DOCKER_HOST:-}" && -z "${DOCKER_CONTEXT:-}" ]]' \
  '[[ "$(docker context show)" == "default"' \
  '"unix:///var/run/docker.sock"' \
  '"root:docker:660"' \
  'docker info --format '\''{{.OSType}}/{{.Architecture}}'\''' \
  'flock 9' \
  'host_linux_builder_create_fresh_target_volume \' \
  'host_linux_builder_remove_target_volume \' \
  'docker build \' \
  'docker run --rm \' \
  '--user "$BUILDER_UID:$BUILDER_GID"' \
  'OWNER_CONTAINER_NAME="${CONTAINER_NAME}-owner"' \
  'chown "$1:$2" /target-root' \
  'app_mount="$app_mount:ro"' \
  'host_linux_cargo_archive_cache.py' \
  'verify_host_linux_build_source.py' \
  '"builderMode": "remote-native"' \
  '"builderHostArchitecture": "x86_64"' \
  'tar --format=ustar -cf -' \
  'find "$REMOTE_ROOT" -xdev -depth -mindepth 1 -delete'
require_tokens "$CARGO_CACHE_VERIFIER" "archive-only Cargo download cache" \
  'registry/cache/index.crates.io-1949cf8c6b5b557f' \
  'cached crate archive checksum differs from Cargo.lock' \
  'persistent Cargo cache contains a non-archive entry' \
  'os.O_NOFOLLOW'
require_tokens "$SOURCE_AUDITOR" "post-build exact source audit" \
  'Cargo.lock' \
  'linux/Cargo.lock' \
  'source file set differs from exact Git tree' \
  'source bytes differ from exact Git blob' \
  'ls-tree'
require_tokens "$PACKAGE_VERIFIER" "complete non-executing package validation" \
  'control.tar.xz' \
  'data.tar.xz' \
  'maintainer' \
  'nostr-vpn.desktop' \
  'copyright' \
  'nvpn/install.sh'
for remote_source in "$NATIVE_BUILDER_LIB" "$REMOTE_BUILDER"; do
  if grep -Eq \
    '(^|[;&|[:space:]])(sudo|systemctl|service|nmcli|wg-quick)([;&|[:space:]]|$)|dpkg[[:space:]]+--install' \
    "$remote_source"
  then
    fail "$(basename "$remote_source") can mutate a remote service or network"
  fi
done
require_tokens "$VERIFIER" "hash/size/version/source receipt validation" \
  'verify_debian_package' \
  'verify_musl_archive' \
  '"schema": 2' \
  '"local-docker": {' \
  '"remote-native": {' \
  '"builtOnHostMac": True' \
  '"builtOnRemoteVm": False' \
  '"builtOnHostMac": False' \
  '"builtOnRemoteVm": True' \
  '"builderHostArchitectures": {"x86_64"}' \
  '"dockerfileSha256": dockerfile_sha256' \
  '"containerPayloadSha256": container_payload_sha256' \
  'receipt rustc version differs from the pinned toolchain' \
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
  'release_root="${NVPN_RELEASE_APP_REPO_PATH:-$ROOT}"' \
  'assert_release_checkout_state' \
  'harness_sha="$(git -C "$ROOT" rev-parse HEAD)"' \
  'harness_tree="$(git -C "$ROOT" rev-parse' \
  '"$ROOT" "$harness_sha" "$harness_tree" "Ubuntu VM guest harness"' \
  'git -C "$root" show "${app_sha}:Cargo.lock"' \
  'git -C "$root" show "${app_sha}:linux/Cargo.lock"' \
  'ubuntu_vm_committed_lock_evidence' \
  '--manifest-specs "$NVPN_FIPS_REPO_PATH"' \
  'mktemp -d /tmp/nvpn-linux-vm-release.XXXXXX' \
  'sha256sum "$package_root/usr/bin/nostr-vpn"' \
  'sha256sum "$package_root/usr/bin/nvpn"' \
  'sha256sum "$remote_dir/desktop_manual_join_e2e_fixture.copy"' \
  'sha256sum "$remote_dir/nostr-vpn.deb.copy"' \
  'sha256sum "$remote_dir/nvpn-x86_64-unknown-linux-musl.copy"' \
  'ubuntu-vm-serialized-dpkg.sh" \' \
  'install "$remote_dir/nostr-vpn.deb" >/dev/null' \
  'host_linux_package_content.py' \
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
  '.schema == 2' \
  '.builderMode == $builder_mode' \
  '$builder_mode == "remote-native"' \
  '.builtOnHostMac == true' \
  '.builtOnRemoteVm == false' \
  '.builtOnHostMac == false' \
  '.builtOnRemoteVm == true' \
  'artifactProductSourceVerified=true' \
  'remoteHarnessSourceVerified=true' \
  'remoteArtifactHashesVerified=true' \
  'remoteArtifactSizesVerified=true' \
  'remoteArtifactVersionsVerified=true' \
  'find "$remote_dir" -xdev -depth -mindepth 1 -delete' \
  'remoteArtifactRemoved=true'
require_tokens "$CLEANUP" "always-attempt transactional Debian cleanup" \
  'if ! "$serialized_dpkg" purge >/dev/null' \
  'cleanup_status=1' \
  'Remove only regular' \
  'sudo -n cp -a -- "$source_path" "$candidate"' \
  'sudo -n cp -a -- "$source_path" "$target_path"' \
  'Pre-gate package-owned paths were not restored byte-for-byte.' \
  'exit "$cleanup_status"'
require_tokens "$SERIALIZED_DPKG" "bounded exact dpkg serialization" \
  'deadline=$((SECONDS + 300))' \
  'LC_ALL=C sudo -n dpkg "${DPKG_ARGS[@]}"' \
  'dpkg (frontend |database )?lock was locked by' \
  'timed out waiting for the Ubuntu package-manager lock' \
  'install "$PACKAGE"' \
  'DPKG_ARGS=(--purge nostr-vpn)'
require_tokens "$RECOVERY" "receipt-bound interrupted-gate recovery" \
  'candidate_dirs=(/tmp/nvpn-linux-vm-release.*)' \
  '(( ${#marked_dirs[@]} == 1 ))' \
  'unmarked nostr-vpn package state is present' \
  'multiple marked nVPN import directories are present' \
  'install receipt does not match its exact bundle receipt' \
  'Debian metadata differs from the exact stale package' \
  'captured package tree differs from the exact stale Debian package' \
  'automatic recovery requires empty preexisting backup trees' \
  'bash "$CLEANUP" "$stale_dir"' \
  'UBUNTU_STALE_IMPORT_RECOVERY_OK'
require_tokens "$IMPORT_LIB" "pre-import interrupted-gate recovery" \
  'ubuntu_vm_acquire_import_lock' \
  'ubuntu_vm_release_import_lock' \
  'ubuntu-vm-import-lock-holder.sh' \
  'ubuntu_vm_recover_stale_imported_release_bundle' \
  'write_import_phase installing' \
  'write_import_phase installed' \
  'stale exact-package recovery failed'
require_tokens "$IMPORT_LOCK_HOLDER" "disconnect-safe import lifecycle lock" \
  'flock -w 30 9' \
  'UBUNTU_IMPORT_LIFECYCLE_LOCK_READY' \
  'IFS= read -r -n 1 _ || true'
for wrapper in "$MANUAL" "$SERVICE"; do
  require_tokens "$wrapper" "shared direct-artifact import" \
    'lib-ubuntu-vm-imported-release.sh' \
    'ubuntu_vm_import_release_bundle' \
    'ubuntu_vm_cleanup_imported_release_bundle' \
    'NVPN_LINUX_APP_PATH="$app"' \
    'NVPN_LINUX_NVPN_PATH="$cli"' \
    'NVPN_LINUX_FIXTURE_PATH="$fixture"'
done
require_tokens "$MANUAL" "absolute guest repository handoff" \
  'cd "$repo"' \
  'repo="$(pwd -P)"' \
  'NVPN_REPO_ROOT="$repo"' \
  '"phase": "ui-verified"' \
  '"adminOutboxQueuedBeforeRuntime": True' \
  '"deliveryCompletedDuringUi": False'
if grep -Fq '"phase": "runtime-verified"' "$MANUAL"; then
  fail "Linux native UI gate still tries to run two machine-global daemons on one VM"
fi
require_tokens "$MANUAL_GUEST" "explicit immutable artifact paths" \
  'cd "${NVPN_REPO_ROOT:-$(dirname "${BASH_SOURCE[0]}")/../..}"' \
  'pwd -P' \
  'NVPN_LINUX_APP_PATH' \
  'NVPN_LINUX_NVPN_PATH' \
  'NVPN_LINUX_FIXTURE_PATH' \
  'Set all three explicit Linux app, CLI, and fixture paths together.'
if grep -Fq 'start_runtime "$ADMIN_DATA_DIR"' "$MANUAL_GUEST"; then
  fail "Linux native UI gate still bypasses the production daemon singleton topology"
fi
python3 - "$MANUAL_GUEST" <<'PY'
import pathlib
import sys

calls = [
    line.strip()
    for line in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
    if line.lstrip().startswith('"$FIXTURE" ')
]
if not calls or not calls[-1].startswith('"$FIXTURE" capture-delivery '):
    raise SystemExit(
        "Linux manual-join UI gate overwrites its terminal signed delivery receipt"
    )
PY
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

cleanup_harness_output="$("$CLEANUP_HARNESS")"
grep -Fq UBUNTU_EXACT_DEB_PURGE_FAILURE_RETRY_OK \
  <<<"$cleanup_harness_output"
recovery_harness_output="$("$RECOVERY_HARNESS")"
grep -Fq UBUNTU_STALE_IMPORT_RECOVERY_HARNESS_OK \
  <<<"$recovery_harness_output"
"$JOIN_SERVICE_CLEANUP_HARNESS"

python3 - "$IMPORT_LIB" "$RELEASE_GATE" <<'PY'
import pathlib
import sys

import_text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
gate_text = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")

import_start = import_text.index("ubuntu_vm_import_release_bundle()")
recover = import_text.index(
    "ubuntu_vm_recover_stale_imported_release_bundle", import_start
)
create = import_text.index(
    "mktemp -d /tmp/nvpn-linux-vm-release.XXXXXX", import_start
)
if not recover < create:
    raise SystemExit("Ubuntu stale recovery does not precede a new import")

prepare_start = gate_text.index("prepare_linux_platform_lane_sync()")
prepare_end = gate_text.index("run_linux_manual_join_ui_gate()", prepare_start)
prepare = gate_text[prepare_start:prepare_end]
sync = prepare.index("./scripts/ubuntu-vm-git-sync.sh")
recover = prepare.index("ubuntu_vm_recover_stale_imported_release_bundle")
build = prepare.index("prepare_host_linux_vm_bundle_and_record")
if not sync < recover < build:
    raise SystemExit(
        "Ubuntu stale recovery does not run before the expensive Linux build"
    )

cleanup_start = gate_text.index("release_gate_cleanup()")
cleanup_end = gate_text.index("\nmain()", cleanup_start)
cleanup = gate_text[cleanup_start:cleanup_end]
cancel = cleanup.index("release_gate_parallel_cancel_all")
recover = cleanup.index("ubuntu_vm_recover_stale_imported_release_bundle")
if not cancel < recover:
    raise SystemExit(
        "release cleanup does not recover Ubuntu after lane cancellation"
    )
PY

python3 - "$IMPORT_LIB" <<'PY'
import pathlib
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
start = text.index("ubuntu_vm_import_release_bundle()")
end = text.index("ubuntu_vm_cleanup_imported_release_bundle()", start)
importer = text[start:end]
guest = importer

required = (
    'harness_sha="${32}"',
    'harness_tree="${33}"',
    'rev-parse HEAD)" == "$harness_sha"',
    'rev-parse \'HEAD^{tree}\')" == "$harness_tree"',
)
for token in required:
    if token not in guest:
        raise SystemExit(f"guest harness source check lacks {token!r}")
for forbidden in (
    'rev-parse HEAD)" == "$app_sha"',
    'rev-parse \'HEAD^{tree}\')" == "$app_tree"',
):
    if forbidden in guest:
        raise SystemExit(
            "guest harness source is still compared to frozen product identity"
        )

product_check = importer.index(
    '"$release_root" "$app_sha" "$app_tree" "Ubuntu VM host bundle"'
)
harness_check = importer.index(
    '"$ROOT" "$harness_sha" "$harness_tree" "Ubuntu VM guest harness"'
)
artifact_verify = importer.index('verify-host-linux-vm-bundle.py')
guest_verify = importer.index('rev-parse HEAD)" == "$harness_sha"')
if not product_check < harness_check < artifact_verify < guest_verify:
    raise SystemExit(
        "product receipt and guest harness are not verified independently in order"
    )
PY

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
dockerfile_sha="$(printf '3%.0s' {1..64})"
payload_sha="$(printf '4%.0s' {1..64})"
container_image_id="sha256:$(printf '5%.0s' {1..64})"
rust_toolchain="1.95.0"
app_version="4.1.5"
fips_version="0.4.45"

safe_tar="$backup/native-output-safe.tar"
unsafe_tar="$backup/native-output-traversal.tar"
python3 - "$safe_tar" "$unsafe_tar" <<'PY'
import io
import sys
import tarfile

expected = (
    "builder-provenance.json",
    "cargo-version.txt",
    "cli-short-version.txt",
    "cli-verbose-version.txt",
    "deb-version.txt",
    "desktop_manual_join_e2e_fixture",
    "file.txt",
    "linux-Cargo.lock.committed",
    "linux-realized-cargo-lock-sha256.txt",
    "musl-cli-short-version.txt",
    "musl-cli-verbose-version.txt",
    "nostr-vpn",
    "nostr-vpn.deb",
    "nvpn",
    "nvpn-x86_64-unknown-linux-musl",
    "nvpn-x86_64-unknown-linux-musl.tar.gz",
    "root-Cargo.lock.committed",
    "root-realized-cargo-lock-sha256.txt",
    "rustc-version.txt",
)
with tarfile.open(sys.argv[1], "w:") as archive:
    for name in expected:
        raw = f"{name}\n".encode()
        info = tarfile.TarInfo(name)
        info.size = len(raw)
        archive.addfile(info, io.BytesIO(raw))
with tarfile.open(sys.argv[2], "w:") as archive:
    raw = b"escape\n"
    info = tarfile.TarInfo("../builder-provenance.json")
    info.size = len(raw)
    archive.addfile(info, io.BytesIO(raw))
PY
# shellcheck disable=SC1090
source "$NATIVE_BUILDER_LIB"
NVPN_HOST_LINUX_VM_NATIVE_BUILDER_HOST="release-builder"
NVPN_HOST_LINUX_VM_NATIVE_BUILDER_JUMP=""
NVPN_HOST_LINUX_VM_NATIVE_BUILDER_PROXY_COMMAND=""
host_linux_native_builder_commands \
  || fail "native builder rejected a location-neutral SSH alias"
NVPN_HOST_LINUX_VM_NATIVE_BUILDER_HOST="2001:db8::1"
if host_linux_native_builder_commands >/dev/null 2>&1; then
  fail "native builder accepted an ambiguous SCP IPv6 destination"
fi
NVPN_HOST_LINUX_VM_NATIVE_BUILDER_HOST="release-builder"
NVPN_HOST_LINUX_VM_NATIVE_BUILDER_JUMP="ssh-jump"
NVPN_HOST_LINUX_VM_NATIVE_BUILDER_PROXY_COMMAND="ssh -W %h:%p ssh-jump"
if host_linux_native_builder_commands >/dev/null 2>&1; then
  fail "native builder accepted both jump and proxy transports"
fi
NVPN_HOST_LINUX_VM_NATIVE_BUILDER_JUMP=""
NVPN_HOST_LINUX_VM_NATIVE_BUILDER_PROXY_COMMAND=""
NVPN_HOST_LINUX_NATIVE_REMOTE_DIR="/tmp/nvpn-linux-native-builder.abc123/escape"
if host_linux_native_builder_cleanup_remote >/dev/null 2>&1; then
  fail "native builder accepted an unsafe remote cleanup path"
fi
NVPN_HOST_LINUX_NATIVE_REMOTE_DIR=""
mkdir "$backup/native-output-safe"
host_linux_native_builder_extract_output \
  "$safe_tar" "$backup/native-output-safe"
[[ "$(find "$backup/native-output-safe" -type f | wc -l | tr -d ' ')" == 19 ]] \
  || fail "safe native output import did not preserve the exact member set"
mkdir "$backup/native-output-traversal"
if host_linux_native_builder_extract_output \
  "$unsafe_tar" "$backup/native-output-traversal" >/dev/null 2>&1
then
  fail "native output import accepted a traversal member"
fi
mkdir "$backup/native-output-symlink"
ln -s "$backup/escape-target" \
  "$backup/native-output-symlink/builder-provenance.json"
if host_linux_native_builder_extract_output \
  "$safe_tar" "$backup/native-output-symlink" >/dev/null 2>&1
then
  fail "native output import followed a preexisting destination symlink"
fi

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
python3 "$PATCH_LOCK_VERIFIER" \
  --materialize "$lock_test/committed.lock" \
  "$lock_test/materialized.lock" "${patch_specs[@]}" >/dev/null
cmp -s "$lock_test/materialized.lock" "$lock_test/realized.lock" \
  || fail "exact FIPS patch lock materialization changed canonical bytes"
if python3 "$PATCH_LOCK_VERIFIER" \
  --materialize "$lock_test/committed.lock" \
  "$lock_test/materialized.lock" "${patch_specs[@]}" >/dev/null 2>&1
then
  fail "exact FIPS patch lock materialization replaced an existing output"
fi
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

cargo_cache_test="$backup/cargo-cache-adversary"
mkdir -p \
  "$cargo_cache_test/cache-parent" \
  "$cargo_cache_test/home/registry/cache/index.crates.io-1949cf8c6b5b557f"
printf 'exact crate archive\n' >"$cargo_cache_test/exact-1.0.0.crate"
cargo_cache_checksum="$(
  shasum -a 256 "$cargo_cache_test/exact-1.0.0.crate" | awk '{print $1}'
)"
cat >"$cargo_cache_test/Cargo.lock" <<EOF
version = 4

[[package]]
name = "exact"
version = "1.0.0"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "$cargo_cache_checksum"
EOF
cp "$cargo_cache_test/exact-1.0.0.crate" \
  "$cargo_cache_test/home/registry/cache/index.crates.io-1949cf8c6b5b557f/"
mkdir -p \
  "$cargo_cache_test/home/registry/src/index.crates.io-1949cf8c6b5b557f/exact-1.0.0"
printf 'Cargo 1.95 extracted source without a legacy checksum manifest\n' \
  >"$cargo_cache_test/home/registry/src/index.crates.io-1949cf8c6b5b557f/exact-1.0.0/lib.rs"
python3 "$CARGO_CACHE_VERIFIER" store \
  "$cargo_cache_test/cache-parent/exact" \
  "$cargo_cache_test/home" \
  "$cargo_cache_test/Cargo.lock" "$cargo_cache_test/Cargo.lock"
[[ ! -e "$cargo_cache_test/home/registry/src" \
  && ! -L "$cargo_cache_test/home/registry/src" ]] \
  || fail "Cargo download cache retained realized registry sources"
cache_manifest="$cargo_cache_test/cache-parent/exact/manifest.json"
cache_manifest_real="$cargo_cache_test/cache-parent/manifest.json.real"
mv "$cache_manifest" "$cache_manifest_real"
ln -s ../manifest.json.real "$cache_manifest"
mkdir "$cargo_cache_test/symlinked-manifest-seed"
if python3 "$CARGO_CACHE_VERIFIER" seed \
  "$cargo_cache_test/cache-parent/exact" \
  "$cargo_cache_test/symlinked-manifest-seed" \
  "$cargo_cache_test/Cargo.lock" "$cargo_cache_test/Cargo.lock" \
  >/dev/null 2>&1
then
  fail "Cargo download cache accepted a symlinked manifest"
fi
unlink "$cache_manifest"
mv "$cache_manifest_real" "$cache_manifest"
mkdir "$cargo_cache_test/seeded"
python3 "$CARGO_CACHE_VERIFIER" seed \
  "$cargo_cache_test/cache-parent/exact" \
  "$cargo_cache_test/seeded" \
  "$cargo_cache_test/Cargo.lock" "$cargo_cache_test/Cargo.lock"
printf '[build]\nrustc-wrapper = "/tmp/forged-wrapper"\n' \
  >"$cargo_cache_test/seeded/config.toml"
if python3 "$CARGO_CACHE_VERIFIER" audit \
  "$cargo_cache_test/cache-parent/exact" \
  "$cargo_cache_test/seeded" \
  "$cargo_cache_test/Cargo.lock" "$cargo_cache_test/Cargo.lock" \
  >/dev/null 2>&1
then
  fail "fresh Cargo home accepted an injected config.toml surface"
fi
unlink "$cargo_cache_test/seeded/config.toml"
cache_archive="$cargo_cache_test/cache-parent/exact/exact-1.0.0.crate"
chmod u+w "$cache_archive"
printf 'forged crate archive\n' >"$cache_archive"
chmod 0444 "$cache_archive"
mkdir "$cargo_cache_test/forged-seed"
if python3 "$CARGO_CACHE_VERIFIER" seed \
  "$cargo_cache_test/cache-parent/exact" \
  "$cargo_cache_test/forged-seed" \
  "$cargo_cache_test/Cargo.lock" "$cargo_cache_test/Cargo.lock" \
  >/dev/null 2>&1
then
  fail "Cargo download cache accepted forged archive bytes"
fi

source_audit_test="$backup/source-audit-adversary"
mkdir -p "$source_audit_test/pristine/linux"
git -C "$source_audit_test/pristine" init -q
printf 'committed root\n' >"$source_audit_test/pristine/Cargo.lock"
printf 'committed linux\n' >"$source_audit_test/pristine/linux/Cargo.lock"
printf 'exact source\n' >"$source_audit_test/pristine/source.txt"
printf '*.ignored\n' >"$source_audit_test/pristine/.gitignore"
git -C "$source_audit_test/pristine" add \
  .gitignore Cargo.lock linux/Cargo.lock source.txt
git -C "$source_audit_test/pristine" \
  -c user.name=test -c user.email=test@example.invalid \
  commit -qm exact
git clone -q "$source_audit_test/pristine" "$source_audit_test/build"
printf 'realized root\n' >"$source_audit_test/build/Cargo.lock"
printf 'realized linux\n' >"$source_audit_test/build/linux/Cargo.lock"
source_audit_sha="$(git -C "$source_audit_test/pristine" rev-parse HEAD)"
source_audit_tree="$(
  git -C "$source_audit_test/pristine" rev-parse 'HEAD^{tree}'
)"
source_audit_root_lock="$(
  shasum -a 256 "$source_audit_test/build/Cargo.lock" | awk '{print $1}'
)"
source_audit_linux_lock="$(
  shasum -a 256 "$source_audit_test/build/linux/Cargo.lock" | awk '{print $1}'
)"
python3 "$SOURCE_AUDITOR" \
  "$source_audit_test/pristine" "$source_audit_test/build" \
  "$source_audit_sha" "$source_audit_tree" \
  "$source_audit_root_lock" "$source_audit_linux_lock" >/dev/null
printf 'ignored source injection\n' \
  >"$source_audit_test/pristine/injected.ignored"
printf 'ignored source injection\n' \
  >"$source_audit_test/build/injected.ignored"
if python3 "$SOURCE_AUDITOR" \
  "$source_audit_test/pristine" "$source_audit_test/build" \
  "$source_audit_sha" "$source_audit_tree" \
  "$source_audit_root_lock" "$source_audit_linux_lock" \
  >/dev/null 2>&1
then
  fail "post-build source audit accepted identical ignored source injection"
fi
rm \
  "$source_audit_test/pristine/injected.ignored" \
  "$source_audit_test/build/injected.ignored"
for checkout in pristine build; do
  git -C "$source_audit_test/$checkout" \
    update-index --assume-unchanged source.txt
  printf 'status-hidden source injection\n' \
    >"$source_audit_test/$checkout/source.txt"
done
[[ -z "$(git -C "$source_audit_test/pristine" \
  status --porcelain --untracked-files=all)" ]]
if python3 "$SOURCE_AUDITOR" \
  "$source_audit_test/pristine" "$source_audit_test/build" \
  "$source_audit_sha" "$source_audit_tree" \
  "$source_audit_root_lock" "$source_audit_linux_lock" \
  >/dev/null 2>&1
then
  fail "post-build source audit trusted status-hidden transformed source"
fi
for checkout in pristine build; do
  git -C "$source_audit_test/$checkout" \
    update-index --no-assume-unchanged source.txt
  git -C "$source_audit_test/$checkout" checkout -- source.txt
done
printf 'forged output\n' >"$source_audit_test/build/target-forged"
if python3 "$SOURCE_AUDITOR" \
  "$source_audit_test/pristine" "$source_audit_test/build" \
  "$source_audit_sha" "$source_audit_tree" \
  "$source_audit_root_lock" "$source_audit_linux_lock" \
  >/dev/null 2>&1
then
  fail "post-build source audit accepted a forged untracked output"
fi

python3 - \
  "$tmp" "$ROOT" "$app_sha" "$app_tree" "$app_version" \
  "$fips_sha" "$fips_tree" "$fips_version" \
  "$root_lock_sha" "$root_realized_lock_sha" \
  "$linux_lock_sha" "$linux_realized_lock_sha" \
  "$dockerfile_sha" "$payload_sha" "$container_image_id" \
  "$rust_toolchain" \
  "${patch_specs[@]}" <<'PY'
import hashlib
import io
import json
import os
import pathlib
import sys
import tarfile

root = pathlib.Path(sys.argv[1])
repo_root = pathlib.Path(sys.argv[2])
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
    dockerfile_sha,
    payload_sha,
    container_image_id,
    rust_toolchain,
    fips_core_patch_spec,
    fips_endpoint_patch_spec,
    fips_identity_patch_spec,
) = sys.argv[3:]
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
archive_path = root / "nvpn-x86_64-unknown-linux-musl.tar.gz"
with tarfile.open(
    archive_path, "w:gz", format=tarfile.USTAR_FORMAT
) as archive:
    for name, raw, mode in (
        ("nvpn/README.txt", b"nvpn - FIPS private mesh CLI\n", 0o644),
        (
            "nvpn/install.sh",
            b"#!/bin/bash\n"
            b"set -e\n"
            b'install -d "${1:-/usr/local/bin}"\n'
            b'install -m 755 nvpn "${1:-/usr/local/bin}/"\n',
            0o555,
        ),
        (
            "nvpn/nvpn",
            (root / executables["muslCli"]).read_bytes(),
            0o555,
        ),
    ):
        info = tarfile.TarInfo(name)
        info.size = len(raw)
        info.mode = mode
        info.mtime = 1
        info.uid = 0
        info.gid = 0
        info.uname = ""
        info.gname = ""
        archive.addfile(info, io.BytesIO(raw))
archive_path.chmod(0o444)
artifacts["muslCliArchive"] = {
    "file": archive_path.name,
    "sha256": hashlib.sha256(archive_path.read_bytes()).hexdigest(),
    "size": archive_path.stat().st_size,
}

data_files = {
    "./usr/bin/nostr-vpn": (
        (root / executables["app"]).read_bytes(),
        0o755,
    ),
    "./usr/bin/nvpn": (
        (root / executables["cli"]).read_bytes(),
        0o755,
    ),
    "./usr/share/applications/nostr-vpn.desktop": (
        (repo_root / "linux/resources/nostr-vpn.desktop").read_bytes(),
        0o644,
    ),
    "./usr/share/doc/nostr-vpn/copyright": (
        b"Format: https://www.debian.org/doc/packaging-manuals/"
        b"copyright-format/1.0/\n"
        b"Upstream-Name: nostr-vpn-linux\n"
        b"Copyright: Nostr VPN\n"
        b"License: UNLICENSED\n",
        0o644,
    ),
}
for size in (16, 22, 24, 32, 48, 64, 128, 256, 512):
    data_files[
        f"./usr/share/icons/hicolor/{size}x{size}/apps/nostr-vpn.png"
    ] = (
        (repo_root / f"linux/resources/nostr-vpn-{size}.png").read_bytes(),
        0o644,
    )
data_directories = set()
for name in data_files:
    parts = name.removeprefix("./").split("/")[:-1]
    for length in range(1, len(parts) + 1):
        data_directories.add(f"./{'/'.join(parts[:length])}")
installed_size = sum(
    1 + (len(raw) + 1023) // 1024 for raw, _mode in data_files.values()
)
depends = (
    "curl, libadwaita-1-0 (>= 1.5~beta), libc6 (>= 2.39), "
    "libcairo2 (>= 1.2.4), libdbus-1-3 (>= 1.9.14), "
    "libglib2.0-0t64 (>= 2.54.0), libgtk-4-1 (>= 4.12.0), "
    "xdg-utils, zbar-tools"
)
control = (
    "Package: nostr-vpn\n"
    f"Version: {app_version}-1\n"
    "Architecture: amd64\n"
    "Section: net\n"
    "Priority: optional\n"
    "Maintainer: Nostr VPN\n"
    f"Installed-Size: {installed_size}\n"
    f"Depends: {depends}\n"
    "Description: Simple private networks over FIPS and Nostr.\n"
    " Simple private networks over FIPS and Nostr.\n\n"
).encode()


def tar_xz(entries):
    output = io.BytesIO()
    with tarfile.open(
        fileobj=output, mode="w:xz", format=tarfile.USTAR_FORMAT
    ) as archive:
        for name, raw, mode, kind in entries:
            info = tarfile.TarInfo(name)
            info.size = len(raw)
            info.mode = mode
            info.mtime = 1
            info.uid = 0
            info.gid = 0
            info.uname = ""
            info.gname = ""
            info.type = tarfile.DIRTYPE if kind == "dir" else tarfile.REGTYPE
            archive.addfile(info, None if kind == "dir" else io.BytesIO(raw))
    return output.getvalue()


control_tar = tar_xz([("./control", control, 0o644, "file")])
data_entries = [
    (name, b"", 0o755, "dir") for name in sorted(data_directories)
] + [
    (name, raw, mode, "file")
    for name, (raw, mode) in sorted(data_files.items())
]
data_tar = tar_xz(data_entries)


def ar_member(name, raw):
    header = (
        f"{name + '/':<16}"
        f"{1:<12}"
        f"{0:<6}"
        f"{0:<6}"
        f"{format(0o100644, 'o'):<8}"
        f"{len(raw):<10}"
        "`\n"
    ).encode("ascii")
    return header + raw + (b"\n" if len(raw) % 2 else b"")


deb = root / "nostr-vpn.deb"
deb.write_bytes(
    b"!<arch>\n"
    + ar_member("debian-binary", b"2.0\n")
    + ar_member("control.tar.xz", control_tar)
    + ar_member("data.tar.xz", data_tar)
)
deb.chmod(0o444)
artifacts["debianPackage"] = {
    "file": deb.name,
    "sha256": hashlib.sha256(deb.read_bytes()).hexdigest(),
    "size": deb.stat().st_size,
}
receipt = {
    "schema": 2,
    "builderMode": "remote-native",
    "builtOnHostMac": False,
    "builtOnRemoteVm": True,
    "builderHostOs": "Linux",
    "builderHostArchitecture": "x86_64",
    "containerImageId": container_image_id,
    "dockerfileSha256": dockerfile_sha,
    "containerPayloadSha256": payload_sha,
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
    "rustcVersion": f"rustc {rust_toolchain} (test)",
    "cargoVersion": f"cargo {rust_toolchain} (test)",
    "cliShortVersion": f"nvpn {app_version}",
    "cliVerboseVersion": f"fips_core: {fips_version} (rev {fips_sha[:10]})",
    "muslCliShortVersion": f"nvpn {app_version}",
    "muslCliVerboseVersion":
        f"fips_core: {fips_version} (rev {fips_sha[:10]})",
    "muslTarget": "x86_64-unknown-linux-musl",
    "cargoDebVersion": "3.7.0",
    "debianPackage": {
        "package": "nostr-vpn",
        "version": f"{app_version}-1",
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
verify_fixture() {
  local mode="$1"
  python3 "$VERIFIER" \
    "$tmp" "$tmp/receipt.json" \
    "$app_sha" "$app_tree" "$app_version" \
    "$fips_sha" "$fips_tree" "$fips_version" \
    "$root_lock_sha" "$root_realized_lock_sha" \
    "$linux_lock_sha" "$linux_realized_lock_sha" \
    x86_64-unknown-linux-gnu "$mode" "$rust_toolchain" \
    "$dockerfile_sha" "$payload_sha" "${patch_specs[@]}"
}

verify_fixture remote-native \
  | grep -Fq HOST_LINUX_VM_BUNDLE_VERIFIED

cp "$tmp/receipt.json" "$backup/receipt-canonical-remote-native.json"
for adversary in \
  schema \
  builder-mode \
  host-flag \
  remote-flag \
  builder-os \
  builder-architecture \
  dockerfile \
  payload
do
  python3 - "$tmp/receipt.json" "$adversary" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
case = sys.argv[2]
receipt = json.loads(path.read_text(encoding="utf-8"))
mutations = {
    "schema": ("schema", 1),
    "builder-mode": ("builderMode", "local-docker"),
    "host-flag": ("builtOnHostMac", True),
    "remote-flag": ("builtOnRemoteVm", False),
    "builder-os": ("builderHostOs", "Darwin"),
    "builder-architecture": ("builderHostArchitecture", "arm64"),
    "dockerfile": ("dockerfileSha256", "0" * 64),
    "payload": ("containerPayloadSha256", "0" * 64),
}
key, value = mutations[case]
receipt[key] = value
path.write_text(
    json.dumps(receipt, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY
  if verify_fixture remote-native >/dev/null 2>&1; then
    fail "bundle verifier accepted forged $adversary builder provenance"
  fi
  cp "$backup/receipt-canonical-remote-native.json" "$tmp/receipt.json"
done

python3 - "$tmp/receipt.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
receipt = json.loads(path.read_text(encoding="utf-8"))
receipt.update(
    {
        "builderMode": "local-docker",
        "builtOnHostMac": True,
        "builtOnRemoteVm": False,
        "builderHostOs": "Darwin",
        "builderHostArchitecture": "x86_64",
    }
)
path.write_text(
    json.dumps(receipt, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY
verify_fixture local-docker >/dev/null \
  || fail "bundle verifier rejected exact local Docker provenance"
python3 - "$tmp/receipt.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
receipt = json.loads(path.read_text(encoding="utf-8"))
receipt["builderHostArchitecture"] = "arm64"
path.write_text(json.dumps(receipt), encoding="utf-8")
PY
if verify_fixture local-docker >/dev/null 2>&1; then
  fail "bundle verifier accepted an emulated arm64 local-docker amd64 build"
fi
cp "$backup/receipt-canonical-remote-native.json" "$tmp/receipt.json"

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
  x86_64-unknown-linux-gnu remote-native "$rust_toolchain" \
  "$dockerfile_sha" "$payload_sha" "${patch_specs[@]}" \
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
  x86_64-unknown-linux-gnu remote-native "$rust_toolchain" \
  "$dockerfile_sha" "$payload_sha" "${patch_specs[@]}" \
  >/dev/null 2>&1
then
  fail "bundle verifier accepted a glibc CLI mislabeled as static musl"
fi
mv "$backup/receipt.json" "$tmp/receipt.json"
mv "$backup/archive.tar.gz" \
  "$tmp/nvpn-x86_64-unknown-linux-musl.tar.gz"

# A self-consistent receipt must not bless changed installer bytes or modes:
# every public archive member is part of the release payload.
cp "$tmp/receipt.json" "$backup/receipt-before-archive-content-adversary.json"
cp "$tmp/nvpn-x86_64-unknown-linux-musl.tar.gz" \
  "$backup/archive-before-content-adversary.tar.gz"
chmod u+w "$tmp/nvpn-x86_64-unknown-linux-musl.tar.gz"
python3 - \
  "$tmp/receipt.json" \
  "$tmp/nvpn-x86_64-unknown-linux-musl.tar.gz" <<'PY'
import hashlib
import io
import json
import pathlib
import sys
import tarfile

receipt_path = pathlib.Path(sys.argv[1])
archive_path = pathlib.Path(sys.argv[2])
with tarfile.open(archive_path, "r:gz") as archive:
    members = {
        member.name: (archive.extractfile(member).read(), member.mode)
        for member in archive.getmembers()
    }
members["nvpn/install.sh"] = (b"#!/bin/sh\nexit 0\n", 0o755)
with tarfile.open(archive_path, "w:gz") as archive:
    for name in ("nvpn/README.txt", "nvpn/install.sh", "nvpn/nvpn"):
        raw, mode = members[name]
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
if verify_fixture remote-native >/dev/null 2>&1; then
  fail "bundle verifier accepted self-consistent forged archive installer bytes"
fi
mv "$backup/receipt-before-archive-content-adversary.json" "$tmp/receipt.json"
mv "$backup/archive-before-content-adversary.tar.gz" \
  "$tmp/nvpn-x86_64-unknown-linux-musl.tar.gz"

cp "$tmp/receipt.json" "$backup/receipt-before-archive-mode-adversary.json"
cp "$tmp/nvpn-x86_64-unknown-linux-musl.tar.gz" \
  "$backup/archive-before-mode-adversary.tar.gz"
chmod u+w "$tmp/nvpn-x86_64-unknown-linux-musl.tar.gz"
python3 - \
  "$tmp/receipt.json" \
  "$tmp/nvpn-x86_64-unknown-linux-musl.tar.gz" <<'PY'
import hashlib
import io
import json
import pathlib
import sys
import tarfile

receipt_path = pathlib.Path(sys.argv[1])
archive_path = pathlib.Path(sys.argv[2])
with tarfile.open(archive_path, "r:gz") as archive:
    entries = []
    for member in archive.getmembers():
        content = archive.extractfile(member).read()
        if member.name == "nvpn/install.sh":
            member.mode = 0o755
        entries.append((member, content))
with tarfile.open(
    archive_path, "w:gz", format=tarfile.USTAR_FORMAT
) as archive:
    for member, content in entries:
        archive.addfile(member, io.BytesIO(content))
receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
entry = receipt["artifacts"]["muslCliArchive"]
entry["sha256"] = hashlib.sha256(archive_path.read_bytes()).hexdigest()
entry["size"] = archive_path.stat().st_size
receipt_path.write_text(json.dumps(receipt), encoding="utf-8")
PY
if verify_fixture remote-native >/dev/null 2>&1; then
  fail "bundle verifier accepted a self-consistent archive mode mutation"
fi
mv "$backup/receipt-before-archive-mode-adversary.json" "$tmp/receipt.json"
mv "$backup/archive-before-mode-adversary.tar.gz" \
  "$tmp/nvpn-x86_64-unknown-linux-musl.tar.gz"

# The DEB must be parsed and completely allowlisted before dpkg can execute it.
# Both attacks update the outer package hash and receipt self-consistently.
cp "$tmp/receipt.json" "$backup/receipt-before-deb-adversary.json"
cp "$tmp/nostr-vpn.deb" "$backup/deb-before-adversary.deb"
for deb_adversary in preinst setuid-extra; do
  cp "$backup/receipt-before-deb-adversary.json" "$tmp/receipt.json"
  chmod u+w "$tmp/nostr-vpn.deb"
  cp "$backup/deb-before-adversary.deb" "$tmp/nostr-vpn.deb"
  python3 - \
    "$tmp/receipt.json" "$tmp/nostr-vpn.deb" "$deb_adversary" <<'PY'
import hashlib
import io
import json
import lzma
import pathlib
import sys
import tarfile

receipt_path = pathlib.Path(sys.argv[1])
deb_path = pathlib.Path(sys.argv[2])
case = sys.argv[3]
raw_deb = deb_path.read_bytes()
if not raw_deb.startswith(b"!<arch>\n"):
    raise SystemExit("test DEB is not ar")
offset = 8
members = []
while offset < len(raw_deb):
    header = raw_deb[offset : offset + 60]
    offset += 60
    name = header[:16].decode("ascii").strip().removesuffix("/")
    size = int(header[48:58].decode("ascii").strip())
    members.append((name, raw_deb[offset : offset + size]))
    offset += size + size % 2
by_name = dict(members)
target = "control.tar.xz" if case == "preinst" else "data.tar.xz"
with tarfile.open(
    fileobj=io.BytesIO(lzma.decompress(by_name[target])), mode="r:"
) as source:
    entries = []
    for member in source.getmembers():
        content = source.extractfile(member).read() if member.isfile() else b""
        entries.append((member, content))
extra = tarfile.TarInfo(
    "./preinst" if case == "preinst" else "./usr/bin/extra-root"
)
extra.mode = 0o755 if case == "preinst" else 0o4755
extra.mtime = 1
extra.uid = 0
extra.gid = 0
extra.uname = ""
extra.gname = ""
extra_content = b"#!/bin/sh\nexit 0\n"
extra.size = len(extra_content)
entries.append((extra, extra_content))
rebuilt = io.BytesIO()
with tarfile.open(
    fileobj=rebuilt, mode="w:xz", format=tarfile.USTAR_FORMAT
) as archive:
    for member, content in entries:
        archive.addfile(
            member,
            io.BytesIO(content) if member.isfile() else None,
        )
by_name[target] = rebuilt.getvalue()


def ar_member(name, raw):
    header = (
        f"{name + '/':<16}"
        f"{1:<12}"
        f"{0:<6}"
        f"{0:<6}"
        f"{format(0o100644, 'o'):<8}"
        f"{len(raw):<10}"
        "`\n"
    ).encode("ascii")
    return header + raw + (b"\n" if len(raw) % 2 else b"")


deb_path.write_bytes(
    b"!<arch>\n"
    + b"".join(ar_member(name, by_name[name]) for name, _raw in members)
)
receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
entry = receipt["artifacts"]["debianPackage"]
entry["sha256"] = hashlib.sha256(deb_path.read_bytes()).hexdigest()
entry["size"] = deb_path.stat().st_size
receipt_path.write_text(
    json.dumps(receipt, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY
  if verify_fixture remote-native >/dev/null 2>&1; then
    fail "bundle verifier accepted a self-consistent DEB $deb_adversary payload"
  fi
done
mv "$backup/receipt-before-deb-adversary.json" "$tmp/receipt.json"
mv "$backup/deb-before-adversary.deb" "$tmp/nostr-vpn.deb"

chmod u+w "$tmp/nvpn"
printf x >>"$tmp/nvpn"
if python3 "$VERIFIER" \
  "$tmp" "$tmp/receipt.json" \
  "$app_sha" "$app_tree" "$app_version" \
  "$fips_sha" "$fips_tree" "$fips_version" \
  "$root_lock_sha" "$root_realized_lock_sha" \
  "$linux_lock_sha" "$linux_realized_lock_sha" \
  x86_64-unknown-linux-gnu remote-native "$rust_toolchain" \
  "$dockerfile_sha" "$payload_sha" "${patch_specs[@]}" \
  >/dev/null 2>&1
then
  fail "bundle verifier accepted a post-receipt CLI mutation"
fi

echo "HOST_LINUX_VM_IMPORT_ONLY_CONTRACT_OK"
