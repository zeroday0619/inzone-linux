# 기능 명세 및 구현 현황 (Feature Specification & Tracking)

이 문서는 Sony INZONE Hub 1.0.19.0의 기능과 비교하여, Linux(PipeWire / WirePlumber / Swift LADSPA) 환경에서 제공되는 기능의 구현 상태, 기술적 상세 내용, 제약 사항 및 검증 기준을 정리한 기술 명세서입니다. CLI, TUI, 설정 관리, 자산 추출 도구, 테스트와 실시간 LADSPA DSP는 Swift로 구현합니다. DSP 소스는 `Sources/InzoneDSP/`에 있으며, Embedded Swift로 `native/inzone_dsp.so`를 빌드합니다.

표의 **구현됨**은 해당 기능의 구현이 존재한다는 의미입니다. Swift 전환 이후의 테스트와 격리된 PipeWire 측정은 [검증 감사 문서](completion-audit.md)에 기록합니다. 실제 헤드셋·데스크톱 세션 검증과 구분하며, 전환 전 실기기 보고서를 Swift 검증 결과로 해석하지 않습니다.

---

## 1. 음향 및 DSP 신호 처리 (Audio & DSP)

| 기능 항목 | 지원 상태 | 세부 구현 설명 | 검증 및 테스트 기준 |
|---|---|---|---|
| **7.1ch 가상 서라운드** | **구현됨** | 소니 공식 512-tap FIR HRTF 필터를 적용하여 7.1ch(FL, FR, FC, LFE, RL, RR, SL, SR) 입력을 바이노럴 스테레오로 렌더링 | PipeWire 채널별 임펄스 응답 검증 (`inzone-tools diagnose-impulse`) |
| **H9 II 하드웨어 보정 필터** | **구현됨** | H9 II (MDR-G900N / YY2987) 전용 7단 IIR Biquad 필터(`wh_g910n_standard.ba`)를 네이티브 double 정밀도로 연산 | 필터 계수, 극점 안정성 및 손상 입력 검사 (`Tests/InzoneCoreTests/FilterTests.swift`) |
| **내부 공간 ALC** | **구현됨** | 8프레임 블록, 32샘플(0.667ms) 룩어헤드 지연을 갖는 다이내믹 피크 리미터로 공간 음향 후 피크 제한 및 +1 dB 게인 적용 | 블록 크기·In-place 출력 일치 검사 (`Tests/InzoneCoreTests/NativeDSPTests.swift`), PipeWire 임펄스 측정 |
| **Sony 10밴드 EQ** | **구현됨** | 31.5Hz ~ 16kHz의 10개 대역을 -12dB ~ +12dB(1dB 간격)로 조절. 소니의 사전 계산된 Biquad 계수 테이블을 호스트 DSP에 적용 | 추출 계수 검사 (`Tests/InzoneToolsTests/`), 프리셋 변환 검사 (`Tests/InzoneCoreTests/PresetsTests.swift`) |
| **Sony 공식 7대 프리셋** | **구현됨** | Flat, FPS 1, FPS 2, FPS 3, Immersion Flat(RPG), Bass Boost, Music/Video 프리셋 내장. Flat 외 적용 시 출력 ALC 자동 연동 | 프리셋 파라미터 및 Windows 프로파일 변환 검사 (`Tests/InzoneCoreTests/PresetsTests.swift`) |
| **ModeEqualizer (몰입 음장)** | **구현됨** | 소니 전용 몰입감 보정 Biquad 필터 구현 (Standard / Immersive 음장 모드 선택 지원) | `inzonevirtualizer.dll` RVA `0x19ae0`에서 확인한 계수 우선순위와 그래프 비교 |
| **출력 자동 음량 제어 (Output ALC)** | **구현됨** | -18dB 감쇠 → Threshold -18dB, Ratio 1000:1, Attack 1ms, Release 1s 피크 압축 → +18dB 복구 스테이지 구성 | PipeWire 출력과 LADSPA 기준 출력 비교 (`inzone-tools diagnose-sfx`) |
| **동적 범위 제어 (DRC)** | **구현됨** | 끔(Off) / 낮음(Low) / 높음(High) 3단계 지원. 10ms 피크 감쇠 기반 상향 압축 및 확장 커브 구현 | 블록 크기·In-place 출력 일치 검사 (`Tests/InzoneCoreTests/NativeDSPTests.swift`), PipeWire 출력 비교 |
| **마이크 자동 게인 제어 (Mic AGC)** | **구현됨** | 마이크 입력 신호의 크기를 조정하는 소프트웨어 AGC | LADSPA 블록 처리 검사 및 마이크 그래프 로드 검사 (`inzone-tools diagnose-live-profiles`) |
| **고해상도 음원 입력** | **구현됨** | 음악 프로파일에서 PipeWire 리샘플러를 사용하여 재생. USB 동글 출력은 16-bit 48kHz이며, 고해상도 입력의 원래 비트 깊이·샘플레이트는 보존되지 않음 | 실제 음원 재생과 리샘플러 동작은 환경별 검증 필요 |

