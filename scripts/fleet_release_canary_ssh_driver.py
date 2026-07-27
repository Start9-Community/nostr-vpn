#!/usr/bin/env python3
"""Checked-in SSH transport for the transactional fleet canary protocol.

All machine names and paths come from an ignored inventory.  The platform
adapters are streamed over SSH and never installed permanently.  Candidate
artifacts are copied byte-for-byte and verified remotely before an adapter is
allowed to stop a service or replace a file.

Remote adapter exit 77 means install authorization expired before live target
mutation and is preserved through staged-artifact cleanup.
"""

from __future__ import annotations

import argparse
import base64
import contextlib
import gzip
import hashlib
import json
import os
import pathlib
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import zipfile
from typing import Any


HOST = re.compile(r"^[A-Za-z0-9_.@:-]+$")
TRANSACTION = re.compile(r"^[0-9a-f]{32}$")
STAGED_ARTIFACT = re.compile(r"^\.nvpn-fleet-[0-9a-f]{32}\.artifact$")
PROTOCOL = "nvpn-fleet-ssh-transactional-v2"
STAGE_TIMEOUT_SECONDS = 90
ADAPTER_TIMEOUT_SECONDS = 180
CLEANUP_TIMEOUT_SECONDS = 20
INSTALL_AUTHORIZATION_EXPIRED = 77
PYTHON_FUTURE_IMPORT = "from __future__ import annotations\n"
WINDOWS_STDIN_WRAPPER = r"""
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$transport = [Console]::In.ReadToEnd()
$compressed = [Convert]::FromBase64String($transport)
$memory = [IO.MemoryStream]::new([byte[]]$compressed)
$gzip = [IO.Compression.GzipStream]::new(
    $memory,
    [IO.Compression.CompressionMode]::Decompress
)
$reader = [IO.StreamReader]::new(
    $gzip,
    [Text.UTF8Encoding]::new($false),
    $true
)
try {
    $source = $reader.ReadToEnd()
} finally {
    $reader.Dispose()
    $gzip.Dispose()
    $memory.Dispose()
}

$path = [IO.Path]::Combine(
    [IO.Path]::GetTempPath(),
    ('nvpn-fleet-' + [Guid]::NewGuid().ToString('N') + '.ps1')
)
$exitCode = 1
$writeStream = $null
$lockStream = $null
try {
    $encoding = [Text.UTF8Encoding]::new($false)
    $bytes = $encoding.GetBytes($source)
    $writeStream = [IO.FileStream]::new(
        $path,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::ReadWrite,
        [IO.FileShare]::None
    )
    $writeStream.Write($bytes, 0, $bytes.Length)
    $writeStream.Flush($true)
    $writeStream.Position = 0
    $writtenBeforeClose = [byte[]]::new($bytes.Length)
    $offset = 0
    while ($offset -lt $writtenBeforeClose.Length) {
        $count = $writeStream.Read(
            $writtenBeforeClose,
            $offset,
            $writtenBeforeClose.Length - $offset
        )
        if ($count -eq 0) {
            throw 'transient fleet adapter initial readback was truncated'
        }
        $offset += $count
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $sourceHash = [Convert]::ToBase64String(
            $sha.ComputeHash($bytes)
        )
        $initialHash = [Convert]::ToBase64String(
            $sha.ComputeHash($writtenBeforeClose)
        )
    } finally {
        $sha.Dispose()
    }
    if (
        $sourceHash -cne $initialHash -or
        $encoding.GetString($writtenBeforeClose) -cne $source
    ) {
        throw 'transient fleet adapter initial readback mismatch'
    }
    $writeStream.Dispose()
    $writeStream = $null

    $lockStream = [IO.FileStream]::new(
        $path,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::Read
    )
    if ($lockStream.Length -ne $bytes.Length) {
        throw 'transient fleet adapter readback length mismatch'
    }
    $lockStream.Position = 0
    $written = [byte[]]::new($bytes.Length)
    $offset = 0
    while ($offset -lt $written.Length) {
        $count = $lockStream.Read(
            $written,
            $offset,
            $written.Length - $offset
        )
        if ($count -eq 0) {
            throw 'transient fleet adapter readback was truncated'
        }
        $offset += $count
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $fileHash = [Convert]::ToBase64String(
            $sha.ComputeHash($written)
        )
    } finally {
        $sha.Dispose()
    }
    if (
        $sourceHash -cne $fileHash -or
        $encoding.GetString($written) -cne $source
    ) {
        throw 'transient fleet adapter readback mismatch'
    }

    & ([IO.Path]::Combine($PSHOME, 'powershell.exe')) `
        -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $path
    $exitCode = $LASTEXITCODE
} finally {
    if ($null -ne $writeStream) {
        $writeStream.Dispose()
    }
    if ($null -ne $lockStream) {
        $lockStream.Dispose()
    }
    if ([IO.File]::Exists($path)) {
        Remove-Item -LiteralPath $path -Force -ErrorAction Stop
    }
    if ([IO.File]::Exists($path)) {
        throw 'transient fleet adapter cleanup failed'
    }
}
exit $exitCode
""".strip()


