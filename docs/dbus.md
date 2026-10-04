# Session D-Bus control API

`inzone-service` exposes the existing Swift profile and headset controllers on the
user session bus. The GUI uses a separate connection for each asynchronous call,
with a 90-second reply timeout. Requests execute serially in the service. The
service does not retain the HID device between requests, so direct CLI and TUI
access remains available.

| Component | Identifier |
|---|---|
| Bus | Session bus |
| Service | `dev.zeroday0619` |
| Object path | `/dev/zeroday0619` |
| Interface | `dev.zeroday0619.Control1` |
| State schema version | `1` |

The installed D-Bus activation file starts the systemd user unit
`inzone-control.service` when the first client connects. No system bus policy or
root service is required. D-Bus introspection is available at the object path.

## Methods

Every method returns a UTF-8 JSON state document as D-Bus type `s`. A successful
mutation also emits `StateChanged(s stateJSON)`. Changes from the CLI, TUI, headset
buttons, or automatic switching are observable through `GetState`; clients should
refresh periodically because these external changes do not emit this service's
signal.

| Method | Input signature | Arguments |
|---|---|---|
| `GetState` | empty | None |
| `ActivateProfile` | `s` | Profile identifier, or `restore` |
| `SetProfileOptions` | `ss` | Profile identifier, partial JSON options object |
| `SetDeviceField` | `si` | Device field name, integer value |
| `SetHostField` | `si` | Host audio field name, integer value |
| `CreateProfile` | `ss` | New display name, base profile identifier |
| `RenameProfile` | `ss` | Custom profile identifier, new display name |
| `DeleteProfile` | `s` | Inactive, unreferenced custom profile identifier |
| `ApplyPreset` | `ss` | Profile identifier, Sony preset identifier |
| `BindApplication` | `ssi` | Executable name/path, profile identifier, priority (-1000 to 1000) |
| `RemoveApplication` | `s` | Executable name/path |
| `SetAutomationEnabled` | `b` | Enable or disable the existing automatic profile service |

Device field names, allowed values, and labels are provided by `device_fields` in
the state document. Device writes use the existing verified HID operations.
`ambient_level` and `voice_focus` require Ambient Sound mode. Host fields are
`game_volume`, `chat_volume`, and `mic_volume` (0 to 100), and `mic_mute` (0 or 1).
Firmware versions are read-only; no firmware update method exists.

`SetProfileOptions` accepts the same keys and validation as the CLI: `drc`,
`output_alc`, `mic_agc`, `hrtf`, `eq`, `eq_enable`, `sound_mode`, and `base_eq`.
Updating options applies the selected profile, matching CLI behavior.

Invalid arguments produce `dev.zeroday0619.Error.InvalidRequest`.
Failures from the existing controllers produce
`dev.zeroday0619.Error.OperationFailed` with the underlying error message.
D-Bus rejects malformed method signatures before dispatch. String arguments are
limited to 4 KiB for the first argument and 64 KiB for the second argument.

## State document

The document contains the following keys:

- `version`: integer schema version.
- `active_profile`: active identifier, or `original` when the original routing is active or the configuration is absent. An unreadable configuration leaves this value empty and provides `profile_error`.
- `profiles`: array of objects with `id`, `name`, `template`, `built_in`, and `options`.
- `presets`: object mapping Sony preset identifiers to display names.
- `device`: the existing headset status object with `connected`, hardware `fields`, and available battery, firmware, microphone, and Bluetooth state.
- `device_fields`: array of metadata objects with `name`, `label`, `values`, and `labels`.
- `host_levels`: available host volume and mute values.
- `automation`: object containing `enabled` and a `rules` array of `app`, `profile`, and `priority` objects.
- `profile_error`, `device_error`, `audio_error`, `automation_error`: an empty string on success, otherwise a diagnostic for the corresponding subsystem.

A disconnected or unavailable headset does not prevent profile collection and
configuration access. Clients should preserve their previous state when a method
returns an error and display the diagnostic.

## Diagnostics

Read live state with:

```sh
busctl --user call dev.zeroday0619 \
  /dev/zeroday0619 dev.zeroday0619.Control1 GetState
```

For an isolated session with hardware and audio operations disabled:

```sh
dbus-run-session -- inzone-service --offline
```

Offline mode supports state, custom profile collection, and application rule
operations in the selected home directory. It rejects profile activation, DSP
changes, hardware writes, and automation service changes. Use a temporary `HOME`
for integration tests to isolate saved settings.

The C client API in `Sources/CInzoneDBus/include/InzoneDBus.h` accepts only the
listed methods. It returns zero on success, a negative error code on failure, and
owned strings released by `inzone_dbus_free`. The module is shared by SwiftPM and
the Qt GUI CMake build.
