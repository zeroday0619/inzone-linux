# 저장소 파일 구성 및 자산 수명 주기 (Repository Structure & Asset Lifecycle)

이 문서는 프로젝트의 디렉터리 구조, Git 공개 파일과 로컬 생성 파일의 분류 기준, 자산(Asset) 추출 및 빌드 파이프라인, 그리고 Git 커밋 전 보안 위생 수칙을 설명합니다.

---

## 1. 공개 정책 및 클린룸 원칙 (Clean-room Policy)

본 프로젝트는 오픈소스 저작권과 Sony의 지적 재산권을 철저히 준수하기 위해 **클린룸 역분석 및 재구현(Clean-room Implementation)** 원칙을 따릅니다.

- **원작권 보호**: Sony의 독점 저작물(설치 바이너리 EXE, MSI, DLL, 암호화된 HRTF HKI, 하드웨어 보정 BA 등)은 Git 저장소에 커밋하거나 배포하지 않습니다.
- **자동화된 로컬 파이프라인**: 런타임에 필요한 오디오 필터 및 EQ 테이블은 각 사용자가 Sony 공식 서버로부터 직접 인스톨러를 다운로드하여 로컬에서 무결성을 검증한 뒤 정적 추출하도록 구현되었습니다.
- **공개 대상**: 자체 작성한 Swift 소스 코드, 시스템 함수와 LADSPA의 C ABI 선언, PipeWire/WirePlumber 설정 파일, 시스템 udev 규칙, 단위/통합 테스트 코드, 그리고 분석 결과 보고서(JSON/Markdown)만을 공개합니다.

---

## 2. 파일 분류 매트릭스 (File Classification Matrix)

| 구분 | Git 저장소 공개 항목 | 로컬에만 보관 (Git 제외) |
|---|---|---|
| **빌드 & 패키지** | • 최상위 `Makefile`<br>• `native/Makefile`, `native/exports.map`<br>• `Package.swift`, `Package.resolved` | • Swift 빌드 및 의존성 캐시 (`.build/`, `.swiftpm/`)<br>• 빌드 임시 파일 (`*.o`, `*.tmp`)<br>• 다운로드 캐시 및 임시 디렉터리 |
| **소스 코드** | • `Sources/` (Swift CLI, SwiftTUI, 데몬, HID 제어, 파일 파서 및 개발 도구)<br>• `Sources/InzoneDSP/` (Swift LADSPA DSP 구현)<br>• `Sources/CLADSPA/` (C ABI 헤더와 시스템 모듈 정의) | • 컴파일된 실행 파일 및 `native/inzone_dsp.so` |
| **시스템 설정** | • `configs/` (WirePlumber 51/52 설정)<br>• `configs/systemd/` (사용자 서비스 유닛)<br>• `configs/udev/` (70-inzone-h9-ii.rules) | • 사용자 런타임 설정 (`~/.config/inzone-h9-ii`)<br>• 활성 WirePlumber 세션 파일 |
| **개발 도구** | • `Sources/InzoneTools/` (개발 도구 CLI)<br>• `Sources/InzoneToolsCore/` (에셋 추출·설치·분석 구현) | • `tools/ilspycmd` (다운로드된 디컴파일러)<br>• `tools/.store/`, `.dotnet/`, `.nuget/` |
| **분석 & 역분석** | • `docs/` (기술 보고서 및 아키텍처 문서)<br>• `analysis/README.md`<br>• `evidence/installer.json` (공식 URL 및 해시) | • `downloads/` (Sony 설치 파일 EXE/MSI)<br>• `analysis/payload/` (추출된 원본 바이너리)<br>• `analysis/decompiled/` (디컴파일 소스)<br>• `analysis/msi/`, `*.ole`, 원시 덤프 파일 |
| **오디오 자산** | 없음 (로컬에서 정적 추출하여 생성) | • `assets/` (`sony-eq-tables.json`, `sony-presets.json`, HRTF/BA 파일 등) |
| **테스트 & 검증** | • `Tests/` (Swift 단위·DSP·CLI·에셋 도구·설치 테스트)<br>• `analysis/*.json` (검토 완료된 요약 검증 보고서) | • 원시 오디오 녹음 파일 (`*.wav`, `*.f32`)<br>• 장치 원시 USB/HID 캡처 및 터미널 덤프 |
| **백업 데이터** | 없음 | • `backups/`, `~/.local/state/inzone-linux/backups` |

