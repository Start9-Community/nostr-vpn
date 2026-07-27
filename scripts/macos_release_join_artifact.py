#!/usr/bin/env python3
"""Create and independently verify the imported macOS Release join artifact."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import re
import ssl
import subprocess
import sys
import tempfile
from typing import Any

from mobile_release_artifact_receipt import (
    load_json,
    require_equal,
    sha256_file,
    tree_sha256,
)


def run(command: list[str], *, cwd: pathlib.Path | None = None) -> bytes:
    completed = subprocess.run(
        command,
        cwd=cwd,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return completed.stdout


def git_text(root: pathlib.Path, *arguments: str) -> str:
    return run(["git", "-C", str(root), *arguments]).decode().strip()


def git_snapshot(root: pathlib.Path) -> dict[str, str]:
    if git_text(root, "status", "--porcelain", "--untracked-files=all"):
        raise ValueError(f"source checkout is dirty: {root}")
    index = run(["git", "-C", str(root), "ls-files", "-s", "-z"])
    return {
        "head": git_text(root, "rev-parse", "HEAD"),
        "tree": git_text(root, "rev-parse", "HEAD^{tree}"),
        "manifest": hashlib.sha256(index).hexdigest(),
    }


def fips_version(root: pathlib.Path) -> str:
    manifest = root / "crates" / "fips-core" / "Cargo.toml"
    text = manifest.read_text(encoding="utf-8")
    package = re.search(
        r"(?ms)^\[package\]\s*$.*?^version\s*=\s*\"([^\"]+)\"",
        text,
    )
    if not package:
        raise ValueError("could not derive the exact FIPS package version")
    return package.group(1)


def normalized_hex(value: str, length: int, label: str) -> str:
    normalized = re.sub(r"[:\s]", "", value).lower()
    if not re.fullmatch(rf"[0-9a-f]{{{length}}}", normalized):
        raise ValueError(f"{label} must be exactly {length} hexadecimal digits")
    return normalized


def resolve_certificate(identity_sha1: str) -> str:
    expected = normalized_hex(identity_sha1, 40, "signing identity SHA-1")
    output = run(["security", "find-certificate", "-a", "-p"])
    blocks = re.findall(
        rb"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----",
        output,
        re.DOTALL,
    )
    matches = []
    for block in blocks:
        certificate = ssl.PEM_cert_to_DER_cert(block.decode("ascii"))
        if hashlib.sha1(certificate).hexdigest() == expected:
            matches.append(hashlib.sha256(certificate).hexdigest())
    if len(matches) != 1:
        raise ValueError(
            "configured signing identity must resolve to exactly one certificate"
        )
    return matches[0]


def codesign_value(details: str, label: str) -> str:
    prefix = f"{label}="
    for line in details.splitlines():
        if line.startswith(prefix):
            return line.removeprefix(prefix)
    raise ValueError(f"macOS signature has no {label}")


def inspect_signature(app: pathlib.Path) -> dict[str, str]:
    run(["codesign", "--verify", "--deep", "--strict", str(app)])
    completed = subprocess.run(
        ["codesign", "-dvvv", str(app)],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    details = completed.stdout + completed.stderr
    with tempfile.TemporaryDirectory(prefix="nvpn-macos-release-cert.") as directory:
        prefix = pathlib.Path(directory) / "certificate"
        run(
            [
                "codesign",
                "-d",
                f"--extract-certificates={prefix}",
                str(app),
            ]
        )
        certificate = pathlib.Path(f"{prefix}0")
        if not certificate.is_file():
            raise ValueError("macOS signature has no extractable leaf certificate")
        certificate_bytes = certificate.read_bytes()
    return {
        "authority": codesign_value(details, "Authority"),
        "cdhash": codesign_value(details, "CDHash").lower(),
        "certificateSha1": hashlib.sha1(certificate_bytes).hexdigest(),
        "certificateSha256": hashlib.sha256(certificate_bytes).hexdigest(),
        "team": codesign_value(details, "TeamIdentifier"),
    }


def observed_receipt(args: argparse.Namespace) -> dict[str, Any]:
    app = pathlib.Path(args.app).resolve()
    archive = pathlib.Path(args.archive).resolve()
    app_root = pathlib.Path(args.app_root).resolve()
    fips_root = pathlib.Path(args.fips_root).resolve()
    executable = app / "Contents" / "MacOS" / "Nostr VPN"
    for path in (archive, executable):
        if not path.is_file():
            raise ValueError(f"required macOS Release artifact is missing: {path}")
    app_source = git_snapshot(app_root)
    fips_source = git_snapshot(fips_root)
    expected_identity = normalized_hex(
        args.expected_identity_sha1, 40, "signing identity SHA-1"
    )
    expected_signer = normalized_hex(
        args.expected_signer_sha256, 64, "signer certificate SHA-256"
    )
    signature = inspect_signature(app)
    expected = {
        "appGitSha": args.expected_app_head,
        "appGitTree": args.expected_app_tree,
        "fipsGitSha": args.expected_fips_head,
        "fipsGitTree": args.expected_fips_tree,
        "fipsCoreVersion": args.expected_fips_version,
    }
    actual = {
        "appGitSha": app_source["head"],
        "appGitTree": app_source["tree"],
        "fipsGitSha": fips_source["head"],
        "fipsGitTree": fips_source["tree"],
        "fipsCoreVersion": fips_version(fips_root),
    }
    for name, value in expected.items():
        if actual[name] != value:
            raise ValueError(
                f"{name} mismatch: expected {value!r}, got {actual[name]!r}"
            )
    if signature["team"] != args.expected_team:
        raise ValueError("macOS Release app has the wrong signing team")
    if signature["certificateSha1"] != expected_identity:
        raise ValueError("macOS Release app has the wrong signing identity")
    if signature["certificateSha256"] != expected_signer:
        raise ValueError("macOS Release app has the wrong signer certificate")
    if not signature["authority"].startswith("Developer ID Application: "):
        raise ValueError("macOS Release app is not Developer ID signed")
    bundle_manifest = tree_sha256(app)
    return {
        "receiptSchema": 1,
        "artifactType": "macOS company Developer ID Release app",
        "archiveSha256": sha256_file(archive),
        "archiveSize": archive.stat().st_size,
        "appBundleName": app.name,
        "appBundleTreeSha256": bundle_manifest,
        "bundleManifestSha256": bundle_manifest,
        "appExecutableSha256": sha256_file(executable),
        "appCodeDirectoryHash": signature["cdhash"],
        "appGitSha": app_source["head"],
        "appGitTree": app_source["tree"],
        "appSourceManifestSha256": app_source["manifest"],
        "fipsGitSha": fips_source["head"],
        "fipsGitTree": fips_source["tree"],
        "fipsSourceManifestSha256": fips_source["manifest"],
        "fipsCoreVersion": actual["fipsCoreVersion"],
        "signingTeam": signature["team"],
        "signingAuthority": signature["authority"],
        "signingIdentitySha1": signature["certificateSha1"],
        "signerCertificateSha256": signature["certificateSha256"],
        "companySigningVerified": True,
        "configuration": "Release",
        "builtOnHost": True,
        "builtOnTestVm": False,
        "appLaunchArgumentsOrEnvironment": False,
        "privateAppStateRead": False,
    }


def create_receipt(args: argparse.Namespace) -> None:
    receipt = observed_receipt(args)
    pathlib.Path(args.receipt).write_text(
        json.dumps(receipt, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def validate_receipt(args: argparse.Namespace) -> None:
    receipt_path = pathlib.Path(args.receipt)
    receipt = load_json(receipt_path)
    observed = observed_receipt(args)
    for name, value in observed.items():
        require_equal(receipt, name, value)
    verification = {
        "receiptSchema": 1,
        "remoteImportVerified": True,
        "artifactReceiptSha256": sha256_file(receipt_path),
        "archiveSha256": observed["archiveSha256"],
        "bundleManifestSha256": observed["bundleManifestSha256"],
        "appGitSha": observed["appGitSha"],
        "appGitTree": observed["appGitTree"],
        "fipsGitSha": observed["fipsGitSha"],
        "fipsGitTree": observed["fipsGitTree"],
        "fipsSourceManifestSha256": observed["fipsSourceManifestSha256"],
        "signingTeam": observed["signingTeam"],
        "signingIdentitySha1": observed["signingIdentitySha1"],
        "signerCertificateSha256": observed["signerCertificateSha256"],
        "builtOnHost": True,
        "builtOnTestVm": False,
    }
    pathlib.Path(args.verification_output).write_text(
        json.dumps(verification, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def add_common_arguments(command: argparse.ArgumentParser) -> None:
    for name in (
        "receipt",
        "app",
        "archive",
        "app_root",
        "fips_root",
        "expected_app_head",
        "expected_app_tree",
        "expected_fips_head",
        "expected_fips_tree",
        "expected_fips_version",
        "expected_team",
        "expected_identity_sha1",
        "expected_signer_sha256",
    ):
        command.add_argument(f"--{name.replace('_', '-')}", required=True)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    subparsers = result.add_subparsers(dest="command", required=True)
    certificate = subparsers.add_parser("resolve-certificate")
    certificate.add_argument("--identity-sha1", required=True)
    create = subparsers.add_parser("create")
    add_common_arguments(create)
    validate = subparsers.add_parser("validate")
    add_common_arguments(validate)
    validate.add_argument("--verification-output", required=True)
    return result


def main() -> int:
    args = parser().parse_args()
    try:
        if args.command == "resolve-certificate":
            print(resolve_certificate(args.identity_sha1))
        elif args.command == "create":
            create_receipt(args)
        else:
            validate_receipt(args)
    except (
        OSError,
        ValueError,
        json.JSONDecodeError,
        subprocess.CalledProcessError,
    ) as error:
        print(f"macOS Release join artifact rejected: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
