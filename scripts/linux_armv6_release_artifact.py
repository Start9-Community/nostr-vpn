#!/usr/bin/env python3
"""Create and verify the sealed Linux ARMv6 release CLI artifact."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import json
import os
import pathlib
import re
import stat
import struct
import tarfile
from typing import Any


TARGET = "arm-unknown-linux-musleabihf"
ARCHIVE_NAME = f"nvpn-{TARGET}.tar.gz"
MEMBERS = ["nvpn/README.txt", "nvpn/install.sh", "nvpn/nvpn"]
README = """nvpn - FIPS private mesh CLI
============================

Binary included:
  nvpn  - CLI control plane

Quick install:
  ./install.sh
  ./install.sh ~/.local/bin
"""
INSTALL = """#!/bin/bash
set -e

path_contains() {
  case ":${PATH}:" in
    *":$1:"*) return 0 ;;
    *) return 1 ;;
  esac
}

default_install_dir() {
  if [ "$(uname -s)" = "Darwin" ] && { [ -d /opt/homebrew/bin ] || path_contains /opt/homebrew/bin; }; then
    printf '%s\\n' /opt/homebrew/bin
  else
    printf '%s\\n' /usr/local/bin
  fi
}

INSTALL_DIR="${1:-$(default_install_dir)}"
install -d "${INSTALL_DIR}"
install -m 755 nvpn "${INSTALL_DIR}/"
"""


def fail(message: str) -> None:
    raise SystemExit(f"Linux ARMv6 release artifact verification failed: {message}")


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_json(path: pathlib.Path) -> dict[str, Any]:
    def unique(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        value: dict[str, Any] = {}
        for key, item in pairs:
            if key in value:
                fail(f"duplicate JSON field {key}")
            value[key] = item
        return value

    try:
        payload = json.loads(
            path.read_text(encoding="utf-8"), object_pairs_hook=unique
        )
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"could not read {path}: {error}")
    if not isinstance(payload, dict):
        fail(f"{path} is not a JSON object")
    return payload


def exact_hash(value: str, label: str) -> None:
    if not re.fullmatch(r"[0-9a-f]{40}", value):
        fail(f"{label} is not an exact lowercase Git hash")


def exact_sha256(value: Any, label: str) -> None:
    if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value):
        fail(f"{label} is not an exact lowercase SHA-256")


def exact_version(value: str, label: str) -> None:
    if not re.fullmatch(r"\d+\.\d+\.\d+(?:[+-][0-9A-Za-z.-]+)?", value):
        fail(f"{label} is invalid")


def assert_static_arm_elf(binary: bytes) -> None:
    if len(binary) < 52 or binary[:4] != b"\x7fELF":
        fail("binary is not ELF")
    if binary[4:6] != b"\x01\x01":
        fail("binary is not 32-bit little-endian ELF")
    if struct.unpack_from("<H", binary, 18)[0] != 40:
        fail("binary ELF machine is not ARM")
    flags = struct.unpack_from("<I", binary, 36)[0]
    if flags & 0xFF000000 != 0x05000000:
        fail("binary does not declare ARM EABI5")
    if flags & 0x00000400 == 0:
        fail("binary does not declare the hard-float ABI")
    phoff = struct.unpack_from("<I", binary, 28)[0]
    phentsize = struct.unpack_from("<H", binary, 42)[0]
    phnum = struct.unpack_from("<H", binary, 44)[0]
    if phnum and (phentsize < 32 or phoff + phentsize * phnum > len(binary)):
        fail("binary has an invalid ELF program-header table")
    for index in range(phnum):
        if struct.unpack_from("<I", binary, phoff + index * phentsize)[0] == 3:
            fail("binary has a dynamic program interpreter")


def archive_payloads(path: pathlib.Path, epoch: int) -> dict[str, bytes]:
    try:
        raw = path.read_bytes()
    except OSError as error:
        fail(f"could not read archive: {error}")
    if len(raw) < 10 or raw[:2] != b"\x1f\x8b" or raw[4:8] != b"\0\0\0\0":
        fail("archive does not have a deterministic gzip header")
    try:
        with tarfile.open(path, "r:gz") as archive:
            entries = archive.getmembers()
            if [entry.name for entry in entries] != MEMBERS:
                fail("archive member list/order is not exact")
            payloads: dict[str, bytes] = {}
            for entry in entries:
                expected_mode = 0o444 if entry.name.endswith("README.txt") else 0o555
                if (
                    not entry.isfile()
                    or entry.uid != 0
                    or entry.gid != 0
                    or entry.uname
                    or entry.gname
                    or entry.mtime != epoch
                    or stat.S_IMODE(entry.mode) != expected_mode
                ):
                    fail(f"archive metadata is not canonical for {entry.name}")
                extracted = archive.extractfile(entry)
                if extracted is None:
                    fail(f"could not read archive member {entry.name}")
                payloads[entry.name] = extracted.read()
    except (OSError, tarfile.TarError) as error:
        fail(f"could not inspect archive: {error}")
    if payloads[MEMBERS[0]] != README.encode():
        fail("README content is not canonical")
    if payloads[MEMBERS[1]] != INSTALL.encode():
        fail("install script content is not canonical")
    assert_static_arm_elf(payloads[MEMBERS[2]])
    return payloads


def add_member(
    archive: tarfile.TarFile, name: str, payload: bytes, mode: int, epoch: int
) -> None:
    info = tarfile.TarInfo(name)
    info.size = len(payload)
    info.mode = mode
    info.mtime = epoch
    info.uid = 0
    info.gid = 0
    info.uname = ""
    info.gname = ""
    archive.addfile(info, io.BytesIO(payload))


def package(args: argparse.Namespace) -> None:
    binary_path = pathlib.Path(args.binary)
    archive_path = pathlib.Path(args.archive)
    if binary_path.is_symlink() or not binary_path.is_file():
        fail("build output is not a regular, non-symlink binary")
    binary = binary_path.read_bytes()
    assert_static_arm_elf(binary)
    archive_path.parent.mkdir(parents=True, exist_ok=True)
    tar_buffer = io.BytesIO()
    with tarfile.open(fileobj=tar_buffer, mode="w", format=tarfile.USTAR_FORMAT) as tar:
        add_member(tar, MEMBERS[0], README.encode(), 0o444, args.epoch)
        add_member(tar, MEMBERS[1], INSTALL.encode(), 0o555, args.epoch)
        add_member(tar, MEMBERS[2], binary, 0o555, args.epoch)
    with archive_path.open("wb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as zipped:
            zipped.write(tar_buffer.getvalue())
    archive_payloads(archive_path, args.epoch)


def parse_smoke(
    path: pathlib.Path,
    app_version: str,
    fips_version: str,
    fips_sha: str,
    binary_sha: str,
) -> dict[str, Any]:
    smoke = load_json(path)
    parse_smoke_payload(
        smoke,
        app_version,
        fips_version,
        fips_sha,
        binary_sha,
    )
    return smoke


def write_smoke(args: argparse.Namespace) -> None:
    try:
        version = json.loads(
            pathlib.Path(args.version_json).read_text(encoding="utf-8")
        )
        verbose_version = pathlib.Path(args.verbose_version).read_text(
            encoding="utf-8"
        ).strip()
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"could not read ARMv6 version output: {error}")
    if not isinstance(version, dict):
        fail("ARMv6 version output is not a JSON object")
    payload = {
        "realChecks": True,
        "mocked": False,
        "installPerformed": False,
        "networkMutated": False,
        "hostArchitecture": args.host_architecture,
        "remoteBinarySha256": args.remote_sha,
        "version": version,
        "verboseVersion": verbose_version,
        "cleaned": True,
    }
    pathlib.Path(args.output).write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    parse_smoke_payload(
        payload,
        args.app_version,
        args.fips_version,
        args.fips_sha,
        args.binary_sha,
    )


def write_receipt(args: argparse.Namespace) -> None:
    archive_path = pathlib.Path(args.archive)
    payloads = archive_payloads(archive_path, args.epoch)
    binary = payloads["nvpn/nvpn"]
    smoke = None
    if args.smoke:
        smoke = parse_smoke(
            pathlib.Path(args.smoke),
            args.app_version,
            args.fips_version,
            args.fips_sha,
            sha256_bytes(binary),
        )
    payload = {
        "schema": 1,
        "artifactType": "sealed Linux ARMv6 static-musl CLI",
        "appGitSha": args.app_sha,
        "appGitTree": args.app_tree,
        "appVersion": args.app_version,
        "fipsGitSha": args.fips_sha,
        "fipsGitTree": args.fips_tree,
        "fipsVersion": args.fips_version,
        "target": TARGET,
        "fleetArch": "armv6",
        "builderImage": args.builder_image,
        "builderImageId": args.builder_image_id,
        "sourceDateEpoch": args.epoch,
        "archive": {
            "file": ARCHIVE_NAME,
            "sha256": sha256_file(archive_path),
            "size": archive_path.stat().st_size,
            "members": MEMBERS,
        },
        "binary": {
            "member": "nvpn/nvpn",
            "sha256": sha256_bytes(binary),
            "size": len(binary),
        },
        "smoke": smoke,
    }
    pathlib.Path(args.receipt).write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )


def verify(args: argparse.Namespace) -> None:
    directory = pathlib.Path(args.directory)
    archive_path = directory / ARCHIVE_NAME
    receipt_path = directory / "receipt.json"
    if directory.is_symlink() or not directory.is_dir():
        fail("artifact directory is missing or is a symlink")
    if sorted(entry.name for entry in directory.iterdir()) != [
        ARCHIVE_NAME,
        "receipt.json",
    ]:
        fail("artifact directory contains unexpected files")
    for path in (archive_path, receipt_path):
        metadata = path.lstat()
        if not stat.S_ISREG(metadata.st_mode) or path.is_symlink():
            fail(f"{path.name} is not a regular file")
        if metadata.st_mode & 0o222:
            fail(f"{path.name} is writable")
    receipt = load_json(receipt_path)
    payloads = archive_payloads(archive_path, args.epoch)
    binary = payloads["nvpn/nvpn"]
    expected = {
        "schema": 1,
        "artifactType": "sealed Linux ARMv6 static-musl CLI",
        "appGitSha": args.app_sha,
        "appGitTree": args.app_tree,
        "appVersion": args.app_version,
        "fipsGitSha": args.fips_sha,
        "fipsGitTree": args.fips_tree,
        "fipsVersion": args.fips_version,
        "target": TARGET,
        "fleetArch": "armv6",
        "builderImage": args.builder_image,
        "builderImageId": args.builder_image_id,
        "sourceDateEpoch": args.epoch,
        "archive": {
            "file": ARCHIVE_NAME,
            "sha256": sha256_file(archive_path),
            "size": archive_path.stat().st_size,
            "members": MEMBERS,
        },
        "binary": {
            "member": "nvpn/nvpn",
            "sha256": sha256_bytes(binary),
            "size": len(binary),
        },
    }
    for key, value in expected.items():
        if receipt.get(key) != value:
            fail(f"receipt mismatch for {key}")
    if set(receipt) != set(expected) | {"smoke"}:
        fail("receipt has missing or unexpected fields")
    smoke = receipt.get("smoke")
    if args.require_smoke and not isinstance(smoke, dict):
        fail("real ARMv6 smoke evidence is required")
    if isinstance(smoke, dict):
        parse_smoke_payload(
            smoke,
            args.app_version,
            args.fips_version,
            args.fips_sha,
            sha256_bytes(binary),
        )
    elif smoke is not None:
        fail("smoke evidence must be an object or null")
    if args.smoke_copy:
        observed = parse_smoke(
            pathlib.Path(args.smoke_copy),
            args.app_version,
            args.fips_version,
            args.fips_sha,
            sha256_bytes(binary),
        )
        if observed != smoke:
            fail("current ARMv6 smoke differs from the sealed receipt")


def parse_smoke_payload(
    smoke: dict[str, Any],
    app_version: str,
    fips_version: str,
    fips_sha: str,
    binary_sha: str,
) -> None:
    expected_fips = f"{fips_version} (rev {fips_sha[:10]})"
    if smoke != {
        "realChecks": True,
        "mocked": False,
        "installPerformed": False,
        "networkMutated": False,
        "hostArchitecture": "armv6l",
        "remoteBinarySha256": binary_sha,
        "version": {
            "version": app_version,
            "fips_core_version": expected_fips,
        },
        "verboseVersion": f"{app_version}\nfips_core_version: {expected_fips}",
        "cleaned": True,
    }:
        fail("real ARMv6 smoke evidence is incomplete or does not match the binary")


def extract(args: argparse.Namespace) -> None:
    payloads = archive_payloads(pathlib.Path(args.archive), args.epoch)
    output = pathlib.Path(args.output)
    output.write_bytes(payloads["nvpn/nvpn"])
    output.chmod(0o555)


def identity_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--app-sha", required=True)
    parser.add_argument("--app-tree", required=True)
    parser.add_argument("--app-version", required=True)
    parser.add_argument("--fips-sha", required=True)
    parser.add_argument("--fips-tree", required=True)
    parser.add_argument("--fips-version", required=True)
    parser.add_argument("--builder-image", required=True)
    parser.add_argument("--builder-image-id", required=True)
    parser.add_argument("--epoch", required=True, type=int)


def validate_identity(args: argparse.Namespace) -> None:
    exact_hash(args.app_sha, "appGitSha")
    exact_hash(args.app_tree, "appGitTree")
    exact_hash(args.fips_sha, "fipsGitSha")
    exact_hash(args.fips_tree, "fipsGitTree")
    exact_version(args.app_version, "appVersion")
    exact_version(args.fips_version, "fipsVersion")
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", args.builder_image_id):
        fail("builderImageId is not an exact image content digest")
    if not args.builder_image.strip():
        fail("builderImage is empty")
    if args.epoch < 0:
        fail("sourceDateEpoch is negative")


def main() -> None:
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    package_parser = commands.add_parser("package")
    package_parser.add_argument("--binary", required=True)
    package_parser.add_argument("--archive", required=True)
    package_parser.add_argument("--epoch", required=True, type=int)
    package_parser.set_defaults(run=package)

    write_parser = commands.add_parser("write-receipt")
    write_parser.add_argument("--archive", required=True)
    write_parser.add_argument("--receipt", required=True)
    write_parser.add_argument("--smoke")
    identity_arguments(write_parser)
    write_parser.set_defaults(run=write_receipt)

    smoke_parser = commands.add_parser("write-smoke")
    smoke_parser.add_argument("--version-json", required=True)
    smoke_parser.add_argument("--verbose-version", required=True)
    smoke_parser.add_argument("--output", required=True)
    smoke_parser.add_argument("--host-architecture", required=True)
    smoke_parser.add_argument("--remote-sha", required=True)
    smoke_parser.add_argument("--binary-sha", required=True)
    smoke_parser.add_argument("--app-version", required=True)
    smoke_parser.add_argument("--fips-version", required=True)
    smoke_parser.add_argument("--fips-sha", required=True)
    smoke_parser.set_defaults(run=write_smoke)

    verify_parser = commands.add_parser("verify")
    verify_parser.add_argument("--directory", required=True)
    verify_parser.add_argument("--require-smoke", action="store_true")
    verify_parser.add_argument("--smoke-copy")
    identity_arguments(verify_parser)
    verify_parser.set_defaults(run=verify)

    extract_parser = commands.add_parser("extract")
    extract_parser.add_argument("--archive", required=True)
    extract_parser.add_argument("--output", required=True)
    extract_parser.add_argument("--epoch", required=True, type=int)
    extract_parser.set_defaults(run=extract)

    args = parser.parse_args()
    if args.command in {"write-receipt", "verify"}:
        validate_identity(args)
    args.run(args)


if __name__ == "__main__":
    main()
