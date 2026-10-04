#!/usr/bin/env python3
"""Include the corresponding application and bridge sources in binary packages."""
import argparse
import os
from pathlib import Path
import subprocess
import tarfile


def tracked_files(directory):
    output = subprocess.check_output(
        ["git", "-C", str(directory), "ls-files", "--cached", "--others", "--exclude-standard", "-z"]
    )
    for name in sorted(set(output.decode().split("\0"))):
        path = directory / name
        if name and path.is_file() and not path.is_symlink():
            yield name, path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", type=Path, required=True)
    parser.add_argument("--qtbridge", type=Path, required=True)
    parser.add_argument("--swift-checkouts", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    epoch = int(os.environ.get("SOURCE_DATE_EPOCH") or subprocess.check_output(
        ["git", "-C", str(arguments.repository), "log", "-1", "--format=%ct"], text=True).strip())
    sources = [(arguments.repository, "inzone-linux"), (arguments.qtbridge, "third_party/qtbridge")]
    if arguments.swift_checkouts.is_dir():
        sources.extend((path, "third_party/" + path.name)
                       for path in sorted(arguments.swift_checkouts.iterdir()) if path.is_dir())
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(arguments.output, "w:xz") as archive:
        for directory, prefix in sources:
            for name, path in tracked_files(directory):
                information = archive.gettarinfo(str(path), arcname=prefix + "/" + name)
                information.uid = information.gid = 0
                information.uname = information.gname = "root"
                information.mtime = epoch
                with path.open("rb") as stream:
                    archive.addfile(information, stream)
    print(f"Packaged corresponding source: {arguments.output.name}")


if __name__ == "__main__":
    main()
