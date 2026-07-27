"""Strict validation for real, transactional nvpn fleet evidence.

This module deliberately validates canonical observations rather than accepting
an unstructured "passed" flag.  File-system binding for the raw driver receipt
is performed by ``fleet_release_canary.py`` before these semantic checks run.
"""

from __future__ import annotations

import re
from typing import Any


HEX64 = re.compile(r"^[0-9a-f]{64}$")
TRANSACTION_ID = re.compile(r"^[0-9a-f]{32}$")


class EvidenceError(RuntimeError):
    """A missing or inconsistent real-machine evidence field."""


def fail(message: str) -> None:
    raise EvidenceError(message)


def exact(value: Any, expected: Any, label: str) -> None:
    if value != expected:
        fail(f"{label} mismatch")


def true(value: Any, label: str) -> None:
    if value is not True:
        fail(f"{label} must be true")


def false(value: Any, label: str) -> None:
    if value is not False:
        fail(f"{label} must be false")


def boolean(value: Any, label: str) -> bool:
    if not isinstance(value, bool):
        fail(f"{label} must be a boolean")
    return value


def hex64(value: Any, label: str) -> str:
    if not isinstance(value, str) or HEX64.fullmatch(value) is None:
        fail(f"{label} is invalid")
    return value


def optional_hex64(value: Any, label: str) -> str | None:
    if value is None:
        return None
    return hex64(value, label)


