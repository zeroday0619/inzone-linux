#!/usr/bin/env python3
"""Verify a Debian CI artifact and collect evidence without installing packages."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def run_logged(arguments: list[str], output: Path, *, errors: Path | None = None,
               environment: dict[str, str], timeout: int = 600) -> None:
    print(f"Running {Path(arguments[0]).name}: {output.name}", flush=True)
    with output.open("w") as stream:
        if errors is None:
            subprocess.run(arguments, check=True, stdout=stream, stderr=subprocess.STDOUT,
                           env=environment, timeout=timeout)
        else:
            with errors.open("w") as error_stream:
                subprocess.run(arguments, check=True, stdout=stream, stderr=error_stream,
                               env=environment, timeout=timeout)


def verify(package: Path, sysroot: Path, apt_config: Path, output: Path) -> None:
    repository = Path(__file__).resolve().parents[2]
    environment = dict(os.environ, LC_ALL="C.UTF-8")
    run_logged([sys.executable, str(repository / "scripts/verify-debian.py"), str(package),
                "--sysroot", str(sysroot)], output / "verification.json",
               errors=output / "verification.log", environment=environment)
    verification = json.loads((output / "verification.json").read_text())
    if verification.get("result") != "passed" or verification.get("runtimeTest") != "passed":
        raise ValueError("The package and extracted runtime must both pass verification.")

    # CI does not inherit a developer's local Lintian overrides or display settings.
    run_logged(["lintian", "--no-cfg", "--ignore-lintian-env", "--no-user-dirs",
                "--color", "never", "--fail-on", "error", str(package)],
               output / "lintian.log", environment=environment)

    with tempfile.TemporaryDirectory(prefix="inzone-apt-verification-") as temporary:
        working = Path(temporary)
        status = working / "status"
        status.touch()
        preferences = working / "preferences"
        preferences.touch()
        (working / "preferences.d").mkdir()
        # Empty state makes dependency resolution independent of the runner's installed packages.
        apt_arguments = [
            "apt-get", "--simulate", "--no-install-recommends",
            "-o", f"Dir::State::status={status}",
            "-o", f"Dir::State::extended_states={working / 'extended_states'}",
            "-o", f"Dir::Cache::pkgcache={working / 'pkgcache.bin'}",
            "-o", f"Dir::Cache::srcpkgcache={working / 'srcpkgcache.bin'}",
            "-o", f"Dir::Etc::preferences={preferences}",
            "-o", f"Dir::Etc::preferencesparts={working / 'preferences.d'}",
            "install", str(package),
        ]
        run_logged(apt_arguments, output / "apt-simulation.log",
                   environment=dict(environment, APT_CONFIG=str(apt_config)))

    preparation = sysroot.parent
    for source, name in ((preparation / "debian-manifest.json", "debian-manifest.json"),
                         (preparation / "qt/manifest.json", "qt-manifest.json")):
        if not source.is_file():
            raise FileNotFoundError(f"Preparation manifest is missing: {source}")
        shutil.copyfile(source, output / name)

    destination = output / package.name
    if package != destination:
        shutil.copyfile(package, destination)
    with destination.open("rb") as stream:
        checksum = hashlib.file_digest(stream, "sha256").hexdigest()
    (output / "SHA256SUMS").write_text(f"{checksum}  {destination.name}\n")
    print(json.dumps({"package": destination.name, "result": "passed", "output": str(output)}, indent=2))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", type=Path, help="The single .deb artifact to verify.")
    parser.add_argument("--sysroot", type=Path, required=True, help="The prepared Debian root directory.")
    parser.add_argument("--apt-config", type=Path, required=True, help="The preparation's signed repository configuration.")
    parser.add_argument("--output-directory", type=Path, required=True, help="Collect the verified package and validation logs here.")
    arguments = parser.parse_args()
    output = arguments.output_directory.resolve()
    try:
        if os.geteuid() == 0:
            raise ValueError("Run package validation as the desktop user.")
        package = arguments.package.resolve(strict=True)
        sysroot = arguments.sysroot.resolve(strict=True)
        apt_config = arguments.apt_config.resolve(strict=True)
        if not package.is_file() or package.suffix != ".deb":
            raise ValueError("The artifact must be a Debian package file.")
        if not sysroot.is_dir() or sysroot == Path("/") or not apt_config.is_file():
            raise ValueError("A prepared sysroot and its APT configuration are required.")
        if apt_config.parent.parent != sysroot.parent:
            raise ValueError("The APT configuration and sysroot must belong to the same preparation.")
        output.mkdir(parents=True, exist_ok=True)
        # A failed rerun must not leave an earlier success checksum in its evidence directory.
        (output / "SHA256SUMS").unlink(missing_ok=True)
        verify(package, sysroot, apt_config, output)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"Debian CI validation failed: {error}", file=sys.stderr)
        print(f"Validation logs: {output}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
