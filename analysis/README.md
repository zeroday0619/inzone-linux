# 분석 보고서 및 검증 데이터 아카이브 (Analysis & Reports)

이 디렉터리는 Sony INZONE Hub 리버스 엔지니어링 과정에서 추출된 기술 데이터, 실측 검증 보고서(JSON), 그리고 로컬 분석 작업 공간을 관리하는 공간입니다.

---

## 1. 공개 추적 보고서 (Tracked Summary Reports)

저장소에 포함된 JSON 보고서들은 드라이버의 신호 처리 정합성과 하드웨어 제어 동작을 실측하고 검증한 데이터입니다:

| 보고서 파일명 | 검증 항목 | 주요 계측 및 검증 내용 |
|---|---|---|
| **`impulse-results.json`** | 7.1ch 임펄스 응답 | 379,392개 샘플 출력, 8개 채널 정상 응답, 최대 피크 1.0 제한, 잔류 노이즈 피크 0.0 확인 |
| **`pipewire-sfx-results.json`** | PipeWire DSP 계산 정합성 | 3개 프로파일 조합 각각 720,000개 샘플, LADSPA 엔진 직접 실행 대비 최대 절대 오차 및 RMS 오차 0.0 (무손실 신호 처리 확인) |
| **`live-profile-results.json`** | 세션 프로파일 전환 | 6대 기본 프로파일의 실시간 PipeWire 노드 연결 및 DSP 포트 라우팅 검증 |
| **`profile-switch-results.json`** | 프로파일 전환 안정성 | 기본 프로파일 전환 시 종료 코드 및 싱크 바인딩 정상 여부 확인 |
| **`live-automation-results.json`** | 프로세스 자동 감지 | 게임 실행/종료 시 프로파일 자동 전환, 수동 선택 보존, 종료 후 원복 동작 검증 |
| **`device-write-verification.json`** | USB HID 제어 안정성 | 실제 헤드셋 하드웨어의 사이드톤 레지스터 값 쓰기, 반영 확인, 초기값 복원 테스트 |

> 상세한 리버스 엔지니어링 분석 내용은 [`docs/reverse-engineering.md`](../docs/reverse-engineering.md), 세부 테스트 감사 결과는 [`docs/completion-audit.md`](../docs/completion-audit.md)를 참고하세요.

---

## 2. 로컬 전용 아티팩트 (Local Artifacts - Git 제외)

저작권 보호 및 저장소 용량 관리를 위해 아래 디렉터리는 `.gitignore`에 의해 로컬에만 유지되며 Git 커밋에서 제외됩니다:

- **`payload/`**: 소니 공식 인스톨러에서 정적 추출된 원본 바이너리 (`inzonevirtualizer.dll`, `inzonehub.dll`, `shp_for_game_v2.0_512tap.hki`, `wh_g910n_standard.ba` 등)
- **`decompiled/`**: ILSpy를 통해 디컴파일된 관리형 C# 소스 코드
- **`msi/`**: MSI 데이터베이스 및 OLE 스트림 추출 파일
- **원시 덤프 및 로그**: 디스어셈블리(`.asm`), 스트링 덤프(`.txt`), 오디오 원본 캡처(`.wav`, `.f32`)

### 로컬 에셋 추출 방법
저장소 루트에서 다음 명령을 실행하면 필요한 원본 바이너리와 디컴파일 결과가 `analysis/payload/` 및 `analysis/decompiled/`에 자동으로 생성됩니다:

```sh
# 공식 인스톨러 다운로드 및 에셋 자동 추출
make assets

# 이미 다운로드받은 설치 파일이 있는 경우 오프라인 실행
make assets FETCH_FLAGS=--offline
```

---

## 3. 신규 검증 보고서 추가 가이드

새로운 하드웨어 계측이나 진단 결과를 저장소에 추가할 때는 다음 절차를 따릅니다:

1. 요약 결과 보고서를 JSON 형식으로 `analysis/` 디렉터리에 생성합니다.
2. 보고서 내에 개인정보(사용자 계정 경로, 고유 식별자 등)나 원본 바이너리의 덤프가 포함되지 않았는지 검토합니다.
3. `.gitignore`에 해당 파일의 추적 예외 규칙(`!/analysis/<파일명>.json`)을 추가합니다.
4. `git status`로 해당 JSON 파일만 정상적으로 스테이징되는지 확인 후 커밋합니다.
