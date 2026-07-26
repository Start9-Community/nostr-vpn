#!/usr/bin/env python3
"""Validate one physical-iOS VPN probe receipt and write its counter summary."""

import json
import sys

(
    path,
    summary_path,
    expected_build_git_sha,
    require_reply_raw,
    expected_exit_ip,
    verify_direct_raw,
    expected_dns_mode,
    expected_dns_provider,
    expected_custom_url,
    expected_bootstrap_ips,
    expected_through_servers,
    switch_direct_raw,
    expect_wireguard_raw,
    expected_debug_dns_injected_raw,
    expect_active_lifecycle_raw,
    expected_active_lifecycle_cycles_raw,
    expected_wireguard_endpoint,
    expected_resolve_host,
    expected_fetch_url,
) = sys.argv[1:20]
require_reply = require_reply_raw.strip().lower() in {"1", "true", "yes", "on"}
verify_direct = verify_direct_raw.strip().lower() in {"1", "true", "yes", "on"}
switch_direct = switch_direct_raw.strip().lower() in {"1", "true", "yes", "on"}
expect_wireguard = expect_wireguard_raw.strip().lower() in {"1", "true", "yes", "on"}
expect_active_lifecycle = (
    expect_active_lifecycle_raw.strip().lower() in {"1", "true", "yes", "on"}
)
expected_active_lifecycle_cycles = (
    int(expected_active_lifecycle_cycles_raw)
    if expected_active_lifecycle_cycles_raw.isdigit()
    else None
)
expected_debug_dns_injected = None
if expected_debug_dns_injected_raw:
    expected_debug_dns_injected = (
        expected_debug_dns_injected_raw.strip().lower() in {"1", "true", "yes", "on"}
    )
with open(path, encoding="utf-8") as fh:
    result = json.load(fh)

runtime = None

def counter(value):
    if isinstance(value, int):
        return value
    if isinstance(value, str) and value.isdigit():
        return int(value)
    return None

def probe_values():
    expected = counter(result.get("tunPacketProbeExpectedPackets"))
    sent = counter(result.get("tunPacketProbeSentPackets"))
    observed = counter(result.get("tunPacketProbeObservedPackets"))
    missing = counter(result.get("tunPacketProbeMissingPackets"))
    reply_packets = counter(result.get("tunPacketProbeReplyPackets"))
    missing_reply_packets = counter(result.get("tunPacketProbeMissingReplyPackets"))
    observed_bytes = counter(result.get("tunPacketProbeObservedBytesRead"))
    observed_written = counter(result.get("tunPacketProbeObservedWritten"))
    observed_bytes_written = counter(result.get("tunPacketProbeObservedBytesWritten"))
    dropped_delta = counter(result.get("tunPacketProbeDroppedDelta"))
    loss_pct = None
    observed_pct = None
    if expected and expected > 0:
        if missing is not None:
            loss_pct = round(missing * 100.0 / expected, 3)
        if observed is not None:
            observed_pct = round(observed * 100.0 / expected, 3)
    return {
        "target": result.get("tunPacketProbeTarget"),
        "port": counter(result.get("tunPacketProbePort")),
        "expected": expected,
        "sent": sent,
        "observed": observed,
        "missing": missing,
        "replyPackets": reply_packets,
        "missingReplyPackets": missing_reply_packets,
        "observedPct": observed_pct,
        "packetLossPct": loss_pct,
        "observedBytesRead": observed_bytes,
        "observedWritten": observed_written,
        "observedBytesWritten": observed_bytes_written,
        "droppedDelta": dropped_delta,
        "firstObservedMs": counter(result.get("tunPacketProbeFirstObservedMs")),
        "elapsedMs": counter(result.get("tunPacketProbeElapsedMs")),
        "polls": counter(result.get("tunPacketProbePolls")),
        "pollIntervalMs": counter(result.get("tunPacketProbePollIntervalMs")),
        "baselineRead": counter(result.get("tunPacketProbeBaselineRead")),
        "finalRead": counter(result.get("tunPacketProbeFinalRead")),
        "baselineBytesRead": counter(result.get("tunPacketProbeBaselineBytesRead")),
        "finalBytesRead": counter(result.get("tunPacketProbeFinalBytesRead")),
        "baselineWritten": counter(result.get("tunPacketProbeBaselineWritten")),
        "finalWritten": counter(result.get("tunPacketProbeFinalWritten")),
        "baselineBytesWritten": counter(result.get("tunPacketProbeBaselineBytesWritten")),
        "finalBytesWritten": counter(result.get("tunPacketProbeFinalBytesWritten")),
        "baselineDropped": counter(result.get("tunPacketProbeBaselineDropped")),
        "finalDropped": counter(result.get("tunPacketProbeFinalDropped")),
        "readIncreased": result.get("tunPacketProbeReadIncreased"),
        "bytesReadIncreased": result.get("tunPacketProbeBytesReadIncreased"),
        "writtenIncreased": result.get("tunPacketProbeWrittenIncreased"),
        "bytesWrittenIncreased": result.get("tunPacketProbeBytesWrittenIncreased"),
        "droppedIncreased": result.get("tunPacketProbeDroppedIncreased"),
        "replyRequired": require_reply,
        "replyObserved": expected is not None
        and reply_packets is not None
        and reply_packets >= expected
        and result.get("tunPacketProbeWrittenIncreased") is True
        and result.get("tunPacketProbeBytesWrittenIncreased") is True
        and result.get("tunPacketProbeDroppedIncreased") is False,
        "error": result.get("tunPacketProbeError"),
        "replyError": result.get("tunPacketProbeReplyError"),
        "rawOutput": path,
    }

