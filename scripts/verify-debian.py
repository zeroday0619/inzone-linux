#!/usr/bin/env python3
"""Validate an extracted Debian package without installing it or accessing headset hardware."""

from __future__ import annotations

import argparse
from email.parser import Parser
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile


EXECUTABLES = ("inzone-profile", "inzone-tools", "inzone-service", "inzone-gui")
PROPRIETARY_SUFFIXES = {".exe", ".dll", ".hki", ".ba"}
SECRET_DIRECTORIES = {".git", ".ssh", ".aws", ".gnupg", ".codex"}
SECRET_SUFFIXES = {".pem", ".key", ".p12", ".pfx", ".jks"}
EXPLICIT_DEPENDENCIES = {
    "pipewire-bin", "pipewire-pulse", "wireplumber", "pulseaudio-utils", "dbus-user-session", "udev",
    "libc6", "libsystemd0",
}
QML_DEPENDENCIES = {
    "qml6-module-qtquick", "qml6-module-qtquick-window", "qml6-module-qtquick-layouts",
    "qml6-module-qtquick-controls", "qml6-module-qtquick-templates", "qml6-module-qtqml-workerscript", "qt6-wayland",
}
REQUIRED_FILES = (
    "usr/share/inzone-linux/gui/Main.qml",
    "usr/share/inzone-linux/gui/components/HostVolume.qml",
    "usr/share/applications/dev.zeroday0619.desktop",
    "usr/share/metainfo/dev.zeroday0619.InzoneControl.metainfo.xml",
    "usr/share/icons/hicolor/scalable/apps/dev.zeroday0619.svg",
    "usr/share/dbus-1/services/dev.zeroday0619.service",
    "usr/lib/systemd/user/inzone-control.service",
    "usr/lib/systemd/user/inzone-profile-auto.service",
    "usr/lib/systemd/user/inzone-filter-chain.service",
    "usr/lib/udev/rules.d/70-inzone-h9-ii.rules",
    "usr/lib/ladspa/inzone_dsp.so",
    "usr/share/inzone-linux/setup/README.md",
    "usr/share/inzone-linux/setup/configs/balanced.conf",
    "usr/share/inzone-linux/setup/configs/filter-chain.conf",
    "usr/share/inzone-linux/setup/configs/systemd/inzone-profile-auto.service",
    "usr/share/inzone-linux/setup/evidence/installer.json",
    "usr/share/inzone-linux/setup/native/inzone_dsp.so",
    "usr/share/doc/inzone-linux/copyright",
    "usr/share/doc/inzone-linux/LICENSE.inzone-linux",
    "usr/share/doc/inzone-linux/debian.md",
    "usr/share/doc/inzone-linux/runtime-manifest.json",
    "usr/share/doc/inzone-linux/source.tar.xz",
    "usr/share/doc/inzone-linux/licenses/swift/LICENSE.txt",
    "usr/share/doc/inzone-linux/licenses/qtbridge/LICENSE.txt",
)


class VerificationError(Exception):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise VerificationError(message)


def command(arguments: list[str], **options) -> subprocess.CompletedProcess:
    return subprocess.run(arguments, check=True, capture_output=True, text=True, timeout=60, **options)


def archive_path(name: str) -> PurePosixPath:
    path = PurePosixPath(name)
    require(not path.is_absolute() and ".." not in path.parts, f"Unsafe archive path: {name}")
    return path


