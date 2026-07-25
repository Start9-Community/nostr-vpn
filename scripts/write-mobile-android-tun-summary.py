#!/usr/bin/env python3
"""Write the normalized physical-Android TUN packet evidence summary."""

import json
import sys

(
    summary_path,
    target,
    ping_timeout_secs,
    baseline,
    current,
    required_increase,
    baseline_bytes,
    current_bytes,
    baseline_written,
    current_written,
    baseline_bytes_written,
    current_bytes_written,
    baseline_dropped,
    current_dropped,
    ping_path,
    ping_status,
    first_observed_ms,
    elapsed_ms,
    polls,
    poll_interval_ms,
    require_reply,
    runtime_state_path,
    ping_summary_path,
    vpn_link_stats_path,
    vpn_link_stats_summary_path,
    build_metadata_path,
) = sys.argv[1:]

def number(value):
    try:
        return int(value)
    except (TypeError, ValueError):
        return None

baseline = number(baseline)
current = number(current)
required_increase = number(required_increase)
baseline_bytes = number(baseline_bytes)
current_bytes = number(current_bytes)
baseline_written = number(baseline_written)
current_written = number(current_written)
baseline_bytes_written = number(baseline_bytes_written)
current_bytes_written = number(current_bytes_written)
baseline_dropped = number(baseline_dropped)
current_dropped = number(current_dropped)
ping_status = number(ping_status)
ping_timeout_secs = number(ping_timeout_secs)
first_observed_ms = number(first_observed_ms)
elapsed_ms = number(elapsed_ms)
polls = number(polls)
poll_interval_ms = number(poll_interval_ms)
require_reply = str(require_reply).strip().lower() in {"1", "true", "yes", "on"}

observed = None
if baseline is not None and current is not None:
    observed = max(current - baseline, 0)

missing = None
if required_increase is not None and observed is not None:
    missing = max(required_increase - observed, 0)

observed_pct = None
packet_loss_pct = None
if required_increase and required_increase > 0:
    if observed is not None:
        observed_pct = round(observed * 100.0 / required_increase, 3)
    if missing is not None:
        packet_loss_pct = round(missing * 100.0 / required_increase, 3)

bytes_delta = None
if baseline_bytes is not None and current_bytes is not None:
    bytes_delta = current_bytes - baseline_bytes

written_delta = None
if baseline_written is not None and current_written is not None:
    written_delta = current_written - baseline_written

bytes_written_delta = None
if baseline_bytes_written is not None and current_bytes_written is not None:
    bytes_written_delta = current_bytes_written - baseline_bytes_written

dropped_delta = None
if baseline_dropped is not None and current_dropped is not None:
    dropped_delta = current_dropped - baseline_dropped

ping_received = None
try:
    with open(ping_summary_path, encoding="utf-8") as fh:
        ping_summary = json.load(fh)
    value = ping_summary.get("received")
    if isinstance(value, int):
        ping_received = value
except (OSError, json.JSONDecodeError):
    pass

reply_observed = (
    (ping_received is None or ping_received > 0)
    and written_delta is not None
    and written_delta > 0
    and bytes_written_delta is not None
    and bytes_written_delta > 0
    and (dropped_delta is None or dropped_delta == 0)
)

summary = {
    "target": target,
    "pingTimeoutSecs": ping_timeout_secs,
    "pingExitStatus": ping_status,
    "pingReceived": ping_received,
    "expected": required_increase,
    "observed": observed,
    "missing": missing,
    "observedPct": observed_pct,
    "packetLossPct": packet_loss_pct,
    "baselineRead": baseline,
    "finalRead": current,
    "baselineBytesRead": baseline_bytes,
    "finalBytesRead": current_bytes,
    "observedBytesRead": bytes_delta,
    "baselineWritten": baseline_written,
    "finalWritten": current_written,
    "observedWritten": written_delta,
    "baselineBytesWritten": baseline_bytes_written,
    "finalBytesWritten": current_bytes_written,
    "observedBytesWritten": bytes_written_delta,
    "writtenIncreased": written_delta is not None and written_delta > 0,
    "bytesWrittenIncreased": bytes_written_delta is not None and bytes_written_delta > 0,
    "baselineDropped": baseline_dropped,
    "finalDropped": current_dropped,
    "droppedDelta": dropped_delta,
    "firstObservedMs": first_observed_ms,
    "elapsedMs": elapsed_ms,
    "polls": polls,
    "pollIntervalMs": poll_interval_ms,
    "readIncreased": observed is not None
    and required_increase is not None
    and observed >= required_increase,
    "bytesReadIncreased": bytes_delta is not None and bytes_delta > 0,
    "droppedIncreased": dropped_delta is not None and dropped_delta > 0,
    "replyRequired": require_reply,
    "replyObserved": reply_observed,
    "rawPingOutput": ping_path,
    "pingSummaryOutput": ping_summary_path,
    "vpnLinkStatsOutput": vpn_link_stats_path,
    "vpnLinkStatsSummaryOutput": vpn_link_stats_summary_path,
    "runtimeStateOutput": runtime_state_path,
    "buildMetadataOutput": build_metadata_path,
}
try:
    with open(build_metadata_path, encoding="utf-8") as fh:
        build_metadata = json.load(fh)
except (OSError, json.JSONDecodeError):
    build_metadata = {}
for key in (
    "appPackageName",
    "appVersionName",
    "appVersionCode",
    "appBuildGitSha",
    "appBuildTimestampUtc",
):
    if key in build_metadata:
        summary[key] = build_metadata[key]
with open(summary_path, "w", encoding="utf-8") as fh:
    json.dump(summary, fh, sort_keys=True, indent=2)
    fh.write("\n")
