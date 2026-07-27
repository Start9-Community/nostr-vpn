#!/usr/bin/env python3
"""Build fail-closed, source-bound receipts from real release network gates."""

from __future__ import annotations

import argparse
import hashlib
import ipaddress
import json
import pathlib
import re
import sys
from typing import Any


DNS_CASES = {
    "automatic-profile": "dns-profile",
    "cloudflare-doh": "doh-cloudflare",
    "quad9-doh": "doh-quad9",
    "custom-doh": "doh-google",
    "through-exit": "dns-through",
}
COUNTERS = ("query", "profile", "cloudflare", "quad9", "google", "through", "forward")
DNS_COUNTERS_INCREASED = {
    "dns-profile": {"query", "profile"},
    "doh-cloudflare": {"cloudflare"},
    "doh-quad9": {"quad9"},
    "doh-google": {"google"},
    "dns-through": {"query", "through"},
}
DESKTOP_DNS_COUNTERS = {
    "automatic": "cloudflare",
    "cloudflare": "cloudflare",
    "quad9": "quad9",
    "custom": "google",
    "through-exit": "fixture_dns",
}
DESKTOP_DNS_COUNTER_NAMES = ("cloudflare", "quad9", "google", "fixture_dns")
DESKTOP_DNS_UI_SETTINGS = {
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
    "through-exit": ("through_exit", "cloudflare", "", "", None),
}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_json(path: pathlib.Path) -> dict[str, Any]:
    require(path.is_file() and not path.is_symlink(), f"missing regular JSON receipt: {path}")
    value = json.loads(path.read_text(encoding="utf-8"))
    require(isinstance(value, dict), f"JSON receipt is not an object: {path}")
    return value


