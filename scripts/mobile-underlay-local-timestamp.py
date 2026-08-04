#!/usr/bin/env python3
"""Run a continuity command and timestamp each received line on the local host."""

from __future__ import annotations

import os
import signal
import subprocess
import sys
import time
from pathlib import Path


class StopRequested(Exception):
    """Interrupt a blocking pipe read when the observer is stopped."""


def main() -> int:
    if len(sys.argv) < 4 or sys.argv[2] != "--":
        raise SystemExit(
            "usage: mobile-underlay-local-timestamp.py OUTPUT -- COMMAND [ARG ...]"
        )
    output = Path(sys.argv[1])
    command = sys.argv[3:]
    output.parent.mkdir(parents=True, exist_ok=True)
    child = subprocess.Popen(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
        start_new_session=True,
    )
    stopping = False

    def stop_child(_signum: int, _frame: object) -> None:
        nonlocal stopping
        stopping = True
        try:
            os.killpg(child.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        except PermissionError:
            try:
                child.terminate()
            except ProcessLookupError:
                pass
        raise StopRequested

    signal.signal(signal.SIGINT, stop_child)
    signal.signal(signal.SIGTERM, stop_child)

    assert child.stdout is not None
    with output.open("w", encoding="utf-8", buffering=1) as handle:
        try:
            for line in child.stdout:
                now_ms = time.time_ns() // 1_000_000
                seconds, milliseconds = divmod(now_ms, 1_000)
                handle.write(f"[{seconds}.{milliseconds:03d}] {line}")
        except StopRequested:
            pass

    try:
        status = child.wait(timeout=3 if stopping else None)
    except subprocess.TimeoutExpired:
        child.kill()
        status = child.wait()
    if stopping:
        return 0
    return status


if __name__ == "__main__":
    raise SystemExit(main())