def display(value, suffix=""):
    if value is None:
        return "?"
    if isinstance(value, float):
        return f"{value:.3f}".rstrip("0").rstrip(".") + suffix
    return f"{value}{suffix}"

def probe_summary():
    values = probe_values()
    parts = [
        f"read={values['baselineRead']}->{values['finalRead']}",
        f"observed={values['observed']}/{values['expected']}",
        f"observedPct={display(values['observedPct'], '%')}",
        f"missing={values['missing']}",
        f"lossPct={display(values['packetLossPct'], '%')}",
        f"replies={values['replyPackets']}/{values['expected']}",
        f"missingReplies={values['missingReplyPackets']}",
        f"bytes={values['observedBytesRead']}",
        f"written={values['observedWritten']}",
        f"bytesWritten={values['observedBytesWritten']}",
        f"drops={values['droppedDelta']}",
        f"firstMs={values['firstObservedMs']}",
        f"elapsedMs={values['elapsedMs']}",
        f"polls={values['polls']}",
        f"target={values['target']}",
    ]
    if isinstance(runtime, dict):
        parts.extend([
            f"runtimeRead={runtime.get('tunPacketsRead')}",
            f"runtimeWritten={runtime.get('tunPacketsWritten')}",
            f"runtimeDropped={runtime.get('tunPacketsDropped')}",
        ])
    return "iOS TUN packet probe counters: " + " ".join(parts)

