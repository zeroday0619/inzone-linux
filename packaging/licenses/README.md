# Runtime license notices

The Debian runtime stager copies the notices in this directory into the package.
Each version has a `manifest.json` containing the upstream revision, source URL,
and SHA-256 for every recorded file. The stager verifies these hashes before
copying notices and makes no network requests during this step.

## Included versions

| Runtime | Notice sources | Additional records copied during packaging |
| --- | --- | --- |
| Swift 6.3.3 | Official `swift-6.3.3-RELEASE` revisions, Foundation third-party notices, and the ICU 76.1 license | The selected toolchain's installed license, including for statically linked Swift executables |
| Qt 6.11.2 | qtbase, qtdeclarative, and qtsvg revisions from the official SDK SPDX inventories; the qtwayland `v6.11.2` revision; ICU 73.2 notices | The SDK's four SPDX JSON inventories with component copyright and attribution records |

Swift's FoundationICU and the Qt SDK use different ICU versions. The pinned
FoundationICU `uvernum.h` identifies ICU 76.1, and its README records the Apple
ICU derivation. The Qt SDK supplies ICU 73.2; its notices are stored separately.

System Qt retains the notices supplied by the distribution when the package
does not bundle Qt.

## Updating a runtime

A new Swift or bundled Qt version requires a matching notice directory and
verified manifest. Use notices from the corresponding source revisions and
retain their original contents. Do not replace an existing version's notices
with text from a different release.

The runtime stager's version checks are implemented in
[`scripts/package-runtime.py`](../../scripts/package-runtime.py).
