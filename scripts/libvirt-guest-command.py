#!/usr/bin/env python3
"""Run bounded Linux gate commands outside the guest's protected data network."""

import argparse
import base64
import json
import shlex
import subprocess
import sys
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hypervisor", required=True)
    parser.add_argument("--vm", required=True)
    parser.add_argument("--timeout", type=float, default=30)
    parser.add_argument("--stdin", action="store_true")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command or not 0 < args.timeout <= 600:
        parser.error("provide a command and a timeout in (0, 600] seconds")
    deadline = time.monotonic() + args.timeout + 10

    def request(name, arguments):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("guest command observation deadline expired")
        payload = json.dumps({"execute": name, "arguments": arguments})
        result = subprocess.run(
            ["ssh", "-o", "BatchMode=yes", "-o", "ConnectionAttempts=1",
             "-o", "ConnectTimeout=5", "-o", "ControlMaster=no",
             "-o", "ControlPersist=no", "-o", "ControlPath=none",
             "-o", "ServerAliveInterval=2", "-o", "ServerAliveCountMax=2",
             args.hypervisor,
             shlex.join(["virsh", "qemu-agent-command", args.vm, payload])],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, timeout=min(10, remaining), check=True,
        )
        response = json.loads(result.stdout)
        if "error" in response:
            raise RuntimeError(response["error"].get("desc", "guest agent error"))
        return response["return"]

    arguments = {
        "path": "/usr/bin/timeout",
        "arg": ["--signal=TERM", "--kill-after=2", str(args.timeout), *command],
        "capture-output": True,
    }
    if args.stdin:
        arguments["input-data"] = base64.b64encode(sys.stdin.buffer.read()).decode()
    pid = request("guest-exec", arguments)["pid"]
    # Submit once. A lost observation must never execute the command twice.
    while True:
        try:
            status = request("guest-exec-status", {"pid": pid})
        except (subprocess.SubprocessError, TimeoutError) as error:
            raise RuntimeError(f"guest PID {pid} observation failed; command remains bounded") from error
        if status.get("exited"):
            if status.get("out-truncated") or status.get("err-truncated"):
                raise RuntimeError(f"guest PID {pid} output was truncated")
            for key, stream in [("out-data", sys.stdout.buffer), ("err-data", sys.stderr.buffer)]:
                stream.write(base64.b64decode(status.get(key, ""), validate=True))
                stream.flush()
            return status.get("exitcode", 128 + status.get("signal", 0))
        time.sleep(0.1)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"Linux VM management command failed: {error}", file=sys.stderr)
        sys.exit(125)
