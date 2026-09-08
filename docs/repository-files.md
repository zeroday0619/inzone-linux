# 저장소 파일 구성 및 자산 수명 주기 (Repository Structure & Asset Lifecycle)

이 문서는 프로젝트의 디렉터리 구조, Git 공개 파일과 로컬 생성 파일의 분류 기준, 자산(Asset) 추출 및 빌드 파이프라인, 그리고 Git 커밋 전 보안 위생 수칙을 설명합니다.

---

## 1. 공개 정책 및 클린룸 원칙 (Clean-room Policy)

본 프로젝트는 오픈소스 저작권과 Sony의 지적 재산권을 철저히 준수하기 위해 **클린룸 역분석 및 재구현(Clean-room Implementation)** 원칙을 따릅니다.

- **원작권 보호**: Sony의 독점 저작물(설치 바이너리 EXE, MSI, DLL, 암호화된 HRTF HKI, 하드웨어 보정 BA 등)은 Git 저장소에 커밋하거나 배포하지 않습니다.
- **자동화된 로컬 파이프라인**: 런타임에 필요한 오디오 필터 및 EQ 테이블은 각 사용자가 Sony 공식 서버로부터 직접 인스톨러를 다운로드하여 로컬에서 무결성을 검증한 뒤 정적 추출하도록 구현되었습니다.
- **공개 대상**: 자체 작성한 C/Python 소스 코드, PipeWire/WirePlumber 설정 파일, 시스템 udev 규칙, 단위/통합 테스트 코드, 그리고 분석 결과 보고서(JSON/Markdown)만을 공개합니다.

---

## 2. 파일 분류 매트릭스 (File Classification Matrix)

| 구분 | Git 저장소 공개 항목 | 로컬에만 보관 (Git 제외) |
|---|---|---|
| **빌드 & 패키지** | • 최상위 `Makefile`<br>• `native/Makefile` | • 빌드 임시 파일 (`*.o`, `*.tmp`)<br>• 다운로드 캐시 및 임시 디렉터리 |
| **소스 코드** | • `src/` (Python CLI, TUI, 데몬, 드라이버)<br>• `native/` (C LADSPA DSP 엔진 구현) | • 가상 환경 (`.venv/`, `venv/`)<br>• 바이트코드 캐시 (`__pycache__/`, `*.pyc`) |
| **시스템 설정** | • `configs/` (WirePlumber 51/52 설정)<br>• `configs/systemd/` (사용자 서비스 유닛)<br>• `configs/udev/` (70-inzone-h9-ii.rules) | • 사용자 런타임 설정 (`~/.config/inzone-h9-ii`)<br>• 활성 WirePlumber 세션 파일 |
| **도구 & 스크립트** | • `tools/fetch_assets.py`<br>• `tools/install_profiles.py`<br>• `tools/export_eq_tables.py`<br>• `tools/export_presets.py`<br>• `tools/disassemble.py` | • `tools/ilspycmd` (다운로드된 디컴파일러)<br>• `tools/.store/`, `.dotnet/`, `.nuget/` |
| **분석 & 역분석** | • `docs/` (기술 보고서 및 아키텍처 문서)<br>• `analysis/README.md`<br>• `evidence/installer.json` (공식 URL 및 해시) | • `downloads/` (Sony 설치 파일 EXE/MSI)<br>• `analysis/payload/` (추출된 원본 바이너리)<br>• `analysis/decompiled/` (디컴파일 소스)<br>• `analysis/msi/`, `*.ole`, 원시 덤프 파일 |
| **오디오 자산** | 없음 (로컬에서 정적 추출하여 생성) | • `assets/` (`sony-eq-tables.json`, `sony-presets.json`, HRTF/BA 파일 등) |
| **테스트 & 검증** | • `tests/` (31개 단위 테스트 및 별도 통합 테스트 코드)<br>• `analysis/*.json` (검토 완료된 요약 검증 보고서) | • 원시 오디오 녹음 파일 (`*.wav`, `*.f32`)<br>• 장치 원시 USB/HID 캡처 및 터미널 덤프 |
| **백업 데이터** | 없음 | • `backups/`, `~/.local/state/inzone-linux/backups` |