def write_probe_summary(validation_errors=None):
    values = probe_values()
    if isinstance(runtime, dict):
        values["runtime"] = {
            "tunPacketsRead": counter(runtime.get("tunPacketsRead")),
            "tunBytesRead": counter(runtime.get("tunBytesRead")),
            "tunPacketsWritten": counter(runtime.get("tunPacketsWritten")),
            "tunBytesWritten": counter(runtime.get("tunBytesWritten")),
            "tunPacketsDropped": counter(runtime.get("tunPacketsDropped")),
        }
    values["replyRequired"] = require_reply
    values["passed"] = not validation_errors
    if validation_errors:
        values["validationErrors"] = validation_errors
    for key in (
        "phase",
        "packetTunnelStatusRawValue",
        "packetTunnelConnected",
        "vpnEnabled",
        "vpnActive",
        "startError",
        "vpnStartElapsedMs",
        "vpnWaitRequestedMs",
        "statusCollectionElapsedMs",
        "fetchElapsedMs",
        "debugProbeElapsedMs",
        "startedAt",
        "vpnStartFinishedAt",
        "finishedAt",
        "debugDnsInjected",
        "internetSource",
        "exitDnsMode",
        "exitDnsDohProvider",
        "exitDnsCustomDohUrl",
        "exitDnsCustomDohBootstrapIps",
        "exitDnsThroughExitServers",
        "activeTunnelLifecycleObserved",
        "activeTunnelLifecycleCycles",
        "activeTunnelStatusBeforeBackgroundRawValue",
        "activeTunnelStatusAfterForegroundRawValue",
        "postForegroundProbe",
        "wireguardExitEndpoint",
    ):
        if key in result:
            values[key] = result[key]
    for key in (
        "appBundleIdentifier",
        "appVersionName",
        "appVersionCode",
        "appBuildGitSha",
        "appBuildTimestampUtc",
    ):
        if key in result:
            values[key] = result[key]
    with open(summary_path, "w", encoding="utf-8") as fh:
        json.dump(values, fh, sort_keys=True, indent=2)
        fh.write("\n")
    return summary_path

errors = []
actual_build_git_sha = result.get("appBuildGitSha")
if expected_build_git_sha:
    if not actual_build_git_sha:
        errors.append(f"appBuildGitSha missing expected={expected_build_git_sha!r}")
    elif actual_build_git_sha != expected_build_git_sha:
        errors.append(
            f"appBuildGitSha={actual_build_git_sha!r} expected={expected_build_git_sha!r}"
        )
if result.get("phase") != "finished" or "finishedAt" not in result:
    errors.append(
        "debug probe did not finish "
        f"phase={result.get('phase')!r} finishedAt={result.get('finishedAt')!r}"
    )
if result.get("startError"):
    errors.append(f"startError={result['startError']}")
if result.get("packetTunnelStatusRawValue") != 3:
    errors.append(f"packetTunnelStatusRawValue={result.get('packetTunnelStatusRawValue')!r}")
if result.get("vpnEnabled") is not True:
    errors.append(f"vpnEnabled={result.get('vpnEnabled')!r}")
if expect_wireguard:
    if result.get("internetSource") != "wireguard":
        errors.append(f"internetSource={result.get('internetSource')!r} expected='wireguard'")
    if result.get("wireguardExitEnabled") is not True:
        errors.append(
            f"wireguardExitEnabled={result.get('wireguardExitEnabled')!r} expected=True"
        )
    if result.get("wireguardExitConfigured") is not True:
        errors.append(
            "wireguardExitConfigured="
            f"{result.get('wireguardExitConfigured')!r} expected=True"
        )
    if (
        expected_wireguard_endpoint
        and result.get("wireguardExitEndpoint") != expected_wireguard_endpoint
    ):
        errors.append(
            "wireguardExitEndpoint="
            f"{result.get('wireguardExitEndpoint')!r} "
            f"expected={expected_wireguard_endpoint!r}"
        )