---

## 2. 하드웨어 장치 제어 (USB HID Hardware Control)

INZONE H9 II의 USB 동글(VID `054c`, PID `0fa8`) 인터페이스 5를 통해 독자적인 소니 HCI 패킷 프로토콜로 직접 제어합니다.

| 제어 항목 | CLI 키 | 지원 상태 | 제어 범위 및 옵션 | 비고 |
|---|---|---|---|---|
| **소음 제어 (ANC)** | `anc` | **구현됨** | `0`: 끔, `1`: 노이즈 캔슬링(NC), `2`: 주변 소리 | 하드웨어 레지스터 즉시 반영 |
| **주변 소리 크기** | `ambient_level` | **구현됨** | `1` ~ `20` (20단계 레벨) | 주변 소리 모드일 때 동작 |
| **음성 집중 모드** | `voice_focus` | **구현됨** | `0`: 끔, `1`: 켬 | 주변 소리 내 사람 목소리 대역 통과 |
| **사이드톤 (내 목소리 듣기)** | `sidetone` | **구현됨** | `0` ~ `10` (11단계 레벨) | 마이크 입력 헤드폰 모니터링 |
| **Game / Chat 밸런스** | `game_chat` | **구현됨** | `0` ~ `100` (50: 정중앙) | Game과 Chat 스트림 간 음량 비율 |
| **물리 NC 버튼 순환 설정** | `toggle_*` | **구현됨** | `toggle_off`, `toggle_nc`, `toggle_ambient` (`0`: 제외, `1`: 포함) | 헤드셋 본체 NC 버튼 누를 때 순환 목록 |
| **시작 시 NC 모드** | `nc_startup` | **구현됨** | `0`: 끔, `1`: NC, `2`: 주변 소리, `3`: 이전 상태 유지 | 전원 On 시 기본 소음 제어 상태 |
| **시작 시 Bluetooth** | `bt_startup` | **구현됨** | `0`: 끔, `1`: 켬, `2`: 이전 상태 유지 | 전원 On 시 블루투스 모듈 활성화 여부 |
| **자동 전원 끄기** | `auto_power` | **구현됨** | `0`, `5`, `15`, `30`, `60`, `180` (분 단위, `0`: 비활성화) | 신호 없을 때 대기 전원 차단 |
| **음성 안내 언어** | `language` | **구현됨** | `0`: 영어, `1`: 일본어, `2`: 중국어 | 내장 음성 안내(Voice Prompt) 언어 |
| **알림음 및 음성 안내** | `guidance` | **구현됨** | `0`: 끔, `1`: 켬 | 조작 알림 비프음 및 가이던스 |
| **배터리 잔량 조회** | - | **구현됨** | `0%` ~ `100%` (충전 중 여부 포함) | 실시간 상태 조회 (`--device-status`) |
| **펌웨어 버전 확인** | - | **구현됨** | 헤드셋 및 동글 펌웨어 버전 문자열 | 실시간 상태 조회 (`--device-status`) |
| **마이크 테스트 듣기** | - | **구현됨** | 실시간 로컬 루프백 (최대 30초, 파일 저장 없음) | TUI 내 `T` 단축키로 활성화 |

---

## 3. 프로파일 관리 및 자동화 (Profiles & Automation)

| 기능 항목 | 지원 상태 | 세부 설명 |
|---|---|---|
| **6대 사전 정의 프로파일** | **구현됨** | `surround`(공간 음향), `fps`(발소리 강조), `music`(원음 지향), `voice`(통화 최적화), `balanced`(균형 기본값), `restore`(초기 복원) |
| **프로파일별 독립 설정 저장** | **구현됨** | EQ, DRC, 출력 ALC, 마이크 AGC, 음장 모드(Sound Mode), HRTF 선택이 프로파일마다 독립적으로 영구 보존 (`~/.config/inzone-h9-ii`) |
| **프로세스 기반 자동 전환** | **구현됨** | 1초 주기로 실행 중인 프로세스를 감지하여 대상 프로파일로 자동 전환. Linux 네이티브 실행 파일 및 Wine/Proton Windows 실행 파일(`*.exe`) 이름 감지 지원 |
| **우선순위 및 지연 안정화** | **구현됨** | 규칙별 우선순위(Priority) 부여 지원. 일치 상태가 2초 이상 지속될 때만 전환(디바운스)하여 불필요한 빈번한 전환 방지 |
| **자동 복원 및 수동 우선** | **구현됨** | 등록된 게임/앱이 종료되면 직전 프로파일로 자동 원복. 사용자가 TUI/CLI로 수동 전환한 경우 해당 선택을 최우선 유지 |
| **systemd 사용자 데몬** | **구현됨** | 로그인 시 백그라운드에서 상시 실행되는 `inzone-profile-auto.service` 유닛 제공 |

