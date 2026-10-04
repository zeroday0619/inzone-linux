"""Verify native Sway or nested Hyprland behavior in an isolated Wayland session."""

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


def stop(process):
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=5)


def run(command, environment, log_path, timeout=30):
    result = subprocess.run(command, env=environment, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True, timeout=timeout)
    log_path.write_text(result.stdout)
    if result.returncode:
        raise RuntimeError(f"Command exited with {result.returncode}: {command}\n{result.stdout[-5000:]}")
    return result.stdout


def wait_for_socket(process, runtime, excluded=()):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"The isolated compositor exited with {process.returncode}.")
        for path in sorted(runtime.glob("wayland-*")):
            if path.name not in excluded and path.is_socket():
                return path.name
        time.sleep(0.05)
    raise RuntimeError("The isolated compositor did not create a Wayland socket.")


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
    assert state["window"]["visible"] and state["window"]["exposed"], state
    assert math.isclose(state["window"]["devicePixelRatio"], arguments.scale, abs_tol=0.01), state
    assert len(state["screens"]) == 1, state
    screen = state["screens"][0]
    assert abs(screen["width"] * arguments.scale - 1920) <= 2, state
    assert abs(screen["height"] * arguments.scale - 1440) <= 2, state
    assert 'set_app_id("dev.zeroday0619")' in output, "No native Wayland app_id request was observed."
    assert "xdg_toplevel" in output, "No native desktop surface was observed."
    if arguments.scale % 1:
        assert "wp_fractional_scale" in output, "No fractional scaling protocol was observed."
    image = screenshot.read_bytes()
    assert image[:8] == b"\x89PNG\r\n\x1a\n", "A rendered PNG was not produced."
    width, height = struct.unpack(">II", image[16:24])
    window = state["window"]
    assert abs(width - window["width"] * window["devicePixelRatio"]) <= 2, state
    assert abs(height - window["height"] * window["devicePixelRatio"]) <= 2, state
    print(f"PASS {arguments.kind}: native Wayland, DPR={window['devicePixelRatio']}, image={width}x{height}", flush=True)
    return state


