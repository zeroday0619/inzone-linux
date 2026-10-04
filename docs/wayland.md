# Wayland desktop support

## Scope

The supported desktop targets are KDE Plasma, GNOME, Hyprland, and Sway. The
compatibility target covers the existing INZONE GUI: profile and equalizer
editing, microphone and headset controls, application rules, keyboard and text
input, window management, and per-output scaling. A successful smoke test alone
is not evidence that every desktop interaction has been verified.

## Runtime contract

- A Wayland session selects the native Qt `wayland` platform. There is no implicit
  XWayland fallback when that session cannot be opened.
- An explicit `QT_QPA_PLATFORM` or Qt `-platform` argument takes precedence. This
  supports deliberate X11 sessions and isolated offscreen diagnostics.
- The Wayland `xdg_toplevel.app_id`, Qt application name, desktop entry basename,
  and icon identifier are `dev.zeroday0619`. The embedded SVG also supplies an
  icon when the desktop's icon theme has no matching entry.
- Qt Quick uses logical pixels. Window sizing follows the screen's logical
  dimensions; compact navigation and scrolling support a 640 × 360 logical
  viewport. Focused settings scroll into view, including when an input panel
  reduces the available height.
- Qt handles native window decorations, popup placement, clipboard and input
  method transport. The application preserves input method composition and
  commits text before an explicit Save action.
- Device operations use session D-Bus. Automatic profile selection scans
  same-user processes in `/proc`; it does not inspect X11 windows or require
  an active-window extension. Rules apply to running applications, including
  background applications.

