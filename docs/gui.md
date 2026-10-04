# Qt desktop interface

The desktop combines Swift application logic with Qt Quick presentation through
[Qt Bridge for Swift](https://github.com/qt/qtbridge-swift). The bridge is pinned
to `0.2.0-beta` commit `407714006dd21107b70db6547ce75e43df0c8a75` because its
preview API can change between revisions. The desktop uses a separate CMake
build; the existing CLI, TUI, and service use Swift Package Manager.

## Architecture

```text
Qt Quick/QML -> Swift GuiModel -> session D-Bus -> Swift ControlService -> InzoneCore
```

The GUI does not run shell commands to perform settings changes. A small C
adapter wraps systemd's sd-bus API for typed D-Bus calls. The Swift service owns
request validation and invokes the same profile controller, settings stores,
and headset readback used by the command-line interface.

D-Bus requests run on a serial Swift worker queue. The Qt event loop remains
responsive while a profile changes. A QML timer publishes completed results on
the GUI thread because Qt Bridge's Linux event loop does not run Swift's main
dispatch queue. Status refreshes every five seconds; background reads do not
block editing. Changes made by the CLI or automatic profile watcher appear in
the next status refresh.

The service opens and closes the HID device for each request. It does not retain
the exclusive device lock between requests, so existing CLI and TUI sessions can
continue to access the headset. Device or audio errors are separate from saved
profile data, allowing the GUI to display profiles while a headset is absent.

## Build and installation

The verified development configuration uses Swift 6.3.3 and Qt 6.11.2. Minimum
GUI requirements are Swift 6.3, Qt 6.10, CMake 3.29, Ninja, Qt Core private
headers, Qt Quick Controls and Layouts, Qt Wayland Client and its platform plugin,
and libsystemd development headers. Tests also require Qt Quick Test and Qt Test.
The Qt Bridge dependency is fetched during CMake configuration.

```sh
make gui-build SWIFT=/path/to/swift/toolchain/usr/bin/swift
make gui-test SWIFT=/path/to/swift/toolchain/usr/bin/swift
make gui-install SWIFT=/path/to/swift/toolchain/usr/bin/swift
```

`GUI_BUILD_DIRECTORY` defaults to `build/gui`. `GUI_CMAKE_FLAGS` accepts
additional CMake configuration options such as a Qt installation prefix.
`INSTALL_HOME` defaults to the current desktop user's home. The GUI installation
uses `INSTALL_HOME/.local` and does not install the audio assets or system DSP
plugin; install the main audio stack first.

| Installed path relative to `.local` | Purpose |
| --- | --- |
| `bin/inzone-gui` | Swift Qt desktop executable |
| `bin/inzone-service` | Swift D-Bus service |
| `share/inzone-linux/gui/` | QML screens and components |
| `share/applications/dev.zeroday0619.desktop` | Application menu entry |
| `share/icons/hicolor/scalable/apps/dev.zeroday0619.svg` | Application icon |
| `share/dbus-1/services/dev.zeroday0619.service` | D-Bus activation |
| `share/systemd/user/inzone-control.service` | User service lifecycle |

The GUI dynamically links Qt and the selected Swift toolchain's runtime. Keep
those runtime libraries installed. The service uses a statically linked Swift
runtime and dynamically links the system sd-bus library.

The first GUI request activates the service through the session bus. Inspect
service failures with:

```sh
systemctl --user status inzone-control.service
journalctl --user -u inzone-control.service
```

## Presentation and editing

The QML theme adapts [Fluent 2 color roles](https://fluent2.microsoft.design/color),
[native typography](https://fluent2.microsoft.design/typography), and
[layout spacing](https://fluent2.microsoft.design/layout). Neutral surfaces group
related settings; blue identifies primary actions and selection. The interface
provides light and dark themes, keyboard focus indicators, accessible control
names, and scrollable pages. It uses the platform font instead of bundling a
Microsoft font.

- Selecting a profile previews its options. **Apply profile** activates it.
- Equalizer sliders edit a draft. **Apply equalizer** sends all ten gains in one
  request. Failed applies retain the draft; background refreshes do not discard it.
- DSP switches and device controls apply their labeled setting when activated.
  The service validates values and verifies device writes through readback.
- Microphone controls distinguish software automatic gain from host input volume
  and hardware microphone mute.
- Custom profiles support creation, rename, and deletion. Deletion requires a
  confirmation dialog; controller restrictions on active and referenced profiles
  still apply.
- Application rules select profiles by process name and priority using the existing
  automatic profile service.
- Unavailable device fields remain disabled. Errors are shown until dismissed or
  superseded by another operation. Firmware versions are read-only.

`Ctrl+1` through `Ctrl+4` select the four pages. `Ctrl+R` refreshes status.

## Validation

```sh
ctest --test-dir build/gui --output-on-failure
QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software \
  build/gui/bin/inzone-gui --smoke-test --screenshot /tmp/inzone-gui.png
```

The screenshot option captures the actual Qt Quick window. Smoke validation
checks that a visible root window was created; it does not establish hardware
write success. D-Bus integration tests and live device checks cover the transport
and control paths separately.

## Wayland

The desktop selects native Wayland in Wayland sessions and uses
`dev.zeroday0619` as its desktop application identifier. See
[Wayland support](wayland.md) for platform overrides, diagnostics, compositor
targets, scale validation, and the acceptance record.

## Debian distribution

The [Debian package](debian.md) includes the required Swift runtime privately.
Its executables do not require an installed Swift toolchain. The Debian 13
variant also carries a compatible Qt runtime with application-specific QML and
plugin paths. Native packages use the distribution's Qt and declare the
corresponding library and QML dependencies.
