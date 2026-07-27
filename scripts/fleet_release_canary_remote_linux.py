"""Transient root-side Linux adapter for the nvpn fleet canary.

The checked-in SSH driver injects ``FLEET_PAYLOAD_B64`` immediately after the
future import and streams this file to ``sudo -n python3 -``.  Nothing from
this adapter is installed on the host.
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import pathlib
import pwd
import re
import shutil
import socket
import stat
import subprocess
import sys
import tarfile
import time
import urllib.request
from typing import Any


def fail(message: str) -> None:
    raise RuntimeError(message)


def canonical(value: Any) -> bytes:
    return (json.dumps(value, separators=(",", ":"), sort_keys=True) + "\n").encode()


def digest_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def digest_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def atomic_json(path: pathlib.Path, value: dict[str, Any]) -> None:
    temporary = path.with_name(f".{path.name}.tmp-{os.getpid()}")
    with temporary.open("wb") as handle:
        handle.write(canonical(value))
        handle.flush()
        os.fsync(handle.fileno())
    temporary.replace(path)
    directory_fd = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)


def run(
    arguments: list[str],
    *,
    check: bool = True,
    timeout: int = 20,
) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        arguments,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
    )
    if check and result.returncode != 0:
        details = result.stderr.strip() or result.stdout.strip()
        fail(f"{arguments[0]} failed: {details}")
    return result


def absolute_path(value: Any, label: str) -> pathlib.Path:
    if not isinstance(value, str) or not value.startswith("/"):
        fail(f"{label} must be an absolute Linux path")
    path = pathlib.Path(value)
    if ".." in path.parts:
        fail(f"{label} cannot contain parent traversal")
    return path


def service_properties(unit: str) -> dict[str, str]:
    result = run(
        [
            "systemctl",
            "show",
            unit,
            "--property=LoadState,UnitFileState,ActiveState,MainPID,FragmentPath,ExecStart",
            "--no-pager",
        ],
        check=False,
    )
    values: dict[str, str] = {}
    for line in result.stdout.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            values[key] = value
    return values


def systemd_exec_start_path(value: str) -> pathlib.Path:
    matches = re.findall(r"(?:^|[{\s;])path=([^ ;}]+)", value)
    if len(matches) != 1:
        fail("systemd service does not expose one exact ExecStart path")
    path = pathlib.Path(matches[0])
    if not path.is_absolute():
        fail("systemd ExecStart path is not absolute")
    return path


def nvpn_processes() -> list[int]:
    pids: list[int] = []
    for entry in pathlib.Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        try:
            if (entry / "comm").read_text(encoding="utf-8").strip() == "nvpn":
                pids.append(int(entry.name))
        except OSError:
            continue
    return sorted(pids)


def service_snapshot(
    unit: str,
    binary_path: pathlib.Path,
) -> dict[str, Any]:
    properties = service_properties(unit)
    installed = properties.get("LoadState") not in (None, "", "not-found") and bool(
        properties.get("FragmentPath")
    )
    enabled = properties.get("UnitFileState") in {
        "enabled",
        "enabled-runtime",
        "static",
    }
    running = properties.get("ActiveState") == "active"
    raw_pid = properties.get("MainPID", "0")
    pid = int(raw_pid) if raw_pid.isdigit() and int(raw_pid) > 0 else None
    if not running:
        pid = None
    processes = nvpn_processes()
    binary_present = binary_path.is_file()
    fragment = pathlib.Path(properties.get("FragmentPath", ""))
    definition_hash = (
        digest_file(fragment) if installed and fragment.is_file() else None
    )
    configured_resolved = (
        str(binary_path.resolve(strict=True)) if binary_present else None
    )
    exec_start_path = None
    exec_start_resolved = None
    if installed:
        exec_start = systemd_exec_start_path(properties.get("ExecStart", ""))
        exec_start_path = str(exec_start)
        try:
            exec_start_resolved = str(exec_start.resolve(strict=True))
        except OSError as error:
            fail(f"systemd ExecStart executable cannot be resolved: {error}")
    main_process_exe_path = None
    main_process_exe_sha256 = None
    if running and pid is not None:
        proc_exe = pathlib.Path(f"/proc/{pid}/exe")
        try:
            main_process_exe_path = os.readlink(proc_exe)
            main_process_exe_sha256 = digest_file(proc_exe)
        except OSError as error:
            fail(f"systemd MainPID executable cannot be inspected: {error}")
    return {
        "installed": installed,
        "enabled": enabled,
        "running": running,
        "binaryPresent": binary_present,
        "binarySha256": digest_file(binary_path) if binary_present else None,
        "definitionSha256": definition_hash,
        "processCount": len(processes),
        "pid": pid,
        "_fragmentPath": str(fragment) if installed else "",
        "_processes": processes,
        "_configuredBinaryResolvedPath": configured_resolved,
        "_execStartPath": exec_start_path,
        "_execStartResolvedPath": exec_start_resolved,
        "_mainProcessExePath": main_process_exe_path,
        "_mainProcessExeSha256": main_process_exe_sha256,
    }


def assert_service_runtime_binding(
    service: dict[str, Any],
    binary_path: pathlib.Path,
    installed_binary_sha256: str,
    *,
    require_process: bool = True,
) -> dict[str, Any]:
    configured_resolved = service.get("_configuredBinaryResolvedPath")
    if not isinstance(configured_resolved, str) or not configured_resolved:
        fail("configured binary does not resolve to an installed executable")
    exec_start_path = service.get("_execStartPath")
    exec_start_resolved = service.get("_execStartResolvedPath")
    if not isinstance(exec_start_path, str) or not exec_start_path:
        fail("systemd service lacks an exact ExecStart executable")
    if exec_start_resolved != configured_resolved:
        fail("systemd ExecStart does not resolve to the configured binary")
    main_process_path = service.get("_mainProcessExePath")
    main_process_hash = service.get("_mainProcessExeSha256")
    if require_process:
        if main_process_path != configured_resolved:
            fail("systemd MainPID does not execute the configured binary")
        if main_process_hash != installed_binary_sha256:
            fail("systemd MainPID executable hash is not the expected binary")
    elif main_process_path is not None or main_process_hash is not None:
        fail("stopped systemd service unexpectedly has a bound MainPID")
    return {
        "configuredBinaryPath": str(binary_path),
        "configuredBinaryResolvedPath": configured_resolved,
        "execStartPath": exec_start_path,
        "execStartResolvedPath": exec_start_resolved,
        "mainProcessExePath": main_process_path,
        "mainProcessExeSha256": main_process_hash,
    }


def status_json(binary: pathlib.Path, config: pathlib.Path) -> dict[str, Any]:
    result = run(
        [
            str(binary),
            "status",
            "--config",
            str(config),
            "--json",
            "--discover-secs",
            "0",
        ],
        timeout=30,
    )
    try:
        value = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        fail(f"nvpn status was not JSON: {error}")
    if not isinstance(value, dict):
        fail("nvpn status must be an object")
    return value


def version_json(binary: pathlib.Path) -> dict[str, str]:
    result = run([str(binary), "version", "--json"], timeout=30)
    try:
        value = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        fail(f"nvpn version was not JSON: {error}")
    if not isinstance(value, dict):
        fail("nvpn version must be an object")
    app_version = value.get("version")
    fips_version = value.get("fips_core_version")
    if not isinstance(app_version, str) or not app_version:
        fail("nvpn version lacks version")
    if not isinstance(fips_version, str) or not fips_version:
        fail("nvpn version lacks fips_core_version")
    return {
        "version": app_version,
        "fips_core_version": fips_version,
    }


def peer_identity(peer: dict[str, Any]) -> str:
    for field in ("participant_pubkey", "public_key", "node_id"):
        value = peer.get(field)
        if isinstance(value, str) and value.strip():
            return value.strip()
    fail("nvpn status peer lacks an identity")


def config_snapshot(
    config: pathlib.Path,
    status: dict[str, Any],
) -> dict[str, Any]:
    if not config.is_file():
        fail(f"nvpn config does not exist: {config}")
    network_id = status.get("network_id")
    device_id = status.get("device_id")
    expected_peers = status.get("expected_peer_count")
    peers = status.get("peers")
    if not isinstance(network_id, str) or not network_id:
        fail("nvpn status lacks network_id")
    if not isinstance(device_id, str) or not device_id:
        fail("nvpn status lacks device_id")
    if (
        not isinstance(expected_peers, int)
        or isinstance(expected_peers, bool)
        or expected_peers < 0
    ):
        fail("nvpn status expected_peer_count is invalid")
    if not isinstance(peers, list):
        fail("nvpn status peers is invalid")
    signed_rosters = config.parent / "signed-rosters.json"
    if not signed_rosters.is_file():
        fail(f"signed roster store does not exist: {signed_rosters}")
    roster = sorted(
        {
            (
                peer_identity(peer),
                str(peer.get("tunnel_ip", "")),
            )
            for peer in peers
            if isinstance(peer, dict)
        }
    )
    roster_value = {
        "networkId": network_id,
        "localDeviceId": device_id,
        "expectedPeerCount": expected_peers,
        "peers": roster,
    }
    return {
        "sha256": digest_file(config),
        "signedRosterStoreSha256": digest_file(signed_rosters),
        "rosterIdentitySha256": digest_bytes(canonical(roster_value)),
        "rosterPeerCount": expected_peers,
        "localDeviceIdentitySha256": digest_bytes(device_id.encode()),
        "networkIdentitySha256": digest_bytes(network_id.encode()),
    }


def normalized_json_command(arguments: list[str]) -> tuple[Any, bytes]:
    result = run(arguments)
    try:
        value = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        fail(f"{arguments[0]} returned invalid JSON: {error}")
    return value, canonical(value)


def resolver_state() -> bytes:
    values: dict[str, Any] = {}
    resolv = pathlib.Path("/etc/resolv.conf")
    values["resolvConf"] = (
        resolv.read_text(encoding="utf-8", errors="replace")
        if resolv.exists()
        else None
    )
    if shutil.which("resolvectl"):
        for name, arguments in (
            ("dns", ["resolvectl", "dns"]),
            ("domain", ["resolvectl", "domain"]),
            ("defaultRoute", ["resolvectl", "default-route"]),
        ):
            result = run(arguments, check=False)
            values[name] = result.stdout.strip()
    return canonical(values)


def direct_mode(status: dict[str, Any]) -> bool:
    wireguard = status.get("wireguard_exit")
    wireguard_enabled = isinstance(wireguard, dict) and wireguard.get("enabled") is True
    exit_node = status.get("exit_node")
    return not wireguard_enabled and exit_node in (None, "")


def network_snapshot(
    status: dict[str, Any],
    checks: dict[str, Any],
) -> dict[str, Any]:
    routes, route_bytes = normalized_json_command(
        ["ip", "-j", "route", "show", "table", "all"]
    )
    defaults = [
        route
        for route in routes
        if isinstance(route, dict) and route.get("dst") == "default"
    ]
    default_bytes = canonical(defaults)
    resolver = resolver_state()
    wireguard = status.get("wireguard_exit")
    interface = (
        str(wireguard.get("interface", "")) if isinstance(wireguard, dict) else ""
    )
    owned_routes = [
        route for route in defaults if interface and route.get("dev") == interface
    ]
    owned_resolver = 0
    if interface and shutil.which("resolvectl"):
        result = run(["resolvectl", "dns", interface], check=False)
        if result.returncode == 0 and ":" in result.stdout:
            owned_resolver = 1
    dns_name = str(checks["dnsName"])
    direct_url = str(checks["directUrl"])
    try:
        dns_answers = socket.getaddrinfo(dns_name, None)
    except OSError:
        dns_answers = []
    public_ok = False
    try:
        with urllib.request.urlopen(direct_url, timeout=10) as response:
            public_ok = 200 <= int(response.status) < 400
    except Exception:
        public_ok = False
    return {
        "directMode": direct_mode(status),
        "wireguardExitEnabled": not direct_mode(status),
        "dnsResolved": bool(dns_answers),
        "publicInternet": public_ok,
        "resolverFingerprint": digest_bytes(resolver),
        "defaultRouteFingerprint": digest_bytes(default_bytes),
        "routeTableFingerprint": digest_bytes(route_bytes),
        "ownedRouteCount": len(owned_routes),
        "ownedResolverArtifactCount": owned_resolver,
        "_routesBytes": route_bytes,
        "_resolverBytes": resolver,
    }


def machine_identity() -> str:
    for candidate in (
        pathlib.Path("/etc/machine-id"),
        pathlib.Path("/var/lib/dbus/machine-id"),
    ):
        if candidate.is_file():
            value = candidate.read_text(encoding="utf-8").strip()
            if value:
                return digest_bytes(value.encode())
    fail("Linux machine identity is unavailable")


def pending_transactions(root: pathlib.Path) -> list[str]:
    pending: list[str] = []
    if not root.is_dir():
        return pending
    for journal in root.glob("*/journal.json"):
        try:
            value = json.loads(journal.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            pending.append(journal.parent.name)
            continue
        if value.get("state") in {"preparing", "installing", "rolling-back"}:
            pending.append(journal.parent.name)
    return sorted(pending)


def public_service(value: dict[str, Any]) -> dict[str, Any]:
    return {key: item for key, item in value.items() if not key.startswith("_")}


def public_network(value: dict[str, Any]) -> dict[str, Any]:
    return {key: item for key, item in value.items() if not key.startswith("_")}


def capture(
    target: dict[str, Any],
    *,
    checks: dict[str, Any],
) -> dict[str, Any]:
    deployment = target["deployment"]
    unit = deployment.get("serviceName", "nvpn.service")
    if unit != "nvpn.service":
        fail("Linux fleet serviceName must be nvpn.service")
    binary = absolute_path(deployment.get("binaryPath"), "binaryPath")
    config = absolute_path(deployment.get("configPath"), "configPath")
    probe_binary = absolute_path(
        deployment.get("probeBinaryPath", str(binary)), "probeBinaryPath"
    )
    if not probe_binary.is_file():
        fail(f"probe CLI does not exist: {probe_binary}")
    probe_version = version_json(probe_binary)
    status = status_json(probe_binary, config)
    service = service_snapshot(unit, binary)
    config_value = config_snapshot(config, status)
    network = network_snapshot(status, checks)
    return {
        "service": service,
        "config": config_value,
        "network": network,
        "status": status,
        "probeBinarySha256": digest_file(probe_binary),
        "probeAppVersion": probe_version["version"],
        "probeFipsCoreVersion": probe_version["fips_core_version"],
        "binaryPath": binary,
        "configPath": config,
        "unit": unit,
    }


def assert_expected(
    state: dict[str, Any],
    target: dict[str, Any],
    expected: dict[str, Any],
) -> None:
    frozen = target["expected"]
    if machine_identity() != frozen["machineIdentitySha256"]:
        fail("remote machine identity changed")
    preinstall_probe = expected["preinstallProbe"]
    if state["probeBinarySha256"] != preinstall_probe["probeBinarySha256"]:
        fail("probe CLI binary changed after preflight")
    if state["probeAppVersion"] != preinstall_probe["probeAppVersion"]:
        fail("probe CLI app version changed after preflight")
    if (
        state["probeFipsCoreVersion"]
        != preinstall_probe["probeFipsCoreVersion"]
    ):
        fail("probe CLI FIPS version changed after preflight")
    for field in (
        "configSha256",
        "signedRosterStoreSha256",
        "rosterIdentitySha256",
        "rosterPeerCount",
        "localDeviceIdentitySha256",
        "networkIdentitySha256",
    ):
        state_field = {
            "configSha256": "sha256",
            "signedRosterStoreSha256": "signedRosterStoreSha256",
            "rosterIdentitySha256": "rosterIdentitySha256",
            "rosterPeerCount": "rosterPeerCount",
            "localDeviceIdentitySha256": "localDeviceIdentitySha256",
            "networkIdentitySha256": "networkIdentitySha256",
        }[field]
        if state["config"][state_field] != frozen[field]:
            fail(f"frozen {field} changed before install")
    if not state["network"]["directMode"]:
        fail("target is not in Direct mode")
    if state["network"]["ownedRouteCount"] != 0:
        fail("target has stale exit routes before install")
    if state["network"]["ownedResolverArtifactCount"] != 0:
        fail("target has stale exit resolver state before install")
    if expected.get("expected") != frozen:
        fail("expectations do not bind the frozen target identity")
    service = state["service"]
    if service["installed"]:
        if not service["binaryPresent"]:
            fail("cannot canary an installed service whose binary is absent")
        transition = (
            "reinstalled-exact"
            if service["binarySha256"] == expected["installedBinarySha256"]
            else "candidate-transition"
        )
    else:
        transition = "fresh-install"
    if expected.get("installTransition") != transition:
        fail("install transition does not match the preinstall service state")


def snapshot_transaction(
    transaction: pathlib.Path,
    state: dict[str, Any],
    target: dict[str, Any],
) -> dict[str, Any]:
    transaction.mkdir(parents=True, mode=0o700)
    files = transaction / "snapshot"
    files.mkdir(mode=0o700)
    binary = state["binaryPath"]
    config = state["configPath"]
    service = state["service"]
    shutil.copy2(config, files / "config")
    shutil.copy2(config.parent / "signed-rosters.json", files / "signed-rosters.json")
    if service["binaryPresent"]:
        shutil.copy2(binary, files / "binary")
    fragment = service.get("_fragmentPath")
    if fragment:
        shutil.copy2(fragment, files / "service-definition")
    companions: dict[str, str] = {}
    companion_paths = target["deployment"].get("companionPaths", {})
    if not isinstance(companion_paths, dict):
        fail("deployment.companionPaths must be an object")
    companion_root = files / "companions"
    for member, raw_path in companion_paths.items():
        path = absolute_path(raw_path, f"companionPaths[{member}]")
        if path.is_file():
            companion_root.mkdir(exist_ok=True)
            backup = companion_root / hashlib.sha256(member.encode()).hexdigest()
            shutil.copy2(path, backup)
            companions[member] = str(backup)
    raw = {
        "service": public_service(service),
        "config": state["config"],
        "network": public_network(state["network"]),
        "binaryPath": str(binary),
        "configPath": str(config),
        "signedRosterPath": str(config.parent / "signed-rosters.json"),
        "fragmentPath": fragment,
        "companions": companions,
    }
    atomic_json(files / "state.json", raw)
    (files / "routes.json").write_bytes(state["network"]["_routesBytes"])
    (files / "resolver.json").write_bytes(state["network"]["_resolverBytes"])
    (files / "processes.json").write_bytes(canonical(service["_processes"]))
    (files / "status.json").write_bytes(canonical(state["status"]))
    return {
        "durable": True,
        "service": public_service(service),
        "config": state["config"],
        "network": public_network(state["network"]),
        "serviceReceiptSha256": digest_bytes(canonical(public_service(service))),
        "configReceiptSha256": digest_bytes(canonical(state["config"])),
        "routesReceiptSha256": digest_file(files / "routes.json"),
        "resolverReceiptSha256": digest_file(files / "resolver.json"),
        "processesReceiptSha256": digest_file(files / "processes.json"),
        "statusReceiptSha256": digest_file(files / "status.json"),
    }


def write_journal(
    transaction: pathlib.Path,
    target_id: str,
    transaction_id: str,
    state: str,
) -> str:
    path = transaction / "journal.json"
    atomic_json(
        path,
        {
            "schema": 1,
            "targetId": target_id,
            "transactionId": transaction_id,
            "state": state,
            "updatedAt": int(time.time()),
        },
    )
    return digest_file(path)


def extract_payload(
    artifact: pathlib.Path,
    transaction: pathlib.Path,
    expected: dict[str, Any],
) -> tuple[pathlib.Path, dict[str, pathlib.Path]]:
    payload = expected["installPayload"]
    candidate = transaction / "candidate"
    companions: dict[str, pathlib.Path] = {}
    if payload["format"] == "executable":
        shutil.copy2(artifact, candidate)
    elif payload["format"] == "tar-gz":
        with tarfile.open(artifact, "r:gz") as archive:
            member = archive.getmember(payload["executableMember"])
            if not member.isfile():
                fail("candidate executable archive member is not a file")
            with archive.extractfile(member) as source, candidate.open("wb") as dest:
                if source is None:
                    fail("candidate executable archive member is unreadable")
                shutil.copyfileobj(source, dest)
            for companion in payload["companions"]:
                archive_member = archive.getmember(companion["member"])
                if not archive_member.isfile():
                    fail("candidate companion archive member is not a file")
                output = transaction / (
                    "companion-"
                    + hashlib.sha256(companion["member"].encode()).hexdigest()
                )
                with archive.extractfile(archive_member) as source, output.open(
                    "wb"
                ) as dest:
                    if source is None:
                        fail("candidate companion archive member is unreadable")
                    shutil.copyfileobj(source, dest)
                companions[companion["member"]] = output
    else:
        fail("unsupported Linux install payload")
    candidate.chmod(0o755)
    if digest_file(candidate) != expected["installedBinarySha256"]:
        fail("extracted candidate executable hash mismatch")
    for companion in payload["companions"]:
        path = companions[companion["member"]]
        if digest_file(path) != companion["sha256"]:
            fail("extracted candidate companion hash mismatch")
    return candidate, companions


def atomic_install(source: pathlib.Path, destination: pathlib.Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(f".{destination.name}.fleet-{os.getpid()}")
    shutil.copy2(source, temporary)
    temporary.chmod(0o755)
    temporary.replace(destination)


def wait_service(unit: str, running: bool) -> None:
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        state = service_properties(unit).get("ActiveState") == "active"
        if state == running:
            return
        time.sleep(0.25)
    fail(f"{unit} did not reach the expected state")


def aggregate_counters(status: dict[str, Any]) -> tuple[int, int]:
    tx = 0
    rx = 0
    peers = status.get("daemon", {}).get("state", {}).get("peers", [])
    if not isinstance(peers, list) or not peers:
        peers = status.get("peers", [])
    for peer in peers if isinstance(peers, list) else []:
        if not isinstance(peer, dict):
            continue
        tx += int(peer.get("fips_bytes_sent", peer.get("tx_bytes", 0)) or 0)
        rx += int(peer.get("fips_bytes_recv", peer.get("rx_bytes", 0)) or 0)
    return tx, rx


def dns_probe(name: str) -> tuple[list[str], str]:
    answers = sorted(
        {value[4][0] for value in socket.getaddrinfo(name, None) if value[4]}
    )
    if not answers:
        fail(f"DNS returned no answer for {name}")
    raw = canonical({"name": name, "answers": answers})
    return answers, digest_bytes(raw)


def direct_probe(url: str) -> tuple[int, str]:
    with urllib.request.urlopen(url, timeout=10) as response:
        status = int(response.status)
        body = response.read(1024 * 1024)
    if status < 200 or status >= 400:
        fail(f"Direct URL returned HTTP {status}")
    return status, digest_bytes(
        canonical(
            {
                "url": url,
                "status": status,
                "bodySha256": digest_bytes(body),
            }
        )
    )


def restore_transaction(
    transaction: pathlib.Path,
    target: dict[str, Any],
    transaction_id: str,
) -> dict[str, Any]:
    snapshot_dir = transaction / "snapshot"
    snapshot_file = snapshot_dir / "state.json"
    if not snapshot_file.is_file():
        fail("durable rollback snapshot is missing")
    raw = json.loads(snapshot_file.read_text(encoding="utf-8"))
    unit = target["deployment"].get("serviceName", "nvpn.service")
    binary = pathlib.Path(raw["binaryPath"])
    config = pathlib.Path(raw["configPath"])
    signed_rosters = pathlib.Path(raw["signedRosterPath"])
    prior = raw["service"]
    write_journal(transaction, target["id"], transaction_id, "rolling-back")
    run(["systemctl", "stop", unit], check=False)
    if prior["binaryPresent"]:
        atomic_install(snapshot_dir / "binary", binary)
    else:
        binary.unlink(missing_ok=True)
    shutil.copy2(snapshot_dir / "config", config)
    shutil.copy2(snapshot_dir / "signed-rosters.json", signed_rosters)
    fragment = raw.get("fragmentPath")
    if prior["installed"]:
        if not fragment:
            fail("installed service snapshot lacks fragment path")
        definition = pathlib.Path(fragment)
        definition.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(snapshot_dir / "service-definition", definition)
    else:
        if fragment:
            pathlib.Path(fragment).unlink(missing_ok=True)
        pathlib.Path("/etc/systemd/system/nvpn.service").unlink(missing_ok=True)
    companion_paths = target["deployment"].get("companionPaths", {})
    snapshot_companions = raw.get("companions", {})
    for member, raw_path in companion_paths.items():
        destination = absolute_path(raw_path, f"companionPaths[{member}]")
        backup = snapshot_companions.get(member)
        if backup:
            atomic_install(pathlib.Path(backup), destination)
        else:
            destination.unlink(missing_ok=True)
    run(["systemctl", "daemon-reload"])
    if prior["installed"] and prior["enabled"]:
        run(["systemctl", "enable", unit])
    else:
        run(["systemctl", "disable", unit], check=False)
    if prior["installed"] and prior["running"]:
        run(["systemctl", "start", unit])
        wait_service(unit, True)
    else:
        run(["systemctl", "stop", unit], check=False)
    after = capture(target, checks=target["checks"])
    after_public = {
        "service": public_service(after["service"]),
        "config": after["config"],
        "network": public_network(after["network"]),
    }
    expected_public = {
        "service": raw["service"],
        "config": raw["config"],
        "network": raw["network"],
    }
    for field, value in expected_public["service"].items():
        if field != "pid" and after_public["service"].get(field) != value:
            fail(f"rollback did not restore service field {field}")
    prior_pid = expected_public["service"]["pid"]
    restored_pid = after_public["service"]["pid"]
    if prior["running"]:
        if not isinstance(restored_pid, int) or restored_pid <= 0:
            fail("rollback did not restart the restored service")
        if restored_pid == prior_pid:
            fail("rollback did not prove a new restored service process")
    elif restored_pid is not None:
        fail("rollback unexpectedly started a previously stopped service")
    if after_public["config"] != expected_public["config"]:
        fail("rollback did not restore the exact config snapshot")
    if after_public["network"] != expected_public["network"]:
        fail("rollback did not restore the exact network snapshot")
    runtime_binding: dict[str, Any] = {}
    if prior["installed"]:
        runtime_binding = assert_service_runtime_binding(
            after["service"],
            binary,
            prior["binarySha256"],
            require_process=prior["running"],
        )
    restored_service = {
        **after_public["service"],
        **runtime_binding,
    }
    journal_hash = write_journal(
        transaction, target["id"], transaction_id, "rolled-back"
    )
    return {
        "schema": 2,
        "targetId": target["id"],
        "machineIdentitySha256": machine_identity(),
        "remoteBuildPerformed": False,
        "transaction": {
            "id": transaction_id,
            "state": "rolled-back",
            "durableJournal": True,
            "journalReceiptSha256": journal_hash,
        },
        "service": restored_service,
        "config": after_public["config"],
        "network": after_public["network"],
        "snapshotReceiptSha256": digest_file(snapshot_file),
        "serviceReceiptSha256": digest_bytes(canonical(restored_service)),
        "configReceiptSha256": digest_bytes(canonical(after_public["config"])),
        "routesReceiptSha256": digest_bytes(after["network"]["_routesBytes"]),
        "resolverReceiptSha256": digest_bytes(after["network"]["_resolverBytes"]),
        "processesReceiptSha256": digest_bytes(
            canonical(after["service"]["_processes"])
        ),
    }


def install_staged(
    payload: dict[str, Any],
    target: dict[str, Any],
    expected: dict[str, Any],
    stage: pathlib.Path,
) -> dict[str, Any]:
    if target["deployment"].get("authorization") != "install":
        fail("target inventory does not authorize install")
    transaction_id = expected["transactionId"]
    root = absolute_path(
        target["deployment"].get("transactionRoot", "/var/lib/nvpn/fleet-canary"),
        "transactionRoot",
    )
    transaction = root / transaction_id
    if transaction.exists():
        fail("transaction id already exists")
    if digest_file(stage) != expected["artifactSha256"]:
        fail("staged artifact SHA-256 mismatch")
    if stage.stat().st_size != expected["artifactSize"]:
        fail("staged artifact size mismatch")
    before = capture(target, checks=target["checks"])
    assert_expected(before, target, expected)
    if before["service"]["installed"]:
        assert_service_runtime_binding(
            before["service"],
            before["binaryPath"],
            before["service"]["binarySha256"],
            require_process=before["service"]["running"],
        )
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    snapshot = snapshot_transaction(transaction, before, target)
    write_journal(transaction, target["id"], transaction_id, "preparing")
    candidate, companions = extract_payload(stage, transaction, expected)
    unit = before["unit"]
    binary = before["binaryPath"]
    config = before["configPath"]
    write_journal(transaction, target["id"], transaction_id, "installing")
    try:
        run(["systemctl", "stop", unit], check=False)
        atomic_install(candidate, binary)
        companion_paths = target["deployment"].get("companionPaths", {})
        for companion in expected["installPayload"]["companions"]:
            member = companion["member"]
            raw_destination = companion_paths.get(member)
            if not raw_destination:
                fail(f"no install destination for companion {member}")
            atomic_install(
                companions[member],
                absolute_path(raw_destination, f"companionPaths[{member}]"),
            )
        if before["service"]["installed"]:
            run(["systemctl", "daemon-reload"])
            run(["systemctl", "enable", unit])
            run(["systemctl", "start", unit])
        else:
            run(
                [
                    str(binary),
                    "service",
                    "install",
                    "--config",
                    str(config),
                    "--force",
                ],
                timeout=30,
            )
        wait_service(unit, True)
        first = capture(target, checks=target["checks"])
        first_pid = first["service"]["pid"]
        assert_service_runtime_binding(
            first["service"],
            binary,
            expected["installedBinarySha256"],
        )
        status_before = first["status"]
        tx_before, rx_before = aggregate_counters(status_before)
        payload_target = str(target["checks"]["payloadTarget"])
        ping = run(
            ["ping", "-c", "1", "-W", "3", payload_target],
            timeout=8,
        )
        payload_receipt = digest_bytes(
            canonical(
                {
                    "target": payload_target,
                    "stdout": ping.stdout,
                    "stderr": ping.stderr,
                }
            )
        )
        answers, dns_receipt = dns_probe(str(target["checks"]["dnsName"]))
        http_status, direct_receipt = direct_probe(str(target["checks"]["directUrl"]))
        status_after_payload = status_json(binary, config)
        tx_after, rx_after = aggregate_counters(status_after_payload)
        run(["systemctl", "restart", unit])
        wait_service(unit, True)
        final = capture(target, checks=target["checks"])
        final_pid = final["service"]["pid"]
        runtime_binding = assert_service_runtime_binding(
            final["service"],
            binary,
            expected["installedBinarySha256"],
        )
        final_answers, final_dns_receipt = dns_probe(str(target["checks"]["dnsName"]))
        final_http_status, final_direct_receipt = direct_probe(
            str(target["checks"]["directUrl"])
        )
        if before["config"] != final["config"]:
            fail("install mutated config or roster identity")
        if public_network(before["network"]) != public_network(final["network"]):
            fail("Direct resolver/route state was not restored after restart")
        version_result = run([str(binary), "version", "--json"])
        version = json.loads(version_result.stdout)
        if version.get("version") != expected["appVersion"]:
            fail("installed nvpn version mismatch")
        if version.get("fips_core_version") != (
            f"{expected['fipsVersion']} (rev {expected['fipsGitSha'][:10]})"
        ):
            fail("installed FIPS core version mismatch")
        journal_hash = write_journal(
            transaction, target["id"], transaction_id, "committed"
        )
        return {
            "schema": 2,
            "targetId": target["id"],
            "platform": target["platform"],
            "arch": target["arch"],
            "machineIdentitySha256": machine_identity(),
            "realChecks": True,
            "mocked": False,
            "remoteBuildPerformed": False,
            "installAuthorized": True,
            **{
                field: expected[field]
                for field in (
                    "appGitSha",
                    "appGitTree",
                    "appVersion",
                    "fipsGitSha",
                    "fipsGitTree",
                    "fipsVersion",
                )
            },
            "artifactSha256": expected["artifactSha256"],
            "artifactSize": expected["artifactSize"],
            "stagedArtifactSha256": expected["artifactSha256"],
            "preinstallProbe": {
                "probeBinarySha256": before["probeBinarySha256"],
                "probeAppVersion": before["probeAppVersion"],
                "probeFipsCoreVersion": before["probeFipsCoreVersion"],
            },
            "transaction": {
                "id": transaction_id,
                "state": "committed",
                "durableJournal": True,
                "rollbackAvailable": True,
                "journalReceiptSha256": journal_hash,
                "snapshot": snapshot,
            },
            "service": {
                "installed": True,
                "enabled": True,
                "running": True,
                "restartDurable": first_pid != final_pid,
                "binarySha256": final["service"]["binarySha256"],
                "binaryVersion": f"nvpn {version['version']}",
                "fipsCoreVersion": version["fips_core_version"],
                "priorInstalled": before["service"]["installed"],
                "priorEnabled": before["service"]["enabled"],
                "priorRunning": before["service"]["running"],
                "priorBinaryPresent": before["service"]["binaryPresent"],
                "priorBinarySha256": before["service"]["binarySha256"],
                "installTransition": expected["installTransition"],
                "processCount": final["service"]["processCount"],
                "pidBeforeRestart": first_pid,
                "pidAfterRestart": final_pid,
                **runtime_binding,
            },
            "config": {
                "mutationOutsideInstall": False,
                "sha256Before": before["config"]["sha256"],
                "sha256After": final["config"]["sha256"],
                "signedRosterStoreSha256Before": before["config"][
                    "signedRosterStoreSha256"
                ],
                "signedRosterStoreSha256After": final["config"][
                    "signedRosterStoreSha256"
                ],
                "rosterIdentitySha256Before": before["config"]["rosterIdentitySha256"],
                "rosterIdentitySha256After": final["config"]["rosterIdentitySha256"],
                "rosterPeerCountBefore": before["config"]["rosterPeerCount"],
                "rosterPeerCountAfter": final["config"]["rosterPeerCount"],
                "localDeviceIdentitySha256Before": before["config"][
                    "localDeviceIdentitySha256"
                ],
                "localDeviceIdentitySha256After": final["config"][
                    "localDeviceIdentitySha256"
                ],
                "networkIdentitySha256Before": before["config"][
                    "networkIdentitySha256"
                ],
                "networkIdentitySha256After": final["config"]["networkIdentitySha256"],
            },
            "roster": {
                "meshReady": bool(
                    status_after_payload.get("mesh_ready")
                    or status_after_payload.get("daemon", {})
                    .get("state", {})
                    .get("mesh_ready")
                ),
                "expectedPeerCount": final["config"]["rosterPeerCount"],
                "connectedPeerCount": int(status_after_payload.get("peer_count", 0)),
                "payloadTarget": payload_target,
                "payloadSuccess": True,
                "txIncreased": tx_after > tx_before,
                "rxIncreased": rx_after > rx_before,
                "txBytesBefore": tx_before,
                "txBytesAfter": tx_after,
                "rxBytesBefore": rx_before,
                "rxBytesAfter": rx_after,
                "payloadReceiptSha256": payload_receipt,
            },
            "network": {
                "directMode": final["network"]["directMode"],
                "wireguardExitEnabled": final["network"]["wireguardExitEnabled"],
                "dnsResolvedBefore": bool(answers),
                "dnsResolvedAfter": bool(final_answers),
                "dnsRestored": (
                    before["network"]["resolverFingerprint"]
                    == final["network"]["resolverFingerprint"]
                ),
                "defaultRouteRestored": (
                    before["network"]["defaultRouteFingerprint"]
                    == final["network"]["defaultRouteFingerprint"]
                ),
                "routeTableRestored": (
                    before["network"]["routeTableFingerprint"]
                    == final["network"]["routeTableFingerprint"]
                ),
                "publicInternetAfter": final["network"]["publicInternet"],
                "dnsName": target["checks"]["dnsName"],
                "dnsAnswerCount": len(final_answers),
                "directUrl": target["checks"]["directUrl"],
                "directHttpStatus": final_http_status,
                "resolverFingerprintBefore": before["network"]["resolverFingerprint"],
                "resolverFingerprintAfter": final["network"]["resolverFingerprint"],
                "defaultRouteFingerprintBefore": before["network"][
                    "defaultRouteFingerprint"
                ],
                "defaultRouteFingerprintAfter": final["network"][
                    "defaultRouteFingerprint"
                ],
                "routeTableFingerprintBefore": before["network"][
                    "routeTableFingerprint"
                ],
                "routeTableFingerprintAfter": final["network"]["routeTableFingerprint"],
                "ownedRouteCountAfter": final["network"]["ownedRouteCount"],
                "ownedResolverArtifactCountAfter": final["network"][
                    "ownedResolverArtifactCount"
                ],
                "dnsReceiptSha256": digest_bytes(
                    canonical([dns_receipt, final_dns_receipt])
                ),
                "directProbeReceiptSha256": digest_bytes(
                    canonical(
                        [
                            http_status,
                            direct_receipt,
                            final_http_status,
                            final_direct_receipt,
                        ]
                    )
                ),
                "routesReceiptSha256": digest_bytes(final["network"]["_routesBytes"]),
                "resolverReceiptSha256": digest_bytes(
                    final["network"]["_resolverBytes"]
                ),
                "processesReceiptSha256": digest_bytes(
                    canonical(final["service"]["_processes"])
                ),
            },
        }
    except Exception:
        try:
            restore_transaction(transaction, target, transaction_id)
        except Exception as rollback_error:
            print(
                f"automatic rollback also failed: {rollback_error}",
                file=sys.stderr,
            )
        raise


def remove_staged_path(stage: pathlib.Path) -> None:
    try:
        stage.unlink(missing_ok=True)
    except OSError as error:
        fail(f"staged artifact cleanup failed: {error}")
    if stage.exists() or stage.is_symlink():
        fail("staged artifact cleanup left remote residue")


def copy_staged_artifact(
    stage: pathlib.Path,
    root: pathlib.Path,
    transaction_id: str,
) -> tuple[pathlib.Path, bool]:
    root_created = not root.exists()
    private = root / f".staged-{transaction_id}"
    source_fd = -1
    destination_fd = -1
    private_created = False
    primary_error: Exception | None = None
    descriptor_cleanup_errors: list[str] = []
    try:
        root.mkdir(parents=True, exist_ok=True, mode=0o700)
        root_metadata = root.lstat()
        if (
            not stat.S_ISDIR(root_metadata.st_mode)
            or root_metadata.st_uid != os.geteuid()
            or root_metadata.st_mode & 0o077
        ):
            fail(
                "fleet transaction root is not a private "
                "administrator directory"
            )
        source_fd = os.open(stage, os.O_RDONLY | os.O_NOFOLLOW)
        source_metadata = os.fstat(source_fd)
        if not stat.S_ISREG(source_metadata.st_mode):
            fail("staged artifact is not a regular non-symlink file")
        destination_fd = os.open(
            private,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL,
            0o600,
        )
        private_created = True
        with (
            os.fdopen(source_fd, "rb", closefd=False) as source,
            os.fdopen(destination_fd, "wb", closefd=False) as destination,
        ):
            shutil.copyfileobj(source, destination)
            destination.flush()
            os.fsync(destination.fileno())
    except Exception as error:
        primary_error = error
    finally:
        if destination_fd >= 0:
            try:
                os.close(destination_fd)
            except OSError as error:
                descriptor_cleanup_errors.append(
                    f"private descriptor: {error}"
                )
        if source_fd >= 0:
            try:
                os.close(source_fd)
            except OSError as error:
                descriptor_cleanup_errors.append(
                    f"source descriptor: {error}"
                )
    if primary_error is None and descriptor_cleanup_errors:
        primary_error = RuntimeError("descriptor cleanup failed")
        descriptor_cleanup_errors = [
            f"staged artifact descriptor cleanup: {value}"
            for value in descriptor_cleanup_errors
        ]
    if primary_error is not None:
        cleanup_errors = descriptor_cleanup_errors
        if private_created:
            try:
                private.unlink()
            except OSError as error:
                cleanup_errors.append(f"private staged artifact: {error}")
        if root_created:
            try:
                root.rmdir()
            except OSError as error:
                cleanup_errors.append(f"private staging directory: {error}")
        details = f"staged artifact could not be secured: {primary_error}"
        if cleanup_errors:
            details += "; cleanup also failed: " + "; ".join(cleanup_errors)
        fail(details)
    return private, root_created


def finish_staged_cleanup(
    primary_error: Exception | None,
    cleanup_errors: list[str],
) -> None:
    if primary_error is not None:
        if cleanup_errors:
            fail(
                f"{primary_error}; staged artifact cleanup also failed: "
                + "; ".join(cleanup_errors)
            )
        raise primary_error
    if cleanup_errors:
        fail("staged artifact cleanup failed: " + "; ".join(cleanup_errors))


def install(
    payload: dict[str, Any],
    target: dict[str, Any],
    expected: dict[str, Any],
) -> dict[str, Any]:
    stage_name = payload.get("stageName")
    if (
        not isinstance(stage_name, str)
        or re.fullmatch(
            r"\.nvpn-fleet-[0-9a-f]{32}\.artifact",
            stage_name,
        )
        is None
    ):
        fail("staged artifact name is invalid")
    sudo_user = os.environ.get("SUDO_USER", "")
    if not sudo_user:
        fail("Linux adapter requires sudo with SUDO_USER")
    stage = pathlib.Path(pwd.getpwnam(sudo_user).pw_dir) / stage_name
    if not stage.is_file():
        fail("staged artifact is missing")
    transaction_id = expected["transactionId"]
    if (
        not isinstance(transaction_id, str)
        or re.fullmatch(r"[0-9a-f]{32}", transaction_id) is None
    ):
        fail("transaction id is invalid")
    root = absolute_path(
        target["deployment"].get("transactionRoot", "/var/lib/nvpn/fleet-canary"),
        "transactionRoot",
    )
    transaction = root / transaction_id
    if transaction.exists():
        fail("transaction id already exists")
    private_stage: pathlib.Path | None = None
    root_created = False
    result: dict[str, Any] | None = None
    primary_error: Exception | None = None
    try:
        private_stage, root_created = copy_staged_artifact(
            stage,
            root,
            transaction_id,
        )
        result = install_staged(payload, target, expected, private_stage)
    except Exception as error:
        primary_error = error
    cleanup_errors: list[str] = []
    for path in (private_stage,):
        if path is None:
            continue
        try:
            remove_staged_path(path)
        except Exception as error:
            cleanup_errors.append(str(error))
    if root_created and not transaction.exists():
        try:
            root.rmdir()
        except OSError as error:
            cleanup_errors.append(f"private staging directory: {error}")
    finish_staged_cleanup(primary_error, cleanup_errors)
    if result is None:
        fail("staged install returned no result")
    return result


payload = json.loads(base64.b64decode(FLEET_PAYLOAD_B64))
if payload.get("protocol") != "nvpn-fleet-ssh-transactional-v2":
    fail("fleet protocol mismatch")
target = payload["target"]
action = payload["action"]
transaction_root = absolute_path(
    target["deployment"].get("transactionRoot", "/var/lib/nvpn/fleet-canary"),
    "transactionRoot",
)
if action == "probe":
    state = capture(target, checks=target["checks"])
    pending = pending_transactions(transaction_root)
    result = {
        "schema": 2,
        "targetId": target["id"],
        "reachable": True,
        "platform": target["platform"],
        "arch": target["arch"],
        "machineIdentitySha256": machine_identity(),
        "realChecks": True,
        "mocked": False,
        "remoteBuildPerformed": False,
        "probeBinarySha256": state["probeBinarySha256"],
        "probeAppVersion": state["probeAppVersion"],
        "probeFipsCoreVersion": state["probeFipsCoreVersion"],
        "transaction": {
            "recoveryRequired": bool(pending),
            "pendingTransactionIds": pending,
        },
        "service": public_service(state["service"]),
        "config": state["config"],
        "network": public_network(state["network"]),
    }
elif action == "install":
    result = install(payload, target, payload["expectations"])
elif action == "rollback":
    transaction_id = payload["expectations"]["transactionId"]
    result = restore_transaction(
        transaction_root / transaction_id,
        target,
        transaction_id,
    )
else:
    fail("unsupported fleet action")
sys.stdout.write(json.dumps(result, separators=(",", ":"), sort_keys=True))