class DriverError(RuntimeError):
    """A local transport or adapter failure."""

    def __init__(self, message: str, *, exit_code: int = 1) -> None:
        super().__init__(message)
        if exit_code not in {1, 75, 76, INSTALL_AUTHORIZATION_EXPIRED}:
            raise ValueError("fleet driver exit code is invalid")
        self.exit_code = exit_code


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


def require_exact_archive_member(
    names: list[str],
    expected: str,
    label: str,
) -> None:
    if names.count(expected) != 1:
        raise DriverError(f"{label} must occur exactly once")


@contextlib.contextmanager
def materialize_candidate_executable(
    artifact: pathlib.Path,
    payload: dict[str, Any],
    expected_sha256: str,
    platform_name: str,
):
    """Materialize only the frozen executable, never an archive tree."""
    payload_format = payload.get("format")
    member = payload.get("executableMember")
    with tempfile.TemporaryDirectory(prefix="nvpn-fleet-candidate.") as raw:
        root = pathlib.Path(raw)
        output = root / ("nvpn.exe" if platform_name == "windows" else "nvpn")
        if payload_format == "executable":
            shutil.copyfile(artifact, output)
        elif payload_format == "tar-gz" and platform_name == "linux":
            if not isinstance(member, str) or not member:
                raise DriverError("Linux candidate executable member is invalid")
            try:
                with tarfile.open(artifact, "r:gz") as archive:
                    members = archive.getmembers()
                    require_exact_archive_member(
                        [item.name for item in members],
                        member,
                        "candidate executable archive member",
                    )
                    selected = next(item for item in members if item.name == member)
                    if not selected.isfile():
                        raise DriverError(
                            "candidate executable archive member is not a file"
                        )
                    source = archive.extractfile(selected)
                    if source is None:
                        raise DriverError(
                            "candidate executable archive member is unreadable"
                        )
                    with source, output.open("xb") as destination:
                        shutil.copyfileobj(source, destination)
            except (tarfile.TarError, OSError) as error:
                raise DriverError(
                    f"candidate executable archive is invalid: {error}"
                ) from error
        elif payload_format == "zip" and platform_name == "windows":
            if not isinstance(member, str) or not member:
                raise DriverError("Windows candidate executable member is invalid")
            try:
                with zipfile.ZipFile(artifact) as archive:
                    entries = archive.infolist()
                    require_exact_archive_member(
                        [item.filename for item in entries],
                        member,
                        "candidate executable archive member",
                    )
                    selected = next(
                        item for item in entries if item.filename == member
                    )
                    if selected.is_dir():
                        raise DriverError(
                            "candidate executable archive member is not a file"
                        )
                    with archive.open(selected) as source, output.open(
                        "xb"
                    ) as destination:
                        shutil.copyfileobj(source, destination)
            except (zipfile.BadZipFile, OSError) as error:
                raise DriverError(
                    f"candidate executable archive is invalid: {error}"
                ) from error
        else:
            raise DriverError("candidate install payload does not match the platform")
        require_regular(output, "materialized candidate executable")
        if output.stat().st_size <= 0:
            raise DriverError("materialized candidate executable is empty")
        if sha256_file(output) != expected_sha256:
            raise DriverError("materialized candidate executable SHA-256 mismatch")
        output.chmod(0o700)
        yield output


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
    if result.returncode == INSTALL_AUTHORIZATION_EXPIRED:
        return INSTALL_AUTHORIZATION_EXPIRED
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


def run_transport(
    arguments: list[str],
    *,
    input_text: str | None,
    timeout: int,
    label: str,
) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            arguments,
            input=input_text,
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as error:
        raise DriverError(
            f"{label} timed out after {timeout} seconds"
        ) from error


def stage_artifact(
    target: dict[str, Any],
    artifact: pathlib.Path,
    stage_name: str,
) -> None:
    if STAGED_ARTIFACT.fullmatch(stage_name) is None:
        raise DriverError("staged artifact name is invalid")
    destination = f"{transport_arguments(target, 'scp')[-1]}:{stage_name}"
    arguments = transport_arguments(target, "scp")
    arguments[-1:] = [str(artifact), destination]
    result = run_transport(
        arguments,
        input_text=None,
        timeout=STAGE_TIMEOUT_SECONDS,
        label="artifact transport",
    )
    if result.returncode != 0:
        code = classify_ssh_failure(result)
        raise DriverError(
            f"artifact transport failed (classification {code}): "
            f"{result.stderr.strip() or result.stdout.strip()}",
            exit_code=code,
        )


