#!/usr/bin/env python3
"""Resolve package dependencies against a prepared Debian sysroot."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys


def prepare_database(sysroot: Path, database: Path) -> None:
    source = sysroot / "var/lib/dpkg"
    if not (source / "status").is_file() or not (source / "info").is_dir():
        raise ValueError("The sysroot must include dpkg status, file lists, symbols, and shlibs metadata.")
    database.mkdir(parents=True, exist_ok=True)
    information = database / "info"
    information.mkdir(exist_ok=True)
    shutil.copyfile(source / "status", database / "status")
    # The format marker enables architecture-qualified package metadata names.
    (information / "format").write_text("1\n")
    (database / "arch").write_text("amd64\n")
    (database / "arch-native").write_text("amd64\n")
    for file in sorted((source / "info").iterdir()):
        if file.suffix in (".symbols", ".shlibs"):
            shutil.copyfile(file, information / file.name)
        elif file.suffix == ".list":
            lines = file.read_text().splitlines()
            if any(not line.startswith("/") for line in lines):
                raise ValueError(f"A package file list contains a non-absolute path: {file}")
            (information / file.name).write_text("\n".join(str(sysroot) + line for line in lines) + "\n")


def check_libraries(sysroot: Path, arguments: list[str]) -> None:
    root = Path.cwd().resolve()
    loader = sysroot / "usr/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2"
    directories = [root / "usr/lib/inzone-linux/swift", root / "usr/lib/inzone-linux/qt/lib",
                   sysroot / "usr/lib/x86_64-linux-gnu", sysroot / "lib/x86_64-linux-gnu"]
    library_path = ":".join(str(path) for path in directories if path.is_dir())
    environment = dict(os.environ)
    for key in ("LD_LIBRARY_PATH", "LD_PRELOAD", "LD_AUDIT"):
        environment.pop(key, None)
    for argument in arguments:
        path = Path(argument[2:] if argument.startswith("-e") else argument)
        if not path.is_file():
            continue
        with path.open("rb") as stream:
            if stream.read(4) != b"\x7fELF":
                continue
        result = subprocess.run([str(loader), "--inhibit-cache", "--library-path", library_path,
                                 "--list", str(path.resolve())], env=environment,
                                capture_output=True, text=True)
        if result.returncode:
            raise ValueError(f"The Debian sysroot cannot resolve {path}:\n{result.stderr}")
        for filename in re.findall(r"=>\s+(/\S+)\s+\(", result.stdout):
            library = Path(filename).resolve()
            if not library.is_relative_to(sysroot) and not library.is_relative_to(root):
                raise ValueError(f"A package dependency resolves outside the Debian sysroot and the package: {library}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sysroot", required=True, type=Path)
    parser.add_argument("--database", required=True, type=Path)
    parser.add_argument("--prepare", action="store_true")
    parser.add_argument("arguments", nargs=argparse.REMAINDER)
    options = parser.parse_args()
    sysroot = options.sysroot.resolve(strict=True)
    database = options.database.resolve()
    if sysroot == Path("/"):
        raise ValueError("The host filesystem cannot be used as the Debian sysroot.")
    if options.prepare:
        prepare_database(sysroot, database)
        return 0
    arguments = options.arguments
    if arguments[:1] == ["--"]:
        arguments = arguments[1:]
    if "--help" not in arguments and "--version" not in arguments:
        check_libraries(sysroot, arguments)
    command = ["/usr/bin/dpkg-shlibdeps", f"--admindir={database}", f"-S{sysroot}",
               f"-l{sysroot}/usr/lib/x86_64-linux-gnu", *arguments]
    return subprocess.call(command)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, OSError) as error:
        print(f"Debian sysroot dependency check failed: {error}", file=sys.stderr)
        raise SystemExit(1)
