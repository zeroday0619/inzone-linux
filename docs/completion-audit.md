# Implementation and Verification Audit

This document records what the automated and archived checks establish for the
Sony INZONE H9 II Linux audio stack. A passing software test does not establish
physical-headset behavior unless the test used the H9 II and says so explicitly.

## 1. Verification Model

| Area | Automated evidence | Boundary |
|---|---|---|
| Direct FIR DSP | Descriptor contract, bank integrity, comparison with a test-side implementation of the recovered direct-convolution order, callback block shapes, in-place buffers, reactivation, and missing-channel zero input | The test oracle mirrors the implementation structure and is not a current execution oracle from `inzonevirtualizer.dll`; end-to-end headset acoustics require hardware verification |
| Retained DSP descriptors | LADSPA metadata and sample comparison against the retired C implementation | The retired C implementation is a Linux reference, not Sony's DLL |
| PipeWire routing | Generated graph tests and an isolated PipeWire/WirePlumber test target for exact 2.0, 5.1, and 7.1 links, zero missing FIR inputs, and target reconnection | The isolated normal-environment run does not establish production desktop routing or listening quality |
| Profiles and automation | CRUD, UUID identity, collection limits, reference protection, transaction rollback, debounce, priority, and restoration tests | Process fixtures do not cover every launcher or desktop session |
| Personalization | HKI/BA validation, normalization boundaries, complete-bank exchange, activation rollback and rollback retry, unresolved-bank cleanup protection, reset, and deferred cleanup tests | Authentic account-generated personal files and listening results require user data and hardware |
| USB HID | Packet codec, exact field offsets, read-modify-write preservation, response matching, readback convergence, bounded multipart notifications, snapshot watermarks, disconnect, malformed-frame recovery, and physical change/readback/restoration for all 14 H9 II writable fields | Physical unsolicited notifications and reconnect races remain unverified |
| Firmware safety | Event 3 GET/decode tests, physical installed-version GET, write rejection, Event 160 rejection/ignore tests, updater-artifact catalog, and install rejection | The physical GET covers headset and dongle firmware `01.001.000`; no latest-version service is queried |
| Installation | Path, symlink, digest, privilege-separation, sealed-snapshot, complete FIR-bank publication, reinstall, and backup tests | Staged installations do not establish a successful installation on the user's host |

## 2. DSP Reference Coverage

The golden fixture contains **89 scenarios** across the six retained LADSPA
descriptors, representing **4,554,752 channel samples** at 32,768 frames per
scenario. Exact Swift-to-retired-C equality is expected and tested for **87
scenarios**, or **4,489,216 channel samples**. The remaining two fixtures use
deliberately unstable biquad feedback. They preserve the retired C implementation's
non-finite checkpoints while the Swift implementation intentionally clears the
invalid state and recovers, so they are explicit divergence cases.

The fixture records its own provenance in
`Tests/InzoneCoreTests/Fixtures/dsp-golden.json`, including the reference ELF
SHA-256 `6b947631928d6a20074ab56257ab106236bd32450ed79ac41008449c6714d713`,
compiler, flags, C source hashes, and digest definition. Descriptors 6 through 8
are outside that retired-C fixture:

| Index | Unique ID | LADSPA label | Bank |
|---:|---:|---|---|
| 6 | 59876 | `inzone_fir_standard` | Standard H9 II HRTF |
| 7 | 59877 | `inzone_fir_personal` | Imported personalized HRTF |
| 8 | 59878 | `inzone_fir_downmix` | Sony surround-off downmix |

Each FIR descriptor exposes eight inputs (`FL`, `FR`, `FC`, `LFE`, `RL`, `RR`,
`SL`, `SR`), stereo outputs, and a latency control output. The runtime performs
direct 512-tap Float32 convolution in the recovered Sony channel and summation
order. `FIRDSPTests.swift` compares it with a test-side source-derived oracle that
uses the same recovered calculation structure, plus one narrow frozen addition-order
vector. This supports regression consistency, not an independent proof of full
native-DLL bit identity.

## 3. Current and Archived Results

