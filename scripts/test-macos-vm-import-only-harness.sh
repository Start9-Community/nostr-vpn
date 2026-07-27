#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

files=(
  "$ROOT/scripts/macos-vm-release-mobile-join-e2e.sh"
  "$ROOT/scripts/macos-release-mobile-join-remote.sh"
  "$ROOT/scripts/macos-vm-manual-join-e2e.sh"
  "$ROOT/scripts/macos-vm-service-toggle-e2e.sh"
  "$ROOT/scripts/macos-vm-desktop-app-launch-smoke.sh"
  "$ROOT/scripts/macos-vm-desktop-wireguard-exit-e2e.sh"
  "$ROOT/scripts/macos-vm-desktop-daemon-idle-e2e.sh"
  "$ROOT/scripts/e2e-macos-release-network.sh"
  "$ROOT/scripts/e2e-macos-manual-join-ui.sh"
  "$ROOT/scripts/e2e-macos-service-toggle.sh"
  "$ROOT/scripts/macos-app-launch-smoke.sh"
  "$ROOT/scripts/e2e-wireguard-exit-host.sh"
  "$ROOT/scripts/e2e-macos-service.sh"
  "$ROOT/scripts/release-gate.sh"
)
for file in "${files[@]}"; do
  bash -n "$file"
done
python3 -B "$ROOT/scripts/macos_release_join_artifact.py" --help >/dev/null
# shellcheck disable=SC1091
source "$ROOT/scripts/lib-macos-vm-imported-release.sh"
[[ "$(macos_vm_imported_release_package "src/nostr-vpn")" \
  == "artifacts/macos-release-mobile-join/imported" ]]
[[ "$(macos_vm_imported_release_package "/tmp/src/nostr-vpn")" \
  == "/tmp/src/nostr-vpn/artifacts/macos-release-mobile-join/imported" ]]

python3 - "${files[@]}" "$ROOT/scripts/macos_release_join_artifact.py" \
  "$ROOT/scripts/macos-build" <<'PY'
import pathlib
import sys

paths = [pathlib.Path(value) for value in sys.argv[1:]]
texts = {path.name: path.read_text(encoding="utf-8") for path in paths}

host = texts["macos-vm-release-mobile-join-e2e.sh"]
remote = texts["macos-release-mobile-join-remote.sh"]
artifact = texts["macos_release_join_artifact.py"]
macos_build = texts["macos-build"]
release_gate = texts["release-gate.sh"]

for required in (
    'git -C "$ROOT" archive --format=tar "$APP_GIT_SHA"',
    'git clone --quiet --no-checkout --no-hardlinks',
    'checkout --quiet --detach "$RELEASE_JOIN_FIPS_SHA"',
    'NVPN_FIPS_REPO_PATH="$HOST_FIPS_ROOT"',
    '--fips-root "$HOST_FIPS_ROOT"',
    '"$HOST_BUILD_ROOT/scripts/macos-build" macos-app',
    '"$HOST_BUILD_ROOT/scripts/macos-build" macos-gate-support',
    "desktop_manual_join_e2e_fixture",
    "desktop-manual-join-ax",
    "macos-service-toggle-ax",
    "codesign --force",
    "ditto -c -k --sequesterRsrc --keepParent",
    "macos_release_join_artifact.py\" create",
):
    if required not in host:
        raise SystemExit(f"host macOS gate package is missing {required}")

for required in (
    "macos-gate-support",
    "swiftc",
    "desktop_manual_join_e2e_fixture",
):
    if required not in macos_build:
        raise SystemExit(f"host macOS support build is missing {required}")

for required in (
    "packageTreeSha256",
    "appExecutableSha256",
    "cliExecutableSha256",
    "manualJoinFixtureSha256",
    "manualJoinDriverSha256",
    "serviceToggleDriverSha256",
    "manualJoinFixtureCodeDirectoryHash",
    "manualJoinDriverCodeDirectoryHash",
    "serviceToggleDriverCodeDirectoryHash",
    "tree_sha256(package)",
):
    if required not in artifact:
        raise SystemExit(f"macOS gate receipt omits {required}")

for forbidden in (
    "cargo build",
    "xcodebuild",
    "macos-build",
    "codesign --force",
    "/usr/bin/swift",
    "swift -e",
    "swiftc",
):
    if forbidden in remote:
        raise SystemExit(f"macOS artifact importer can execute VM-side {forbidden}")