def render_staged_artifact_cleanup(
    platform_name: str,
    stage_name: str,
) -> tuple[str, list[str]]:
    if platform_name not in {"linux", "windows"}:
        raise DriverError("staged artifact cleanup platform is invalid")
    if STAGED_ARTIFACT.fullmatch(stage_name) is None:
        raise DriverError("staged artifact cleanup name is invalid")
    if platform_name == "linux":
        source = f"""\
import os
import pathlib
import sys

path = pathlib.Path.home() / {stage_name!r}
try:
    path.unlink()
except FileNotFoundError:
    pass
except OSError as error:
    print(f"staged artifact cleanup failed: {{error}}", file=sys.stderr)
    raise SystemExit(1)
if os.path.lexists(path):
    print("staged artifact cleanup left remote residue", file=sys.stderr)
    raise SystemExit(1)
"""
        return source, ["python3", "-"]
    cleanup = f"""\
$ErrorActionPreference = 'Stop'
$path = Join-Path $HOME '{stage_name}'
$parent = Split-Path -Parent $path
$leaf = Split-Path -Leaf $path
function Get-StagedItem {{
    return @(
        Get-ChildItem -LiteralPath $parent -Force -Filter $leaf `
            -ErrorAction Stop |
            Where-Object {{ $_.Name -ceq $leaf }}
    )
}}
try {{
    $items = @(Get-StagedItem)
    if ($items.Count -gt 1) {{
        throw 'staged artifact path is ambiguous'
    }}
    if ($items.Count -eq 1) {{
        $item = $items[0]
        if (
            $item.PSIsContainer -and
            !($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
        ) {{
            throw 'staged artifact path is not a regular file'
        }}
        Remove-Item -LiteralPath $path -Force -ErrorAction Stop
    }}
}} catch {{
    [Console]::Error.WriteLine("staged artifact cleanup failed: $_")
    exit 1
}}
if (@(Get-StagedItem).Count -ne 0) {{
    [Console]::Error.WriteLine('staged artifact cleanup left remote residue')
    exit 1
}}
"""
    encoded = base64.b64encode(cleanup.encode("utf-16le")).decode()
    return "", [
        "powershell.exe",
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy",
        "Bypass",
        "-EncodedCommand",
        encoded,
    ]


def cleanup_staged_artifact(
    target: dict[str, Any],
    stage_name: str,
) -> None:
    source, remote_command = render_staged_artifact_cleanup(
        target.get("platform"),
        stage_name,
    )
    arguments = transport_arguments(target, "ssh") + remote_command
    result = run_transport(
        arguments,
        input_text=source or None,
        timeout=CLEANUP_TIMEOUT_SECONDS,
        label="staged artifact cleanup",
    )
    if result.returncode != 0:
        code = classify_ssh_failure(result)
        details = result.stderr.strip() or result.stdout.strip()
        raise DriverError(
            f"staged artifact cleanup failed (classification {code}): "
            f"{details or 'remote cleanup returned no details'}",
            exit_code=code,
        )


def adapter_source(platform_name: str) -> pathlib.Path:
    suffix = "linux.py" if platform_name == "linux" else "windows.ps1"
    return (
        pathlib.Path(__file__)
        .resolve()
        .with_name(f"fleet_release_canary_remote_{suffix}")
    )


def render_adapter_invocation(
    platform_name: str,
    payload: dict[str, Any],
) -> tuple[str, list[str]]:
    if platform_name not in {"linux", "windows"}:
        raise DriverError("only Linux and Windows fleet targets are supported")
    source_path = adapter_source(platform_name)
    require_regular(source_path, f"{platform_name} fleet adapter")
    encoded = base64.b64encode(
        json.dumps(payload, separators=(",", ":"), sort_keys=True).encode()
    ).decode()
    helper = source_path.read_text(encoding="utf-8")
    if platform_name == "linux":
        if helper.count(PYTHON_FUTURE_IMPORT) != 1:
            raise DriverError(
                "Linux fleet adapter must contain exactly one canonical "
                "future-import line"
            )
        source = helper.replace(
            PYTHON_FUTURE_IMPORT,
            f"{PYTHON_FUTURE_IMPORT}\nFLEET_PAYLOAD_B64={encoded!r}\n",
            1,
        )
        try:
            compile(source, str(source_path), "exec")
        except SyntaxError as error:
            raise DriverError(
                f"generated Linux fleet adapter is invalid: {error}"
            ) from error
        remote_command = ["sudo", "-n", "python3", "-"]
    else:
        raw_source = f"$script:FleetPayloadB64 = '{encoded}'\n{helper}"
        source = base64.b64encode(
            gzip.compress(raw_source.encode(), mtime=0)
        ).decode()
        wrapper = base64.b64encode(
            WINDOWS_STDIN_WRAPPER.encode("utf-16le")
        ).decode()
        remote_command = [
            "powershell.exe",
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-EncodedCommand",
            wrapper,
        ]
    return source, remote_command


