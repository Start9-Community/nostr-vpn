#!/usr/bin/env python3
"""Query Android's public UIAutomator XML for the Release join gate."""

import argparse
import html
import re
import sys
import xml.etree.ElementTree as ET


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    result.add_argument("xml")
    result.add_argument("kind", choices=("resource", "description", "resource-prefix"))
    result.add_argument("expected")
    result.add_argument(
        "output",
        choices=("center", "safe-center", "description", "text", "count", "width"),
    )
    return result


def resource_matches(actual: str, expected: str) -> bool:
    return actual == expected or actual.endswith(f":id/{expected}") or actual.endswith(f"/{expected}")


def matches(node: ET.Element, kind: str, expected: str) -> bool:
    if kind == "resource":
        return resource_matches(node.attrib.get("resource-id", ""), expected)
    if kind == "resource-prefix":
        actual = node.attrib.get("resource-id", "")
        short = actual.rsplit("/", 1)[-1]
        return short.startswith(expected)
    return html.unescape(node.attrib.get("content-desc", "")) == expected


def center(node: ET.Element) -> str:
    left, top, right, bottom = bounds(node)
    return f"{(left + right) // 2} {(top + bottom) // 2}"


def bounds(node: ET.Element) -> tuple[int, int, int, int]:
    bounds = node.attrib.get("bounds", "")
    match = re.fullmatch(r"\[(\d+),(\d+)]\[(\d+),(\d+)]", bounds)
    if not match:
        raise ValueError(f"invalid bounds: {bounds}")
    left, top, right, bottom = map(int, match.groups())
    if right <= left or bottom <= top:
        raise ValueError(f"empty bounds: {bounds}")
    return left, top, right, bottom


def main() -> int:
    args = parser().parse_args()
    root = ET.parse(args.xml).getroot()
    found = [node for node in root.iter("node") if matches(node, args.kind, args.expected)]
    if args.output == "count":
        print(len(found))
        return 0
    if not found:
        return 1
    node = found[0]
    if args.output in ("center", "safe-center"):
        if args.output == "safe-center":
            viewport_bottom = 0
            for candidate in root.iter("node"):
                try:
                    box = bounds(candidate)
                except ValueError:
                    continue
                if box[:2] == (0, 0):
                    viewport_bottom = max(viewport_bottom, box[3])
            if viewport_bottom == 0:
                return 1
            if bounds(node)[3] > viewport_bottom - 300:
                return 1
        print(center(node))
    elif args.output == "width":
        left, _, right, _ = bounds(node)
        print(right - left)
    elif args.output == "description":
        print(html.unescape(node.attrib.get("content-desc", "")))
    else:
        print(html.unescape(node.attrib.get("text", "")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
