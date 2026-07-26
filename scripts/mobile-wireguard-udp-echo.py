#!/usr/bin/env python3
"""Small UDP echo used only by the remote physical-mobile WireGuard fixture."""

import os
import socket
import sys


def main() -> int:
    if len(sys.argv) != 4:
        raise SystemExit("usage: mobile-wireguard-udp-echo.py IP PORT PID_FILE")
    host, port_raw, pid_file = sys.argv[1:]
    port = int(port_raw)
    with open(pid_file, "w", encoding="utf-8") as handle:
        handle.write(f"{os.getpid()}\n")
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as server:
        server.bind((host, port))
        while True:
            payload, address = server.recvfrom(65_535)
            server.sendto(payload, address)


if __name__ == "__main__":
    raise SystemExit(main())
