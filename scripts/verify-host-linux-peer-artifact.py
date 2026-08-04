#!/usr/bin/env python3
"""Verify the immutable host-built Linux peer receipt used by release gates."""

from __future__ import annotations

import hashlib
import json
import os
import pathlib
import re
import stat
import sys
from typing import Any


def fail(message: str) -> None:
    raise SystemExit(f"host Linux peer artifact verification failed: {message}")


def load_receipt(path: pathlib.Path) -> dict[str, Any]:
    def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in pairs:
            if key in result:
                fail(f"duplicate receipt field {key}")
            result[key] = value
        return result

    try:
        payload = json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=reject_duplicate_keys,
        )
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        fail(f"could not read receipt: {exc}")
    if not isinstance(payload, dict):
        fail("receipt is not a JSON object")
    return payload


def main() -> None:
    if len(sys.argv) != 9:
        fail(
            "expected RECEIPT BINARY APP_SHA APP_TREE FIPS_SHA FIPS_TREE "
            "FIPS_VERSION TARGET"
        )
    (
        receipt_arg,
        binary_arg,
        app_sha,
        app_tree,
        fips_sha,
        fips_tree,
        fips_version,
        target,
    ) = sys.argv[1:]
    for label, value in (
        ("app Git SHA", app_sha),
        ("app Git tree", app_tree),
        ("FIPS Git SHA", fips_sha),
        ("FIPS Git tree", fips_tree),
    ):
        if not re.fullmatch(r"[0-9a-f]{40}", value):
            fail(f"{label} is not an exact lowercase hash")
    if not re.fullmatch(r"\d+\.\d+\.\d+(?:[+-][0-9A-Za-z.-]+)?", fips_version):
        fail("FIPS version is invalid")
    if target != "x86_64-unknown-linux-musl":
        fail(f"unsupported target {target}")

    receipt_path = pathlib.Path(receipt_arg)
    binary_path = pathlib.Path(binary_arg)
    try:
        metadata = binary_path.stat()
    except OSError as exc:
        fail(f"could not stat binary: {exc}")
    if not stat.S_ISREG(metadata.st_mode):
        fail("binary is not a regular file")
    if not os.access(binary_path, os.X_OK):
        fail("binary is not executable")
    if metadata.st_mode & 0o222:
        fail("binary is writable")

    receipt = load_receipt(receipt_path)
    expected: dict[str, Any] = {
        "schema": 1,
        "appGitSha": app_sha,
        "appGitTree": app_tree,
        "fipsGitSha": fips_sha,
        "fipsGitTree": fips_tree,
        "fipsVersion": fips_version,
        "target": target,
        "binarySize": metadata.st_size,
    }
    for key, value in expected.items():
        if receipt.get(key) != value:
            fail(f"receipt mismatch for {key}")
    local_build = (
        receipt.get("builtOnHostMac") is True
        and receipt.get("builtOnRemoteVm") is False
    )
    remote_build = (
        receipt.get("builtOnHostMac") is False
        and receipt.get("builtOnRemoteVm") is True
        and receipt.get("builtOnMacosUtm") is False
        and receipt.get("buildExecutionHostClass") == "remote-linux-builder"
    )
    if not (local_build or remote_build):
        fail("receipt has no approved build execution class")
    digest = hashlib.sha256(binary_path.read_bytes()).hexdigest()
    if receipt.get("binarySha256") != digest:
        fail("binary SHA-256 does not match the receipt")


if __name__ == "__main__":
    main()