if expect_active_lifecycle:
    if result.get("activeTunnelLifecycleObserved") is not True:
        errors.append(
            "activeTunnelLifecycleObserved="
            f"{result.get('activeTunnelLifecycleObserved')!r}"
        )
    cycles = counter(result.get("activeTunnelLifecycleCycles"))
    if (
        expected_active_lifecycle_cycles is None
        or not 1 <= expected_active_lifecycle_cycles <= 5
    ):
        errors.append(
            "expectedActiveTunnelLifecycleCycles="
            f"{expected_active_lifecycle_cycles_raw!r}"
        )
    elif cycles != expected_active_lifecycle_cycles:
        errors.append(
            f"activeTunnelLifecycleCycles={cycles!r} "
            f"expected={expected_active_lifecycle_cycles!r}"
        )
    if result.get("activeTunnelStatusBeforeBackgroundRawValue") != 3:
        errors.append(
            "activeTunnelStatusBeforeBackgroundRawValue="
            f"{result.get('activeTunnelStatusBeforeBackgroundRawValue')!r}"
        )
    if result.get("activeTunnelStatusAfterForegroundRawValue") != 3:
        errors.append(
            "activeTunnelStatusAfterForegroundRawValue="
            f"{result.get('activeTunnelStatusAfterForegroundRawValue')!r}"
        )
    if result.get("postForegroundProbe") is not True:
        errors.append(f"postForegroundProbe={result.get('postForegroundProbe')!r}")
    cycle_results = result.get("activeTunnelLifecycleCycleResults")
    if not isinstance(cycle_results, list) or len(cycle_results) != cycles:
        errors.append(
            "activeTunnelLifecycleCycleResults="
            f"{type(cycle_results).__name__}/"
            f"{len(cycle_results) if isinstance(cycle_results, list) else '?'} "
            f"expected={cycles!r}"
        )
    else:
        expected_cycle_dns = {
            "exitDnsMode": expected_dns_mode,
            "exitDnsDohProvider": expected_dns_provider,
            "exitDnsCustomDohUrl": expected_custom_url,
            "exitDnsCustomDohBootstrapIps": expected_bootstrap_ips,
            "exitDnsThroughExitServers": expected_through_servers,
        }
        for index, cycle_result in enumerate(cycle_results, start=1):
            prefix = f"activeLifecycleCycle[{index}]"
            if not isinstance(cycle_result, dict):
                errors.append(f"{prefix}={cycle_result!r}")
                continue
            if cycle_result.get("cycle") != index:
                errors.append(f"{prefix}.cycle={cycle_result.get('cycle')!r}")
            for key in ("statusBeforeBackgroundRawValue", "statusAfterForegroundRawValue"):
                if cycle_result.get(key) != 3:
                    errors.append(f"{prefix}.{key}={cycle_result.get(key)!r}")
            if cycle_result.get("postForegroundProbe") is not True:
                errors.append(
                    f"{prefix}.postForegroundProbe="
                    f"{cycle_result.get('postForegroundProbe')!r}"
                )
            for key in ("vpnEnabled", "vpnActive"):
                if cycle_result.get(key) is not True:
                    errors.append(f"{prefix}.{key}={cycle_result.get(key)!r}")
            if expect_wireguard:
                for key in ("wireguardExitEnabled", "wireguardExitConfigured"):
                    if cycle_result.get(key) is not True:
                        errors.append(f"{prefix}.{key}={cycle_result.get(key)!r}")
                if cycle_result.get("internetSource") != "wireguard":
                    errors.append(
                        f"{prefix}.internetSource="
                        f"{cycle_result.get('internetSource')!r}"
                    )
                if (
                    expected_wireguard_endpoint
                    and cycle_result.get("wireguardExitEndpoint")
                    != expected_wireguard_endpoint
                ):
                    errors.append(
                        f"{prefix}.wireguardExitEndpoint="
                        f"{cycle_result.get('wireguardExitEndpoint')!r}"
                    )
            if expected_dns_mode:
                for key, expected in expected_cycle_dns.items():
                    if cycle_result.get(key) != expected:
                        errors.append(
                            f"{prefix}.{key}={cycle_result.get(key)!r} "
                            f"expected={expected!r}"
                        )
            if expected_resolve_host:
                if cycle_result.get("resolvedHost") != expected_resolve_host:
                    errors.append(
                        f"{prefix}.resolvedHost="
                        f"{cycle_result.get('resolvedHost')!r} "
                        f"expected={expected_resolve_host!r}"
                    )
                if cycle_result.get("resolveError"):
                    errors.append(
                        f"{prefix}.resolveError={cycle_result.get('resolveError')!r}"
                    )
                addresses = cycle_result.get("resolvedAddresses")
                if not isinstance(addresses, list) or not addresses:
                    errors.append(f"{prefix}.resolvedAddresses={addresses!r}")
                elif expected_exit_ip and expected_exit_ip not in addresses:
                    errors.append(
                        f"{prefix}.resolvedAddresses={addresses!r} "
                        f"expected={expected_exit_ip!r}"
                    )
            if expected_fetch_url:
                if cycle_result.get("url") != expected_fetch_url:
                    errors.append(
                        f"{prefix}.url={cycle_result.get('url')!r} "
                        f"expected={expected_fetch_url!r}"
                    )
                if cycle_result.get("fetchError"):
                    errors.append(
                        f"{prefix}.fetchError={cycle_result.get('fetchError')!r}"
                    )
                status_code = cycle_result.get("statusCode")
                if not isinstance(status_code, int) or not 200 <= status_code < 400:
                    errors.append(f"{prefix}.statusCode={status_code!r}")
            elif cycle_result.get("fetchError"):
                errors.append(
                    f"{prefix}.unexpectedFetchError={cycle_result.get('fetchError')!r}"
                )
            expected_packets = counter(
                cycle_result.get("tunPacketProbeExpectedPackets")
            )
            replies = counter(cycle_result.get("tunPacketProbeReplyPackets"))
            if (
                cycle_result.get("tunPacketProbeReadIncreased") is not True
                or cycle_result.get("tunPacketProbeBytesReadIncreased") is not True
                or cycle_result.get("tunPacketProbeDroppedIncreased") is not False
                or expected_packets is None
                or expected_packets < 1
            ):
                errors.append(f"{prefix}.tunPacketProbe=invalid")
            if require_reply and (
                replies is None
                or expected_packets is None
                or replies < expected_packets
                or cycle_result.get("tunPacketProbeWrittenIncreased") is not True
                or cycle_result.get("tunPacketProbeBytesWrittenIncreased") is not True
            ):
                errors.append(
                    f"{prefix}.tunPacketProbeReplyPackets="
                    f"{replies!r}/{expected_packets!r}"
                )
            cycle_runtime_json = cycle_result.get("packetTunnelRuntimeStateJson")
            try:
                cycle_runtime = json.loads(cycle_runtime_json or "")
            except (json.JSONDecodeError, TypeError):
                errors.append(f"{prefix}.packetTunnelRuntimeStateJson=invalid")
            else:
                if cycle_runtime.get("vpnActive") is not True:
                    errors.append(
                        f"{prefix}.runtime.vpnActive="
                        f"{cycle_runtime.get('vpnActive')!r}"
                    )
