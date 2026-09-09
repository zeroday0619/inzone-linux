# Feature Specification & Implementation Status

This document records the implemented scope, verification status, and explicit
boundaries of the PipeWire, WirePlumber, and Swift LADSPA implementation compared
with Sony's **INZONE Hub 1.0.19.0** behavior analyzed by this project.

---

## 1. Audio & DSP Signal Processing

| Feature | Status | Description | Verification Path |
|---|:---:|---|---|
| **Layout-specific Virtual Sinks** | Implemented | Separate 2.0, 5.1, and 7.1 sinks declare `FL FR`, `FL FR FC LFE SL SR`, and `FL FR FC LFE RL RR SL SR`; unconnected FIR inputs are exact zero | Graph and controller tests pass; isolated PipeWire layout execution passed in the normal environment |
| **Direct FIR Rendering** | Supported | LADSPA descriptors `inzone_fir_standard`, `inzone_fir_personal`, and `inzone_fir_downmix` execute the 512-tap, eight-input, two-output direct FIR path | `FIRDSPTests.swift`, `DSPGoldenTests.swift` |
| **Surround HRTF** | Supported | Standard or personalized binaural rendering selects the eight H9 II speaker directions from the 14-direction HKI metadata set | HKI topology checks (`FilterTests.swift`) and source-derived direct-FIR oracle (`FIRDSPTests.swift`) |
| **Surround-off Sony Downmix** | Supported | Game-oriented profiles with surround disabled use `downmix.hki`, followed by spatial ALC, instead of bypassing Sony's downmix path | Exact delta-FIR and isolated PipeWire layout tests |
| **H9 II Hardware Correction Filter** | Supported | 7-stage IIR Biquad filter (`wh_g910n_standard.ba`) dedicated to H9 II (MDR-G900N / YY2987), computed in native double precision | Pole stability and corrupted input tests (`FilterTests.swift`) |
| **Internal Spatial ALC** | Supported | Dynamic peak limiter with 8-frame blocks and 32-sample (0.667 ms) lookahead latency; suppresses post-spatialization clipping with a +1.0 dB level compensation | Block size and in-place buffer consistency tests (`NativeDSPTests.swift`) |
| **Sony 10-Band EQ** | Supported | 10 frequency bands from 31.5 Hz to 16 kHz with -12 dB to +12 dB range (1 dB steps), applying Sony precomputed Biquad coefficient tables directly | Coefficient table integrity checks (`AssetExportTests.swift`) |
| **Sony Official 7 Presets** | Supported | Built-in Flat, FPS 1, FPS 2, FPS 3, Immersion Flat (RPG), Bass Boost, and Music/Video presets; automatically engages Output ALC for non-Flat presets | Preset parameter and transformation tests (`PresetsTests.swift`) |
| **ModeEqualizer (Immersive Soundstage)** | Supported | Sony proprietary immersion compensation Biquad filter (Standard / Immersive soundfield modes) | Native coefficient precedence and filter graph tests |
| **Output Auto Level Control (Output ALC)** | Supported | -18 dB attenuation stage followed by peak compression (Threshold -18 dB, Ratio 1000:1, Attack 1 ms, Release 1 s) and +18 dB recovery stage | PipeWire vs. direct LADSPA reference comparisons (`diagnose-sfx`) |
| **Dynamic Range Control (DRC)** | Supported | 3 levels: Off / Low / High; upward compression and expansion curve based on 10 ms peak detection | Bit-level single-precision floating-point matching (`DSPGoldenTests.swift`) |
| **Microphone Auto Gain Control (Mic AGC)** | Supported | Software AGC normalizing microphone input level | LADSPA block processing and graph loading tests |
| **Audio Format Boundary** | 48 kHz path | Sony FIR/BA assets and the direct FIR descriptors require 48 kHz; the documented H9 II Game endpoint is 16-bit, 48 kHz stereo | Descriptor sample-rate rejection and graph tests; physical endpoint behavior remains hardware-dependent |

---

## 2. Hardware Device Control (USB HID)

Direct hardware control over the INZONE H9 II wireless transceiver (VID `054C`, PID `0FA8`) via USB Interface 5 using Sony proprietary HCI packet protocol.

