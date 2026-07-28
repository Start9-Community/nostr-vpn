#!/usr/bin/env python3
"""Validate and bind real desktop↔Pixel manual-join Release evidence."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import re
import tempfile
from typing import Any, NoReturn


GIT_SHA = re.compile(r"^[0-9a-f]{40}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
VERSION = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:[+-][0-9A-Za-z.-]+)?$")
PLATFORMS = ("windows", "linux")
ROLES = ("desktopAdminPixelJoiner", "pixelAdminDesktopJoiner")
ROLE_FLAGS = (
    "desktopAccepted",
    "pixelAccepted",
    "desktopRelaunchAccepted",
    "pixelRelaunchAccepted",
)


def fail(message: str) -> NoReturn:
    raise ValueError(message)


def load_json(path: pathlib.Path, label: str) -> dict[str, Any]:
    if not path.is_file() or path.is_symlink():
        fail(f"{label} is not a regular non-symlink file")
    try:
        value = json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, ValueError) as error:
        fail(f"could not parse {label}: {error}")
    if not isinstance(value, dict):
        fail(f"{label} root is not an object")
    return value


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require_exact(value: dict[str, Any], key: str, expected: Any, label: str) -> None:
    if value.get(key) != expected:
        fail(f"{label} requires {key}={expected!r}")


def require_git_sha(value: str, label: str) -> None:
    if not GIT_SHA.fullmatch(value):
        fail(f"{label} is not an exact Git SHA")


def require_sha256(value: Any, label: str) -> str:
    if not isinstance(value, str):
        fail(f"{label} is not a SHA-256 string")
    normalized = value.lower()
    if not SHA256.fullmatch(normalized):
        fail(f"{label} is not an exact SHA-256")
    return normalized


def require_artifact_entry(
    artifacts: dict[str, Any], name: str, label: str
) -> dict[str, Any]:
    entry = artifacts.get(name)
    if not isinstance(entry, dict):
        fail(f"{label} lacks the {name} artifact")
    require_sha256(entry.get("sha256"), f"{label} {name} hash")
    size = entry.get("size")
    if not isinstance(size, int) or isinstance(size, bool) or size <= 0:
        fail(f"{label} {name} size is not positive")
    filename = entry.get("file")
    if not isinstance(filename, str) or not filename.strip():
        fail(f"{label} {name} filename is empty")
    return entry


def validate_desktop_receipt(
    receipt: dict[str, Any],
    platform: str,
    app_sha: str,
    app_tree: str,
    fips_sha: str,
    fips_tree: str,
    fips_version: str,
) -> dict[str, Any]:
    label = f"{platform} desktop artifact receipt"
    require_exact(receipt, "schema", 2 if platform == "linux" else 1, label)
    require_exact(receipt, "appGitSha", app_sha, label)
    require_exact(receipt, "appGitTree", app_tree, label)
    require_exact(receipt, "fipsGitSha", fips_sha, label)
    require_exact(receipt, "fipsGitTree", fips_tree, label)
    require_exact(receipt, "fipsVersion", fips_version, label)
    version = receipt.get("appVersion")
    if not isinstance(version, str) or not VERSION.fullmatch(version):
        fail(f"{label} has no valid appVersion")
    artifacts = receipt.get("artifacts")
    if not isinstance(artifacts, dict):
        fail(f"{label} has no artifact map")
    app = require_artifact_entry(artifacts, "app", label)
    cli = require_artifact_entry(artifacts, "cli", label)

    if platform == "windows":
        require_exact(receipt, "platform", "windows", label)
        require_exact(receipt, "configuration", "Release", label)
        require_exact(receipt, "builtOnWindowsVm", True, label)
        app_core = require_artifact_entry(artifacts, "appCore", label)
        if cli.get("shortVersion") != f"nvpn {version}":
            fail(f"{label} CLI version differs from appVersion")
        verbose = cli.get("verboseVersion")
        if not isinstance(verbose, str) or f"(rev {fips_sha[:10]})" not in verbose:
            fail(f"{label} CLI does not bind the exact FIPS revision")
    else:
        mode = receipt.get("builderMode")
        if mode == "local-docker":
            require_exact(receipt, "builtOnHostMac", True, label)
            require_exact(receipt, "builtOnRemoteVm", False, label)
            require_exact(receipt, "builderHostOs", "Darwin", label)
            if receipt.get("builderHostArchitecture") not in {"arm64", "x86_64"}:
                fail(f"{label} has invalid local Docker host architecture")
        elif mode == "remote-native":
            require_exact(receipt, "builtOnHostMac", False, label)
            require_exact(receipt, "builtOnRemoteVm", True, label)
            require_exact(receipt, "builderHostOs", "Linux", label)
            require_exact(receipt, "builderHostArchitecture", "x86_64", label)
        else:
            fail(f"{label} has unsupported builderMode")
        require_sha256(receipt.get("dockerfileSha256"), f"{label} Dockerfile hash")
        require_sha256(
            receipt.get("containerPayloadSha256"),
            f"{label} container payload hash",
        )
        image_id = receipt.get("containerImageId")
        if not isinstance(image_id, str) or not re.fullmatch(
            r"sha256:[0-9a-f]{64}", image_id
        ):
            fail(f"{label} has invalid container image identity")
        require_exact(receipt, "dockerPlatform", "linux/amd64", label)
        require_exact(receipt, "target", "x86_64-unknown-linux-gnu", label)
        app_core = None
        if receipt.get("cliShortVersion") != f"nvpn {version}":
            fail(f"{label} CLI version differs from appVersion")
        verbose = receipt.get("cliVerboseVersion")
        if not isinstance(verbose, str) or f"(rev {fips_sha[:10]})" not in verbose:
            fail(f"{label} CLI does not bind the exact FIPS revision")

    result: dict[str, Any] = {
        "appSha256": app["sha256"],
        "appSize": app["size"],
        "cliSha256": cli["sha256"],
        "cliSize": cli["size"],
        "appVersion": version,
    }
    if app_core is not None:
        result["appCoreSha256"] = app_core["sha256"]
        result["appCoreSize"] = app_core["size"]
    return result


def validate_android_receipt(
    receipt: dict[str, Any],
    apk: pathlib.Path,
    app_sha: str,
    app_tree: str,
    fips_sha: str,
    fips_tree: str,
) -> dict[str, Any]:
    label = "Android Release install receipt"
    if not apk.is_file() or apk.is_symlink():
        fail("Android APK is not a regular non-symlink file")
    apk_hash = sha256_file(apk)
    require_exact(receipt, "artifact", "Android Release APK", label)
    require_exact(receipt, "apkSha256", apk_hash, label)
    require_exact(receipt, "installedApkSha256", apk_hash, label)
    require_exact(receipt, "appGitSha", app_sha, label)
    require_exact(receipt, "appGitTree", app_tree, label)
    require_exact(receipt, "fipsGitSha", fips_sha, label)
    require_exact(receipt, "fipsGitTree", fips_tree, label)
    require_exact(receipt, "package", "fi.siriusbusiness.nvpn", label)
    require_exact(receipt, "replacementInstall", True, label)
    require_exact(receipt, "replacementInstallVerified", True, label)
    require_exact(receipt, "debuggable", False, label)
    require_exact(receipt, "canonicalPackageCount", 1, label)
    require_exact(receipt, "canonicalProcessCount", 1, label)
    signer = require_sha256(
        receipt.get("signerCertificateSha256"),
        "Android Release signer certificate",
    )
    return {
        "apkSha256": apk_hash,
        "apkSize": apk.stat().st_size,
        "signerCertificateSha256": signer,
        "package": receipt["package"],
    }


def validate_phase_evidence(
    evidence: dict[str, Any], platform: str
) -> dict[str, Any]:
    label = f"{platform} desktop↔Pixel phase evidence"
    require_exact(evidence, "schema", 1, label)
    require_exact(evidence, "platform", platform, label)
    require_exact(evidence, "publicUiOnly", True, label)
    require_exact(evidence, "privateStateRead", False, label)
    require_exact(evidence, "fixtureInvoked", False, label)
    require_exact(evidence, "appLaunchArgumentsOrEnvironment", False, label)
    require_exact(
        evidence,
        "acceptedSelectorSemantics",
        "participant-state-not-pending",
        label,
    )
    deadline = evidence.get("completionDeadlineSeconds")
    if (
        not isinstance(deadline, int)
        or isinstance(deadline, bool)
        or deadline <= 0
        or deadline > 15
    ):
        fail(f"{label} completion deadline exceeds 15 seconds")
    validated_roles: dict[str, Any] = {}
    for role_name in ROLES:
        role = evidence.get(role_name)
        if not isinstance(role, dict):
            fail(f"{label} lacks role {role_name}")
        for flag in ROLE_FLAGS:
            require_exact(role, flag, True, f"{label} {role_name}")
        elapsed = role.get("deliveryMilliseconds")
        if (
            not isinstance(elapsed, int)
            or isinstance(elapsed, bool)
            or elapsed < 0
            or elapsed > deadline * 1000
        ):
            fail(f"{label} {role_name} delivery exceeded the deadline")
        validated_roles[role_name] = {
            **{flag: True for flag in ROLE_FLAGS},
            "deliveryMilliseconds": elapsed,
        }
    return {
        "completionDeadlineSeconds": deadline,
        **validated_roles,
    }


def write_json_atomically(path: pathlib.Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", suffix=".tmp", dir=path.parent
    )
    temporary = pathlib.Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(value, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def create_receipt(args: argparse.Namespace) -> None:
    for value, label in (
        (args.expected_app_sha, "expected app SHA"),
        (args.expected_app_tree, "expected app tree"),
        (args.expected_fips_sha, "expected FIPS SHA"),
        (args.expected_fips_tree, "expected FIPS tree"),
    ):
        require_git_sha(value, label)
    if not VERSION.fullmatch(args.expected_fips_version):
        fail("expected FIPS version is invalid")

    desktop_source = load_json(args.desktop_receipt, "desktop artifact receipt")
    android_source = load_json(
        args.android_install_receipt, "Android install receipt"
    )
    phase_source = load_json(args.phase_evidence, "phase evidence")
    desktop = validate_desktop_receipt(
        desktop_source,
        args.platform,
        args.expected_app_sha,
        args.expected_app_tree,
        args.expected_fips_sha,
        args.expected_fips_tree,
        args.expected_fips_version,
    )
    android = validate_android_receipt(
        android_source,
        args.android_apk,
        args.expected_app_sha,
        args.expected_app_tree,
        args.expected_fips_sha,
        args.expected_fips_tree,
    )
    phases = validate_phase_evidence(phase_source, args.platform)
    output = {
        "schema": 1,
        "platform": args.platform,
        "artifact": {
            "desktop": desktop,
            "android": android,
            "appGitSha": args.expected_app_sha,
            "appGitTree": args.expected_app_tree,
            "fipsGitSha": args.expected_fips_sha,
            "fipsGitTree": args.expected_fips_tree,
            "fipsVersion": args.expected_fips_version,
        },
        "publicUiOnly": True,
        "privateStateRead": False,
        "fixtureInvoked": False,
        "appLaunchArgumentsOrEnvironment": False,
        "acceptedSelectorSemantics": "participant-state-not-pending",
        "desktopRelaunchDurability": True,
        "pixelRelaunchDurability": True,
        **phases,
    }
    write_json_atomically(args.output, output)


def validate_receipt(args: argparse.Namespace) -> None:
    receipt = load_json(args.receipt, "desktop↔Pixel receipt")
    require_exact(receipt, "schema", 1, "desktop↔Pixel receipt")
    require_exact(receipt, "platform", args.platform, "desktop↔Pixel receipt")
    require_exact(receipt, "publicUiOnly", True, "desktop↔Pixel receipt")
    require_exact(receipt, "privateStateRead", False, "desktop↔Pixel receipt")
    require_exact(receipt, "fixtureInvoked", False, "desktop↔Pixel receipt")
    require_exact(
        receipt,
        "acceptedSelectorSemantics",
        "participant-state-not-pending",
        "desktop↔Pixel receipt",
    )
    require_exact(receipt, "desktopRelaunchDurability", True, "desktop↔Pixel receipt")
    require_exact(receipt, "pixelRelaunchDurability", True, "desktop↔Pixel receipt")
    validate_phase_evidence(receipt, args.platform)


def validate_android_only(args: argparse.Namespace) -> None:
    for value, label in (
        (args.expected_app_sha, "expected app SHA"),
        (args.expected_app_tree, "expected app tree"),
        (args.expected_fips_sha, "expected FIPS SHA"),
        (args.expected_fips_tree, "expected FIPS tree"),
    ):
        require_git_sha(value, label)
    receipt = load_json(args.receipt, "Android install receipt")
    validated = validate_android_receipt(
        receipt,
        args.apk,
        args.expected_app_sha,
        args.expected_app_tree,
        args.expected_fips_sha,
        args.expected_fips_tree,
    )
    print(validated["apkSha256"])


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser()
    subcommands = root.add_subparsers(dest="command", required=True)
    create = subcommands.add_parser("create")
    create.add_argument("--platform", choices=PLATFORMS, required=True)
    create.add_argument("--desktop-receipt", type=pathlib.Path, required=True)
    create.add_argument(
        "--android-install-receipt", type=pathlib.Path, required=True
    )
    create.add_argument("--android-apk", type=pathlib.Path, required=True)
    create.add_argument("--phase-evidence", type=pathlib.Path, required=True)
    create.add_argument("--expected-app-sha", required=True)
    create.add_argument("--expected-app-tree", required=True)
    create.add_argument("--expected-fips-sha", required=True)
    create.add_argument("--expected-fips-tree", required=True)
    create.add_argument("--expected-fips-version", required=True)
    create.add_argument("--output", type=pathlib.Path, required=True)
    create.set_defaults(function=create_receipt)

    validate = subcommands.add_parser("validate")
    validate.add_argument("--platform", choices=PLATFORMS, required=True)
    validate.add_argument("--receipt", type=pathlib.Path, required=True)
    validate.set_defaults(function=validate_receipt)

    android = subcommands.add_parser("validate-android")
    android.add_argument("--receipt", type=pathlib.Path, required=True)
    android.add_argument("--apk", type=pathlib.Path, required=True)
    android.add_argument("--expected-app-sha", required=True)
    android.add_argument("--expected-app-tree", required=True)
    android.add_argument("--expected-fips-sha", required=True)
    android.add_argument("--expected-fips-tree", required=True)
    android.set_defaults(function=validate_android_only)
    return root


def main() -> None:
    args = parser().parse_args()
    try:
        args.function(args)
    except (OSError, ValueError) as error:
        raise SystemExit(
            f"desktop/mobile manual-join receipt rejected: {error}"
        ) from error


if __name__ == "__main__":
    main()