def positive(value: Any, label: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
        fail(f"{label} must be a positive integer")
    return value


def nonnegative(value: Any, label: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value < 0:
        fail(f"{label} must be a non-negative integer")
    return value


def mapping(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        fail(f"{label} requires an object")
    return value


def nonempty(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value.strip():
        fail(f"{label} is required")
    return value


def validate_service_snapshot(
    value: Any,
    label: str,
) -> dict[str, Any]:
    service = mapping(value, label)
    installed = boolean(service.get("installed"), f"{label}.installed")
    enabled = boolean(service.get("enabled"), f"{label}.enabled")
    running = boolean(service.get("running"), f"{label}.running")
    binary_present = boolean(service.get("binaryPresent"), f"{label}.binaryPresent")
    process_count = nonnegative(service.get("processCount"), f"{label}.processCount")
    pid = service.get("pid")
    if running:
        exact(process_count, 1, f"{label}.processCount")
        pid = positive(pid, f"{label}.pid")
    else:
        exact(process_count, 0, f"{label}.processCount")
        exact(pid, None, f"{label}.pid")
    if enabled and not installed:
        fail(f"{label} cannot be enabled when not installed")
    if running and not installed:
        fail(f"{label} cannot be running when not installed")
    if installed and not binary_present:
        fail(f"{label} installed service has no executable")
    binary_hash = optional_hex64(service.get("binarySha256"), f"{label}.binarySha256")
    if binary_present and binary_hash is None:
        fail(f"{label}.binarySha256 is required for an existing executable")
    if not binary_present and binary_hash is not None:
        fail(f"{label}.binarySha256 must be null when executable is absent")
    definition_hash = optional_hex64(
        service.get("definitionSha256"), f"{label}.definitionSha256"
    )
    if installed and definition_hash is None:
        fail(f"{label}.definitionSha256 is required for an installed service")
    if not installed and definition_hash is not None:
        fail(f"{label}.definitionSha256 must be null when service is absent")
    return {
        "installed": installed,
        "enabled": enabled,
        "running": running,
        "binaryPresent": binary_present,
        "binarySha256": binary_hash,
        "definitionSha256": definition_hash,
        "processCount": process_count,
        "pid": pid,
    }


def validate_config_snapshot(
    value: Any,
    target: dict[str, Any],
    label: str,
) -> dict[str, Any]:
    config = mapping(value, label)
    sha = hex64(config.get("sha256"), f"{label}.sha256")
    signed_roster_store = hex64(
        config.get("signedRosterStoreSha256"),
        f"{label}.signedRosterStoreSha256",
    )
    roster_identity = hex64(
        config.get("rosterIdentitySha256"),
        f"{label}.rosterIdentitySha256",
    )
    roster_peer_count = nonnegative(
        config.get("rosterPeerCount"), f"{label}.rosterPeerCount"
    )
    local_identity = hex64(
        config.get("localDeviceIdentitySha256"),
        f"{label}.localDeviceIdentitySha256",
    )
    network_identity = hex64(
        config.get("networkIdentitySha256"),
        f"{label}.networkIdentitySha256",
    )
    expected = target["expected"]
    exact(
        sha,
        expected["configSha256"],
        f"{label}.sha256 frozen inventory",
    )
    exact(
        signed_roster_store,
        expected["signedRosterStoreSha256"],
        f"{label}.signedRosterStoreSha256 frozen inventory",
    )
    exact(
        roster_identity,
        expected["rosterIdentitySha256"],
        f"{label}.rosterIdentitySha256 frozen inventory",
    )
    exact(
        roster_peer_count,
        expected["rosterPeerCount"],
        f"{label}.rosterPeerCount frozen inventory",
    )
    exact(
        local_identity,
        expected["localDeviceIdentitySha256"],
        f"{label}.localDeviceIdentitySha256 frozen inventory",
    )
    exact(
        network_identity,
        expected["networkIdentitySha256"],
        f"{label}.networkIdentitySha256 frozen inventory",
    )
    return {
        "sha256": sha,
        "signedRosterStoreSha256": signed_roster_store,
        "rosterIdentitySha256": roster_identity,
        "rosterPeerCount": roster_peer_count,
        "localDeviceIdentitySha256": local_identity,
        "networkIdentitySha256": network_identity,
    }


def validate_network_snapshot(value: Any, label: str) -> dict[str, Any]:
    network = mapping(value, label)
    true(network.get("directMode"), f"{label}.directMode")
    false(
        network.get("wireguardExitEnabled"),
        f"{label}.wireguardExitEnabled",
    )
    true(network.get("dnsResolved"), f"{label}.dnsResolved")
    true(network.get("publicInternet"), f"{label}.publicInternet")
    exact(network.get("ownedRouteCount"), 0, f"{label}.ownedRouteCount")
    exact(
        network.get("ownedResolverArtifactCount"),
        0,
        f"{label}.ownedResolverArtifactCount",
    )
    resolver = hex64(
        network.get("resolverFingerprint"),
        f"{label}.resolverFingerprint",
    )
    default_route = hex64(
        network.get("defaultRouteFingerprint"),
        f"{label}.defaultRouteFingerprint",
    )
    route_table = hex64(
        network.get("routeTableFingerprint"),
        f"{label}.routeTableFingerprint",
    )
    return {
        "resolverFingerprint": resolver,
        "defaultRouteFingerprint": default_route,
        "routeTableFingerprint": route_table,
        "ownedRouteCount": 0,
        "ownedResolverArtifactCount": 0,
    }


def validate_probe(
    result: dict[str, Any],
    target: dict[str, Any],
    artifact: dict[str, Any],
    source: dict[str, str],
) -> dict[str, Any]:
    label = f"target {target['id']} probe evidence"
    exact(result.get("schema"), 2, f"{label} schema")
    exact(result.get("targetId"), target["id"], f"{label} targetId")
    true(result.get("reachable"), f"{label} reachable")
    exact(result.get("platform"), target["platform"], f"{label} platform")
    exact(result.get("arch"), target["arch"], f"{label} arch")
    true(result.get("realChecks"), f"{label} realChecks")
    false(result.get("mocked"), f"{label} mocked")
    false(result.get("remoteBuildPerformed"), f"{label} remoteBuildPerformed")
    probe_binary_hash = hex64(
        result.get("probeBinarySha256"),
        f"{label} probeBinarySha256",
    )
    exact(
        probe_binary_hash,
        artifact["_installed_hash"],
        f"{label} probeBinarySha256 frozen artifact",
    )
    probe_app_version = nonempty(
        result.get("probeAppVersion"),
        f"{label} probeAppVersion",
    )
    exact(
        probe_app_version,
        source["appVersion"],
        f"{label} probeAppVersion frozen source",
    )
    probe_fips_version = nonempty(
        result.get("probeFipsCoreVersion"),
        f"{label} probeFipsCoreVersion",
    )
    exact(
        probe_fips_version,
        f"{source['fipsVersion']} (rev {source['fipsGitSha'][:10]})",
        f"{label} probeFipsCoreVersion frozen source",
    )
    identity = hex64(
        result.get("machineIdentitySha256"), f"{label} machineIdentitySha256"
    )
    exact(
        identity,
        target["expected"]["machineIdentitySha256"],
        f"{label} frozen machine identity",
    )
    transaction = mapping(result.get("transaction"), f"{label} transaction")
    false(
        transaction.get("recoveryRequired"),
        f"{label} transaction.recoveryRequired",
    )
    exact(
        transaction.get("pendingTransactionIds"),
        [],
        f"{label} transaction.pendingTransactionIds",
    )
    service = validate_service_snapshot(result.get("service"), f"{label} service")
    config = validate_config_snapshot(result.get("config"), target, f"{label} config")
    network = validate_network_snapshot(result.get("network"), f"{label} network")
    return {
        "machineIdentitySha256": identity,
        "probeBinarySha256": probe_binary_hash,
        "probeAppVersion": probe_app_version,
        "probeFipsCoreVersion": probe_fips_version,
        "service": service,
        "config": config,
        "network": network,
    }


def validate_snapshot_against_probe(
    value: Any,
    target: dict[str, Any],
    probe: dict[str, Any],
    label: str,
) -> None:
    snapshot = mapping(value, label)
    true(snapshot.get("durable"), f"{label}.durable")
    for field in (
        "serviceReceiptSha256",
        "configReceiptSha256",
        "routesReceiptSha256",
        "resolverReceiptSha256",
        "processesReceiptSha256",
        "statusReceiptSha256",
    ):
        hex64(snapshot.get(field), f"{label}.{field}")
    service = validate_service_snapshot(snapshot.get("service"), f"{label}.service")
    config = validate_config_snapshot(snapshot.get("config"), target, f"{label}.config")
    network = validate_network_snapshot(snapshot.get("network"), f"{label}.network")
    exact(service, probe["service"], f"{label}.service versus probe")
    exact(config, probe["config"], f"{label}.config versus probe")
    exact(network, probe["network"], f"{label}.network versus probe")


def validate_install_result(
    result: dict[str, Any],
    target: dict[str, Any],
    artifact: dict[str, Any],
    source: dict[str, str],
    probe: dict[str, Any],
    transaction_id: str,
) -> None:
    label = f"target {target['id']} install evidence"
    exact(result.get("schema"), 2, f"{label} schema")
    exact(result.get("targetId"), target["id"], f"{label} targetId")
    exact(result.get("platform"), target["platform"], f"{label} platform")
    exact(result.get("arch"), target["arch"], f"{label} arch")
    exact(
        result.get("machineIdentitySha256"),
        probe["machineIdentitySha256"],
        f"{label} machine identity",
    )
    true(result.get("realChecks"), f"{label} realChecks")
    false(result.get("mocked"), f"{label} mocked")
    false(result.get("remoteBuildPerformed"), f"{label} remoteBuildPerformed")
    true(result.get("installAuthorized"), f"{label} installAuthorized")
    for field, expected in source.items():
        exact(result.get(field), expected, f"{label} {field}")
    exact(
        result.get("artifactSha256"),
        artifact["sha256"],
        f"{label} artifactSha256",
    )
    exact(
        result.get("artifactSize"),
        artifact["size"],
        f"{label} artifactSize",
    )
    exact(
        result.get("stagedArtifactSha256"),
        artifact["sha256"],
        f"{label} stagedArtifactSha256",
    )

    transaction = mapping(result.get("transaction"), f"{label} transaction")
    if (
        not isinstance(transaction_id, str)
        or TRANSACTION_ID.fullmatch(transaction_id) is None
    ):
        fail(f"{label} expected transaction id is invalid")
    exact(
        transaction.get("id"),
        transaction_id,
        f"{label} transaction.id",
    )
    exact(transaction.get("state"), "committed", f"{label} transaction.state")
    true(
        transaction.get("durableJournal"),
        f"{label} transaction.durableJournal",
    )
    true(
        transaction.get("rollbackAvailable"),
        f"{label} transaction.rollbackAvailable",
    )
    hex64(
        transaction.get("journalReceiptSha256"),
        f"{label} transaction.journalReceiptSha256",
    )
    validate_snapshot_against_probe(
        transaction.get("snapshot"),
        target,
        probe,
        f"{label} transaction.snapshot",
    )

    service = mapping(result.get("service"), f"{label} service evidence")
    for field in ("installed", "enabled", "running", "restartDurable"):
        true(service.get(field), f"{label} service.{field}")
    exact(
        service.get("binarySha256"),
        artifact["_installed_hash"],
        f"{label} service.binarySha256",
    )
    exact(
        service.get("binaryVersion"),
        f"nvpn {source['appVersion']}",
        f"{label} service.binaryVersion",
    )
    exact(
        service.get("fipsCoreVersion"),
        f"{source['fipsVersion']} (rev {source['fipsGitSha'][:10]})",
        f"{label} service.fipsCoreVersion",
    )
    exact(
        service.get("priorInstalled"),
        probe["service"]["installed"],
        f"{label} service.priorInstalled",
    )
    exact(
        service.get("priorEnabled"),
        probe["service"]["enabled"],
        f"{label} service.priorEnabled",
    )
    exact(
        service.get("priorRunning"),
        probe["service"]["running"],
        f"{label} service.priorRunning",
    )
    exact(
        service.get("priorBinaryPresent"),
        probe["service"]["binaryPresent"],
        f"{label} service.priorBinaryPresent",
    )
    exact(
        service.get("priorBinarySha256"),
        probe["service"]["binarySha256"],
        f"{label} service.priorBinarySha256",
    )
    exact(service.get("processCount"), 1, f"{label} service.processCount")
    first_pid = positive(
        service.get("pidBeforeRestart"), f"{label} service.pidBeforeRestart"
    )
    final_pid = positive(
        service.get("pidAfterRestart"), f"{label} service.pidAfterRestart"
    )
    if first_pid == final_pid:
        fail(f"{label} did not prove a real service restart")

    config = mapping(result.get("config"), f"{label} config evidence")
    false(
        config.get("mutationOutsideInstall"),
        f"{label} config.mutationOutsideInstall",
    )
    for field in ("sha256Before", "sha256After"):
        exact(
            config.get(field),
            probe["config"]["sha256"],
            f"{label} config.{field}",
        )
    for field in (
        "signedRosterStoreSha256Before",
        "signedRosterStoreSha256After",
    ):
        exact(
            config.get(field),
            probe["config"]["signedRosterStoreSha256"],
            f"{label} config.{field}",
        )
    for field in (
        "rosterIdentitySha256Before",
        "rosterIdentitySha256After",
    ):
        exact(
            config.get(field),
            probe["config"]["rosterIdentitySha256"],
            f"{label} config.{field}",
        )
    for field in ("rosterPeerCountBefore", "rosterPeerCountAfter"):
        exact(
            config.get(field),
            probe["config"]["rosterPeerCount"],
            f"{label} config.{field}",
        )
    for field in (
        "localDeviceIdentitySha256Before",
        "localDeviceIdentitySha256After",
    ):
        exact(
            config.get(field),
            probe["config"]["localDeviceIdentitySha256"],
            f"{label} config.{field}",
        )
    for field in ("networkIdentitySha256Before", "networkIdentitySha256After"):
        exact(
            config.get(field),
            probe["config"]["networkIdentitySha256"],
            f"{label} config.{field}",
        )

    roster = mapping(result.get("roster"), f"{label} roster evidence")
    for field in ("meshReady", "payloadSuccess", "txIncreased", "rxIncreased"):
        true(roster.get(field), f"{label} roster.{field}")
    exact(
        roster.get("expectedPeerCount"),
        target["expected"]["rosterPeerCount"],
        f"{label} roster.expectedPeerCount",
    )
    connected = nonnegative(
        roster.get("connectedPeerCount"), f"{label} roster.connectedPeerCount"
    )
    if target["expected"]["rosterPeerCount"] > 0 and connected <= 0:
        fail(f"{label} has no connected roster peer")
    exact(
        roster.get("payloadTarget"),
        target["checks"]["payloadTarget"],
        f"{label} roster.payloadTarget",
    )
    tx_before = nonnegative(
        roster.get("txBytesBefore"), f"{label} roster.txBytesBefore"
    )
    tx_after = positive(roster.get("txBytesAfter"), f"{label} roster.txBytesAfter")
    rx_before = nonnegative(
        roster.get("rxBytesBefore"), f"{label} roster.rxBytesBefore"
    )
    rx_after = positive(roster.get("rxBytesAfter"), f"{label} roster.rxBytesAfter")
    if tx_after <= tx_before or rx_after <= rx_before:
        fail(f"{label} payload counters did not increase")
    hex64(
        roster.get("payloadReceiptSha256"),
        f"{label} roster.payloadReceiptSha256",
    )

    network = mapping(result.get("network"), f"{label} network evidence")
    for field in (
        "directMode",
        "dnsResolvedBefore",
        "dnsResolvedAfter",
        "dnsRestored",
        "defaultRouteRestored",
        "routeTableRestored",
        "publicInternetAfter",
    ):
        true(network.get(field), f"{label} network.{field}")
    false(
        network.get("wireguardExitEnabled"),
        f"{label} network.wireguardExitEnabled",
    )
    exact(
        network.get("dnsName"),
        target["checks"]["dnsName"],
        f"{label} network.dnsName",
    )
    positive(network.get("dnsAnswerCount"), f"{label} network.dnsAnswerCount")
    exact(
        network.get("directUrl"),
        target["checks"]["directUrl"],
        f"{label} network.directUrl",
    )
    status = positive(
        network.get("directHttpStatus"), f"{label} network.directHttpStatus"
    )
    if status < 200 or status >= 400:
        fail(f"{label} direct HTTP status is not successful")
    for field in ("resolverFingerprintBefore", "resolverFingerprintAfter"):
        exact(
            network.get(field),
            probe["network"]["resolverFingerprint"],
            f"{label} network.{field}",
        )
    for field in (
        "defaultRouteFingerprintBefore",
        "defaultRouteFingerprintAfter",
    ):
        exact(
            network.get(field),
            probe["network"]["defaultRouteFingerprint"],
            f"{label} network.{field}",
        )
    for field in ("routeTableFingerprintBefore", "routeTableFingerprintAfter"):
        exact(
            network.get(field),
            probe["network"]["routeTableFingerprint"],
            f"{label} network.{field}",
        )
    exact(
        network.get("ownedRouteCountAfter"),
        0,
        f"{label} network.ownedRouteCountAfter",
    )
    exact(
        network.get("ownedResolverArtifactCountAfter"),
        0,
        f"{label} network.ownedResolverArtifactCountAfter",
    )
    for field in (
        "dnsReceiptSha256",
        "directProbeReceiptSha256",
        "routesReceiptSha256",
        "resolverReceiptSha256",
        "processesReceiptSha256",
    ):
        hex64(network.get(field), f"{label} network.{field}")


def validate_rollback(
    result: dict[str, Any],
    target: dict[str, Any],
    probe: dict[str, Any],
    transaction_id: str,
) -> None:
    label = f"target {target['id']} rollback evidence"
    exact(result.get("schema"), 2, f"{label} schema")
    exact(result.get("targetId"), target["id"], f"{label} targetId")
    exact(
        result.get("machineIdentitySha256"),
        probe["machineIdentitySha256"],
        f"{label} machine identity",
    )
    false(result.get("remoteBuildPerformed"), f"{label} remote build")
    transaction = mapping(result.get("transaction"), f"{label} transaction")
    exact(transaction.get("id"), transaction_id, f"{label} transaction.id")
    exact(
        transaction.get("state"),
        "rolled-back",
        f"{label} transaction.state",
    )
    true(
        transaction.get("durableJournal"),
        f"{label} transaction.durableJournal",
    )
    hex64(
        transaction.get("journalReceiptSha256"),
        f"{label} transaction.journalReceiptSha256",
    )
    service = validate_service_snapshot(result.get("service"), f"{label} service")
    config = validate_config_snapshot(result.get("config"), target, f"{label} config")
    network = validate_network_snapshot(result.get("network"), f"{label} network")
    exact(service, probe["service"], f"{label} service versus probe")
    exact(config, probe["config"], f"{label} config versus probe")
    exact(network, probe["network"], f"{label} network versus probe")
    for field in (
        "snapshotReceiptSha256",
        "serviceReceiptSha256",
        "configReceiptSha256",
        "routesReceiptSha256",
        "resolverReceiptSha256",
        "processesReceiptSha256",
    ):
        hex64(result.get(field), f"{label} {field}")