---

## 3. 자산 준비 및 빌드 수명 주기 (Asset Lifecycle)

최상위 `Makefile`은 검증 → 자산 추출 → 네이티브 C 컴파일 → 단위 테스트 → 사용자 배포의 전 과정을 체계적으로 관리합니다.

```
       make fetch
           │ (공식 인스톨러 다운로드 & SHA-256 검증)
           ▼
       make assets
           │ (ILSpy 준비, MSI/CAB 정적 추출, HKI/BA 복호화, EQ 테이블 생성)
           ▼
       make build
           │ (native/ C LADSPA DSP 플러그인 컴파일)
           ▼
       make check (or make test)
           │ (단위 테스트 31종 실행)
           ▼
       make install (or make all)
             (WirePlumber, udev 규칙, CLI 스크립트 설치)
```

### 주요 Make 타깃 가이드

- **`make help`**: 사용 가능한 모든 타깃과 환경 변수 옵션을 출력합니다.
- **`make fetch`**: Python 표준 라이브러리만을 사용하여 Sony 공식 서버로부터 `INZONEHub_Setup_1.0.19.0.exe`를 다운로드하고 고정 크기와 SHA-256 해시를 검증합니다.
- **`make assets`**: `fetch`를 포함하여 7-Zip으로 MSI 및 CAB를 압축 해제하고, ILSpy로 필요한 어셈블리 클래스를 역어셈블한 뒤 기본 HRTF, 모델 보정 필터, 10밴드 EQ 계수 테이블을 `assets/` 디렉터리에 생성합니다. Windows 바이너리는 전혀 실행되지 않습니다.
- **`make build`**: `assets`를 준비한 후 `native/` 디렉터리의 C 소스 코드를 컴파일하여 `inzone_dsp.so` 플러그인을 빌드합니다.
- **`make check`** (또는 `make test`): 시스템에 설치하기 전 전체 단위 테스트 스위트를 실행하여 모든 DSP 및 파일 파서 로직을 검증합니다.
- **`make`** (또는 `make install`): 자산 준비, 빌드, 검증을 순차적으로 수행한 후, 데스크톱 사용자 환경(`~/.local/`, `~/.config/`)에 설치하고 udev 규칙을 시스템에 등록합니다.

### 빌드 변수 및 오프라인 모드
- **오프라인 빌드**: 이미 인스톨러 파일이 준비되어 있는 폐쇄망 환경에서는 네트워크 다운로드를 건너뛸 수 있습니다.
  ```sh
  make assets FETCH_FLAGS=--offline
  ```
- **별도 경로의 인스톨러 지정**:
  ```sh
  make assets FETCH_FLAGS='--installer /path/to/INZONEHub_Setup_1.0.19.0.exe'
  ```
- **설치 사용자 홈 지정**:
  ```sh
  make install INSTALL_HOME=/home/username
  ```
- **Python 인터프리터 변경**:
  ```sh
  make check PYTHON=/usr/bin/python3
  ```

---

## 4. Git 커밋 전 위생 점검 (Git Hygiene)

저장소에 비공개 파일이나 대용량 바이너리가 실수로 포함되지 않도록 커밋 전 다음 절차를 수행합니다.

### 4.1. 제외 상태 및 미추적 파일 확인
```sh
git status --short --ignored
```
- `downloads/`, `assets/`, `analysis/payload/` 등의 경로가 `!` 또는 `??` 상태가 아닌 정상적인 무시(`!!`) 상태인지 확인합니다.

### 4.2. 인덱스 추적 목록 검사
```sh
git ls-files
```
- 추적 대상 목록에 `.exe`, `.dll`, `.cab`, `.msi`, `.hki`, `.ba`, `.so` 등의 바이너리 파일이 포함되어 있지 않은지 최종 확인합니다.

### 4.3. 실수로 추적된 파일 해제 방법
만약 `.gitignore` 적용 전이나 `git add -f` 등으로 비공개 파일이 스테이징된 경우:
```sh
git rm --cached path/to/unwanted_file
```
위 명령으로 로컬 디스크의 실제 파일은 보존하면서 Git 인덱스에서만 안전하게 추적을 해제할 수 있습니다.