def safe_archive_member(member: tarfile.TarInfo, source: bool = False) -> PurePosixPath:
    path = archive_path(member.name)
    require(member.uid == 0 and member.gid == 0, f"Archive member is not root-owned: {member.name}")
    require(member.isfile() or member.isdir() or member.issym() or member.islnk(), f"Unsupported archive member: {member.name}")
    require(path.suffix.lower() not in PROPRIETARY_SUFFIXES, f"Proprietary asset bundled: {member.name}")
    require(not any(part in SECRET_DIRECTORIES for part in path.parts), f"Private directory bundled: {member.name}")
    if source:
        require(path.suffix.lower() not in SECRET_SUFFIXES, f"Credential file bundled in source: {member.name}")
        require(not (path.name == ".env" or path.name.startswith(".env.")) or path.name in {".env.example", ".env.sample"},
                f"Environment secret file bundled in source: {member.name}")
    if member.issym() or member.islnk():
        target = PurePosixPath(member.linkname)
        require(not target.is_absolute(), f"Absolute archive link: {member.name}")
        base = path.parent if member.issym() else PurePosixPath(".")
        depth = 0
        for part in (base / target).parts:
            depth += -1 if part == ".." else 0 if part == "." else 1
            require(depth >= 0, f"Archive link escapes the package: {member.name}")
    return path


