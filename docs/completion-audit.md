# Linux 구현 및 검증 범위 (Implementation & Verification Audit)

이 문서는 Swift 구현의 검증 경로와 이전 구현에서 수집한 측정 결과를 구분합니다. CLI, TUI, 설정 관리, 자산 추출, 진단 도구와 테스트는 Swift로 구현합니다. 실시간 LADSPA DSP는 `Sources/InzoneDSP/`의 Embedded Swift 구현이며, `native/Makefile`이 공유 라이브러리를 생성합니다. `Sources/CLADSPA/`에는 C ABI 선언만 있습니다.

## 1. 검증 기준

- **DSP 정합성**: 블록 크기, In-place 처리와 재초기화가 출력에 미치는 영향을 검사합니다. PipeWire 출력 비교의 기준이 Linux LADSPA 구현인지 Sony 원본 엔진인지 명시합니다.
- **입력 무결성**: 손상된 필터, 잘못된 설정값, 비정상 HID 패킷과 자산 해시 불일치를 거부합니다.
- **상태 보존**: 프로파일 전환과 설정 갱신 실패 시 기존 파일 및 세션 상태를 복원하는지 검사합니다.
- **검증 범위 분리**: 테스트 소스의 존재, 테스트 실행 성공, 임시 경로 설치, 실제 설치와 실기기 작동을 별도로 기록합니다.

## 2. Swift 테스트 및 진단 매핑

| 검증 영역 | 구현 위치 | 테스트·진단 경로 | 검증 범위 |
|---|---|---|---|
| 네이티브 DSP | `Sources/InzoneDSP/Plugin.swift`, `Dynamics.swift`, `SpatialALC.swift` | `Tests/InzoneCoreTests/NativeDSPTests.swift`, `DSPGoldenTests.swift`, `Fixtures/dsp-golden.json` | LADSPA 계약, 기존 C 출력 해시, 제어값 변경, 비유한 입력, 가변 블록, In-place 처리, 재활성화와 독립 인스턴스 |
| 필터 복호화·개인화 | `Sources/InzoneCore/FilterCrypto.swift`, `Filters.swift` | `Tests/InzoneCoreTests/FilterTests.swift` | MD5/SHA-256 및 AES 알려진 정답, HKI/BA 구조, Cipher 7, 안정성·유한값 검사, 정규화, 원자적 가져오기 |
| 설정·EQ·Windows 호환성 | `Sources/InzoneCore/Settings.swift`, `Presets.swift`, `GraphRenderer.swift` | `Tests/InzoneCoreTests/SettingsTests.swift`, `PresetsTests.swift` | 설정값 검증, 그래프 순서, 프리셋, JSONC·enum 파싱, Windows 왕복 변환 및 손실 변환 거부 |
| HID 통신 | `Sources/InzoneCore/Device.swift` | `Tests/InzoneCoreTests/DeviceTests.swift` | 패킷 인코딩·디코딩, 체크섬, 거래 ID 및 비동기 알림 처리. 실제 USB 쓰기는 별도 검증 |
| 프로파일·자동화 | `Sources/InzoneCore/ProfileController.swift`, `Automation.swift` | `Tests/InzoneCoreTests/ProfileControllerTests.swift`, `AutomationTests.swift` | 파일·상태 복구, 프로세스 이름·우선순위·디바운스, 수동 선택 보존 |
| CLI·설치 | `Sources/InzoneCLI/`, `Sources/InzoneToolsCore/` | `Tests/InzoneCoreTests/CommandLineTests.swift`, `Tests/InzoneToolsTests/InstallationTests.swift` | 필수 플러그인·udev 다이제스트, 사용자 단계의 root·홈 소유 UID 거부, live·staging 시스템 단계의 권한 분리, 설치 파일 배치, 기존 사용자 설정 보존, 백업 및 자산 무결성 |
| SwiftTUI | `Sources/InzoneTUI/InzoneTUI.swift` | `Tests/InzoneTUITests/TUITests.swift`, `TerminalSessionTests.swift` | 화면 렌더링, 키 입력, 입력값 검증, 종료 처리와 실제 PTY 상호작용. 하드웨어 조작은 별도 검증 |
| 자산 추출·역어셈블리 | `Sources/InzoneToolsCore/` | `Tests/InzoneToolsTests/` | 설치 파일 무결성, 추출·디컴파일 경로, EQ·프리셋 데이터, PE RVA 범위 |
| PipeWire 임펄스·DSP | `Sources/InzoneDiagnostics/` | `inzone-tools diagnose-impulse`, `diagnose-sfx` | 채널별 응답, 피크·무음 복귀, PipeWire 출력과 Linux LADSPA 기준 출력 비교 |
| 실행 중인 세션 | `Sources/InzoneDiagnostics/` | `inzone-tools diagnose-live-profiles`, `diagnose-live-automation` | 실제 프로파일 로드·라우팅, 자동 전환 및 원래 상태 복원 |

