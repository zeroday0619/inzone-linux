# Sony INZONE H9 II for Linux

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Swift 6.3](https://img.shields.io/badge/Swift-6.3%2B-orange.svg)](https://www.swift.org)
[![PipeWire](https://img.shields.io/badge/Audio-PipeWire%20%2F%20WirePlumber-brightgreen.svg)](https://pipewire.org)

A native Linux driver and DSP audio stack for the **Sony INZONE H9 II (MDR-G900N / Model Code YY2987)** wireless gaming headset.

Reverse-engineered from the Windows-only **INZONE Hub** utility, this project implements 7.1-channel spatial audio, Sony proprietary 10-band EQ and presets, USB HID hardware control (ANC, Ambient Sound, Sidetone, Game/Chat balance), and automated profile switching using **PipeWire**, **WirePlumber**, and an **Embedded Swift native LADSPA engine**.

Enjoy the complete feature set of the headset on Linux without requiring Windows utilities or virtual machines.

---

## Key Features

- **Authentic Sony 7.1ch Spatial Audio**
  - Real-time rendering driven by Sony official 512-tap FIR HRTF filters and the H9 II-dedicated 7-stage IIR Biquad hardware correction filter (`wh_g910n_standard.ba`).
  - Integrated 32-sample lookahead internal spatial ALC (dynamic limiter) to prevent clipping and balance volume.
- **Complete Hardware Control (USB HID)**
  - Direct control over Active Noise Cancellation (ANC on/off), 20-step Ambient Sound level, Voice Focus mode, Sidetone (mic monitoring), and Game/Chat hardware balance.
  - Configurable physical button toggle cycles, power-on defaults, auto-power-off timer, voice guidance language, and real-time battery status monitoring.
- **Sony Official 10-Band EQ & 7 Presets**
  - Built-in Flat, FPS 1/2/3, Immersion Flat (RPG), Bass Boost, and Music/Video presets utilizing Sony precision-tuned Biquad coefficient tables.
  - Fully customizable 10-band user EQ (-12 dB to +12 dB in 1 dB steps).
- **Automatic Game & App Profile Switching**
  - Automatically switches to surround/FPS profiles when games launch (supporting native Linux, Steam, Proton, and Wine binaries) and switches to voice mode when Discord launches, restoring the previous profile when exited.
- **Intuitive TUI & Powerful CLI**
  - Interactive terminal interface (`inzone-profile`) driven by SwiftTUI with mouse and keyboard controls, plus a comprehensive CLI for scripting, hotkeys, and window manager integration.
- **Windows Profile & Personalized HRTF Interoperability**
  - Import and export `SoundProfile.json` from/to Windows INZONE Hub.
  - Import mobile ear-measurement personalization files (`personalized_hrtf.hki`, `YY2987.ba`) to apply personalized spatial audio on Linux.

---

## System Requirements

- **OS**: Linux (PipeWire and WirePlumber desktop environment)
- **Target Device**: Sony INZONE H9 II USB Wireless Transceiver (USB VID `054C`, PID `0FA8`)
- **Required Runtime Packages**:
  - `pipewire-bin` (`pw-dump`, `pw-cat`, `pw-cli`, etc.)
  - `pulseaudio-utils` (`pactl` for volume control)
  - `systemd` user service support
- **Build Tools**:
  - Swift 6.3 or higher ([Official Swift Installation Guide](https://www.swift.org/install/linux/))
  - `build-essential` (`make`, C compiler, and linker)
  - `ladspa-sdk` (LADSPA C headers)
  - `7zip` (`7z` or `7zz`)
  - `.NET 10 SDK` (for running ILSpy during asset extraction from official installer)

> **Note**: Neither the Swift toolchain nor .NET is required for daily operation after installation. CLI binaries are statically linked against the Swift standard library, and the DSP plugin is compiled using Embedded Swift for minimal, standalone execution.

---

## Quick Start

In compliance with Sony proprietary licensing, no binary assets are bundled in this repository. A single `make` invocation downloads the official installer, verifies its integrity, extracts filter assets, builds the binaries, and installs the driver stack.

### 1. Install Dependencies
Debian / Ubuntu:
```sh
sudo apt update
sudo apt install pipewire-bin pulseaudio-utils 7zip build-essential ladspa-sdk
```

### 2. Build and Install
**Run as a regular user (not root)**:
```sh
# Fetch dependencies, build, and install the complete stack
make
```

> **Privilege Note**: Do not run `sudo make`. User-space files (`~/.local/bin`, `~/.config`) are installed under regular user permissions. `sudo` is requested only at the final step for installing udev rules (`/etc/udev/rules.d`) and system LADSPA plugins (`/usr/lib/ladspa`).

Run installation in a foreground terminal. During administrator authentication,
the installer hands terminal control to `sudo`, which reads the password directly.
Password characters are not echoed. Terminal ownership and input settings are
restored when the command finishes, fails, is interrupted, or times out.

### 3. Reconnect Device & Activate
Unplug and replug the USB dongle to apply the new udev permissions, then activate the surround sound profile:

```sh
inzone-profile surround
```

The Sony spatial audio stack is now active.

---

## Interactive TUI Guide

See [DESIGN.md](DESIGN.md) for the visual system, interaction contracts, and design-review requirements.

Running `inzone-profile` without arguments opens the interactive terminal controller:

```sh
inzone-profile
```
*(Recommended terminal size: 72 columns × 24 rows or larger)*

The profile list displays names without ordinal numbers or active-state labels.
Bold text and a neutral highlight identify the selected profile.
The details area describes the selected profile. Selecting a row does not apply it;
use **Apply** or **Enter** to activate the selection.
The selected profile's description and sound-processing values appear in a separate
detail column. Unavailable settings show `—`.

### Touch Layout

The default layout places a profile list beside its details. Primary action buttons
use three-row targets; profile rows use two rows in short windows and three rows
when at least 30 terminal rows are available. Tap **Controls** for DSP values, EQ,
and presets. The bottom action area opens **Device** and **Automation** directly.
**Device & apps** also provides these destinations and personalization imports.
Tap **Compact** for the dense desktop layout, or **Touch layout** to return.
The layout choice lasts for the current session.

Both layouts share a fixed three-row header and two-row footer. The header shows
the current screen and the layout toggle. The footer displays the operation status
or device error on its first row and screen-specific shortcuts on its second row.
Content and the workspace sidebar occupy the area between them, so navigation,
editing, and resizing do not move the header or footer into the content area.
A blank row separates the content from both the header and footer.

The interface uses neutral graphite surfaces, blue primary actions, and restrained
secondary text. Hover and press feedback cover the full target. Releasing outside
a button cancels its action. Selection uses weight and neutral shading; destructive
actions use red labels. Button labels have no decorative brackets or selection
prefixes. DSP controls show their current
values and are disabled when the selected profile does not support them.

At 110 columns or wider, the touch layout adds a workspace sidebar with direct
navigation to Profiles, Device, and Automation. Profile details remain in the main
content area instead of repeating in the sidebar.
Navigation is disabled while an editor is open or an operation is running;
save or cancel the editor before changing sections. Smaller windows retain the
single-panel layout, including the 72×24 minimum.

The touch EQ screen shows all ten band gains as bars around a 0 dB baseline.
Tap a bar or frequency to select a band, then drag vertically to adjust its draft
gain within −12 to +12 dB. Dragging stays on the original band and clamps at the
plot limits. Frequency-label taps and drags select without changing gain.
Use **− 1 dB** / **+ 1 dB** for precise changes and **‹** / **›** to switch bands.
The graph's drag resolution depends on terminal height. It displays band settings,
not the calculated filter frequency response. **Reset all** resets the draft for
all ten bands. Only **Save & Apply** saves it; **Cancel** discards it.
Preset and automation lists follow the selection across pages. Device settings use
category tabs with **Previous** and **More settings** for longer sections.

Touch operation requires a terminal or remote terminal client that translates
touch taps into primary-pointer press and release reports. Target sizes use terminal
cells, not physical pixels; adjust the terminal font size for the display.
Native multitouch gestures are not used. Text entry requires a physical or system
onscreen keyboard; the TUI does not provide a virtual keyboard.

The layout adapts the [HIG layout](https://sosumi.ai/design/human-interface-guidelines/layout),
[color](https://sosumi.ai/design/human-interface-guidelines/color), and
[button](https://sosumi.ai/design/human-interface-guidelines/buttons) principles to
terminal cells. It does not implement native Apple materials or physical point sizing.
It also applies [One UI's viewing and interaction areas](https://developer.samsung.com/one-ui/index.html),
[grouped settings lists](https://developer.samsung.com/one-ui/comp/list.html), and
[concise, task-focused wording](https://developer.samsung.com/one-ui/writing/simple-and-human.html).
Status information stays above the settings, and Apply/Discard stay at the bottom.

### Visual Review

Export hardware-independent screen previews and render their actual ANSI colors:

```sh
INZONE_TUI_PREVIEW_DIRECTORY=/tmp/inzone-preview swift test --filter VisualPreviewTests
python3 tools/render_tui_snapshot.py /tmp/inzone-preview /tmp/inzone-preview-png
```

The optional PNG renderer requires Pillow and DejaVu Sans Mono fonts. Neither is a
runtime dependency. Preview data is synthetic and does not read device settings.

### Mouse Controls

Mouse operation requires a terminal that forwards SGR mouse reports. SwiftTUI 0.12.0
enables reporting for the interactive session and restores it on normal exit.
The interface uses the framework's [pointer and gesture APIs](https://minacle.github.io/swift-tui/latest/documentation/swifttuiessentials/inputrecognition/).
Keyboard shortcuts remain available when mouse reports are unavailable.

| Target | Mouse action | Result |
|:---|:---|:---|
| Profile, preset, device, or automation row | Click | Select the row without applying or deleting it |
| Lists and EQ | Wheel up/down | Move the selection as with the arrow keys; long lists follow the selection |
| Button | Click | Run the displayed action, including navigation, Apply, Back, and Cancel |
| EQ band | Click **−** or **+** | Select the band and adjust its draft gain by 1 dB, within −12 to +12 dB |
| EQ graph | Tap to select; drag vertically to adjust | Edit the original band's draft gain without applying it |
| EQ footer | Click **Reset**, **Save & Apply**, or **Cancel** | Reset the draft to zero, save it, or discard it |
| Device setting | Click **−** / **+**, or tap an On/Off value | Stage a value marked `*`; changing rows or tabs preserves it |
| Device action area | Click **Apply** or **Discard** | Apply all available drafts or clear them without writing to the device |
| Input form | Click the field, **Continue** / **Save**, or **Cancel** | Edit text, advance or complete the form, or return to the previous screen |

The compact EQ meter shows the draft gain and its zero reference. Profile DSP controls
(DRC, Output ALC, Mic AGC, and HRTF) apply immediately, as their keyboard shortcuts do.
Selection and setting changes are blocked while an operation is in progress.

### Keyboard Shortcuts

| Shortcut | Action | Description |
|:---:|:---|:---|
| **↑ / ↓** or **1–6** | Move cursor | Browse through available profiles |
| **Enter** | Apply profile | Immediately commit selected profile and DSP graph to WirePlumber |
| **H** | Device controls | Open noise, sound, microphone, and system settings |
| **E** | Edit 10-band EQ | Adjust bands from 31.5 Hz to 16 kHz (-12 to +12 dB) |
| **S** | Select Sony preset | Choose from Flat, FPS 1/2/3, RPG, Bass Boost, or Music/Video |
| **D** | Dynamic Range Control (DRC) | Cycle through Off → Low → High |
| **A** | Output Auto Level Control | Toggle profile-specific Output ALC |
| **M** | Mic Auto Gain Control | Toggle profile-specific Microphone AGC |
| **P** | HRTF mode | Select Standard or Personal HRTF in surround mode |
| **I** | Import personalization | Input file paths for mobile HKI and correction BA files |
| **U** | Process auto-switching | Edit executable binding rules and toggle background daemon |
| **Q / Esc** | Quit | Exit TUI (current audio settings remain active) |

### Device Controls (H Key)

The touch layout keeps connection and battery status in a compact top area.
Battery status includes the reported percentage, a ten-segment gauge, and charging
state. Low charge (20% or below) and charge errors use the warning color.
Missing or invalid battery readings remain unavailable rather than appearing as 0%.
Disconnected snapshots do not retain stale battery or firmware values.

Settings are grouped into Noise, Sound, Mic, System, and Info tabs. Each setting
has its own value control: tap binary values to toggle them or use the adjacent
minus/plus buttons. Firmware versions appear in Info. Mic contains the microphone
monitor control. Setting labels align left and values align right.

Tap a tab or swipe left/right across the tabs or settings area to change sections.
Each swipe moves one section and stops at either end. Swiping across a control does
not change its value. Tabs and setting rows are three rows high with centered text.

Draft changes survive row selection, tab changes, refresh, and workspace navigation.
Apply writes and verifies each setting sequentially. Confirmed readbacks clear the
corresponding drafts; unconfirmed drafts remain after a failure. If a draft's setting
is unavailable, refresh the connection or discard the drafts before applying.
Drafts are held only for the current TUI session.

- **← / → Arrow Keys**: Adjust selected hardware parameter (e.g., cycle ANC modes, change Sidetone level)
- **Enter**: Apply the staged device and system-audio settings
- **R**: Refresh live headset state (battery level, firmware version, etc.)
- **T**: Microphone loopback audio test (up to 30 seconds, pure in-memory playback without file writes)

---

## CLI Command Reference

The command-line interface enables scripting, desktop shortcuts, and window manager integration (i3, sway, Hyprland).

### 1. Profile Management
```sh
# Switch profile immediately
inzone-profile surround      # 7.1ch surround mode
inzone-profile fps           # Footstep-boosted FPS mode
inzone-profile music         # Music listening mode

# Check current status and list profiles
inzone-profile --status
inzone-profile --list
```

### 2. Hardware Device Control (`--device-set`, `--device-status`)
```sh
# Query live headset status (battery, firmware, ANC state in JSON)
inzone-profile --device-status

# Change noise control mode (0: Off, 1: Noise Canceling, 2: Ambient Sound)
inzone-profile --device-set anc 1

# Set sidetone (mic monitoring) level (0 to 10)
inzone-profile --device-set sidetone 4

# Adjust ambient sound volume level (1 to 20)
inzone-profile --device-set ambient_level 12

# Adjust Game / Chat hardware balance (0 to 100, 50 is center)
inzone-profile --device-set game_chat 50
```

> **Supported hardware fields**: `anc`, `ambient_level`, `voice_focus`, `game_chat`, `sidetone`, `toggle_off`, `toggle_nc`, `toggle_ambient`, `nc_startup`, `bt_startup`, `auto_power`, `language`, `guidance`

### 3. DSP and EQ Parameter Control
```sh
# Apply Sony official presets
inzone-profile --preset fps fps1
inzone-profile --preset surround immersion_flat

# Configure Dynamic Range Control (0: Off, 1: Low, 2: High)
inzone-profile --set fps drc 2

# Set custom 10-band EQ values (-12 to +12 dB)
inzone-profile --set music eq '[0, 0, 1, 2, 0, 0, -1, 1, 2, 3]'

# Enable microphone auto gain control
inzone-profile --set voice mic_agc true

# Export and import profile settings
inzone-profile --export my_settings.json
inzone-profile --import my_settings.json
```

---

## Automated Profile Switching by Process Detection

Configure a background service to automatically activate surround mode when launching a game and voice mode when launching Discord:

```sh
# Bind executable names to profiles (last argument is priority; higher wins)
inzone-profile --auto-bind cs2 fps 15
inzone-profile --auto-bind game.exe surround 10
inzone-profile --auto-bind discord voice 5

# View registered auto-switch rules
inzone-profile --auto-config

# Enable background service (registers and starts systemd user daemon)
inzone-profile --auto-enable

# Disable service
inzone-profile --auto-disable

# Remove a specific rule
inzone-profile --auto-remove game.exe
```

- **Full Wine / Proton Support**: Accurately detects Windows process names (`*.exe`) running under Steam Proton or Wine in addition to native Linux executables.
- **Audio Debounce**: Requires a 2-second continuous state match before switching, preventing transient audio interruptions during brief process spawns.
- **Smart Restoration & Manual Priority**: Automatically restores the previous profile upon game exit. If the user manually changes profiles while a game is running, the manual selection takes precedence and is retained.

```mermaid
sequenceDiagram
    autonumber
    participant App as Target Process (Game / Discord)
    participant Daemon as Auto Daemon (inzone-profile-auto)
    participant PipeWire as WirePlumber / PipeWire
    participant Headset as INZONE H9 II Transceiver

    App->>Daemon: Process launch detected (Linux native or Wine/Proton exe)
    Note over Daemon: 2-second debounce wait (prevents glitches)
    Daemon->>PipeWire: Request mapped profile (surround / fps / voice)
    PipeWire->>Headset: Update audio routing and DSP nodes in real time
    Note over App,Headset: Audio renders with optimized profile
    App->>Daemon: Process exit detected
    Daemon->>PipeWire: Restore previous profile
    PipeWire->>Headset: Revert audio routing to baseline settings
```

---

## Windows Profiles & Personalized HRTF Integration

### 1. Import Mobile App Personalized HRTF
Personalized spatial audio generated via ear photography in the Sony mobile app can be imported into Linux:
- **Windows Path**: `%APPDATA%\Sony\INZONE Hub\VirtualizeUser`
- **Required Files**: `personalized_hrtf.hki` and model correction file `YY2987.ba`

```sh
# Import personalized files (automatic Cipher 7 decryption & validation)
inzone-profile --personalize-import /path/to/personalized_hrtf.hki /path/to/YY2987.ba

# Enable personalized HRTF in surround profile
inzone-profile --set surround hrtf '"personal"'
```

### 2. Windows INZONE Hub Profile (`SoundProfile.json`)
Directly import or export profiles configured in Windows INZONE Hub (`%APPDATA%\Sony\INZONE Hub\SoundProfile.json`):

```sh
# List profiles in Windows file
inzone-profile --windows-list /path/to/SoundProfile.json

# Import a specific profile to Linux
inzone-profile --windows-import surround /path/to/SoundProfile.json 1

# Export Linux configuration to a Windows-compatible JSON file
inzone-profile --windows-export surround exported_profile.json
```

---

## Audio Architecture & DSP Pipeline

The INZONE H9 II wireless USB transceiver exposes two independent physical PCM playback streams:
- **Game Stream (PCM 1)**: `alsa_output.usb-Sony_INZONE_H9_II-00.stereo-game` (games and primary audio)
- **Chat Stream (PCM 0)**: `alsa_output.usb-Sony_INZONE_H9_II-00.stereo-chat` (Discord and voice communications)

The driver creates a virtual 7.1-channel surround sink (`inzone.sony-surround`) that receives multi-channel audio, processes it through the DSP pipeline below, and renders binaural stereo to the Game stream:

```mermaid
flowchart TD
    subgraph Input ["Audio Input"]
        In71["7.1ch Multichannel Stream<br>(FL, FR, FC, LFE, RL, RR, SL, SR)"]
        InChat["Voice Chat Stream<br>(Discord, voice apps)"]
    end

    subgraph PipeWire ["PipeWire Virtual Surround Node (inzone.sony-surround)"]
        Stage1["1. Sony Spatial Convolution (FIR 512-tap)<br>Binaural 3D soundfield synthesis from official HRTF"]
        Stage2["2. Model BA Equalization (7-stage IIR Biquad)<br>H9 II hardware acoustic correction (wh_g910n_standard.ba)"]
        Stage3["3. Internal Spatial ALC (Lookahead Limiter)<br>32-sample lookahead peak limiter and +1.0 dB boost"]
        
        subgraph InlineDSP ["Optional Inline DSP Chain"]
            DSP1["Amp1 (-18 dB attenuation)"]
            DSP2["Sony ModeEqualizer (Immersive soundfield)"]
            DSP3["Sony 10-band User EQ (Precalculated tables)"]
            DSP4["Output ALC (Threshold -18 dB, Ratio 1000:1)"]
            DSP5["Amp2 (+18 dB recovery)"]
            DSP6["Peak DRC (Low / High)"]
            DSP1 --> DSP2 --> DSP3 --> DSP4 --> DSP5 --> DSP6
        end

        Stage1 --> Stage2 --> Stage3 --> InlineDSP
    end

    subgraph Hardware ["Sony INZONE H9 II Transceiver (054C:0FA8)"]
        SinkGame["Game Stream (PCM 1, Interface 4)<br>16-bit 48kHz Stereo"]
        SinkChat["Chat Stream (PCM 0, Interface 1)<br>16-bit 48kHz Stereo"]
    end

    In71 --> Stage1
    InlineDSP --> SinkGame
    InChat --> SinkChat
```

> **In-Game Audio Configuration**:
> If a game provides its own headphone spatializer or 3D audio engine, running both can cause phase cancellation and muffled sound. Set your in-game audio output to **7.1 Surround Speakers**.

---

## Development & Build Targets

Common `make` targets for repository maintenance:

```sh
# 1. Synchronize Swift dependencies
make sync

# 2. Download official installer and verify SHA-256
make fetch

# 3. Extract assets statically and decompile
make assets

# 4. Build all targets (CLI/TUI + Embedded Swift LADSPA DSP)
make build

# 5. Run test suite and DSP numerical verification
make check

# 6. Display Make targets and options
make help
```

---

## Technical Documentation

Detailed reverse-engineering specifications and internal implementation architectures are available in `docs/`:

- [Feature Specification & Implementation Status (docs/features.md)](docs/features.md): Feature matrix, scope, and Hub parity
- [Reverse Engineering Technical Specification (docs/reverse-engineering.md)](docs/reverse-engineering.md): Binary disassembly, key derivation algorithms, and USB HID protocol
- [Repository Structure & Asset Lifecycle (docs/repository-files.md)](docs/repository-files.md): Clean-room asset policies, build lifecycle, and directory layout
- [Implementation & Verification Audit (docs/completion-audit.md)](docs/completion-audit.md): Numerical precision verification and diagnostic test results
- [Analysis Reports and Verification Archive (analysis/README.md)](analysis/README.md): Measurement summaries and JSON reports

---

## License

Distributed under the [MIT License](LICENSE). Sony and INZONE are trademarks or registered trademarks of Sony Group Corporation. This project is an independent community open-source effort and is not affiliated with or endorsed by Sony.
