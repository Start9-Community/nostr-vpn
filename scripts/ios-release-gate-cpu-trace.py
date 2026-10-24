#!/usr/bin/env python3
"""Analyze external CPU counters only; artifact/connectivity proof is separate."""
import argparse
import hashlib
import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


def require(condition, message):
    if not condition:
        raise ValueError(message)


def analyze(args):
    toc = ET.parse(args.toc).getroot()
    runs = toc.findall("run")
    require(len(runs) == 1, "Expected exactly one recording run")
    device = runs[0].find("info/target/device")
    require(device is not None, "Trace target device is missing")
    require(device.get("platform") == "iOS", "Trace is not from a physical iOS device")
    device_hash = hashlib.sha256(device.get("uuid", "").lower().encode()).hexdigest()
    require(device_hash == args.device_sha256, "Trace target device does not match")
    summary = runs[0].find("info/summary")
    require(summary is not None, "Recording summary is missing")
    require(summary.findtext("template-name") == "Activity Monitor", "Wrong trace template")
    require(summary.findtext("end-reason") == "Time limit reached", "Recording did not complete its time limit")

    root = ET.parse(args.xml).getroot()
    schemas = root.findall(".//schema")
    require(len(schemas) == 1 and schemas[0].get("name") == "sysmon-process", "Expected one cumulative process CPU table")
    columns = [c.findtext("mnemonic") for c in schemas[0].findall("col")]
    require(len(columns) == len(set(columns)), "Duplicate table columns")
    required = {"time", "pid", "process", "recently-died", "cpu-total-system", "cpu-total-user"}
    require(required.issubset(columns), "Required process CPU columns are missing")
    ids = {}
    for element in root.iter():
        if "id" in element.attrib:
            key = element.attrib["id"]
            require(key not in ids, "Duplicate trace reference ID")
            ids[key] = element

    def resolve(element):
        seen = set()
        while "ref" in element.attrib:
            key = element.attrib["ref"]
            require(key not in seen and key in ids, "Invalid trace reference")
            seen.add(key)
            element = ids[key]
        return element

    samples = []
    process_ids = set()
    for row in root.findall(".//row"):
        require(len(row) == len(columns), "Malformed CPU table row")
        values = {key: resolve(value) for key, value in zip(columns, row)}
        if values["pid"].tag == "sentinel" or int(values["pid"].text) != args.pid:
            continue
        process = values["process"]
        require(process.get("fmt") == f"{args.process_name} ({args.pid})", "PID belongs to a different process")
        process_ids.add(process.get("id"))
        require(values["recently-died"].text == "0", "Target process exited during the recording")
        if any(values[key].tag == "sentinel" for key in ("time", "cpu-total-system", "cpu-total-user")):
            continue
        samples.append((int(values["time"].text), int(values["cpu-total-system"].text) + int(values["cpu-total-user"].text)))
    require(len(process_ids) == 1 and None not in process_ids, "Target process identity changed or was absent")
    require(len(samples) >= 2, "Not enough cumulative CPU samples")
    require(all(b[0] > a[0] and b[1] >= a[1] for a, b in zip(samples, samples[1:])), "Sample time or cumulative CPU moved backwards")

    # Fixed policy: first complete sample, then all samples through 120 seconds.
    # Never choose a later, quieter subwindow based on its CPU result.
    samples = [sample for sample in samples if sample[0] <= samples[0][0] + 120_000_000_000]
    elapsed = (samples[-1][0] - samples[0][0]) / 1e9
    require(60 <= elapsed <= 120, f"Sample interval {elapsed:.3f}s is outside 60–120 seconds")
    max_gap = max((b[0] - a[0]) / 1e9 for a, b in zip(samples, samples[1:]))
    require(max_gap <= 5, f"CPU sampling has an unexplained {max_gap:.3f}s gap")
    cpu = (samples[-1][1] - samples[0][1]) / 1e9
    return {
        "measurementValid": True,
        "cpuThresholdMet": cpu * 100 / elapsed <= 2,
        "maxPercent": 2,
        "cpuPercent": cpu * 100 / elapsed,
        "cpuSeconds": cpu,
        "elapsedSeconds": elapsed,
        "sampleCount": len(samples),
        "maxSampleGapSeconds": max_gap,
        "firstSampleTimeNs": samples[0][0],
        "lastSampleTimeNs": samples[-1][0],
        "traceStartedAt": summary.findtext("start-date"),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--xml", type=Path, required=True)
    parser.add_argument("--toc", type=Path, required=True)
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--process-name", default="Nostr VPN Tunnel")
    parser.add_argument("--device-sha256", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    require(not args.output.exists(), "Refusing to overwrite an existing measurement")
    require(args.pid > 0 and re.fullmatch("[0-9a-f]{64}", args.device_sha256), "Invalid target identity")
    result = {
        "scope": "External CPU measurement only",
        "releaseAcceptanceProven": False,
        "artifactAndPublicMeshProofRequiredSeparately": True,
        "pid": args.pid,
        "processName": args.process_name,
        "deviceSha256": args.device_sha256,
        "xmlSha256": hashlib.sha256(args.xml.read_bytes()).hexdigest(),
        "tocSha256": hashlib.sha256(args.toc.read_bytes()).hexdigest(),
    }
    try:
        result.update(analyze(args))
    except (ValueError, KeyError, TypeError, ET.ParseError) as error:
        result.update(measurementValid=False, cpuThresholdMet=None, error=str(error))
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({key: result[key] for key in ("measurementValid", "cpuThresholdMet")}))
    return 2 if not result["measurementValid"] else (0 if result["cpuThresholdMet"] else 1)


if __name__ == "__main__":
    sys.exit(main())