Swift 패키지는 Swift 6.3 이상을 요구하며, TUI는 `minacle/swift-tui` 0.12.0을 사용합니다. 테스트는 XCTest와 Swift Testing으로 작성합니다. 로컬 Sony 자산이 없는 경우 관련 테스트가 건너뛰어질 수 있으므로, 성공 건수와 건너뛴 항목을 함께 확인해야 합니다.

```sh
make check
```

`make check`는 빌드와 자산 준비 후 Swift 테스트를 실행합니다. 설치 Makefile은 비특권 `install-all`을 한 번 실행합니다. 이 조정 명령은 실행 파일을 먼저 봉인하고, 플러그인과 udev 규칙의 별도 봉인 스냅샷과 다이제스트를 사용자 경로 쓰기 전에 준비합니다. 사용자 설치 후 `/usr/bin/sudo`에는 세 procfd와 두 다이제스트만 전달합니다. live root 단계는 저장소를 받지 않으며, 같은 descriptor에서 두 데이터 스냅샷의 regular-file 형식, 크기, 필수 봉인과 다이제스트를 검증한 뒤 그 데이터를 씁니다. 권한 경계 명령은 작업 디렉터리 `/`와 상속한 표준 입출력 descriptor를 사용하고 임시 캡처 파일을 만들지 않습니다. 사용자 단계는 root를 거부하고 홈 소유 UID를 확인합니다. live 시스템 단계는 root와 실행 중인 memfd의 필수 봉인을 요구하며, staging 단계는 root를 거부하고 저장소 기반 입력을 유지합니다. 확보한 설치 파일로 자산을 준비하려면 `make check FETCH_FLAGS=--offline`을 사용합니다. 실제 PipeWire 진단은 별도로 실행하며, 프로파일·자동화 진단은 현재 오디오 세션과 설정을 변경한 뒤 복원합니다.

```sh
swift run inzone-tools diagnose-impulse
swift run inzone-tools diagnose-sfx
swift run inzone-tools diagnose-live-profiles
swift run inzone-tools diagnose-live-automation
```

## 3. 전환 전 측정 기록

아래 JSON은 Swift 전환 전에 기존 제어·진단 코드와 C DSP를 사용하여 수집한 기록입니다. 파일을 보존하며, Swift 구현으로 재측정한 결과로 간주하지 않습니다. 원본 보고서에 없는 정확도, 지연, 환경 정보 또는 검사 범위를 추가로 추정하지 않습니다.

| 보고서 | 기록된 결과 | 적용 범위 |
|---|---|---|
| [`device-write-verification.json`](../analysis/device-write-verification.json) | 사이드톤 `4 → 3 → 4` | 해당 필드의 쓰기·복원 사례. 모든 HID 제어 항목의 실기기 검증을 입증하지 않음 |
| [`live-profile-results.json`](../analysis/live-profile-results.json) | 6개 프로파일 로드·라우팅 및 기록된 DSP 포트 확인 | 당시 프로파일과 옵션 조합 |
| [`profile-switch-results.json`](../analysis/profile-switch-results.json) | 6개 프로파일 전환의 종료 코드 0 및 기본 싱크 | 전환 소요 시간은 기록되지 않음 |
| [`live-automation-results.json`](../analysis/live-automation-results.json) | 게임 시작·종료 전환, 수동 선택 보존, 종료 후 `music` 복원 | 보고서에 나열된 자동화 시나리오 |
| [`install-results.json`](../analysis/install-results.json) | 최초 설치·반복 설치·백업 플래그 `true` | 세부 파일 목록과 권한은 보고서에 기록되지 않음 |
| [`tui-results.json`](../analysis/tui-results.json) | 이전 Curses UI의 80×24 터미널, 6개 화면, 변경 적용 없음, 종료 코드 0 | 이전 UI의 화면 이동 기록. SwiftTUI·하드웨어 쓰기·마이크 동작의 검증 결과는 아님 |

## 4. Swift 전환 이후 검증 상태

2026-09-09에 `feat/swift-reimplementation` 작업 트리(기준 커밋 `c9ed0d2`)에서 확인했습니다. 환경은 Debian forky/sid x86_64, Swift 6.3.3, PipeWire 1.6.8입니다. 실제 데스크톱 세션의 WirePlumber는 0.5.15이며 아래 격리 진단에서는 사용하지 않았습니다.