Qt documents the [Wayland platform integration](https://doc.qt.io/qt-6/wayland-and-qt.html),
[desktop file identity](https://doc.qt.io/qt-6/qguiapplication.html#desktopFileName-prop),
and [logical-pixel and per-window DPI model](https://doc.qt.io/qt-6/highdpi.html).
The window's device pixel ratio is authoritative for fractional scaling;
[`QScreen::devicePixelRatio()`](https://doc.qt.io/qt-6.11/qscreen.html#devicePixelRatio-prop)
can differ from the window DPR on Wayland.

## Requirements and diagnostics

The GUI build requires Qt Wayland Client and its platform plugin in addition to
the Qt Quick dependencies. On the verified Debian Qt 6.11.2 installation,
`qt6-base-dev` provides the Wayland Client CMake package and
`libqt6waylandclient6` provides `libqwayland.so`. Qt 6.10 distributions may package
these components separately as `qt6-wayland-dev` and `qt6-wayland`. The Wayland compositor is supplied by the
user's desktop; the application does not embed a compositor.

```sh
inzone-gui --smoke-test --diagnostics /tmp/inzone-wayland.json
cat /tmp/inzone-wayland.json
```

In a Wayland session, the report must contain `platformName: "wayland"`,
`nativeWayland: true`, `desktopFileName: "dev.zeroday0619"`, and an exposed window.
It also records Qt version, rendering API, screen names, logical sizes, window
DPR, and whether the icon is available. `--diagnostics -` writes to stdout.

To explicitly require native Wayland without an X11 connection:

```sh
env -u DISPLAY QT_QPA_PLATFORM=wayland inzone-gui \
  --smoke-test --diagnostics /tmp/inzone-native.json \
  --screenshot /tmp/inzone-native.png
```

The screenshot captures only the application's own window. A missing Wayland
socket or platform plugin is an error; installing or repairing the desktop's
Qt Wayland runtime resolves that failure. Explicit environment overrides remain
visible in the diagnostic report.

## Automated validation

```sh
make gui-test SWIFT=/path/to/swift/toolchain/usr/bin/swift
make gui-wayland-test SWIFT=/path/to/swift/toolchain/usr/bin/swift
```

`gui-test` covers application startup, the Swift/C D-Bus transport, QML controls,
and Qt input method events. Offscreen runs exercise scale factors 1, 1.25, 1.5,
and 2. These are simulated DPI tests, separate from native Wayland validation.

`gui-wayland-test` requires test tools `kwin_wayland`, `kscreen-doctor`, `qdbus6`
(or Qt 6 `qdbus`), and `dbus-run-session`. It creates a private D-Bus session,
Wayland socket and XDG directories. It never replaces the running desktop,
starts XWayland, changes physical outputs, or writes headset settings.

The native suite verifies:

- Native Wayland startup with no `DISPLAY`, actual `set_app_id` protocol traffic,
  an exposed window, and an available application icon.
- Native compositor scales 100%, 125%, 150%, and 200%, including fractional-scale
  protocol use and screenshot dimensions matching the window DPR.
- OpenGL and software Qt Quick rendering, explicit platform overrides, and
  failure on a nonexistent Wayland socket.
- Migration from a 100% virtual output to a 150% output. The existing window must
  receive the new preferred scale, retain its identity, and remain exposed.
- QML control interactions on every scale and Hangul preedit, Return/Enter,
  commit, cancellation, and exact saved text through `QInputMethodEvent`.

Artifacts are written under `build/gui/wayland-validation/` or the selected
`GUI_BUILD_DIRECTORY`. The native tests deliberately fail when their compositor
or protocol assertions are unavailable; they do not report a skip as a pass.

## Additional compositor suites

Enable the installed compositor executables explicitly. These are test tools,
not production dependencies of the INZONE application. GNOME tests require a
Python interpreter with PyGObject, Gio, and GLib.

```sh
make gui-test SWIFT=/path/to/swift/toolchain/usr/bin/swift \
  GUI_CMAKE_FLAGS='-DINZONE_WAYLAND_TESTS=ON -DINZONE_SWAY_EXECUTABLE=/usr/bin/sway -DINZONE_HYPRLAND_EXECUTABLE=/usr/bin/Hyprland -DINZONE_GNOME_SHELL_EXECUTABLE=/usr/bin/gnome-shell -DINZONE_GNOME_TEST_PYTHON=/usr/bin/python3'
```

Sway runs with its headless backend. Hyprland runs nested inside a separate
virtual KWin compositor. GNOME Shell runs with its headless backend and a virtual
monitor. All use private session buses with service auto-activation disabled,
separate XDG directories, and no XWayland server. GNOME's system-bus requests also
use its private test bus. The fixtures change only virtual display settings.

Each suite validates 100%, 125%, 150%, and 200% with actual compositor scales;
`QT_SCALE_FACTOR` is cleared. Hyprland's nested output explicitly uses
1920 × 1440 because its default 1280 × 720 mode adjusts a requested 150% scale to
160%. Requested and reported DPR must still match within 0.01.

Tests fail when prerequisites or expected protocol behavior are unavailable.
For extracted test packages, the caller can supply library/schema paths through
its environment; `INZONE_GNOME_TEST_ENVIRONMENT` accepts a CMake list of additional
GNOME fixture environment entries. No fixture downloads or installs a compositor.

## Acceptance record

Validation date: 2026-10-04. Application toolchain: Swift 6.3.3, Qt 6.11.2,
Qt Bridge `407714006dd21107b70db6547ce75e43df0c8a75`.

| Environment | Validation |
| --- | --- |
| KDE Plasma / KWin 6.7.4, physical desktop | Native startup with `DISPLAY` removed, OpenGL, correct application ID and icon, exposed window at 150%, live D-Bus device status |
| KWin 6.7.4, isolated virtual outputs | Native 100/125/150/200% scaling, 26 QML/input-method tests at each scale, OpenGL and software rendering, 100% to 150% output migration |
| Sway 1.12, isolated headless output | Native 100/125/150/200% scaling and 26 QML/input-method tests at each scale |
| Hyprland 0.56.2, isolated nested output | Native 100/125/150/200% scaling and 26 QML/input-method tests at each scale |
| GNOME Shell / Mutter 50.5, isolated headless output | Native 100/125/150/200% scaling and 26 QML/input-method tests at each scale |

The combined CTest run passed all 23 tests, including the 16 native compositor
configurations, offscreen interactions, application startup, PATH launch, and
D-Bus integration.

The additional compositors were extracted from official Debian packages under
`/tmp`, with archive SHA-256 verification. They were not installed into the
system and package maintainer scripts were not executed.

### Remaining desktop-session validation

The compatibility target is full support for the existing GUI, but the tests
above do not constitute a universal 100% certification across hardware and
desktop versions. The following remain **Verification required**:

- Physical display hotplug and suspend/resume on each target desktop.
- Fcitx/IBus candidate-window selection and clipboard exchange with other native
  applications. Synthetic `QInputMethodEvent` tests establish application
  composition handling, not the complete external input-method service path.
- Assistive-technology behavior with a screen reader and physical GPU/driver
  combinations beyond the current KDE desktop. Virtual compositor tests use
  software rendering or Mesa software OpenGL.