for required in (
    "ditto -x -k",
    "macos_release_join_artifact.py\" validate",
    "verify-import",
    "verification.json",
):
    if required not in remote:
        raise SystemExit(f"macOS artifact importer is missing {required}")

wrapper_contracts = {
    "macos-vm-manual-join-e2e.sh": (
        "NVPN_MACOS_VM_IMPORT_ONLY=1",
        "NVPN_MACOS_APP_PATH=",
        "NVPN_DESKTOP_MANUAL_JOIN_FIXTURE=",
        "NVPN_DESKTOP_MANUAL_JOIN_DRIVER=",
    ),
    "macos-vm-service-toggle-e2e.sh": (
        "NVPN_MACOS_VM_IMPORT_ONLY=1",
        "NVPN_MACOS_APP_PATH=",
        "NVPN_DESKTOP_SERVICE_TOGGLE_FIXTURE=",
        "NVPN_DESKTOP_SERVICE_TOGGLE_DRIVER=",
    ),
    "macos-vm-desktop-app-launch-smoke.sh": (
        "NVPN_MACOS_VM_IMPORT_ONLY=1",
        "NVPN_MACOS_APP_PATH=",
        "NVPN_MACOS_APP_SMOKE_BUILD=0",
        "NVPN_MACOS_APP_IDLE_CPU_SAMPLE_SECONDS=",
        "NVPN_MACOS_APP_IDLE_CPU_SETTLE_SECONDS=",
    ),
    "macos-vm-desktop-wireguard-exit-e2e.sh": (
        "NVPN_MACOS_VM_IMPORT_ONLY=1",
        "NVPN_E2E_BINARY=",
        "e2e-macos-release-network.sh",
    ),
    "macos-vm-desktop-daemon-idle-e2e.sh": (
        "NVPN_MACOS_VM_IMPORT_ONLY=1",
        "NVPN_E2E_BINARY=",
    ),
}
for name, required_values in wrapper_contracts.items():
    text = texts[name]
    if "macos_vm_prepare_or_verify_imported_release" not in text:
        raise SystemExit(f"{name} does not prepare/verify the host artifact")
    for required in required_values:
        if required not in text:
            raise SystemExit(f"{name} does not pass {required}")

import_only_children = {
    "e2e-macos-manual-join-ui.sh": (
        "NVPN_DESKTOP_MANUAL_JOIN_FIXTURE",
        "NVPN_DESKTOP_MANUAL_JOIN_DRIVER",
    ),
    "e2e-macos-service-toggle.sh": (
        "NVPN_DESKTOP_SERVICE_TOGGLE_FIXTURE",
        "NVPN_DESKTOP_SERVICE_TOGGLE_DRIVER",
    ),
    "macos-app-launch-smoke.sh": ("NVPN_MACOS_APP_SMOKE_BUILD=0",),
    "e2e-wireguard-exit-host.sh": ("NVPN_WG_EXIT_HOST_BINARY",),
    "e2e-macos-release-network.sh": ("NVPN_E2E_BINARY",),
    "e2e-macos-service.sh": ("NVPN_E2E_BINARY",),
}
for name, required_values in import_only_children.items():
    text = texts[name]
    if "NVPN_MACOS_VM_IMPORT_ONLY" not in text:
        raise SystemExit(f"{name} has no fail-closed VM import-only mode")
    for required in required_values:
        if required not in text:
            raise SystemExit(f"{name} import-only mode does not require {required}")
    for forbidden in ("/usr/bin/swift", "swift -e", "swiftc"):
        if forbidden in text:
            raise SystemExit(f"{name} can compile Swift on the VM through {forbidden}")

for name in (
    "e2e-macos-manual-join-ui.sh",
    "e2e-macos-service-toggle.sh",
):
    if "--check-accessibility" not in texts[name]:
        raise SystemExit(f"{name} does not use its imported AX driver for preflight")

if "codesign --force" in texts["e2e-macos-service-toggle.sh"]:
    raise SystemExit("service-toggle gate still re-signs a VM-side app copy")

