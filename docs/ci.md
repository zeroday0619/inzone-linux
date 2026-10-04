# Debian package CI

[`.github/workflows/debian-packages.yml`](../.github/workflows/debian-packages.yml)
builds amd64 packages on push, pull request, and manual `workflow_dispatch`
events. In GitHub, select **Actions → Debian packages → Run workflow** for a
manual build. The workflow requires no repository secrets or self-hosted runner.

## Build targets

| Matrix suite | Target libraries | Package revision | Qt runtime |
| --- | --- | --- | --- |
| `trixie` | Debian 13, including updates and security updates | `1~deb13u1` | Private Qt 6.11.2 |
| `forky` | Debian testing, selected by the `forky` codename | `1~forky1` | Private Qt 6.11.2 |

Both CI variants compile against extracted Debian sysroots on GitHub's
`ubuntu-24.04` runner. Compilers and Qt code generators run as the runner user.
The workflow does not use a container, chroot, or privileged project build.
Host build prerequisites are installed with APT before the unprivileged build.
The separate native `make deb` path continues to use the build host's system Qt.

The matrix does not claim compatibility with every future testing or unstable
snapshot. Each artifact includes the exact Debian package versions and hashes
used to build and validate it. Debian repository updates can change these inputs.

## Toolchain and source inputs

- `scripts/ci/install-swift.sh` installs the official Swift 6.3.3 Ubuntu 24.04
  amd64 toolchain in the runner's temporary directory. It verifies the archive
  signature against the pinned Swift release-key fingerprint before extraction.
  The runtime notice manifest requires this exact Swift version.
- `scripts/ci/prepare-debian-keyring.sh` downloads Debian's archive, security,
  and stable-release keys and checks their primary fingerprints. A dedicated
  keyring avoids relying on the Ubuntu image's older Debian keyring.
- `scripts/prepare-debian.py` verifies Debian archive metadata with APT and
  prepares the selected sysroot without running package maintainer scripts.
  Qt SDK archives must match `packaging/debian/qt-sdk-6.11.2.json`.
- QtBridge is pinned in `CMakeLists.txt`; SwiftPM resolves the checked-in
  `Package.resolved`. Downloaded source checkouts retain Git metadata so the
  package can include their corresponding source.
- GitHub actions are pinned to full commit IDs. The workflow grants only
  `contents: read` and disables checkout credential persistence.

Generated files stay under `RUNNER_TEMP`. Each job prepares fresh inputs and
build directories. `SOURCE_DATE_EPOCH` comes from the checked-out commit.
SwiftPM and CMake parallelism is limited to two jobs for hosted runner memory.
The workflow does not download Sony assets or firmware.

## Checks and artifacts

The lint job runs actionlint 1.7.12, ShellCheck, and Python syntax checks.
The `trixie` job builds the free DSP plugin and runs the installation,
installation coordinator, and packaged-setup unit tests. Tests that require
proprietary prepared assets report skips; the workflow retains the test log and
does not download those assets. Both package jobs then run:

1. Release build and CPack DEB packaging against the selected sysroot.
2. Payload, permissions, runtime-manifest hashes, source archive, and ELF
   dependency checks with `scripts/verify-debian.py`.
3. Extracted CLI help and offscreen GUI execution using the target Debian
   loader and libraries.
4. Lintian with errors treated as failures. Warnings remain in the log,
   including the documented data-only `libicudata.so.73` warning.
5. APT installation simulation against the target repositories with an empty
   installed-package database.

Successful jobs upload `inzone-linux-trixie-amd64` or
`inzone-linux-forky-amd64`, containing:

- The `.deb` and `SHA256SUMS`.
- `verification.json`, `verification.log`, `lintian.log`, and
  `apt-simulation.log`.
- `debian-manifest.json` and `qt-manifest.json` with input versions and hashes.
- `debian-target.json` and `source-commit.txt` identifying the target and checkout.

The `debian-SUITE-diagnostics` artifact retains available logs even after a
failed job. Artifacts expire after 14 days. Packages are uploaded only after
all validation steps succeed; the workflow does not publish a GitHub release
or install the generated package on the runner.

After downloading and extracting a successful artifact, verify it with:

```sh
sha256sum --check SHA256SUMS
```

The automated runtime check uses Qt's offscreen backend. Native desktop
Wayland behavior, headset interaction, and privileged package installation and
removal require separate release validation.

## Reproduce a matrix build

Use a normal desktop user with the host prerequisites listed in the workflow:

```sh
suite=trixie
work=/tmp/inzone-ci-trixie
scripts/ci/install-swift.sh "$work/swift-6.3.3"
scripts/ci/prepare-debian-keyring.sh "$work/debian-archive.gpg"
python3 scripts/prepare-debian.py "$work/inputs" \
  --suite "$suite" --keyring "$work/debian-archive.gpg"
INZONE_BUILD_JOBS=2 scripts/build-debian.sh "$suite" \
  "$work/inputs/root" "$work/inputs/qt/sdk" \
  "$work/swift-6.3.3" "$work/build"
python3 scripts/ci/verify-package.py "$work"/build/packages/*.deb \
  --sysroot "$work/inputs/root" --apt-config "$work/inputs/apt/config" \
  --output-directory "$work/artifacts"
```

Use `suite=forky` and a separate working directory for the other target.
The existing `prepare-debian13.py` and `build-debian13.sh` commands remain
compatible wrappers for `trixie`. See [Debian packaging](debian.md) for package
installation and user setup.

## References

- [GitHub workflow syntax](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax)
- [Ubuntu 24.04 runner software](https://github.com/actions/runner-images/blob/main/images/ubuntu/Ubuntu2404-Readme.md)
- [Swift Ubuntu toolchains](https://www.swift.org/install/linux/ubuntu/24_04/)
- [Swift release signing keys](https://www.swift.org/keys/active/)
- [Debian archive signing keys](https://ftp-master.debian.org/keys.html)
