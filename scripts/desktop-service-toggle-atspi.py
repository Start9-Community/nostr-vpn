#!/usr/bin/env python3
"""Click the shipped GTK VPN switch through its real AT-SPI control."""

import argparse
import subprocess
import sys
import time

import pyatspi


def walk(node):
    yield node
    try:
        children = list(node)
    except Exception:
        return
    for child in children:
        yield from walk(child)


def visible(node):
    try:
        state = node.getState()
        return (
            state.contains(pyatspi.STATE_VISIBLE)
            and state.contains(pyatspi.STATE_SHOWING)
            and state.contains(pyatspi.STATE_SENSITIVE)
            and not state.contains(pyatspi.STATE_DEFUNCT)
        )
    except Exception:
        return False


def find_toggle(pid, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        for node in walk(pyatspi.Registry.getDesktop(0)):
            try:
                if (
                    node.get_process_id() == pid
                    and node.name == "nvpn-service-toggle"
                    and visible(node)
                ):
                    extents = node.queryComponent().getExtents(
                        pyatspi.DESKTOP_COORDS
                    )
                    if extents.width > 0 and extents.height > 0:
                        return node, extents
            except Exception:
                continue
        pyatspi.Registry.pumpQueuedEvents()
        time.sleep(0.1)
    raise RuntimeError("visible sensitive nvpn-service-toggle did not appear")


def focus_toggle_with_keyboard(pid, window_id, max_tabs=80):
    subprocess.run(
        ["xdotool", "windowfocus", "--sync", str(window_id)],
        check=True,
    )
    focused_names = []
    for _ in range(max_tabs):
        node, _ = find_toggle(pid, timeout=1)
        if node.getState().contains(pyatspi.STATE_FOCUSED):
            return
        subprocess.run(
            ["xdotool", "key", "--clearmodifiers", "Tab"],
            check=True,
        )
        time.sleep(0.05)
        for candidate in walk(pyatspi.Registry.getDesktop(0)):
            try:
                if (
                    candidate.get_process_id() == pid
                    and candidate.getState().contains(pyatspi.STATE_FOCUSED)
                ):
                    focused_names.append(
                        f"{candidate.getRoleName()}:{candidate.name}"
                    )
                    break
            except Exception:
                continue
    raise RuntimeError(
        "keyboard focus did not reach nvpn-service-toggle; focused sequence: "
        + ", ".join(focused_names)
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--pid", required=True, type=int)
    parser.add_argument("--window-id", required=True, type=int)
    args = parser.parse_args()
    node, extents = find_toggle(args.pid)
    subprocess.run(
        ["xdotool", "windowfocus", "--sync", str(args.window_id)],
        check=True,
    )
    try:
        if node.queryComponent().grabFocus():
            subprocess.run(
                ["xdotool", "key", "--clearmodifiers", "space"],
                check=True,
            )
        else:
            raise RuntimeError("AT-SPI refused toggle focus")
    except Exception as focus_error:
        print(
            f"AT-SPI direct focus failed ({focus_error}); using real keyboard focus chain",
            file=sys.stderr,
        )
        try:
            focus_toggle_with_keyboard(args.pid, args.window_id)
            subprocess.run(
                ["xdotool", "key", "--clearmodifiers", "space"],
                check=True,
            )
        except Exception as keyboard_error:
            print(
                f"keyboard toggle activation failed ({keyboard_error}); using physical pointer",
                file=sys.stderr,
            )
            subprocess.run(
                [
                    "xdotool",
                    "mousemove",
                    str(extents.x + extents.width // 2),
                    str(extents.y + extents.height // 2),
                    "click",
                    "1",
                ],
                check=True,
            )
    print("LINUX_SERVICE_TOGGLE_REAL_UI_CLICK_OK")


if __name__ == "__main__":
    main()
