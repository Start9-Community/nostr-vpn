#!/usr/bin/env python3
"""Capture xcodebuild output and independently sample iOS Release processes."""

from __future__ import annotations

import concurrent.futures
import json
import re
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path


MARKER = re.compile(
    r"NVPN_IOS_UNDERLAY_SWITCH_(?P<cycle>[12])_"
    r"(?P<phase>REQUESTED|AVAILABLE|PAYLOAD_RECOVERY|VERIFIED)_MS="
    r"(?P<value>\d+)"
)
ACTIVE = re.compile(
    r"NVPN_IOS_RELEASE_ACTIVE_SESSION_(?P<phase>BEGIN|END)_MS=\d+"
)
CHECKPOINT = re.compile(
    r"NVPN_IOS_(?P<name>"
    r"UNDERLAY_SWITCH_[12]_(?:REQUESTED|AVAILABLE|PAYLOAD_RECOVERY|VERIFIED)"
    r"|RELEASE_BACKGROUND_\d+_REQUESTED"
    r"|RELEASE_FOREGROUND_\d+_VERIFIED"
    r"|RELEASE_CONNECTED_DIRECT_PASSED"
    r")"
)


def process_ids(payload: object) -> tuple[list[int], list[int]]:
    app: set[int] = set()
    tunnel: set[int] = set()

    def visit(value: object) -> None:
        if isinstance(value, dict):
            executable = str(value.get("executable", ""))
            process_id = value.get("processIdentifier")
            if isinstance(process_id, int):
                normalized = executable.replace("%20", " ")
                if normalized.endswith(
                    "/Nostr VPN.app/PlugIns/Nostr VPN Tunnel.appex/"
                    "Nostr VPN Tunnel"
                ):
                    tunnel.add(process_id)
                elif normalized.endswith("/Nostr VPN.app/Nostr VPN"):
                    app.add(process_id)
            for child in value.values():
                visit(child)
        elif isinstance(value, list):
            for child in value:
                visit(child)

    visit(payload)
    return sorted(app), sorted(tunnel)


