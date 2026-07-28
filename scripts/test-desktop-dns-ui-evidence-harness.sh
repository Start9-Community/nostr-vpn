#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

required_source=(
  'macos/Sources/RootViewInternet.swift:.accessibilityIdentifier("exit-dns-mode")'
  'macos/Sources/RootViewInternet.swift:.accessibilityIdentifier("exit-dns-save")'
  'linux/src/main/saved_networks.rs:nvpn-exit-dns-mode'
  'linux/src/main/saved_networks.rs:nvpn-exit-dns-save'
  'windows/NostrVpn.Windows/MainWindow.xaml:AutomationProperties.AutomationId="ExitDnsMode"'
  'windows/NostrVpn.Windows/MainWindow.xaml:AutomationProperties.AutomationId="ExitDnsSave"'
  'scripts/desktop-mobile-manual-join-atspi.py:uiRestartReadback'
  'scripts/desktop-mobile-manual-join-windows-ui.ps1:uiRestartReadback'
  'scripts/ubuntu-vm-exit-dns-ui-e2e.sh:DnsPolicy'
  'scripts/ubuntu-vm-exit-dns-ui-e2e.sh:artifact_root="$(cd "$artifact_root" && pwd -P)"'
  'scripts/ubuntu-vm-exit-dns-ui-e2e.sh:repo="$(pwd -P)"'
  'scripts/windows-vm-exit-dns-ui-e2e.sh:DnsPolicy'
)
for entry in "${required_source[@]}"; do
  file="${entry%%:*}"
  text="${entry#*:}"
  rg -Fq "$text" "$file" || {
    echo "desktop DNS UI source contract is missing: $file: $text" >&2
    exit 1
  }
done

python3 - "$ROOT/scripts/ubuntu-vm-exit-dns-ui-e2e.sh" <<'PY'
import pathlib
import sys

script = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
canonical_handoff = (
    'artifact_root="$(cd "$artifact_root" && pwd -P)"\n'
    'cd "$repo"\n'
    'repo="$(pwd -P)"\n'
    'export GDK_BACKEND=x11'
)
if canonical_handoff not in script:
    raise SystemExit(
        "Linux Exit DNS UI wrapper does not canonicalize its relative guest "
        "repository and artifact directory before handing them to the nested "
        "Xvfb/DBus shell"
    )
for required in (
    "cleanup_remote_dns_state()",
    'case_root="/tmp/nvpn-linux-exit-dns-ui"',
    'artifact_root="$guest_repo/artifacts/linux-exit-dns-ui"',
    '[[ "$artifact_root" == */nostr-vpn-release-gate/artifacts/linux-exit-dns-ui ]]',
    'test ! -e "$artifact_root"',
    'test ! -e "$case_root"',
):
    if required not in script:
        raise SystemExit(
            "Linux Exit DNS UI wrapper does not clean exact remote state "
            f"after cancellation: {required}"
        )
cleanup = script[
    script.index("cleanup() {") : script.index("trap cleanup EXIT")
]
dns_cleanup = cleanup.find("cleanup_remote_dns_state")
bundle_cleanup = cleanup.find("ubuntu_vm_cleanup_imported_release_bundle")
if dns_cleanup < 0 or bundle_cleanup < 0 or dns_cleanup > bundle_cleanup:
    raise SystemExit(
        "Linux Exit DNS UI wrapper does not remove exact DNS state before "
        "the slower imported-package cleanup"
    )
PY

python3 - \
  "$ROOT/linux/src/main/saved_networks.rs" \
  "$ROOT/scripts/desktop-mobile-manual-join-atspi.py" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
driver = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
for variable, selector in (
    ("mode", "nvpn-exit-dns-mode"),
    ("provider", "nvpn-exit-dns-provider"),
    ("custom_url", "nvpn-exit-dns-custom-url"),
    ("bootstrap_ips", "nvpn-exit-dns-bootstrap-ips"),
    ("through_servers", "nvpn-exit-dns-through-servers"),
    ("save", "nvpn-exit-dns-save"),
):
    exposure = f'selectors.expose_object("{selector}", &{variable});'
    if source.count(exposure) != 1:
        raise SystemExit(
            f"Linux Exit DNS control does not expose the exact stable GTK "
            f"buildable ID {selector}"
        )
if "set_dropdown_accessible_label" in source:
    raise SystemExit("Linux Exit DNS still duplicates selectors as dynamic labels")
for required in (
    'name.startswith("nvpn-exit-dns-")',
    "node.get_accessible_id() == name",
    "ancestor_with_accessible_id(candidate, name)",
    '"nvpn-exit-dns-mode": (',
    '"Automatic (recommended)"',
    '"Encrypted DNS"',
    '"DNS through exit"',
    '"nvpn-exit-dns-provider": (',
    '"Cloudflare"',
    '"Quad9"',
    '"Custom DoH"',
    "def select_dns_index(name: str, index: int)",
    "def selected_dns_index(",
    "labels = DNS_DROPDOWN_LABELS[name]",
    "selected_dns_index(name, expected=index)",
    "canonical_ip_csv(",
    "observed_bootstrap",
    "self.args.dns_bootstrap_ips",
    "wait_dropdown_expanded(name, False)",
    "wait_dropdown_expanded(name, True)",
    "pyatspi.STATE_EXPANDED",
    "wait_dropdown_popup_ready(name)",
    "expected_items = len(DNS_DROPDOWN_LABELS[name])",
    'node.getRoleName() != "list box"',
):
    if required not in driver:
        raise SystemExit(
            "Linux Exit DNS AT-SPI driver does not match exact stable "
            f"accessible IDs: {required}"
        )