| Control Item | CLI Identifier | Status | Range & Values | Description |
|---|---|:---:|---|---|
| **Noise Control (ANC)** | `anc` | Supported | `0`: Off, `1`: Noise Canceling (NC), `2`: Ambient Sound | Directly updates headset hardware register |
| **Ambient Sound Level** | `ambient_level` | Supported | `1` to `20` (20 steps) | Controls microphone passthrough level while Ambient mode is active |
| **Voice Focus Mode** | `voice_focus` | Supported | `0`: Off, `1`: On | Passes human vocal frequencies while suppressing ambient noise; changed while Ambient mode is active |
| **Sidetone (Mic Monitoring)** | `sidetone` | Supported | `0` to `10` (11 steps) | Real-time microphone monitoring in headphones |
| **Game / Chat Balance** | `game_chat` | Supported | `0` to `100` in steps of `10` (50: Center) | Hardware balance between Game and Chat audio streams |
| **Headphone Hardware Volume** | `headphone_volume` | Supported | `0` to `30` | Preserves the other Event 33 payload fields during read-modify-write |
| **Headphone Mute Status** | - | GET/notification only | `0`: Unmuted, `1`: Muted | H9 II reports Event 33 byte 0; Hub changes only the volume byte for this model |
| **Boom Microphone Mute Status** | - | GET/notification only | `0`: Unmuted, `1`: Muted | H9 II reports Event 36, while Hub exposes its generic SET button only for INZONE Buds |
| **Physical Button Toggle Cycle** | `toggle_*` | Supported | `toggle_off`, `toggle_nc`, `toggle_ambient` (`0` or `1`) | Determines modes cycled when pressing headset NC button |
| **Power-on NC Default** | `nc_startup` | Supported | `0`: Off, `1`: NC, `2`: Ambient, `3`: Retain Last State | Initial noise control mode upon powering on |
| **Power-on Bluetooth** | `bt_startup` | Supported | `0`: Off, `1`: On, `2`: Retain Last State | Bluetooth module state upon powering on |
| **Auto Power Off** | `auto_power` | Supported | `0`, `5`, `15`, `30`, `60`, `180` (minutes, `0`: Disabled) | Standby auto shutoff timer when no audio signal is present |
| **Voice Guidance Language** | `language` | Supported | `0`: English, `1`: Japanese, `2`: Chinese | Built-in voice prompt language |
| **Notification Tones & Guidance** | `guidance` | Supported | `0`: Off, `1`: On | Enables or disables operation beeps and voice guidance |
| **Battery Status Query** | - | Supported | `0%` to `100%` (including charging state) | Live status readout (`--device-status`) |
| **Installed Firmware Version Query** | - | GET-only | Reads Event 3 and formats headset and transceiver versions; no latest-version comparison | `--device-status`; codec and transport tests |
| **Asynchronous Status** | - | Supported | Reassembles bounded multipart `NTFY_ACTIVE` (`0xA0`) reports and publishes typed notifications with snapshot watermarks | `DeviceTests.swift`, `DeviceStatusTests.swift` |
| **Mic Loopback Test** | - | Supported | Real-time local loopback (up to 30 seconds, pure memory queue) | Easy auditioning via TUI key `T` |

The Hub's shared protocol enum also contains Event 98 (Bluetooth sound quality)
and Event 130 (LED setting). Its H9 II capability/visibility path hides those
generic controls, so they are not part of the H9 II feature matrix above.

---

## 3. Profiles & Automation

| Feature | Status | Description |
|---|:---:|---|
| **Built-in Profiles** | Supported | Five editable templates: `surround`, `fps`, `music`, `voice`, and `balanced`; `restore` returns to the captured baseline configuration |
| **Dynamic Custom Profiles** | Supported | Create, clone, rename, and delete profiles with stable UUID identifiers and retained routing templates; maximum 256 custom profiles |
| **Collection Import Modes** | Supported | Import appends without confirmation and reports imported/skipped counts at the 256-profile limit; explicit Replace requires `IMPORT` and preserves active/automation reference integrity |
| **Independent Profile Settings** | Supported | EQ, DRC, Output ALC, Mic AGC, Sound Mode, and HRTF selections persist independently per profile (`~/.config/inzone-h9-ii/`) |
| **Safe Profile References** | Supported | Active profiles, automation bindings, and pending automation restoration state prevent deletion or collection replacement that would leave dangling identifiers |
| **Process Detection Auto-Switching** | Supported | Monitors active processes on a 1-second interval to switch profiles (supports native Linux and Wine/Proton Windows `*.exe` executables) |
| **Priority & Debounce** | Supported | Configurable per-rule priorities; enforces a 2-second continuous state match before switching to avoid audio stuttering |
| **Smart Restoration & Manual Priority** | Supported | Restores prior profile when target process exits; preserves manual user profile changes during active sessions |
| **systemd User Daemon** | Supported | Background resident service unit provided via `inzone-profile-auto.service` (`inzone-profile --auto-enable`) |

