"""Verify native Qt Wayland behavior in an isolated headless GNOME Shell session."""

import argparse
import json
import math
import os
from pathlib import Path
import re
import resource
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import time


def run(command, environment, log_path, timeout=40):
    with log_path.open("w") as log:
        result = subprocess.run(command, env=environment, stdout=log,
                                stderr=subprocess.STDOUT, text=True, timeout=timeout)
    output = log_path.read_text()
    if result.returncode:
        raise RuntimeError(f"Command exited with {result.returncode}: {command}\n{output[-5000:]}")
    return output


def stop(process):
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=5)


def configure_display(arguments, compositor, socket):
    from gi.repository import Gio, GLib

    connection = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    interface = "org.gnome.Mutter.DisplayConfig"
    object_path = "/org/gnome/Mutter/DisplayConfig"

    def call(destination, path, name, method, parameters=None):
        return connection.call_sync(destination, path, name, method, parameters, None,
                                    Gio.DBusCallFlags.NONE, 10000, None).unpack()

    deadline = time.monotonic() + 20
    while True:
        if compositor.poll() is not None:
            raise RuntimeError(f"GNOME Shell exited with {compositor.returncode} before becoming ready.")
        try:
            if socket.is_socket():
                state = call(interface, object_path, interface, "GetCurrentState")
                if state[1]:
                    call("org.gnome.Shell", "/org/gnome/Shell", "org.freedesktop.DBus.Properties", "Get",
                         GLib.Variant("(ss)", ("org.gnome.Shell", "OverviewActive")))
                    break
        except GLib.Error:
            pass
        if time.monotonic() >= deadline:
            raise RuntimeError("The isolated GNOME Shell did not expose a ready Wayland display.")
        time.sleep(0.05)

    # Shell exports D-Bus before its startup animation enters the overview.
    time.sleep(3)
    call("org.gnome.Shell", "/org/gnome/Shell", "org.freedesktop.DBus.Properties", "Set",
         GLib.Variant("(ssv)", ("org.gnome.Shell", "OverviewActive", GLib.Variant("b", False))))

    monitor = state[1][0]
    connector = monitor[0][0]
    mode = next(mode for mode in monitor[1] if mode[6].get("is-current"))
    record = {"connector": connector, "mode": mode[0], "requested_scale": arguments.scale,
              "supported_scales": mode[5]}
    scale_path = arguments.artifacts / "display-scale.json"
    scale_path.write_text(json.dumps(record, indent=2) + "\n")
    if not any(math.isclose(scale, arguments.scale, abs_tol=0.01) for scale in mode[5]):
        raise RuntimeError(f"The virtual monitor does not support scale {arguments.scale}: {mode[5]}")
    # Logical layout mode permits fractional output scales without changing user preferences.
    configuration = GLib.Variant("(uua(iiduba(ssa{sv}))a{sv})", (
        state[0], 1, [(0, 0, arguments.scale, 0, True, [(connector, mode[0], {})])],
        {"layout-mode": GLib.Variant("u", 1)}))
    call(interface, object_path, interface, "ApplyMonitorsConfig", configuration)
    deadline = time.monotonic() + 10
    while True:
        updated = call(interface, object_path, interface, "GetCurrentState")
        if updated[2] and math.isclose(updated[2][0][2], arguments.scale, abs_tol=0.01):
            record["applied_scale"] = updated[2][0][2]
            scale_path.write_text(json.dumps(record, indent=2) + "\n")
            return
        if time.monotonic() >= deadline:
            raise RuntimeError("Mutter did not acknowledge the requested virtual output scale.")
        time.sleep(0.05)


def verify_application(arguments, environment):
    diagnostics = arguments.artifacts / "native.json"
    screenshot = arguments.artifacts / "native.png"
    diagnostics.unlink(missing_ok=True)
    screenshot.unlink(missing_ok=True)
    output = run([str(arguments.application), "--smoke-test", "--diagnostics", str(diagnostics),
                  "--screenshot", str(screenshot)], dict(environment, WAYLAND_DEBUG="1"),
                 arguments.artifacts / "native.log")
    state = json.loads(diagnostics.read_text())
    assert state["platformName"] == "wayland", state
    assert state["platformSelection"] == "wayland-session", state
    assert state["nativeWayland"] is True, state
    assert state["applicationName"] == "dev.zeroday0619", state
    assert state["desktopFileName"] == "dev.zeroday0619", state
    assert state["windowIconAvailable"] is True, state
    window = state["window"]
    assert window["visible"] and window["exposed"], state
    assert math.isclose(window["devicePixelRatio"], arguments.scale, abs_tol=0.01), state
    assert 'set_app_id("dev.zeroday0619")' in output, "No native Wayland app_id request was observed."
    assert "xdg_toplevel" in output, "No native desktop surface was observed."
    if arguments.scale % 1:
        assert "wp_fractional_scale" in output, "No fractional scaling protocol was observed."
    image = screenshot.read_bytes()
    assert image[:8] == b"\x89PNG\r\n\x1a\n", "A rendered PNG was not produced."
    width, height = struct.unpack(">II", image[16:24])
    assert abs(width - window["width"] * window["devicePixelRatio"]) <= 2, state
    assert abs(height - window["height"] * window["devicePixelRatio"]) <= 2, state
    print(f"PASS GNOME: native Wayland, DPR={window['devicePixelRatio']}, image={width}x{height}", flush=True)
    return state


