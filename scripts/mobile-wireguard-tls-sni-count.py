#!/usr/bin/env python3
"""Count complete TLS ClientHello SNI values in a tcpdump pcap."""

from __future__ import annotations

import pathlib
import struct
import sys


def packet_payload(packet: bytes, link_type: int) -> bytes:
    offsets = {1: 14, 12: 0, 101: 0, 113: 16, 276: 20}
    offset = offsets.get(link_type)
    if offset is None or len(packet) < offset + 20:
        return b""
    if link_type == 1 and packet[12:14] == b"\x81\x00":
        offset += 4
    ip = packet[offset:]
    if ip[0] >> 4 != 4 or ip[9] != 6:
        return b""
    tcp = ip[(ip[0] & 0x0F) * 4 :]
    if len(tcp) < 20:
        return b""
    return tcp[(tcp[12] >> 4) * 4 :]


def client_hello_snis(payload: bytes) -> list[str]:
    names: list[str] = []
    for start in range(max(0, len(payload) - 8)):
        if payload[start : start + 2] != b"\x16\x03":
            continue
        record_end = start + 5 + int.from_bytes(payload[start + 3 : start + 5], "big")
        if record_end > len(payload) or payload[start + 5] != 1:
            continue
        hello_end = start + 9 + int.from_bytes(payload[start + 6 : start + 9], "big")
        if hello_end > record_end:
            continue
        hello = payload[start + 9 : hello_end]
        if len(hello) < 35:
            continue
        cursor = 34 + 1 + hello[34]
        if cursor + 2 > len(hello):
            continue
        cursor += 2 + int.from_bytes(hello[cursor : cursor + 2], "big")
        if cursor >= len(hello):
            continue
        cursor += 1 + hello[cursor]
        if cursor + 2 > len(hello):
            continue
        extensions_end = cursor + 2 + int.from_bytes(hello[cursor : cursor + 2], "big")
        cursor += 2
        while cursor + 4 <= min(extensions_end, len(hello)):
            kind = int.from_bytes(hello[cursor : cursor + 2], "big")
            size = int.from_bytes(hello[cursor + 2 : cursor + 4], "big")
            value = hello[cursor + 4 : cursor + 4 + size]
            cursor += 4 + size
            if kind != 0 or len(value) < 5 or value[2] != 0:
                continue
            name_size = int.from_bytes(value[3:5], "big")
            if 5 + name_size <= len(value):
                names.append(value[5 : 5 + name_size].decode("ascii", "strict").lower())
    return names


def captured_snis(path: pathlib.Path) -> list[str]:
    data = path.read_bytes() if path.is_file() else b""
    if len(data) < 24:
        return []
    byte_order = {
        b"\xd4\xc3\xb2\xa1": "<",
        b"\xa1\xb2\xc3\xd4": ">",
        b"\x4d\x3c\xb2\xa1": "<",
        b"\xa1\xb2\x3c\x4d": ">",
    }.get(data[:4])
    if byte_order is None:
        return []
    link_type = struct.unpack_from(byte_order + "I", data, 20)[0]
    names: list[str] = []
    cursor = 24
    while cursor + 16 <= len(data):
        captured = struct.unpack_from(byte_order + "I", data, cursor + 8)[0]
        cursor += 16
        if cursor + captured > len(data):
            break
        names.extend(client_hello_snis(packet_payload(data[cursor : cursor + captured], link_type)))
        cursor += captured
    return names


if __name__ == "__main__":
    observed = captured_snis(pathlib.Path(sys.argv[1]))
    print("\t".join(str(observed.count(name.lower())) for name in sys.argv[2:]))