---

## 4. Data Interoperability

| Feature | Status | Description |
|---|:---:|---|
| **Windows Profile Import/Export** | Supported with validation | Read or write individual entries and complete Windows-compatible `SoundProfile.json` collections. The Linux path preserves order, stable identity, routing templates, supported representations, and unknown object fields when possible. A unique ID can recover a stripped template from the existing local collection; cross-machine files without the extension fall back from the Surround flag. Hub acceptance remains `Verification required` |
| **Personalized HRTF (`.hki`) Import** | Supported | Accepts the optional 52-byte outer wrapper, decrypts and validates mobile app Cipher 7-encrypted HKI files, requires all eight H9 II renderer directions, applies the native 512-sample partition normalization contract, and stages a complete bank |
| **Personal Correction Filter (`YY2987.ba`) Import** | Supported | Parses the `ba00` container with its 48-byte header, verifies checksum, validates 7-stage Biquad stability, and installs safely |
| **Atomic Personalization Lifecycle** | Supported | Atomically publishes or exchanges a complete personal bank, activates it in the profile transaction, attempts prior-bank restoration on activation failure, protects an unresolved rollback bank from cleanup, and records retired banks when cleanup must be retried |
| **Profile Activation Rollback** | Supported | Restores the previous managed configuration, profile state, and default sink when a verified profile transition fails |

---

## 5. UI & Tooling

| Tool | Implementation | Purpose & Capabilities |
|---|---|---|
| **Terminal UI (TUI)** | SwiftTUI Interface | Arrow-key profile switching, 10-band EQ editor, hardware control dialog, personalization import, and mic loopback test |
| **CLI Controller** | `inzone-profile` | Profile CRUD, DSP settings, Windows collection exchange, personalization lifecycle, device status/control, and automation commands |
| **Asset Extraction Tool** | `inzone-tools fetch / assets` | Installer SHA-256 verification, MSI/CAB static extraction, selected ILSpy decompilation, reverse-engineering inventory generation, and audio coefficient generation |
| **Diagnostics & Verification** | `inzone-tools diagnose-*` | PipeWire impulse response measurements, LADSPA numerical accuracy verification, and session routing diagnostics |

---

## 6. Scope & Non-Goals

| Item | Status | Rationale & Alternatives |
|---|:---:|---|
| **Smartphone Ear Photo Cloud Analysis** | Out of Scope | Requires communication with proprietary Sony cloud servers and account authentication. To safeguard user privacy and maintain offline operation, cloud communication is omitted. Users can generate `personalized_hrtf.hki` and `YY2987.ba` files via the mobile app/Windows Hub and import them locally. |
| **Latest Firmware Lookup or Comparison** | Intentionally unsupported | The implementation reads installed Event 3 values only. It does not contact an update catalog or decide whether a newer version exists. |
| **Firmware Download, Update, or Flashing** | Intentionally unsupported | Event 160 is rejected or ignored, known updater artifacts are cataloged for analysis only, and no updater executable or firmware payload is installed. Firmware maintenance must use Sony-supported software. |

## 7. Verification Boundaries

The automated suite covers packet codecs and simulated HCI transport, exact
profile and asset transactions, direct FIR behavior against a source-derived
oracle, and isolated PipeWire/WirePlumber routing. The repository's recorded
physical H9 II run changes, reads back, and restores all 14 writable fields and
reads headset and dongle firmware `01.001.000`. Physical unsolicited
notifications, reconnect races, personalized files from a real account, and
end-to-end headset acoustics remain unverified.
