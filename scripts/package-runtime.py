#!/usr/bin/env python3
"""Stage private Swift and optional Qt runtimes for an INZONE Debian package."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys


NEEDED_PATTERN = re.compile(r"\(NEEDED\).*\[([^]]+)\]")
IMPORT_PATTERN = re.compile(r"^\s*(?:default\s+)?(?:import|depends)\s+([A-Za-z][A-Za-z0-9_.]*)", re.MULTILINE)
SYSTEM_LIBRARIES = re.compile(
    r"^(?:ld-linux.*|lib(?:c|m|dl|pthread|rt|resolv|gcc_s|stdc\+\+|EGL|GL|GLX|OpenGL|GLdispatch|drm|gbm))\.so(?:\..*)?$"
)
SWIFT_LIBRARIES = re.compile(r"^lib(?:swift.*|Foundation.*|_FoundationICU|dispatch|BlocksRuntime)\.so$")
PLUGIN_PATTERNS = {
    "platforms": ("libqwayland*.so", "libqoffscreen.so", "libqxcb.so"),
    "platforminputcontexts": ("libcomposeplatforminputcontextplugin.so", "libibusplatforminputcontextplugin.so"),
    "imageformats": ("libqsvg.so",),
    "iconengines": ("libqsvgicon.so",),
    "wayland-decoration-client": ("lib*.so",),
    "wayland-graphics-integration-client": ("lib*.so",),
    "wayland-shell-integration": ("lib*.so",),
    "xcbglintegrations": ("lib*.so",),
    "egldeviceintegrations": ("lib*.so",),
}
QML_MODULES = {
    "QML", "QtQml", "QtQml.Models", "QtQml.WorkerScript", "QtQuick",
    "QtQuick.Window", "QtQuick.Layouts", "QtQuick.Templates",
    "QtQuick.Controls", "QtQuick.Controls.Basic", "QtQuick.Controls.impl",
    "QtQuick.Controls.Basic.impl",
}


def run(*arguments: str) -> str:
    return subprocess.check_output(arguments, text=True, stderr=subprocess.PIPE)


def is_elf(path: Path) -> bool:
    if not path.is_file():
        return False
    with path.open("rb") as stream:
        return stream.read(4) == b"\x7fELF"


def needed_libraries(path: Path) -> list[str]:
    return NEEDED_PATTERN.findall(run("readelf", "-d", str(path)))


def origin_path(binary: Path, directory: Path) -> str:
    relative = os.path.relpath(directory, binary.parent)
    return "$ORIGIN" if relative == "." else f"$ORIGIN/{relative}"


class RuntimeStager:
    def __init__(self, staging_root: Path, swift_runtime: Path, qt_prefix: Path | None):
        self.root = staging_root.resolve(strict=True)
        if self.root == Path("/") or not (self.root / "usr/bin/inzone-gui").is_file():
            raise ValueError("The staging root must contain usr/bin/inzone-gui and cannot be the filesystem root.")
        self.swift_source = swift_runtime.resolve(strict=True)
        self.swift_destination = self.root / "usr/lib/inzone-linux/swift"
        self.qt_destination = self.root / "usr/lib/inzone-linux/qt"
        self.documentation = self.root / "usr/share/doc/inzone-linux"
        self.qt_prefix = qt_prefix.resolve(strict=True) if qt_prefix else None
        self.qt_library_directories: list[Path] = []
        self.copied: set[Path] = set()
        self.system_dependencies: set[str] = set()
        self.notices = Path(__file__).resolve().parent.parent / "packaging/licenses"
        if self.qt_prefix:
            if self.qt_prefix in (Path("/"), Path("/usr"), Path("/usr/local")):
                raise ValueError("--qt-prefix must identify a dedicated Qt installation, not a system prefix.")
            self.qt_library_directories = [self.qt_prefix / "lib", self.qt_prefix / "lib64"]
            self.qt_library_directories.extend(sorted((self.qt_prefix / "lib").glob("*-linux-gnu")))

    def destination(self, path: Path) -> Path:
        # Every write stays inside the staging tree, including when a parent is a symlink.
        if not path.resolve().is_relative_to(self.root):
            raise ValueError(f"A staging path escapes the package root: {path}")
        return path

    def copy(self, source: Path, destination: Path) -> Path:
        self.destination(destination)
        destination.parent.mkdir(parents=True, exist_ok=True)
        if destination.is_symlink():
            destination.unlink()
        shutil.copyfile(source.resolve(strict=True), destination)
        destination.chmod(0o644)
        self.copied.add(destination)
        return destination

    def copy_module_files(self, source: Path, destination: Path) -> list[Path]:
        files: list[Path] = []
        for entry in sorted(source.iterdir()):
            if entry.is_dir():
                if entry.name in ("designer", "tooling"):
                    continue
                # Child QML modules are visited through their own import declarations.
                if not (entry / "qmldir").is_file():
                    files.extend(self.copy_module_files(entry, destination / entry.name))
            elif entry.is_file():
                files.append(self.copy(entry, destination / entry.name))
        return files

    def qt_resource_directory(self, name: str) -> Path:
        assert self.qt_prefix is not None
        candidates = [self.qt_prefix / name]
        candidates.extend(directory / "qt6" / name for directory in self.qt_library_directories)
        for candidate in candidates:
            if candidate.is_dir():
                return candidate
        raise ValueError(f"The Qt installation is missing its {name} directory.")

    def stage_notices(self, component: str, version: str) -> None:
        source = self.notices / f"{component}-{version}"
        manifest_path = source / "manifest.json"
        if not manifest_path.is_file():
            raise ValueError(f"Verified {component} {version} license notices are missing from {source}.")
        manifest = json.loads(manifest_path.read_text())
        if manifest["version"] != version:
            raise ValueError(f"The {component} license notice version does not match {version}.")
        for entry in manifest["files"]:
            file = source / entry["path"]
            if not file.resolve().is_relative_to(source.resolve()):
                raise ValueError("A license manifest path escapes its source directory.")
            if hashlib.sha256(file.read_bytes()).hexdigest() != entry["sha256"]:
                raise ValueError(f"A pinned license notice failed its SHA-256 check: {file}.")
            self.copy(file, self.documentation / "licenses" / component / entry["path"])
        self.copy(manifest_path, self.documentation / "licenses" / component / "manifest.json")

    def stage_qt_notices(self) -> None:
        assert self.qt_prefix is not None
        version_files = [directory / "cmake/Qt6Core/Qt6CoreConfigVersionImpl.cmake" for directory in self.qt_library_directories]
        version = None
        for file in version_files:
            if file.is_file():
                match = re.search(r'set\(PACKAGE_VERSION "([0-9.]+)"\)', file.read_text())
                if match:
                    version = match[1]
                    break
        if not version:
            raise ValueError("The bundled Qt version could not be read from Qt6CoreConfigVersionImpl.cmake.")
        self.stage_notices("qt", version)
        for module in ("qtbase", "qtdeclarative", "qtsvg", "qtwayland"):
            source = self.qt_prefix / "sbom" / f"{module}-{version}.spdx.json"
            if not source.is_file():
                raise ValueError(f"The official Qt SDK copyright and attribution inventory is missing: {source}.")
            self.copy(source, self.documentation / "licenses/qt/sbom" / source.name)

    def stage_swift_notices(self) -> None:
        swift_prefix = self.swift_source.parents[2]
        version_text = run(str(swift_prefix / "bin/swiftc"), "--version")
        match = re.search(r"Swift version ([0-9.]+)", version_text)
        if not match:
            raise ValueError("The Swift compiler version could not be identified for runtime license notices.")
        self.stage_notices("swift", match[1])
        swift_license = swift_prefix / "share/swift/LICENSE.txt"
        if not swift_license.is_file():
            raise ValueError(f"The Swift toolchain license was not found at {swift_license}.")
        self.copy(swift_license, self.documentation / "licenses/swift/LICENSE.txt")

    def stage_qt_resources(self) -> None:
        qml_source = self.qt_resource_directory("qml")
        modules = set(QML_MODULES)
        pending = sorted(modules)
        while pending:
            module = pending.pop()
            relative = Path(*module.split("."))
            source = qml_source / relative
            if not (source / "qmldir").is_file():
                raise ValueError(f"The Qt installation is missing QML module {module}.")
            destination = self.qt_destination / "qml" / relative
            files = self.copy_module_files(source, destination)
            for file in files:
                if file.suffix != ".qml" and file.name != "qmldir":
                    continue
                for dependency in IMPORT_PATTERN.findall(file.read_text()):
                    if dependency not in modules:
                        modules.add(dependency)
                        pending.append(dependency)

        plugins_source = self.qt_resource_directory("plugins")
        for category, patterns in PLUGIN_PATTERNS.items():
            for pattern in patterns:
                for source in sorted((plugins_source / category).glob(pattern)):
                    self.copy(source, self.qt_destination / "plugins" / category / source.name)
        if not list((self.qt_destination / "plugins/platforms").glob("libqwayland*.so")):
            raise ValueError("The bundled Qt installation must include a native Wayland platform plugin.")
        if not (self.qt_destination / "plugins/platforms/libqoffscreen.so").is_file():
            raise ValueError("The bundled Qt installation must include the offscreen validation plugin.")
        self.stage_qt_notices()
        assert self.qt_prefix is not None
        for name in ("licenses", "Licenses"):
            source = self.qt_prefix / name
            if source.is_dir():
                for file in source.rglob("*"):
                    if file.is_file():
                        self.copy(file, self.documentation / "licenses/qt" / file.relative_to(source))

    def stage_dependency(self, name: str) -> Path | None:
        if Path(name).name != name:
            raise ValueError(f"An ELF DT_NEEDED entry contains a build path: {name}")
        if SYSTEM_LIBRARIES.match(name):
            return None
        swift_library = self.swift_source / name
        if swift_library.is_file():
            destination = self.swift_destination / name
            if destination in self.copied:
                return destination
            return self.copy(swift_library, destination)
        if SWIFT_LIBRARIES.match(name):
            raise ValueError(f"The Swift runtime is missing required library {name}.")
        if self.qt_prefix:
            for directory in self.qt_library_directories:
                source = directory / name
                if source.is_file():
                    destination = self.qt_destination / "lib" / name
                    if destination in self.copied:
                        return destination
                    return self.copy(source, destination)
            if name.startswith("libQt6"):
                raise ValueError(f"The Qt installation is missing required library {name}.")
        return None

    def stage(self) -> dict:
        if self.qt_prefix:
            self.stage_qt_resources()
        binaries = sorted({path.resolve() for path in self.root.rglob("*") if is_elf(path)})
        pending = list(binaries)
        visited: set[Path] = set()
        while pending:
            binary = pending.pop()
            self.destination(binary)
            if binary in visited:
                continue
            visited.add(binary)
            for library in needed_libraries(binary):
                private_library = self.stage_dependency(library)
                if private_library:
                    pending.append(private_library)
                else:
                    self.system_dependencies.add(library)

        for binary in sorted(visited):
            dependencies = needed_libraries(binary)
            # Static Swift executables need no private search path. Removing their old
            # RUNPATH prevents the package from retaining the build toolchain location.
            search_directories = [self.swift_destination]
            if self.qt_prefix:
                search_directories.append(self.qt_destination / "lib")
            if binary.parent != self.root / "usr/bin":
                search_directories.insert(0, binary.parent)
            paths = list(dict.fromkeys(origin_path(binary, path) for path in search_directories if path.is_dir()))
            has_private_dependency = any((directory / library).is_file() for directory in search_directories for library in dependencies)
            current_path = run("patchelf", "--print-rpath", str(binary)).strip()
            if paths and has_private_dependency:
                desired_path = ":".join(paths)
                if current_path != desired_path:
                    run("patchelf", "--set-rpath", desired_path, str(binary))
            elif current_path:
                run("patchelf", "--remove-rpath", str(binary))
            run("strip", "--strip-unneeded", str(binary))
            runtime_path = run("patchelf", "--print-rpath", str(binary)).strip()
            if any(not entry.startswith("$ORIGIN") for entry in runtime_path.split(":") if entry):
                raise ValueError(f"An absolute runtime path remains in {binary}.")

        self.stage_swift_notices()
        manifest = {
            "format": 1,
            "swiftRuntime": "/usr/lib/inzone-linux/swift",
            "qtRuntime": "/usr/lib/inzone-linux/qt" if self.qt_prefix else None,
            "systemLibraries": sorted(self.system_dependencies),
            "files": [
                {"path": "/" + str(path.relative_to(self.root)), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
                for path in sorted(self.copied)
            ],
        }
        manifest_path = self.destination(self.documentation / "runtime-manifest.json")
        manifest_path.parent.mkdir(parents=True, exist_ok=True)
        manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
        manifest_path.chmod(0o644)
        return manifest


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--staging-root", required=True, type=Path)
    parser.add_argument("--swift-runtime", required=True, type=Path)
    parser.add_argument("--qt-prefix", type=Path)
    arguments = parser.parse_args()
    for command in ("readelf", "patchelf", "strip"):
        if not shutil.which(command):
            parser.error(f"Required packaging tool was not found: {command}")
    try:
        manifest = RuntimeStager(arguments.staging_root, arguments.swift_runtime, arguments.qt_prefix).stage()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"Runtime packaging failed: {error}", file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError) and error.stderr:
            print(error.stderr.rstrip(), file=sys.stderr)
        return 1
    print(f"Staged {len(manifest['files'])} runtime and license files.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
