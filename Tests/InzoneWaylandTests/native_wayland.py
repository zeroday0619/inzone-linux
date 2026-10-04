"""Verify native Qt Wayland behavior without using the desktop session or XWayland."""

import argparse
import json
import math
import os
from pathlib import Path
import resource
import shutil
import struct
import subprocess
import sys
import tempfile
import time

from mixed_output import verify_mixed_outputs


def run(command, environment, log_path, timeout=30):
    result = subprocess.run(command, env=environment, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True, timeout=timeout)
    log_path.write_text(result.stdout)
    if result.returncode:
        raise RuntimeError(f"Command exited with {result.returncode}: {command}\n{result.stdout[-5000:]}")
    return result.stdout


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)


def inspect_application(arguments, environment, name, platform, selection, scale=None, extra_arguments=()):
    diagnostics = arguments.artifacts / f"{name}.json"
    screenshot = arguments.artifacts / f"{name}.png"
    diagnostics.unlink(missing_ok=True)
    screenshot.unlink(missing_ok=True)
    output = run([str(arguments.application), "--smoke-test", "--diagnostics", str(diagnostics),
                  "--screenshot", str(screenshot), *extra_arguments], environment, arguments.artifacts / f"{name}.log")
    state = json.loads(diagnostics.read_text())
    assert state["platformName"] == platform, state
    assert state["platformSelection"] == selection, state
    assert state["desktopFileName"] == "dev.zeroday0619", state
    assert state["windowIconAvailable"], state
    assert state["window"]["exposed"], state
    assert state["nativeWayland"] == (platform == "wayland"), state
    if platform == "wayland":
        assert len(state["screens"]) == 2, state
        assert 'set_app_id("dev.zeroday0619")' in output, "No Wayland app_id request was observed."
        assert "xdg_toplevel" in output, "No native desktop surface was observed."
        assert math.isclose(state["window"]["devicePixelRatio"], scale, abs_tol=0.01), state
        if scale % 1:
            assert "wp_fractional_scale" in output, "No fractional scaling protocol was observed."
    image = screenshot.read_bytes()
    assert image[:8] == b"\x89PNG\r\n\x1a\n", "A rendered PNG was not produced."
    width, height = struct.unpack(">II", image[16:24])
    window = state["window"]
    assert abs(width - window["width"] * window["devicePixelRatio"]) <= 2, state
    assert abs(height - window["height"] * window["devicePixelRatio"]) <= 2, state
    print(f"PASS {name}: {platform}, DPR={window['devicePixelRatio']}, image={width}x{height}", flush=True)
    return state


