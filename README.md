# INZONE H9 II — Linux 구현

INZONE Hub 1.0.19.0의 공간 음향·자동 음량 제어·EQ와 H9 II USB 제어를 역분석한 PipeWire/WirePlumber 구현입니다. 실시간 처리는 네이티브 Linux 코드로 실행합니다.

## 실행과 TUI

```sh
~/.local/bin/inzone-profile
```

최소 72열 × 24행. 방향키 또는 1–6으로 프로파일을 선택하고 Enter로 적용합니다.

| 키 | 기능 |
|---|---|
| D | 선택한 프로파일의 DRC: 끔 / 낮음 / 높음 |
| A | 선택한 프로파일의 출력 자동 음량 제어 |
| M | 선택한 프로파일의 마이크 자동 게인 |
| E | Sony 10밴드 EQ, −12~+12 dB, 1 dB 간격 |
| S | Sony 프리셋: Flat, FPS 1/2/3, RPG/Adventure, Bass Boost, Music/Video |
| U | 게임 실행에 따른 자동 프로파일 전환 규칙·시작/중지 |
| P | 서라운드의 기본 / 개인화 HRTF 선택 |
| I | 개인화 HKI·H9 II 보정 BA 파일 가져오기 |
| H | 장치 제어: ANC·주변 소리·사이드톤·게임/채팅 균형·전원 옵션·음성 안내 등 |
| Q / Esc | 종료 |

장치 화면에서는 좌우 키로 값을 고르고 Enter로 적용합니다. R은 상태 갱신, T는 마이크 듣기 시작/중지입니다. 마이크 듣기는 최대 30초이며 파일로 녹음하지 않습니다. 장치 설정은 모든 프로파일에 공통으로 적용됩니다. EQ·DRC·자동 게인·HRTF 선택은 프로파일마다 별도로 저장됩니다.

현재 음악 프로파일은 EQ·공간 처리·추가 자동 게인을 끈 기본 상태로 유지했습니다. 서라운드를 선택하면 고정 −12 dB 감쇠 대신 검증한 Sony 공간 음향 내부 ALC가 작동합니다. 공간 ALC는 서라운드 처리의 필수 단계이며 A 키로 조절하는 출력 ALC와 별개입니다.

게임에서 7.1 출력을 사용하면 `inzone.sony-surround`가 Sony HRTF → H9 II 보정 EQ → 내부 ALC → Game 출력으로 처리합니다. 같은 게임의 헤드폰 HRTF를 함께 켜면 공간 처리가 중복됩니다. 스테레오 소스에 없던 후방 위치 정보를 복원하지는 않습니다.

음악/FPS/기본은 Game, 통화는 Chat을 선택합니다. 출력 효과도 선택한 Game 또는 Chat에만 적용되어 다른 출력에 중복되지 않습니다. 기존 HeSuVi 전역 싱크는 비활성 상태이며 `~/.local/bin/inzone-play`는 제거 상태입니다. 서라운드 싱크는 해당 프로파일에서만 생성되며 동글이 없을 때 다른 스피커로 우회하지 않습니다.

## 개인화

보유한 개인화 HKI 파일과 H9 II 보정 BA 파일을 로컬에서 가져옵니다. TUI의 I로 파일 경로를 입력한 뒤 서라운드에서 P로 개인화 HRTF를 선택합니다. 개인화 파일이 없으면 기본 HRTF를 사용합니다.

```sh
inzone-profile --personalize-import /path/personalized_hrtf.hki /path/YY2987.ba
inzone-profile --set surround hrtf '"personal"'
```

Windows 파일 위치: `%APPDATA%\Sony\INZONE Hub\VirtualizeUser`.

H9 II 개인화 보정의 모델명은 `YY2987`입니다. 기본 HRTF의 `wh_g910n_standard.ba`와 구별합니다. 다운로드된 컨테이너의 52바이트 래퍼도 인식합니다.

HKI2 cipher 5/7, selector 1, 48 kHz, 양쪽 귀 512 taps와 필요한 7.1 방향을 검증합니다. BA는 7단 보정 필터의 체크섬·유한값·안정성을 검사합니다. 정상적인 파일만 교체하며 이전 개인화 폴더를 보관합니다.

