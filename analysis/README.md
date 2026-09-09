# Analysis Reports and Verification Archive

This directory manages technical datasets, empirical verification reports (JSON), and the local reverse-engineering workspace derived from Sony INZONE Hub.

---

## 1. Tracked Summary Reports

The tracked JSON files are archived measurements from specific implementation
snapshots. Treat a report as applicable only when its embedded plugin digest and
test topology match the build under review.

| Report File | Verification Target | Key Measurements & Findings |
|---|---|---|
| **`impulse-results.json`** | Historical 7.1 impulse response | 379,392 output samples across 8 channels for plugin SHA-256 `e93cf211a0d60b283a1a9396e3f523276494f9f92775cc0abf0f0d6f3a0b8cd0` |
| **`pipewire-sfx-results.json`** | Historical PipeWire/LADSPA comparison | Three 720,000-sample cases produced 0.0 maximum and RMS error against the same Linux LADSPA graph outside PipeWire, using plugin SHA-256 `e93cf211a0d60b283a1a9396e3f523276494f9f92775cc0abf0f0d6f3a0b8cd0` |
| **`live-profile-results.json`** | Historical session transitions | Recorded the five built-in profiles plus Restore and three DSP-option checks before dynamic profiles and direct FIR downmix were added |
| **`profile-switch-results.json`** | Historical profile switching | Records exit codes and default sinks from the pre-downmix profile graph; its non-surround sink expectations are no longer current |
| **`live-automation-results.json`** | Historical process automation | Records one launch/exit, manual-override, and restoration session from the archived implementation |
| **`device-write-verification.json`** | Physical USB HID write | Records one sidetone change (`4` → `3`) and restoration (`3` → `4`); it does not validate every supported field |

> For comprehensive reverse-engineering technical details, see [`docs/reverse-engineering.md`](../docs/reverse-engineering.md). For detailed test audit results, see [`docs/completion-audit.md`](../docs/completion-audit.md).

The two DSP reports predate the current `inzone_fir_standard`,
`inzone_fir_personal`, and `inzone_fir_downmix` descriptors. Their zero-error
results do not validate the current plugin, Sony's Windows DLL, the new 2.0/5.1
layouts, or physical-headset output. Compare a report's `plugin_sha256` with
`sha256sum native/inzone_dsp.so` before using it as current evidence.

---

## 2. Local-Only Artifacts (Git Excluded)

To respect copyright and maintain repository size, the following directories are ignored by `.gitignore` and kept only on local developer machines:

- **`payload/`**: Pinned feature binaries and filter inputs extracted statically from the official installer (`inzonevirtualizer.dll`, `inzonehub.dll`, `shp_for_game_v2.0_512tap.hki`, `wh_g910n_standard.ba`, etc.); exact known updater payloads are excluded
- **`decompiled/`**: Managed C# source code decompiled via ILSpy
- **`msi/`**: Extracted MSI database and OLE stream files
- **`reverse-engineering-inventory.json`**: Generated inventory of selected managed source types, feature payload hashes, and firmware artifacts marked `catalog-only-do-not-execute`
- **Raw Dumps & Logs**: Disassembly (`.asm`), string dumps (`.txt`), raw audio captures (`.wav`, `.f32`)

Local files such as `graph.json`, `test-dump.json`, and
`pipewire-sfx-*-graphs.json` may describe the retired PipeWire built-in convolver
topology. Regenerate them with the current plugin before using them as review
evidence.

### Local Asset Extraction
Running the following command from the repository root automatically generates the necessary original binaries and decompiled sources in `analysis/payload/` and `analysis/decompiled/`:

```sh
# Download official installer and extract assets automatically
make assets

# Offline execution with pre-downloaded installer
make assets FETCH_FLAGS=--offline
```

The extraction process does not execute Windows binaries. The complete CAB may
contain firmware updater files, but the inventory retains only their names,
sizes, hashes, and static-only policy. Their bytes are excluded from the published
`analysis/payload/` tree. The Linux installer does not publish them into runtime
asset directories and rejects updater names or Windows PE files as application
executables. The pinned virtualizer DLL is installed separately as non-executable
decoder input for local personalization import.

---

## 3. Guidelines for Adding New Verification Reports

When adding new hardware telemetry or diagnostic results to the repository, follow this workflow:

1. Generate a summarized report in JSON format within the `analysis/` directory.
2. Confirm that the report contains no sensitive personal data (e.g., local user paths, machine IDs) or proprietary binary dumps.
3. Add a tracking exception rule in `.gitignore` (`!/analysis/<filename>.json`).
4. Verify with `git status` that only the intended JSON summary is staged, then commit.
