#!/usr/bin/env python3
"""Checked-in SSH transport for the transactional fleet canary protocol.

All machine names and paths come from an ignored inventory.  The platform
adapters are streamed over SSH and never installed permanently.  Candidate
artifacts are copied byte-for-byte and verified remotely before an adapter is
allowed to stop a service or replace a file.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import pathlib
import re
import stat
import subprocess
import sys
from typing import Any


HOST = re.compile(r"^[A-Za-z0-9_.@:-]+$")
TRANSACTION = re.compile(r"^[0-9a-f]{32}$")
PROTOCOL = "nvpn-fleet-ssh-transactional-v2"


class DriverError(RuntimeError):
    """A local transport or adapter failure."""


def load_json(path: pathlib.Path, label: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise DriverError(f"{label} is not readable JSON: {error}") from error
    if not isinstance(value, dict):
        raise DriverError(f"{label} must be a JSON object")
    return value


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require_regular(path: pathlib.Path, label: str) -> None:
    metadata = path.lstat()
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        raise DriverError(f"{label} must be a regular non-symlink file")


def atomic_json(path: pathlib.Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp-{os.getpid()}")
    temporary.write_text(
        json.dumps(value, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    temporary.chmod(0o600)
    temporary.replace(path)


def transport_arguments(target: dict[str, Any], command: str) -> list[str]:
    transport = target.get("transport")
    if not isinstance(transport, dict) or transport.get("kind") != "ssh":
        raise DriverError("target transport must be ssh")
    host = transport.get("hostAlias")
    if not isinstance(host, str) or HOST.fullmatch(host) is None:
        raise DriverError("target SSH host alias is invalid")
    arguments = [
        command,
        "-q",
        "-o",
        "BatchMode=yes",
        "-o",
        "ConnectTimeout=10",
        "-o",
        "ServerAliveInterval=5",
        "-o",
        "ServerAliveCountMax=2",
    ]
    port = transport.get("port")
    if port is not None:
        if (
            not isinstance(port, int)
            or isinstance(port, bool)
            or not 1 <= port <= 65535
        ):
            raise DriverError("target SSH port is invalid")
        arguments.extend(["-p" if command == "ssh" else "-P", str(port)])
    proxy_jump = transport.get("proxyJump")
    if proxy_jump is not None:
        if not isinstance(proxy_jump, str) or HOST.fullmatch(proxy_jump) is None:
            raise DriverError("target SSH proxyJump is invalid")
        arguments.extend(["-J", proxy_jump])
    arguments.append(host)
    return arguments


def classify_ssh_failure(result: subprocess.CompletedProcess[str]) -> int:
    details = f"{result.stdout}\n{result.stderr}".lower()
    if any(
        marker in details
        for marker in (
            "permission denied",
            "authentication failed",
            "no supported authentication methods",
        )
    ):
        return 76
    if result.returncode == 255 and any(
        marker in details
        for marker in (
            "connection refused",
            "connection timed out",
            "could not resolve hostname",
            "name or service not known",
            "network is unreachable",
            "no route to host",
            "connection closed",
        )
    ):
        return 75
    return 1


def stage_artifact(
    target: dict[str, Any],
    artifact: pathlib.Path,
    transaction_id: str,
) -> str:
    stage_name = f".nvpn-fleet-{transaction_id}.artifact"
    destination = f"{transport_arguments(target, 'scp')[-1]}:{stage_name}"
    arguments = transport_arguments(target, "scp")
    arguments[-1:] = [str(artifact), destination]
    result = subprocess.run(
        arguments,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        code = classify_ssh_failure(result)
        raise DriverError(
            f"artifact transport failed (classification {code}): "
            f"{result.stderr.strip() or result.stdout.strip()}"
        )
    return stage_name


def adapter_source(platform_name: str) -> pathlib.Path:
    suffix = "linux.py" if platform_name == "linux" else "windows.ps1"
    return (
        pathlib.Path(__file__)
        .resolve()
        .with_name(f"fleet_release_canary_remote_{suffix}")
    )


def invoke_adapter(
    target: dict[str, Any],
    payload: dict[str, Any],
) -> tuple[int, dict[str, Any] | None, str]:
    platform_name = target.get("platform")
    if platform_name not in {"linux", "windows"}:
        raise DriverError("only Linux and Windows fleet targets are supported")
    source_path = adapter_source(platform_name)
    require_regular(source_path, f"{platform_name} fleet adapter")
    encoded = base64.b64encode(
        json.dumps(payload, separators=(",", ":"), sort_keys=True).encode()
    ).decode()
    if platform_name == "linux":
        source = f"FLEET_PAYLOAD_B64={encoded!r}\n" + source_path.read_text(
            encoding="utf-8"
        )
        remote_command = ["sudo", "-n", "python3", "-"]
    else:
        source = f"$script:FleetPayloadB64 = '{encoded}'\n" + source_path.read_text(
            encoding="utf-8"
        )
        remote_command = [
            "powershell.exe",
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-Command",
            "-",
        ]
    arguments = transport_arguments(target, "ssh") + remote_command
    result = subprocess.run(
        arguments,
        input=source,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        return (
            classify_ssh_failure(result),
            None,
            (result.stderr.strip() or result.stdout.strip()),
        )
    try:
        value = json.loads(result.stdout)
    except json.JSONDecodeError:
        return 1, None, "remote adapter did not return one JSON document"
    if not isinstance(value, dict):
        return 1, None, "remote adapter result must be a JSON object"
    return 0, value, result.stderr.strip()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("probe", "install", "rollback"))
    parser.add_argument("--target", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--artifact", type=pathlib.Path)
    parser.add_argument("--receipt", type=pathlib.Path)
    parser.add_argument("--expectations", type=pathlib.Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        target = load_json(args.target, "target")
        target_id = target.get("id")
        if not isinstance(target_id, str) or not target_id:
            raise DriverError("target id is required")
        payload: dict[str, Any] = {
            "protocol": PROTOCOL,
            "action": args.action,
            "target": target,
        }
        if args.action in {"install", "rollback"}:
            if args.expectations is None:
                raise DriverError(f"{args.action} requires expectations")
            expectations = load_json(args.expectations, "expectations")
            transaction_id = expectations.get("transactionId")
            if (
                not isinstance(transaction_id, str)
                or TRANSACTION.fullmatch(transaction_id) is None
            ):
                raise DriverError("expectations transactionId is invalid")
            payload["expectations"] = expectations
        if args.action == "install":
            if args.artifact is None or args.receipt is None:
                raise DriverError("install requires artifact and receipt")
            require_regular(args.artifact, "candidate artifact")
            require_regular(args.receipt, "candidate receipt")
            expected_hash = expectations.get("artifactSha256")
            expected_size = expectations.get("artifactSize")
            if sha256_file(args.artifact) != expected_hash:
                raise DriverError("local candidate artifact SHA-256 changed")
            if args.artifact.stat().st_size != expected_size:
                raise DriverError("local candidate artifact size changed")
            payload["stageName"] = stage_artifact(target, args.artifact, transaction_id)

        code, result, details = invoke_adapter(target, payload)
        if code != 0:
            if details:
                print(details, file=sys.stderr)
            return code
        assert result is not None
        if result.get("targetId") != target_id:
            raise DriverError("remote adapter returned the wrong target id")
        raw_path = args.output.with_name(f"{args.output.stem}-raw.json")
        atomic_json(raw_path, result)
        wrapped = {
            **result,
            "rawReceipt": {
                "path": str(raw_path.resolve()),
                "sha256": sha256_file(raw_path),
                "size": raw_path.stat().st_size,
            },
        }
        atomic_json(args.output, wrapped)
        return 0
    except (DriverError, OSError) as error:
        print(f"fleet SSH driver blocked: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