if (
    expected_debug_dns_injected is not None
    and result.get("debugDnsInjected") is not expected_debug_dns_injected
):
    errors.append(
        "debugDnsInjected="
        f"{result.get('debugDnsInjected')!r} expected={expected_debug_dns_injected!r}"
    )
if expected_dns_mode:
    expected_dns = {
        "exitDnsMode": expected_dns_mode,
        "exitDnsDohProvider": expected_dns_provider,
        "exitDnsCustomDohUrl": expected_custom_url,
        "exitDnsCustomDohBootstrapIps": expected_bootstrap_ips,
        "exitDnsThroughExitServers": expected_through_servers,
    }
    for key, value in expected_dns.items():
        if result.get(key) != value:
            errors.append(f"{key}={result.get(key)!r} expected={value!r}")
if expected_exit_ip and not expected_resolve_host:
    errors.append("expectedExitIp requires expectedResolveHost")
if expected_resolve_host:
    if result.get("resolvedHost") != expected_resolve_host:
        errors.append(
            f"resolvedHost={result.get('resolvedHost')!r} "
            f"expected={expected_resolve_host!r}"
        )
    resolved = result.get("resolvedAddresses")
    if result.get("resolveError"):
        errors.append(f"resolveError={result['resolveError']}")
    if not isinstance(resolved, list) or not resolved:
        errors.append(f"resolvedAddresses={resolved!r}")
    elif expected_exit_ip and expected_exit_ip not in resolved:
        errors.append(
            f"resolvedAddresses={resolved!r} expected to contain {expected_exit_ip!r}"
        )
