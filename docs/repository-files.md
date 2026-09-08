# 공개 저장소 파일 구성

분석 보고서는 공개하고, 원본·추출 파일은 각 사용자의 환경에서 준비합니다.

| 공개 | 로컬에만 보관 |
|---|---|
| `src/`, `native/`의 구현 소스, `configs/` | `downloads/`의 Sony 설치 EXE·MSI·CAB |
| `tools/`의 Python 스크립트 | `tools/ilspycmd`, `tools/.store/`의 내려받은 ILSpy |
| `tests/`의 테스트 코드 | `analysis/payload/`, `analysis/decompiled/`, 원시 덤프 |
| `docs/`의 분석 문서 | `assets/`의 추출 EQ·프리셋·HRTF·보정 계수 |
| `analysis/README.md`에 열거한 요약 보고서 | 원시 오디오·장치·터미널 기록, 백업, 빌드 결과 |
| `evidence/installer.json`의 URL·버전·해시 | `evidence/`의 USB/HID 캡처 |

`.gitignore`는 `analysis/` 전체를 기본 제외한 뒤 검토한 보고서만 파일명으로 허용합니다. 추출 파일을 다른 디렉터리로 잘못 복사한 경우에도 일반적인 바이너리·디컴파일·덤프 확장자는 제외합니다.

## 로컬 자산 준비

Python 3.10 이상과 `cryptography`, 7-Zip, .NET 10 SDK를 준비한 뒤 실행합니다.

```sh
python3 tools/fetch_assets.py
```

1. ILSpy 11.0.0.9375가 없으면 NuGet 공식 피드에서 프로젝트의 `tools/`에 설치합니다.
2. Sony 공식 URL에서 INZONE Hub 1.0.19.0을 다운로드하고 고정된 크기·SHA-256을 검증합니다.
3. 고정 오프셋의 MSI와 CAB를 추출하고 필요한 파일의 SHA-256을 검증합니다.
4. EQ·프리셋에 필요한 두 타입만 디컴파일하고 HRTF·보정 필터·계수 JSON을 생성합니다.
5. 검증과 생성이 끝난 결과를 `analysis/payload/`, `analysis/decompiled/`, `assets/`에 반영합니다.

설치 EXE와 DLL은 Windows 프로그램으로 실행하지 않습니다. 소스·보고서와 현재 오디오 설정은 자산 준비 과정에서 변경하지 않습니다. 테스트의 보정 입력은 설치 파일의 기본 BA이며, 개인의 귀 사진이나 계정 데이터를 내려받지 않습니다.

`--download-only`는 Python 표준 라이브러리만으로 설치 파일을 다운로드·검증합니다. `--offline`은 설치 파일과 ILSpy가 이미 있을 때만 실행하며 네트워크 다운로드를 하지 않습니다. 다른 위치에 ILSpy를 설치했다면 `--ilspycmd /path/to/ilspycmd`로 지정할 수 있습니다. 캐시 파일의 해시가 맞지 않으면 덮어쓰지 않고 중단하므로, 잘못된 파일을 확인한 뒤 제거하거나 정상 파일을 `--installer`로 지정하세요.

제외 파일을 준비한 뒤 `make -C native`와 단위 테스트를 실행할 수 있습니다. 장치 제어·음향 설정 설치는 README의 별도 설치 단계에서 진행합니다.

## 커밋 전 확인

```sh
git status --short --ignored
git ls-files
```

`.gitignore`는 이미 추적된 파일을 자동으로 제거하지 않습니다. 기존 저장소에 적용한다면 `git ls-files`에서 제외 대상이 추적 중인지 확인하고 해당 경로만 `git rm --cached`로 추적 해제해야 합니다. `git add -f`는 제외 규칙을 무시하므로 원본·추출 파일에 사용하지 마세요.