## CLI

```sh
inzone-profile --set fps drc 2
inzone-profile --set voice mic_agc true
inzone-profile --set surround output_alc true
inzone-profile --set music eq '[0,0,0,0,0,0,0,0,0,0]'
inzone-profile --settings
inzone-profile --export profiles.json
inzone-profile --import profiles.json
inzone-profile --device-status
inzone-profile --device-set anc 1
inzone-profile --device-set sidetone 4
```

`--export/--import`는 이 구현의 프로파일별 DSP 설정 JSON입니다. Windows 형식은 아래 별도 명령으로 처리합니다. 장치 명령 키는 `anc`, `ambient_level`, `voice_focus`, `game_chat`, `sidetone`, `toggle_off`, `toggle_nc`, `toggle_ambient`, `nc_startup`, `bt_startup`, `auto_power`, `language`, `guidance`입니다.

## Sony 프리셋·Windows 프로파일

S로 Sony의 일곱 기본 프리셋을 선택합니다. 원본 `Control.yaml`의 몰입 음장 계수와 Hub의 10밴드 값을 사용합니다. Sony 프리셋을 적용하면 기존 Linux FPS/통화 출력 EQ를 대체하며, Windows와 같이 Flat 이외의 프리셋은 출력 ALC를 켭니다. 마이크 저역 필터 등 입력 설정은 유지합니다. 직접 음장을 고를 때는 `--set PROFILE sound_mode '"immersive"'` 또는 `'"standard"'`를 사용합니다.

```sh
inzone-profile --preset
inzone-profile --preset fps fps1
inzone-profile --preset surround immersion_flat
inzone-profile --windows-list /path/SoundProfile.json
inzone-profile --windows-import surround /path/SoundProfile.json 1
inzone-profile --windows-export surround exported.json
```

Windows 파일은 `%APPDATA%\Sony\INZONE Hub\SoundProfile.json` 또는 Hub의 내보내기 JSON입니다. 목록 번호는 1부터 시작합니다. 원본 클래스의 enum, 대소문자 무시, 주석·마지막 쉼표·숫자 문자열을 지원합니다. Windows의 `Surround` 값과 가져올 Linux 프로파일이 일치해야 합니다. Windows 파일에 없는 기존 Linux 개인화·마이크 AGC 선택은 가져올 때 유지합니다. 반대로 내보낼 때 표현할 수 없는 설정은 누락시키지 않고 오류로 알립니다.

## 자동 프로파일

U에서 실행 파일 이름 또는 정확한 경로와 대상 프로파일을 등록한 뒤 Space로 서비스를 켭니다. 최초 설치 시 자동 전환은 꺼져 있고 규칙도 없습니다.

```sh
inzone-profile --auto-bind game.exe surround 10
inzone-profile --auto-bind discord voice 20
inzone-profile --auto-config
inzone-profile --auto-enable
inzone-profile --auto-disable
inzone-profile --auto-remove game.exe
```

본인 계정의 실행 중인 프로세스를 1초마다 검사합니다. Linux 실행 파일과 Wine/Proton의 Windows 실행 파일 이름을 인식하며, 인수의 부분 문자열은 매칭하지 않습니다. 높은 우선순위가 먼저이고 동률은 규칙 목록 순서입니다. 2초 동안 일치 상태가 유지되면 전환하고, 마지막 앱이 종료되면 이전 선택으로 복원합니다. 수동 선택은 일치하는 앱 목록이 바뀔 때까지 유지되며 이후 복원 기준도 수동 선택으로 바뀝니다. 활성 프로파일을 통째로 전환하므로 동시에 실행한 다른 앱에도 영향을 줍니다. 창의 포커스에 따라 전환하는 기능은 아닙니다.

## Linux 검사

- LADSPA 블록 크기·재초기화·in-place 처리·DRC 제한·ALC 지연
- PipeWire 7.1 채널 응답·자동 음량 제한·무음 복귀
- PipeWire 인라인 처리와 Linux LADSPA 그래프의 일치
- HKI/BA 형식·암호·정규화·손상 거부·안전한 파일 교체
- 프로파일·TUI·자동 전환·장치 제어

