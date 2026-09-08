# Static interoperability notes — INZONE Hub 1.0.19.0

## Provenance

Official download page: https://support.sony.jp/electronics/support/headphones-gaming-headphones/mdr-g600/software/00384248
Installer: https://info.update.sony.net/HP002/APID001WN00/contents/0011/INZONEHub_Setup_1.0.19.0.exe

Installer SHA-256: `8cb73e7524281905ec3e5f52679bb757557ee069571ec8c68ceff89d0edd2540`.
INZONEVirtualizer.dll SHA-256: `d3fb1a9619335af6f8256029714ac57ba53d643fb4ce9f43d8d50e3a20179860`.

The InstallShield executable contains the MSI at offset 7,212,312, length 136,132,608. `7z x` on the MSI yields Data1.cab; extracting the CAB yields the files in analysis/payload. The installer was not executed. Run `python3 tools/fetch_assets.py` to download the pinned installer, verify its SHA-256 and regenerate the runtime inputs. ILSpy is also downloaded locally at a pinned version; neither the tool nor raw extraction outputs belong in Git.

The MSI File table (568 rows, 18 bytes/row, column-major) proves this rename:
`shp_for_game_v2.0_512tap.hki` → `SHP_FO~1.HKI|standard_hrtf.hki`, size 57,952.
`ApoFileCommunication.SetVirtualizer` selects standard_hrtf.hki plus model_standard.ba for enabled, non-personalized surround. Disabled surround selects downmix.hki and no BA. H9 II uses wh_g910n_standard.ba. ALC config is a separate stage.

## Native code

The pinned DLL image base is 0x180000000. The following are relative virtual addresses:

- HKI key derivation: 0x9480, selector length table 0x1f6ab0, pointer table 0x1f6ab8.
- BA key derivation: 0x10c80; 20-word table at 0x1f7d80.
- AES-128 CBC decrypt wrapper: 0x11520.
- MD5 plaintext comparison: 0x117f0.
- HKI allocation/record copy and FFT preparation: 0x79c0. At 0x7c50 it skips the 16-byte record metadata and copies 512 float words without coefficient conversion. Metadata field 3 is retained separately; its full semantic meaning is not established.

Key derivation is reproduced in source from local DLL tables, not hardcoded asset keys. Lookup the header marker, XOR table entries at +7 and +11 modulo table length, then run the 16-step byte/state recurrence. Reverse each four-byte group before AES. The 16-byte header checksum doubles as the IV. Decrypt, validate PKCS#7 padding, and compare MD5. The checksum is format integrity validation, not authentication.

## HKI structure

| Offset | Meaning |
|---|---|
| 0 | `hki2` |
| 4 | uint32 key-table marker |
| 8 | 16-byte plaintext MD5 / AES IV |
| 36–52 | date/time fields |
| 56 | sample rate, 48000 |
| 60 | ear count, 2 |
| 76 | uint16 cipher mode, 5 for bundled files |
| 78 | uint16 selector, 1 |
| 88 | tap count, 512 |
| 92 | direction count, 14 |
| 144 | AES-CBC ciphertext |

Plaintext 57,792 bytes = 14 × 2 × (16 + 512×4).
Each record: uint32 azimuth, polar angle, kind, ear; then 512 little-endian float32 taps. Records are paired by direction and ear. The standard file uses kind 2; downmix uses kind 1. Both contain raw FIR coefficients, as verified in the native parser.

## BA structure

48-byte header: `ba00`, uint32 marker, MD5/IV at 8, sample rate at 24, seven sections at 28, value 1 at 32. AES-CBC ciphertext begins at 48. Validated plaintext has 140 bytes: seven groups of five float32 values. Standard transfer-function interpretation (b0,b1,b2,a1,a2) gives stable poles for all sections. The spatial BA uses double state and float stage boundaries.

## Channels and Linux integration

| PipeWire | HKI azimuth/polar |
|---|---|
| FL | 330/90 |
| FR | 30/90 |
| FC | 0/90 |
| LFE | 0/0 |
| RL | 210/90 |
| RR | 150/90 |
| SL | 250/90 |
| SR | 110/90 |

FL/FR and side/rear orientation is supported by the downmix impulses (unity or -3 dB in the expected ear, zero in the other). LFE assignment uses the only non-directional equal-ear lowpass record. Height directions are decoded but not exposed by this 7.1 prototype.

USB 054c:0fa8 exposes Chat playback at PCM 0/interface 1 and Game at PCM 1/interface 4. Both accept S16_LE, 48 kHz, two channels. The prior iec958 profile used PCM 0 (Chat). The standard ALSA profile set usb-gaming-headset.conf maps both correctly, plus the mono microphone.

