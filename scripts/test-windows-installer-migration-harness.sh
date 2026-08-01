#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$ROOT" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
installer = (root / "scripts/windows-installer.iss").read_text(encoding="utf-8")
migration = (root / "windows/installer/windows-installer-migrate.ps1").read_text(encoding="utf-8")
tests = (root / "windows/installer/windows-installer-migrate.tests.ps1").read_text(encoding="utf-8")
view_model = (root / "windows/NostrVpn.Windows/ViewModels/AppViewModel.cs").read_text(encoding="utf-8")
service_e2e = (root / "scripts/e2e-windows-service-toggle.ps1").read_text(encoding="utf-8")
windows_smoke = (root / "scripts/windows-vm-app-launch-smoke.sh").read_text(encoding="utf-8")

required_installer = (
    "CloseApplicationsFilter=NostrVpn.Windows.exe,nostr-vpn-gui.exe",
    "Flags: dontcopy",
    "function PrepareToInstall",
    "ewWaitUntilTerminated",
    "ResultCode <> 0",
    "avoid installing a second copy",
)
for value in required_installer:
    if value not in installer:
        raise SystemExit(f"installer migration integration is missing: {value}")

required_migration = (
    "HKEY_LOCAL_MACHINE",
    "WOW6432Node",
    "HKEY_CURRENT_USER",
    "nostr-vpn-gui.exe",
    "NostrVpn.Windows.exe",
    "Resolve-NvpnOwnedRegistration",
    "Invoke-NvpnOwnedUninstall",
    "RequiresElevation",
    "Refusing an uninstaller outside",
    "registration survived its uninstaller",
    "executable survived its uninstaller",
)
for value in required_migration:
    if value not in migration:
        raise SystemExit(f"installer migration implementation is missing: {value}")

for value in (
    "Program Files\\Nostr VPN",
    "LocalAppData\\Programs\\Nostr VPN",
    "Roaming\\Nostr VPN",
    "Migration changed roaming config data",
    "outside legacy uninstaller",
    "failed current uninstaller",
):
    if value not in tests:
        raise SystemExit(f"seeded migration test is missing: {value}")

if "CanToggleVpn(" not in view_model:
    raise SystemExit("ToggleVpnCommand does not use the focused policy")
expression = "hasRuntimeActiveNetwork || (serviceSupported && !serviceInstalled)"
if expression not in view_model:
    raise SystemExit("ToggleVpnCommand still requires an active network when the service is missing")

def can_toggle(in_flight, supported, has_network, service_supported, installed):
    return (
        not in_flight
        and supported
        and (has_network or (service_supported and not installed))
    )

cases = (
    ((False, True, False, True, False), True, "missing service without network"),
    ((False, True, True, True, True), True, "installed service with network"),
    ((False, True, False, True, True), False, "installed service without network"),
    ((True, True, False, True, False), False, "action already running"),
    ((False, False, False, True, False), False, "VPN control unsupported"),
)
for inputs, expected, label in cases:
    actual = can_toggle(*inputs)
    if actual is not expected:
        raise SystemExit(f"toggle policy failed {label}: {actual} != {expected}")

if "desktop_roster_e2e_fixture" in service_e2e:
    raise SystemExit("service-toggle E2E still seeds an active network")
for value in (
    "New-Item -ItemType Directory -Force -Path $DataDir",
    "if (!$Toggle.Current.IsEnabled)",
    "supported service is missing",
):
    if value not in service_e2e:
        raise SystemExit(f"service-toggle no-network E2E is missing: {value}")

if "windows-installer-migrate.tests.ps1" not in windows_smoke:
    raise SystemExit("Windows artifact lane does not run the migration unit test")

print("WINDOWS_INSTALLER_MIGRATION_SOURCE_HARNESS_OK")
PY
