# Sony INZONE H9 II for Linux

Sony INZONE H9 II (MDR-G900N / 모델 코드 YY2987) 무선 게이밍 헤드셋을 위한 Linux 네이티브 드라이버 및 DSP 오디오 스택입니다.

Windows 전용 유틸리티인 **INZONE Hub 1.0.19.0**의 독점 기능(7.1ch 공간 음향 가상화, 소니 전용 10밴드 EQ 및 프리셋, 내부 공간 ALC, 동적 범위 제어(DRC), 마이크 AGC, 그리고 USB HID 하드웨어 제어)을 역분석하여 **PipeWire**, **WirePlumber**, 그리고 **Swift LADSPA 네이티브 엔진**으로 재구현했습니다.

프로파일 관리, USB HID 제어, 개인화 파일 처리, 자동 전환 데몬, 실시간 LADSPA DSP와 에셋 추출·설치·분석 도구를 Swift로 구현합니다. TUI는 [minacle/swift-tui](https://github.com/minacle/swift-tui)를 사용합니다. `inzone-profile`은 설치되는 CLI/TUI이며, `inzone-tools`는 저장소에서 사용하는 에셋·설치·분석 실행 파일입니다. LADSPA와 시스템 수학 함수 연동에는 C ABI 선언을 사용합니다. 빌드, 설치, 실행 및 테스트에 Python이나 uv는 필요하지 않습니다.

---

## 목차
- [주요 기능](#주요-기능)
- [시스템 요구사항](#시스템-요구사항)
- [설치 및 빠른 시작](#설치-및-빠른-시작)
- [Swift 의존성 및 개발 도구](#swift-의존성-및-개발-도구)
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
- **터미널 인터페이스**: SwiftTUI 기반 TUI(`inzone-profile`)와 스크립트 자동화를 위한 CLI를 제공합니다.

---

## 시스템 요구사항

- **운영체제**: Linux (PipeWire 및 WirePlumber 사용)
- **지원 하드웨어**: Sony INZONE H9 II USB 무선 동글 (USB VID `054C`, PID `0FA8`)
- **런타임 의존성**:
  - `pipewire-bin` (`pw-dump`, `pw-cat`, `pw-cli`, `pw-loopback` 및 Game/Chat 카드 프로파일)
  - `pulseaudio-utils` (`pactl`을 통한 기본 출력 및 음량 제어)
  - `systemd` 사용자 서비스 (`systemctl`을 통한 WirePlumber 및 자동 전환 서비스 제어)
  - 빌드한 실행 파일과 호환되는 Linux 시스템 라이브러리 (`glibc` 등)
- **빌드 및 설치 도구**:
  - Swift 6.3 이상 및 Swift Package Manager
  - `/proc`에 마운트된 procfs와 실행·파일 봉인을 지원하는 Linux memfd
  - 고정 경로 `/usr/bin/sudo` 및 `/usr/bin/udevadm`
  - `libcurl.so.4` (`inzone-tools`의 HTTPS 다운로드에 사용)
  - [SwiftTUI 0.12.0](https://github.com/minacle/swift-tui) (`Package.swift`에 고정하며 Swift Package Manager가 준비)
  - 7-Zip (`7z` 또는 `7zz`)
  - `build-essential` (`make`, 시스템 개발 헤더 및 링크 도구)
  - `ladspa-sdk` (LADSPA 헤더)
  - `.NET 10 SDK` (에셋 준비 시 ILSpy 디컴파일러 구동용)

`make swift-build`는 CLI와 개발 도구에 Swift 표준 라이브러리를 정적으로 링크합니다. `make native-build`는 Embedded Swift로 DSP 플러그인을 빌드하여 전체 Swift 표준 라이브러리와 Swift 공유 런타임 의존성을 제거합니다. Embedded Swift는 실험 기능이며, 현재 검증한 도구체인은 Swift 6.3.3입니다. 설치된 CLI와 DSP 플러그인 실행에 Swift 도구체인, Python, uv는 필요하지 않습니다. Linux 시스템 라이브러리는 동적으로 링크하므로 다른 배포판으로 바이너리를 옮길 때는 시스템 라이브러리 호환성을 확인해야 합니다.

---

## 설치 및 빠른 시작

저장소에는 순수 소스 코드와 분석 문서만 포함되어 있습니다. Sony 공식 인스톨러로부터 필수 런타임 에셋을 다운로드·검증하고 네이티브 라이브러리를 빌드하여 시스템에 배포하는 전체 과정은 `Makefile`을 통해 원스텝으로 진행됩니다.

### 1. 패키지 설치
Debian/Ubuntu 계열 배포판:
```sh
sudo apt update
sudo apt install pipewire-bin pulseaudio-utils 7zip build-essential ladspa-sdk
```
Swift 6.3 이상은 [Swift Linux 설치 가이드](https://www.swift.org/install/linux/)에 따라 준비합니다. `.NET 10 SDK`는 배포판 패키지 관리자 또는 Microsoft 공식 가이드에 따라 준비합니다.

### 2. Swift 패키지 준비

저장소 최상위 디렉터리에서 Swift 도구체인 버전을 확인하고 패키지 의존성을 준비합니다:

```sh
swift --version
make sync
```

`make sync`는 `swift package resolve`를 실행합니다. `Package.swift`에 선언한 패키지 제약 조건과 `Package.resolved`의 해결된 버전을 사용합니다. Swift 실행 파일이 `PATH`에 없으면 `make SWIFT=/absolute/path/to/swift`로 지정합니다.

### 3. 빌드 및 설치 실행
**데스크톱 일반 사용자 권한**으로 최상위 디렉터리에서 `make`를 실행합니다:
```sh
make
```

> **주의**: 전체 명령을 `sudo make`로 실행하지 마세요. 관리자 권한은 마지막 단계에서 udev 규칙 등록 및 신뢰 경로(`/usr/lib/ladspa`) 라이브러리 복사에만 `sudo`를 통해 요청됩니다.

`make install`은 비특권 조정 명령 `inzone-tools install-all`을 한 번 호출합니다. 이 명령이 사용자 설치와 시스템 설치를 순서대로 수행합니다. `~`는 `INSTALL_HOME`으로 지정한 데스크톱 사용자의 홈 디렉터리입니다.

`install-all`은 실행 중인 `/proc/self/exe`를 실행 가능한 memfd에 먼저 복사하고, 쓰기·크기 변경을 막는 Linux 파일 봉인을 적용합니다. 이어 DSP 플러그인과 `configs/udev/70-inzone-h9-ii.rules`를 각각 한 번 읽어 별도의 memfd에 봉인하고, 이 정확한 바이트의 SHA-256을 계산한 뒤 사용자 설치를 시작합니다. 사용자 단계는 저장소 플러그인을 다시 읽어 준비한 다이제스트와 비교하므로, 그사이 플러그인이 바뀌면 사용자 경로를 쓰기 전에 중단합니다. 마지막 시스템 단계는 절대 경로 `/usr/bin/sudo`에 실행 파일, 플러그인, udev 규칙의 `/proc/<coordinator-pid>/fd/<fd>` 경로만 전달합니다. root 프로세스는 저장소나 홈을 탐색하지 않고 두 불변 스냅샷을 설치하므로, 이후 저장소 파일이 바뀌어도 설치 바이트에는 영향을 주지 않습니다. `sudo` 암호를 입력하는 동안 빌드 경로가 교체되거나 원본 inode가 수정되어도, 시스템 단계는 봉인한 정확한 실행 파일 바이트를 사용합니다.

사용자 단계는 root 실행을 거부하고, 정규화한 `INSTALL_HOME`의 소유 UID가 현재 프로세스의 유효 UID와 맞는지 확인합니다. 이후 `.build/release/inzone-profile`을 `~/.local/bin/inzone-profile`에 실행 권한 `0755`로 원자적으로 교체하고, 사용자 설정·에셋·홈 LADSPA 플러그인을 설치합니다. 마지막 live 시스템 단계는 root 권한을 요구하므로 `sudo`로 실행하며, 저장소와 홈 경로를 받거나 탐색하지 않습니다. `sudo`와 `/usr/bin/udevadm`은 작업 디렉터리 `/`에서 표준 입출력 descriptor를 직접 상속하므로, root 임시 캡처 파일을 만들지 않습니다. 시스템 단계는 봉인된 udev 규칙과 해시 이름의 LADSPA 플러그인만 각각 `/etc/udev/rules.d`와 `/usr/lib/ladspa`에 설치합니다.

`install-system --staging-root`는 패키징과 테스트용 비특권 경로이며 root 실행을 거부합니다. 실제 시스템 단계에서는 `--staging-root`를 사용하지 않으며, 봉인된 memfd 실행 파일로 시작한 root 프로세스만 허용합니다.

| 저장소 설정 파일 | 설치 경로 |
|---|---|
| `configs/fps.conf`, `music.conf`, `voice.conf`, `balanced.conf` | `~/.config/inzone-h9-ii/` |
| `configs/original.conf` | `~/.config/inzone-h9-ii/original.conf` (없을 때만 설치) |
| `configs/52-inzone-game-chat.conf` | `~/.config/wireplumber/wireplumber.conf.d/52-inzone-game-chat.conf` |
| `configs/systemd/inzone-profile-auto.service` | `~/.config/systemd/user/inzone-profile-auto.service` |
| `configs/udev/70-inzone-h9-ii.rules` | `/etc/udev/rules.d/70-inzone-h9-ii.rules` |

재설치 시 기존 사용자 설치 파일을 `~/.local/state/inzone-linux/backups/`에 백업한 후 기본 프로파일 4개를 갱신합니다. 기존 `original.conf`, 활성 프로파일 `51-inzone-h9-ii.conf`, 사용자 DSP 설정 `profile-settings.json`, 자동 전환 규칙 `auto-profiles.json`은 보존합니다. 최초 설치에서는 `balanced.conf`를 활성 프로파일로 복사하고, `surround.conf`는 추출한 에셋으로 생성합니다. 프로파일 전환 시 선택한 설정만 활성 파일에 적용됩니다.

이전 Python 실행기는 교체 전에 백업합니다. 기존 `~/.local/share/inzone-linux/python/` 및 `venv/` 디렉터리는 복구를 위해 남겨 두며, Swift CLI에서는 사용하지 않습니다. 새 설치에서는 해당 디렉터리를 만들지 않습니다.

### 4. 장치 권한 적용 및 프로파일 활성화

설치가 완료되면 USB 동글을 분리한 뒤 다시 연결하여 udev 장치 접근 권한을 적용합니다. 규칙 다시 읽기만으로는 이미 연결된 장치의 권한이 갱신되지 않습니다. 데스크톱 사용자 세션에서 다음 명령으로 WirePlumber 설정과 서라운드 프로파일을 활성화합니다:

```sh
~/.local/bin/inzone-profile surround
```

### 주요 Make 타깃 안내
```sh
# 1. 소니 공식 인스톨러만 다운로드 및 SHA-256 해시 검증
make fetch

# 2. MSI/CAB 추출, ILSpy 디컴파일, HKI/BA 복호화 및 EQ 테이블 생성
make assets

# 3. Swift CLI/TUI·개발 도구 빌드, 에셋 준비 및 Swift LADSPA DSP 플러그인 빌드
make build

# 4. Swift 실행 파일을 빌드하거나 단위 테스트를 실행합니다 (에셋 준비 없음).
make swift-build
make swift-test

# 5. Swift 단위·DSP·설치 테스트를 실행합니다 (시스템 설치 없음).
make check

# 6. 준비된 인스톨러와 추출 도구를 오프라인에서 재사용합니다.
make assets FETCH_FLAGS=--offline

# 7. 별도로 보관 중인 인스톨러 파일 지정
make FETCH_FLAGS='--installer /path/to/INZONEHub_Setup_1.0.19.0.exe'

# 8. 전체 타깃 및 옵션 도움말 출력
make help
```

`SWIFT_CONFIGURATION`의 기본값은 `release`이며, `SWIFT_FLAGS`로 Swift Package Manager 옵션을 추가할 수 있습니다. 빌드 출력 디렉터리를 변경하면 `SWIFT_BINARY=/absolute/path/to/inzone-profile`과 `SWIFT_TOOLS_BINARY=/absolute/path/to/inzone-tools`도 지정합니다. DSP 컴파일러는 `SWIFTC`, 최적화 옵션은 `SWIFT_DSP_FLAGS`로 지정하며 기본값은 `-O -whole-module-optimization`입니다. `FETCH_FLAGS=--offline`은 에셋 준비 도구에 적용되므로, 오프라인 빌드에 필요한 Swift 의존성도 미리 준비해야 합니다.

자세한 저장소 구성 및 자산 정책은 [저장소 파일 구성](docs/repository-files.md)을 참고하세요.

---

## Swift 의존성 및 개발 도구

`Package.swift`는 Swift 6.3 이상, 실행 파일·라이브러리·테스트 타깃 및 패키지 의존성을 선언합니다. SwiftTUI는 0.12.0에 고정하며, `Package.resolved`에는 해결된 패키지 버전을 기록합니다. `.build/`와 `.swiftpm/`은 로컬 빌드 및 패키지 캐시이며 커밋하지 않습니다.

```sh
# Swift 패키지 의존성을 준비합니다.
make sync

# CLI/TUI와 에셋·설치·분석 도구를 빌드합니다.
make swift-build

# 개발 도구의 명령과 옵션을 확인합니다.
.build/release/inzone-tools --help

# 에셋과 Swift DSP를 준비한 뒤 전체 Swift 테스트를 실행합니다.
make check
```

`inzone-tools fetch`는 인스톨러 다운로드·검증, MSI/CAB 추출, ILSpy 디컴파일, HKI/BA 처리 및 EQ 테이블 생성을 담당합니다. `inzone-tools install-all`은 봉인된 실행 파일을 통해 사용자 설치와 live 시스템 설치를 조정합니다. `install`은 현재 사용자의 실행 파일, 설정, 에셋 및 홈 DSP 플러그인을 설치하며, `install-system`은 고정된 시스템 udev·LADSPA 경로만 설치합니다. `export-filters`, `export-eq`, `export-presets`, `disassemble`로 개별 역분석 작업을 실행합니다. 옵션은 `inzone-tools --help`로 확인합니다.

7-Zip과 .NET 10의 ILSpy는 외부 도구로 사용합니다. Swift 소스 또는 패키지 의존성을 변경한 뒤 설치된 CLI를 갱신하려면 `make install`을 다시 실행합니다.

DSP 플러그인은 Swift Package Manager 실행 파일과 별도로 `make native-build`가 `Sources/InzoneDSP/`를 `-enable-experimental-feature Embedded`로 컴파일하여 `native/inzone_dsp.so`에 생성합니다. `Sources/CLADSPA/`는 LADSPA와 시스템 함수의 C ABI 선언을 제공하는 시스템 라이브러리 모듈입니다. 플러그인은 `ladspa_descriptor`만 공개하고, ELF 종료 함수로 디스크립터 메모리를 정리하며, 외부 심볼을 로드 시점에 바인딩합니다. 실시간 호출의 컴파일러 검사 범위와 시스템 수학 함수에 대한 가정은 [DSP 구현 문서](docs/reverse-engineering.md#53-swift-dsp-및-ladspa-abi)에 설명합니다.

---

## 대화형 TUI 가이드

터미널에서 아래 명령을 실행하면 SwiftTUI 기반의 대화형 제어 인터페이스가 열립니다:
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

단위 테스트, Swift DSP 검증, CLI 및 설치 테스트는 Swift로 작성하며 `swift test`로 실행합니다. `make check`는 에셋과 빌드 결과를 준비한 뒤 Swift 테스트를 실행합니다. 설치 테스트는 Swift 설치 API에 임시 사용자 홈과 비특권 staging 시스템 디렉터리를 전달하여 배포 결과를 확인합니다. 실제 root 권한의 live 시스템 설치는 실행하지 않았으며, 실제 사용자 설정이나 시스템 서비스도 변경하지 않습니다.

```sh
# 에셋과 Swift 빌드 결과를 준비한 뒤 전체 Swift 테스트를 실행합니다.
make check

# 이미 준비한 환경에서 Swift 테스트만 실행합니다.
make swift-test

# 설치 테스트만 실행합니다.
make swift-test SWIFT_FLAGS='--filter InstallationTests'
```

`make swift-test`는 Swift DSP를 빌드한 뒤 Swift 테스트를 실행하며 에셋은 준비하지 않습니다. vendor 에셋 또는 릴리스 실행 파일이 없으면 관련 통합 테스트는 사유를 출력하고 건너뜁니다. 전체 검증은 `make check`를 사용합니다.

DSP 이식 검증에서는 정상 유한값을 유지하는 87개 합성 시나리오의 출력 4,489,216개 샘플을 이전 C 구현과 비교하여 부동소수점 비트 패턴 일치를 확인했습니다. 비유한 재귀 상태를 만들던 `4-unstable-feedback`과 `5-unstable-feedback`은 상태를 초기화하고 0을 출력하도록 보강했기 때문에 C 기준과 의도적으로 다릅니다. C 기준 결과의 SHA-256, 디스크립터와 입력 생성 조건은 `Tests/InzoneCoreTests/Fixtures/dsp-golden.json`에 보존하며, `DSPGoldenTests.swift`에서 회귀 검사합니다. 이 비교는 명시된 입력·빌드 환경의 수치 정합성을 검증합니다.

`inzone-tools diagnose-sfx`는 저장소에서 빌드한 플러그인을 SHA-256 기반 이름으로 격리 세션의 `LADSPA_PATH`에 배치합니다. PipeWire와 직접 LADSPA 실행 모두 이 플러그인을 사용하므로 설치된 플러그인과 혼동하지 않습니다. 현재 검사 결과와 이전 Python·C 구현의 측정 기록은 [docs/completion-audit.md](docs/completion-audit.md)와 [analysis/README.md](analysis/README.md)에서 구분합니다. 실제 오디오 전환, USB HID 제어, 장시간 자동 전환 동작은 별도 데스크톱 세션 검증이 필요합니다.

---

## 프로젝트 디렉터리 및 기술 문서

- **소스 코드**:
  - `Package.swift`, `Package.resolved`: Swift 타깃 및 SwiftTUI 의존성 잠금 버전
  - `Sources/`: Swift CLI, SwiftTUI 화면, 설정 관리, HID 제어, 개인화 파서, 자동 전환 데몬 및 에셋·설치·분석 도구
  - `Sources/InzoneDSP/`: Swift LADSPA 디스크립터, Biquad, DRC, ALC 및 마이크 AGC 구현
  - `Sources/CLADSPA/`: LADSPA·시스템 수학 함수의 C ABI 선언 및 시스템 모듈 정의
  - `Tests/`: Swift 단위 테스트, DSP·CLI·에셋 도구·설치 검증 및 이전 C DSP의 기준 해시
  - `native/`: DSP 빌드 규칙, ELF 심볼 공개 설정 및 생성된 `inzone_dsp.so`
  - `configs/`: WirePlumber 및 udev 시스템 설정
  - `tools/`: 로컬에서 준비한 ILSpy 실행 파일 및 .NET 도구 캐시 (Git 제외)
- **기술 분석 문서**:
  - [docs/reverse-engineering.md](docs/reverse-engineering.md): INZONE Hub 바이너리 및 HID 프로토콜 역분석 기술 분석서
  - [docs/features.md](docs/features.md): 전체 기능 구현 현황 및 명세
  - [docs/repository-files.md](docs/repository-files.md): 저장소 파일 구성 및 자산 수명 주기
  - [docs/completion-audit.md](docs/completion-audit.md): 구현 완성도 및 테스트 감사 보고서
  - [analysis/README.md](analysis/README.md): 분석 보고서 및 측정 결과 아카이브
- **런타임 및 상태 디렉터리**:
  - Swift 실행 파일: `~/.local/bin/inzone-profile`
  - 오디오 에셋: `~/.local/share/inzone-linux/assets`
  - LADSPA 플러그인: `/usr/lib/ladspa/inzone_dsp_*.so`, `~/.local/lib/ladspa/inzone_dsp.so`
  - 사용자 설정: `~/.config/inzone-h9-ii/`
  - WirePlumber 설정: `~/.config/wireplumber/wireplumber.conf.d/`
  - 자동 백업: `~/.local/state/inzone-linux/backups/`
