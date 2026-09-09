# Project Execution Policy

## Execution environment

All project commands MUST run outside sandboxed environments, under the normal
desktop user session.

This requirement applies to:

- SwiftPM, Swift, compiler, linker, Make, and test commands;
- Git status, diff, lint, and validation commands;
- reverse-engineering and asset-extraction tools;
- project CLI and TUI executables;
- PipeWire, WirePlumber, D-Bus, systemd user-session, and audio diagnostics;
- USB HID discovery, headset queries, and hardware validation.

Sandbox access may be used only to edit repository files. Do not launch a
project command or executable from a sandbox. If an operation requires explicit
permission to use the normal environment, request that permission instead of
falling back to a sandbox.

Results produced by a sandbox do not count as project validation. Re-run any
such check in the normal user environment before reporting it as passed.

Run build and test workflows as the desktop user. Do not use `sudo make`.

## Firmware boundary

Firmware support is read-only. The project may query and display the installed
headset and transceiver firmware versions. It MUST NOT look up, download,
install, flash, or otherwise execute firmware updates or vendor updater code.
