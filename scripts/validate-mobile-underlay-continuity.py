#!/usr/bin/env python3
"""Validate WireGuard recovery across one physical Wi-Fi radio off/on cycle."""

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
        r"^NVPN_IOS_UNDERLAY_SWITCH_(?P<cycle>1)_"
        r"(?P<phase>REQUESTED|OUTAGE|RECOVERY_REQUESTED|"
        r"UNDERLAY_VALIDATED|PAYLOAD_RECOVERY|VERIFIED)_MS="
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
            "switch_1_outage",
            "switch_1_recovery_requested",
            "switch_1_underlay_validated",
            "switch_1_payload_recovery",
            "switch_1_verified",
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

    raw_replies = parse_ping_replies(ping_path)
    markers, marker_counts = parse_markers(marker_path)
    errors: list[str] = []
    required_markers = [
        "switch_1_requested",
        "switch_1_outage",
        "switch_1_recovery_requested",
        "switch_1_underlay_validated",
        "switch_1_payload_recovery",
        "switch_1_verified",
    ]
    for name in required_markers:
        if name not in markers:
            errors.append(f"missing marker {name}")
        elif marker_counts.get(name) != 1:
            errors.append(
                f"marker {name} occurred {marker_counts.get(name, 0)} times"
            )
    replies: list[tuple[int, int]] = []
    seen_sequences: set[int] = set()
    for reply in raw_replies:
        if reply[1] in seen_sequences:
            continue
        seen_sequences.add(reply[1])
        replies.append(reply)
    duplicate_payloads = len(raw_replies) - len(replies)
    if len(replies) < 6:
        errors.append(f"only {len(replies)} unique bidirectional payloads")

    cycles: list[dict[str, int | bool]] = []
    if not errors:
        for cycle in (1,):
            requested = markers[f"switch_{cycle}_requested"]
            outage = markers[f"switch_{cycle}_outage"]
            radio_on_requested = markers[f"switch_{cycle}_recovery_requested"]
            underlay_validated = markers[f"switch_{cycle}_underlay_validated"]
            recovery_ms = markers[f"switch_{cycle}_payload_recovery"]
            verified = markers[f"switch_{cycle}_verified"]
            if (
                requested > outage
                or outage >= radio_on_requested
                or radio_on_requested > underlay_validated
                or underlay_validated > verified
            ):
                errors.append(
                    f"switch {cycle} markers are not "
                    "request <= outage < radio-on-requested "
                    "<= underlay-validated <= verified"
                )
                continue
            before = [
                timestamp
                for timestamp, _ in replies
                if requested - 5_000 <= timestamp <= requested
            ]
            during_outage = [
                timestamp
                for timestamp, _ in replies
                if outage <= timestamp < radio_on_requested
            ]
            during_association = [
                timestamp
                for timestamp, _ in replies
                if radio_on_requested <= timestamp < underlay_validated
            ]
            after_validation = [
                timestamp
                for timestamp, _ in replies
                if underlay_validated <= timestamp <= verified
            ]
            if not before:
                errors.append(
                    f"switch {cycle} had no successful payload in the five seconds before it"
                )
                continue
            if during_outage:
                errors.append(
                    f"switch {cycle} had {len(during_outage)} reverse payloads "
                    "between outage and radio-on request"
                )
            if not after_validation:
                errors.append(
                    f"switch {cycle} had no successful payload after underlay validation"
                )
                continue
            association_ms = underlay_validated - radio_on_requested
            if recovery_ms < 0:
                errors.append(f"switch {cycle} payload recovery was negative")
                continue
            if recovery_ms > max_recovery_ms:
                errors.append(
                    f"switch {cycle} payload recovery was {recovery_ms}ms "
                    f"(limit {max_recovery_ms}ms)"
                )
            first_after_validation_ms = after_validation[0] - underlay_validated
            first_reverse_recovery_ms = (
                0 if during_association else first_after_validation_ms
            )
            if first_after_validation_ms > max_recovery_ms:
                errors.append(
                    f"switch {cycle} first reverse payload after validation was "
                    f"{first_after_validation_ms}ms "
                    f"(limit {max_recovery_ms}ms)"
                )
            post_recovery_gaps = [
                current - previous
                for previous, current in zip(after_validation, after_validation[1:])
            ]
            if (
                post_recovery_gaps
                and max(post_recovery_gaps) > max_recovery_ms
            ):
                errors.append(
                    f"switch {cycle} payload gap after recovery was "
                    f"{max(post_recovery_gaps)}ms "
                    f"(limit {max_recovery_ms}ms)"
                )
            verified_tail_ms = verified - after_validation[-1]
            if verified_tail_ms > max_recovery_ms:
                errors.append(
                    f"switch {cycle} had no payload for {verified_tail_ms}ms "
                    f"before verification (limit {max_recovery_ms}ms)"
                )
            cycles.append(
                {
                    "dnsAndWireGuardRecoveryMilliseconds": recovery_ms,
                    "firstReversePayloadRecoveryMilliseconds": (
                        first_reverse_recovery_ms
                    ),
                    "outageAtMilliseconds": outage,
                    "outageReversePayloads": len(during_outage),
                    "payloadBeforeSwitch": True,
                    "recoveryMilliseconds": recovery_ms,
                    "recoveryRequestedAtMilliseconds": radio_on_requested,
                    "reversePayloadAfterRecoveryRequest": True,
                    "reversePayloadRecoveredBeforeValidation": bool(
                        during_association
                    ),
                    "requestedAtMilliseconds": requested,
                    "underlayAssociationMilliseconds": association_ms,
                    "underlayValidatedAtMilliseconds": underlay_validated,
                    "verifiedAtMilliseconds": verified,
                }
            )

    summary = {
        "bidirectionalPayload": "wireguard-server-icmp-request-and-mobile-reply",
        "cycles": cycles,
        "duplicatePayloads": duplicate_payloads,
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
            f"switch {index} recovery={cycle['recoveryMilliseconds']}ms"
            for index, cycle in enumerate(cycles, start=1)
        )
        + f"; receipt={summary_path}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
