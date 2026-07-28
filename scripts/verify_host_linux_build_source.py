#!/usr/bin/env python3
"""Audit Linux release source bytes directly against exact Git tree objects."""

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


def git(root: pathlib.Path, *args: str, text: bool = True) -> str | bytes:
    completed = subprocess.run(
        ["git", "-C", str(root), *args],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=text,
    )
    if completed.returncode != 0:
        error = completed.stderr
        if isinstance(error, bytes):
            error = error.decode(errors="replace")
        fail(error.strip() or f"git {' '.join(args)} failed")
    return completed.stdout


def file_digest(path: pathlib.Path, algorithm: str, prefix: bytes = b"") -> str:
    digest = hashlib.new(algorithm)
    digest.update(prefix)
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha256(path: pathlib.Path) -> str:
    return file_digest(path, "sha256")


def git_blob_oid(path: pathlib.Path, size: int) -> str:
    prefix = f"blob {size}\0".encode()
    return file_digest(path, "sha1", prefix)


def expected_tree(
    root: pathlib.Path,
    tree: str,
) -> tuple[
    dict[pathlib.PurePosixPath, tuple[str, int, str]],
    set[pathlib.PurePosixPath],
]:
    if git(root, "rev-parse", "--show-object-format").strip() != "sha1":
        fail("source repository does not use the expected SHA-1 object format")
    raw = git(root, "ls-tree", "-rz", "--full-tree", tree, text=False)
    assert isinstance(raw, bytes)
    leaves: dict[pathlib.PurePosixPath, tuple[str, int, str]] = {}
    directories: set[pathlib.PurePosixPath] = set()
    for record in raw.split(b"\0"):
        if not record:
            continue
        try:
            metadata, raw_path = record.split(b"\t", 1)
            raw_mode, raw_kind, raw_oid = metadata.split(b" ", 2)
            mode = int(raw_mode, 8)
            kind = raw_kind.decode("ascii")
            oid = raw_oid.decode("ascii")
            relative = pathlib.PurePosixPath(os.fsdecode(raw_path))
        except (UnicodeDecodeError, ValueError) as error:
            fail(f"Git tree entry is malformed: {error}")
        if (
            kind != "blob"
            or mode not in {0o100644, 0o100755, 0o120000}
            or len(oid) != 40
            or any(character not in "0123456789abcdef" for character in oid)
            or relative.is_absolute()
            or ".." in relative.parts
            or not relative.parts
            or relative in leaves
        ):
            fail(f"Git tree contains an unsupported entry: {relative}")
        entry_kind = "link" if mode == 0o120000 else "file"
        leaves[relative] = (entry_kind, mode, oid)
        for length in range(1, len(relative.parts)):
            directories.add(pathlib.PurePosixPath(*relative.parts[:length]))
    if not leaves:
        fail("Git tree contains no source files")
    return leaves, directories


def actual_tree(
    root: pathlib.Path,
) -> tuple[
    dict[pathlib.PurePosixPath, tuple[str, int, int | str]],
    set[pathlib.PurePosixPath],
]:
    leaves: dict[pathlib.PurePosixPath, tuple[str, int, int | str]] = {}
    found_directories: set[pathlib.PurePosixPath] = set()
    git_metadata = root / ".git"
    if (
        not git_metadata.exists()
        or git_metadata.is_symlink()
        or not (git_metadata.is_dir() or git_metadata.is_file())
    ):
        fail("source Git metadata is missing or unsafe")
    for current, directories, files in os.walk(root, followlinks=False):
        current_path = pathlib.Path(current)
        relative_root = pathlib.PurePosixPath(
            current_path.relative_to(root).as_posix()
        )
        if relative_root == pathlib.PurePosixPath("."):
            directories[:] = [name for name in directories if name != ".git"]
            files[:] = [name for name in files if name != ".git"]
        for name in list(directories):
            path = current_path / name
            relative = pathlib.PurePosixPath(path.relative_to(root).as_posix())
            metadata = path.lstat()
            if stat.S_ISLNK(metadata.st_mode):
                directories.remove(name)
                target = os.fsencode(os.readlink(path))
                leaves[relative] = (
                    "link",
                    0o120000,
                    hashlib.sha1(
                        f"blob {len(target)}\0".encode() + target
                    ).hexdigest(),
                )
            elif stat.S_ISDIR(metadata.st_mode):
                if stat.S_IMODE(metadata.st_mode) != 0o755:
                    fail(f"source directory mode differs: {relative}")
                found_directories.add(relative)
            else:
                fail(f"source tree contains an unsafe entry: {relative}")
        for name in files:
            path = current_path / name
            relative = pathlib.PurePosixPath(path.relative_to(root).as_posix())
            metadata = path.lstat()
            if stat.S_ISLNK(metadata.st_mode):
                target = os.fsencode(os.readlink(path))
                leaves[relative] = (
                    "link",
                    0o120000,
                    hashlib.sha1(
                        f"blob {len(target)}\0".encode() + target
                    ).hexdigest(),
                )
            elif stat.S_ISREG(metadata.st_mode):
                mode = stat.S_IMODE(metadata.st_mode)
                if mode not in {0o644, 0o755}:
                    fail(f"source file mode differs: {relative}")
                leaves[relative] = (
                    "file",
                    0o100000 | mode,
                    git_blob_oid(path, metadata.st_size),
                )
            else:
                fail(f"source tree contains an unsafe entry: {relative}")
    return leaves, found_directories


