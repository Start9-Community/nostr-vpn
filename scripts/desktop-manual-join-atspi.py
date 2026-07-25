#!/usr/bin/env python3
"""Drive the shipped Linux manual-join controls through AT-SPI."""

import argparse
import subprocess
import sys
import time

import pyatspi

target_pid = 0
target_window = 0


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
            and not state.contains(pyatspi.STATE_DEFUNCT)
        )
    except Exception:
        return False


def find_named(name, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        desktop = pyatspi.Registry.getDesktop(0)
        for node in walk(desktop):
            try:
                if (
                    node.get_process_id() == target_pid
                    and node.name == name
                    and visible(node)
                ):
                    return node
            except Exception:
                continue
        pyatspi.Registry.pumpQueuedEvents()
        time.sleep(0.1)
    visible_nodes = []
    for node in walk(pyatspi.Registry.getDesktop(0)):
        try:
            if (
                node.get_process_id() == target_pid
                and visible(node)
                and node.name
            ):
                visible_nodes.append(f"{node.getRoleName()}:{node.name}")
        except Exception:
            continue
    print(
        "Visible AT-SPI controls: " + ", ".join(visible_nodes[:300]),
        file=sys.stderr,
    )
    raise RuntimeError(f"visible AT-SPI control did not appear: {name}")


def focus_named_with_keyboard(name, max_tabs=80):
    subprocess.run(
        ["xdotool", "windowfocus", "--sync", str(target_window)],
        check=True,
    )
    focused_names = []
    for _ in range(max_tabs):
        node = find_named(name, timeout=1)
        try:
            if node.getState().contains(pyatspi.STATE_FOCUSED):
                return node
        except Exception:
            pass
        subprocess.run(
            ["xdotool", "key", "--clearmodifiers", "Tab"],
            check=True,
        )
        time.sleep(0.05)
        for candidate in walk(pyatspi.Registry.getDesktop(0)):
            try:
                if (
                    candidate.get_process_id() == target_pid
                    and candidate.getState().contains(pyatspi.STATE_FOCUSED)
                ):
                    focused_names.append(
                        f"{candidate.getRoleName()}:{candidate.name}"
                    )
                    break
            except Exception:
                continue
    raise RuntimeError(
        f"keyboard focus did not reach {name}; focused sequence: "
        + ", ".join(focused_names)
    )


def invoke(name):
    node = find_named(name)
    component = node.queryComponent()
    extents = component.getExtents(pyatspi.DESKTOP_COORDS)
    if extents.width <= 0 or extents.height <= 0:
        raise RuntimeError(f"{name} has no clickable visible bounds: {extents}")
    geometry = subprocess.run(
        ["xdotool", "getwindowgeometry", "--shell", str(target_window)],
        check=True,
        text=True,
        capture_output=True,
    ).stdout.strip().replace("\n", " ")
    print(f"click {name}: extents={extents}; {geometry}", file=sys.stderr)
    subprocess.run(
        ["xdotool", "windowfocus", "--sync", str(target_window)],
        check=True,
    )
    try:
        if component.grabFocus():
            subprocess.run(
                ["xdotool", "key", "--clearmodifiers", "space"],
                check=True,
            )
            time.sleep(0.25)
            return
    except Exception:
        # GTK4's X11 AT-SPI bridge can expose valid controls while rejecting
        # Component.grabFocus. Traverse the real focus chain with keyboard
        # events instead of trusting the bridge's broken (0, 0) bounds.
        pass
    try:
        focus_named_with_keyboard(name)
        subprocess.run(
            ["xdotool", "key", "--clearmodifiers", "space"],
            check=True,
        )
        time.sleep(0.25)
        return
    except Exception as keyboard_error:
        print(f"keyboard activation failed for {name}: {keyboard_error}", file=sys.stderr)
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
    time.sleep(0.25)


def set_text(name, value):
    actual = ""
    for attempt in range(3):
        focus_named_with_keyboard(name)
        subprocess.run(
            ["xdotool", "key", "--clearmodifiers", "ctrl+a"],
            check=True,
        )
        subprocess.run(
            ["xdotool", "type", "--clearmodifiers", "--delay", "1", "--", value],
            check=True,
        )
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            for candidate in walk(pyatspi.Registry.getDesktop(0)):
                try:
                    if (
                        candidate.get_process_id() == target_pid
                        and candidate.name == name
                        and visible(candidate)
                    ):
                        actual = candidate.queryText().getText(0, -1)
                        if actual == value:
                            return
                except Exception:
                    continue
            time.sleep(0.05)
        print(
            f"retry text entry {name}: attempt={attempt + 1} got={actual!r}",
            file=sys.stderr,
        )
    raise RuntimeError(f"AT-SPI failed to set {name}: got {actual!r}")


def run_joiner(args):
    invoke("nvpn-manual-join-choose-join")
    invoke("nvpn-manual-join-expander")
    set_text("nvpn-manual-join-admin-id", args.admin_npub)
    set_text("nvpn-manual-join-network-id", args.mesh_network_id)
    invoke("nvpn-manual-join-submit")


def run_admin(args):
    invoke("nvpn-manual-join-admin-open")
    set_text("nvpn-manual-join-admin-device-id", args.joiner_npub)
    set_text("nvpn-manual-join-admin-device-name", args.joiner_alias)
    invoke("nvpn-manual-join-admin-submit")


def main():
    global target_pid, target_window
    parser = argparse.ArgumentParser()
    parser.add_argument("phase", choices=("joiner", "admin"))
    parser.add_argument("--pid", required=True, type=int)
    parser.add_argument("--window-id", required=True, type=int)
    parser.add_argument("--admin-npub", default="")
    parser.add_argument("--mesh-network-id", default="")
    parser.add_argument("--joiner-npub", default="")
    parser.add_argument("--joiner-alias", default="")
    args = parser.parse_args()
    target_pid = args.pid
    target_window = args.window_id
    if args.phase == "joiner":
        if not args.admin_npub or not args.mesh_network_id:
            parser.error("joiner phase requires --admin-npub and --mesh-network-id")
        run_joiner(args)
    else:
        if not args.joiner_npub or not args.joiner_alias:
            parser.error("admin phase requires --joiner-npub and --joiner-alias")
        run_admin(args)
    print(f"LINUX_MANUAL_JOIN_UI_{args.phase.upper()}_OK")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"Linux manual-join UI driver failed: {error}", file=sys.stderr)
        raise
