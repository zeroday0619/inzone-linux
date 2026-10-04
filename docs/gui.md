# Qt desktop interface

The INZONE desktop provides profile, equalizer, microphone, headset, and
application-rule controls. Swift application logic connects to Qt Quick through
[Qt Bridge for Swift](https://github.com/qt/qtbridge-swift).

## Install and launch

For a packaged installation, follow the [Debian package guide](debian.md). Packages
include a private Swift runtime and do not require an installed Swift toolchain.
Both the Debian 13 and forky packages built by [GitHub Actions](ci.md) also bundle
Qt 6.11.2 with application-specific QML and plugin paths. Native packages built
with the distribution's Qt declare the corresponding library and QML dependencies.

After installation, open **INZONE Control** from the application menu or run:

```sh
inzone-gui
```

The first GUI request activates the session D-Bus service. To inspect a service
failure:

```sh
systemctl --user status inzone-control.service
journalctl --user -u inzone-control.service
```

### Build and install from source

The verified development configuration uses Swift 6.3.3 and Qt 6.11.2.

| Requirement | Minimum or required component |
| --- | --- |
| Swift | 6.3 |
| Qt | 6.10, including Core private headers, Qt Quick Controls and Layouts, Qt Wayland Client, and its platform plugin |
| Build tools | CMake 3.29, Ninja, pkg-config, and host `wayland-scanner` (`libwayland-bin` on Debian/Ubuntu) |
| D-Bus library | libsystemd development headers |
| Tests, enabled by default | Qt Quick Test, Qt Test, the QtTest QML module, Python 3, and `dbus-run-session` |

`BUILD_TESTING` defaults to `ON`, so the test requirements also apply to the
standard build and installation commands. Debian provides the QtTest QML module
in `qml6-module-qttest`. To omit tests, pass
`GUI_CMAKE_FLAGS='-DBUILD_TESTING=OFF'`. Re-enable `BUILD_TESTING` before running
`gui-test`.

```sh
make gui-build SWIFT=/path/to/swift/toolchain/usr/bin/swift
make gui-test SWIFT=/path/to/swift/toolchain/usr/bin/swift
make gui-install SWIFT=/path/to/swift/toolchain/usr/bin/swift
```

The desktop uses CMake; the CLI, TUI, and service use Swift Package Manager.
CMake fetches Qt Bridge `0.2.0-beta` at commit
`407714006dd21107b70db6547ce75e43df0c8a75`. The pin keeps the build on a known
revision of the preview API.

| Build variable | Default and purpose |
| --- | --- |
| `GUI_BUILD_DIRECTORY` | `build/gui`; CMake build and test output directory |
| `GUI_CMAKE_FLAGS` | Additional CMake options, such as a Qt installation prefix |
| `INSTALL_HOME` | Current desktop user's home; installation prefix is `INSTALL_HOME/.local` |

The GUI installation does not install audio assets or the system DSP plugin.
Install the main audio stack first. Source-built GUI executables dynamically link
Qt and the selected Swift toolchain's runtime; keep those libraries installed.
The service statically links the Swift runtime and dynamically links the system
sd-bus library.

| Installed path relative to `.local` | Purpose |
| --- | --- |
| `bin/inzone-gui` | Swift Qt desktop executable |
| `bin/inzone-service` | Swift D-Bus service |
| `share/inzone-linux/gui/` | QML screens and components |
| `share/applications/dev.zeroday0619.desktop` | Application menu entry |
| `share/icons/hicolor/scalable/apps/dev.zeroday0619.svg` | Application icon |
| `share/dbus-1/services/dev.zeroday0619.service` | D-Bus activation |
| `share/systemd/user/inzone-control.service` | User service lifecycle |

## Edit settings

- Select a profile to preview its options. **Apply profile** activates it.
- Equalizer sliders edit a draft. **Apply equalizer** sends all ten gains in one
  request. Failed applies retain the draft, and background refreshes preserve it.
- DSP switches and device controls apply their labeled setting when activated.
  The service validates values and verifies device writes through readback.
- Microphone controls distinguish software automatic gain, host input volume,
  and hardware microphone mute.
- Create, rename, or delete custom profiles. Deletion requires confirmation;
  controller restrictions on active and referenced profiles still apply.
- Application rules select profiles by process name and priority through the
  existing automatic profile service.
- Unavailable device fields stay disabled. Errors remain visible until dismissed
  or superseded by another operation. Firmware versions are read-only.

`Ctrl+1` through `Ctrl+5` select Sound, Microphone, Headset, App profiles, and
About, respectively. `Ctrl+R` refreshes status.
Status refreshes every five seconds when no D-Bus request is pending. Changes
made by the CLI or automatic profile watcher appear in the next refresh.

### View application information

Open **About** or press `Ctrl+5` to view the application version, developer name
and email address, and MIT license information. The version comes from the CMake
project version used to build the executable. About remains available when the
D-Bus service or headset is unavailable and while a settings request is pending.

The developer profile, project repository, issue tracker, and license buttons
open their addresses in the default browser when activated. Viewing About does
not change headset or audio settings. The developer email address is selectable
for copying.

Select **Dependencies and licenses** in About to open the dependency list. Each
entry identifies the component, version, license, and source address. Select
**License** to read the included license text and notices offline.
Source buttons open the component's website in the default browser.

The [MIT license](../LICENSE) applies to the project's original source code.
Dependencies retain their own license terms. The pinned `swift-terminal` 0.0.2
[source snapshot](../Vendor/swift-terminal/UPSTREAM.md) contains no license
declaration, so the list marks its license as unavailable.

### Presentation and accessibility

The QML theme adapts Fluent 2 [color roles](https://fluent2.microsoft.design/color),
[typography](https://fluent2.microsoft.design/typography), and
[spacing](https://fluent2.microsoft.design/layout). Neutral surfaces group related
settings, and blue identifies primary actions and selection. The interface
provides light and dark themes, keyboard focus indicators, accessible control
names, and scrollable pages. It uses the platform font without bundling a
Microsoft font.

## Control architecture

```text
Qt Quick/QML -> Swift GuiModel -> session D-Bus -> Swift ControlService -> InzoneCore
```

The GUI sends typed D-Bus calls through a C adapter for systemd's sd-bus API. It
does not run shell commands to change settings. The Swift service validates
requests and invokes the same profile controller, settings stores, and headset
readback as the CLI. See the [D-Bus API](dbus.md) for the wire contract.

D-Bus requests run on a serial Swift worker queue so profile changes do not block
the Qt event loop. A QML timer publishes completed results on the GUI thread
because Qt Bridge's Linux event loop does not run Swift's main dispatch queue.
Background reads do not block editing.

The service opens and closes the HID device for each request. Releasing the
exclusive device lock between requests preserves CLI and TUI access. Device and
audio errors are separate from saved profile data, so profiles remain available
when the headset is absent.

## Validate the build

```sh
ctest --test-dir build/gui --output-on-failure
QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software \
  build/gui/bin/inzone-gui --smoke-test --screenshot /tmp/inzone-gui.png
```

The screenshot captures the Qt Quick window. The smoke test checks that a visible
root window exists; hardware write success requires separate device checks.
D-Bus integration tests cover the transport and control paths.

In Wayland sessions, the desktop selects native Wayland and uses
`dev.zeroday0619` as its application identifier. See [Wayland support](wayland.md)
for platform overrides, diagnostics, compositor targets, scaling tests, and the
acceptance record.
