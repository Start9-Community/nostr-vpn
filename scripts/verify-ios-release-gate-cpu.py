#!/usr/bin/env python3
"""Validate signed production CPU evidence without rebuilding or touching a phone."""
import argparse
import hashlib
import importlib.util
import json
import math
import re
from pathlib import Path
from types import SimpleNamespace

from mobile_release_artifact_receipt import tree_sha256


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def validate(args):
    base = args.receipt.parent
    accepted = json.loads(args.receipt.read_text())
    require(accepted.get("scope") == "signed-production-iphone-idle-cpu", "Wrong CPU evidence scope")
    require(accepted.get("releaseAcceptanceProven") is True
            and accepted.get("exitCode") == 0 and accepted.get("cleanupExitCode") == 0,
            "CPU measurement or cleanup did not pass")
    names = ["qualification/inputs.json", "installed-production.json", "public-mesh.json",
             "trace/recording.json", "trace/cpu-measurement.json"]
    require(set(accepted.get("evidenceSha256", {})) == set(names), "Incomplete CPU evidence")
    for name in names:
        require(digest(base / name) == accepted["evidenceSha256"][name], "CPU evidence changed: " + name)
    inputs, installed, mesh, recording, measured = [json.loads((base / n).read_text()) for n in names]
    artifact = json.loads(args.artifact_receipt.read_text())
    require(digest(args.artifact_receipt) == inputs["productionReceiptSha256"], "Production receipt changed")
    require(digest(base / "qualification/validated-production-export.json")
            == inputs["frozenExportReceiptSha256"], "Validated export changed")
    for key, expected in {"appGitSha": args.app_git_sha, "fipsGitSha": args.fips_git_sha}.items():
        require(all(value.get(key) == expected for value in [accepted, inputs, artifact]),
                "CPU evidence is for another source: " + key)
    require(artifact.get("receiptSchema") == 2
            and artifact.get("artifactType") == "iOS company Ad Hoc Release app"
            and artifact.get("companySigningVerified") is True
            and artifact.get("debuggable") is False
            and inputs.get("productionArtifactValidated") is True,
            "CPU evidence is not for the signed production app")
    app_tree = tree_sha256(args.app)
    require(all(value.get("appBundleTreeSha256") == app_tree for value in [accepted, inputs, artifact])
            and installed.get("productionAppTreeSha256") == app_tree
            and installed.get("installedAppVerified") is True, "Measured production app changed")
    require(inputs.get("selectedPhysicalDeviceIdentifierSha256")
            == artifact.get("selectedPhysicalDeviceIdentifierSha256"), "Artifact device changed")
    require(mesh.get("publicMeshVerified") is True and mesh.get("sameTunnelPid") is True
            and mesh.get("routingRoleObserved") is True, "Normal public mesh was not verified")
    counts, roles = mesh.get("publicPeerCountsBeforeAfter", []), mesh.get("clientOnlyBeforeAfter", [])
    require(len(counts) == len(roles) == 2 and all(type(n) is int and n > 0 for n in counts)
            and all(type(role) is bool for role in roles)
            and accepted.get("clientOnlyBeforeAfter") == roles, "Public peers or routing-role observations missing")
    logs = mesh.get("logSha256", {})
    require(set(logs) == {"mesh-before.log", "mesh-after.log"}, "Missing before/after mesh logs")
    for index, name in enumerate(["mesh-before.log", "mesh-after.log"]):
        expected = logs[name]
        require(Path(name).name == name and digest(base / name) == expected, "Mesh log changed")
        text = (base / name).read_text()
        peers = re.findall(r"NVPN_RELEASE_JOIN_BOOTSTRAP_CONNECTED=(\d+)", text)
        observed_roles = re.findall(r"NVPN_RELEASE_JOIN_CLIENT_ONLY=([01])(?:\s|$)", text)
        require(peers and int(peers[-1]) == counts[index] and observed_roles
                and (observed_roles[-1] == "1") == roles[index]
                and "NVPN_RELEASE_JOIN_CARRIER_PREFLIGHT_READY=1" in text, "Mesh logs disagree")
    require(recording.get("wrapperComplete") is True and recording.get("exitCode") == 0
            and recording.get("sameTunnelPidBeforeAfter") is True
            and recording.get("recordSeconds") == 120, "Incomplete bounded CPU trace")
    steps = recording.get("commands", [])
    require([s.get("step") for s in steps]
            == ["processes-before", "record", "processes-after", "export-toc", "export-cpu", "analyze"]
            and all(s.get("exitCode") == 0 for s in steps), "CPU recording command failed")
    require(type(mesh.get("pid")) is int and mesh["pid"] > 0
            and mesh["pid"] == recording.get("expectedPid") == measured.get("pid"), "Tunnel PID changed")
    device = inputs["traceDeviceSha256"]
    require(device == recording.get("deviceSha256") == measured.get("deviceSha256"), "Trace device changed")
    xml, toc = base / "trace/sysmon.xml", base / "trace/toc.xml"
    require(digest(xml) == measured.get("xmlSha256") and digest(toc) == measured.get("tocSha256"),
            "Raw CPU trace changed")
    path = Path(__file__).with_name("ios-release-gate-cpu-trace.py")
    spec = importlib.util.spec_from_file_location("ios_cpu_trace", path)
    analyzer = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(analyzer)
    recomputed = analyzer.analyze(SimpleNamespace(xml=xml, toc=toc, pid=mesh["pid"],
                                                process_name="Nostr VPN Tunnel", device_sha256=device))
    require(all(measured.get(k) == v for k, v in recomputed.items())
            and recording.get("cpu") == measured, "CPU counters disagree with the recorded result")
    require(recomputed["cpuThresholdMet"] is True and recomputed["maxPercent"] == 2
            and math.isfinite(recomputed["cpuPercent"])
            and accepted.get("cpuPercent") == recomputed["cpuPercent"]
            and accepted.get("sampleSeconds") == recomputed["elapsedSeconds"], "Production CPU exceeds 2%")
    return {"passed": True, "cpuPercent": recomputed["cpuPercent"],
            "sampleSeconds": recomputed["elapsedSeconds"], "deviceTouched": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--receipt", type=Path, required=True)
    parser.add_argument("--artifact-receipt", type=Path, required=True)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--app-git-sha", required=True)
    parser.add_argument("--fips-git-sha", required=True)
    args = parser.parse_args()
    try:
        print(json.dumps(validate(args)))
    except (ValueError, KeyError, TypeError, OSError) as error:
        parser.exit(1, str(error) + "\n")


if __name__ == "__main__":
    main()
