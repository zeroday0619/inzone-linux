#!/usr/bin/env python3
"""Prepare a verified Debian sysroot and pinned Qt SDK without installing packages."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pwd
from pathlib import Path
import shutil
import subprocess
import tarfile
import urllib.request


PACKAGES = """
base-files libc6-dev g++ libsystemd-dev ladspa-sdk libcurl4-openssl-dev
libgl-dev libegl-dev libxkbcommon-dev libvulkan-dev libwayland-dev libx11-dev
libx11-xcb1 libxcb-cursor0 libxcb-icccm4 libxcb-keysyms1 libxcb-image0
libxcb-render-util0 libxcb-xinerama0 libxcb-randr0 libxcb-shape0 libxcb-xfixes0
libxcb-sync1 libxcb-render0 libxcb-shm0 libxcb-xkb1 libxkbcommon-x11-0
libfontconfig1 libfreetype6 libglib2.0-0t64 libgssapi-krb5-2 libdbus-1-3
libproxy1v5 zlib1g libdouble-conversion3 libb2-1 libicu-dev libpcre2-16-0
libzstd1 liblzma5 libpng16-16t64 libbrotli1 libharfbuzz0b libssl3t64
""".split()


def run(*arguments: str, **options) -> None:
    subprocess.run(arguments, check=True, **options)


def extract_debian(base: Path) -> None:
    root = base / "root"
    if root.exists():
        shutil.rmtree(root)
    database = root / "var/lib/dpkg"
    information = database / "info"
    information.mkdir(parents=True, exist_ok=True)
    control_root = base / "control"
    control_root.mkdir(exist_ok=True)
    status = []
    manifest = []
    selected = {}
    for archive in sorted((base / "apt/archives").glob("*.deb")):
        control = subprocess.check_output(["dpkg-deb", "--field", str(archive)], text=True)
        fields = dict(line.split(": ", 1) for line in control.splitlines()
                      if line and not line[0].isspace() and ": " in line)
        key = (fields["Package"], fields["Architecture"])
        previous = selected.get(key)
        if previous and subprocess.call(["dpkg", "--compare-versions", fields["Version"],
                                         "le", previous[2]["Version"]]) == 0:
            continue
        selected[key] = (archive, control, fields)
    for archive, control, fields in sorted(selected.values()):
        name = fields["Package"]
        label = name + (":" + fields["Architecture"] if fields.get("Multi-Arch") == "same" else "")
        run("dpkg-deb", "--extract", str(archive), str(root))
        destination = control_root / label
        run("dpkg-deb", "--control", str(archive), str(destination))
        for filename in ("shlibs", "symbols"):
            if (destination / filename).is_file():
                shutil.copyfile(destination / filename, information / f"{label}.{filename}")
        process = subprocess.Popen(["dpkg-deb", "--fsys-tarfile", str(archive)], stdout=subprocess.PIPE)
        paths = []
        with tarfile.open(fileobj=process.stdout, mode="r|") as stream:
            for member in stream:
                paths.append(("/" + member.name.removeprefix("./")).rstrip("/") or "/")
        if process.wait() != 0:
            raise RuntimeError(f"Cannot read package file list: {archive}")
        (information / f"{label}.list").write_text("\n".join(paths) + "\n")
        status.append(control + "Status: install ok installed\n")
        manifest.append({"package": name, "version": fields["Version"],
                         "architecture": fields["Architecture"], "archive": archive.name,
                         "sha256": hashlib.sha256(archive.read_bytes()).hexdigest()})
    (database / "status").write_text("\n".join(status))
    (information / "format").write_text("1\n")
    (database / "arch").write_text("amd64\n")
    (database / "arch-native").write_text("amd64\n")
    for name in ("lib", "lib64", "bin", "sbin"):
        link = root / name
        if not link.exists() and not link.is_symlink():
            link.symlink_to("usr/" + name)
    (base / "debian-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


def prepare_qt(base: Path, repository: Path) -> None:
    extractor = shutil.which("bsdtar")
    if not extractor:
        raise RuntimeError("bsdtar from libarchive-tools is required to extract the pinned Qt SDK.")
    manifest_path = repository / "packaging/debian/qt-sdk-6.11.2.json"
    manifest = json.loads(manifest_path.read_text())
    downloads = base / "qt/downloads"
    downloads.mkdir(parents=True, exist_ok=True)
    for entry in manifest:
        archive = downloads / Path(entry["url"]).name
        if not archive.is_file() or hashlib.sha256(archive.read_bytes()).hexdigest() != entry["sha256"]:
            temporary = archive.with_suffix(archive.suffix + ".download")
            with urllib.request.urlopen(entry["url"], timeout=300) as response, temporary.open("wb") as output:
                shutil.copyfileobj(response, output)
            if hashlib.sha256(temporary.read_bytes()).hexdigest() != entry["sha256"]:
                temporary.unlink()
                raise RuntimeError(f"Qt archive SHA-256 mismatch: {archive.name}")
            temporary.replace(archive)
        destination = base / "qt/sdk"
        if "icu-linux-" in archive.name:
            destination /= "lib"
        destination.mkdir(parents=True, exist_ok=True)
        run(extractor, "-xf", str(archive), "-C", str(destination))
        print(f"Verified and extracted {archive.name}", flush=True)
    shutil.copyfile(manifest_path, base / "qt/manifest.json")


def main(default_suite: str | None = None) -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    if default_suite is None:
        parser.add_argument("--suite", choices=("trixie", "forky"), required=True)
    else:
        parser.set_defaults(suite=default_suite)
    parser.add_argument("--keyring", type=Path,
                        default=Path("/usr/share/keyrings/debian-archive-keyring.gpg"),
                        help="Trusted Debian archive keyring used to verify APT indexes.")
    parser.add_argument("--reuse", action="store_true", help="Reuse and update an existing preparation directory.")
    options = parser.parse_args()
    if os.geteuid() == 0:
        raise RuntimeError("Run preparation as the desktop user.")
    base = options.directory.resolve()
    if base in (Path("/"), Path.home()) or any(character in str(base) for character in ('"', ';', '\n')):
        raise ValueError("Use a dedicated preparation directory with an unambiguous path.")
    keyring = options.keyring.resolve(strict=True)
    if not keyring.is_file() or any(character.isspace() or character in '\";[]' for character in str(keyring)):
        raise ValueError("Use an existing Debian archive keyring without whitespace or APT syntax in its path.")
    marker = base / ".inzone-debian-preparation.json"
    marker_content = {"format": 1, "project": "inzone-linux", "architecture": "amd64", "suite": options.suite}
    legacy_marker = base / ".inzone-debian13-preparation.json"
    legacy_content = {"format": 1, "project": "inzone-linux", "architecture": "amd64"}
    if base.exists() and any(base.iterdir()):
        current_marker_matches = marker.is_file() and json.loads(marker.read_text()) == marker_content
        legacy_marker_matches = (not marker.exists() and options.suite == "trixie" and
                                 legacy_marker.is_file() and json.loads(legacy_marker.read_text()) == legacy_content)
        if not options.reuse or not (current_marker_matches or legacy_marker_matches):
            raise ValueError("Reusing a directory requires --reuse and an INZONE marker for the same Debian suite.")
    base.mkdir(parents=True, exist_ok=True)
    marker.write_text(json.dumps(marker_content) + "\n")
    for directory in ("apt/lists/partial", "apt/archives/partial", "apt/empty-parts", "root"):
        (base / directory).mkdir(parents=True, exist_ok=True)
    config = base / "apt/config"
    (base / "apt/status").touch()
    sources = [f"https://deb.debian.org/debian {options.suite}"]
    if options.suite == "trixie":
        sources.extend(("https://deb.debian.org/debian trixie-updates",
                        "https://security.debian.org/debian-security trixie-security"))
    (base / "apt/sources.list").write_text("".join(
        f"deb [arch=amd64 signed-by={keyring}] {source} main\n" for source in sources))
    config.write_text(f'''Dir::Etc::main "-";
Dir::Etc::parts "{base}/apt/empty-parts";
Dir::Etc::sourcelist "{base}/apt/sources.list";
Dir::Etc::sourceparts "{base}/apt/empty-parts";
Dir::State::lists "{base}/apt/lists";
Dir::State::status "{base}/apt/status";
Dir::Cache::archives "{base}/apt/archives";
Dir::Cache::pkgcache "{base}/apt/pkgcache.bin";
Dir::Cache::srcpkgcache "{base}/apt/srcpkgcache.bin";
APT::Architecture "amd64";
APT::Architectures {{ "amd64"; }};
APT::Sandbox::User "{pwd.getpwuid(os.getuid()).pw_name}";
APT::Install-Recommends "false";
APT::Install-Suggests "false";
Acquire::Languages "none";
''')
    environment = dict(os.environ, APT_CONFIG=str(config))
    run("apt-get", "update", env=environment)
    run("apt-get", "--download-only", "--assume-yes", "install", *PACKAGES, env=environment)
    extract_debian(base)
    target = {"format": 1, "suite": options.suite, "architecture": "amd64"}
    for destination in (base / "debian-target.json", base / "root/.inzone-debian-target.json"):
        destination.write_text(json.dumps(target, indent=2) + "\n")
    prepare_qt(base, Path(__file__).resolve().parents[1])
    print(f"Debian {options.suite} sysroot: {base}/root\nQt SDK: {base}/qt/sdk")


if __name__ == "__main__":
    main()
