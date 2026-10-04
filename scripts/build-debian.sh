#!/bin/sh
# Build outside a container while linking exclusively against the selected Debian sysroot.
set -eu

usage() {
    printf '%s\n' 'Usage: build-debian.sh SUITE SYSROOT QT_PREFIX SWIFT_TOOLCHAIN BUILD_DIRECTORY [CMAKE_ARGUMENT ...]' \
        'SUITE must be trixie or forky.' \
        'SYSROOT must contain matching Debian amd64 development files and a dpkg database.' \
        'QT_PREFIX must contain a compatible Qt 6.10+ SDK with Wayland and QML.' \
        'SWIFT_TOOLCHAIN is the toolchain directory containing usr/bin/swiftc.'
}
if [ "$#" -lt 5 ]; then
    usage >&2
    exit 2
fi
if [ "$(id -u)" -eq 0 ]; then
    printf '%s\n' 'Run this build as the desktop user.' >&2
    exit 1
fi
suite=$1
case "$suite" in
    trixie) release=1~deb13u1; toolchain_label=debian13 ;;
    forky) release=1~forky1; toolchain_label=debian-forky ;;
    *) usage >&2; exit 2 ;;
esac
shift
build_jobs=${INZONE_BUILD_JOBS:-4}
case "$build_jobs" in ''|*[!0-9]*|0) printf '%s\n' 'INZONE_BUILD_JOBS must be a positive integer.' >&2; exit 2;; esac
export CMAKE_BUILD_PARALLEL_LEVEL="${CMAKE_BUILD_PARALLEL_LEVEL:-$build_jobs}"
sysroot=$(realpath "$1")
qt_prefix=$(realpath "$2")
swift_toolchain=$(realpath "$3")
build_directory=$(realpath -m "$4")
shift 4
repository=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
for path in "$sysroot" "$qt_prefix" "$swift_toolchain" "$build_directory"; do
    case "$path" in *';'*|*'"'*|*\\*|*' '*) printf '%s\n' 'Build paths cannot contain spaces, semicolons, quotes, or backslashes.' >&2; exit 2;; esac
done
if [ "$sysroot" = / ] || [ ! -f "$sysroot/usr/include/features.h" ] ||
   [ ! -f "$sysroot/var/lib/dpkg/status" ] || [ ! -x "$swift_toolchain/usr/bin/swiftc" ] ||
   [ ! -f "$qt_prefix/lib/cmake/Qt6/Qt6Config.cmake" ]; then
    printf '%s\n' 'The prepared sysroot, Qt SDK, or Swift toolchain is incomplete.' >&2
    exit 1
fi
python3 - "$sysroot" "$suite" <<'PYTHON'
import json
from pathlib import Path
import subprocess
import sys

root = Path(sys.argv[1])
suite = sys.argv[2]
metadata = root / ".inzone-debian-target.json"
if metadata.is_file():
    expected = {"format": 1, "suite": suite, "architecture": "amd64"}
    if json.loads(metadata.read_text()) != expected:
        raise SystemExit("The prepared sysroot metadata does not match the requested Debian suite and architecture.")
elif suite != "trixie":
    raise SystemExit("The sysroot has no suite metadata; prepare it with prepare-debian.py.")
# Legacy Debian 13 exports did not include the preparation metadata.
version = subprocess.check_output(
    ["dpkg-query", "--admindir=" + str(root / "var/lib/dpkg"), "-W", "-f=${Version}", "libc6:amd64"], text=True)
if suite == "trixie" and not version.startswith("2.41-"):
    raise SystemExit("Expected Debian 13 glibc 2.41, found " + version + ".")
