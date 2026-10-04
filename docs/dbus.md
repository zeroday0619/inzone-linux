# Session D-Bus control API

Use `inzone-service` to access the Swift profile and headset controllers over the
user session bus. The GUI uses this API through asynchronous calls.

| Component | Identifier |
| --- | --- |
| Bus | Session bus |
| Service | `dev.zeroday0619` |
| Object path | `/dev/zeroday0619` |
| Interface | `dev.zeroday0619.Control1` |
| State schema version | `1` |

## Read current state

```sh
busctl --user call dev.zeroday0619 \
  /dev/zeroday0619 dev.zeroday0619.Control1 GetState
```

The installed D-Bus activation file starts the systemd user unit
`inzone-control.service` on the first request. No system bus policy or root
service is required. D-Bus introspection is available at the object path.

The GUI opens a separate connection for each call with a 90-second reply timeout.
The service executes requests serially and releases the HID device between
requests, preserving direct CLI and TUI access.

## Methods and notifications

Every method returns a UTF-8 JSON state document as D-Bus type `s`. A successful
mutation also emits `StateChanged(s stateJSON)`.

| Method | Input signature | Arguments |
| --- | --- | --- |
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

Clients must refresh periodically to observe changes made through the CLI, TUI,
headset buttons, or automatic switching. Those changes appear in `GetState` but
do not emit this service's signal.

### Accepted values

- `SetProfileOptions` accepts the same keys and validation as the CLI: `drc`,
  `output_alc`, `mic_agc`, `hrtf`, `eq`, `eq_enable`, `sound_mode`, and `base_eq`.
  Updating options applies the selected profile, matching CLI behavior.
- `device_fields` in the state document supplies device field names, allowed
  values, and labels. Device writes use the existing verified HID operations.
  `ambient_level` and `voice_focus` require Ambient Sound mode.
- Host fields are `game_volume`, `chat_volume`, and `mic_volume` (0 to 100), and
  `mic_mute` (0 or 1).
- Firmware versions are read-only. The API has no firmware update method.

### Errors and limits

| Condition | Result |
| --- | --- |
| Invalid arguments | `dev.zeroday0619.Error.InvalidRequest` |
| Controller failure | `dev.zeroday0619.Error.OperationFailed` with the underlying diagnostic |
| Malformed method signature | D-Bus rejects the request before dispatch |

String limits are 4 KiB for the first argument and 64 KiB for the second,
measured in UTF-8 bytes. When a method fails, clients should preserve their
previous state and display the diagnostic.

## State document

| Key | Contents |
| --- | --- |
| `version` | Integer schema version |
| `active_profile` | Active identifier, or `original` when original routing is active or configuration is absent. An unreadable configuration leaves this value empty and sets `profile_error`. |
| `profiles` | Array of objects with `id`, `name`, `template`, `built_in`, and `options` |
| `presets` | Object mapping Sony preset identifiers to display names |
| `device` | Headset status with `connected`, hardware `fields`, and available battery, firmware, microphone, and Bluetooth state |
| `device_fields` | Array of metadata objects with `name`, `label`, `values`, and `labels` |
| `host_levels` | Available host volume and mute values |
| `automation` | Object containing `enabled` and a `rules` array of `app`, `profile`, and `priority` objects |
| `profile_error`, `device_error`, `audio_error`, `automation_error` | Empty string on success; otherwise the diagnostic for that subsystem |

A disconnected or unavailable headset does not prevent access to the profile
collection or configuration.

## Test without hardware

Start an isolated session with hardware and audio operations disabled:

```sh
dbus-run-session -- inzone-service --offline
```

Offline mode supports state, custom profile collection, and application-rule
operations in the selected home directory. It rejects profile activation, DSP
changes, hardware writes, and automation service changes. Use a temporary `HOME`
for integration tests to isolate saved settings.

## C client API

`Sources/CInzoneDBus/include/InzoneDBus.h` accepts only the listed methods. Calls
return zero on success and a negative error code on failure. Release returned
owned strings with `inzone_dbus_free`. SwiftPM and the Qt GUI CMake build share
the same C module.