class ProcessSampler:
    def __init__(self, device: str, summary_path: Path) -> None:
        self.device = device
        self.summary_path = summary_path
        self.active = threading.Event()
        self.stopped = threading.Event()
        self.lock = threading.Lock()
        self.samples_lock = threading.Lock()
        self.checkpoint = "active-session-begin"
        self.required_checkpoints: set[str] = set()
        self.checkpoint_executor = concurrent.futures.ThreadPoolExecutor(
            max_workers=4,
            thread_name_prefix="ios-process-checkpoint",
        )
        self.checkpoint_futures: list[
            concurrent.futures.Future[bool]
        ] = []
        self.begin_seen = False
        self.end_seen = False
        self.samples: list[dict[str, object]] = []
        self.thread = threading.Thread(target=self._run, daemon=True)

    def start(self) -> None:
        self.thread.start()

    def begin(self) -> None:
        self.begin_seen = True
        self.update_checkpoint("active-session-begin")
        self.active.set()

    def update_checkpoint(self, checkpoint: str) -> None:
        normalized = checkpoint.lower()
        should_sample = False
        with self.lock:
            self.checkpoint = normalized
            if normalized not in self.required_checkpoints:
                self.required_checkpoints.add(normalized)
                should_sample = True
        if should_sample:
            future = self.checkpoint_executor.submit(
                self._sample, normalized
            )
            with self.lock:
                self.checkpoint_futures.append(future)

    def stop(self) -> None:
        with self.lock:
            self.end_seen = True
        self.update_checkpoint("active-session-end")
        self.stopped.set()

    def finish(self) -> int:
        self.active.set()
        self.stopped.set()
        self.thread.join(timeout=7)
        errors: list[str] = []
        with self.lock:
            checkpoint_futures = list(self.checkpoint_futures)
        done, pending = concurrent.futures.wait(
            checkpoint_futures,
            timeout=12,
        )
        if pending:
            errors.append(
                f"{len(pending)} checkpoint process observations did not finish"
            )
        for future in done:
            try:
                future.result()
            except Exception as error:  # pragma: no cover - defensive boundary
                errors.append(
                    "checkpoint process observation raised "
                    f"{type(error).__name__}"
                )
        self.checkpoint_executor.shutdown(
            wait=False,
            cancel_futures=True,
        )
        if self.thread.is_alive():
            errors.append("process sampler did not stop")
        if not self.begin_seen:
            errors.append("active-session begin marker was missing")
        if not self.end_seen:
            errors.append("active-session end marker was missing")
        with self.samples_lock:
            samples = list(self.samples)
        if len(samples) < 2:
            errors.append(
                f"only {len(samples)} active-session process observations"
            )
        app_pids: set[int] = set()
        tunnel_pids: set[int] = set()
        valid_checkpoints: set[str] = set()
        for index, sample in enumerate(samples, start=1):
            if sample.get("error"):
                errors.append(
                    f"process observation {index}: {sample['error']}"
                )
                continue
            app = sample.get("appPids")
            tunnel = sample.get("packetTunnelPids")
            if not isinstance(app, list) or len(app) != 1:
                errors.append(
                    f"process observation {index} appPids={app!r}"
                )
            else:
                app_pids.add(int(app[0]))
            if not isinstance(tunnel, list) or len(tunnel) != 1:
                errors.append(
                    f"process observation {index} packetTunnelPids={tunnel!r}"
                )
            else:
                tunnel_pids.add(int(tunnel[0]))
            if (
                isinstance(app, list)
                and len(app) == 1
                and isinstance(tunnel, list)
                and len(tunnel) == 1
            ):
                valid_checkpoints.add(str(sample.get("checkpoint", "")))
        if len(app_pids) != 1:
            errors.append(f"distinct app PIDs={sorted(app_pids)}")
        if len(tunnel_pids) != 1:
            errors.append(
                f"distinct packet-tunnel PIDs={sorted(tunnel_pids)}"
            )
        with self.lock:
            required_checkpoints = set(self.required_checkpoints)
        missing_checkpoints = sorted(required_checkpoints - valid_checkpoints)
        if missing_checkpoints:
            errors.append(
                "checkpoints without a valid process observation="
                f"{missing_checkpoints}"
            )
        summary = {
            "activeSessionBeginSeen": self.begin_seen,
            "activeSessionEndSeen": self.end_seen,
            "appProcessIdentifiers": sorted(app_pids),
            "observedCheckpoints": sorted(valid_checkpoints),
            "packetTunnelProcessIdentifiers": sorted(tunnel_pids),
            "passed": not errors,
            "requiredCheckpoints": sorted(required_checkpoints),
            "sampleCount": len(samples),
            "samples": samples,
        }
        if errors:
            summary["errors"] = errors
        self.summary_path.parent.mkdir(parents=True, exist_ok=True)
        self.summary_path.write_text(
            json.dumps(summary, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        if errors:
            print(
                "iOS Release process continuity failed: " + "; ".join(errors),
                file=sys.stderr,
            )
            return 1
        return 0

    def _run(self) -> None:
        self.active.wait()
        while not self.stopped.is_set():
            with self.lock:
                checkpoint = self.checkpoint
            self._sample(checkpoint)
            self.stopped.wait(0.25)

    def _sample(self, checkpoint: str) -> bool:
        timestamp_ms = time.time_ns() // 1_000_000
        sample: dict[str, object] = {
            "checkpoint": checkpoint,
            "observedAtMilliseconds": timestamp_ms,
        }
        with tempfile.NamedTemporaryFile(suffix=".json") as output:
            try:
                completed = subprocess.run(
                    [
                        "xcrun",
                        "devicectl",
                        "device",
                        "info",
                        "processes",
                        "--device",
                        self.device,
                        "--json-output",
                        output.name,
                        "--quiet",
                    ],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.PIPE,
                    text=True,
                    timeout=5,
                    check=False,
                )
                if completed.returncode != 0:
                    sample["error"] = (
                        "devicectl process query failed "
                        f"with status {completed.returncode}"
                    )
                else:
                    payload = json.loads(Path(output.name).read_text())
                    app, tunnel = process_ids(payload)
                    sample["appPids"] = app
                    sample["packetTunnelPids"] = tunnel
            except (OSError, subprocess.TimeoutExpired, json.JSONDecodeError) as error:
                sample["error"] = type(error).__name__
        with self.samples_lock:
            self.samples.append(sample)
        return (
            not sample.get("error")
            and isinstance(sample.get("appPids"), list)
            and len(sample["appPids"]) == 1
            and isinstance(sample.get("packetTunnelPids"), list)
            and len(sample["packetTunnelPids"]) == 1
        )


def main() -> int:
    if len(sys.argv) not in (3, 5):
        raise SystemExit(
            "usage: capture-mobile-ios-underlay-output.py "
            "XCODE_LOG HOST_MARKERS [DEVICE PROCESS_SUMMARY]"
        )
    log_path = Path(sys.argv[1])
    marker_path = Path(sys.argv[2])
    log_path.parent.mkdir(parents=True, exist_ok=True)
    marker_path.parent.mkdir(parents=True, exist_ok=True)
    sampler = (
        ProcessSampler(sys.argv[3], Path(sys.argv[4]))
        if len(sys.argv) == 5
        else None
    )
    if sampler:
        sampler.start()
    seen: set[str] = set()
    with (
        log_path.open("w", encoding="utf-8", buffering=1) as log,
        marker_path.open("w", encoding="utf-8", buffering=1) as markers,
    ):
        for line in sys.stdin:
            received_ms = time.time_ns() // 1_000_000
            log.write(line)
            active_match = ACTIVE.search(line)
            if active_match and sampler:
                if active_match.group("phase") == "BEGIN":
                    sampler.begin()
                else:
                    sampler.stop()
            checkpoint_match = CHECKPOINT.search(line)
            if checkpoint_match and sampler:
                sampler.update_checkpoint(checkpoint_match.group("name"))
            match = MARKER.search(line)
            if not match:
                continue
            name = (
                f"switch_{match.group('cycle')}_"
                f"{match.group('phase').lower()}"
            )
            if name in seen:
                continue
            seen.add(name)
            value = (
                match.group("value")
                if match.group("phase") == "PAYLOAD_RECOVERY"
                else str(received_ms)
            )
            markers.write(f"{name}\t{value}\n")
    return sampler.finish() if sampler else 0


if __name__ == "__main__":
    raise SystemExit(main())
