# Runtime license notices

These files accompany the private runtimes shipped in the Debian package. The
packaging step performs no network requests. Each version directory contains a
manifest recording the exact upstream commit, source URL, and SHA-256 checksum
for every file. The runtime stager verifies these checksums before copying files.

## Swift 6.3.3

The notices use the `swift-6.3.3-RELEASE` commits from the official Swift
repositories. They include Foundation third-party notices and the Unicode ICU
76.1 license. The pinned FoundationICU `uvernum.h` identifies ICU 76.1; its README
identifies the Apple ICU derivation. The toolchain's own installed license is
also copied separately, including for statically linked Swift executables.

## Qt 6.11.2

The Qt license texts use the exact qtbase, qtdeclarative, and qtsvg source commits
recorded in the official Linux SDK SPDX inventories. The qtwayland texts use
the `v6.11.2` release commit. The SDK supplies ICU 73.2, whose full notices are
included separately. The installed package also includes the SDK's four SPDX
JSON inventories, preserving component copyright and attribution information.

System Qt packages retain their own notices when Qt is not bundled. A different
Swift or bundled Qt version requires a corresponding verified notice directory.
Do not replace a version directory with notices from an unrelated release.