---

## 4. 데이터 상호 운용성 (Interoperability & Data)

| 기능 항목 | 지원 상태 | 세부 설명 |
|---|---|---|
| **Windows 프로파일 가져오기/내보내기** | **구현됨** | Windows INZONE Hub의 `%APPDATA%\Sony\INZONE Hub\SoundProfile.json` 파일을 직접 읽고 쓰기 지원. enum 파싱, 주석 처리, 왕복(Round-trip) 변환 검사 |
| **개인화 HRTF (`.hki`) 가져오기** | **구현됨** | 모바일 앱에서 생성된 사용자 맞춤형 Cipher 7 암호화 HKI 파일 복호화 및 유효성 검증(방위각, 탭 수, 극각, FFT 정규화) |
| **개인 보정 필터 (`YY2987.ba`) 가져오기** | **구현됨** | H9 II 개인 맞춤 보정 필터의 52바이트 헤더 래퍼 인식, 체크섬 검증, 7단 Biquad 안정성 확인 후 안전하게 적용 |
| **설정 백업 및 롤백** | **구현됨** | 설정 변경 또는 프로파일 교체 실패 시 기존 WirePlumber 설정 및 오디오 싱크 상태를 자동으로 즉시 복원 |

---

## 5. 터미널 UI 및 개발 도구 (TUI & Tooling)

| 기능 항목 | 구현 | 실행·검증 경로 |
|---|---|---|
| **터미널 UI** | [minacle/swift-tui](https://github.com/minacle/swift-tui) 0.12.0 기반 SwiftTUI 화면. 프로파일, EQ, 프리셋, 하드웨어, 자동화와 개인화 입력 제공 | `inzone-profile --tui`, `Tests/InzoneTUITests/` |
| **자산 수집·정적 추출** | Swift에서 설치 파일 무결성 검사, MSI/CAB 추출 및 ILSpy 실행을 조정 | `inzone-tools fetch`, `make assets` |
| **필터·EQ·프리셋 내보내기** | HKI/BA 복호화, WAV·계수 생성, 디컴파일 소스 및 YAML 데이터 추출 | `inzone-tools export-filters`, `export-eq`, `export-presets` |
| **역어셈블리 범위 조회** | PE RVA를 가상 주소 범위로 변환하고 기존 역어셈블리 텍스트에서 명령어 추출 | `inzone-tools disassemble START END [--input FILE.asm]` |
| **테스트·진단** | XCTest와 Swift Testing을 이용한 테스트, Swift 기반 PipeWire 및 프로파일 진단 | `make check`, `inzone-tools diagnose-impulse`, `diagnose-sfx`, `diagnose-live-profiles`, `diagnose-live-automation` |

Swift Package Manager가 패키지 의존성을 관리합니다. Linux 터미널 의존성 수정은 `Vendor/swift-terminal/UPSTREAM.md`에 기록합니다.

DSP의 LADSPA ABI, Biquad, DRC·마이크 AGC, ALC는 `Sources/InzoneDSP/Plugin.swift`, `Dynamics.swift`, `SpatialALC.swift`에서 구현합니다. `Tests/InzoneCoreTests/DSPGoldenTests.swift`는 이전 C 구현의 기준 데이터와 출력 비트·제어 변경·디스크립터를 비교합니다. Embedded Swift의 검증 도구체인은 Swift 6.3.3이며, 시스템 수학 함수 연동은 C ABI 선언을 사용합니다.

---

## 6. 범위 제한 및 미지원 항목 (Scope Limitations & Security Rationale)

| 기능 항목 | 지원 상태 | 미지원 사유 및 기술적 배경 |
|---|---|---|
| **귀 사진 스마트폰 촬영 분석** | **제공하지 않음** | Sony 클라우드 서버와 사용자 계정 로그인이 필요한 영역입니다. 개인정보 보호와 오프라인 독립 실행 원칙에 따라 서버 통신 기능은 포함하지 않으며, Windows 환경에서 한 번 생성된 `personalized_hrtf.hki` 및 `YY2987.ba` 파일을 로컬에서 가져와 사용하는 방식을 지원합니다. |
| **펌웨어 OTA 업데이트 플래싱** | **미제공 (조회만 제공)** | 무선 USB 통신 상에서 역분석된 비공식 프로토콜을 사용한 펌웨어 플래싱은 헤드셋 하드웨어를 영구적으로 손상(Brick)시킬 위험이 있습니다. 안전을 위해 현재 설치된 펌웨어 버전의 읽기(Read) 기능만 제공하며, 펌웨어 업데이트는 공식 Windows INZONE Hub를 통해서만 수행하는 것을 강력히 권장합니다. |