if expected_fetch_url:
    if result.get("url") != expected_fetch_url:
        errors.append(f"url={result.get('url')!r} expected={expected_fetch_url!r}")
    if result.get("fetchError"):
        errors.append(f"fetchError={result['fetchError']}")
    status = result.get("statusCode")
    if not isinstance(status, int) or not 200 <= status < 400:
        errors.append(f"statusCode={status!r}")
if verify_direct:
    for phase in ("directBefore", "directAfter"):
        if result.get(f"{phase}ResolveError"):
            errors.append(f"{phase}ResolveError={result[f'{phase}ResolveError']}")
        addresses = result.get(f"{phase}ResolvedAddresses")
        if not isinstance(addresses, list) or not addresses:
            errors.append(f"{phase}ResolvedAddresses={addresses!r}")
        if result.get(f"{phase}FetchError"):
            errors.append(f"{phase}FetchError={result[f'{phase}FetchError']}")
        status = result.get(f"{phase}StatusCode")
        if not isinstance(status, int) or not 200 <= status < 400:
            errors.append(f"{phase}StatusCode={status!r}")
        tunnel_status = result.get(f"{phase}PacketTunnelStatusRawValue")
        if tunnel_status not in (0, 1):
            errors.append(f"{phase}PacketTunnelStatusRawValue={tunnel_status!r}")
if switch_direct:
    if result.get("directWhileTunnelUiSelectionObserved") is not True:
        errors.append(
            "directWhileTunnelUiSelectionObserved="
            f"{result.get('directWhileTunnelUiSelectionObserved')!r}"
        )
    if result.get("directWhileTunnelPacketTunnelStatusRawValue") != 3:
        errors.append(
            "directWhileTunnelPacketTunnelStatusRawValue="
            f"{result.get('directWhileTunnelPacketTunnelStatusRawValue')!r}"
        )
    if result.get("directWhileTunnelVpnEnabled") is not True:
        errors.append(
            f"directWhileTunnelVpnEnabled={result.get('directWhileTunnelVpnEnabled')!r}"
        )
    if result.get("directWhileTunnelInternetSource") != "direct":
        errors.append(
            "directWhileTunnelInternetSource="
            f"{result.get('directWhileTunnelInternetSource')!r}"
        )
    if result.get("directWhileTunnelHasDefaultRoute") is not False:
        errors.append(
            "directWhileTunnelHasDefaultRoute="
            f"{result.get('directWhileTunnelHasDefaultRoute')!r}"
        )
    if result.get("directWhileTunnelHasWireGuardExit") is not False:
        errors.append(
            "directWhileTunnelHasWireGuardExit="
            f"{result.get('directWhileTunnelHasWireGuardExit')!r}"
        )
    if result.get("directWhileTunnelResolveError"):
        errors.append(
            f"directWhileTunnelResolveError={result['directWhileTunnelResolveError']}"
        )
    addresses = result.get("directWhileTunnelResolvedAddresses")
    if not isinstance(addresses, list) or not addresses:
        errors.append(f"directWhileTunnelResolvedAddresses={addresses!r}")
    if result.get("directWhileTunnelFetchError"):
        errors.append(f"directWhileTunnelFetchError={result['directWhileTunnelFetchError']}")
    status = result.get("directWhileTunnelStatusCode")
    if not isinstance(status, int) or not 200 <= status < 400:
        errors.append(f"directWhileTunnelStatusCode={status!r}")