def verify_session(arguments):
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    environment = dict(os.environ)
    runtime = Path(environment["XDG_RUNTIME_DIR"]).resolve()
    if (str(runtime) != environment.get("INZONE_GNOME_TEST_RUNTIME")
            or not runtime.is_relative_to(Path(tempfile.gettempdir()).resolve())
            or environment.get("DISPLAY")):
        raise RuntimeError("GNOME validation requires the launcher-created temporary runtime.")
    # The private bus also absorbs system service requests from the isolated Shell.
    environment["DBUS_SYSTEM_BUS_ADDRESS"] = environment["DBUS_SESSION_BUS_ADDRESS"]
    socket_name = "inzone-gnome-wayland"
    command = [str(arguments.compositor), "--wayland", "--headless", "--no-x11",
               "--wayland-display=" + socket_name, "--virtual-monitor=1920x1080"]
    with (arguments.artifacts / "compositor.log").open("w") as log:
        compositor = subprocess.Popen(command, env=environment, stdout=log,
                                      stderr=subprocess.STDOUT, start_new_session=True)
        try:
            configure_display(arguments, compositor, runtime / socket_name)
            client = dict(environment, WAYLAND_DISPLAY=socket_name, QT_QUICK_BACKEND="software",
                          QT_QPA_PLATFORMTHEME="generic")
            state = verify_application(arguments, client)
            output = run([str(arguments.qmltestrunner), "-platform", "wayland", "-input",
                          str(arguments.qml_tests)], client, arguments.artifacts / "qml-tests.log", timeout=60)
            totals = re.search(r"Totals: (\d+) passed, (\d+) failed, (\d+) skipped", output)
            assert totals is not None and int(totals[1]) > 0, "The Qt test runner reported no tests."
            assert int(totals[2]) == 0 and int(totals[3]) == 0, output
            print(totals[0], flush=True)
            (arguments.artifacts / "result.json").write_text(json.dumps({
                "compositor": "gnome", "scale": arguments.scale,
                "tests_passed": int(totals[1]), "diagnostics": state,
            }, indent=2) + "\n")
        finally:
            stop(compositor)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compositor", type=Path, required=True, help="Path to gnome-shell.")
    parser.add_argument("--application", type=Path, required=True)
    parser.add_argument("--qmltestrunner", type=Path, required=True)
    parser.add_argument("--qml-tests", type=Path, required=True)
    parser.add_argument("--scale", type=float, choices=(1, 1.25, 1.5, 2), default=1)
    parser.add_argument("--artifacts", type=Path, required=True)
    parser.add_argument("--inside-session", action="store_true", help=argparse.SUPPRESS)
    arguments = parser.parse_args()
    for name in ("compositor", "application", "qmltestrunner", "qml_tests", "artifacts"):
        setattr(arguments, name, getattr(arguments, name).resolve())
    arguments.artifacts.mkdir(parents=True, exist_ok=True)
    (arguments.artifacts / "result.json").unlink(missing_ok=True)
    try:
        from gi.repository import Gio, GLib
    except ImportError:
        parser.error("The selected Python interpreter requires PyGObject with Gio and GLib support.")
    if arguments.inside_session:
        verify_session(arguments)
        return
    bus_runner = shutil.which("dbus-run-session")
    if not bus_runner:
        parser.error("dbus-run-session is required.")
    with tempfile.TemporaryDirectory(prefix="inz-gnome-") as directory:
        environment = dict(os.environ)
        for name in ("DISPLAY", "WAYLAND_DISPLAY", "WAYLAND_SOCKET", "XAUTHORITY", "DBUS_SESSION_BUS_ADDRESS",
                     "DBUS_SESSION_BUS_PID", "QT_QPA_PLATFORM", "QT_IM_MODULE", "XMODIFIERS", "QT_SCALE_FACTOR",
                     "QT_SCREEN_SCALE_FACTORS", "QT_SCALE_FACTOR_ROUNDING_POLICY", "QT_QUICK_BACKEND",
                     "QSG_RHI_BACKEND", "QT_FONT_DPI", "WAYLAND_DEBUG", "QT_QPA_PLATFORMTHEME"):
            environment.pop(name, None)
        for variable, relative in (("XDG_CONFIG_HOME", "config"), ("XDG_DATA_HOME", "data"),
                                   ("XDG_CACHE_HOME", "cache"), ("XDG_STATE_HOME", "state")):
            path = Path(directory) / relative
            path.mkdir(mode=0o700)
            environment[variable] = str(path)
        environment.update(XDG_RUNTIME_DIR=directory, INZONE_GNOME_TEST_RUNTIME=directory,
                           XDG_SESSION_TYPE="wayland", XDG_CURRENT_DESKTOP="GNOME", GDK_BACKEND="wayland",
                           LIBGL_ALWAYS_SOFTWARE="1", GSETTINGS_BACKEND="memory")
        # Omitting service directories prevents activation of host portals or user services.
        bus_config = Path(directory) / "session-bus.conf"
        bus_config.write_text("""<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
"http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <listen>unix:tmpdir=/tmp</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow own="*"/>
    <allow send_destination="*"/>
    <allow receive_sender="*"/>
  </policy>
</busconfig>
""")
        command = [bus_runner, "--config-file", str(bus_config), "--", sys.executable,
                   str(Path(__file__).resolve()), *sys.argv[1:], "--inside-session"]
        result = subprocess.run(command, env=environment, timeout=110)
        if result.returncode:
            print(f"GNOME validation failed. Artifacts: {arguments.artifacts}", file=sys.stderr)
            raise SystemExit(result.returncode)
        print(f"GNOME validation passed. Artifacts: {arguments.artifacts}")


if __name__ == "__main__":
    main()
