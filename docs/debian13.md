# Build Debian 13 packages

Debian 13 ships Qt 6.8, while QtBridge requires Qt 6.10 or later. The Debian 13
package therefore bundles Qt and compiles its C, C++, and Swift targets against
a Debian 13 amd64 sysroot. The compiler and QtBridge macro plugin run as the
normal user on the host. The build does not use a container, chroot, or
privileged project commands.

## Check prerequisites

The host needs CMake 3.29 or later, Ninja, Make, Git, Python 3.10 or later,
`pkg-config`, `dpkg-dev`, `binutils`, `patchelf`, and a Swift toolchain containing
Clang. Swift 6.3 is the minimum compiler version; the current package notices
require Swift 6.3.3. The [CI artifact verifier](ci.md#build-and-verification-steps)
requires Python 3.11 or later.

Preparation also needs `apt-get`, a current Debian archive keyring, and
`bsdtar` from `libarchive-tools`. The default keyring is supplied by
`debian-archive-keyring`.

The Qt SDK must provide Qt 6.10 or later, Qt Quick, the Basic controls style,
Qt SVG, and native Wayland and offscreen platform plugins. The helper prepares
Qt 6.11.2, which matches the included notice manifest. Another SDK version needs
verified notices for its bundled runtime. Its binaries must have glibc
requirements compatible with Debian 13, or be built against that sysroot.
Use the same SDK for compilation and packaging. The bundled SDK option must
point to a dedicated installation, not `/usr`.

## Prepare the sysroot and Qt SDK

```sh
python3 scripts/prepare-debian13.py /path/to/debian13-inputs
```

The helper uses a dedicated APT configuration to download packages from
`trixie`, `trixie-updates`, and `trixie-security`. It verifies signed archive
indexes, then extracts payloads and dpkg dependency metadata without installing
packages or executing maintainer scripts.

It also downloads the official Qt 6.11.2 desktop SDK archives and checks their
pinned SHA-256 values in `packaging/debian/qt-sdk-6.11.2.json`. That manifest
records each official download URL. The upstream SHA-1 values were checked
before the SHA-256 pins were recorded.

The Debian 13 commands are wrappers around shared helpers. If the host keyring
predates Debian 13, supply a current keyring through the equivalent command:

```sh
python3 scripts/prepare-debian.py /path/to/debian13-inputs --suite trixie \
  --keyring /path/to/debian-archive-keyring.gpg
```

### Refresh prepared inputs

Use `--reuse` only with a directory created by the helper. Its ownership marker
must be present and identify the same Debian suite. Refresh recreates the
managed `root/` directory from the newest cached version of each package.
Do not store unrelated files in the preparation directory.

Debian security and point updates can change package versions. The preparation
records its inputs in these files:

| File | Purpose |
| --- | --- |
| `debian-manifest.json` | Downloaded package versions and SHA-256 values |
| `apt/lists/` | Signed APT indexes |
| `debian-target.json` and `root/.inzone-debian-target.json` | Target suite and architecture |
| `qt/manifest.json` | Copy of the repository's fixed Qt archive versions, URLs, and hashes |

The build rejects target metadata that does not match the requested suite and
architecture. Preparation rejects reusing another suite's directory.

## Build the package

```sh
scripts/build-debian13.sh \
  /path/to/debian13-inputs/root \
  /path/to/debian13-inputs/qt/sdk \
  /path/to/swift-toolchain \
  /path/to/build-debian13
```

The Swift toolchain path must contain `usr/bin/swiftc`. Additional arguments
are passed to CMake. `INZONE_BUILD_JOBS` controls build parallelism and defaults
to four. It applies to SwiftPM and the main CMake build; nested CMake builds
retain an explicit `CMAKE_BUILD_PARALLEL_LEVEL` value if one is set.

CMake and SwiftPM may download pinned source dependencies. The build script
does not download Qt, Debian packages, Sony assets, or firmware; prepare its
inputs first.

The output is
`packages/inzone-linux_0.1.0-1~deb13u1_amd64.deb` below the build directory.
It contains the [standard application components](debian.md#choose-a-package)
plus Qt libraries, QML modules, plugins, and required SDK support libraries
under `/usr/lib/inzone-linux/qt/`.

The shared `scripts/build-debian.sh` command accepts `trixie` followed by the
same four paths. Both shared helpers also accept `forky`, which selects a forky
sysroot and package revision `1~forky1` with the same pinned private Qt SDK.
See [CI and local reproduction](ci.md) for that build. Native `make deb` uses
the build host's system Qt.

### Supply an external Debian 13 sysroot

An external amd64 sysroot must contain glibc 2.41 and these development packages
with their runtime dependencies:

- `libc6-dev`, `libstdc++-14-dev`, `libsystemd-dev`, and `ladspa-sdk`.
- `libcurl4-openssl-dev`, `libgl-dev`, `libegl-dev`, `libvulkan-dev`,
  `libwayland-dev`, `libxkbcommon-dev`, and `libx11-dev`.
- The Qt SDK's external dependencies, including fontconfig, FreeType, GLib,
  D-Bus, XCB, XKB, OpenSSL, and Wayland client libraries.

Retain `/var/lib/dpkg/status` and the matching `info/*.list`, `info/*.symbols`,
and `info/*.shlibs` files. An export of a Debian 13 installation provides this
metadata. When assembling a sysroot from `.deb` archives, verify downloads
against signed Debian archive indexes, extract them with `dpkg-deb --extract`,
and retain their control metadata. Maintainer scripts do not need to run.
Include `/lib -> usr/lib` and `/lib64 -> usr/lib64` links where required by the
toolchain.

Legacy Debian 13 sysroots without target metadata remain accepted after
the glibc version check. If target metadata is present, it must identify
`trixie` and `amd64`.

The build creates `usr/lib/swift` and `usr/lib/swift_static` symlinks inside the
sysroot when absent. Existing paths must resolve to the supplied Swift
toolchain. These links provide startup objects and libraries; the build does
not copy them into the system installation.

## Verify target compatibility

The build passes the SDK through both SwiftPM's `--sdk` option and Swift's
frontend `-sdk` argument. These select the sysroot for Clang imports and Swift
compilation respectively. C and C++ use the sysroot's GCC headers, startup
objects, and standard libraries.

`packaging/debian/sysroot_shlibdeps.py` makes a build-local copy of the sysroot
package database with relocated file lists. CPack runs `dpkg-shlibdeps` against
that database to derive dependencies from Debian 13 symbols. Before dependency
generation, the helper uses the Debian 13 dynamic loader with its cache disabled
to resolve every packaged ELF file. Missing libraries, newer symbol
requirements, or resolution outside the package and sysroot abort packaging.

Verify the completed package, including GUI and CLI execution with the target
loader and libraries:

```sh
python3 scripts/verify-debian.py \
  /path/to/build-debian13/packages/inzone-linux_0.1.0-1~deb13u1_amd64.deb \
  --sysroot /path/to/debian13-inputs/root
```

The verifier checks the original archive and bundled library hashes before
changing temporary executable copies to use the sysroot loader. It leaves the
`.deb` unchanged and installs no files on the host.

The bundled data-only `libicudata.so.73` has no `DT_NEEDED` entries and can
produce a Lintian `shared-library-lacks-prerequisites` warning. The warning is
retained, and the package still undergoes dependency and runtime checks.

These checks establish the packaged ELF dependency closure and execution
against Debian 13 userspace. They do not boot a Debian 13 desktop or run
privileged maintainer scripts. Native installation and removal remain release
acceptance checks. See the [validation record](debian.md#validation-record) for
completed tests and their limits.

## References

- [Debian 13 Qt development package](https://packages.debian.org/trixie/qt6-base-dev)
- [QtBridge compiler and Qt requirements](https://github.com/qt/qtbridge-swift)
- [Qt 6.11 supported platforms](https://doc.qt.io/qt-6.11/supported-platforms.html)
- [dpkg-shlibdeps](https://manpages.debian.org/trixie/dpkg-dev/dpkg-shlibdeps.1.en.html)