PYTHON
mkdir -p "$build_directory"
for runtime in swift swift_static; do
    target="$sysroot/usr/lib/$runtime"
    if [ -e "$target" ] || [ -L "$target" ]; then
        if [ "$(realpath "$target")" != "$(realpath "$swift_toolchain/usr/lib/$runtime")" ]; then
            printf 'The sysroot runtime path belongs to another toolchain: %s\n' "$target" >&2
            exit 1
        fi
    else
        ln -s "$swift_toolchain/usr/lib/$runtime" "$target"
    fi
done
export PATH="$swift_toolchain/usr/bin:$PATH"
export PKG_CONFIG_SYSROOT_DIR="$sysroot"
export PKG_CONFIG_LIBDIR="$sysroot/usr/lib/x86_64-linux-gnu/pkgconfig:$sysroot/usr/share/pkgconfig"
unset CC CXX LD AR CFLAGS CXXFLAGS LDFLAGS PKG_CONFIG_PATH
python3 "$repository/packaging/debian/sysroot_shlibdeps.py" --sysroot "$sysroot" \
    --database "$build_directory/dpkg-admin" --prepare
cat > "$build_directory/${toolchain_label}-toolchain.cmake" <<EOF
set(CMAKE_C_COMPILER "$swift_toolchain/usr/bin/clang")
set(CMAKE_CXX_COMPILER "$swift_toolchain/usr/bin/clang++")
set(CMAKE_Swift_COMPILER "$swift_toolchain/usr/bin/swiftc")
set(CMAKE_SYSROOT "$sysroot")
set(CMAKE_C_FLAGS_INIT "--gcc-toolchain=$sysroot/usr")
set(CMAKE_CXX_FLAGS_INIT "--gcc-toolchain=$sysroot/usr")
set(CMAKE_Swift_FLAGS_INIT "-sdk $sysroot -Xcc --gcc-toolchain=$sysroot/usr")
set(CMAKE_EXE_LINKER_FLAGS_INIT "-Wl,-rpath-link,$sysroot/usr/lib/x86_64-linux-gnu")
set(CMAKE_FIND_ROOT_PATH "$qt_prefix;$sysroot")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE BOTH)
EOF
cat > "$build_directory/${toolchain_label}-shlibdeps" <<EOF
#!/bin/sh
exec python3 "$repository/packaging/debian/sysroot_shlibdeps.py" --sysroot "$sysroot" --database "$build_directory/dpkg-admin" -- "\$@"
EOF
chmod 755 "$build_directory/${toolchain_label}-shlibdeps"
cat > "$build_directory/${toolchain_label}-cpack.cmake" <<EOF
set(SHLIBDEPS_EXECUTABLE "$build_directory/${toolchain_label}-shlibdeps")
EOF
cmake -S "$repository" -B "$build_directory" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr \
    -DCMAKE_TOOLCHAIN_FILE="$build_directory/${toolchain_label}-toolchain.cmake" \
    -DCMAKE_PREFIX_PATH="$qt_prefix" -DBUILD_TESTING=OFF \
    -DINZONE_DEBIAN_PACKAGE=ON -DINZONE_DEBIAN_RELEASE="$release" \
    -DINZONE_BUNDLED_QT_PREFIX="$qt_prefix" \
    -DCPACK_PROJECT_CONFIG_FILE="$build_directory/${toolchain_label}-cpack.cmake" \
    "-DINZONE_SWIFTPM_FLAGS=--jobs;$build_jobs;--sdk;$sysroot;-Xswiftc;-sdk;-Xswiftc;$sysroot;-Xcc;--gcc-toolchain=$sysroot/usr" \
    "-DINZONE_NATIVE_MAKE_ARGUMENTS=CC=$swift_toolchain/usr/bin/clang --sysroot=$sysroot --gcc-toolchain=$sysroot/usr;SWIFT_DSP_FLAGS=-O -whole-module-optimization -sdk $sysroot -Xcc --gcc-toolchain=$sysroot/usr" \
    "$@"
cmake --build "$build_directory" --parallel "$build_jobs"
cpack --config "$build_directory/CPackConfig.cmake" -G DEB
