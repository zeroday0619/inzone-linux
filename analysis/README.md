# 분석 보고서 및 검증 결과 아카이브 (Analysis & Reports)

이 디렉터리는 Sony INZONE Hub 역분석 과정에서 도출된 기술 검증 요약 보고서와 로컬 역공학 작업 공간을 관리하는 공간입니다.

---

## 1. Git 공개 추적 보고서 (Tracked Summary Reports)

`impulse-results.json`과 `pipewire-sfx-results.json`은 2026-09-09에 Embedded Swift DSP를 격리된 PipeWire 서버에 로드하여 측정한 기록입니다. 두 보고서의 플러그인 SHA-256은 빌드 결과와 일치합니다. 나머지 JSON은 제어·진단 도구의 Swift 전환 전 기록입니다. 실행 환경과 검증 범위는 [검증 감사 문서](../docs/completion-audit.md)에 기록합니다.

| 보고서 파일명 | 검증 항목 | 주요 계측 및 검증 내용 |
|---|---|---|
| **`impulse-results.json`** | Embedded Swift DSP의 7.1 임펄스 응답 | 379,392개 출력 샘플, 8개 채널 응답, 피크 1.0, 무음 꼬리 피크 0.0. 플러그인 SHA-256 포함 |
| **`pipewire-sfx-results.json`** | Embedded Swift DSP의 계산 정합성 | 3개 조합 각각 720,000개 샘플, 동일 Swift 플러그인의 직접 실행 대비 최대 절대 오차와 RMS 오차 0.0. 플러그인 SHA-256 포함 |
| **`live-profile-results.json`** | 실시간 세션 프로파일 전환 | 6개 프로파일 로드·라우팅 및 기록된 옵션 조합의 DSP 포트 확인 |
| **`profile-switch-results.json`** | 프로파일 전환 결과 | 6개 기본 프로파일의 종료 코드와 기본 싱크 기록. 전환 시간은 포함하지 않음 |
| **`live-automation-results.json`** | 프로세스 자동 전환 데몬 | 게임 시작·종료 시 전환, 수동 선택 보존, 종료 후 프로파일 복원 |
| **`device-write-verification.json`** | USB HID 하드웨어 제어 안전성 | H9 II 실제 하드웨어의 사이드톤 레지스터 값 쓰기, 반영 상태 확인, 초기값 복원 테스트 기록 |
| **`install-results.json`** | 이전 설치 결과 | 최초 설치·반복 설치·백업 성공 플래그. 세부 파일 목록과 권한은 포함하지 않음 |
| **`tui-results.json`** | 이전 터미널 UI 동작성 | Curses TUI의 80×24 터미널, 6개 화면, 변경 적용 없음, 종료 코드 0. SwiftTUI의 검증 결과는 아님 |

> 상세한 역분석 알고리즘 분석은 [`docs/reverse-engineering.md`](../docs/reverse-engineering.md), 전체 구현 현황은 [`docs/completion-audit.md`](../docs/completion-audit.md)를 참고하세요.

DSP 이식 검증의 C 기준 디스크립터·출력 해시는 [`Tests/InzoneCoreTests/Fixtures/dsp-golden.json`](../Tests/InzoneCoreTests/Fixtures/dsp-golden.json)에 보존합니다. 정상 유한값을 유지하는 87개 시나리오의 출력 4,489,216개 샘플은 Swift 구현과 비트 단위로 일치합니다. 비유한 재귀 상태를 만들던 2개 시나리오는 보안 복구 동작으로 인해 의도적으로 달라집니다. 이 기준 데이터는 실제 헤드셋 캡처가 아니며, 입력 생성 조건과 기준 바이너리·소스 해시를 포함합니다.

---

## 2. 로컬 전용 데이터 (Untracked Local Artifacts)

저장소의 `.gitignore` 규칙에 따라 아래의 하위 폴더와 파일들은 로컬 개발 환경에만 유지되며 Git 커밋에서 자동 제외됩니다.

- **`payload/`**: 공식 인스톨러의 MSI 및 CAB에서 정적 추출된 원본 Windows 바이너리 (`inzonevirtualizer.dll`, `inzonehub.dll`, `shp_for_game_v2.0_512tap.hki`, `wh_g910n_standard.ba` 등)
- **`decompiled/`**: ILSpy를 통해 역어셈블된 관리형 C# 소스 코드 (`SoundQualitySettingsViewModel.decompiled.cs`, `ApoFileCommunication.decompiled.cs` 등)
- **`msi/`**: MSI 데이터베이스 추출 파일 및 OLE 스트림 목록
- **원시 분석 덤프**: 디스어셈블리(`.asm`), 스트링 덤프(`.strings-*.txt`), PE 바이너리 헤더 덤프(`.pe.txt`), 원시 오디오 캡처(`.wav`, `.f32`)

`make assets` 또는 `swift run inzone-tools fetch`를 저장소 최상위 디렉터리에서 실행하면 필요한 원본 바이너리와 디컴파일 결과를 `analysis/payload/` 및 `analysis/decompiled/`에 생성합니다. Swift 패키지 의존성은 `Package.swift`와 `Package.resolved`로 관리하며, `make sync`로 준비합니다. MSI/CAB 추출과 디컴파일에 필요한 외부 도구는 별도로 설치해야 합니다.

확보한 설치 파일을 사용하려면 `make assets FETCH_FLAGS=--offline`을 실행합니다. 개별 추출·역어셈블리 명령은 [`docs/reverse-engineering.md`](../docs/reverse-engineering.md)를 참고하세요. PipeWire와 프로파일 진단은 `inzone-tools diagnose-impulse`, `diagnose-sfx`, `diagnose-live-profiles`, `diagnose-live-automation`으로 실행합니다.

현재 `diagnose-sfx`는 `make native-build`로 생성한 Embedded Swift 플러그인 `native/inzone_dsp.so`를 직접 사용합니다. 격리 세션에는 SHA-256 기반 파일명과 전용 `LADSPA_PATH`로 배치하며, 설치된 플러그인을 재사용하지 않습니다. 새 보고서에는 플러그인 해시를 함께 기록하여 DSP 이식 전 측정과 구분합니다.

---

## 3. 새로운 분석 보고서 등록 절차

새로운 Swift 진단 도구나 하드웨어 테스트의 결과를 공개 저장소에 포함하려면 다음 단계를 따릅니다:

1. 결과 요약 보고서를 JSON 형식으로 `analysis/` 아래에 저장합니다. 대상 커밋, Swift·PipeWire 버전, 실행 명령과 실행 환경을 기록하여 이전 구현의 결과와 구분합니다.
2. 보고서 내에 개인정보(사용자 계정명, 고유 식별자 등)나 원본 바이너리의 덤프가 포함되지 않았는지 검토합니다.
3. `.gitignore` 파일에 해당 파일의 추적 예외 규칙(`!/analysis/<new-report>.json`)을 추가합니다.
4. `git status`로 해당 보고서만 정상적으로 추적되는지 확인한 후 커밋합니다.