for forbidden in ("doAction(", "grabFocus(", "querySelection(", "selectChild("):
    if forbidden in driver:
        raise SystemExit(
            f"Linux Exit DNS driver retains a fallback path: {forbidden}"
        )
PY

python3 - "$ROOT/scripts/macos-exit-dns-ax.swift" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
for required in (
    "func canonicalCSV(_ value: String) -> String",
    "canonicalCSV(observedBootstrap) == canonicalCSV(bootstrapIPs)",
    'values["bootstrapIps"] = bootstrapIPs',
):
    if required not in source:
        raise SystemExit(
            f"macOS Exit DNS driver lacks canonical CSV readback: {required}"
        )
PY

python3 - "$ROOT/scripts/release-network-evidence.py" <<'PY'
import importlib.util
import json
import pathlib
import shutil
import sys
import tempfile

spec = importlib.util.spec_from_file_location("release_network_evidence", sys.argv[1])
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)

app_sha = "a" * 40
app_tree = "b" * 40
artifact_hash = "c" * 64
cli_hash = "d" * 64
settings = {
    "automatic": ("automatic", "cloudflare", "", "", ""),
    "cloudflare": ("encrypted", "cloudflare", "", "", ""),
    "quad9": ("encrypted", "quad9", "", "", ""),
    "custom": (
        "encrypted",
        "custom",
        "https://dns.google/dns-query",
        "8.8.8.8,8.8.4.4",
        "",
    ),
    "through-exit": ("through_exit", "cloudflare", "", "", "10.99.79.53"),
}


def write(root: pathlib.Path, platform: str) -> None:
    for case, values in settings.items():
        mode, provider, custom, bootstrap, through = values
        (root / f"{case}.json").write_text(
            json.dumps(
                {
                    "schema": 1,
                    "mode": "DnsPolicy",
                    "publicUiOnly": True,
                    "privateStateRead": False,
                    "receiptSchema": 1,
                    "platform": platform,
                    "case": case,
                    "evidenceSource": "shipped-ui-restart-readback",
                    "savedViaShippedUi": True,
                    "uiRestartReadback": True,
                    "releaseBlackbox": True,
                    "exitDnsMode": mode,
                    "exitDnsDohProvider": provider,
                    "exitDnsCustomDohUrl": custom,
                    "exitDnsCustomDohBootstrapIps": bootstrap,
                    "exitDnsThroughExitServers": through,
                    "appGitSha": app_sha,
                    "appGitTree": app_tree,
                    "appExecutableSha256": artifact_hash,
                    "cliExecutableSha256": cli_hash,
                }
            )
            + "\n",
            encoding="utf-8",
        )


with tempfile.TemporaryDirectory() as temporary:
    base = pathlib.Path(temporary)
    for platform in ("linux", "macos", "windows"):
        root = base / platform
        root.mkdir()
        write(root, platform)
        cases, hashes = module.validate_desktop_dns_ui_receipts(
            root, platform, app_sha, app_tree
        )
        assert set(cases) == set(settings)
        assert set(hashes) == {f"{case}.json" for case in settings}

    bad = base / "bad-bootstrap"
    shutil.copytree(base / "linux", bad)
    path = bad / "custom.json"
    value = json.loads(path.read_text(encoding="utf-8"))
    value["exitDnsCustomDohBootstrapIps"] = "1.1.1.1"
    path.write_text(json.dumps(value) + "\n", encoding="utf-8")
    try:
        module.validate_desktop_dns_ui_receipts(
            bad, "linux", app_sha, app_tree
        )
    except ValueError:
        pass
    else:
        raise SystemExit("wrong custom bootstrap was accepted")

    mixed = base / "mixed-artifact"
    shutil.copytree(base / "windows", mixed)
    path = mixed / "quad9.json"
    value = json.loads(path.read_text(encoding="utf-8"))
    value["appExecutableSha256"] = "e" * 64
    path.write_text(json.dumps(value) + "\n", encoding="utf-8")
    try:
        module.validate_desktop_dns_ui_receipts(
            mixed, "windows", app_sha, app_tree
        )
    except ValueError:
        pass
    else:
        raise SystemExit("mixed desktop app artifacts were accepted")

    private = base / "private-state"
    shutil.copytree(base / "macos", private)
    path = private / "automatic.json"
    value = json.loads(path.read_text(encoding="utf-8"))
    value["privateStateRead"] = True
    path.write_text(json.dumps(value) + "\n", encoding="utf-8")
    try:
        module.validate_desktop_dns_ui_receipts(
            private, "macos", app_sha, app_tree
        )
    except ValueError:
        pass
    else:
        raise SystemExit("private-state desktop DNS evidence was accepted")

    missing = base / "missing"
    shutil.copytree(base / "linux", missing)
    (missing / "through-exit.json").unlink()
    try:
        module.validate_desktop_dns_ui_receipts(
            missing, "linux", app_sha, app_tree
        )
    except ValueError:
        pass
    else:
        raise SystemExit("incomplete desktop DNS UI matrix was accepted")
PY

echo "DESKTOP_DNS_UI_EVIDENCE_CONTRACT_OK"
