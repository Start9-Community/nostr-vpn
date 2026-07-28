#!/usr/bin/env python3
"""Seed/store only Cargo archives whose bytes match the exact lockfiles."""

from __future__ import annotations

import hashlib
import json
import os
import pathlib
import re
import shutil
import stat
import sys
import tempfile
from typing import NoReturn


CRATES_IO_CACHE = "registry/cache/index.crates.io-1949cf8c6b5b557f"


def fail(message: str) -> NoReturn:
    raise SystemExit(f"host Linux Cargo archive cache rejected: {message}")


def read_regular_bytes(path: pathlib.Path, label: str) -> bytes:
    try:
        metadata = path.lstat()
    except OSError as error:
        fail(f"could not stat {label}: {error}")
    if not stat.S_ISREG(metadata.st_mode) or path.is_symlink():
        fail(f"{label} is not a regular non-symlink file")
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, "rb") as source:
        opened = os.fstat(source.fileno())
        if (
            opened.st_dev != metadata.st_dev
            or opened.st_ino != metadata.st_ino
            or not stat.S_ISREG(opened.st_mode)
        ):
            fail(f"{label} changed while opening")
        return source.read()


def sha256_regular(path: pathlib.Path) -> str:
    try:
        metadata = path.lstat()
    except OSError as error:
        fail(f"could not stat cached crate archive: {error}")
    if not stat.S_ISREG(metadata.st_mode) or path.is_symlink():
        fail("persistent Cargo cache contains a non-archive entry")
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    digest = hashlib.sha256()
    with os.fdopen(descriptor, "rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def expected_archives(lock_paths: list[pathlib.Path]) -> dict[str, str]:
    expected: dict[str, str] = {}
    for lock_path in lock_paths:
        try:
            document = read_regular_bytes(
                lock_path, "exact Cargo.lock"
            ).decode("utf-8")
        except (OSError, UnicodeDecodeError) as error:
            fail(f"could not parse exact Cargo.lock: {error}")
        sections = document.split("[[package]]\n")
        if len(sections) < 2:
            fail("exact Cargo.lock has no package tables")
        for section in sections[1:]:
            values: dict[str, str] = {}
            for key in ("name", "version", "source", "checksum"):
                matches = re.findall(
                    rf'^{key} = "([^"\\]*)"$',
                    section,
                    flags=re.MULTILINE,
                )
                if len(matches) > 1:
                    fail(f"exact Cargo.lock package has duplicate {key}")
                if matches:
                    values[key] = matches[0]
            if "name" not in values or "version" not in values:
                fail("exact Cargo.lock package lacks name or version")
            source = values.get("source")
            checksum = values.get("checksum")
            if source is None:
                if checksum is not None:
                    fail("path package unexpectedly has a checksum")
                continue
            if source != "registry+https://github.com/rust-lang/crates.io-index":
                fail("exact Cargo.lock contains a non-crates.io remote source")
            if not isinstance(checksum, str) or len(checksum) != 64:
                fail("registry package lacks an exact SHA-256 checksum")
            if re.fullmatch(r"[0-9a-f]{64}", checksum) is None:
                fail("registry package checksum is malformed")
            name = f"{values['name']}-{values['version']}.crate"
            previous = expected.setdefault(name, checksum)
            if previous != checksum:
                fail(f"Cargo.lock has ambiguous archive identity: {name}")
    if not expected:
        fail("exact Cargo.lock set contains no registry archives")
    return expected


def require_private_empty_directory(path: pathlib.Path, label: str) -> None:
    try:
        metadata = path.lstat()
    except OSError as error:
        fail(f"{label} is unavailable: {error}")
    if not stat.S_ISDIR(metadata.st_mode) or path.is_symlink():
        fail(f"{label} is not a real directory")
    if any(path.iterdir()):
        fail(f"{label} is not fresh and empty")


def read_cache(
    cache_dir: pathlib.Path, expected: dict[str, str]
) -> dict[str, pathlib.Path]:
    if not cache_dir.exists():
        if cache_dir.is_symlink():
            fail("persistent Cargo cache root is a symlink")
        return {}
    try:
        metadata = cache_dir.lstat()
    except OSError as error:
        fail(f"could not stat persistent Cargo cache: {error}")
    if (
        not stat.S_ISDIR(metadata.st_mode)
        or cache_dir.is_symlink()
        or stat.S_IMODE(metadata.st_mode) != 0o700
    ):
        fail("persistent Cargo cache root is unsafe")
    entries = {entry.name: entry for entry in cache_dir.iterdir()}
    if set(entries) != {*expected, "manifest.json"}:
        fail("persistent Cargo cache contains a non-archive entry")
    manifest_path = entries["manifest.json"]
    if stat.S_IMODE(manifest_path.lstat().st_mode) != 0o444:
        fail("persistent Cargo cache manifest mode differs")
    try:
        manifest = json.loads(
            read_regular_bytes(
                manifest_path, "persistent Cargo cache manifest"
            ).decode("utf-8")
        )
    except (OSError, ValueError) as error:
        fail(f"persistent Cargo cache manifest is invalid: {error}")
    if manifest != {"schema": 1, "archives": expected}:
        fail("persistent Cargo cache manifest differs from exact Cargo.lock")
    result: dict[str, pathlib.Path] = {}
    for name, expected_checksum in expected.items():
        path = entries[name]
        if stat.S_IMODE(path.lstat().st_mode) != 0o444:
            fail("persistent Cargo cache archive mode differs")
        if sha256_regular(path) != expected_checksum:
            fail("cached crate archive checksum differs from Cargo.lock")
        result[name] = path
    return result


def copy_archive(source: pathlib.Path, destination: pathlib.Path) -> None:
    source_descriptor = os.open(source, os.O_RDONLY | os.O_NOFOLLOW)
    destination_descriptor = os.open(
        destination,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
        0o444,
    )
    try:
        with os.fdopen(source_descriptor, "rb") as source_file:
            with os.fdopen(destination_descriptor, "wb") as destination_file:
                for chunk in iter(
                    lambda: source_file.read(1024 * 1024), b""
                ):
                    destination_file.write(chunk)
                destination_file.flush()
                os.fsync(destination_file.fileno())
    except BaseException:
        destination.unlink(missing_ok=True)
        raise


def seed(
    cache_dir: pathlib.Path,
    cargo_home: pathlib.Path,
    expected: dict[str, str],
) -> None:
    require_private_empty_directory(cargo_home, "fresh Cargo home")
    cached = read_cache(cache_dir, expected)
    if not cached:
        return
    destination = cargo_home / CRATES_IO_CACHE
    destination.mkdir(parents=True, mode=0o700)
    for name, source in cached.items():
        copy_archive(source, destination / name)


def cargo_archives(
    cargo_home: pathlib.Path, expected: dict[str, str]
) -> dict[str, pathlib.Path]:
    registry_cache = cargo_home / "registry/cache"
    if not registry_cache.is_dir() or registry_cache.is_symlink():
        fail("fresh Cargo home did not produce a registry archive cache")
    found: dict[str, pathlib.Path] = {}
    for index_dir in registry_cache.iterdir():
        if not index_dir.is_dir() or index_dir.is_symlink():
            fail("fresh Cargo home registry cache contains an unsafe entry")
        for entry in index_dir.iterdir():
            if entry.name not in expected or entry.name in found:
                fail("fresh Cargo home downloaded an unexpected archive")
            if sha256_regular(entry) != expected[entry.name]:
                fail("downloaded crate archive checksum differs from Cargo.lock")
            found[entry.name] = entry
    if set(found) != set(expected):
        missing = sorted(set(expected) - set(found))
        fail(f"fresh Cargo home is missing exact archives: {missing[:3]}")
    return found


def purge_extracted_sources(cargo_home: pathlib.Path) -> None:
    source_root = cargo_home / "registry/src"
    if not source_root.exists():
        if source_root.is_symlink():
            fail("fresh Cargo home registry source root is a symlink")
        return
    try:
        metadata = source_root.lstat()
    except OSError as error:
        fail(f"could not stat fresh Cargo registry source root: {error}")
    if not stat.S_ISDIR(metadata.st_mode) or source_root.is_symlink():
        fail("fresh Cargo home registry source root is unsafe")
    try:
        shutil.rmtree(source_root)
    except OSError as error:
        fail(f"could not purge realized Cargo registry sources: {error}")


def audit(cargo_home: pathlib.Path, expected: dict[str, str]) -> None:
    for name in (
        "bin",
        "config",
        "config.toml",
        "credentials",
        "credentials.toml",
        "env",
        "git",
    ):
        if (cargo_home / name).exists() or (cargo_home / name).is_symlink():
            fail(f"fresh Cargo home contains forbidden executable/config surface: {name}")
    cargo_archives(cargo_home, expected)


def store(
    cargo_home: pathlib.Path,
    cache_dir: pathlib.Path,
    expected: dict[str, str],
) -> None:
    archives = cargo_archives(cargo_home, expected)
    if cache_dir.exists() or cache_dir.is_symlink():
        read_cache(cache_dir, expected)
        return
    parent = cache_dir.parent
    if not parent.is_dir() or parent.is_symlink():
        fail("persistent Cargo cache parent is unsafe")
    temporary = pathlib.Path(
        tempfile.mkdtemp(prefix=f".{cache_dir.name}.", dir=parent)
    )
    try:
        temporary.chmod(0o700)
        for name, source in archives.items():
            copy_archive(source, temporary / name)
        manifest = temporary / "manifest.json"
        descriptor = os.open(
            manifest,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
            0o444,
        )
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            json.dump(
                {"schema": 1, "archives": expected},
                output,
                indent=2,
                sort_keys=True,
            )
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        os.rename(temporary, cache_dir)
        directory_descriptor = os.open(parent, os.O_RDONLY)
        try:
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
    finally:
        if temporary.exists():
            for child in temporary.iterdir():
                child.unlink()
            temporary.rmdir()


def main() -> None:
    if len(sys.argv) != 6 or sys.argv[1] not in {"audit", "seed", "store"}:
        fail(
            "usage: host_linux_cargo_archive_cache.py "
            "audit|seed|store CACHE_DIR CARGO_HOME ROOT_LOCK LINUX_LOCK"
        )
    operation = sys.argv[1]
    cache_dir = pathlib.Path(sys.argv[2])
    cargo_home = pathlib.Path(sys.argv[3])
    expected = expected_archives(
        [pathlib.Path(sys.argv[4]), pathlib.Path(sys.argv[5])]
    )
    if operation == "seed":
        seed(cache_dir, cargo_home, expected)
    elif operation == "audit":
        audit(cargo_home, expected)
    else:
        audit(cargo_home, expected)
        store(cargo_home, cache_dir, expected)
        purge_extracted_sources(cargo_home)


if __name__ == "__main__":
    main()