runtime_json = result.get("packetTunnelRuntimeStateJson") or ""
if result.get("packetTunnelStatusRawValue") == 3:
    if not runtime_json:
        errors.append("packetTunnelRuntimeStateJson missing")
    else:
        try:
            runtime = json.loads(runtime_json)
        except json.JSONDecodeError as error:
            errors.append(f"packetTunnelRuntimeStateJson invalid JSON: {error}")
        else:
            if runtime.get("vpnActive") is not True:
                errors.append(f"runtime.vpnActive={runtime.get('vpnActive')!r}")
            for key in (
                "tunPacketsRead",
                "tunBytesRead",
                "tunPacketsWritten",
                "tunBytesWritten",
                "tunPacketsDropped",
            ):
                if key not in runtime:
                    errors.append(f"runtime.{key} missing")
            expected = result.get("tunPacketProbeExpectedPackets")
            sent = result.get("tunPacketProbeSentPackets")
            observed = result.get("tunPacketProbeObservedPackets")
            reply_packets = counter(result.get("tunPacketProbeReplyPackets"))
            missing_reply_packets = counter(
                result.get("tunPacketProbeMissingReplyPackets")
            )
            observed_bytes = counter(result.get("tunPacketProbeObservedBytesRead"))
            observed_written = counter(result.get("tunPacketProbeObservedWritten"))
            observed_bytes_written = counter(result.get("tunPacketProbeObservedBytesWritten"))
            dropped_delta = counter(result.get("tunPacketProbeDroppedDelta"))
            if (
                result.get("tunPacketProbeReadIncreased") is not True
                or result.get("tunPacketProbeBytesReadIncreased") is not True
                or result.get("tunPacketProbeDroppedIncreased") is not False
                or not isinstance(expected, int)
                or sent != expected
                or not isinstance(observed, int)
                or observed < expected
                or observed_bytes is None
                or observed_bytes <= 0
                or dropped_delta is None
                or dropped_delta != 0
            ):
                errors.append(
                    "tunPacketProbeReadIncreased="
                    f"{result.get('tunPacketProbeReadIncreased')!r} "
                    f"bytesIncreased={result.get('tunPacketProbeBytesReadIncreased')!r} "
                    f"droppedIncreased={result.get('tunPacketProbeDroppedIncreased')!r} "
                    f"baseline={result.get('tunPacketProbeBaselineRead')!r} "
                    f"final={result.get('tunPacketProbeFinalRead')!r} "
                    f"expected={expected!r} sent={sent!r} observed={observed!r} "
                    f"observedBytes={observed_bytes!r} droppedDelta={dropped_delta!r} "
                    f"error={result.get('tunPacketProbeError')!r} "
                    f"replyError={result.get('tunPacketProbeReplyError')!r}"
                )
            if require_reply and (
                not isinstance(expected, int)
                or reply_packets is None
                or reply_packets < expected
                or missing_reply_packets != 0
                or result.get("tunPacketProbeWrittenIncreased") is not True
                or result.get("tunPacketProbeBytesWrittenIncreased") is not True
                or observed_written is None
                or observed_written <= 0
                or observed_bytes_written is None
                or observed_bytes_written <= 0
                or dropped_delta != 0
            ):
                errors.append(
                    f"tunPacketProbeReplyPackets={reply_packets!r}/{expected!r} "
                    f"missingReplies={missing_reply_packets!r} "
                    "writtenIncreased="
                    f"{result.get('tunPacketProbeWrittenIncreased')!r} "
                    f"bytesWrittenIncreased={result.get('tunPacketProbeBytesWrittenIncreased')!r} "
                    f"baselineWritten={result.get('tunPacketProbeBaselineWritten')!r} "
                    f"finalWritten={result.get('tunPacketProbeFinalWritten')!r} "
                    f"observedWritten={observed_written!r} "
                    f"observedBytesWritten={observed_bytes_written!r} "
                    f"droppedDelta={dropped_delta!r} "
                    f"replyError={result.get('tunPacketProbeReplyError')!r}"
                )

if errors:
    summary_written = write_probe_summary(errors)
    if result.get("tunPacketProbeBaselineRead") is not None:
        print(probe_summary(), file=sys.stderr)
    print("iOS TUN packet probe summary: " + summary_written, file=sys.stderr)
    print("iOS VPN probe failed: " + ", ".join(errors), file=sys.stderr)
    sys.exit(1)

if result.get("tunPacketProbeReadIncreased") is True:
    print("iOS TUN packet probe passed")
    print(probe_summary())
    print("iOS TUN packet probe summary: " + write_probe_summary())
