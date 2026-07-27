#!/usr/bin/env python3
"""Replay frozen fleet result receipts through the production validators.

This command is intentionally read-only.  It verifies the exact bound files in
an execute result and reruns the same probe/install semantic validators used by
the transactional fleet canary.  Publication calls it after checking the
release, manifest, inventory, and result hashes.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import re
import stat
import sys
from typing import Any

from fleet_release_canary_evidence import (
    EvidenceError,
    validate_install_result,
    validate_probe,
    validate_result_evidence,
)


HEX40 = re.compile(r"^[0-9a-f]{40}$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
SOURCE_FIELDS = (
    "appGitSha",
    "appGitTree",
    "appVersion",
    "fipsGitSha",
    "fipsGitTree",
    "fipsVersion",
)


class ReplayError(RuntimeError):
    """Fleet evidence cannot be replayed exactly."""


def fail(message: str) -> None:
    raise ReplayError(message)


def object_value(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        fail(f"{label} must be a JSON object")
    return value


def load_json(path: pathlib.Path, label: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"{label} is not readable JSON: {error}")
    return object_value(value, label)


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def hex_value(value: Any, pattern: re.Pattern[str], label: str) -> str:
    if not isinstance(value, str) or pattern.fullmatch(value) is None:
        fail(f"{label} is invalid")
    return value


def bound_file(binding: Any, label: str) -> pathlib.Path:
    value = object_value(binding, label)
    if set(value) != {"path", "sha256", "size"}:
        fail(f"{label} must contain exactly: path, sha256, size")
    raw_path = value.get("path")
    if not isinstance(raw_path, str):
        fail(f"{label}.path is required")
    path = pathlib.Path(raw_path)
    if not path.is_absolute():
        fail(f"{label}.path must be absolute")
    try:
        metadata = path.lstat()
    except OSError as error:
        fail(f"{label} is missing: {error}")
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        fail(f"{label} must be a regular non-symlink file")
    if str(path.resolve()) != raw_path:
        fail(f"{label}.path must be canonical")
    expected_sha256 = hex_value(value.get("sha256"), HEX64, f"{label}.sha256")
    size = value.get("size")
    if not isinstance(size, int) or isinstance(size, bool) or size <= 0:
        fail(f"{label}.size must be a positive integer")
    if sha256_file(path) != expected_sha256:
        fail(f"{label} SHA-256 mismatch")
    if metadata.st_size != size:
        fail(f"{label} size mismatch")
    return path


def source_from_manifest(manifest: dict[str, Any]) -> dict[str, str]:
    source: dict[str, str] = {}
    for field in SOURCE_FIELDS:
        value = manifest.get(field)
        if field.endswith(("GitSha", "GitTree")):
            source[field] = hex_value(value, HEX40, f"fleet manifest {field}")
        elif not isinstance(value, str) or not value.strip():
            fail(f"fleet manifest {field} is required")
        else:
            source[field] = value
    return source


def validate_artifacts(
    manifest: dict[str, Any],
    source: dict[str, str],
) -> dict[str, dict[str, Any]]:
    entries = manifest.get("artifacts")
    if not isinstance(entries, list) or not entries:
        fail("fleet manifest requires frozen artifacts")
    artifacts: dict[str, dict[str, Any]] = {}
    for index, entry_value in enumerate(entries):
        entry = object_value(entry_value, f"artifacts[{index}]")
        artifact_id = entry.get("id")
        if not isinstance(artifact_id, str) or not artifact_id.strip():
            fail(f"artifacts[{index}].id is required")
        if artifact_id in artifacts:
            fail(f"duplicate artifact id: {artifact_id}")
        artifact_path = bound_file(
            {
                "path": entry.get("path"),
                "sha256": entry.get("sha256"),
                "size": entry.get("size"),
            },
            f"artifact {artifact_id}",
        )
        receipt_path = bound_file(
            entry.get("receipt"),
            f"artifact {artifact_id} receipt",
        )
        receipt = load_json(receipt_path, f"artifact {artifact_id} receipt")
        for field, expected in source.items():
            if receipt.get(field) != expected:
                fail(f"artifact {artifact_id} receipt {field} mismatch")
        for field in ("platform", "arch"):
            if receipt.get(field) != entry.get(field):
                fail(f"artifact {artifact_id} receipt {field} mismatch")
        if receipt.get("artifactSha256") != entry.get("sha256"):
            fail(f"artifact {artifact_id} receipt artifactSha256 mismatch")
        if receipt.get("artifactSize") != entry.get("size"):
            fail(f"artifact {artifact_id} receipt artifactSize mismatch")
        installed_hash = hex_value(
            receipt.get("installedBinarySha256"),
            HEX64,
            f"artifact {artifact_id} receipt installedBinarySha256",
        )
        payload = object_value(
            entry.get("installPayload"),
            f"artifact {artifact_id} installPayload",
        )
        payload_format = payload.get("format")
        if payload_format not in {"executable", "tar-gz", "zip"}:
            fail(f"artifact {artifact_id} installPayload.format is invalid")
        executable_member = payload.get("executableMember")
        executable_key = (
            "executable"
            if payload_format == "executable"
            else executable_member
        )
        if not isinstance(executable_key, str) or not executable_key.strip():
            fail(
                f"artifact {artifact_id} installPayload.executableMember "
                "is required"
            )
        installed_payloads = object_value(
            receipt.get("installedPayloads"),
            f"artifact {artifact_id} receipt installedPayloads",
        )
        if installed_payloads.get(executable_key) != installed_hash:
            fail(f"artifact {artifact_id} installed executable mismatch")
        artifacts[artifact_id] = {
            **entry,
            "_path": artifact_path,
            "_installed_hash": installed_hash,
        }
    return artifacts


def target_map(
    inventory: dict[str, Any],
    artifacts: dict[str, dict[str, Any]],
) -> dict[str, dict[str, Any]]:
    targets = inventory.get("targets")
    if not isinstance(targets, list) or not targets:
        fail("fleet inventory requires targets")
    mapped: dict[str, dict[str, Any]] = {}
    for index, target_value in enumerate(targets):
        target = object_value(target_value, f"targets[{index}]")
        target_id = target.get("id")
        if not isinstance(target_id, str) or not target_id.strip():
            fail(f"targets[{index}].id is required")
        if target_id in mapped:
            fail(f"duplicate fleet target id: {target_id}")
        artifact = artifacts.get(target.get("artifact"))
        if artifact is None:
            fail(f"target {target_id} references an unknown artifact")
        if target.get("platform") != artifact.get("platform"):
            fail(f"target {target_id} platform mismatch")
        if target.get("arch") != artifact.get("arch"):
            fail(f"target {target_id} architecture mismatch")
        if target.get("deployment", {}).get("authorization") != "install":
            fail(f"target {target_id} is not authorized for installation")
        mapped[target_id] = target
    return mapped


def replay(
    result_path: pathlib.Path,
    manifest_path: pathlib.Path,
    inventory_path: pathlib.Path,
) -> int:
    result = load_json(result_path, "fleet execute result")
    manifest = load_json(manifest_path, "fleet manifest")
    inventory = load_json(inventory_path, "fleet inventory")
    source = source_from_manifest(manifest)
    if result.get("schema") != 2 or result.get("mode") != "execute":
        fail("fleet publication requires schema-2 execute evidence")
    if result.get("status") != "passed":
        fail("fleet publication requires a passed result")
    for field, expected in source.items():
        if result.get(field) != expected:
            fail(f"fleet result {field} mismatch")
    if manifest.get("inventorySha256") != sha256_file(inventory_path):
        fail("fleet manifest inventory SHA-256 mismatch")
    if result.get("manifestSha256") != sha256_file(manifest_path):
        fail("fleet result manifest SHA-256 mismatch")
    if result.get("inventorySha256") != sha256_file(inventory_path):
        fail("fleet result inventory SHA-256 mismatch")
    hex_value(result.get("driverSha256"), HEX64, "fleet result driverSha256")
    hex_value(
        result.get("releaseGateManifestSha256"),
        HEX64,
        "fleet result releaseGateManifestSha256",
    )
    artifacts = validate_artifacts(manifest, source)
    targets = target_map(inventory, artifacts)

    result_targets = result.get("targets")
    if not isinstance(result_targets, list) or len(result_targets) != len(targets):
        fail("fleet result does not contain the exact target set")
    seen: set[str] = set()
    for result_target_value in result_targets:
        result_target = object_value(result_target_value, "fleet result target")
        target_id = result_target.get("id")
        target = targets.get(target_id)
        if target is None or target_id in seen:
            fail("fleet result does not contain the exact target set")
        seen.add(target_id)
        if result_target.get("status") != "passed":
            fail(f"target {target_id} did not pass")
        bindings = validate_result_evidence(
            result_target.get("evidence"),
            {"probe", "install"},
            f"target {target_id} result evidence",
        )
        probe_path = bound_file(
            bindings["probe"],
            f"target {target_id} probe raw receipt",
        )
        install_path = bound_file(
            bindings["install"],
            f"target {target_id} install raw receipt",
        )
        probe_raw = load_json(
            probe_path,
            f"target {target_id} probe raw receipt",
        )
        install_raw = load_json(
            install_path,
            f"target {target_id} install raw receipt",
        )
        probe = validate_probe(probe_raw, target)
        transaction = object_value(
            install_raw.get("transaction"),
            f"target {target_id} install transaction",
        )
        validate_install_result(
            install_raw,
            target,
            artifacts[target["artifact"]],
            source,
            probe,
            transaction.get("id"),
        )
    if seen != set(targets):
        fail("fleet result does not contain the exact target set")
    print(f"replayed canonical fleet evidence for {len(seen)} target(s)")
    return 0


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--result", required=True, type=pathlib.Path)
    parser.add_argument("--manifest", required=True, type=pathlib.Path)
    parser.add_argument("--inventory", required=True, type=pathlib.Path)
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    arguments = parse_args(argv)
    return replay(
        arguments.result.resolve(),
        arguments.manifest.resolve(),
        arguments.inventory.resolve(),
    )


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except (EvidenceError, ReplayError) as error:
        print(f"fleet evidence replay rejected: {error}", file=sys.stderr)
        raise SystemExit(1)
