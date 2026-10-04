# Debian package CI

The [Debian packages workflow](../.github/workflows/debian-packages.yml) is
configured to build and verify amd64 packages on push, pull request, and manual
`workflow_dispatch` events. It uses GitHub-hosted `ubuntu-24.04` runners and
requires no repository secrets or self-hosted runner.

## Run a build

Push a commit or open a pull request to trigger the workflow. For a manual run,
open **Actions → Debian packages → Run workflow** in GitHub.

Each run has two package jobs:

| Suite | Target libraries | Package revision | Bundled Qt runtime |
| --- | --- | --- | --- |
| `trixie` | Debian 13, including updates and security updates | `1~deb13u1` | Qt 6.11.2 |
| `forky` | Debian testing, selected by the `forky` codename | `1~forky1` | Qt 6.11.2 |

Both jobs compile against extracted Debian sysroots. The separate native
`make deb` build uses the host distribution's Qt packages. Debian repository
updates can change the sysroot inputs; the artifact manifests record the exact
versions and hashes used for each build. Validation applies to those inputs
and does not establish compatibility with future testing or unstable snapshots.

The lint job must pass before either package job starts. A failure in one
package job does not cancel the other. A newer run for the same Git ref cancels
an older run. The lint job has a 10-minute timeout; each package job has a
90-minute timeout.

## Download and verify a package

Open a successful **Debian packages** run and download the artifact for the
target distribution:

| Artifact | Contents | Retention |
| --- | --- | --- |
| `inzone-linux-trixie-amd64` | Verified Debian 13 package and evidence | 14 days |
| `inzone-linux-forky-amd64` | Verified forky package and evidence | 14 days |
| `debian-SUITE-diagnostics` | Available build and verification logs, including after a failed job | 14 days |

A package artifact contains:

- The `.deb` and `SHA256SUMS`.
- `verification.json`, `verification.log`, `lintian.log`, and
  `apt-simulation.log`.
- `debian-manifest.json` and `qt-manifest.json` with input versions and hashes.
- `debian-target.json` and `source-commit.txt` identifying the target and checkout.

Extract the artifact, change to its directory, and verify the package checksum:

```sh
sha256sum --check SHA256SUMS
```

Package artifacts are uploaded only after the job's validation steps succeed.
The workflow does not publish a GitHub release or install the generated package.
See [Debian packaging](debian.md) for installation and user setup.

## Build and verification steps

The lint job runs actionlint 1.7.12, ShellCheck, and Python syntax checks.
The `trixie` job also builds the free DSP plugin and runs `InstallationTests`,
`InstallCoordinatorTests`, and `PackagedSetupTests`. Cases that require
proprietary prepared assets report skips. Their results remain in the test log;
the workflow does not download those assets.

Each package job then performs these checks:

1. Build in Release mode and generate a DEB with CPack against the selected
   sysroot.
2. Check the payload, ownership, permissions, runtime-manifest hashes,
   corresponding source archive, and ELF dependencies with
   [`scripts/verify-debian.py`](../scripts/verify-debian.py).
3. Run the extracted executables' help commands and the GUI smoke test with the
   target Debian loader and libraries. Dependency checks reject host-library
   fallback. The GUI uses Qt's offscreen backend.
4. Run Lintian with errors treated as failures. Warnings remain in the log.
   Both bundled Qt variants can report `shared-library-lacks-prerequisites`
   for the data-only `libicudata.so.73` library.
5. Simulate APT installation against the target repositories with an empty
   installed-package database. The simulation does not execute maintainer
   scripts or install packages.

Compilers, Qt code generators, tests, and package checks run as the runner user.
APT installs host build prerequisites with `sudo` before these steps. Project
builds do not use root privileges, containers, or chroots. SwiftPM and CMake
parallelism is limited to two jobs for hosted runner memory.

Toolchains, sysroots, package build directories, logs, and artifacts use
`RUNNER_TEMP`. The `trixie` test step additionally writes `native/inzone_dsp.so`,
`native/debug.o`, and `.build/native-module-cache` in the checkout. Each job
starts with fresh preparation and build directories. `SOURCE_DATE_EPOCH` is the
checked-out commit's timestamp.

## Verified inputs