The most recently completed direct-FIR test snapshot used plugin SHA-256
`a933ca797669b890d93b637d113bfbafd3c0fe88f6906ce6b3b2110f4366f301`.
`FIRDSPTests` passed 8 of 8 tests and `DSPGoldenTests` passed 6 of 6 tests. Three
`NativeDSPTests` completed before the suite stalled at a sandbox-restricted test,
so that target does not have a complete current result. `DownmixLayoutTests` has
no valid result in this environment: the
first test failed when the sandbox rejected the PipeWire protocol socket bind,
and the second was interrupted after the same startup condition. These are
environment limits, not evidence that the desktop-session layout behavior passed.

The FIR source changed after that plugin was built. A final native rebuild and
repeat of the direct-FIR checks are therefore required before treating the digest
or test counts above as current implementation evidence.

The same validation snapshot recorded 27 of 27 `DeviceTests`, 11 of 11
`DeviceStatusTests`, and 12 of 12 `DeviceDraftTests` passing. Five selected
installation and reinstall tests also passed. Later targeted normal-environment
runs passed 18 `AutomationTests`, 36 profile import/storage tests, and the
personalization-related groups of 31 filter, 8 controller, and 9 TUI tests.
These overlapping targeted groups are not a substitute for a final full-suite
count. Process-executing installation tests did not complete in the earlier
sandbox because the Swift process stalled while initializing `CFSocket`.

`AssetFetcherTests` passed 30 of 30 tests. An offline extraction run with the
latest debug tool completed, decompiled 38 selected managed types, published the
nested downmix tree, retained 15 firmware-artifact metadata entries, and retained
none of those updater bytes in the published payload. The top-level release
`make assets` invocation was not completed in that snapshot because a concurrently
edited `ProfileController.swift` did not compile; the successful debug-tool run
does not replace a final release build check.

The JSON reports under `analysis/` are archived measurements. In particular,
`impulse-results.json` records 379,392 output samples, while each of the three
`pipewire-sfx-results.json` cases records 720,000 samples. Both reports identify
plugin SHA-256 `e93cf211a0d60b283a1a9396e3f523276494f9f92775cc0abf0f0d6f3a0b8cd0`.
That digest predates the direct FIR descriptors, so these reports do not validate
the current plugin binary or the new downmix layouts. A zero difference in the
SFX report means that PipeWire matched the same historical Linux LADSPA graph run
outside PipeWire; it is not a lossless comparison with Sony's Windows engine.

## 4. HID and Firmware Boundaries

The HCI transport accepts supported GET commands and explicitly writable SET
commands. A transaction completes only on the matching event, source, sequence,
and response kind. SET applies one read-modify-write operation and then polls GET
for convergence without retransmitting the write. Unsolicited `NTFY_ACTIVE`
reports are reassembled separately and published with revisions. The atomic
observe API returns a snapshot plus event watermarks so a notification captured
before its corresponding snapshot response cannot replace newer state.

Firmware support is limited to Event 3 GET and formatting the installed headset
and transceiver versions. Event 3 is not writable. Event 160 is rejected by the
codec and discarded if received by the asynchronous reader. CLI names associated
with firmware lookup, download, update, or flashing fail without opening such a
path. The asset inventory catalogs updater-related files as
`catalog-only-do-not-execute`. Known updater names and Windows PE files are
rejected as Linux executable inputs; the pinned virtualizer DLL remains
non-executable decoder data.

The only tracked physical-device write report is
`analysis/device-write-verification.json`: sidetone changed from 4 to 3 and was
restored to 4. Physical verification is still required for all other field writes,
asynchronous notifications, Event 3 version reads, reconnect behavior, and
headset audio output.

## 5. Running Verification

The top-level check target prepares the pinned assets and native plugin before
running Swift tests:

```sh
make check
```

Targeted checks are available through SwiftPM after `make build` has prepared the
assets and native plugin:

```sh
swift test --filter FIRDSPTests
swift test --filter DeviceTests
swift test --filter ProfileControllerTests
swift test --filter DownmixLayoutTests
swift test --filter InzoneTUITests
git diff --check
```

Hardware-independent TUI previews, staged installations, and isolated PipeWire
servers do not establish physical touch operation, production installation, or
listening quality. The physical H9 II run covers all 14 supported field writes,
restoration, status reads, and installed firmware `01.001.000`; it does not cover
unsolicited notification timing or reconnect races. Human review remains required
for AI-assisted changes.