def require_git_identity(
    root: pathlib.Path,
    *,
    expected_sha: str,
    expected_tree: str,
) -> None:
    if git(root, "rev-parse", "HEAD").strip() != expected_sha:
        fail("source HEAD differs from exact candidate")
    if git(root, "rev-parse", "HEAD^{tree}").strip() != expected_tree:
        fail("source tree object differs from exact candidate")


def verify_tree(
    root: pathlib.Path,
    expected_sha: str,
    expected_tree_oid: str,
    lock_overrides: dict[pathlib.PurePosixPath, str],
) -> None:
    require_git_identity(
        root,
        expected_sha=expected_sha,
        expected_tree=expected_tree_oid,
    )
    expected_leaves, expected_directories = expected_tree(
        root, expected_tree_oid
    )
    actual_leaves, actual_directories = actual_tree(root)
    if actual_directories != expected_directories:
        fail("source directory set differs from exact Git tree")
    if set(actual_leaves) != set(expected_leaves):
        fail("source file set differs from exact Git tree")
    if not set(lock_overrides).issubset(expected_leaves):
        fail("realized lock override is absent from the exact Git tree")
    for relative, expected in expected_leaves.items():
        actual = actual_leaves[relative]
        if actual[:2] != expected[:2]:
            fail(f"source type or mode differs from Git: {relative}")
        if relative in lock_overrides:
            path = root / pathlib.Path(*relative.parts)
            if (
                expected[0] != "file"
                or not path.is_file()
                or path.is_symlink()
                or sha256(path) != lock_overrides[relative]
            ):
                fail(f"realized {relative} differs from exact expected bytes")
        elif actual[2] != expected[2]:
            fail(f"source bytes differ from exact Git blob: {relative}")


def main() -> None:
    if len(sys.argv) == 5 and sys.argv[1] == "--exact":
        root = pathlib.Path(sys.argv[2])
        expected_sha, expected_tree_oid = sys.argv[3:]
        for label, value in (
            ("source SHA", expected_sha),
            ("source tree", expected_tree_oid),
        ):
            if len(value) != 40 or any(
                character not in "0123456789abcdef" for character in value
            ):
                fail(f"{label} is malformed")
        if not root.is_dir() or root.is_symlink():
            fail("source root is not a real directory")
        verify_tree(root, expected_sha, expected_tree_oid, {})
        print("HOST_LINUX_BUILD_SOURCE_VERIFIED")
        return
    if len(sys.argv) != 7:
        fail(
            "usage: verify_host_linux_build_source.py "
            "--exact ROOT SHA TREE | "
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
    verify_tree(pristine, app_sha, app_tree, {})
    verify_tree(
        build,
        app_sha,
        app_tree,
        {
            pathlib.PurePosixPath("Cargo.lock"): root_lock_sha,
            pathlib.PurePosixPath("linux/Cargo.lock"): linux_lock_sha,
        },
    )
    print("HOST_LINUX_BUILD_SOURCE_VERIFIED")


if __name__ == "__main__":
    main()
