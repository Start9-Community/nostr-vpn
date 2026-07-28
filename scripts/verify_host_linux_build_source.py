#!/usr/bin/env python3
"""Audit a realized-lock Linux build tree against its pristine exact clone."""

from __future__ import annotations

import hashlib
import os
import pathlib
import stat
import subprocess
import sys
from typing import NoReturn


LOCK_PATHS = {
    pathlib.PurePosixPath("Cargo.lock"),
    pathlib.PurePosixPath("linux/Cargo.lock"),
}


def fail(message: str) -> NoReturn:
    raise SystemExit(f"host Linux build-source audit failed: {message}")


def git(root: pathlib.Path, *args: str) -> str:
    completed = subprocess.run(
        ["git", "-C", str(root), *args],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if completed.returncode != 0:
        fail(completed.stderr.strip() or f"git {' '.join(args)} failed")
    return completed.stdout


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def entry_identity(path: pathlib.Path) -> tuple[object, ...]:
    metadata = path.lstat()
    mode = stat.S_IMODE(metadata.st_mode)
    if stat.S_ISREG(metadata.st_mode):
        return ("file", mode, metadata.st_size, sha256(path))
    if stat.S_ISDIR(metadata.st_mode):
        return ("dir", mode)
    if stat.S_ISLNK(metadata.st_mode):
        return ("link", mode, os.readlink(path))
    fail(f"source tree contains an unsafe filesystem type: {path}")


def manifest(root: pathlib.Path) -> dict[pathlib.PurePosixPath, tuple[object, ...]]:
    result: dict[pathlib.PurePosixPath, tuple[object, ...]] = {}
    for current, directories, files in os.walk(root, followlinks=False):
        current_path = pathlib.Path(current)
        relative_root = current_path.relative_to(root)
        if relative_root == pathlib.Path(".git"):
            directories.clear()
            continue
        directories[:] = [
            name for name in directories if relative_root / name != pathlib.Path(".git")
        ]
        for name in [*directories, *files]:
            path = current_path / name
            relative = pathlib.PurePosixPath(path.relative_to(root).as_posix())
            if relative in LOCK_PATHS:
                continue
            result[relative] = entry_identity(path)
    return result


def require_git_identity(
    root: pathlib.Path,
    *,
    expected_sha: str,
    expected_tree: str,
    pristine: bool,
) -> None:
    if git(root, "rev-parse", "HEAD").strip() != expected_sha:
        fail("source HEAD differs from exact candidate")
    if git(root, "rev-parse", "HEAD^{tree}").strip() != expected_tree:
        fail("source tree object differs from exact candidate")
    status = git(root, "status", "--porcelain=v1", "--untracked-files=all")
    if pristine:
        if status:
            fail("pristine exact source clone changed")
        return
    changed = {
        pathlib.PurePosixPath(line[3:])
        for line in status.splitlines()
        if len(line) >= 4
    }
    if changed != LOCK_PATHS:
        fail(f"unexpected build-source change: {sorted(map(str, changed))}")


def main() -> None:
    if len(sys.argv) != 7:
        fail(
            "usage: verify_host_linux_build_source.py "
            "PRISTINE BUILD APP_SHA APP_TREE ROOT_LOCK_SHA LINUX_LOCK_SHA"
        )
    pristine, build = map(pathlib.Path, sys.argv[1:3])
    app_sha, app_tree, root_lock_sha, linux_lock_sha = sys.argv[3:]
    for label, value, length in (
        ("app SHA", app_sha, 40),
        ("app tree", app_tree, 40),
        ("root lock SHA", root_lock_sha, 64),
        ("Linux lock SHA", linux_lock_sha, 64),
    ):
        malformed = len(value) != length or any(
            character not in "0123456789abcdef" for character in value
        )
        if malformed:
            fail(f"{label} is malformed")
    for root in (pristine, build):
        if not root.is_dir() or root.is_symlink():
            fail("source root is not a real directory")
    require_git_identity(
        pristine,
        expected_sha=app_sha,
        expected_tree=app_tree,
        pristine=True,
    )
    require_git_identity(
        build,
        expected_sha=app_sha,
        expected_tree=app_tree,
        pristine=False,
    )
    if manifest(build) != manifest(pristine):
        fail("unexpected build-source change outside the realized lockfiles")
    for relative, expected in (
        (pathlib.Path("Cargo.lock"), root_lock_sha),
        (pathlib.Path("linux/Cargo.lock"), linux_lock_sha),
    ):
        path = build / relative
        if (
            not path.is_file()
            or path.is_symlink()
            or sha256(path) != expected
        ):
            fail(f"realized {relative} differs from exact expected bytes")
    print("HOST_LINUX_BUILD_SOURCE_VERIFIED")


if __name__ == "__main__":
    main()
