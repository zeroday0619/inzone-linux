# 분석 보고서 및 검증 결과 아카이브 (Analysis & Reports)

이 디렉터리는 Sony INZONE Hub 역분석 과정에서 도출된 기술 검증 요약 보고서와 로컬 역공학 작업 공간을 관리하는 공간입니다.

---

## 1. Git 공개 추적 보고서 (Tracked Summary Reports)

저장소에는 엄격한 검토를 거쳐 개인정보 및 원본 바이너리가 배제된 다음의 JSON 검증 결과 보고서들만 버전 관리됩니다.

| 보고서 파일명 | 검증 항목 | 주요 계측 및 검증 내용 |
|---|---|---|
| **`impulse-results.json`** | 7.1 가상 서라운드 임펄스 응답 | 각 채널(FL, FR, FC, LFE, RL, RR, SL, SR)별 바이노럴 분리도, 음량 제한(Peak Limiting), 무음 복귀 시간 계측 |
| **`pipewire-sfx-results.json`** | DSP 계산 정합성 | PipeWire filter-chain 인라인 그래프와 Linux 네이티브 C LADSPA 구현의 출력 비트 일치성 비교 |
| **`live-profile-results.json`** | 실시간 세션 프로파일 전환 | WirePlumber 서비스의 동적 리로드 안정성, 싱크 노드 바인딩 및 오디오 지연(Latency) 검증 |
| **`profile-switch-results.json`** | 프로파일 전환 성능 | 6개 기본 프로파일 간 전환 시 소요 시간 및 WirePlumber 재시작 버스트 리셋 검증 |
| **`live-automation-results.json`** | 프로세스 자동 전환 데몬 | 게임 실행 감지, 우선순위 큐 처리, 2초 디바운스 안정화, 앱 종료 시 직전 프로파일 자동 복원 검증 |
| **`device-write-verification.json`** | USB HID 하드웨어 제어 안전성 | H9 II 실제 하드웨어의 사이드톤 레지스터 값 쓰기, 반영 상태 확인, 초기값 복원 테스트 기록 |
| **`install-results.json`** | 시스템 설치 무결성 | 설치 및 재설치 시 파일 배치, 퍼미션, udev 규칙 적용, 이전 설정 백업 보존 검증 |
| **`tui-results.json`** | 터미널 UI 동작성 | Curses TUI 화면 렌더링, 키 입력 응답, 하드웨어 설정 모달, 마이크 테스트 루프 동작 검증 |

> 상세한 역분석 알고리즘 분석은 [`docs/reverse-engineering.md`](../docs/reverse-engineering.md), 전체 구현 현황은 [`docs/completion-audit.md`](../docs/completion-audit.md)를 참고하세요.

---

## 2. 로컬 전용 데이터 (Untracked Local Artifacts)

저장소의 `.gitignore` 규칙에 따라 아래의 하위 폴더와 파일들은 로컬 개발 환경에만 유지되며 Git 커밋에서 자동 제외됩니다.

- **`payload/`**: 공식 인스톨러의 MSI 및 CAB에서 정적 추출된 원본 Windows 바이너리 (`inzonevirtualizer.dll`, `inzonehub.dll`, `shp_for_game_v2.0_512tap.hki`, `wh_g910n_standard.ba` 등)
- **`decompiled/`**: ILSpy를 통해 역어셈블된 관리형 C# 소스 코드 (`SoundQualitySettingsViewModel.decompiled.cs`, `ApoFileCommunication.decompiled.cs` 등)
- **`msi/`**: MSI 데이터베이스 추출 파일 및 OLE 스트림 목록
- **원시 분석 덤프**: 디스어셈블리(`.asm`), 스트링 덤프(`.strings-*.txt`), PE 바이너리 헤더 덤프(`.pe.txt`), 원시 오디오 캡처(`.wav`, `.f32`)

`make assets` (또는 `python3 tools/fetch_assets.py`) 명령을 실행하면 필요한 원본 바이너리와 디컴파일 결과가 `payload/` 및 `decompiled/`로 자동 생성됩니다.

---

## 3. 새로운 분석 보고서 등록 절차

새로운 검증 스크립트나 하드웨어 테스트 결과를 추가하고 이를 공개 저장소에 포함하려면 다음 단계를 따릅니다:

1. 결과 요약 보고서를 JSON 형식으로 `analysis/` 아래에 저장합니다.
2. 보고서 내에 개인정보(사용자 계정명, 고유 식별자 등)나 원본 바이너리의 덤프가 포함되지 않았는지 검토합니다.
3. `.gitignore` 파일에 해당 파일의 추적 예외 규칙(`!/analysis/<new-report>.json`)을 추가합니다.
4. `git status`로 해당 보고서만 정상적으로 추적되는지 확인한 후 커밋합니다.
