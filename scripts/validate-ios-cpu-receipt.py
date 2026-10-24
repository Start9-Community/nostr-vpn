#!/usr/bin/env python3
"""Validate cumulative CPU and connected-overlay evidence from a real iPhone."""

import json
import math
import sys


def finite_number(value):
    return type(value) in (int, float) and math.isfinite(value)


def validate(result, process, label, maximum, duration, git_sha, connected):
    errors = []
    for key, expected in (("phase", "finished"), ("ok", True),
                          ("process", process), ("label", label),
                          ("appBuildGitSha", git_sha)):
        if result.get(key) != expected:
            errors.append(f"{key}={result.get(key)!r}, expected {expected!r}")
    pid = result.get("pid")
    cpu = result.get("cpuPercent")
    elapsed = result.get("elapsedSeconds")
    cpu_seconds = result.get("cpuSeconds")
    if type(pid) is not int or pid <= 0:
        errors.append("missing process identity")
    if not finite_number(cpu) or not 0 <= cpu <= maximum:
        errors.append(f"cpuPercent={cpu!r}, maximum={maximum}")
    if not finite_number(elapsed) or elapsed < duration:
        errors.append(f"elapsedSeconds={elapsed!r}, required={duration}")
    if (not finite_number(cpu_seconds) or cpu_seconds < 0
            or not finite_number(elapsed) or elapsed <= 0
            or not finite_number(cpu)
            or not math.isclose(cpu_seconds * 100 / elapsed, cpu, abs_tol=0.001)):
        errors.append("invalid cumulative CPU measurement")
    if connected:
        samples = result.get("connectionSamples")
        previous = None
        if not isinstance(samples, list) or not samples:
            errors.append("connected-use samples missing")
            samples = []
        for sample in samples:
            if not isinstance(sample, dict):
                errors.append("invalid connection sample")
                continue
            at = sample.get("elapsedSeconds")
            if not finite_number(at) or at < 0:
                errors.append("invalid connection sample time")
                continue
            if ((previous is None and at > 2)
                    or (previous is not None and not 0 < at - previous <= 8)):
                errors.append("connected-use observation gap")
            previous = at
            if (sample.get("pid") != pid or sample.get("vpnActive") is not True
                    or type(sample.get("fipsPeerCount")) is not int
                    or sample["fipsPeerCount"] <= 0
                    or type(sample.get("connectedRelayCount")) is not int
                    or sample["connectedRelayCount"] <= 0):
                errors.append("VPN, FIPS peer, relay, or process continuity lost")
        if (previous is None or previous < duration
                or not finite_number(elapsed) or not 0 <= elapsed - previous <= 2):
            errors.append("connected overlay was not observed for the entire sample")
    return errors


if __name__ == "__main__":
    path, process, label, maximum, duration, sha, connected = sys.argv[1:]
    with open(path, encoding="utf-8") as handle:
        result = json.load(handle)
    errors = validate(result, process, label, float(maximum), float(duration),
                      sha, connected == "1")
    if errors:
        raise SystemExit("iOS CPU receipt failed: " + "; ".join(errors))
    print(f"{label} CPU ok: {result['cpuPercent']:.3f}% <= {float(maximum):.3f}%")
    print(f"Result: {path}")