WirePlumber node.software-dsp.rules loads the filter-chain as a LocalModule when the Game node exists, only with the surround profile. Capture is an eight-channel virtual sink; playback is pinned to Game with fallback disabled. Switching modes restarts WirePlumber and removes the module. Music selects physical Game and its original no-EQ/dither settings. Subsequent device-control work implements validated GET/SET HCI reports. No firmware or USB descriptors were modified.

PipeWire filter documentation: https://docs.pipewire.org/page_module_filter_chain.html
Local implementation references: /usr/share/wireplumber/scripts/node/software-dsp.lua and /usr/share/wireplumber/scripts/node/filter-graph.lua.

## DSP reconstruction

Real-time Linux playback uses `inzone_dsp.so` and decoded coefficients. DLL tables are read as data for filter import.

Relative virtual addresses:

| Function | RVA |
|---|---|
| Spatial create / init / reset / process sample | 0x1840 / 0x2610 / 0x2b80 / 0x2c90 |
| Spatial shutdown / destroy | 0x29f0 / 0x2420 |
| Internal ALC init / configure / process 8 frames | 0xd5e0 / 0xd610 / 0xd8b0 |
| ALC constructor / configure / process | 0x11a90 / 0x11df0 / 0x11be0 |
| DRC constructor / configure / process | 0x18880 / 0x18da0 / 0x18af0 |
| Model BA biquad kernel | 0x11210 |
| User EQ float biquad kernel | 0x155c0 |
| HRTF magnitude / normalization | 0x8b10 / 0x8fd0 |

Internal spatial ALC uses stereo-linked blocks of eight frames, 24-frame lookahead plus the outer eight-frame buffer, and +1 dB gain (`alc.cfg`). Downmix uses 0 dB (`alc_for_downmix.cfg`). Envelope attack/release are 0x67d2ec9b/2^31 and 0x7ac6b85a/2^31. The logarithm approximation and gain clamp are reproduced in `native/spatial_alc.c`. Total algorithmic ALC delay is 32 samples at 48 kHz; transport/FFT buffering is separate.

External ALC and DRC use a peak envelope with 10 ms decay. DRC includes upward compression and an expansion region, with different smoothing branches. See the C implementation. Low/high DRC and microphone AGC parameters come from the managed Hub defaults. The optional output ALC graph uses −18 dB attenuation → threshold −18 dB, ratio 1000, attack 1 ms, release 1 s → +18 dB recovery. Model BA and user EQ have different numerical kernels; using PipeWire's generic float biquad for model BA gave excessive error and was replaced.

Hub user EQ uses ten precomputed 25-row tables, not a fixed-Q approximation. `tools/export_eq_tables.py` extracts those local tables with the managed DLL hash. Gains are integer −12..+12 dB and centres 31.5, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000 Hz. User EQ state and output are float32; model BA state is double.

Spatial channel slots in the native 14-input array are `[1,2,0,13,5,6,3,4]` for FL,FR,FC,LFE,RL,RR,SL,SR. Reset must be called after native init; initialization alone leaves convolution buffers uninitialized.

## Personalization

Personalization imports local HKI and H9 II `YY2987.ba` files. Containers with a 52-byte wrapper before the HKI header are supported. The local model BA fixture has SHA-256 `9d9faae35a2db1ed16d277dbb73ea0e4e2bd96d85df5258593acf1dabf0797e2`.

HKI2 cipher 7 applies the same AES wrapper as cipher 5, then word XOR. Seed is header uint32 at offset 80 plus 0x52276af7; XOR mask is seed+(seed>>24), next seed=seed*0x80849+0x2a3b5 modulo 2^32. Sum of decoded bytes modulo 256 must equal the low checksum byte. Linux tests check decoded cipher-7 records against the generic cipher-5 bank.

HRTF normalization bounds the maximum complex FFT-bin magnitude across directions/ears to 18. The 512-tap path has one 1024-point FFT partition. Linux tests use an impulse with an analytic flat spectrum to check the normalization bound. Standard bank requires no attenuation. Personal import validates paired directions, rate/taps, checksum, required 7.1 positions and stable BA; unsupported assets fail without replacing the installed personal bank.

Local fixtures are derived from generic stock filters and are never described as the user's personalized HRTF. A personal HRTF requires the user's own local filter files.

## H9 II HID protocol

