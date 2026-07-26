#!/usr/bin/env python3
"""Validate continuous server-to-mobile WireGuard payload across two underlay changes."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path


def parse_ping_replies(path: Path) -> list[tuple[int, int]]:
    replies: list[tuple[int, int]] = []
    pattern = re.compile(
        r"^\[(?P<seconds>\d+)(?:\.(?P<fraction>\d+))?\].*"
        r"bytes from .*icmp_seq[= ](?P<sequence>\d+)"
    )
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        match = pattern.search(line)
        if not match:
            continue
        fraction = (match.group("fraction") or "")[:3].ljust(3, "0")
        timestamp_ms = int(match.group("seconds")) * 1_000 + int(fraction or "0")
        replies.append((timestamp_ms, int(match.group("sequence"))))
    return replies


def parse_markers(path: Path) -> tuple[dict[str, int], dict[str, int]]:
    markers: dict[str, int] = {}
    counts: dict[str, int] = {}
    ios_pattern = re.compile(
        r"^NVPN_IOS_UNDERLAY_SWITCH_(?P<cycle>[12])_"
        r"(?P<phase>REQUESTED|AVAILABLE|PAYLOAD_RECOVERY|VERIFIED)_MS="
        r"(?P<value>\d+)$"
    )
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        match = ios_pattern.match(line)
        if match:
            key = f"switch_{match.group('cycle')}_{match.group('phase').lower()}"
            counts[key] = counts.get(key, 0) + 1
            markers[key] = int(match.group("value"))
            continue
        fields = line.split("\t")
        if len(fields) == 2 and fields[0] in {
            "switch_1_requested",
            "switch_1_available",
            "switch_1_payload_recovery",
            "switch_1_verified",
            "switch_2_requested",
            "switch_2_available",
            "switch_2_payload_recovery",
            "switch_2_verified",
        }:
            try:
                counts[fields[0]] = counts.get(fields[0], 0) + 1
                markers[fields[0]] = int(fields[1])
            except ValueError:
                pass
    return markers, counts


def main() -> int:
    if len(sys.argv) != 6:
        raise SystemExit(
            "usage: validate-mobile-underlay-continuity.py "
            "PING_LOG MARKERS SUMMARY PLATFORM MAX_RECOVERY_MS"
        )
    ping_path = Path(sys.argv[1])
    marker_path = Path(sys.argv[2])
    summary_path = Path(sys.argv[3])
    platform = sys.argv[4]
    max_recovery_ms = int(sys.argv[5])
    if not 1 <= max_recovery_ms <= 10_000:
        raise SystemExit("maximum recovery must be 1-10000ms")

    replies = parse_ping_replies(ping_path)
    markers, marker_counts = parse_markers(marker_path)
    errors: list[str] = []
    required_markers = [
        "switch_1_requested",
        "switch_1_available",
        "switch_1_payload_recovery",
        "switch_1_verified",
        "switch_2_requested",
        "switch_2_available",
        "switch_2_payload_recovery",
        "switch_2_verified",
    ]
    for name in required_markers:
        if name not in markers:
            errors.append(f"missing marker {name}")
        elif marker_counts.get(name) != 1:
            errors.append(
                f"marker {name} occurred {marker_counts.get(name, 0)} times"
            )
    sequences = [sequence for _, sequence in replies]
    if len(replies) < 6:
        errors.append(f"only {len(replies)} successful bidirectional payloads")
    if any(current <= previous for previous, current in zip(sequences, sequences[1:])):
        errors.append("successful ICMP sequence numbers are not strictly increasing")

    cycles: list[dict[str, int | bool]] = []
    if not errors:
        previous_available = 0
        for cycle in (1, 2):
            requested = markers[f"switch_{cycle}_requested"]
            available = markers[f"switch_{cycle}_available"]
            recovery_ms = markers[f"switch_{cycle}_payload_recovery"]
            verified = markers[f"switch_{cycle}_verified"]
            if requested > available or available > verified:
                errors.append(
                    f"switch {cycle} markers are not request <= available <= verified"
                )
                continue
            if requested < previous_available:
                errors.append(f"switch {cycle} markers overlap the previous switch")
                continue
            previous_available = verified
            before = [
                timestamp
                for timestamp, _ in replies
                if requested - 5_000 <= timestamp <= requested
            ]
            after = [
                timestamp
                for timestamp, _ in replies
                if available <= timestamp <= verified
            ]
            if not before:
                errors.append(
                    f"switch {cycle} had no successful payload in the five seconds before it"
                )
                continue
            if not after:
                errors.append(f"switch {cycle} had no successful payload after availability")
                continue
            if recovery_ms < 0:
                errors.append(f"switch {cycle} payload recovery was negative")
                continue
            if recovery_ms > max_recovery_ms:
                errors.append(
                    f"switch {cycle} payload recovery was {recovery_ms}ms "
                    f"(limit {max_recovery_ms}ms)"
                )
            recovered = available + recovery_ms
            post_recovery_gaps = [
                current - previous
                for previous, current in zip(after, after[1:])
            ]
            if post_recovery_gaps and max(post_recovery_gaps) > max_recovery_ms:
                errors.append(
                    f"switch {cycle} payload gap after recovery was "
                    f"{max(post_recovery_gaps)}ms (limit {max_recovery_ms}ms)"
                )
            verified_tail_ms = verified - after[-1]
            if verified_tail_ms > max_recovery_ms:
                errors.append(
                    f"switch {cycle} had no payload for {verified_tail_ms}ms "
                    f"before verification (limit {max_recovery_ms}ms)"
                )
            cycles.append(
                {
                    "associationMilliseconds": available - requested,
                    "payloadBeforeSwitch": True,
                    "payloadRecoveryEvidence": (
                        "same-clock-unique-udp-echo-completion"
                    ),
                    "reversePayloadAfterAvailability": True,
                    "recoveredAtMilliseconds": recovered,
                    "recoveryMilliseconds": recovery_ms,
                    "requestedAtMilliseconds": requested,
                    "underlayAvailableAtMilliseconds": available,
                    "verifiedAtMilliseconds": verified,
                }
            )

    summary = {
        "bidirectionalPayload": "wireguard-server-icmp-request-and-mobile-reply",
        "cycles": cycles,
        "maxRecoveryMilliseconds": max_recovery_ms,
        "passed": not errors,
        "platform": platform,
        "successfulPayloads": len(replies),
    }
    if errors:
        summary["errors"] = errors
    summary_path.parent.mkdir(parents=True, exist_ok=True)
    summary_path.write_text(
        json.dumps(summary, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    if errors:
        raise SystemExit(f"{platform} underlay continuity failed: " + "; ".join(errors))
    print(
        f"{platform} underlay continuity passed: "
        + ", ".join(
            f"switch {index} recovery={cycle['recoveryMilliseconds']}ms "
            f"association={cycle['associationMilliseconds']}ms"
            for index, cycle in enumerate(cycles, start=1)
        )
        + f"; receipt={summary_path}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
