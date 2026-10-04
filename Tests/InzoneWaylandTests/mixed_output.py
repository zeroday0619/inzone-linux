"""Verify output migration inside the caller's isolated Wayland session."""

import json
import math
from pathlib import Path
import re
import struct
import subprocess
import tempfile
import time


def verify_mixed_outputs(arguments, client_environment, outputs):
    """Move the native application from a 100% output to a 150% output."""
    runtime = Path(client_environment["XDG_RUNTIME_DIR"]).resolve()
    temporary = Path(tempfile.gettempdir()).resolve()
    if not runtime.is_relative_to(temporary) or client_environment.get("DISPLAY"):
        raise RuntimeError("Mixed-output validation requires an isolated temporary Wayland runtime.")
    if len(outputs) != 2:
        raise RuntimeError("Mixed-output validation requires exactly two virtual outputs.")
    source, target = sorted(outputs, key=lambda output: output["name"])
    artifacts = arguments.artifacts
    diagnostics = artifacts / "mixed-output.json"
    screenshot = artifacts / "mixed-output.png"
    trace_path = artifacts / "mixed-output.log"
    diagnostics.unlink(missing_ok=True)
    screenshot.unlink(missing_ok=True)
    environment = dict(client_environment, WAYLAND_DEBUG="1")
    environment.pop("QT_SCALE_FACTOR", None)
    environment.pop("QT_SCREEN_SCALE_FACTORS", None)

    def run(command, name):
        result = subprocess.run(command, env=client_environment, capture_output=True,
                                text=True, timeout=10)
        (artifacts / name).write_text(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError(f"Mixed-output command failed: {command}\n{result.stdout}{result.stderr}")
        return result.stdout

    configuration = json.loads(run([arguments.output_tool, "--json"], "mixed-outputs-before.json"))
    run([arguments.output_tool,
         f"output.{source['id']}.scale.1", f"output.{source['id']}.position.0,0",
         f"output.{target['id']}.scale.1.5", f"output.{target['id']}.position.1920,0"],
        "mixed-configure-outputs.log")
    configured = json.loads(run([arguments.output_tool, "--json"], "mixed-outputs-after.json"))
    scales = {output["name"]: output["scale"] for output in configured["outputs"]}
    assert math.isclose(scales[source["name"]], 1, abs_tol=0.01), configured
    assert math.isclose(scales[target["name"]], 1.5, abs_tol=0.01), configured
    loaded_scripts = []
    process = None

    def trace():
        return trace_path.read_text(errors="replace")

    def wait_for(predicate, description):
        deadline = time.monotonic() + 1.4
        while not predicate(trace()):
            if process.poll() is not None or time.monotonic() >= deadline:
                raise RuntimeError(f"The application did not {description}. See {trace_path}.")
            time.sleep(0.01)

    def move_to(output, suffix):
        script = artifacts / f"mixed-move-{suffix}.js"
        name = f"inzone-wayland-mixed-{suffix}"
        # Matching the exact desktop identifier prevents moving unrelated test windows.
        script.write_text(
            "const target = workspace.screens.find(output => output.name === "
            + json.dumps(output["name"]) + ");\n"
            + "if (!target) throw new Error('The virtual target output is missing.');\n"
            + "const windows = workspace.windowList().filter(window => "
            + "String(window.resourceClass) === 'dev.zeroday0619');\n"
            + "if (windows.length !== 1) throw new Error('Expected one INZONE window.');\n"
            + "workspace.sendClientToScreen(windows[0], target);\n"
            + "print('INZONE mixed-output move:', windows[0].output.name);\n"
        )
        identifier = run([arguments.qdbus, "org.kde.KWin", "/Scripting",
                          "org.kde.kwin.Scripting.loadScript", str(script), name],
                         f"mixed-load-{suffix}.log").strip()
        if not identifier.isdecimal():
            raise RuntimeError(f"KWin did not return a script identifier: {identifier}")
        loaded_scripts.append(name)
        run([arguments.qdbus, "org.kde.KWin", f"/Scripting/Script{identifier}",
             "org.kde.kwin.Script.run"], f"mixed-run-{suffix}.log")

    try:
        with trace_path.open("w") as log:
            process = subprocess.Popen(
                [str(arguments.application), "--smoke-test", "--diagnostics", str(diagnostics),
                 "--screenshot", str(screenshot)],
                env=environment, stdout=log, stderr=subprocess.STDOUT,
            )
            wait_for(lambda text: 'set_app_id("dev.zeroday0619")' in text
                     and re.search(r"wl_surface#\d+\.enter\(wl_output#\d+\)", text),
                     "create its native desktop surface")
            move_to(source, "source")
            wait_for(lambda text: "preferred_scale(120)" in text, "use the 100% source output")
            before_move = len(trace())
            move_to(target, "target")
            wait_for(lambda text: "preferred_scale(180)" in text[before_move:],
                     "receive the 150% output scale after migration")
            process.wait(timeout=10)
        if process.returncode:
            raise RuntimeError(f"The migrated application exited with {process.returncode}. See {trace_path}.")
        state = json.loads(diagnostics.read_text())
        assert state["nativeWayland"] is True, state
        assert state["platformName"] == "wayland", state
        assert state["desktopFileName"] == "dev.zeroday0619", state
        assert state["windowIconAvailable"] is True, state
        assert state["window"]["screenName"] == target["name"], state
        assert math.isclose(state["window"]["devicePixelRatio"], 1.5, abs_tol=0.01), state
        assert state["window"]["visible"] and state["window"]["exposed"], state
        image = screenshot.read_bytes()
        assert image[:8] == b"\x89PNG\r\n\x1a\n", "A migrated window screenshot was not produced."
        width, height = struct.unpack(">II", image[16:24])
        assert abs(width - state["window"]["width"] * 1.5) <= 2, state
        assert abs(height - state["window"]["height"] * 1.5) <= 2, state
        print(f"PASS mixed-output: {source['name']} (100%) -> {target['name']} (150%), native Wayland and icon preserved", flush=True)
        return state
    finally:
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
        for name in loaded_scripts:
            run([arguments.qdbus, "org.kde.KWin", "/Scripting",
                 "org.kde.kwin.Scripting.unloadScript", name], f"mixed-unload-{name}.log")
        settings = []
        for output in configuration["outputs"]:
            settings.extend([f"output.{output['id']}.scale.{output['scale']}",
                             f"output.{output['id']}.position.{output['pos']['x']},{output['pos']['y']}"])
        run([arguments.output_tool, *settings], "mixed-restore-outputs.log")