USB 054c:0fa8 interface 5 exposes report ID 2 (64 bytes including ID) on usage page 0xff04. Report byte 1 is HCI payload length; bytes 2 onward carry the packet and zero padding. Source: managed `HidDevice`, `HciPacket`, `HciCommandPacket`, `HciEventPacket`, `PcWidgetCommunication`, `HeadsetParam`.

Command: type 1, opcode 0xfc00 LE, parameter length (8+payload), Sony key 0xc396 LE, address byte, event ID, event type, uint16 transaction ID LE, payload, checksum. Source PC=1, dongle TX=2, headset RX=4; address=(destination<<4)|source. Checksum is byte sum from Sony key to end of payload modulo 256. Event replies start 04 ff, length=total−3, dummy 00; checksum includes dummy. GET=01, SET=02, RET=10, NTFY=20, unsolicited notification=a0.

State queries verified on the attached headset. Battery was 13% and headset/dongle firmware 01.001.000 at capture. Sidetone 4→3→4 SET and GET were verified and original state restored. Responses are matched by event, transaction and source; malformed lengths/checksums fail. Firmware event 0xa0 is excluded from the control API. User access uses device-specific uaccess rules, not world-writable hidraw permissions.

## Remaining validation and feature scope

`docs/features.md` distinguishes implemented audio/device functions from remaining Hub features. Physical reconnect and long-duration stress remain optional operational checks. Firmware flashing is not implemented. Process-associated profiles are implemented and covered by a separate live test.

PipeWire's in-daemon LADSPA loader restricts libraries to trusted search paths. Source: https://github.com/PipeWire/pipewire/blob/1.6.8/spa/plugins/filter-graph/plugin_ladspa.c . Runtime library versions use content-derived names to avoid old descriptor caches. Installations that already loaded an earlier library may require an audio-service restart.


## 프리셋과 ModeEqualizer

`SoundQualitySettingsViewModel.EQPresetItem`에서 Flat, FPS1/2/3, Immersion Flat(RPG/Adventure), Bass Boost, Music/Video의 10밴드 값을 추출했습니다. `EQAxis`는 Standard/Immersive 두 종류이며 별도 연속 보간 모드가 아닙니다.

`Control.yaml`의 `mode_equalizer.coeffs`가 몰입 음장의 실제 계수입니다. UI의 `SetEqEnable`은 coefficients와 parameters 양쪽의 첫 10개 enable을 모두 켜고, 네이티브 `Equalizer::SetParameters`(RVA 0x19ae0)는 coefficients를 우선 선택합니다. 따라서 기본 생성자에 있는 다른 주파수·Q·gain 값이나 YAML의 params에서 다시 계산한 값을 사용하면 UI 동작과 달라집니다. 효과적인 10단 계수와 Sony 프리셋은 `tools/export_presets.py`로 추출하고 `assets/sony-presets.json`에 원본 SHA-256과 함께 저장했습니다.

PipeWire inline 필터의 신호 순서는 기존 Linux EQ(선택) → Amp1 → ModeEQ → EQ → ALC → Amp2 → DRC입니다. Sony 프리셋은 기존 Linux EQ를 끕니다. Amp1은 원본 `powf(10, float(-18 / 20))`에서 얻은 0.1258925497531891, Amp2는 7.943282127380371을 사용합니다. double로 계산한 뒤 float로 변환하면 Amp1이 1 ULP 달라집니다.

실제 PipeWire 1.6.8은 `audioconvert.filter-graph.N`을 **큰 N부터 실행**합니다. `insert_graph()`는 내림차순으로 정렬하므로 WirePlumber 배열에는 원하는 신호 순서의 역순으로 저장합니다. 또한 `parse_prop_params()`의 문자열 버퍼가 4096바이트라서 각 그래프를 그보다 작게 나눕니다. 이 두 동작은 [해당 버전 audioconvert 소스](https://github.com/PipeWire/pipewire/blob/1.6.8/spa/plugins/audioconvert/audioconvert.c)에서 확인했습니다. 큰 한 개 그래프의 실패와, 로딩에는 성공했지만 결합 출력이 달랐던 원인을 각각 설명합니다.

Windows `SoundProfileCollection`은 최대 256개의 `SoundProfile` 배열을 JSON으로 읽고 씁니다. enum은 `CustomEnumConverter`로 이름 문자열을 쓰며 숫자·숫자 문자열도 읽습니다. 별도 CLI 변환은 이 필드 구조를 사용하고, 표현할 수 없는 Linux 전용 옵션을 조용히 삭제하지 않습니다. Linux에서 합성 파일·모든 기본 프리셋의 JSON 왕복 검사를 수행합니다.