def check_payload_archive(package: Path) -> int:
    process = subprocess.Popen(["dpkg-deb", "--fsys-tarfile", str(package)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    count = 0
    try:
        assert process.stdout is not None
        with tarfile.open(fileobj=process.stdout, mode="r|*") as archive:
            for member in archive:
                path = safe_archive_member(member)
                require(not path.parts or path.parts[0] == "usr", f"Package writes outside /usr: {member.name}")
                count += 1
        _, errors = process.communicate(timeout=60)
        require(process.returncode == 0, f"Cannot inspect package data: {errors.decode(errors='replace')}")
    finally:
        if process.poll() is None:
            process.kill()
            process.communicate()
    return count


def check_control_archive(package: Path) -> None:
    process = subprocess.Popen(["dpkg-deb", "--ctrl-tarfile", str(package)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        assert process.stdout is not None
        with tarfile.open(fileobj=process.stdout, mode="r|*") as archive:
            for member in archive:
                safe_archive_member(member)
                if member.name.removeprefix("./") in {"preinst", "postinst", "prerm", "postrm"}:
                    require(member.isfile() and member.mode & 0o111 != 0, f"Maintainer script is not executable: {member.name}")
        _, errors = process.communicate(timeout=60)
        require(process.returncode == 0, f"Cannot inspect package control archive: {errors.decode(errors='replace')}")
    finally:
        if process.poll() is None:
            process.kill()
            process.communicate()


def field_lines(path: Path) -> dict[str, str]:
    return dict(line.split("=", 1) for line in path.read_text().splitlines() if "=" in line and not line.startswith("#"))


def check_files(root: Path) -> None:
    for name in REQUIRED_FILES:
        require((root / name).is_file(), f"Required package file is missing: /{name}")
    for executable in EXECUTABLES:
        path = root / "usr/bin" / executable
        require(path.is_file() and os.access(path, os.X_OK), f"Required executable is missing: {executable}")
    for path in root.rglob("*"):
        require(path.resolve().is_relative_to(root), f"Extracted link escapes package: {path.relative_to(root)}")
    service = field_lines(root / "usr/share/dbus-1/services/dev.zeroday0619.service")
    require(service.get("Name") == "dev.zeroday0619", "Unexpected D-Bus service identity")
    require(service.get("Exec") == "/usr/bin/inzone-service", "D-Bus activation uses an unexpected executable")
    require(service.get("SystemdService") == "inzone-control.service", "Unexpected D-Bus systemd unit")
    control = field_lines(root / "usr/lib/systemd/user/inzone-control.service")
    require(control.get("Type") == "dbus" and control.get("BusName") == "dev.zeroday0619", "Unexpected control service identity")
    require(control.get("ExecStart") == "/usr/bin/inzone-service", "Control service uses an unexpected executable")
    automatic = field_lines(root / "usr/lib/systemd/user/inzone-profile-auto.service")
    require(automatic.get("ExecStart") in {'"/usr/bin/inzone-profile" --auto-watch', "/usr/bin/inzone-profile --auto-watch"},
            "Automatic profile service does not use the packaged CLI")
    desktop = field_lines(root / "usr/share/applications/dev.zeroday0619.desktop")
    require(desktop.get("Exec") == "inzone-gui", "Unexpected desktop executable")
    require(desktop.get("StartupWMClass") == "dev.zeroday0619", "Unexpected desktop application identity")
    require((root / "usr/lib/ladspa/inzone_dsp.so").read_bytes() == (root / "usr/share/inzone-linux/setup/native/inzone_dsp.so").read_bytes(),
            "The setup DSP plugin differs from the system plugin")


def check_manifest(root: Path) -> dict:
    manifest = json.loads((root / "usr/share/doc/inzone-linux/runtime-manifest.json").read_text())
    require(manifest.get("format") == 1, "Unsupported runtime manifest format")
    require(manifest.get("swiftRuntime") == "/usr/lib/inzone-linux/swift", "Unexpected Swift runtime location")
    require(manifest.get("qtRuntime") in {None, "/usr/lib/inzone-linux/qt"}, "Unexpected Qt runtime location")
    require(isinstance(manifest.get("files"), list) and bool(manifest["files"]), "Runtime manifest has no files")
    paths = set()
    for entry in manifest["files"]:
        name = entry["path"]
        require(isinstance(name, str) and name.startswith("/usr/"), "Runtime manifest path must be below /usr")
        path = root / archive_path(name[1:])
        require(path.resolve().is_relative_to(root) and path.is_file(), f"Runtime manifest file is missing: {name}")
        require(name not in paths, f"Duplicate runtime manifest entry: {name}")
        paths.add(name)
        require(re.fullmatch(r"[a-f0-9]{64}", entry["sha256"]) is not None, f"Invalid runtime checksum: {name}")
        require(hashlib.sha256(path.read_bytes()).hexdigest() == entry["sha256"], f"Runtime checksum mismatch: {name}")
    for directory in ("usr/lib/inzone-linux/swift", "usr/lib/inzone-linux/qt"):
        for path in (root / directory).rglob("*"):
            if path.is_file():
                require("/" + str(path.relative_to(root)) in paths, f"Untracked private runtime file: {path.relative_to(root)}")
    if manifest["qtRuntime"] is not None:
        runtime = root / "usr/lib/inzone-linux/qt"
        require(bool(list((runtime / "plugins/platforms").glob("libqwayland*.so"))), "The bundled Qt runtime has no Wayland platform plugin")
        require((runtime / "plugins/platforms/libqoffscreen.so").is_file(), "The bundled Qt runtime has no offscreen platform plugin")
        for module in ("QtQuick", "QtQuick/Window", "QtQuick/Layouts", "QtQuick/Controls", "QtQuick/Controls/Basic", "QtQuick/Templates"):
            require((runtime / "qml" / module / "qmldir").is_file(), f"Bundled QML module is missing: {module}")
    return manifest


def check_metadata(package: Path, manifest: dict) -> dict:
    fields = dict(Parser().parsestr(command(["dpkg-deb", "--field", str(package)]).stdout).items())
    require(fields.get("Package") == "inzone-linux", "Unexpected Debian package name")
    require(fields.get("Architecture") in {"amd64", "arm64"}, "Unsupported Debian package architecture")
    require(bool(re.fullmatch(r"[0-9][0-9A-Za-z.+:~\-]*", fields.get("Version", ""))), "Missing or invalid Debian package version")
    require(fields.get("Section") == "sound", "Unexpected package section")
    dependencies = set(re.findall(r"(?:^|[,|])\s*([a-z0-9][a-z0-9+.-]*)", fields.get("Depends", "")))
    required = EXPLICIT_DEPENDENCIES | (QML_DEPENDENCIES if manifest["qtRuntime"] is None else set())
    require(required <= dependencies, "Missing Debian dependencies: " + ", ".join(sorted(required - dependencies)))
    require(re.search(r"\bwireplumber\s*\(>=\s*0\.5\)", fields.get("Depends", "")) is not None,
            "The package must require WirePlumber >= 0.5")
    return fields


def check_elf_paths(root: Path) -> int:
    count = 0
    for path in sorted(root.rglob("*")):
        if not path.is_file():
            continue
        with path.open("rb") as stream:
            if stream.read(4) != b"\x7fELF":
                continue
        dynamic = command(["readelf", "--dynamic", str(path)]).stdout
        for values in re.findall(r"\((?:RPATH|RUNPATH)\).*\[([^]]*)\]", dynamic):
            for value in values.split(":"):
                require(value == "$ORIGIN" or value.startswith("$ORIGIN/"), f"Non-relative ELF runtime path in {path.relative_to(root)}: {value}")
                resolved = (path.parent / value.removeprefix("$ORIGIN").lstrip("/")).resolve()
                require(resolved.is_relative_to(root), f"ELF runtime path escapes the package: {path.relative_to(root)}")
        for dependency in re.findall(r"\(NEEDED\).*\[([^]]+)\]", dynamic):
            require("/" not in dependency, f"Absolute ELF dependency in {path.relative_to(root)}: {dependency}")
        count += 1
    require(count >= len(EXECUTABLES) + 1, "Application or DSP ELF files are missing")
    return count


def check_source_archive(root: Path) -> int:
    count = 0
    names = set()
    with tarfile.open(root / "usr/share/doc/inzone-linux/source.tar.xz", "r:xz") as archive:
        for member in archive:
            path = safe_archive_member(member, source=True)
            require(path.parts and path.parts[0] in {"inzone-linux", "third_party"}, f"Unexpected source archive root: {member.name}")
            names.add(member.name)
            if member.isfile() and member.size <= 1024 * 1024:
                stream = archive.extractfile(member)
                assert stream is not None
                beginning = stream.read(128)
                require(re.match(rb"-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----", beginning) is None,
                        f"Private key bundled in source: {member.name}")
            count += 1
    for name in ("inzone-linux/LICENSE", "inzone-linux/CMakeLists.txt", "inzone-linux/Package.swift", "third_party/qtbridge/LICENSE.txt"):
        require(name in names, f"Corresponding source is missing: {name}")
    return count


def prepare_sysroot_runtime(root: Path, sysroot: Path, environment: dict[str, str]) -> None:
    require(sysroot != Path("/"), "Use a prepared sysroot instead of the host filesystem")
    loader = sysroot / "usr/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2"
    require(loader.is_file(), "The sysroot does not contain the amd64 dynamic loader")
    require(shutil.which("patchelf") is not None, "patchelf is required for sysroot runtime validation")
    directories = (root / "usr/lib/inzone-linux/swift", root / "usr/lib/inzone-linux/qt/lib",
                   sysroot / "usr/lib/x86_64-linux-gnu", sysroot / "lib/x86_64-linux-gnu")
    library_path = ":".join(str(path) for path in directories if path.is_dir())
    for path in sorted(root.rglob("*")):
        if not path.is_file():
            continue
        with path.open("rb") as stream:
            if stream.read(4) != b"\x7fELF":
                continue
        result = command([str(loader), "--inhibit-cache", "--library-path", library_path,
                          "--list", str(path)], env=environment)
        for filename in re.findall(r"=>\s+(/\S+)\s+\(", result.stdout):
            library = Path(filename).resolve()
            require(library.is_relative_to(root) or library.is_relative_to(sysroot),
                    f"Runtime dependency escapes the package and sysroot: {library}")
    # Only the temporary extraction changes, after payload and checksum validation.
    # Executing the ELF itself keeps /proc/self/exe and relative Qt resources correct.
    for executable in EXECUTABLES:
        command(["patchelf", "--set-interpreter", str(loader), str(root / "usr/bin" / executable)])
    environment["LD_LIBRARY_PATH"] = library_path


def check_runtime(root: Path, working: Path, sysroot: Path | None = None) -> None:
    environment = dict(os.environ)
    for name in ("DISPLAY", "WAYLAND_DISPLAY", "WAYLAND_SOCKET", "QT_QPA_PLATFORM_PLUGIN_PATH", "QT_PLUGIN_PATH",
                 "QML_IMPORT_PATH", "QML2_IMPORT_PATH", "LD_LIBRARY_PATH", "LD_PRELOAD", "LD_AUDIT", "QT_SCALE_FACTOR", "QT_SCREEN_SCALE_FACTORS", "INZONE_DEBUG"):
        environment.pop(name, None)
    for name, directory in (("XDG_CONFIG_HOME", "config"), ("XDG_DATA_HOME", "data"), ("XDG_CACHE_HOME", "cache"),
                            ("XDG_STATE_HOME", "state"), ("XDG_RUNTIME_DIR", "runtime")):
        path = working / directory
        path.mkdir(mode=0o700)
        environment[name] = str(path)
    environment.update({
        "PATH": "/usr/bin:/bin", "LC_ALL": "C.UTF-8", "QT_QPA_PLATFORM": "offscreen", "QT_QUICK_BACKEND": "software",
        "DBUS_SESSION_BUS_ADDRESS": "unix:path=" + str(working / "absent-session-bus"),
        "DBUS_SYSTEM_BUS_ADDRESS": "unix:path=" + str(working / "absent-system-bus"),
    })
    if sysroot is not None:
        prepare_sysroot_runtime(root, sysroot, environment)
    # An invalid private bus address prevents GUI startup from activating the user's control service.
    for executable in EXECUTABLES:
        result = command([str(root / "usr/bin" / executable), "--help"], env=environment, cwd=working)
        require("Usage:" in result.stdout, f"The extracted {executable} did not print its usage")
    diagnostics = working / "gui-diagnostics.json"
    command([str(root / "usr/bin/inzone-gui"), "--smoke-test", "--diagnostics", str(diagnostics)], env=environment, cwd=working)
    result = json.loads(diagnostics.read_text())
    require(result.get("platformName") == "offscreen", "The extracted GUI did not select offscreen rendering")
    require(result.get("desktopFileName") == "dev.zeroday0619" and result.get("applicationName") == "dev.zeroday0619",
            "The extracted GUI application identity is incorrect")
    require(result.get("windowIconAvailable") is True and result.get("window", {}).get("exposed") is True,
            "The extracted GUI did not expose its window and application icon")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", type=Path, help="The .deb artifact to verify")
    parser.add_argument("--skip-runtime", action="store_true", help="Inspect package contents without executing extracted applications")
    parser.add_argument("--sysroot", type=Path, help="Run extracted applications with this Debian userspace and reject host library fallback")
    arguments = parser.parse_args()
    for executable in ("dpkg-deb", "readelf"):
        if not shutil.which(executable):
            parser.error(f"Required verification tool is missing: {executable}")
    try:
        package = arguments.package.resolve(strict=True)
        sysroot = arguments.sysroot.resolve(strict=True) if arguments.sysroot else None
        members = check_payload_archive(package)
        check_control_archive(package)
        with tempfile.TemporaryDirectory(prefix="inzone-debian-verification-") as temporary:
            working = Path(temporary)
            root = working / "package"
            command(["dpkg-deb", "--extract", str(package), str(root)])
            check_files(root)
            manifest = check_manifest(root)
            metadata = check_metadata(package, manifest)
            elf_count = check_elf_paths(root)
            source_count = check_source_archive(root)
            if not arguments.skip_runtime:
                check_runtime(root, working, sysroot)
        print(json.dumps({
            "package": metadata["Package"], "version": metadata["Version"], "architecture": metadata["Architecture"],
            "archiveMembers": members, "elfFiles": elf_count, "sourceFiles": source_count,
            "runtimeFiles": len(manifest["files"]), "runtimeTest": "skipped" if arguments.skip_runtime else "passed",
            "result": "passed",
        }, indent=2))
    except (OSError, ValueError, KeyError, TypeError, tarfile.TarError, VerificationError, subprocess.SubprocessError) as error:
        print(f"Debian package verification failed: {error}", file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError):
            print((error.stderr or error.stdout).rstrip(), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