| 명령·검사 | 결과 |
|---|---|
| `make check -o assets` | 이전에 Swift로 추출한 로컬 에셋 재사용. 릴리스 실행 파일 2개와 Embedded Swift DSP 빌드, XCTest 137개와 Swift Testing 9개 통과, 실패·건너뛰기 0개 |
| 보안 수정 후 격리 빌드의 전체 XCTest 번들 | 최신 소스로 빌드한 XCTest 192개 통과, 실패·건너뛰기 0개. 공유 `.build` 잠금 때문에 `make check` 래퍼와 Swift Testing 9개는 이 최종 재실행에서 반복하지 않음 |
| C 구현과의 수치 비교 | 6개 descriptor. 유한값 87개 시나리오·4,489,216개 출력 샘플의 Float 비트 일치. 비유한 상태를 만들던 2개 시나리오는 보안 복구를 위해 의도적으로 차이. 기준 C 소스·ELF·컴파일 옵션은 golden fixture에 기록 |
| `inzone-tools diagnose-impulse` | Swift DSP를 격리 서버에 로드. 출력 379,392개 샘플, 8개 채널 응답, 최대 피크 1.0, 무음 꼬리 피크 0.0 |
| `inzone-tools diagnose-sfx` | 빌드한 Swift DSP를 임시 LADSPA 경로에 배치. 3개 조합 각각 720,000개 샘플, 동일 플러그인의 직접 실행 대비 최대 절대 오차·RMS 오차 0.0, 전송 오프셋 2,304프레임 |
| `readelf -d .build/release/inzone-profile` | Swift 공유 런타임 의존성 없음. Linux 시스템 라이브러리는 동적 링크 |
| DSP ELF 검사 | 34,512바이트. 동적 의존성은 `libm.so.6`·`libc.so.6`, 공개 심볼은 `ladspa_descriptor` 하나. RPATH/RUNPATH 없음, BIND_NOW와 DT_FINI 설정 |
| 반복 로드·해제 | 1,005회 load/instantiate/activate/run(0)/cleanup/unload 성공. `mallinfo2().uordblks` 표본은 87,216→87,216바이트, 해제 후 플러그인 매핑 없음 |

PipeWire 결과는 [`impulse-results.json`](../analysis/impulse-results.json)과 [`pipewire-sfx-results.json`](../analysis/pipewire-sfx-results.json)에 기록했습니다. 두 보고서의 `plugin_sha256`은 `e93cf211a0d60b283a1a9396e3f523276494f9f92775cc0abf0f0d6f3a0b8cd0`으로 빌드한 Swift 플러그인과 일치합니다. 전송 오프셋은 격리된 시험 연결의 정렬값이며 헤드셋 지연 측정값이 아닙니다. PipeWire 출력 비교의 기준은 동일한 Swift LADSPA 구현의 직접 실행이며 Sony Windows 엔진과의 비교가 아닙니다. 설치 및 PTY 테스트는 임시 홈, 비특권 staging 시스템 경로와 가상 터미널을 사용했습니다. 실제 root 권한의 live 시스템 설치는 실행하지 않았습니다.

오디오 콜백과 Swift DSP 호출 경로는 최적화 빌드에서 `@_noLocks` 검사를 통과했습니다. 외부 libm의 성능 계약은 C 선언의 `swift_attr`로 명시하며, Swift 컴파일러가 libm 내부 구현을 증명하는 것은 아닙니다. Embedded Swift는 Swift 6.3.3의 실험적 컴파일 모드입니다. 이 기록은 해당 환경의 수치·로딩·격리 오디오 검사이며 모든 환경의 최악 실행시간이나 장시간 무중단 동작을 보장하지 않습니다.

`swift-terminal` 0.0.2에는 Linux import 순서 보정을 적용했습니다. SwiftPM의 로컬 의존성 재정의 경고와 제거 조건은 [해당 소스 기록](../Vendor/swift-terminal/UPSTREAM.md)에 설명합니다.

- **Verification required — 실제 설치**: Swift 설치 도구를 통한 사용자 경로 배치, 소유권, 재설치와 root 권한의 live 시스템 설치 및 서비스 활성화.
- **Verification required — 실기기 HID**: Swift 통신 구현으로 조회·쓰기·재조회·복원을 수행한 결과.
- **Verification required — 실제 오디오 세션**: 헤드셋과 데스크톱 세션을 사용한 Swift 프로파일·자동화 진단 결과.
- **Verification required — 장치 연결 TUI**: SwiftTUI에서 하드웨어 설정과 마이크 테스트를 수행한 결과.
