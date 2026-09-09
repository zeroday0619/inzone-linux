# Feature Specification & Implementation Status

This document details the feature parity, implementation scope, and technical specifications of this project (based on PipeWire, WirePlumber, and Swift LADSPA) compared against Sony official utility, **INZONE Hub 1.0.19.0**.

---

## 1. Audio & DSP Signal Processing

| Feature | Status | Description | Verification Path |
|---|:---:|---|---|
| **7.1ch Virtual Surround** | Supported | Real-time binaural rendering of 7.1ch (FL, FR, FC, LFE, RL, RR, SL, SR) input using Sony official 512-tap FIR HRTF filters | PipeWire impulse response diagnostics (`inzone-tools diagnose-impulse`) |
| **H9 II Hardware Correction Filter** | Supported | 7-stage IIR Biquad filter (`wh_g910n_standard.ba`) dedicated to H9 II (MDR-G900N / YY2987), computed in native double precision | Pole stability and corrupted input tests (`FilterTests.swift`) |
| **Internal Spatial ALC** | Supported | Dynamic peak limiter with 8-frame blocks and 32-sample (0.667 ms) lookahead latency; suppresses post-spatialization clipping with a +1.0 dB level compensation | Block size and in-place buffer consistency tests (`NativeDSPTests.swift`) |
| **Sony 10-Band EQ** | Supported | 10 frequency bands from 31.5 Hz to 16 kHz with -12 dB to +12 dB range (1 dB steps), applying Sony precomputed Biquad coefficient tables directly | Coefficient table integrity checks (`AssetExportTests.swift`) |
| **Sony Official 7 Presets** | Supported | Built-in Flat, FPS 1, FPS 2, FPS 3, Immersion Flat (RPG), Bass Boost, and Music/Video presets; automatically engages Output ALC for non-Flat presets | Preset parameter and transformation tests (`PresetsTests.swift`) |
| **ModeEqualizer (Immersive Soundstage)** | Supported | Sony proprietary immersion compensation Biquad filter (Standard / Immersive soundfield modes) | Native coefficient precedence and filter graph tests |
| **Output Auto Level Control (Output ALC)** | Supported | -18 dB attenuation stage followed by peak compression (Threshold -18 dB, Ratio 1000:1, Attack 1 ms, Release 1 s) and +18 dB recovery stage | PipeWire vs. direct LADSPA reference comparisons (`diagnose-sfx`) |
| **Dynamic Range Control (DRC)** | Supported | 3 levels: Off / Low / High; upward compression and expansion curve based on 10 ms peak detection | Bit-level single-precision floating-point matching (`DSPGoldenTests.swift`) |
| **Microphone Auto Gain Control (Mic AGC)** | Supported | Software AGC normalizing microphone input level | LADSPA block processing and graph loading tests |
| **Hi-Res Audio Playback** | Supported | Processed via PipeWire resampler in music profile (hardware output fixed at 16-bit 48kHz) | PipeWire resampling session tests |

---

## 2. Hardware Device Control (USB HID)

Direct hardware control over the INZONE H9 II wireless transceiver (VID `054C`, PID `0FA8`) via USB Interface 5 using Sony proprietary HCI packet protocol.

| Control Item | CLI Identifier | Status | Range & Values | Description |
|---|---|:---:|---|---|
| **Noise Control (ANC)** | `anc` | Supported | `0`: Off, `1`: Noise Canceling (NC), `2`: Ambient Sound | Directly updates headset hardware register |
| **Ambient Sound Level** | `ambient_level` | Supported | `1` to `20` (20 steps) | Controls microphone passthrough level in Ambient mode |
| **Voice Focus Mode** | `voice_focus` | Supported | `0`: Off, `1`: On | Passes human vocal frequencies while suppressing ambient noise |
| **Sidetone (Mic Monitoring)** | `sidetone` | Supported | `0` to `10` (11 steps) | Real-time microphone monitoring in headphones |
| **Game / Chat Balance** | `game_chat` | Supported | `0` to `100` (50: Center) | Hardware balance between Game and Chat audio streams |
| **Physical Button Toggle Cycle** | `toggle_*` | Supported | `toggle_off`, `toggle_nc`, `toggle_ambient` (`0` or `1`) | Determines modes cycled when pressing headset NC button |
| **Power-on NC Default** | `nc_startup` | Supported | `0`: Off, `1`: NC, `2`: Ambient, `3`: Retain Last State | Initial noise control mode upon powering on |
| **Power-on Bluetooth** | `bt_startup` | Supported | `0`: Off, `1`: On, `2`: Retain Last State | Bluetooth module state upon powering on |
| **Auto Power Off** | `auto_power` | Supported | `0`, `5`, `15`, `30`, `60`, `180` (minutes, `0`: Disabled) | Standby auto shutoff timer when no audio signal is present |
| **Voice Guidance Language** | `language` | Supported | `0`: English, `1`: Japanese, `2`: Chinese | Built-in voice prompt language |
| **Notification Tones & Guidance** | `guidance` | Supported | `0`: Off, `1`: On | Enables or disables operation beeps and voice guidance |
| **Battery Status Query** | - | Supported | `0%` to `100%` (including charging state) | Live status readout (`--device-status`) |
| **Firmware Version Query** | - | Supported | Headset and transceiver firmware version strings | Live status readout (`--device-status`) |
| **Mic Loopback Test** | - | Supported | Real-time local loopback (up to 30 seconds, pure memory queue) | Easy auditioning via TUI key `T` |

