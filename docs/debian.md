# Debian binary packages

## Package variants

`make deb` builds an `inzone-linux` binary package for the distribution used to
compile it. The native variant uses the distribution's Qt 6.10 or later and
includes the matching Swift runtime privately. The Debian 13 variant uses a
Debian 13 sysroot and a compatible Qt SDK bundled privately with the application;
a package linked against newer host libraries is not a Debian 13 build.

Both variants contain the desktop, CLI, setup utility, session D-Bus service,
LADSPA plugin, udev rule, systemd user units, and setup templates. They share the
package name and cannot be installed together. Package upgrades preserve user
configuration. Maintainer scripts reload udev rules but do not initialize user
homes, download assets, enable services, or restart desktop audio.

See [Debian 13 build preparation](debian13.md) for the stable variant.

[GitHub Actions](ci.md) builds `trixie` and `forky` amd64 packages against their
respective sysroots. Both automated variants bundle Qt 6.11.2 so they can build
on the standard Ubuntu runner. The native build below uses the host's system Qt.

## Native build

Prerequisites are the GUI development dependencies, Swift 6.3 or later,
`dpkg-dev`, `binutils`, `patchelf`, and Python 3. The included license manifest
currently covers Swift 6.3.3 and bundled Qt 6.11.2; other runtime versions require
a matching verified notice manifest. The build and bundled Qt SDK must be the
same installation because QtBridge uses private Qt interfaces. Build as the desktop user:

```sh
make deb SWIFT=/path/to/swift/toolchain/usr/bin/swift
```

Packages are written to `build/debian/packages/`. `DEB_BUILD_DIRECTORY` changes
the build directory, and `DEB_CMAKE_FLAGS` accepts additional CMake arguments.
The equivalent CMake preset is `debian`; select the Swift compiler explicitly
when the default `swift` command belongs to another application.

The package build does not fetch Sony assets. CMake and SwiftPM may fetch pinned
source dependencies during the build. To build offline, prepare those caches
beforehand and supply `FETCHCONTENT_SOURCE_DIR_QTBRIDGE` if needed.

## Installation and user setup

```sh
sudo apt install ./inzone-linux_VERSION_ARCH.deb
inzone-tools setup --assets-from /path/to/prepared/inzone-linux
systemctl --user daemon-reload
systemctl --user enable --now inzone-filter-chain.service
inzone-gui
```

Reconnect the USB transceiver after the first installation so the new udev
access rule applies to the device.

The prepared asset directory must contain `assets/sony-eq-tables.json`,
`assets/sony-presets.json`, and the required decoder inputs under
`analysis/payload/`. Existing source installations can reuse their prepared
checkout. Setup uses the existing validated installer, preserves user state,
and points automation at the package-managed executable. Run setup without
`sudo`; it does not write system files or restart audio.

An explicit `inzone-tools setup --download` prepares the pinned INZONE Hub asset
inputs in the user's cache before setup. This requires 7-Zip and the existing
.NET/ILSpy extraction prerequisites. Downloads occur only on that explicit
command. Firmware updating is unsupported.

After a source installation, commands in `~/.local/bin` and user D-Bus activation
files can take precedence over package files. Check `command -v inzone-gui`,
`command -v inzone-profile`, and the user service's `ExecStart` before migration.
Back up local files and remove only obsolete application-specific overrides
when choosing the system installation. The package does not delete user files.

## Runtime layout and verification

| Path | Content |
| --- | --- |
| `/usr/bin/inzone-{gui,profile,tools,service}` | Application executables |
| `/usr/lib/inzone-linux/swift/` | Required Swift runtime libraries |
| `/usr/lib/inzone-linux/qt/` | Optional private Qt SDK runtime |
| `/usr/lib/ladspa/inzone_dsp.so` | Embedded Swift DSP plugin |
| `/usr/lib/systemd/user/` | Control, automation, and filter-chain services |
| `/usr/share/inzone-linux/` | QML and setup resources |
| `/usr/share/doc/inzone-linux/` | Copyright, runtime manifest, and corresponding source |

ELF dependencies are generated with `dpkg-shlibdeps`; QML modules and external
audio commands are declared explicitly. Runtime paths are relative to each ELF
file and must not reference a developer's home or build directory. The Swift
compiler is not needed to run an installed package.

Inspect an artifact before installation:

```sh
dpkg-deb --info inzone-linux_VERSION_ARCH.deb
dpkg-deb --contents inzone-linux_VERSION_ARCH.deb
lintian inzone-linux_VERSION_ARCH.deb
```

The private runtime manifest records bundled library hashes. The corresponding
application, QtBridge, and Swift package dependency sources are included in
`source.tar.xz`. QtBridge has per-file LGPL-3.0-only and GPL-3.0-only terms;
upstream license texts are included. A bundled Qt SDK retains its own license
terms and source-distribution requirements.

References: [CPack DEB generator](https://cmake.org/cmake/help/latest/cpack_gen/deb.html)
and [Debian file policy](https://www.debian.org/doc/debian-policy/ch-files.html).

## Validation record

Validated on 2026-10-04 for amd64 with Swift 6.3.3 and Qt 6.11.2:

- Native forky/sid and Debian 13 packages passed payload, ownership, runtime
  checksum, executable help, and extracted GUI smoke checks.
- The Debian 13 package passed dependency closure checks and executable tests
  using Debian 13's loader and libraries. APT installation simulations passed
  against the corresponding distribution repositories.
- Installation/setup tests passed (42 tests), and the existing GUI/D-Bus CTest
  subset passed (7 tests).
- Native Lintian reported no errors or warnings. Debian 13 Lintian reported no
  errors and one `shared-library-lacks-prerequisites` warning for the SDK's
  data-only `libicudata.so.73`, which has no `DT_NEEDED` entries.

These checks did not install packages on the host or boot a Debian 13 desktop.
Native Debian 13 installation, removal, and privileged maintainer-script
execution remain separate release acceptance checks.
