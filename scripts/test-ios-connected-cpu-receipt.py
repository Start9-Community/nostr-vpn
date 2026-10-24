#!/usr/bin/env python3
"""Exercise the same receipt validator used by the physical release gate."""

import copy
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location(
    "receipt", Path(__file__).with_name("validate-ios-cpu-receipt.py")
)
receipt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(receipt)


class ConnectedCpuReceiptTests(unittest.TestCase):
    def setUp(self):
        self.result = {
            "phase": "finished", "ok": True, "process": "packet-tunnel",
            "label": "iOS packet tunnel", "appBuildGitSha": "candidate",
            "pid": 123, "cpuPercent": 1, "elapsedSeconds": 60,
            "cpuSeconds": 0.6,
            "connectionSamples": [
                {"elapsedSeconds": second, "pid": 123, "vpnActive": True,
                 "fipsPeerCount": 2, "connectedRelayCount": 4}
                for second in range(0, 61, 5)
            ],
        }

    def validate(self, result):
        return receipt.validate(result, "packet-tunnel", "iOS packet tunnel",
                                2, 60, "candidate", True)

    def test_connected_minute(self):
        self.assertEqual(self.validate(self.result), [])

    def test_rejects_disconnected_busy_restarted_or_short_runs(self):
        mutations = [
            lambda r: r.update(elapsedSeconds=59),
            lambda r: r.update(cpuPercent=15, cpuSeconds=9),
            lambda r: r.update(cpuPercent=float("nan")),
            lambda r: r.update(elapsedSeconds=float("inf")),
            lambda r: r.update(cpuPercent=0.1),  # forged/inconsistent CPU delta
            lambda r: r.update(appBuildGitSha="old-build"),
            lambda r: r.pop("connectionSamples"),
            lambda r: r["connectionSamples"][6].update(vpnActive=False),
            lambda r: r["connectionSamples"][6].update(fipsPeerCount=0),
            lambda r: r["connectionSamples"][6].update(connectedRelayCount=0),
            lambda r: r["connectionSamples"][6].update(pid=124),
            lambda r: r["connectionSamples"].pop(6),
            lambda r: r["connectionSamples"].pop(),
            lambda r: r["connectionSamples"].reverse(),
        ]
        for mutate in mutations:
            with self.subTest(mutation=mutate):
                result = copy.deepcopy(self.result)
                mutate(result)
                self.assertTrue(self.validate(result), result)


if __name__ == "__main__":
    unittest.main()
