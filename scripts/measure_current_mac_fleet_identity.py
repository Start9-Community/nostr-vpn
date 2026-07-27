#!/usr/bin/env python3
"""Write a private, measured current-Mac identity receipt for fleet exclusion."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import re
import subprocess
import time


def private_output(root: pathlib.Path, output: pathlib.Path) -> pathlib.Path:
    resolved_root = root.resolve()
    resolved = output.resolve()
    try:
        relative = resolved.relative_to(resolved_root)
    except ValueError:
        return resolved
    ignored = subprocess.run(
        [
            "git",
            "-C",
            str(resolved_root),
            "check-ignore",
            "-q",
            "--no-index",
            "--",
            str(relative),
        ],
        check=False,
    )
    if ignored.returncode != 0:
        raise SystemExit(
            "current-Mac receipt must be outside the checkout or ignored as private"
        )
    return resolved


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=pathlib.Path, default=pathlib.Path.cwd())
    parser.add_argument("--output", required=True, type=pathlib.Path)
    arguments = parser.parse_args()
    output = private_output(arguments.root, arguments.output)
    if output.exists():
        raise SystemExit(f"refusing to replace existing receipt: {output}")
    measured = subprocess.run(
        ["ioreg", "-rd1", "-c", "IOPlatformExpertDevice"],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
    ).stdout
    match = re.search(r'"IOPlatformUUID"\s*=\s*"([^"]+)"', measured)
    if match is None:
        raise SystemExit("could not measure IOPlatformUUID")
    identity = hashlib.sha256(match.group(1).encode("utf-8")).hexdigest()
    output.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    output.parent.chmod(0o700)
    output.write_text(
        json.dumps(
            {
                "schema": 1,
                "kind": "nvpn-current-mac-measurement-v1",
                "source": "ioreg-IOPlatformUUID-sha256",
                "measuredAt": int(time.time()),
                "machineIdentitySha256": identity,
            },
            indent=2,
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )
    output.chmod(0o600)
    print(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
