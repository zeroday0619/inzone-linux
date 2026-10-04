# Debian packages

## Choose a package

| Build | Target libraries | Qt runtime | Instructions |
| --- | --- | --- | --- |
| Native | Libraries from the Debian build host | System Qt 6.10 or later | [Build a native package](#build-a-native-package) |
| Debian 13 (`trixie`) | Debian 13 sysroot | Bundled Qt 6.11.2 | [Debian 13 build](debian13.md) |
| Debian testing (`forky`) | Forky sysroot | Bundled Qt 6.11.2 | [CI and local reproduction](ci.md) |

All variants use the package name `inzone-linux` and cannot be installed
together. Each contains the GUI, CLI, setup utility, session D-Bus service,
LADSPA plugin, udev rule, systemd user units, setup templates, and matching Swift
runtime. Installed applications do not require the Swift compiler.

The [GitHub Actions workflow](ci.md) builds the two sysroot variants on an Ubuntu
runner. A Debian 13 package must link against Debian 13 libraries; a native
package built against newer host libraries does not establish Debian 13
compatibility.

## Build a native package

Install the [GUI development dependencies](gui.md#build-and-install-from-source),
`dpkg-dev`, `binutils`, `patchelf`, and Python 3.10 or later. The GUI requires
Swift 6.3 or later. The packaged runtime notice manifest currently covers Swift
6.3.3. Use that version unless a verified notice manifest has been added
for another runtime. The CI artifact verifier additionally requires Python
3.11 or later.

Run the build as the desktop user:

```sh
make deb SWIFT=/path/to/swift/toolchain/usr/bin/swift
```

The output directory is `build/debian/packages/`. Set `DEB_BUILD_DIRECTORY` to
change it, or pass additional CMake options through `DEB_CMAKE_FLAGS`. The
`debian` CMake preset configures the same build. Select the Swift compiler
explicitly if the default `swift` command belongs to another application.

CMake and SwiftPM may fetch pinned source dependencies. For an offline build,
prepare their caches and set `FETCHCONTENT_SOURCE_DIR_QTBRIDGE` if needed. The
package build does not fetch Sony assets.

Bundled Qt builds must compile and package the same SDK because QtBridge uses
private Qt interfaces. The included Qt notice manifest covers 6.11.2; another
bundled version requires verified notices for that version.

## Install and initialize user settings

### Migrate an existing source installation

Commands in `~/.local/bin` and user D-Bus activation files can take precedence
over package files. Before migration, check `command -v inzone-gui`,
`command -v inzone-profile`, and the user service's `ExecStart`. Back up local
files and remove only obsolete application-specific overrides when selecting
the system installation. The package does not delete user files.

### Install the package

```sh
sudo apt install ./inzone-linux_VERSION_ARCH.deb
```

Reconnect the USB transceiver after the first installation to apply the new
udev access rule. Package upgrades preserve user configuration. Maintainer
scripts reload udev rules but do not initialize user homes, download assets,
enable services, or restart desktop audio.

### Prepare assets and start the GUI

Run setup as the desktop user without `sudo`. Choose exactly one asset source.
To reuse a prepared checkout:

```sh
inzone-tools setup --assets-from /path/to/prepared/inzone-linux
```

That directory must contain `assets/sony-eq-tables.json`,
`assets/sony-presets.json`, and the required decoder inputs under
`analysis/payload/`.

To download and prepare the pinned INZONE Hub asset inputs in the user's cache:

```sh
inzone-tools setup --download
```

This mode requires 7-Zip and the project's .NET/ILSpy extraction prerequisites.
Setup downloads assets only when `--download` is explicit. Firmware support is
read-only.

Setup uses the existing installer, preserves user state, and points automation
at the package-managed executable. It does not write system files or restart
audio. After setup:

```sh
systemctl --user daemon-reload
systemctl --user enable --now inzone-filter-chain.service
inzone-gui
```

In the GUI, select the desired profile and choose **Apply profile**. This
restarts WirePlumber and the filter service to activate the generated routing
configuration. Starting the filter service alone does not reload an already
running WirePlumber instance.

## Inspect a package

```sh
dpkg-deb --info inzone-linux_VERSION_ARCH.deb
dpkg-deb --contents inzone-linux_VERSION_ARCH.deb
lintian inzone-linux_VERSION_ARCH.deb
```

### Installed files

| Path | Content |
| --- | --- |
| `/usr/bin/inzone-{gui,profile,tools,service}` | Application executables |
| `/usr/lib/inzone-linux/swift/` | Required Swift runtime libraries |
| `/usr/lib/inzone-linux/qt/` | Qt runtime in the bundled variants |
| `/usr/lib/ladspa/inzone_dsp.so` | Embedded Swift DSP plugin |
| `/usr/lib/systemd/user/` | Control, automation, and filter-chain services |
| `/usr/share/inzone-linux/` | QML and setup resources |
| `/usr/share/doc/inzone-linux/` | Copyright, runtime manifest, and corresponding source |

`dpkg-shlibdeps` generates ELF dependencies. The package declares QML modules
and external audio commands explicitly. ELF runtime paths are relative to each
file and must not reference a developer's home or build directory.

The runtime manifest records hashes of bundled libraries. `source.tar.xz`
contains the application, QtBridge, and Swift package dependency sources.
QtBridge has per-file LGPL-3.0-only and GPL-3.0-only terms, and the package
includes its upstream license texts. A bundled Qt SDK retains its own license
terms and source-distribution requirements.

See the [CPack DEB generator](https://cmake.org/cmake/help/latest/cpack_gen/deb.html)
and [Debian file policy](https://www.debian.org/doc/debian-policy/ch-files.html)
for the packaging format and filesystem requirements.

## Validation record

The following checks ran locally on 2026-10-04 for amd64 with Swift 6.3.3 and
Qt 6.11.2.

| Context | Result |
| --- | --- |
| Native forky/sid and Debian 13 packages | Payload, ownership, runtime hashes, executable help, and extracted GUI smoke checks passed. Debian 13 dependency and execution checks used its loader and libraries. |
| Initial installation/setup tests with prepared assets | 42 tests passed. |
| GUI and D-Bus CTest subset | 7 tests passed. |
| Local CI setup test run without Sony assets | 46 tests reported: 28 passed and 18 skipped; no failures. |
| Local CI package steps for bundled `trixie` and `forky` | Package and target-runtime verification passed. APT installation simulations passed against the target repositories. |
| Lintian | The native package had no errors or warnings. Each bundled Qt variant had no errors and one `shared-library-lacks-prerequisites` warning for `libicudata.so.73`. This data-only library has no `DT_NEEDED` entries. |

These checks did not install packages on the host or boot a Debian 13 desktop.
Native Debian 13 installation, removal, and privileged maintainer-script
execution remain release acceptance checks. The GitHub-hosted workflow has
not been run as part of this validation record.
