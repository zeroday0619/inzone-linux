#!/usr/bin/env python3
"""Prepare the Debian 13 sysroot and pinned Qt SDK using the shared helper."""

from pathlib import Path
import runpy


# Existing callers retain the Debian 13 command line and ownership marker support.
shared = runpy.run_path(str(Path(__file__).with_name("prepare-debian.py")))
for name in ("PACKAGES", "run", "extract_debian", "prepare_qt"):
    globals()[name] = shared[name]


def main() -> None:
    shared["main"](default_suite="trixie")


if __name__ == "__main__":
    main()
