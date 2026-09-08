# Sony INZONE H9 II — Linux 완전 구현

Sony INZONE H9 II (MDR-G900N / 모델 코드 YY2987) 무선 게이밍 헤드셋을 위한 완전한 Linux 네이티브 드라이버 및 DSP 오디오 스택입니다.

Windows 전용 유틸리티인 **INZONE Hub 1.0.19.0**의 독점 기능(7.1ch 공간 음향 가상화, 소니 전용 10밴드 EQ 및 프리셋, 내부 공간 ALC, 동적 범위 제어(DRC), 마이크 AGC, 그리고 USB HID 하드웨어 제어)을 클린룸 역분석하여 **PipeWire**, **WirePlumber**, 그리고 **C LADSPA 네이티브 엔진**으로 재구현했습니다.

---

## 목차
- [주요 기능](#주요-기능)
- [시스템 요구사항](#시스템-요구사항)
- [설치 및 빠른 시작](#설치-및-빠른-시작)
- [대화형 TUI 가이드](#대화형-tui-가이드)
- [CLI 명령어 레퍼런스](#cli-명령어-레퍼런스)
- [하드웨어 장치 제어](#하드웨어-장치-제어)
- [오디오 아키텍처 및 DSP 파이프라인](#오디오-아키텍처-및-dsp-파이프라인)
- [Windows 프로파일 및 개인화 연동](#windows-프로파일-및-개인화-연동)
- [프로세스 기반 자동 프로파일 전환](#프로세스-기반-자동-프로파일-전환)
- [테스트 및 검증](#테스트-및-검증)
- [프로젝트 디렉터리 및 기술 문서](#프로젝트-디렉터리-및-기술-문서)

---

## 주요 기능

- **정통 7.1ch Sony 공간 음향 (Spatial Audio)**: 소니 공식 512-tap FIR HRTF 필터와 H9 II 전용 7단 IIR Biquad 하드웨어 보정 필터(`wh_g910n_standard.ba`), 그리고 피크 왜곡 방지를 위한 32-샘플 내부 공간 ALC(Lookahead Dynamic Limiter)를 실시간으로 구동합니다.
- **하드웨어 직접 제어 (USB HID)**: Windows 유틸리티 없이도 액티브 노이즈 캔슬링(ANC), 주변 소리 20단계, 음성 집중, 사이드톤(내 목소리 듣기), Game/Chat 하드웨어 음량 밸런스, 물리 버튼 순환 모드, 전원 켤 때 초기 상태, 자동 절전 타이머, 음성 안내 언어를 직접 제어하고 배터리 잔량을 실시간으로 조회합니다.
- **독립 6대 프로파일**: `surround`(7.1 가상화), `fps`(발소리 대역 특화), `music`(원음 지향 무손실 재생), `voice`(통화 최적화), `balanced`(기본 균형), `restore`(초기 복원)를 즉시 전환할 수 있습니다.
- **소니 공식 10밴드 EQ 및 7대 프리셋**: 소니의 사전 계산된 Biquad 계수 테이블을 그대로 적용하여 Flat, FPS 1/2/3, Immersion Flat(RPG/Adventure), Bass Boost, Music/Video 프리셋과 사용자 지정 EQ(-12dB ~ +12dB, 1dB 단위)를 완벽 지원합니다.
- **Windows 양방향 데이터 호환**: Windows INZONE Hub의 프로파일 파일(`SoundProfile.json`)을 직접 가져오거나 내보낼 수 있으며, 스마트폰 앱에서 촬영한 귀 사진 기반 개인화 파일(`personalized_hrtf.hki`, `YY2987.ba`)을 리눅스 환경으로 즉시 임포트할 수 있습니다.
- **프로세스 감지 자동 전환 데몬**: 게임이나 특정 프로그램(Wine, Proton, 네이티브 리눅스 게임) 실행 시 지정한 프로파일로 자동 전환되고, 프로그램 종료 시 직전 프로파일로 안전하게 복원되는 background 서비스를 제공합니다.
- **풍부한 인터페이스**: 터미널 환경에 최적화된 직관적인 Curses TUI(`inzone-profile`)와 스크립트 자동화를 지원하는 종합 CLI를 모두 제공합니다.

---

## 시스템 요구사항

- **운영체제**: Linux (PipeWire 0.3.50+ 및 WirePlumber 0.4.10+ 권장, 1.6.8 버전 검증 완료)
- **지원 하드웨어**: Sony INZONE H9 II USB 무선 동글 (USB VID `054C`, PID `0FA8`)
- **빌드 및 런타임 의존성**:
  - Python 3.10 이상
  - `python3-cryptography` (필터 복호화 및 개인화 파싱용)
  - 7-Zip (`7z` 또는 `7zz`)
  - `build-essential` (C 컴파일러 `gcc` / `make`)
  - `ladspa-sdk` (LADSPA 헤더)
  - `.NET 10 SDK` (에셋 준비 시 ILSpy 디컴파일러 구동용)

---

## 설치 및 빠른 시작

저장소에는 순수 소스 코드와 분석 문서만 포함되어 있습니다. Sony 공식 인스톨러로부터 필수 런타임 에셋을 다운로드·검증하고 네이티브 라이브러리를 빌드하여 시스템에 배포하는 전체 과정은 `Makefile`을 통해 원스텝으로 진행됩니다.

### 1. 패키지 설치
Debian/Ubuntu 계열 배포판:
```sh
sudo apt update
sudo apt install python3 python3-cryptography 7zip build-essential ladspa-sdk
```
> **참고**: `.NET 10 SDK`는 배포판 패키지 관리자 또는 Microsoft 공식 가이드에 따라 준비하세요.

### 2. 빌드 및 설치 실행
**데스크톱 일반 사용자 권한**으로 최상위 디렉터리에서 `make`를 실행합니다:
```sh
make
```

> **주의**: 전체 명령을 `sudo make`로 실행하지 마세요. 관리자 권한은 마지막 단계에서 udev 규칙 등록 및 신뢰 경로(`/usr/lib/ladspa`) 라이브러리 복사에만 `sudo`를 통해 요청됩니다.

### 주요 Make 타깃 안내
```sh
# 1. 소니 공식 인스톨러만 다운로드 및 SHA-256 해시 검증
make fetch

# 2. MSI/CAB 추출, ILSpy 디컴파일, HKI/BA 복호화 및 EQ 테이블 생성
make assets

# 3. 네이티브 C LADSPA DSP 플러그인(inzone_dsp.so) 빌드
make build

# 4. 전체 단위 테스트(29개 테스트) 실행 (시스템 설치 없음)
make check

# 5. 오프라인 모드 (이미 다운로드된 인스톨러와 도구 재사용)
make FETCH_FLAGS=--offline

# 6. 별도로 보관 중인 인스톨러 파일 지정
make FETCH_FLAGS='--installer /path/to/INZONEHub_Setup_1.0.19.0.exe'

# 7. 전체 타깃 및 옵션 도움말 출력
make help
```

자세한 저장소 구성 및 자산 정책은 [저장소 파일 구성](docs/repository-files.md)을 참고하세요.

---

## 대화형 TUI 가이드

터미널에서 아래 명령을 실행하면 Curses 기반의 대화형 제어 인터페이스가 열립니다:
```sh
~/.local/bin/inzone-profile
```
*(최소 72열 × 24행 터미널 권장)*

```
┌──────────────────────── INZONE H9 II Controller ────────────────────────┐
│  1. fps        FPS · 저음 감소 / 발소리 대역 강조                          │
│  2. music      음악 · 원음 / 안정성 우선                                  │
│  3. voice      통화 · 말소리 강조 / 마이크 저역 정리                      │
│  4. balanced   기본 · EQ 없음 / 균형 설정                                 │
│* 5. surround   서라운드 · Sony 기본 HRTF / 공간 음향                       │
│  6. restore    변경 전 음색·지연 설정 복원                                │
└─────────────────────────────────────────────────────────────────────────┘
```

### TUI 단축키 안내

| 키 | 기능 | 설명 |
|:---:|---|---|
| **↑ / ↓** 또는 **1–6** | 프로파일 커서 이동 | 원하는 프로파일을 선택합니다. |
| **Enter** | 프로파일 즉시 적용 | 선택한 프로파일의 WirePlumber 노드와 DSP를 적용합니다. |
| **D** | DRC (동적 범위 제어) | 끔(Off) → 낮음(Low) → 높음(High) 순환 변경 |
| **A** | 출력 자동 음량 제어 | 선택한 프로파일의 출력 ALC 활성화/비활성화 토글 |
| **M** | 마이크 자동 게인 | 선택한 프로파일의 마이크 AGC 활성화/비활성화 토글 |
| **E** | Sony 10밴드 EQ 편집 | 31.5Hz ~ 16kHz (-12 ~ +12 dB, 1 dB 단위) 설정 |
| **S** | Sony 공식 프리셋 선택 | Flat, FPS 1/2/3, RPG, Bass Boost, Music/Video 선택 |
| **U** | 프로세스 자동 전환 설정 | 게임/프로세스 바인딩 규칙 편집 및 자동 감지 서비스 시작/중지 |
| **P** | HRTF 모드 선택 | 서라운드 프로파일의 기본(Standard) / 개인화(Personal) HRTF 선택 |
| **I** | 개인화 파일 가져오기 | 로컬의 개인화 HKI 및 H9 II 보정 BA 파일 경로를 입력받아 임포트 |
| **H** | 헤드셋 장치 제어 모달 | ANC, 사이드톤, Game/Chat 밸런스, 전원 설정 등 하드웨어 제어 창 열기 |
| **Q / Esc** | 종료 | TUI 프로그램을 종료합니다 (오디오 설정은 유지됨). |

### 장치 제어 모달 (H 키)
- **← / → 방향키**: 제어 파라미터 값 변경 (예: ANC 모드 변경, 사이드톤 레벨 조절)
- **Enter**: 변경된 하드웨어 값을 헤드셋으로 즉시 전송
- **R**: 헤드셋의 실시간 하드웨어 상태(배터리 잔량, 펌웨어 버전 등) 다시 읽기
- **T**: 마이크 실시간 테스트 듣기 시작/중지 (최대 30초, 파일로 녹음되지 않는 순수 메모리 루프)

---

## CLI 명령어 레퍼런스

스크립트 연동, 단축키 바인딩, 또는 헤드리스 환경을 위해 완전한 CLI 인터페이스를 제공합니다.

### 1. 프로파일 적용 및 상태 조회
```sh
# 프로파일 즉시 전환
inzone-profile surround
inzone-profile fps
inzone-profile music

# 현재 활성 프로파일 확인
inzone-profile --status

# 사용 가능한 프로파일 목록 확인
inzone-profile --list
```

### 2. DSP 파라미터 조정 (`--set`)
```sh
# FPS 프로파일의 DRC를 높음(2)으로 설정 (0: 끔, 1: 낮음, 2: 높음)
inzone-profile --set fps drc 2

# Voice 프로파일의 마이크 AGC 활성화
inzone-profile --set voice mic_agc true

# Surround 프로파일의 출력 ALC 활성화
inzone-profile --set surround output_alc true

# Music 프로파일의 10밴드 EQ 플랫 초기화
inzone-profile --set music eq '[0,0,0,0,0,0,0,0,0,0]'

# 음장 모드 직접 지정 ('immersive' 또는 'standard')
inzone-profile --set surround sound_mode '"immersive"'

# 전체 프로파일 DSP 설정 JSON 확인
inzone-profile --settings
```

### 3. Sony 공식 프리셋 적용 (`--preset`)
```sh
# 사용 가능한 소니 프리셋 목록 출력
inzone-profile --preset

# FPS 프로파일에 소니 FPS 1 프리셋 적용
inzone-profile --preset fps fps1

# Surround 프로파일에 Immersion Flat (RPG) 프리셋 적용
inzone-profile --preset surround immersion_flat
```

### 4. 하드웨어 장치 제어 (`--device-status`, `--device-set`)
```sh
# 헤드셋 실시간 상태 조회 (배터리, 펌웨어, ANC 상태 등 JSON 출력)
inzone-profile --device-status

# 액티브 노이즈 캔슬링(ANC) 설정 (0: 끔, 1: NC, 2: 주변 소리)
inzone-profile --device-set anc 1

# 사이드톤(내 목소리 듣기) 레벨 설정 (0 ~ 10)
inzone-profile --device-set sidetone 4

# 주변 소리 크기 조절 (1 ~ 20)
inzone-profile --device-set ambient_level 12

# Game/Chat 음량 밸런스 설정 (0 ~ 100, 50이 정중앙)
inzone-profile --device-set game_chat 50

# 사용 가능한 장치 필드 목록:
# anc, ambient_level, voice_focus, game_chat, sidetone, toggle_off,
# toggle_nc, toggle_ambient, nc_startup, bt_startup, auto_power, language, guidance
```

### 5. 설정 백업 및 복원
```sh
# 현재 전체 DSP 설정을 JSON 파일로 백업
inzone-profile --export backup_settings.json

# 백업 파일로부터 설정 복원
inzone-profile --import backup_settings.json
```

---

## 오디오 아키텍처 및 DSP 파이프라인

INZONE H9 II는 USB 단일 장비 내에 두 개의 독립된 물리 PCM 재생 스트림을 가집니다:
- **PCM 1 (Interface 4)**: `Game` 스트림 (`alsa_output.usb-Sony_INZONE_H9_II-00.stereo-game`)
- **PCM 0 (Interface 1)**: `Chat` 스트림 (`alsa_output.usb-Sony_INZONE_H9_II-00.stereo-chat`)

### 서라운드 신호 흐름도
게임에서 7.1ch 서라운드 출력을 설정하면 `inzone.sony-surround` 가상 싱크가 입력을 받아 다음 순서로 실시간 렌더링합니다:

```
[7.1ch Audio Stream (FL, FR, FC, LFE, RL, RR, SL, SR)]
                         │
                         ▼
┌─────────────────────────────────────────────────────────────────┐
│ 1. Sony Spatial Convolution (FIR 512-tap)                       │
│    - 소니 공식 HRTF를 통한 바이노럴 3차원 공간 음장 합성        │
└─────────────────────────────────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────────┐
│ 2. Model BA Equalization (7-stage IIR Biquad)                   │
│    - H9 II 하드웨어 보정 필터(wh_g910n_standard.ba) 연산        │
└─────────────────────────────────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────────┐
│ 3. Internal Spatial ALC (32-sample Lookahead Limiter)           │
│    - 공간 처리 후 피크 왜곡 억제 및 +1 dB 레벨 보정              │
└─────────────────────────────────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────────┐
│ 4. PipeWire Inline DSP (선택 적용)                              │
│    - Amp1 (-18dB) → ModeEQ → 10밴드 EQ → Output ALC             │
│      → Amp2 (+18dB) → Peak DRC                                  │
└─────────────────────────────────────────────────────────────────┘
                         │
                         ▼
[Hardware ALSA Endpoint: Game PCM 1 (16-bit 48kHz Stereo)]
```

> **기술적 주의사항**:
> 1. 게임 내 자체 헤드폰 가상 서라운드(3D Audio 등) 옵션을 켠 상태에서 `inzone.sony-surround`를 사용하면 공간 처리가 중복되어 왜곡될 수 있으므로 게임 내 출력은 **7.1 서라운드 스피커** 모드로 설정하세요.
> 2. PipeWire 1.6.8의 `audioconvert` 모듈이 필터 그래프를 내림차순(역순)으로 실행하는 버그를 고려하여, WirePlumber 설정 빌더가 배열 순서를 사전에 반전 보정하여 생성합니다.

---

## Windows 프로파일 및 개인화 연동

### 1. 개인화 HRTF 및 보정 필터 가져오기
스마트폰 모바일 앱에서 귀 사진을 촬영하여 생성된 개인화 파일이 있다면 Linux 환경으로 가져와 사용할 수 있습니다:
- **Windows 파일 위치**: `%APPDATA%\Sony\INZONE Hub\VirtualizeUser`
- **필요한 파일**: `personalized_hrtf.hki` 및 H9 II 개인화 보정 파일 `YY2987.ba`

```sh
# 개인화 파일 임포트 (52바이트 헤더 래퍼 및 Cipher 7 자동 복호화/검증)
inzone-profile --personalize-import /path/to/personalized_hrtf.hki /path/to/YY2987.ba

# 서라운드 프로파일의 HRTF를 개인화 모드로 설정
inzone-profile --set surround hrtf '"personal"'
```

### 2. Windows INZONE Hub 프로파일(`SoundProfile.json`) 연동
Windows INZONE Hub에서 내보낸 프로파일이나 `%APPDATA%\Sony\INZONE Hub\SoundProfile.json`을 읽고 쓸 수 있습니다:
```sh
# Windows 프로파일 파일 내 항목 목록 확인
inzone-profile --windows-list /path/to/SoundProfile.json

# 1번 항목을 리눅스 서라운드 프로파일로 가져오기
inzone-profile --windows-import surround /path/to/SoundProfile.json 1

# 현재 리눅스 서라운드 설정을 Windows 호환 JSON으로 내보내기
inzone-profile --windows-export surround exported_profile.json
```

---

## 프로세스 기반 자동 프로파일 전환

게임을 실행하면 자동으로 `surround`나 `fps`로 전환되고, 디스코드를 켜면 `voice`로 전환되도록 설정할 수 있습니다.

```sh
# 실행 파일과 프로파일 매핑 (우선순위: 숫자가 클수록 우선)
inzone-profile --auto-bind game.exe surround 10
inzone-profile --auto-bind cs2 fps 15
inzone-profile --auto-bind discord voice 5

# 등록된 자동 전환 규칙 확인
inzone-profile --auto-config

# 자동 전환 서비스 활성화 (systemd 사용자 데몬 시작)
inzone-profile --auto-enable

# 자동 전환 서비스 비활성화
inzone-profile --auto-disable

# 특정 규칙 제거
inzone-profile --auto-remove game.exe
```

- **Wine / Proton 지원**: Linux 네이티브 프로세스는 물론 Wine/Proton 하에서 실행되는 Windows 프로세스 이름(`*.exe`)을 완벽하게 인식합니다.
- **안정화 지연 (Debounce)**: 프로세스 일치 상태가 2초 이상 지속될 때만 전환하여 일시적인 프로세스 스폰 시의 오디오 깜빡임을 방지합니다.
- **자동 원복 및 수동 우선**: 실행 중이던 게임이 종료되면 직전 프로파일로 자동 원복됩니다. 게임 실행 중 사용자가 TUI나 CLI로 프로파일을 수동 변경한 경우, 사용자의 수동 선택이 최우선 유지됩니다.

---

## 테스트 및 검증

모든 구현은 Linux 네이티브 환경에서 검증되었으며, 29개의 단위 테스트를 제공합니다:

```sh
# 전체 단위 테스트 실행
make check

# PipeWire 인라인 필터 및 LADSPA 연산 일치 검증
python3 tests/pipewire_sfx.py

# 7.1 가상 서라운드 임펄스 응답 및 분리도 검증
python3 tests/pipewire_impulse.py

# (선택) 실제 데스크톱 사용자 세션 라이브 전환 검증
python3 tests/live_profiles.py
python3 tests/live_automation.py
```

자세한 테스트 결과 및 계측 데이터는 [docs/completion-audit.md](docs/completion-audit.md)와 [analysis/README.md](analysis/README.md)에 기록되어 있습니다.

---

## 프로젝트 디렉터리 및 기술 문서

- **소스 코드**:
  - `src/`: Python CLI, Curses TUI, 설정 관리자, HID 드라이버, 데몬 구현
  - `native/`: C 언어로 작성된 LADSPA DSP 플러그인 (`inzone_dsp.so`)
  - `configs/`: WirePlumber 및 udev 시스템 설정
  - `tools/`: 인스톨러 검증, 에셋 추출, 설치 스크립트
- **기술 분석 문서**:
  - [docs/reverse-engineering.md](docs/reverse-engineering.md): INZONE Hub 바이너리 및 HID 프로토콜 역분석 기술 분석서
  - [docs/features.md](docs/features.md): 전체 기능 구현 현황 및 명세
  - [docs/repository-files.md](docs/repository-files.md): 저장소 파일 구성 및 자산 수명 주기
  - [docs/completion-audit.md](docs/completion-audit.md): 구현 완성도 및 테스트 감사 보고서
  - [analysis/README.md](analysis/README.md): 분석 보고서 및 측정 결과 아카이브
- **런타임 및 상태 디렉터리**:
  - 오디오 에셋: `~/.local/share/inzone-linux/assets`
  - LADSPA 플러그인: `/usr/lib/ladspa/inzone_dsp_*.so`, `~/.local/lib/ladspa/inzone_dsp.so`
  - 사용자 설정: `~/.config/inzone-h9-ii/`
  - WirePlumber 설정: `~/.config/wireplumber/wireplumber.conf.d/`
  - 자동 백업: `~/.local/state/inzone-linux/backups/`
