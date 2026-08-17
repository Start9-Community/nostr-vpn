#!/usr/bin/env python3
"""Drive the shipped Linux manual-join controls through AT-SPI."""

import argparse
import subprocess
import sys
import time

import pyatspi

target_pid = 0
target_window = 0
component_refind_attempts = 4


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


def try_component_focus(name):
    last_error = None
    for attempt in range(component_refind_attempts):
        node = find_named(name, timeout=15 if attempt == 0 else 2)
        try:
            component = node.queryComponent()
            if component is None:
                raise RuntimeError("AT-SPI returned no Component object")
            return bool(component.grabFocus())
        except Exception as error:
            last_error = error
            if attempt + 1 == component_refind_attempts:
                break
            print(
                f"retry AT-SPI Component for {name}: "
                f"attempt={attempt + 1} error={error}",
                file=sys.stderr,
            )
            pyatspi.Registry.pumpQueuedEvents()
            time.sleep(0.1)
    raise RuntimeError(
        f"AT-SPI Component remained unavailable for {name} after "
        f"{component_refind_attempts} fresh lookups: {last_error}"
    )


def try_accessible_action(name):
    node = find_named(name)
    action = node.queryAction()
    if action is None or action.nActions < 1:
        return False
    return bool(action.doAction(0))


def invoke(name):
    geometry = subprocess.run(
        ["xdotool", "getwindowgeometry", "--shell", str(target_window)],
        check=True,
        text=True,
        capture_output=True,
    ).stdout.strip().replace("\n", " ")
    print(f"activate {name} through AT-SPI; {geometry}", file=sys.stderr)
    subprocess.run(
        ["xdotool", "windowfocus", "--sync", str(target_window)],
        check=True,
    )
    try:
        if try_accessible_action(name):
            time.sleep(0.25)
            return
    except Exception as action_error:
        print(
            f"AT-SPI Action activation unavailable for {name}: "
            f"{action_error}",
            file=sys.stderr,
        )
    try:
        if try_component_focus(name):
            subprocess.run(
                ["xdotool", "key", "--clearmodifiers", "space"],
                check=True,
            )
            time.sleep(0.25)
            return
    except Exception as component_error:
        # GTK4's X11 AT-SPI bridge can expose a named control while its
        # Component object is stale or while rejecting Component.grabFocus.
        # Traverse the verified accessibility focus chain after bounded fresh
        # Component lookups instead of clicking unverified screen coordinates.
        print(
            f"AT-SPI Component focus unavailable for {name}: "
            f"{component_error}",
            file=sys.stderr,
        )
    try:
        focus_named_with_keyboard(name)
        subprocess.run(
            ["xdotool", "key", "--clearmodifiers", "space"],
            check=True,
        )
        time.sleep(0.25)
        return
    except Exception as keyboard_error:
        raise RuntimeError(
            f"AT-SPI keyboard activation failed for {name}: {keyboard_error}"
        ) from keyboard_error


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
