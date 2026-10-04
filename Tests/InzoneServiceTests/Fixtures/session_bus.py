"""Exercise the real D-Bus server and C client on an isolated session bus."""

import ctypes
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

service_binary, client_library = sys.argv[1:]
client = ctypes.CDLL(client_library)
client.inzone_dbus_call.argtypes = [
    ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int32,
    ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(ctypes.c_void_p),
]
client.inzone_dbus_call.restype = ctypes.c_int
client.inzone_dbus_free.argtypes = [ctypes.c_void_p]


def call(method, first="", second="", value=0):
    response = ctypes.c_void_p()
    error = ctypes.c_void_p()
    result = client.inzone_dbus_call(
        method.encode(), first.encode(), second.encode(), value,
        ctypes.byref(response), ctypes.byref(error),
    )
    try:
        if result < 0:
            message = ctypes.string_at(error).decode() if error.value else "No error message"
            raise RuntimeError(message)
        return json.loads(ctypes.string_at(response).decode())
    finally:
        client.inzone_dbus_free(response)
        client.inzone_dbus_free(error)


def rejected(method, first="", second="", value=0, message=None):
    try:
        call(method, first, second, value)
    except RuntimeError as error:
        if message:
            assert message in str(error), str(error)
    else:
        raise AssertionError(f"{method} unexpectedly succeeded")


with tempfile.TemporaryDirectory(prefix="inzone-dbus-test-") as directory:
    environment = dict(os.environ, HOME=directory)
    service = subprocess.Popen([service_binary, "--offline"], env=environment,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        deadline = time.monotonic() + 5
        while True:
            ownership = subprocess.check_output([
                "busctl", "--user", "call", "org.freedesktop.DBus", "/org/freedesktop/DBus",
                "org.freedesktop.DBus", "NameHasOwner", "s", "dev.zeroday0619",
            ], text=True)
            if "true" in ownership:
                break
            if service.poll() is not None or time.monotonic() > deadline:
                raise RuntimeError("The isolated service did not acquire its bus name.")
            time.sleep(0.02)
        state = call("GetState")
        assert state["version"] == 1
        assert state["active_profile"] == "original"
        assert state["device"]["connected"] is False
        assert len(state["profiles"]) == 5
        assert len(state["device_fields"]) == 14
        assert "bass_boost" in state["presets"]
        introspection = subprocess.check_output([
            "busctl", "--user", "--xml-interface", "introspect",
            "dev.zeroday0619", "/dev/zeroday0619",
        ], text=True)
        assert 'interface name="dev.zeroday0619.Control1"' in introspection
        assert 'signal name="StateChanged"' in introspection
        state = call("CreateProfile", "D-Bus profile", "voice")
        profile = next(profile for profile in state["profiles"] if not profile["built_in"])
        identifier = profile["id"]
        state = call("RenameProfile", identifier, "D-Bus renamed")
        assert state["profiles"][-1]["name"] == "D-Bus renamed"
        state = call("BindApplication", "inzone-test-app", identifier, -7)
        assert state["automation"]["rules"] == [
            {"app": "inzone-test-app", "profile": identifier, "priority": -7}
        ]
        rejected("DeleteProfile", identifier, message="Remove automatic rules")
        state = call("RemoveApplication", "inzone-test-app")
        assert state["automation"]["rules"] == []
        state = call("DeleteProfile", identifier)
        assert len(state["profiles"]) == 5
        rejected("SetProfileOptions", "voice", '{"mic_agc":1}', message="must be a boolean")
        rejected("SetProfileOptions", "voice", '{"mic_agc":true}', message="offline")
        rejected("SetDeviceField", "firmware", value=1, message="Unknown device field")
        rejected("SetDeviceField", "anc", value=0, message="offline")
        rejected("SetHostField", "mic_volume", value=50, message="offline")
        rejected("ActivateProfile", "voice", message="offline")
        rejected("ApplyPreset", "music", "bass_boost", message="offline")
        rejected("SetAutomationEnabled", value=1, message="offline")
        rejected("Unknown", message="Unknown D-Bus method")
        malformed = subprocess.run([
            "busctl", "--user", "call", "dev.zeroday0619",
            "/dev/zeroday0619", "dev.zeroday0619.Control1",
            "SetHostField", "ss", "mic_volume", "50",
        ], capture_output=True, text=True)
        assert malformed.returncode != 0
        assert not Path(directory, ".config/wireplumber").exists()
        print("D-Bus integration passed: introspection, C client signatures, profile CRUD, rules, validation, and offline isolation.")
    finally:
        service.terminate()
        stdout, stderr = service.communicate(timeout=5)
        assert service.returncode == 0, (service.returncode, stdout, stderr)