---

## 3. Profiles & Automation

| Feature | Status | Description |
|---|:---:|---|
| **6 Base Profiles** | Supported | `surround` (spatial audio), `fps` (footstep boost), `music` (reference sound), `voice` (vocal clarity), `balanced` (flat default), `restore` (baseline revert) |
| **Independent Profile Settings** | Supported | EQ, DRC, Output ALC, Mic AGC, Sound Mode, and HRTF selections persist independently per profile (`~/.config/inzone-h9-ii/`) |
| **Process Detection Auto-Switching** | Supported | Monitors active processes on a 1-second interval to switch profiles (supports native Linux and Wine/Proton Windows `*.exe` executables) |
| **Priority & Debounce** | Supported | Configurable per-rule priorities; enforces a 2-second continuous state match before switching to avoid audio stuttering |
| **Smart Restoration & Manual Priority** | Supported | Restores prior profile when target process exits; preserves manual user profile changes during active sessions |
| **systemd User Daemon** | Supported | Background resident service unit provided via `inzone-profile-auto.service` (`inzone-profile --auto-enable`) |

---

## 4. Data Interoperability

| Feature | Status | Description |
|---|:---:|---|
| **Windows Profile Import/Export** | Supported | Read and write Windows INZONE Hub `SoundProfile.json` directly (lossless bidirectional conversion, enum mapping, and JSON comment handling) |
| **Personalized HRTF (`.hki`) Import** | Supported | Decrypts and validates mobile app Cipher 7-encrypted HKI files (azimuth, tap count, polar angle, and FFT normalization checks) |
| **Personal Correction Filter (`YY2987.ba`) Import** | Supported | Parses 52-byte header wrapper, verifies checksum, validates 7-stage Biquad stability, and installs safely |
| **Safe Backup & Automatic Rollback** | Supported | Reverts to prior WirePlumber configuration and audio sink bindings immediately upon profile switch failure |

---

## 5. UI & Tooling

| Tool | Implementation | Purpose & Capabilities |
|---|---|---|
| **Terminal UI (TUI)** | SwiftTUI Interface | Arrow-key profile switching, 10-band EQ editor, hardware control dialog, personalization import, and mic loopback test |
| **CLI Controller** | `inzone-profile` | Complete command-line interface for shell scripting, hotkeys, and window manager integration |
| **Asset Extraction Tool** | `inzone-tools fetch / assets` | Installer SHA-256 verification, MSI/CAB static extraction, ILSpy decompilation, and audio coefficient generation |
| **Diagnostics & Verification** | `inzone-tools diagnose-*` | PipeWire impulse response measurements, LADSPA numerical accuracy verification, and session routing diagnostics |

---

## 6. Scope & Non-Goals

| Item | Status | Rationale & Alternatives |
|---|:---:|---|
| **Smartphone Ear Photo Cloud Analysis** | Out of Scope | Requires communication with proprietary Sony cloud servers and account authentication. To safeguard user privacy and maintain offline operation, cloud communication is omitted. Users can generate `personalized_hrtf.hki` and `YY2987.ba` files via the mobile app/Windows Hub and import them locally. |
| **Over-the-Air (OTA) Firmware Flashing** | Out of Scope (Version query supported) | Flashing firmware over reverse-engineered wireless USB protocols carries severe device bricking risks. For hardware safety, only firmware version inspection is provided. Firmware updates should be performed via the official Windows INZONE Hub utility. |