---

## 3. 자산 준비 및 빌드 수명 주기 (Asset Lifecycle)

최상위 `Makefile`은 Swift 패키지 준비, 인스톨러 검증, 자산 추출, Swift 빌드, 단위 테스트 및 사용자 배포 타깃을 제공합니다. 런타임, 개발 도구, 테스트와 실시간 LADSPA DSP를 Swift로 구현합니다. Python과 uv는 필요하지 않습니다. 패키지는 Swift 6.3 이상을 요구하며, Embedded Swift DSP의 검증 도구체인은 Swift 6.3.3입니다. `Package.swift`는 [minacle/swift-tui](https://github.com/minacle/swift-tui) 0.12.0을 고정합니다. 다음 순서로 검증 후 설치할 수 있습니다. `make install`은 빌드까지 수행하며, 단위 테스트는 `make check`로 별도 실행합니다.

```
       make sync
           │ (swift package resolve로 Swift 의존성 준비)
           ▼
       make swift-build
           │ (inzone-profile 및 inzone-tools 빌드)
           ▼
       make fetch
           │ (공식 인스톨러 다운로드 & SHA-256 검증)
           ▼
       make assets
           │ (ILSpy 준비, MSI/CAB 정적 추출, HKI/BA 복호화, EQ 테이블 생성)
           ▼
       make build
           │ (Swift 도구·에셋 준비 및 Embedded Swift LADSPA 플러그인 컴파일)
           ▼
       make check (or make test)
           │ (Swift 단위·DSP·CLI·설치 테스트 실행)
           ▼
       make install (or make all)
             (Swift 실행 파일, DSP, 에셋, WirePlumber, udev 규칙 설치)
```

### 주요 Make 타깃 가이드

- **`make help`**: 사용 가능한 모든 타깃과 환경 변수 옵션을 출력합니다.
- **`make sync`**: `swift package resolve`를 실행하여 Swift 패키지 의존성을 준비합니다.
- **`make fetch`**: Swift 도구를 빌드한 뒤 `inzone-tools fetch --repository ROOT --download-only`를 실행합니다. Sony 공식 서버로부터 `INZONEHub_Setup_1.0.19.0.exe`를 다운로드하고 고정 크기와 SHA-256 해시를 검증합니다.
- **`make assets`**: `inzone-tools fetch --repository ROOT`로 전체 에셋 준비를 실행합니다. 7-Zip으로 MSI 및 CAB를 압축 해제하고, ILSpy로 필요한 어셈블리 클래스를 디컴파일한 뒤 기본 HRTF, 모델 보정 필터, 10밴드 EQ 계수 테이블을 `assets/` 디렉터리에 생성합니다. Sony 설치 파일은 실행하지 않습니다.
- **`make native-build`**: `Sources/InzoneDSP/*.swift`를 Embedded Swift로 컴파일하여 LADSPA 플러그인 `native/inzone_dsp.so`를 빌드합니다. `native/exports.map`은 공개 심볼을 `ladspa_descriptor`로 제한합니다.
- **`make swift-build`**: `swift build -c release --static-swift-stdlib`로 Swift CLI/TUI와 개발 도구를 빌드합니다. 기본 출력은 `.build/release/inzone-profile`과 `.build/release/inzone-tools`입니다. Swift 표준 라이브러리는 정적으로 링크하며, `glibc` 등 Linux 시스템 라이브러리 의존성은 남습니다.
- **`make swift-test`**: Swift DSP를 빌드한 뒤 vendor 에셋 추출 없이 Swift 단위 테스트를 실행합니다.
- **`make build`**: Swift 실행 파일과 에셋을 준비하고 Embedded Swift LADSPA 플러그인을 빌드합니다.
- **`make check`** (또는 `make test`): 빌드 후 Swift 단위·DSP·CLI·에셋 도구·설치 테스트를 실행합니다. 설치 테스트는 일반 사용자 단계와 격리된 시스템 staging 단계를 순서대로 실행합니다. 실제 시스템 서비스는 변경하지 않습니다.
- **`make`** (또는 `make install`): 일반 사용자 권한으로 자산과 Swift 빌드 결과를 준비한 뒤 `inzone-tools install-all`을 한 번 실행합니다. 이 조정 명령은 실행 중인 자신을 Linux memfd에 먼저 복사하고 봉인합니다. 이어 플러그인과 udev 규칙을 각각 한 번 읽어 별도의 memfd에 봉인하고, 정확한 스냅샷의 SHA-256을 계산한 뒤 사용자 설치를 실행합니다. 사용자 설치가 끝나면 절대 경로 `/usr/bin/sudo`로 세 `/proc/<coordinator-pid>/fd/<fd>`를 전달합니다. root 단계는 저장소나 홈을 탐색하지 않고 봉인된 두 데이터 스냅샷을 설치하므로, 암호 입력 중 저장소가 바뀌어도 실행 파일과 설치 바이트가 유지됩니다.

Make를 거치지 않는 live 설치도 `install-all`로 시작합니다. 다음 경로를 환경에 맞는 절대 경로로 바꿉니다.

```sh
REPOSITORY_ROOT=/absolute/path/to/inzone-linux
INSTALL_HOME=/home/username
TOOLS_BINARY="$REPOSITORY_ROOT/.build/release/inzone-tools"
PROFILE_BINARY="$REPOSITORY_ROOT/.build/release/inzone-profile"
"$TOOLS_BINARY" install-all --home "$INSTALL_HOME" --repository "$REPOSITORY_ROOT" \
  --binary "$PROFILE_BINARY"
```

명시적 다이제스트 명령과 비특권 `install-system`은 staging 패키징·테스트에 사용할 수 있습니다.

```sh
STAGING_ROOT=/absolute/path/to/staging
PLUGIN_SHA256="$("$TOOLS_BINARY" plugin-digest --repository "$REPOSITORY_ROOT")"
UDEV_RULE_SHA256="$("$TOOLS_BINARY" udev-rule-digest --repository "$REPOSITORY_ROOT")"
"$TOOLS_BINARY" install-system --repository "$REPOSITORY_ROOT" --staging-root "$STAGING_ROOT" \
  --expected-plugin-sha256 "$PLUGIN_SHA256" \
  --expected-udev-rule-sha256 "$UDEV_RULE_SHA256"
```

사용자 설치는 root 실행을 거부합니다. `INSTALL_HOME`은 명령을 실행하는 일반 사용자의 유효 UID가 소유한 기존 디렉터리여야 합니다. Makefile은 실제 경로를 전달하며, `FETCH_FLAGS`의 옵션은 두 에셋 준비 타깃에 적용합니다.

`Package.swift`와 `Package.resolved`는 Swift 빌드 의존성을 기록합니다. CLI/TUI, 에셋·설치·분석 도구 및 테스트는 Swift Package Manager로 빌드합니다. DSP는 `native/Makefile`이 `swiftc`를 직접 호출하여 별도 공유 라이브러리로 빌드하며, 실험 기능인 Embedded Swift를 활성화합니다. 전체 Swift 표준 라이브러리를 포함하지 않고 Linux 시스템 라이브러리와 연결합니다. 7-Zip (`7z` 또는 `7zz`)과 .NET 10의 ILSpy는 외부 도구로 사용합니다. `inzone-tools disassemble`은 기존 역어셈블리 파일의 주소 범위를 출력합니다. 명령 옵션은 `inzone-tools --help`로 확인합니다. 세부 절차는 [Swift 의존성 및 개발 도구](../README.md#swift-의존성-및-개발-도구)를 참고하세요.

`install-system --staging-root`는 비특권 패키징·테스트 단계이며 root 실행을 거부합니다. `--staging-root`가 없는 live 시스템 단계는 root 권한과 실행 중인 memfd의 필수 파일 봉인을 모두 요구합니다. live 단계는 `--repository`를 거부하고, 봉인된 플러그인·udev procfd만 같은 descriptor에서 검증하고 읽어 고정된 `/etc/udev/rules.d`와 `/usr/lib/ladspa`에 씁니다. 권한 경계의 명령은 작업 디렉터리 `/`와 상속한 표준 입출력 descriptor를 사용하며 임시 캡처 파일을 만들지 않습니다. 디스크의 빌드 경로를 직접 `sudo`로 실행하는 방식은 거부됩니다.

재설치에서는 기존 실행기를 백업하고 기본 프로파일 4개를 갱신합니다. `original.conf`, 활성 프로파일, 사용자 DSP 설정 및 자동 전환 규칙은 보존합니다. 이전 설치의 `~/.local/share/inzone-linux/python/`과 `venv/`는 복구용으로 남기며 새 Swift 설치에서는 생성하지 않습니다.

Swift 설치 테스트는 임시 사용자 홈과 staging 시스템 경로에 실행 파일, 설정 및 에셋을 설치하고 재설치 백업을 검증합니다. 시스템 단계가 홈을 변경하지 않고, 사용자 단계가 시스템 staging을 변경하지 않는지도 검사합니다. staging 설치는 udev 명령이나 서비스 시작을 수행하지 않습니다. 실제 root 권한의 live 시스템 설치는 검증하지 않았습니다. vendor 에셋 또는 실행 파일이 준비되지 않으면 관련 통합 테스트는 사유를 출력하고 건너뛰며, `make check`는 필요한 에셋과 빌드 결과를 먼저 준비합니다.

이전 C DSP의 디스크립터·합성 입력·출력 해시는 `Tests/InzoneCoreTests/Fixtures/dsp-golden.json`에 기록하며, `DSPGoldenTests.swift`가 Swift 플러그인을 회귀 검사합니다. 기존 구현의 실기기 측정값과 Swift 진단 결과의 적용 범위는 [분석 기록](../analysis/README.md)에서 구분합니다. 수치 비교 및 격리된 PipeWire 검사는 실제 헤드셋 검증을 대신하지 않습니다.

### 빌드 변수 및 오프라인 모드
- **오프라인 에셋 준비**: 인스톨러, 7-Zip 및 ILSpy를 미리 준비한 뒤 에셋 도구에 오프라인 옵션을 전달합니다.
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
`INSTALL_HOME`은 `make install`을 실행하는 일반 사용자의 UID가 소유해야 합니다. 다른 사용자의 홈을 대상으로 root 사용자 단계를 실행하는 방식은 지원하지 않습니다.
- **Swift 도구체인 및 빌드 옵션 지정**:
  ```sh
  make swift-build SWIFT=/absolute/path/to/swift SWIFT_FLAGS='--jobs 4'
  make native-build SWIFTC=/absolute/path/to/swiftc
  make install SWIFT_CONFIGURATION=debug
  ```
  `SWIFT_CONFIGURATION`의 기본값은 `release`입니다. `SWIFT_FLAGS`로 출력 디렉터리를 변경하면 `SWIFT_BINARY`와 `SWIFT_TOOLS_BINARY`도 실제 실행 파일 경로로 지정합니다. Make의 Swift 호출은 상속된 `CC`, `CXX`, `LD`, `AR`, `CFLAGS`, `CXXFLAGS`, `LDFLAGS`를 제거하여 Swift 도구체인의 컴파일러와 링커를 사용합니다. DSP는 `SWIFTC`와 `SWIFT_DSP_FLAGS`를 사용하며, 기본 최적화 옵션은 `-O -whole-module-optimization`입니다. `SWIFT_CONFIGURATION`과 `SWIFT_FLAGS`는 DSP의 직접 컴파일 옵션을 바꾸지 않습니다.

`FETCH_FLAGS=--offline`은 Swift Package Manager에는 적용되지 않습니다. 오프라인에서 Swift를 빌드하려면 의존성 checkout과 도구체인도 미리 준비해야 합니다.

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