def atomic_json(path: pathlib.Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp")
    temporary.write_text(
        json.dumps(value, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    temporary.replace(path)


def require_hash(value: Any, label: str, length: int = 64) -> str:
    require(
        isinstance(value, str)
        and re.fullmatch(f"[0-9a-f]{{{length}}}", value) is not None,
        f"{label} is not a lowercase {length}-digit hash",
    )
    return value


def artifact_identity(platform: str, artifact: dict[str, Any]) -> dict[str, Any]:
    expected_type = {
        "android": "Android Release APK",
        "ios": "iOS company Ad Hoc Release app",
    }[platform]
    require(
        artifact.get("receiptSchema") == 2
        and artifact.get("artifactType") == expected_type
        and artifact.get("companySigningVerified") is True,
        f"{platform} network gate artifact receipt is not strict Release evidence",
    )
    if platform == "android":
        require(
            artifact.get("apkDerivedFromAab") is True
            and artifact.get("bundletoolVersion") == "1.18.3",
            "Android network gate APK is not derived from the sealed Play AAB",
        )
        require_hash(artifact.get("aabSha256"), "Android artifact AAB SHA-256")
        require_hash(
            artifact.get("bundleReceiptSha256"),
            "Android bundle relationship receipt SHA-256",
        )
        require_hash(
            artifact.get("bundletoolSha256"),
            "Android artifact bundletool SHA-256",
        )
    for field in ("appGitSha", "appGitTree", "fipsGitSha", "fipsGitTree"):
        require_hash(artifact.get(field), f"{platform} artifact {field}", 40)
    fields = {
        "android": (
            "apkSha256",
            "installedApkSha256",
            "package",
            "signerCertificateSha256",
        ),
        "ios": (
            "appBundleTreeSha256",
            "appCodeDirectoryHash",
            "packetTunnelCodeDirectoryHash",
            "appExecutableSha256",
            "packetTunnelExecutableSha256",
            "signerCertificateSha256",
            "installedBundleIdentifier",
        ),
    }[platform]
    identity = {field: artifact.get(field) for field in fields}
    require(all(identity.values()), f"{platform} artifact identity is incomplete")
    return identity


def validate_dns_path_counters(
    label: str,
    evidence: str,
    before_dns: dict[str, int],
    after_dns: dict[str, int],
) -> None:
    expected_evidence = DNS_CASES.get(label)
    require(expected_evidence == evidence, f"{label} has the wrong DNS evidence kind")
    increased = DNS_COUNTERS_INCREASED[evidence]
    require(
        set(before_dns) == set(COUNTERS) and set(after_dns) == set(COUNTERS),
        f"{label} DNS counter set is incomplete",
    )
    for counter in COUNTERS:
        if counter in increased:
            require(
                after_dns[counter] > before_dns[counter],
                f"{label} did not increase required {counter} DNS counter",
            )
        else:
            require(
                after_dns[counter] == before_dns[counter],
                f"{label} used forbidden {counter} DNS path",
            )


def parse_counter_ledger(path: pathlib.Path, expected_cases: list[str]) -> dict[str, Any]:
    require(path.is_file() and not path.is_symlink(), "mobile counter ledger is missing")
    rows: dict[str, Any] = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        fields = raw.split("\t")
        require(len(fields) == 22, "mobile counter ledger row has the wrong width")
        label, evidence = fields[:2]
        require(label not in rows, f"duplicate counter row for {label}")
        values = [int(value) for value in fields[2:]]
        (
            before_rx,
            after_rx,
            before_tx,
            after_tx,
            before_forward,
            after_forward,
            *dns_values,
        ) = values
        require(
            after_rx > before_rx
            and after_tx > before_tx
            and after_forward > before_forward,
            f"{label} lacks increasing WireGuard/forward counters",
        )
        before_dns = dict(zip(COUNTERS, dns_values[:7], strict=True))
        after_dns = dict(zip(COUNTERS, dns_values[7:], strict=True))
        validate_dns_path_counters(label, evidence, before_dns, after_dns)
        rows[label] = {
            "dnsEvidence": evidence,
            "dnsPathCountersBefore": before_dns,
            "dnsPathCountersAfter": after_dns,
            "wireGuardRxBytesBefore": before_rx,
            "wireGuardRxBytesAfter": after_rx,
            "wireGuardTxBytesBefore": before_tx,
            "wireGuardTxBytesAfter": after_tx,
            "forwardedPacketsBefore": before_forward,
            "forwardedPacketsAfter": after_forward,
        }
    require(set(rows) == set(expected_cases), "mobile counter ledger has the wrong DNS cases")
    return {label: rows[label] for label in expected_cases}


def evidence_hashes(root: pathlib.Path, paths: list[pathlib.Path]) -> dict[str, str]:
    result: dict[str, str] = {}
    for path in sorted(set(paths)):
        require(path.is_file() and not path.is_symlink(), f"invalid evidence file: {path}")
        relative = path.relative_to(root).as_posix()
        require(relative not in result, f"duplicate evidence path: {relative}")
        result[relative] = sha256(path)
    require(result, "network gate has no concrete evidence files")
    return result


def exactly_one(root: pathlib.Path, pattern: str, label: str) -> pathlib.Path:
    matches = list(root.glob(pattern))
    require(len(matches) == 1, f"{label} expected one concrete receipt, found {len(matches)}")
    return matches[0]


def validate_ios_support(
    root: pathlib.Path,
    cases: list[str],
    mode: str,
) -> tuple[dict[str, Any], list[pathlib.Path]]:
    summaries: dict[str, Any] = {}
    paths: list[pathlib.Path] = []
    for case in cases:
        process_path = exactly_one(
            root,
            f"mobile-ios-release-network-{case}-*-processes.json",
            f"iOS {case} process",
        )
        marker_path = exactly_one(
            root,
            f"mobile-ios-release-network-{case}-*-runner-markers.log",
            f"iOS {case} UI marker",
        )
        process = load_json(process_path)
        app_pids = process.get("appProcessIdentifiers")
        tunnel_pids = process.get("packetTunnelProcessIdentifiers")
        required = set(process.get("requiredCheckpoints", []))
        observed = set(process.get("observedCheckpoints", []))
        require(
            process.get("passed") is True
            and process.get("activeSessionBeginSeen") is True
            and process.get("activeSessionEndSeen") is True
            and isinstance(app_pids, list)
            and len(app_pids) == 1
            and isinstance(tunnel_pids, list)
            and len(tunnel_pids) == 1
            and required.issubset(observed),
            f"iOS {case} process continuity receipt is incomplete",
        )
        markers = marker_path.read_text(encoding="utf-8").splitlines()
        require(
            f"NVPN_IOS_RELEASE_DNS_UI_PERSISTED={case}" in markers
            and f"NVPN_IOS_RELEASE_EXIT_CONNECTED={case}" in markers
            and "NVPN_IOS_RELEASE_DIRECT_BEFORE_PASSED=1" in markers
            and "NVPN_IOS_RELEASE_DIRECT_AFTER_PASSED=1" in markers
            and f"NVPN_IOS_RELEASE_NETWORK_PASSED={case}" in markers,
            f"iOS {case} lacks exact shipped-UI markers",
        )
        if case == "through-exit":
            require(
                "NVPN_IOS_RELEASE_CONNECTED_DIRECT_PASSED=1" in markers,
                "iOS through-exit case lacks connected Direct restoration",
            )
        summaries[case] = {
            "appProcessIdentifier": app_pids[0],
            "packetTunnelProcessIdentifier": tunnel_pids[0],
            "requiredCheckpointCount": len(required),
            "observedCheckpointCount": len(observed),
            "sampleCount": process.get("sampleCount"),
        }
        paths.extend((process_path, marker_path))

    if mode == "wireguard-dns":
        markers = exactly_one(
            root,
            "mobile-ios-release-network-automatic-profile-*-runner-markers.log",
            "iOS rapid start/stop",
        ).read_text(encoding="utf-8").splitlines()
        require(
            markers.count("NVPN_IOS_RELEASE_START_STOP_RECOVERED=1") == 1,
            "iOS rapid start/stop recovery marker is missing",
        )
        for cycle in range(1, 9):
            require(
                sum(
                    line.startswith(
                        f"NVPN_IOS_RELEASE_RAPID_STOP_REQUESTED_{cycle}_MS="
                    )
                    for line in markers
                )
                == 1
                and sum(
                    line.startswith(f"NVPN_IOS_RELEASE_RAPID_STOPPED_{cycle}_MS=")
                    for line in markers
                )
                == 1,
                f"iOS rapid start/stop cycle {cycle} is incomplete",
            )
        summaries["rapidStartStopCycles"] = 8
    else:
        process_path = exactly_one(
            root,
            "mobile-ios-release-network-automatic-profile-*-processes.json",
            "iOS underlay/lifecycle process",
        )
        process = load_json(process_path)
        required = set(process["requiredCheckpoints"])
        for cycle in range(1, 4):
            require(
                f"release_background_{cycle}_requested" in required
                and f"release_foreground_{cycle}_verified" in required,
                f"iOS lifecycle cycle {cycle} is missing",
            )
        for cycle in (1, 2):
            for phase in ("requested", "available", "payload_recovery", "verified"):
                require(
                    f"underlay_switch_{cycle}_{phase}" in required,
                    f"iOS underlay cycle {cycle} {phase} is missing",
                )
        continuity_path = exactly_one(
            root,
            "mobile-ios-release-network-automatic-profile-*-continuity.json",
            "iOS underlay continuity",
        )
        continuity = load_json(continuity_path)
        require(
            continuity.get("passed") is True
            and continuity.get("platform") == "iOS"
            and continuity.get("maxRecoveryMilliseconds") == 4_000
            and continuity.get("successfulPayloads", 0) > 0
            and isinstance(continuity.get("cycles"), list)
            and len(continuity["cycles"]) == 2
            and all(
                isinstance(cycle.get("recoveryMilliseconds"), int)
                and 0 <= cycle["recoveryMilliseconds"] <= 4_000
                and cycle.get("payloadBeforeSwitch") is True
                and cycle.get("reversePayloadAfterAvailability") is True
                for cycle in continuity["cycles"]
            ),
            "iOS underlay continuity receipt is incomplete",
        )
        summaries["lifecycleCycles"] = 3
        summaries["underlayCycles"] = continuity["cycles"]
        paths.append(continuity_path)
    return summaries, paths


def validate_android_dns_ui_receipts(
    root: pathlib.Path,
    cases: list[str],
) -> list[pathlib.Path]:
    state_paths = list(root.glob("mobile-android-exit-dns-state-*.json"))
    require(
        len(state_paths) == len(cases),
        "Android DNS settings receipts do not cover every requested case",
    )
    expected_settings = {
        "automatic-profile": {
            "mode": "automatic",
            "provider": "cloudflare",
            "customUrl": "",
            "bootstrapIps": "",
            "throughServers": "",
        },
        "cloudflare-doh": {
            "mode": "encrypted",
            "provider": "cloudflare",
            "customUrl": "",
            "bootstrapIps": "",
            "throughServers": "",
        },
        "quad9-doh": {
            "mode": "encrypted",
            "provider": "quad9",
            "customUrl": "",
            "bootstrapIps": "",
            "throughServers": "",
        },
        "custom-doh": {
            "mode": "encrypted",
            "provider": "custom",
            "customUrl": "https://dns.google/dns-query",
            "bootstrapIps": "8.8.8.8",
            "throughServers": "",
        },
        "through-exit": {
            "mode": "through_exit",
            "provider": "cloudflare",
            "customUrl": "",
            "bootstrapIps": "",
            "throughServers": None,
        },
    }
    case_by_mode_provider = {
        (settings["mode"], settings["provider"]): case
        for case, settings in expected_settings.items()
    }
    observed: set[str] = set()
    for path in state_paths:
        state = load_json(path)
        require(
            state.get("receiptSchema") == 1
            and state.get("evidenceSource")
            == "shipped-ui-restart-readback"
            and state.get("uiRestartReadback") is True
            and state.get("releaseBlackbox") is True
            and state.get("wireguardExitEnabled") is True
            and state.get("internetSource") == "wireguard"
            and not state.get("error"),
            "Android DNS settings receipt is not shipped Release UI readback",
        )
        key = (
            str(state.get("exitDnsMode")),
            str(state.get("exitDnsDohProvider")),
        )
        case = case_by_mode_provider.get(key)
        require(case in cases and case not in observed, "Android DNS settings case is wrong or duplicated")
        expected = expected_settings[case]
        require(
            state.get("exitDnsCustomDohUrl") == expected["customUrl"]
            and state.get("exitDnsCustomDohBootstrapIps")
            == expected["bootstrapIps"],
            f"Android {case} UI readback has the wrong custom DoH values",
        )
        through_servers = state.get("exitDnsThroughExitServers")
        if case == "through-exit":
            values = [
                value.strip()
                for value in str(through_servers).split(",")
                if value.strip()
            ]
            require(
                bool(values)
                and all(
                    ipaddress.ip_address(value).version in {4, 6}
                    for value in values
                ),
                "Android through-exit UI readback has no real DNS server",
            )
        else:
            require(
                through_servers == expected["throughServers"],
                f"Android {case} UI readback retained a forbidden through-exit server",
            )
        observed.add(case)
    require(
        observed == set(cases),
        "Android DNS settings receipts have the wrong five policy values",
    )
    return state_paths


def validate_android_support(
    root: pathlib.Path,
    cases: list[str],
    mode: str,
) -> tuple[dict[str, Any], list[pathlib.Path]]:
    paths = validate_android_dns_ui_receipts(root, cases)
    app_probe_paths = list(root.glob("mobile-android-app-network-*.json"))
    for path in app_probe_paths:
        probe = load_json(path)
        require(
            isinstance(probe.get("resolvedAddresses"), list)
            and bool(probe["resolvedAddresses"])
            and isinstance(probe.get("statusCode"), int)
            and 200 <= probe["statusCode"] < 400
            and not any(
                probe.get(field)
                for field in ("error", "resolveError", "fetchError")
            ),
            f"Android app DNS/HTTPS receipt failed: {path.name}",
        )
    paths.extend(app_probe_paths)
    paths.extend(root.glob("mobile-android-tun-probe-summary-*.json"))
    summary: dict[str, Any] = {
        "dnsSettingsReceiptCount": len(state_paths),
    }
    if mode == "wireguard-dns":
        rapid_path = exactly_one(
            root,
            "mobile-android-release-rapid-start-stop-*.tsv",
            "Android rapid start/stop",
        )
        rapid_rows = [
            line.split("\t")
            for line in rapid_path.read_text(encoding="utf-8").splitlines()
            if line
        ]
        require(
            [int(row[0]) for row in rapid_rows]
            == [0, 10, 30, 80, 160, 320, 640, 1000]
            and all(
                len(row) == 3
                and int(row[1]) > 0
                and int(row[2]) >= 0
                for row in rapid_rows
            ),
            "Android rapid start/stop receipt lacks eight real cycles",
        )
        direct_labels = (
            "before-connect",
            "direct-while-connected",
            "after-disconnect",
            "rapid-cancel-stable-direct",
            "rapid-cancel-reconnect-cleanup",
        )
        direct_paths = []
        for label in direct_labels:
            ping_path = exactly_one(
                root,
                f"mobile-android-network-{label}-*.txt",
                f"Android {label} Direct DNS",
            )
            https_path = exactly_one(
                root,
                f"mobile-android-network-{label}-direct-https-*.txt",
                f"Android {label} Direct HTTPS",
            )
            require(
                f"label={label}" in ping_path.read_text(encoding="utf-8")
                and "0% packet loss" in ping_path.read_text(encoding="utf-8")
                and re.search(
                    r"^directHttpsStatus=[23][0-9][0-9]$",
                    https_path.read_text(encoding="utf-8"),
                    re.MULTILINE,
                ),
                f"Android {label} Direct DNS/HTTPS receipt is incomplete",
            )
            direct_paths.extend((ping_path, https_path))
        reconnect_path = exactly_one(
            root,
            "mobile-android-network-rapid-cancel-full-reconnect-*.txt",
            "Android rapid reconnect",
        )
        reconnect_text = reconnect_path.read_text(encoding="utf-8")
        require(
            "capturedHttpStatus=200" in reconnect_text
            and re.search(
                r"capturedHttpsStatus=[23][0-9][0-9]",
                reconnect_text,
            )
            and "exitSourceIp=" in reconnect_text,
            "Android rapid reconnect lacks real exit packet evidence",
        )
        direct_paths.append(reconnect_path)
        summary["rapidStartStopCycles"] = len(rapid_rows)
        summary["directBeforeConnectedAfter"] = True
        paths.extend((rapid_path, *direct_paths))
    if mode == "underlay-lifecycle":
        underlay_path = exactly_one(
            root,
            "mobile-android-underlay-*-summary.json",
            "Android underlay continuity",
        )
        underlay = load_json(underlay_path)
        require(
            underlay.get("passed") is True
            and underlay.get("platform") == "Android"
            and underlay.get("maxRecoveryMilliseconds") == 4_000
            and underlay.get("successfulPayloads", 0) > 0
            and isinstance(underlay.get("cycles"), list)
            and len(underlay["cycles"]) == 2
            and all(
                isinstance(cycle.get("recoveryMilliseconds"), int)
                and 0 <= cycle["recoveryMilliseconds"] <= 4_000
                and cycle.get("payloadBeforeSwitch") is True
                and cycle.get("reversePayloadAfterAvailability") is True
                for cycle in underlay["cycles"]
            ),
            "Android underlay continuity receipt is incomplete",
        )
        lifecycle_ledger = exactly_one(
            root,
            "mobile-android-release-lifecycle-*.tsv",
            "Android lifecycle process",
        )
        lifecycle_rows = [
            line.split("\t")
            for line in lifecycle_ledger.read_text(encoding="utf-8").splitlines()
            if line
        ]
        require(
            [int(row[0]) for row in lifecycle_rows] == [1, 2, 3]
            and len({row[1] for row in lifecycle_rows}) == 1
            and len({row[2] for row in lifecycle_rows}) == 1,
            "Android lifecycle lacks three same-process/tunnel receipts",
        )
        lifecycle_paths = []
        for cycle in range(1, 4):
            for phase in ("background", "foreground"):
                path = exactly_one(
                    root,
                    f"mobile-android-network-release-{phase}-cycle-{cycle}-*.txt",
                    f"Android release {phase} cycle {cycle}",
                )
                text = path.read_text(encoding="utf-8")
                require(
                    "capturedHttpStatus=200" in text
                    and re.search(r"capturedHttpsStatus=[23][0-9][0-9]", text)
                    and "exitSourceIp=" in text,
                    f"Android release {phase} cycle {cycle} lacks DNS/HTTP/HTTPS packet evidence",
                )
                lifecycle_paths.append(path)
        summary["lifecycleCycles"] = 3
        summary["underlayCycles"] = underlay["cycles"]
        summary["postForegroundDnsHttpsAndTunnelCycles"] = 3
        paths.extend((underlay_path, lifecycle_ledger, *lifecycle_paths))
    return summary, paths


def build_mobile(args: argparse.Namespace) -> None:
    platform = args.platform
    mode = args.mode
    cases = list(DNS_CASES) if mode == "wireguard-dns" else ["automatic-profile"]
    artifact_path = pathlib.Path(args.artifact_receipt).resolve()
    root = pathlib.Path(args.artifact_dir).resolve()
    artifact = load_json(artifact_path)
    identity = artifact_identity(platform, artifact)
    counter_cases = parse_counter_ledger(pathlib.Path(args.counter_ledger), cases)
    if platform == "ios":
        support, paths = validate_ios_support(root, cases, mode)
    else:
        support, paths = validate_android_support(root, cases, mode)
    atomic_json(
        pathlib.Path(args.output),
        {
            "receiptSchema": 1,
            "artifactType": f"physical {platform} Release {mode} gate",
            "platform": platform,
            "mode": mode,
            "appGitSha": artifact["appGitSha"],
            "appGitTree": artifact["appGitTree"],
            "fipsGitSha": artifact["fipsGitSha"],
            "fipsGitTree": artifact["fipsGitTree"],
            "artifactReceiptSha256": sha256(artifact_path),
            "artifactIdentity": identity,
            "dnsCases": counter_cases,
            "support": support,
            "evidenceFiles": evidence_hashes(root, paths),
        },
    )


def key_values(path: pathlib.Path) -> dict[str, str]:
    require(path.is_file() and not path.is_symlink(), f"missing receipt: {path}")
    result: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        key, separator, value = line.partition("=")
        if separator:
            require(key not in result, f"duplicate {key} in {path.name}")
            result[key] = value
    return result


def validate_desktop_handoff(receipt: dict[str, Any], label: str) -> dict[str, int]:
    recovery = receipt.get("recovery_milliseconds")
    before = receipt.get("payload_successes_before")
    after = receipt.get("payload_successes_after")
    wg_before = receipt.get("wireguard_payload_successes_before")
    wg_after = receipt.get("wireguard_payload_successes_after")
    rebind_before = receipt.get("rebind_receipts_before")
    rebind_after = receipt.get("rebind_receipts_after")
    require(
        isinstance(recovery, int)
        and 0 <= recovery <= 4_000
        and isinstance(before, int)
        and isinstance(after, int)
        and after > before
        and isinstance(wg_before, int)
        and isinstance(wg_after, int)
        and wg_after > wg_before
        and isinstance(rebind_before, int)
        and rebind_after == rebind_before + 1,
        f"{label} handoff receipt is incomplete",
    )
    return {
        "recoveryMilliseconds": recovery,
        "payloadDelta": after - before,
        "wireGuardPayloadDelta": wg_after - wg_before,
        "rebindDelta": rebind_after - rebind_before,
    }


def desktop_dns_matrix(path: pathlib.Path) -> dict[str, Any]:
    require(path.is_file() and not path.is_symlink(), f"missing receipt: {path}")
    cases: dict[str, Any] = {}
    current = ""
    for line in path.read_text(encoding="utf-8").splitlines():
        key, _, value = line.partition("=")
        if key == "case":
            current = value
            cases[current] = {}
        elif current and key.startswith(("before_", "after_")):
            cases[current][key] = int(value)
    require(set(cases) == set(DESKTOP_DNS_COUNTERS), "desktop DNS matrix lacks the exact five policies")
    for label, counters in cases.items():
        expected_counter = DESKTOP_DNS_COUNTERS[label]
        expected_keys = {
            f"{phase}_{counter}"
            for phase in ("before", "after")
            for counter in DESKTOP_DNS_COUNTER_NAMES
        }
        require(
            set(counters) == expected_keys,
            f"desktop DNS matrix {label} has an incomplete resolver counter set",
        )
        for counter in DESKTOP_DNS_COUNTER_NAMES:
            before = counters[f"before_{counter}"]
            after = counters[f"after_{counter}"]
            require(
                (
                    after > before
                    if counter == expected_counter
                    else after == before
                ),
                f"desktop DNS matrix {label} used the wrong resolver counter",
            )
    return cases


def validate_desktop_dns_ui_receipts(
    root: pathlib.Path,
    platform: str,
    app_sha: str,
    app_tree: str,
) -> tuple[dict[str, Any], dict[str, str]]:
    require(
        root.is_dir() and not root.is_symlink(),
        f"{platform} desktop DNS UI evidence directory is missing",
    )
    receipt_paths = list(root.glob("*.json"))
    require(
        len(receipt_paths) == len(DESKTOP_DNS_UI_SETTINGS),
        f"{platform} desktop DNS UI receipts do not cover exactly five policies",
    )
    observed: dict[str, Any] = {}
    evidence: dict[str, str] = {}
    artifact_identity: tuple[str, str] | None = None
    for path in receipt_paths:
        receipt = load_json(path)
        case = receipt.get("case")
        require(
            receipt.get("receiptSchema") == 1
            and receipt.get("platform") == platform
            and case in DESKTOP_DNS_UI_SETTINGS
            and case not in observed
            and receipt.get("evidenceSource")
            == "shipped-ui-restart-readback"
            and receipt.get("savedViaShippedUi") is True
            and receipt.get("uiRestartReadback") is True
            and receipt.get("releaseBlackbox") is True
            and receipt.get("publicUiOnly") is True
            and receipt.get("privateStateRead") is False
            and receipt.get("appGitSha") == app_sha
            and receipt.get("appGitTree") == app_tree,
            f"{platform} {case} DNS receipt is not exact shipped-UI readback",
        )
        app_hash = require_hash(
            receipt.get("appExecutableSha256"),
            f"{platform} {case} DNS UI app SHA-256",
        )
        cli_hash = require_hash(
            receipt.get("cliExecutableSha256"),
            f"{platform} {case} DNS UI CLI SHA-256",
        )
        identity = (app_hash, cli_hash)
        if artifact_identity is None:
            artifact_identity = identity
        require(
            artifact_identity == identity,
            f"{platform} DNS UI cases did not use one exact app/CLI pair",
        )
        expected = DESKTOP_DNS_UI_SETTINGS[str(case)]
        actual = (
            receipt.get("exitDnsMode"),
            receipt.get("exitDnsDohProvider"),
            receipt.get("exitDnsCustomDohUrl"),
            receipt.get("exitDnsCustomDohBootstrapIps"),
            receipt.get("exitDnsThroughExitServers"),
        )
        provider_matches = actual[1] == expected[1] or (
            platform == "macos"
            and case in {"automatic", "through-exit"}
            and actual[1] == ""
        )
        if case == "through-exit":
            servers = [
                item.strip()
                for item in str(actual[4]).split(",")
                if item.strip()
            ]
            require(
                actual[0] == expected[0]
                and provider_matches
                and actual[2:4] == expected[2:4]
                and bool(servers)
                and all(ipaddress.ip_address(item).version in {4, 6} for item in servers),
                f"{platform} through-exit DNS UI readback is invalid",
            )
        else:
            require(
                actual[0] == expected[0]
                and provider_matches
                and actual[2:] == expected[2:],
                f"{platform} {case} DNS UI readback has the wrong settings",
            )
        observed[str(case)] = {
            "mode": actual[0],
            "provider": actual[1],
            "appExecutableSha256": app_hash,
            "cliExecutableSha256": cli_hash,
        }
        evidence[path.name] = sha256(path)
    require(
        set(observed) == set(DESKTOP_DNS_UI_SETTINGS),
        f"{platform} desktop DNS UI receipts have the wrong policies",
    )
    return (
        {case: observed[case] for case in DESKTOP_DNS_UI_SETTINGS},
        dict(sorted(evidence.items())),
    )


def build_desktop(args: argparse.Namespace) -> None:
    platform = args.platform
    root = pathlib.Path(args.artifact_dir).resolve()
    require(root.is_dir() and not root.is_symlink(), "desktop evidence directory is missing")
    app_sha = require_hash(args.app_git_sha, "desktop application commit", 40)
    app_tree = require_hash(args.app_git_tree, "desktop application tree", 40)
    dns_ui_root = pathlib.Path(args.dns_ui_dir).resolve()
    dns_ui_cases, dns_ui_evidence = validate_desktop_dns_ui_receipts(
        dns_ui_root,
        platform,
        app_sha,
        app_tree,
    )
    paths: list[pathlib.Path] = []
    summary: dict[str, Any] = {
        "dnsUiCases": dns_ui_cases,
        "dnsUiPolicyCount": len(dns_ui_cases),
    }

    if platform in {"linux", "windows"}:
        source_path = root / "source-provenance.txt"
        source = key_values(source_path)
        require(
            source.get("nvpn_base_commit") == app_sha
            and source.get("nvpn_tree") == app_tree,
            f"{platform} desktop network receipt is not source-bound",
        )
        tested_path = root / "tested-artifact.json"
        tested = load_json(tested_path)
        tested_cli_sha = require_hash(
            tested.get("cliSha256"),
            f"{platform} tested CLI SHA-256",
        )
        tested_cli_size = tested.get("cliSize")
        require(
            isinstance(tested_cli_size, int)
            and not isinstance(tested_cli_size, bool)
            and tested_cli_size > 0,
            f"{platform} tested CLI size is invalid",
        )
        summary["testedCliSha256"] = tested_cli_sha
        summary["testedCliSize"] = tested_cli_size
        require(
            all(
                case["cliExecutableSha256"] == tested_cli_sha
                for case in dns_ui_cases.values()
            ),
            f"{platform} DNS UI did not use the exact network-tested CLI",
        )
        paths.append(tested_path)
        if platform == "linux":
            tested_receipt_path = root / "tested-artifact-receipt.json"
            tested_receipt = load_json(tested_receipt_path)
            cli = tested_receipt.get("artifacts", {}).get("cli", {})
            require(
                tested_receipt.get("schema") == 1
                and tested_receipt.get("appGitSha") == app_sha
                and tested_receipt.get("appGitTree") == app_tree
                and cli.get("sha256") == tested_cli_sha
                and cli.get("size") == tested_cli_size
                and tested.get("artifactReceiptSha256")
                == sha256(tested_receipt_path),
                "Linux tested CLI is not bound to its host-built artifact receipt",
            )
            summary["artifactReceiptSha256"] = sha256(tested_receipt_path)
            paths.append(tested_receipt_path)
        secondary_path = root / "secondary-receipt.json"
        primary_path = root / "primary-receipt.json"
        summary["handoffs"] = {
            "primaryToSecondary": validate_desktop_handoff(
                load_json(secondary_path),
                f"{platform} primary-to-secondary",
            ),
            "secondaryToPrimary": validate_desktop_handoff(
                load_json(primary_path),
                f"{platform} secondary-to-primary",
            ),
        }
        dns_path = root / "dns-matrix.txt"
        summary["dnsCases"] = desktop_dns_matrix(dns_path)
        summary["dnsPolicyCount"] = 5
        direct_path = root / "direct-receipt.json"
        direct = load_json(direct_path)
        common_direct = (
            direct.get("wireguard_interface_removed") is True
            and direct.get("wireguard_endpoint_route_removed") is True
            and direct.get("verified_https") is True
        )
        if platform == "linux":
            require(
                common_direct
                and direct.get("wireguard_policy_rule_removed") is True
                and direct.get("wireguard_policy_table_empty") is True,
                "Linux Direct restoration receipt is incomplete",
            )
            crash_path = root / "crash-repair-receipt.json"
            crash = load_json(crash_path)
            require(
                crash.get("sigkill_exit_code") == 137
                and crash.get("fresh_wireguard_handshake") is True
                and crash.get("through_exit_dns_before_crash") is True
                and crash.get("verified_https_before_crash") is True
                and crash.get("cleanup_journal_survived_sigkill") is True
                and crash.get("startup_repair_without_explicit_command") is True
                and crash.get("cleanup_journal_removed") is True
                and crash.get("physical_default_restored") is True
                and crash.get("public_dns_restored") is True
                and crash.get("verified_https_after_restart") is True
                and crash.get("restart_daemon_count") == 1
                and 0 <= crash.get("restart_repair_milliseconds", 4_001) <= 4_000,
                "Linux SIGKILL/restart repair receipt is incomplete",
            )
            summary["crashRepairMilliseconds"] = crash[
                "restart_repair_milliseconds"
            ]
            summary["singletonAfterCrashRecovery"] = True
        else:
            require(
                common_direct
                and direct.get("wireguard_service_removed") is True
                and direct.get("wireguard_source_secrets_removed") is True,
                "Windows Direct restoration receipt is incomplete",
            )
            crash_path = root / "crash-recovery-receipt.json"
            crash = load_json(crash_path)
            require(
                crash.get("sigkillExitCode") == 137
                and crash.get("freshWireGuardHandshake") is True
                and crash.get("throughExitDnsBeforeCrash") is True
                and crash.get("verifiedHttpsBeforeCrash") is True
                and crash.get("nativeWireGuardOwnerDirectoryLayout") is True
                and crash.get("nativeWireGuardOwnerFilesSurvivedCrash") is True
                and crash.get("nativeWireGuardOwnerFilesRemovedAfterRepair") is True
                and crash.get("verifiedHttpsAfterRestart") is True
                and crash.get("restartProcessCount") == 1,
                "Windows crash/owner-file repair receipt is incomplete",
            )
            summary["nativeWireGuardOwnerFilesRepaired"] = True
            summary["singletonAfterCrashRecovery"] = True
        summary["directRestored"] = True
        paths.extend(
            (
                source_path,
                secondary_path,
                primary_path,
                dns_path,
                direct_path,
                crash_path,
            )
        )
    else:
        artifact_path = pathlib.Path(args.artifact_receipt).resolve()
        artifact = load_json(artifact_path)
        require(
            artifact.get("receiptSchema") == 1
            and artifact.get("appGitSha") == app_sha
            and artifact.get("appGitTree") == app_tree
            and artifact.get("companySigningVerified") is True,
            "macOS desktop network artifact receipt is not exact",
        )
        require(
            all(
                case["appExecutableSha256"]
                == artifact.get("appExecutableSha256")
                and case["cliExecutableSha256"]
                == artifact.get("cliExecutableSha256")
                for case in dns_ui_cases.values()
            ),
            "macOS DNS UI did not use the exact gated app/CLI package",
        )
        dns_path = root / "fixture-dns-counters.tsv"
        rows = [
            line.split("\t")
            for line in dns_path.read_text(encoding="utf-8").splitlines()
            if line
        ]
        require(
            len(rows) == 5
            and {row[0] for row in rows}
            == {
                "automatic-profile",
                "cloudflare-doh",
                "quad9-doh",
                "custom-doh",
                "through-exit",
            },
            "macOS DNS matrix lacks the exact five policies",
        )
        for row in rows:
            dns_values = [int(value) for value in row[5:]]
            before_dns = dict(zip(COUNTERS, dns_values[:7], strict=True))
            after_dns = dict(zip(COUNTERS, dns_values[7:], strict=True))
            require(
                len(row) == 19
                and int(row[2]) > int(row[1])
                and int(row[4]) > int(row[3]),
                f"macOS {row[0]} lacks real WireGuard/forward counters",
            )
            validate_dns_path_counters(
                row[0],
                DNS_CASES[row[0]],
                before_dns,
                after_dns,
            )
        underlay_path = root / "underlay.txt"
        underlay = key_values(underlay_path)
        first = int(underlay.get("primary_to_secondary_ms", "4001"))
        second = int(underlay.get("secondary_to_primary_ms", "4001"))
        require(
            0 <= first <= 4_000
            and 0 <= second <= 4_000
            and underlay.get("connected_peer_count") == "1",
            "macOS dual-underlay receipt is incomplete",
        )
        crash_path = root / "crash-restart.txt"
        crash = key_values(crash_path)
        require(
            crash.get("sigkill_journal_seen") == "true"
            and crash.get("old_pid") != crash.get("new_pid")
            and 0 <= int(crash.get("restart_payload_ms", "4001")) <= 4_000
            and crash.get("connected_peer_count") == "1",
            "macOS SIGKILL/restart receipt is incomplete",
        )
        direct_path = root / "direct.txt"
        direct = key_values(direct_path)
        require(
            direct.get("resolver_files_absent") == "true"
            and bool(direct.get("direct_interface"))
            and bool(direct.get("direct_gateway"))
            and bool(direct.get("direct_source_ip")),
            "macOS Direct restoration receipt is incomplete",
        )
        summary.update(
            {
                "artifactReceiptSha256": sha256(artifact_path),
                "dnsPolicyCount": len(rows),
                "handoffRecoveryMilliseconds": [first, second],
                "crashRestartPayloadMilliseconds": int(
                    crash["restart_payload_ms"]
                ),
                "directRestored": True,
                "singletonAfterCrashRecovery": True,
            }
        )
        paths.extend((dns_path, underlay_path, crash_path, direct_path))

    atomic_json(
        pathlib.Path(args.output),
        {
            "receiptSchema": 1,
            "artifactType": f"{platform} Release desktop network gate",
            "platform": platform,
            "appGitSha": app_sha,
            "appGitTree": app_tree,
            "summary": summary,
            "evidenceFiles": evidence_hashes(root, paths),
            "desktopDnsUiEvidenceFiles": dns_ui_evidence,
        },
    )


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    commands = result.add_subparsers(dest="command", required=True)
    mobile = commands.add_parser("mobile")
    mobile.add_argument("--platform", choices=("android", "ios"), required=True)
    mobile.add_argument(
        "--mode",
        choices=("wireguard-dns", "underlay-lifecycle"),
        required=True,
    )
    mobile.add_argument("--artifact-receipt", required=True)
    mobile.add_argument("--artifact-dir", required=True)
    mobile.add_argument("--counter-ledger", required=True)
    mobile.add_argument("--output", required=True)
    desktop = commands.add_parser("desktop")
    desktop.add_argument(
        "--platform",
        choices=("linux", "macos", "windows"),
        required=True,
    )
    desktop.add_argument("--artifact-dir", required=True)
    desktop.add_argument("--artifact-receipt")
    desktop.add_argument("--dns-ui-dir", required=True)
    desktop.add_argument("--app-git-sha", required=True)
    desktop.add_argument("--app-git-tree", required=True)
    desktop.add_argument("--output", required=True)
    return result


def main() -> int:
    args = parser().parse_args()
    try:
        if args.command == "mobile":
            build_mobile(args)
        elif args.command == "desktop":
            build_desktop(args)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"release network evidence failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