for required in (
    "NVPN_MACOS_RELEASE_ARTIFACT_ACTION=prepare-only",
    "NVPN_MACOS_IMPORTED_RELEASE_ARTIFACT_READY=1",
    "NVPN_RELEASE_GATE_MACOS_WG_EXIT_E2E",
    "NVPN_RELEASE_GATE_MACOS_GUI_SMOKE",
    "NVPN_RELEASE_GATE_MACOS_DAEMON_IDLE_CPU",
):
    if required not in release_gate:
        raise SystemExit(f"release gate does not wire imported macOS artifacts: {required}")

for wrapper in wrapper_contracts:
    text = texts[wrapper]
    remote_index = text.find("remote_command=")
    if remote_index < 0:
        raise SystemExit(f"{wrapper} has no explicit remote command")
    remote_path = text[remote_index:]
    for forbidden in (
        "cargo build",
        "xcodebuild",
        "macos-build",
        "codesign --force",
        "/usr/bin/swift",
        "swift -e",
        "swiftc",
    ):
        if forbidden in remote_path:
            raise SystemExit(f"{wrapper} remote path contains {forbidden}")
PY

python3 - "$ROOT" <<'PY'
import argparse
import importlib.util
import pathlib
import sys
import tempfile

root = pathlib.Path(sys.argv[1])
sys.path.insert(0, str(root / "scripts"))
spec = importlib.util.spec_from_file_location(
    "macos_release_join_artifact",
    root / "scripts" / "macos_release_join_artifact.py",
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

signature = {
    "authority": "Developer ID Application: Test (ABCDEFGHIJ)",
    "cdhash": "1" * 40,
    "certificateSha1": "2" * 40,
    "certificateSha256": "3" * 64,
    "team": "ABCDEFGHIJ",
}
module.inspect_signature = lambda path, deep=False: dict(signature)
module.git_snapshot = lambda path: {
    "head": "4" * 40,
    "tree": "5" * 40,
    "manifest": "6" * 64,
}
module.fips_version = lambda path: "0.4.45"

with tempfile.TemporaryDirectory(prefix="nvpn-macos-import-harness.") as tmp:
    work = pathlib.Path(tmp)
    package = work / "package"
    app = package / "Nostr VPN.app"
    executable = app / "Contents" / "MacOS" / "Nostr VPN"
    cli = app / "Contents" / "Resources" / "nvpn"
    fixture = package / "fixtures" / "desktop_manual_join_e2e_fixture"
    manual = package / "drivers" / "desktop-manual-join-ax"
    service = package / "drivers" / "macos-service-toggle-ax"
    for path, payload in (
        (executable, b"app"),
        (cli, b"cli"),
        (fixture, b"fixture"),
        (manual, b"manual"),
        (service, b"service"),
    ):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(payload)
        path.chmod(0o755)
    archive = work / "package.zip"
    archive.write_bytes(b"archive")
    receipt = work / "receipt.json"
    verification = work / "verification.json"
    args = argparse.Namespace(
        receipt=str(receipt),
        package=str(package),
        app=str(app),
        archive=str(archive),
        manual_join_fixture=str(fixture),
        manual_join_driver=str(manual),
        service_toggle_driver=str(service),
        app_root=str(work / "app-source"),
        fips_root=str(work / "fips-source"),
        expected_app_head="4" * 40,
        expected_app_tree="5" * 40,
        expected_fips_head="4" * 40,
        expected_fips_tree="5" * 40,
        expected_fips_version="0.4.45",
        expected_team="ABCDEFGHIJ",
        expected_identity_sha1="2" * 40,
        expected_signer_sha256="3" * 64,
        verification_output=str(verification),
    )
    module.create_receipt(args)
    module.validate_receipt(args)
    for path in (executable, cli, fixture, manual, service):
        original = path.read_bytes()
        path.write_bytes(original + b"-tampered")
        try:
            module.validate_receipt(args)
        except ValueError:
            pass
        else:
            raise SystemExit(f"receipt accepted tampered imported artifact: {path.name}")
        path.write_bytes(original)
        path.chmod(0o755)
    fixture.chmod(0o700)
    try:
        module.validate_receipt(args)
    except ValueError:
        pass
    else:
        raise SystemExit("receipt accepted a changed imported fixture mode")
PY

"$ROOT/scripts/test-macos-release-app-ownership-harness.sh"

echo "macOS VM host-build/import-only contract passed"