def verify_session(arguments):
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    environment = dict(os.environ)
    runtime = Path(environment["XDG_RUNTIME_DIR"]).resolve()
    if (str(runtime) != environment.get("INZONE_COMPOSITOR_TEST_RUNTIME")
            or not runtime.is_relative_to(Path(tempfile.gettempdir()).resolve())
            or environment.get("DISPLAY")):
        raise RuntimeError("Compositor validation requires the launcher-created temporary runtime.")
    processes = []
    logs = []

    def start(command, process_environment, name):
        log = (arguments.artifacts / f"{name}.log").open("w")
        logs.append(log)
        process = subprocess.Popen(command, env=process_environment, stdout=log,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        processes.append(process)
        return process

    try:
        if arguments.kind == "sway":
            config = runtime / "sway.config"
            config.write_text("xwayland disable\n"
                              f"output HEADLESS-1 mode 1920x1440 scale {arguments.scale}\n"
                              "seat seat0 fallback true\n")
            compositor = start([str(arguments.compositor), "--unsupported-gpu", "-c", str(config)],
                               dict(environment, WLR_BACKENDS="headless", WLR_RENDERER="pixman",
                                    WLR_LIBINPUT_NO_DEVICES="1"), "compositor")
            socket = wait_for_socket(compositor, runtime)
        else:
            parent = start([str(arguments.parent_compositor), "--virtual", "--width", "1920",
                            "--height", "1440", "--no-lockscreen", "--no-global-shortcuts",
                            "--no-kactivities", "--socket", "wayland-parent"],
                           dict(environment, QT_QPA_PLATFORM="offscreen"), "parent-compositor")
            parent_socket = wait_for_socket(parent, runtime)
            config = runtime / "hyprland.conf"
            # The nested default 1280x720 mode cannot represent 150% with integer logical dimensions.
            config.write_text(f"monitor = , 1920x1440@60, auto, {arguments.scale}\n"
                              "debug {\n disable_logs = false\n enable_stdout_logs = true\n}\n"
                              "xwayland {\n enabled = false\n}\n"
                              "animations {\n enabled = false\n}\n"
                              "misc {\n disable_hyprland_logo = true\n disable_splash_rendering = true\n}\n")
            # Aquamarine tries DRM before its Wayland backend, so seat acquisition is disabled.
            compositor = start([str(arguments.compositor), "--config", str(config)],
                               dict(environment, WAYLAND_DISPLAY=parent_socket,
                                    LIBSEAT_BACKEND="inzone-disabled",
                                    AQ_DRM_DEVICES=str(runtime / "nonexistent-drm-device")), "compositor")
            socket = wait_for_socket(compositor, runtime, (parent_socket,))
        client = dict(environment, WAYLAND_DISPLAY=socket, XDG_SESSION_TYPE="wayland",
                      QT_QUICK_BACKEND="software", QT_QPA_PLATFORMTHEME="generic")
        state = verify_application(arguments, client)
        output = run([str(arguments.qmltestrunner), "-platform", "wayland", "-input",
                      str(arguments.qml_tests)], client, arguments.artifacts / "qml-tests.log", timeout=60)
        totals = re.search(r"Totals: (\d+) passed, (\d+) failed, (\d+) skipped", output)
        assert totals is not None and int(totals[1]) > 0, "The Qt test runner reported no tests."
        assert int(totals[2]) == 0 and int(totals[3]) == 0, output
        print(totals[0], flush=True)
        (arguments.artifacts / "result.json").write_text(json.dumps({
            "compositor": arguments.kind, "scale": arguments.scale,
            "tests_passed": int(totals[1]), "diagnostics": state,
        }, indent=2) + "\n")
    finally:
        for process in reversed(processes):
            stop(process)
        for log in logs:
            log.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kind", choices=("sway", "hyprland"), required=True)
    parser.add_argument("--compositor", type=Path, required=True)
    parser.add_argument("--parent-compositor", type=Path)
    parser.add_argument("--application", type=Path, required=True)
    parser.add_argument("--qmltestrunner", type=Path, required=True)
    parser.add_argument("--qml-tests", type=Path, required=True)
    parser.add_argument("--scale", type=float, default=1)
    parser.add_argument("--artifacts", type=Path, required=True)
    parser.add_argument("--inside-session", action="store_true", help=argparse.SUPPRESS)
    arguments = parser.parse_args()
    if arguments.kind == "hyprland" and arguments.parent_compositor is None:
        parser.error("--parent-compositor is required for nested Hyprland validation.")
    if not math.isfinite(arguments.scale) or arguments.scale <= 0:
        parser.error("--scale must be a positive finite value.")
    for name in ("compositor", "parent_compositor", "application", "qmltestrunner", "qml_tests", "artifacts"):
        value = getattr(arguments, name)
        if value is not None:
            setattr(arguments, name, value.resolve())
    arguments.artifacts.mkdir(parents=True, exist_ok=True)
    (arguments.artifacts / "result.json").unlink(missing_ok=True)
    if arguments.inside_session:
        verify_session(arguments)
        return
    bus_runner = shutil.which("dbus-run-session")
    if not bus_runner:
        parser.error("dbus-run-session is required.")
    # A short runtime path also accommodates Hyprland's instance-specific IPC sockets.
    with tempfile.TemporaryDirectory(prefix="inz-wl-") as directory:
        environment = dict(os.environ)
        for name in ("DISPLAY", "WAYLAND_DISPLAY", "WAYLAND_SOCKET", "XAUTHORITY", "DBUS_SESSION_BUS_ADDRESS",
                     "DBUS_SESSION_BUS_PID", "QT_QPA_PLATFORM", "QT_IM_MODULE", "XMODIFIERS", "QT_SCALE_FACTOR",
                     "QT_SCREEN_SCALE_FACTORS", "QT_SCALE_FACTOR_ROUNDING_POLICY", "QT_QUICK_BACKEND",
                     "QSG_RHI_BACKEND", "QT_FONT_DPI", "WAYLAND_DEBUG", "GDK_BACKEND", "HYPRLAND_INSTANCE_SIGNATURE",
                     "SWAYSOCK", "XDG_CURRENT_DESKTOP", "QT_QPA_PLATFORMTHEME"):
            environment.pop(name, None)
        for variable, relative in (("HOME", "home"), ("XDG_CONFIG_HOME", "config"), ("XDG_DATA_HOME", "data"),
                                   ("XDG_CACHE_HOME", "cache"), ("XDG_STATE_HOME", "state")):
            path = Path(directory) / relative
            path.mkdir(mode=0o700)
            environment[variable] = str(path)
        environment.update(XDG_RUNTIME_DIR=directory, INZONE_COMPOSITOR_TEST_RUNTIME=directory,
                           XDG_SESSION_TYPE="wayland", LIBGL_ALWAYS_SOFTWARE="1", GSETTINGS_BACKEND="memory")
        environment["PATH"] = str(arguments.compositor.parent) + os.pathsep + environment.get("PATH", "")
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
            print(f"{arguments.kind} validation failed. Artifacts: {arguments.artifacts}", file=sys.stderr)
            raise SystemExit(result.returncode)
        print(f"{arguments.kind} validation passed. Artifacts: {arguments.artifacts}")


if __name__ == "__main__":
    main()
