#!/usr/bin/env python3
"""Reject release receipts that never exercised a connected minute."""

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location(
    "evidence", Path(__file__).with_name("release-network-evidence.py")
)
evidence = importlib.util.module_from_spec(spec)
spec.loader.exec_module(evidence)


def markers(begin=1000, end=62000, samples=range(2000, 62001, 5000)):
    return ([f"NVPN_IOS_RELEASE_CONNECTED_USE_BEGIN_MS={begin}"]
            + [f"NVPN_IOS_RELEASE_CONNECTED_USE_SAMPLE_MS={value}" for value in samples]
            + [f"NVPN_IOS_RELEASE_CONNECTED_USE_END_MS={end}"])


class ConnectedUseEvidenceTests(unittest.TestCase):
    def test_dns_only_does_not_claim_lifecycle_minute(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            stem = "mobile-ios-release-network-automatic-profile-1"
            (root / f"{stem}-processes.json").write_text(json.dumps({
                "passed": True,
                "activeSessionBeginSeen": True,
                "activeSessionEndSeen": True,
                "appProcessIdentifiers": [1],
                "packetTunnelProcessIdentifiers": [2],
                "requiredCheckpoints": ["connected"],
                "observedCheckpoints": ["connected"],
            }))
            rows = [
                "NVPN_IOS_RELEASE_DNS_UI_PERSISTED=automatic-profile",
                "NVPN_IOS_RELEASE_EXIT_CONNECTED=automatic-profile",
                "NVPN_IOS_RELEASE_DIRECT_BEFORE_PASSED=1",
                "NVPN_IOS_RELEASE_DIRECT_AFTER_PASSED=1",
                "NVPN_IOS_RELEASE_NETWORK_PASSED=automatic-profile",
                "NVPN_IOS_RELEASE_START_STOP_RECOVERED=1",
            ]
            for cycle in range(1, 9):
                rows.extend([
                    f"NVPN_IOS_RELEASE_RAPID_STOP_REQUESTED_{cycle}_MS=1000",
                    f"NVPN_IOS_RELEASE_RAPID_STOPPED_{cycle}_MS=1100",
                ])
            (root / f"{stem}-runner-markers.log").write_text("\n".join(rows))
            summary, _ = evidence.validate_ios_support(
                root, ["automatic-profile"], "wireguard-dns"
            )
            self.assertNotIn("connectedUse", summary["automatic-profile"])
            self.assertEqual(summary["rapidStartStopCycles"], 8)
            with self.assertRaisesRegex(ValueError, "connected-use minute"):
                evidence.validate_ios_support(
                    root, ["automatic-profile"], "underlay-lifecycle"
                )

    def test_full_minute(self):
        self.assertEqual(evidence.validate_ios_connected_use(markers()),
                         {"durationMs": 61000, "sampleCount": 13})

    def test_rejects_absent_short_sparse_or_duplicate_evidence(self):
        for value in (
            [], markers(end=57000, samples=range(2000, 57001, 5000)),
            markers(samples=[2000, 62000]),
            markers(samples=[2000, 7000, 12000, 17000, 22000, 27000, 62000]),
            markers(end=90000), markers() + markers(),
            markers(samples=reversed(range(2000, 62001, 5000))),
            markers(begin="nan"),
        ):
            with self.subTest(value=value), self.assertRaises(ValueError):
                evidence.validate_ios_connected_use(value)


if __name__ == "__main__":
    unittest.main()
