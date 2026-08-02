#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$ROOT/scripts/release-network-evidence.py" <<'PY'
import importlib.util
import json
import pathlib
import sys
import tempfile

spec = importlib.util.spec_from_file_location("release_network_evidence", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

cases = {
    "automatic-profile": ("automatic", "cloudflare", "", "", ""),
    "cloudflare-doh": ("encrypted", "cloudflare", "", "", ""),
    "quad9-doh": ("encrypted", "quad9", "", "", ""),
    "custom-doh": (
        "encrypted",
        "custom",
        "https://dns.google/dns-query",
        "8.8.8.8",
        "",
    ),
    "through-exit": ("through_exit", "cloudflare", "", "", "192.0.2.53"),
}


def write(path, text):
    path.write_text(text, encoding="utf-8")


def write_direct_pair(root, label, suffix):
    write(
        root / f"mobile-android-network-{label}-{suffix}.txt",
        f"label={label}\n0% packet loss\n",
    )
    write(
        root / f"mobile-android-network-{label}-direct-https-{suffix}.txt",
        "directHttpsStatus=204\n",
    )


with tempfile.TemporaryDirectory() as temporary:
    root = pathlib.Path(temporary)
    for index, (case, values) in enumerate(cases.items()):
        mode, provider, custom_url, bootstrap, through = values
        payload = {
            "receiptSchema": 1,
            "evidenceSource": "shipped-ui-restart-readback",
            "uiRestartReadback": True,
            "releaseBlackbox": True,
            "wireguardExitEnabled": True,
            "internetSource": "wireguard",
            "error": "",
            "exitDnsMode": mode,
            "exitDnsDohProvider": provider,
            "exitDnsCustomDohUrl": custom_url,
            "exitDnsCustomDohBootstrapIps": bootstrap,
            "exitDnsThroughExitServers": through,
        }
        write(
            root / f"mobile-android-exit-dns-state-{index}.json",
            json.dumps(payload),
        )
        write_direct_pair(root, "before-connect", 1000 + index)
        write_direct_pair(root, "after-disconnect", 1000 + index)

    for index, label in enumerate(
        (
            "direct-while-connected",
            "start-stop-stable-direct",
            "start-stop-reconnect-cleanup",
        )
    ):
        write_direct_pair(root, label, 2000 + index)

    write(root / "mobile-android-release-start-stop-3000.tsv", "semantic\t42\t1\n")
    write(
        root / "mobile-android-network-start-stop-full-reconnect-3000.txt",
        "capturedHttpStatus=200\ncapturedHttpsStatus=204\nexitSourceIp=192.0.2.1\n",
    )

    summary, paths = module.validate_android_support(
        root,
        list(cases),
        "wireguard-dns",
    )
    if summary.get("directBeforeConnectedAfter") is not True:
        raise SystemExit("complete per-case Direct receipts were not accepted")
    expected_path_count = len(cases) * 5 + 8
    if len(paths) != expected_path_count:
        raise SystemExit(f"unexpected concrete evidence count: {len(paths)}")

    write_direct_pair(root, "direct-while-connected", 2999)
    try:
        module.validate_android_support(root, list(cases), "wireguard-dns")
    except ValueError as error:
        if "expected one concrete receipt" not in str(error):
            raise
    else:
        raise SystemExit("singleton Direct event accepted duplicate receipts")

print("Android release network evidence regression passed")
PY