| Input | Selection and verification |
| --- | --- |
| Swift | `scripts/ci/install-swift.sh` downloads the official Swift 6.3.3 Ubuntu 24.04 amd64 toolchain and verifies its archive signature against a pinned release-key fingerprint before extraction. The runtime notice manifest requires this exact version. |
| Debian keys | `scripts/ci/prepare-debian-keyring.sh` checks the archive, security, and stable-release keys against pinned primary fingerprints and creates a dedicated keyring. |
| Debian sysroot | `scripts/prepare-debian.py` uses APT to verify archive metadata, then extracts the selected packages without running their maintainer scripts. |
| Qt | SDK archives must match the SHA-256 values in `packaging/debian/qt-sdk-6.11.2.json`. |
| Source dependencies | QtBridge is pinned in `CMakeLists.txt`. SwiftPM uses the checked-in `Package.resolved`. Downloaded checkouts retain Git metadata for the corresponding source archive. |
| GitHub actions | Actions use full commit IDs. Workflow permissions are limited to `contents: read`, and checkout credentials are not persisted. |

The workflow does not download Sony assets or firmware.

## Reproduce a package job locally

Run these commands from the repository root as a normal desktop user. Install
the host prerequisites listed in the workflow first, including CMake 3.29 or
later. The toolchain helper requires Linux x86_64 and installs the Ubuntu 24.04
Swift distribution. Use a new working directory; the toolchain and keyring
helpers reject existing destinations. Build paths cannot contain spaces,
semicolons, quotes, or backslashes.

Prepare the selected sysroot and toolchain:

```sh
suite=trixie
work="/tmp/inzone-ci-${suite}"
export SOURCE_DATE_EPOCH="$(git log -1 --format=%ct)"
scripts/ci/install-swift.sh "$work/swift-6.3.3"
scripts/ci/prepare-debian-keyring.sh "$work/debian-archive.gpg"
python3 scripts/prepare-debian.py "$work/inputs" \
  --suite "$suite" --keyring "$work/debian-archive.gpg"
```

For `trixie`, run the same installation and setup tests as the workflow:

```sh
if [ "$suite" = trixie ]; then
  make -C native SWIFTC="$work/swift-6.3.3/usr/bin/swiftc"
  "$work/swift-6.3.3/usr/bin/swift" test --jobs 2 \
    --scratch-path "$work/setup-tests" --disable-automatic-resolution \
    --filter 'InstallationTests|InstallCoordinatorTests|PackagedSetupTests'
fi
```

Build the package, validate it, and record its target and source commit:

```sh
INZONE_BUILD_JOBS=2 scripts/build-debian.sh "$suite" \
  "$work/inputs/root" "$work/inputs/qt/sdk" \
  "$work/swift-6.3.3" "$work/build"
python3 scripts/ci/verify-package.py "$work"/build/packages/*.deb \
  --sysroot "$work/inputs/root" --apt-config "$work/inputs/apt/config" \
  --output-directory "$work/artifacts"
git rev-parse HEAD > "$work/artifacts/source-commit.txt"
cp "$work/inputs/debian-target.json" "$work/artifacts/"
```

Use `suite=forky` and a separate working directory for the other target. The
existing `prepare-debian13.py` and `build-debian13.sh` commands remain compatible
wrappers for `trixie`.

## Validation record and limits

Local validation on 2026-10-04 used Swift 6.3.3 and Qt 6.11.2:

- Both sysroot packages passed payload, runtime, and target APT dependency
  checks. Each package contained 84 ELF files and 265 runtime-manifest entries.
- Lintian reported zero errors and one `libicudata.so.73` warning for each
  bundled Qt package.
- The filtered test run from a checkout without proprietary assets reported
  28 passes, 18 skips, and zero failures.

These results were produced locally. A GitHub-hosted workflow run was not
performed during that validation. The offscreen runtime check does not test
native desktop Wayland behavior or headset interaction. Privileged package
installation and removal also require separate release validation.

## References

- [GitHub workflow syntax](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax)
- [Ubuntu 24.04 runner software](https://github.com/actions/runner-images/blob/main/images/ubuntu/Ubuntu2404-Readme.md)
- [Swift Ubuntu toolchains](https://www.swift.org/install/linux/ubuntu/24_04/)
- [Swift release signing keys](https://www.swift.org/keys/active/)
- [Debian archive signing keys](https://ftp-master.debian.org/keys.html)