```sh
make -C native
python3 -m unittest discover -s tests -p 'test_*.py'
python3 tests/pipewire_sfx.py
python3 tests/pipewire_impulse.py
# 실제 사용자 오디오 세션을 전환하는 별도 검사:
python3 tests/live_profiles.py
python3 tests/live_automation.py
```

테스트는 Linux에서 실행합니다. 필터 해독 검사에는 로컬 추출 자산을 사용하며 DLL을 실행하지 않습니다.

## 설치 및 파일

공개 저장소에는 구현 코드와 분석 보고서가 포함됩니다. 원본 설치 파일, DLL, 추출 계수·HRTF, 디컴파일 결과와 실행 로그는 포함하지 않습니다. 필요한 자산은 아래 스크립트로 로컬에서 재생성합니다.

먼저 Python 3.10 이상, Python `cryptography`, 7-Zip (`7z` 또는 `7zz`), .NET 10 SDK를 설치하세요. Debian 계열의 Python·압축·빌드 의존성은 다음과 같습니다. .NET 10 SDK는 배포판 또는 Microsoft의 설치 안내에 따라 별도로 준비합니다.

```sh
sudo apt install python3 python3-cryptography 7zip build-essential ladspa-sdk
python3 tools/fetch_assets.py
make -C native
python3 -m unittest discover -s tests -p 'test_*.py'
# PipeWire/WirePlumber를 사용하는 데스크톱 사용자 홈에 설치:
sudo python3 tools/install_profiles.py --home "$HOME"
```

`fetch_assets.py`는 ILSpy 11.0.0.9375를 NuGet에서 `tools/` 아래로 내려받고, Sony 공식 INZONE Hub 1.0.19.0 설치 파일을 다운로드합니다. 설치 파일·내장 MSI·필수 DLL/필터의 SHA-256을 확인한 뒤 압축을 풀고 기본 HRTF, 보정 필터, 10밴드 EQ 표와 프리셋을 생성합니다. Windows EXE/DLL은 실행하지 않습니다. 기존에 검증된 설치 파일과 도구가 있으면 재사용합니다.

```sh
# 설치 파일만 다운로드·검증:
python3 tools/fetch_assets.py --download-only
# 네트워크 없이 기존 설치 파일과 ILSpy로 재생성:
python3 tools/fetch_assets.py --offline
# 별도로 받은 동일 버전의 설치 파일 사용:
python3 tools/fetch_assets.py --installer /path/INZONEHub_Setup_1.0.19.0.exe
```

공개 파일 범위와 재생성 결과는 [저장소 파일 구성](docs/repository-files.md)에 정리했습니다.

설치 도구는 현재 프로파일과 TUI를 백업하고 네이티브 DSP를 빌드합니다. 데몬 내 필터는 PipeWire의 신뢰 경로인 `/usr/lib/ladspa`의 버전별 라이브러리를 사용합니다. H9 II 전용 udev 규칙은 활성 로컬 사용자에게만 HID 접근 권한을 부여합니다. 새 규칙 설치 후 동글을 다시 연결하면 적용됩니다.

- 소스: `src/`, `native/`
- Linux 검사 기록: `analysis/pipewire-sfx-results.json`, `impulse-results.json`, `live-automation-results.json`, `live-profile-results.json`, `device-write-verification.json`
- 역분석 근거 및 전체 기능 추적: `docs/reverse-engineering.md`, `docs/features.md`
- 런타임: `~/.local/share/inzone-linux`, `~/.local/lib/ladspa`
- 프로파일: `~/.config/inzone-h9-ii`
- 백업: `~/.local/state/inzone-linux/backups`, 최초 백업 `backups/pre-surround`

USB Game·Chat은 모두 16 bit/48 kHz 스테레오입니다. 고해상도 무손실 파일은 음악 모드에서 고품질 변환해 재생하며, 동글로 24 bit/96 kHz 원본 비트를 그대로 전송할 수는 없습니다.
