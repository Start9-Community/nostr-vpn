#!/usr/bin/env python3
"""Serve one fixture-unique HTTP receipt on the WireGuard tunnel address."""

from __future__ import annotations

import http.server
import os
import sys
from pathlib import Path


class Handler(http.server.BaseHTTPRequestHandler):
    token = ""

    def do_GET(self) -> None:  # noqa: N802 - required by BaseHTTPRequestHandler
        expected_path = f"/{self.token}"
        if self.path != expected_path:
            self.send_error(404)
            return
        body = f"{self.token}\n".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *args: object) -> None:
        print(format % args, flush=True)


def main() -> int:
    if len(sys.argv) != 5:
        raise SystemExit(
            "usage: mobile-wireguard-http-probe.py HOST PORT PID_FILE TOKEN"
        )
    host, port_raw, pid_path_raw, token = sys.argv[1:]
    if not token or any(character not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_" for character in token):
        raise SystemExit("HTTP probe token must be non-empty ASCII alphanumeric")
    Handler.token = token
    server = http.server.ThreadingHTTPServer((host, int(port_raw)), Handler)
    Path(pid_path_raw).write_text(f"{os.getpid()}\n", encoding="ascii")
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