def verify_session(arguments):
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    environment = dict(os.environ)
    socket_name = "inzone-test-wayland"
    socket = Path(environment["XDG_RUNTIME_DIR"]) / socket_name
    compositor_command = [arguments.compositor, "--virtual", "--width", "1920", "--height", "1440",
                          "--output-count", "2", "--no-lockscreen", "--no-global-shortcuts",
                          "--no-kactivities", "--socket", socket_name]
    with (arguments.artifacts / "compositor.log").open("w") as log:
        compositor_environment = dict(environment, QT_QPA_PLATFORM="offscreen")
        compositor_environment.pop("WAYLAND_DISPLAY", None)
        compositor = subprocess.Popen(compositor_command, env=compositor_environment, stdout=log, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 15
            while not socket.exists():
                if compositor.poll() is not None or time.monotonic() >= deadline:
                    raise RuntimeError("The isolated Wayland compositor did not become ready.")
                time.sleep(0.05)
            client = dict(environment, WAYLAND_DISPLAY=socket_name, XDG_SESSION_TYPE="wayland")
            configuration = json.loads(run([arguments.output_tool, "--json"], client,
                                           arguments.artifacts / "outputs-before.json"))
            outputs = configuration["outputs"]
            assert len(outputs) == 2, configuration
            settings = []
            for index, output in enumerate(outputs):
                settings.extend([f"output.{output['id']}.scale.{arguments.scale}",
                                 f"output.{output['id']}.position.{int(1920 / arguments.scale) * index},0"])
            run([arguments.output_tool, *settings], client, arguments.artifacts / "configure-outputs.log")
            run([arguments.output_tool, "--json"], client, arguments.artifacts / "outputs-after.json")
            traced = dict(client, WAYLAND_DEBUG="1")
            inspect_application(arguments, traced, "native-default", "wayland", "wayland-session", arguments.scale)
            if arguments.scale == 1:
                inspect_application(arguments, dict(traced, QT_QUICK_BACKEND="software"),
                                    "native-software", "wayland", "wayland-session", 1)
                inspect_application(arguments, dict(client, QT_QPA_PLATFORM="offscreen", QT_QUICK_BACKEND="software"),
                                    "explicit-offscreen", "offscreen", "environment")
                inspect_application(arguments, dict(client, QT_QPA_PLATFORM="wayland", QT_QUICK_BACKEND="software"),
                                    "command-line-offscreen", "offscreen", "command-line",
                                    extra_arguments=("-platform", "offscreen"))
                # A missing Wayland socket must not silently select XCB or another platform.
                failed = subprocess.run([str(arguments.application), "--smoke-test"],
                                        env=dict(client, WAYLAND_DISPLAY="inzone-missing-socket"),
                                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=15)
                (arguments.artifacts / "missing-socket.log").write_text(failed.stdout)
                assert failed.returncode != 0, "The application accepted a nonexistent Wayland session."
            output = run([arguments.qmltestrunner, "-platform", "wayland", "-input", str(arguments.qml_tests)],
                         client, arguments.artifacts / "qml-tests.log", timeout=45)
            print("\n".join(line for line in output.splitlines() if "Totals:" in line), flush=True)
            if arguments.scale == 1:
                verify_mixed_outputs(arguments, client, outputs)
        finally:
            stop(compositor)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dbus-run-session", required=True)
    parser.add_argument("--compositor", required=True)
    parser.add_argument("--output-tool", required=True)
    parser.add_argument("--qdbus", required=True)
    parser.add_argument("--application", type=Path, required=True)
    parser.add_argument("--qmltestrunner", required=True)
    parser.add_argument("--qml-tests", type=Path, required=True)
    parser.add_argument("--scale", type=float, required=True)
    parser.add_argument("--artifacts", type=Path, required=True)
    parser.add_argument("--inside-session", action="store_true", help=argparse.SUPPRESS)
    arguments = parser.parse_args()
    arguments.artifacts = arguments.artifacts.resolve()
    arguments.artifacts.mkdir(parents=True, exist_ok=True)
    if arguments.inside_session:
        verify_session(arguments)
        return
    # D-Bus activation inherits the temporary environment from the bus process itself.
    with tempfile.TemporaryDirectory(prefix="inzone-wayland-") as directory:
        environment = dict(os.environ)
        for name in ("DISPLAY", "WAYLAND_DISPLAY", "XAUTHORITY", "DBUS_SESSION_BUS_ADDRESS",
                     "QT_QPA_PLATFORM", "QT_IM_MODULE", "XMODIFIERS", "QT_SCALE_FACTOR",
                     "QT_SCREEN_SCALE_FACTORS", "QT_SCALE_FACTOR_ROUNDING_POLICY", "QT_QUICK_BACKEND",
                     "QSG_RHI_BACKEND", "QT_FONT_DPI", "WAYLAND_DEBUG"):
            environment.pop(name, None)
        for variable, relative in (("HOME", "home"), ("XDG_RUNTIME_DIR", "runtime"),
                                   ("XDG_CONFIG_HOME", "config"), ("XDG_DATA_HOME", "data"),
                                   ("XDG_CACHE_HOME", "cache"), ("XDG_STATE_HOME", "state")):
            path = Path(directory) / relative
            path.mkdir(mode=0o700)
            environment[variable] = str(path)
        desktop_directory = Path(environment["XDG_DATA_HOME"]) / "applications"
        desktop_directory.mkdir()
        shutil.copyfile(Path(__file__).resolve().parents[2] / "gui/dev.zeroday0619.desktop",
                        desktop_directory / "dev.zeroday0619.desktop")
        environment["WAYLAND_DISPLAY"] = "inzone-test-wayland"
        environment["XDG_SESSION_TYPE"] = "wayland"
        environment["XDG_CURRENT_DESKTOP"] = "KDE"
        environment["LIBGL_ALWAYS_SOFTWARE"] = "1"
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
        command = [arguments.dbus_run_session, "--config-file", str(bus_config),
                   "--", sys.executable, str(Path(__file__).resolve()),
                   *sys.argv[1:], "--inside-session"]
        result = subprocess.run(command, env=environment, timeout=80)
        if result.returncode:
            print(f"Wayland validation failed. Artifacts: {arguments.artifacts}", file=sys.stderr)
            raise SystemExit(result.returncode)
        print(f"Wayland validation passed. Artifacts: {arguments.artifacts}")


if __name__ == "__main__":
    main()
