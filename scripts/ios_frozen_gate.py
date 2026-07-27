#!/usr/bin/env python3
"""Seal real-device evidence to one frozen iOS archive export."""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import tempfile
from typing import Any

from mobile_release_artifact_receipt import load_json, sha256_file


RECEIPT_SCHEMA = 1


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def atomic_json(path: pathlib.Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", dir=path.parent
    )
    temporary = pathlib.Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(value, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def required_string(
    value: Any,
    label: str,
    pattern: str,
) -> str:
    require(
        isinstance(value, str) and re.fullmatch(pattern, value) is not None,
        f"{label} is missing or malformed",
    )
    return value


def required_hash(value: Any, label: str, length: int) -> str:
    return required_string(value, label, rf"[0-9a-f]{{{length}}}")


def validate_archive_and_adhoc(
    archive: dict[str, Any],
    adhoc: dict[str, Any],
    archive_receipt_sha256: str,
) -> tuple[dict[str, Any], dict[str, Any]]:
    require(
        archive.get("receiptSchema") == RECEIPT_SCHEMA
        and archive.get("artifactType") == "iOS frozen App Store xcarchive",
        "gate seal received the wrong frozen archive receipt",
    )
    require(
        adhoc.get("receiptSchema") == RECEIPT_SCHEMA
        and adhoc.get("artifactType")
        == "iOS export from frozen xcarchive"
        and adhoc.get("distribution") == "release-testing",
        "gate seal requires a release-testing export",
    )
    for receipt, prefix in ((archive, "archive"), (adhoc, "Ad Hoc export")):
        required_hash(
            receipt.get("archiveTreeSha256"),
            f"{prefix} archive tree hash",
            64,
        )
        required_hash(receipt.get("appGitSha"), f"{prefix} app Git SHA", 40)
        required_hash(receipt.get("appGitTree"), f"{prefix} app Git tree", 40)
        required_hash(receipt.get("fipsGitSha"), f"{prefix} FIPS Git SHA", 40)
        required_hash(
            receipt.get("fipsGitTree"),
            f"{prefix} FIPS Git tree",
            40,
        )
        required_string(
            receipt.get("fipsCoreVersion"),
            f"{prefix} FIPS version",
            r"[0-9]+\.[0-9]+\.[0-9]+(?:[+-][0-9A-Za-z.-]+)?",
        )
    for name in ("archiveAppBundleTreeSha256", "archivePathSha256"):
        required_hash(archive.get(name), f"archive {name}", 64)
    required_hash(
        adhoc.get("appBundleTreeSha256"),
        "Ad Hoc app bundle tree",
        64,
    )
    required_hash(adhoc.get("ipaPathSha256"), "Ad Hoc IPA path hash", 64)
    required_hash(adhoc.get("ipaSha256"), "Ad Hoc IPA hash", 64)
    required_hash(
        adhoc.get("archiveReceiptSha256"),
        "Ad Hoc frozen-archive receipt hash",
        64,
    )
    identity = archive.get("identity")
    require(isinstance(identity, dict), "frozen archive lacks code identity")
    required_string(
        identity.get("buildNumber"),
        "frozen archive build number",
        r"[1-9][0-9]*",
    )
    required_string(
        identity.get("marketingVersion"),
        "frozen archive marketing version",
        r"[0-9]+\.[0-9]+\.[0-9]+",
    )
    required_string(
        identity.get("appBundleIdentifier"),
        "frozen archive app bundle identifier",
        r"[A-Za-z0-9][A-Za-z0-9.-]+",
    )
    for name in (
        "fipsCargoMetadataReceiptPathSha256",
        "fipsCargoMetadataReceiptSha256",
        "fipsCheckoutPathSha256",
    ):
        required_hash(archive.get(name), f"archive {name}", 64)
    signing = adhoc.get("signing")
    require(
        isinstance(signing, dict),
        "release-testing export lacks signing evidence",
    )
    required_hash(
        signing.get("appCodeDirectoryHash"),
        "Ad Hoc app CodeDirectory hash",
        40,
    )
    required_hash(
        signing.get("packetTunnelCodeDirectoryHash"),
        "Ad Hoc Packet Tunnel CodeDirectory hash",
        40,
    )
    required_hash(
        signing.get("appProvisioningProfileSha256"),
        "Ad Hoc app provisioning profile hash",
        64,
    )
    required_hash(
        signing.get("packetTunnelProvisioningProfileSha256"),
        "Ad Hoc Packet Tunnel provisioning profile hash",
        64,
    )
    required_hash(
        signing.get("signerCertificateSha256"),
        "Ad Hoc signer certificate hash",
        64,
    )
    required_string(
        signing.get("signingTeamIdentifier"),
        "Ad Hoc signing team",
        r"[A-Z0-9]{10}",
    )
    require(
        adhoc.get("archiveTreeSha256") == archive.get("archiveTreeSha256")
        and adhoc.get("archiveReceiptSha256") == archive_receipt_sha256
        and adhoc.get("appGitSha") == archive.get("appGitSha")
        and adhoc.get("appGitTree") == archive.get("appGitTree")
        and adhoc.get("fipsGitSha") == archive.get("fipsGitSha")
        and adhoc.get("fipsGitTree") == archive.get("fipsGitTree")
        and adhoc.get("fipsCoreVersion") == archive.get("fipsCoreVersion")
        and adhoc.get("identity") == identity,
        "release-testing export is not tied to the frozen archive",
    )
    return identity, signing


def validate_mobile_receipt(
    archive: dict[str, Any],
    adhoc: dict[str, Any],
    identity: dict[str, Any],
    adhoc_signing: dict[str, Any],
    mobile: dict[str, Any],
) -> dict[str, Any]:
    require(
        mobile.get("receiptSchema") == 2
        and mobile.get("artifactType") == "iOS company Ad Hoc Release app"
        and mobile.get("companySigningVerified") is True
        and mobile.get("fipsDependenciesForcedRebuilt") is True
        and mobile.get("cashuAndPaidExitCompiled") is False
        and mobile.get("paidExitWalletWorkerCompiled") is False
        and mobile.get("updaterCompiled") is False
        and mobile.get("debuggable") is False,
        "physical mobile receipt is not a strict signed Release receipt",
    )
    selected_device = mobile.get("selectedPhysicalDevice")
    require(
        isinstance(selected_device, dict)
        and selected_device.get("explicitPhysicalDeviceVerified") is True
        and selected_device.get("platform") == "iOS",
        "physical mobile receipt lacks an explicit physical iPhone",
    )
    required_hash(
        selected_device.get("deviceIdentifierSha256"),
        "physical iPhone identifier hash",
        64,
    )
    required_string(
        selected_device.get("model"),
        "physical iPhone model",
        r".+",
    )
    required_string(
        selected_device.get("productType"),
        "physical iPhone product type",
        r".+",
    )
    require(
        mobile.get("selectedPhysicalDeviceIdentifierSha256")
        == selected_device.get("deviceIdentifierSha256"),
        "physical iPhone identifier evidence is inconsistent",
    )
    for name, label in (
        ("appExecutableSha256", "physical app executable hash"),
        (
            "packetTunnelExecutableSha256",
            "physical Packet Tunnel executable hash",
        ),
        ("appPathSha256", "physical app path hash"),
        ("derivedDataPathSha256", "physical DerivedData path hash"),
        ("testProductsPathSha256", "physical test-products path hash"),
        ("testProductsTreeSha256", "physical test-products tree"),
        ("xctestrunPathSha256", "physical xctestrun path hash"),
        ("xctestrunSha256", "physical xctestrun hash"),
        ("fipsCheckoutPathSha256", "physical FIPS checkout path hash"),
        (
            "fipsCargoMetadataReceiptPathSha256",
            "physical FIPS metadata path hash",
        ),
        (
            "fipsCargoMetadataReceiptSha256",
            "physical FIPS metadata receipt hash",
        ),
    ):
        required_hash(mobile.get(name), label, 64)
    required_hash(
        mobile.get("appCodeDirectoryHash"),
        "physical app CodeDirectory hash",
        40,
    )
    required_hash(
        mobile.get("packetTunnelCodeDirectoryHash"),
        "physical Packet Tunnel CodeDirectory hash",
        40,
    )
    required_hash(
        mobile.get("appProvisioningProfileSha256"),
        "physical app provisioning profile hash",
        64,
    )
    required_hash(
        mobile.get("packetTunnelProvisioningProfileSha256"),
        "physical Packet Tunnel provisioning profile hash",
        64,
    )
    required_hash(
        mobile.get("signerCertificateSha256"),
        "physical signer certificate hash",
        64,
    )
    required_hash(
        mobile.get("appBundleTreeSha256"),
        "physical app bundle tree",
        64,
    )
    required_hash(mobile.get("appGitSha"), "physical app Git SHA", 40)
    required_hash(mobile.get("appGitTree"), "physical app Git tree", 40)
    required_hash(mobile.get("fipsGitSha"), "physical FIPS Git SHA", 40)
    required_hash(mobile.get("fipsGitTree"), "physical FIPS Git tree", 40)
    required_string(
        mobile.get("fipsCoreVersion"),
        "physical FIPS version",
        r"[0-9]+\.[0-9]+\.[0-9]+(?:[+-][0-9A-Za-z.-]+)?",
    )
    required_string(
        mobile.get("installedBuildNumber"),
        "physical installed build number",
        r"[1-9][0-9]*",
    )
    required_string(
        mobile.get("installedMarketingVersion"),
        "physical installed marketing version",
        r"[0-9]+\.[0-9]+\.[0-9]+",
    )
    require(
        mobile.get("appCodeDirectoryHash")
        == adhoc_signing.get("appCodeDirectoryHash")
        and mobile.get("packetTunnelCodeDirectoryHash")
        == adhoc_signing.get("packetTunnelCodeDirectoryHash"),
        "physical mobile receipt tested different iOS CodeDirectory hashes",
    )
    require(
        mobile.get("appProvisioningProfileSha256")
        == adhoc_signing.get("appProvisioningProfileSha256")
        and mobile.get("packetTunnelProvisioningProfileSha256")
        == adhoc_signing.get("packetTunnelProvisioningProfileSha256")
        and mobile.get("signerCertificateSha256")
        == adhoc_signing.get("signerCertificateSha256"),
        "physical mobile receipt tested different iOS signing material",
    )
    require(
        mobile.get("appBundleTreeSha256") == adhoc.get("appBundleTreeSha256"),
        "physical mobile receipt tested a different iOS app tree",
    )
    require(
        mobile.get("treeSha256") == mobile.get("appBundleTreeSha256"),
        "physical mobile receipt has inconsistent app tree evidence",
    )
    require(
        mobile.get("fipsCheckoutPathSha256")
        == archive.get("fipsCheckoutPathSha256")
        and mobile.get("fipsCargoMetadataReceiptPathSha256")
        == archive.get("fipsCargoMetadataReceiptPathSha256")
        and mobile.get("fipsCargoMetadataReceiptSha256")
        == archive.get("fipsCargoMetadataReceiptSha256"),
        "physical mobile receipt used different FIPS linkage evidence",
    )
    require(
        mobile.get("appGitSha") == archive.get("appGitSha")
        and mobile.get("appGitTree") == archive.get("appGitTree")
        and mobile.get("fipsGitSha") == archive.get("fipsGitSha")
        and mobile.get("fipsGitTree") == archive.get("fipsGitTree")
        and mobile.get("fipsCoreVersion") == archive.get("fipsCoreVersion")
        and mobile.get("installedBuildNumber") == identity.get("buildNumber")
        and mobile.get("installedMarketingVersion")
        == identity.get("marketingVersion"),
        "physical mobile receipt has the wrong source or version",
    )
    require(
        mobile.get("installedBundleIdentifier")
        == identity.get("appBundleIdentifier"),
        "physical mobile receipt installed the wrong app bundle",
    )
    return {
        "appBundleTreeSha256": mobile.get("appBundleTreeSha256"),
        "appCodeDirectoryHash": mobile.get("appCodeDirectoryHash"),
        "appGitSha": mobile.get("appGitSha"),
        "appGitTree": mobile.get("appGitTree"),
        "appProvisioningProfileSha256": mobile.get(
            "appProvisioningProfileSha256"
        ),
        "fipsCoreVersion": mobile.get("fipsCoreVersion"),
        "fipsGitSha": mobile.get("fipsGitSha"),
        "fipsGitTree": mobile.get("fipsGitTree"),
        "installedBuildNumber": mobile.get("installedBuildNumber"),
        "installedMarketingVersion": mobile.get(
            "installedMarketingVersion"
        ),
        "packetTunnelCodeDirectoryHash": mobile.get(
            "packetTunnelCodeDirectoryHash"
        ),
        "packetTunnelProvisioningProfileSha256": mobile.get(
            "packetTunnelProvisioningProfileSha256"
        ),
        "signerCertificateSha256": mobile.get(
            "signerCertificateSha256"
        ),
    }


def seal_gate(args: argparse.Namespace) -> None:
    archive_receipt = pathlib.Path(args.archive_receipt)
    archive = load_json(archive_receipt)
    adhoc = load_json(pathlib.Path(args.adhoc_receipt))
    mobile = load_json(pathlib.Path(args.mobile_receipt))
    identity, adhoc_signing = validate_archive_and_adhoc(
        archive,
        adhoc,
        sha256_file(archive_receipt),
    )
    mobile_evidence = validate_mobile_receipt(
        archive,
        adhoc,
        identity,
        adhoc_signing,
        mobile,
    )
    required_gates = sorted(set(args.required_gate))
    require(required_gates, "gate seal requires named real-device gates")
    sealed_mobile_receipt = pathlib.Path(args.sealed_mobile_receipt)
    atomic_json(sealed_mobile_receipt, mobile)
    value = {
        "receiptSchema": RECEIPT_SCHEMA,
        "artifactType": "iOS frozen archive physical-gate seal",
        "adhocExportReceiptSha256": sha256_file(pathlib.Path(args.adhoc_receipt)),
        "archiveReceiptSha256": sha256_file(pathlib.Path(args.archive_receipt)),
        "archiveTreeSha256": archive["archiveTreeSha256"],
        "mobileArtifactReceiptSha256": sha256_file(sealed_mobile_receipt),
        "mobileArtifactEvidence": mobile_evidence,
        "requiredRealDeviceGates": required_gates,
    }
    atomic_json(pathlib.Path(args.output), value)


def validate_gate_seal(args: argparse.Namespace) -> None:
    seal = load_json(pathlib.Path(args.gate_seal))
    archive_receipt = pathlib.Path(args.archive_receipt)
    archive = load_json(archive_receipt)
    adhoc = load_json(pathlib.Path(args.adhoc_receipt))
    sealed_mobile_receipt = pathlib.Path(args.sealed_mobile_receipt)
    mobile = load_json(sealed_mobile_receipt)
    require(
        seal.get("receiptSchema") == RECEIPT_SCHEMA
        and seal.get("artifactType")
        == "iOS frozen archive physical-gate seal",
        "iOS physical-gate seal has the wrong type",
    )
    identity, signing = validate_archive_and_adhoc(
        archive,
        adhoc,
        sha256_file(archive_receipt),
    )
    expected_evidence = validate_mobile_receipt(
        archive,
        adhoc,
        identity,
        signing,
        mobile,
    )
    required_hash(
        seal.get("archiveReceiptSha256"),
        "sealed archive receipt hash",
        64,
    )
    required_hash(
        seal.get("adhocExportReceiptSha256"),
        "sealed Ad Hoc receipt hash",
        64,
    )
    required_hash(
        seal.get("mobileArtifactReceiptSha256"),
        "sealed mobile receipt hash",
        64,
    )
    required_hash(
        seal.get("archiveTreeSha256"),
        "sealed archive tree hash",
        64,
    )
    require(
        seal.get("archiveReceiptSha256")
        == sha256_file(pathlib.Path(args.archive_receipt))
        and seal.get("adhocExportReceiptSha256")
        == sha256_file(pathlib.Path(args.adhoc_receipt))
        and seal.get("mobileArtifactReceiptSha256")
        == sha256_file(sealed_mobile_receipt)
        and seal.get("archiveTreeSha256") == archive.get("archiveTreeSha256"),
        "iOS physical-gate seal is stale",
    )
    require(
        adhoc.get("archiveTreeSha256") == archive.get("archiveTreeSha256"),
        "sealed release-testing export does not match the frozen archive",
    )
    evidence = seal.get("mobileArtifactEvidence")
    require(
        isinstance(evidence, dict),
        "iOS physical-gate seal lacks artifact evidence",
    )
    require(
        evidence == expected_evidence,
        "iOS physical-gate seal tested a different artifact",
    )
    required = set(args.required_gate)
    required_list = sorted(required)
    observed_list = seal.get("requiredRealDeviceGates")
    require(
        required
        and isinstance(observed_list, list)
        and all(isinstance(value, str) and value for value in observed_list)
        and observed_list == required_list,
        f"iOS physical-gate seal mismatch: expected {required_list}, "
        f"got {observed_list!r}",
    )
