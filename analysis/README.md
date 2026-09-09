# Analysis Reports and Verification Archive

This directory manages technical datasets, empirical verification reports (JSON), and the local reverse-engineering workspace derived from Sony INZONE Hub.

---

## 1. Tracked Summary Reports

The JSON reports tracked in this repository represent empirical measurements verifying the signal processing fidelity and hardware control behavior of the driver stack:

| Report File | Verification Target | Key Measurements & Findings |
|---|---|---|
| **`impulse-results.json`** | 7.1ch Impulse Response | 379,392 output samples across 8 channels; all channels produced valid responses, peak levels clamped within 1.0, residual noise peak 0.0 |
| **`pipewire-sfx-results.json`** | PipeWire DSP Calculation Accuracy | 720,000 samples across 3 profile combinations; 0.0 maximum absolute error and 0.0 RMS error compared to direct LADSPA execution (lossless signal path confirmed) |
| **`live-profile-results.json`** | Session Profile Transitions | Verified live PipeWire node connections and DSP port routing across all 6 base profiles |
| **`profile-switch-results.json`** | Profile Switching Reliability | Validated clean exit codes and sink bindings during profile switching |
| **`live-automation-results.json`** | Process Auto-Detection | Verified automated profile switching on process launch/exit, manual override preservation, and post-exit restoration |
| **`device-write-verification.json`** | USB HID Control Stability | Validated writing sidetone register, verifying readback, and restoring initial register values on physical headset hardware |

> For comprehensive reverse-engineering technical details, see [`docs/reverse-engineering.md`](../docs/reverse-engineering.md). For detailed test audit results, see [`docs/completion-audit.md`](../docs/completion-audit.md).

---

## 2. Local-Only Artifacts (Git Excluded)

To respect copyright and maintain repository size, the following directories are ignored by `.gitignore` and kept only on local developer machines:

- **`payload/`**: Original binaries extracted statically from the official installer (`inzonevirtualizer.dll`, `inzonehub.dll`, `shp_for_game_v2.0_512tap.hki`, `wh_g910n_standard.ba`, etc.)
- **`decompiled/`**: Managed C# source code decompiled via ILSpy
- **`msi/`**: Extracted MSI database and OLE stream files
- **Raw Dumps & Logs**: Disassembly (`.asm`), string dumps (`.txt`), raw audio captures (`.wav`, `.f32`)

### Local Asset Extraction
Running the following command from the repository root automatically generates the necessary original binaries and decompiled sources in `analysis/payload/` and `analysis/decompiled/`:

```sh
# Download official installer and extract assets automatically
make assets

# Offline execution with pre-downloaded installer
make assets FETCH_FLAGS=--offline
```

---

## 3. Guidelines for Adding New Verification Reports

When adding new hardware telemetry or diagnostic results to the repository, follow this workflow:

1. Generate a summarized report in JSON format within the `analysis/` directory.
2. Confirm that the report contains no sensitive personal data (e.g., local user paths, machine IDs) or proprietary binary dumps.
3. Add a tracking exception rule in `.gitignore` (`!/analysis/<filename>.json`).
4. Verify with `git status` that only the intended JSON summary is staged, then commit.