def invoke_adapter(
    target: dict[str, Any],
    payload: dict[str, Any],
) -> tuple[int, dict[str, Any] | None, str]:
    platform_name = target.get("platform")
    source, remote_command = render_adapter_invocation(platform_name, payload)
    arguments = transport_arguments(target, "ssh") + remote_command
    result = run_transport(
        arguments,
        input_text=source,
        timeout=ADAPTER_TIMEOUT_SECONDS,
        label=f"{platform_name} fleet adapter",
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


def invoke_staged_adapter(
    target: dict[str, Any],
    payload: dict[str, Any],
    artifact: pathlib.Path,
    stage_name: str,
) -> tuple[int, dict[str, Any] | None, str]:
    adapter_result: tuple[int, dict[str, Any] | None, str] | None = None
    primary_error: Exception | None = None
    try:
        stage_artifact(target, artifact, stage_name)
        payload["stageName"] = stage_name
        adapter_result = invoke_adapter(target, payload)
    except Exception as error:
        primary_error = error
    cleanup_error: Exception | None = None
    try:
        cleanup_staged_artifact(target, stage_name)
    except Exception as error:
        cleanup_error = error
    if primary_error is not None:
        if cleanup_error is not None:
            exit_code = (
                primary_error.exit_code
                if isinstance(primary_error, DriverError)
                else 1
            )
            raise DriverError(
                f"{primary_error}; cleanup also failed: {cleanup_error}",
                exit_code=exit_code,
            ) from primary_error
        raise primary_error
    if adapter_result is not None and adapter_result[0] != 0:
        if cleanup_error is None:
            return adapter_result
        code, value, details = adapter_result
        return (
            code,
            value,
            f"{details}; cleanup also failed: {cleanup_error}",
        )
    if cleanup_error is not None:
        raise cleanup_error
    if adapter_result is None:
        raise DriverError("staged fleet adapter returned no result")
    return adapter_result


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
        expectations: dict[str, Any] | None = None
        if args.action in {"probe", "install", "rollback"}:
            if args.expectations is None:
                raise DriverError(f"{args.action} requires expectations")
            expectations = load_json(args.expectations, "expectations")
            id_field = "probeId" if args.action == "probe" else "transactionId"
            transaction_id = expectations.get(id_field)
            if (
                not isinstance(transaction_id, str)
                or TRANSACTION.fullmatch(transaction_id) is None
            ):
                raise DriverError(f"expectations {id_field} is invalid")
            payload["expectations"] = expectations
        if args.action in {"probe", "install"}:
            if args.artifact is None or args.receipt is None:
                raise DriverError(
                    f"{args.action} requires artifact and receipt"
                )
            require_regular(args.artifact, "candidate artifact")
            require_regular(args.receipt, "candidate receipt")
            assert expectations is not None
            expected_hash = expectations.get("artifactSha256")
            expected_size = expectations.get("artifactSize")
            if sha256_file(args.artifact) != expected_hash:
                raise DriverError("local candidate artifact SHA-256 changed")
            if args.artifact.stat().st_size != expected_size:
                raise DriverError("local candidate artifact size changed")
        if args.action == "install":
            stage_name = f".nvpn-fleet-{transaction_id}.artifact"
            code, result, details = invoke_staged_adapter(
                target,
                payload,
                args.artifact,
                stage_name,
            )
        elif args.action == "probe":
            assert expectations is not None
            install_payload = expectations.get("installPayload")
            if not isinstance(install_payload, dict):
                raise DriverError("probe expectations require installPayload")
            expected_binary_hash = expectations.get("installedBinarySha256")
            if (
                not isinstance(expected_binary_hash, str)
                or re.fullmatch(r"[0-9a-f]{64}", expected_binary_hash) is None
            ):
                raise DriverError(
                    "probe expectations installedBinarySha256 is invalid"
                )
            stage_name = f".nvpn-fleet-{transaction_id}.artifact"
            with materialize_candidate_executable(
                args.artifact,
                install_payload,
                expected_binary_hash,
                target.get("platform"),
            ) as candidate:
                payload["candidateBinarySize"] = candidate.stat().st_size
                code, result, details = invoke_staged_adapter(
                    target,
                    payload,
                    candidate,
                    stage_name,
                )
        else:
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
    except DriverError as error:
        print(f"fleet SSH driver blocked: {error}", file=sys.stderr)
        return error.exit_code
    except OSError as error:
        print(f"fleet SSH driver blocked: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
