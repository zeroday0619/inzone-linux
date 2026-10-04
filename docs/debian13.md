# Debian 13 packages

Debian 13 ships Qt 6.8, while QtBridge requires Qt 6.10 or later. The Debian 13
package therefore includes a private Qt runtime. Its C, C++, and Swift targets
are compiled against a Debian 13 amd64 sysroot. The compiler and QtBridge macro
plugin run normally in the desktop session; this workflow does not use a
container, chroot, or privileged build.

## Prerequisites

The host requires CMake 3.29 or later, Ninja, Python 3.10 or later, `pkg-config`,
`dpkg-dev`, `patchelf`, and a Swift 6.3 toolchain containing Clang. The Qt SDK must
provide Qt 6.10 or later, Qt Quick, the Basic controls style, Qt SVG, and the
native Wayland and offscreen platform plugins. Use SDK binaries whose glibc
requirements are compatible with Debian 13, or build the SDK against that
sysroot. Do not point the bundled SDK option at `/usr`.

The preparation helper downloads Debian packages through a dedicated APT
configuration and verifies the signed archive indexes. It extracts payloads and
dpkg dependency metadata without executing maintainer scripts or installing
packages. It also downloads the official Qt 6.11.2 desktop SDK archives and
verifies the pinned SHA-256 values in
`packaging/debian/qt-sdk-6.11.2.json`. Preparation requires `apt-get`,
`debian-archive-keyring`, and `bsdtar` from `libarchive-tools` on the host.

```sh
python3 scripts/prepare-debian13.py /path/to/debian13-inputs
scripts/build-debian13.sh \
  /path/to/debian13-inputs/root \
  /path/to/debian13-inputs/qt/sdk \
  /path/to/swift-toolchain \
  /path/to/build-debian13
```

The Debian 13 entry points delegate to the shared suite-aware helpers. The
following preparation command is equivalent and accepts an explicit Debian
archive keyring when the host's installed keyring predates Debian 13:

```sh
python3 scripts/prepare-debian.py /path/to/debian13-inputs --suite trixie \
  --keyring /path/to/debian-archive-keyring.gpg
```

The shared `scripts/build-debian.sh` takes `trixie` before the four paths shown
above. The helpers also accept `forky`; that build uses the forky sysroot and
revision `1~forky1` while retaining the same pinned private Qt SDK. It does not
replace the native system-Qt `make deb` build.

Use `--reuse` to refresh a directory created by this helper. The ownership
marker must be present. Refresh reconstructs its managed `root/` directory from
the newest cached version of each package, so old library files cannot remain.
Do not store unrelated files in that directory. The helper uses `trixie`,
`trixie-updates`, and `trixie-security`. Debian security and
point updates can change the sysroot package versions; `debian-manifest.json`
records every downloaded package version and SHA-256. The signed APT indexes
remain under `apt/lists/`. `debian-target.json` and the sysroot's
`.inzone-debian-target.json` record the suite and architecture. The build rejects
a mismatched target, and preparation rejects reusing another suite's directory. Qt archive versions and hashes are fixed in the
repository manifest. Its upstream SHA-1 values were checked before recording
the SHA-256 pins, and the manifest records each official download URL.

An externally prepared Debian 13 amd64 sysroot must contain these development
packages and their runtime dependencies:

- `libc6-dev`, `libstdc++-14-dev`, `libsystemd-dev`, and `ladspa-sdk`.
- `libcurl4-openssl-dev`, `libgl-dev`, `libegl-dev`, `libvulkan-dev`,
  `libwayland-dev`, `libxkbcommon-dev`, and `libx11-dev`.
- The Qt SDK's external dependencies, including fontconfig, FreeType, GLib,
  D-Bus, XCB, XKB, OpenSSL, and the corresponding Wayland client libraries.

The sysroot must retain `/var/lib/dpkg/status` and the matching `info/*.list`,
`info/*.symbols`, and `info/*.shlibs` files. An export of an existing Debian 13
installation provides this metadata. When assembling a sysroot from `.deb`
archives, use the signed Debian archive indexes to verify the downloads, extract
payloads with `dpkg-deb --extract`, and retain their control metadata. Package
maintainer scripts do not need to run. Include `/lib -> usr/lib` and
`/lib64 -> usr/lib64` merged-directory links when required by the toolchain.

The build script creates `usr/lib/swift` and `usr/lib/swift_static` symlinks in
the supplied sysroot if they are absent. Existing links must select the supplied
Swift toolchain. These provide the Swift startup objects and libraries; they are
not copied into the system installation.

## Build

```sh
scripts/build-debian13.sh \
  /path/to/debian13-sysroot \
  /path/to/qt-sdk \
  /path/to/swift-toolchain \
  /path/to/build-debian13
```

The Swift toolchain argument is the directory containing `usr/bin/swiftc`.
Additional arguments are passed to CMake. `INZONE_BUILD_JOBS` controls parallel
build jobs and defaults to four. Pinned source dependencies can be downloaded by
CMake and SwiftPM; the script does not download Qt, Debian packages, Sony assets,
or firmware.

The output is `packages/inzone-linux_0.1.0-1~deb13u1_amd64.deb` below the build
directory. It includes the same application components as the native package
and adds Qt libraries, QML modules, plugins, and required SDK support libraries
under `/usr/lib/inzone-linux/qt/`.

The script sets the SDK for SwiftPM twice because its `--sdk` option controls
Clang's sysroot while Swift's frontend also needs an explicit `-sdk` argument.
C and C++ use the sysroot's GCC headers, startup objects, and standard libraries.

## Dependency and ABI checks

`packaging/debian/sysroot_shlibdeps.py` creates a build-local copy of the sysroot
package database with relocated file lists. CPack then runs `dpkg-shlibdeps`
against that database, so library versions are derived from Debian 13 symbols
rather than the build host's distribution.

Before dependency generation, the helper asks the Debian 13 dynamic loader to
resolve every packaged ELF file. It disables the loader cache and checks that
all resolved libraries belong to the package or sysroot. Missing libraries,
newer symbol requirements, and host-library fallback abort packaging.

Verify the completed artifact, including GUI and CLI execution against that
userspace:

```sh
python3 scripts/verify-debian.py \
  /path/to/build-debian13/packages/inzone-linux_0.1.0-1~deb13u1_amd64.deb \
  --sysroot /path/to/debian13-inputs/root
```

The verifier checks the original archive and bundled library hashes first. It
then changes only its temporary extracted executable copies to use the sysroot
loader. The `.deb` remains unchanged, and no files are installed on the host.

This verifies the packaged ELF dependency closure against Debian 13 userspace.
It does not boot a Debian 13 installation or exercise package maintainer scripts
with root privileges. A native Debian 13 installation test remains a separate
release acceptance step.

The bundled ICU data library can produce one Lintian warning:
`shared-library-lacks-prerequisites` for `libicudata.so.73`. This data-only library
has no `DT_NEEDED` entries. The warning is retained; the full package dependency
and runtime checks still apply.

## References

- [Debian 13 Qt development package](https://packages.debian.org/trixie/qt6-base-dev)
- [QtBridge compiler and Qt requirements](https://github.com/qt/qtbridge-swift)
- [Qt 6.11 supported platforms](https://doc.qt.io/qt-6.11/supported-platforms.html)
- [dpkg-shlibdeps](https://manpages.debian.org/trixie/dpkg-dev/dpkg-shlibdeps.1.en.html)
