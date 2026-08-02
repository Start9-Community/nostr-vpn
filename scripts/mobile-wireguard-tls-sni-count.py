#!/usr/bin/env python3
"""Count complete TLS ClientHello SNI values in a tcpdump pcap."""

from __future__ import annotations

import collections
import pathlib
import struct
import sys

MAX_CAPTURE_BYTES = 1_100_000
MAX_FLOWS = 128
MAX_SEGMENTS_PER_FLOW = 128
MAX_FLOW_BYTES = 64 * 1024
RESOLVER_IPS = {
    bytes((1, 1, 1, 1)),
    bytes((1, 0, 0, 1)),
    bytes((9, 9, 9, 9)),
    bytes((149, 112, 112, 112)),
    bytes((8, 8, 8, 8)),
    bytes((8, 8, 4, 4)),
}


def packet_segment(packet: bytes, link_type: int):
    offsets = {1: 14, 12: 0, 101: 0, 113: 16, 276: 20}
    offset = offsets.get(link_type)
    if offset is None or len(packet) < offset + 20:
        return None
    if link_type == 1 and packet[12:14] == b"\x81\x00":
        offset += 4
    ip = packet[offset:]
    if ip[0] >> 4 != 4 or ip[9] != 6:
        return None
    tcp = ip[(ip[0] & 0x0F) * 4 :]
    if len(tcp) < 20:
        return None
    source_port, destination_port, sequence = struct.unpack_from("!HHI", tcp)
    header_size = (tcp[12] >> 4) * 4
    if (
        destination_port != 443
        or ip[16:20] not in RESOLVER_IPS
        or header_size < 20
        or header_size > len(tcp)
    ):
        return None
    return (ip[12:20], source_port, destination_port), sequence, tcp[header_size:]


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
    paths = [path] if path.is_file() else sorted(path.parent.glob(path.name + "*"))
    if len(paths) > 1:
        return []
    flows = collections.defaultdict(dict)
    for capture in paths:
        if not capture.is_file():
            return []
        data = capture.read_bytes()
        if len(data) > MAX_CAPTURE_BYTES:
            return []
        byte_order = {
            b"\xd4\xc3\xb2\xa1": "<",
            b"\xa1\xb2\xc3\xd4": ">",
            b"\x4d\x3c\xb2\xa1": "<",
            b"\xa1\xb2\x3c\x4d": ">",
        }.get(data[:4])
        if len(data) < 24 or byte_order is None:
            continue
        link_type = struct.unpack_from(byte_order + "I", data, 20)[0]
        cursor = 24
        while cursor + 16 <= len(data):
            captured = struct.unpack_from(byte_order + "I", data, cursor + 8)[0]
            cursor += 16
            if cursor + captured > len(data):
                break
            segment = packet_segment(data[cursor : cursor + captured], link_type)
            cursor += captured
            if segment is None or not segment[2]:
                continue
            flow, sequence, payload = segment
            if flow not in flows and len(flows) >= MAX_FLOWS:
                return []
            prior = flows[flow].get(sequence, b"")
            if len(payload) > len(prior):
                flows[flow][sequence] = payload
            if (
                len(flows[flow]) > MAX_SEGMENTS_PER_FLOW
                or sum(map(len, flows[flow].values())) > MAX_FLOW_BYTES
            ):
                return []

    names: list[str] = []
    for segments in flows.values():
        stream = bytearray()
        next_sequence = None
        for sequence, payload in sorted(segments.items()):
            if next_sequence is None or sequence > next_sequence:
                names.extend(client_hello_snis(stream))
                stream = bytearray(payload)
                next_sequence = sequence + len(payload)
            elif sequence + len(payload) > next_sequence:
                stream.extend(payload[next_sequence - sequence :])
                next_sequence = sequence + len(payload)
        names.extend(client_hello_snis(stream))
    return names


if __name__ == "__main__":
    observed = captured_snis(pathlib.Path(sys.argv[1]))
    print("\t".join(str(observed.count(name.lower())) for name in sys.argv[2:]))
