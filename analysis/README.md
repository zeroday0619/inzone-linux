# 분석 보고서와 로컬 자료

공개 저장소에는 다음 요약 보고서만 포함합니다.

- `impulse-results.json`: 7.1 채널·음량 제한·무음 복귀 검사
- `pipewire-sfx-results.json`: PipeWire와 Linux DSP 계산 결과 비교
- `live-profile-results.json`, `profile-switch-results.json`: 프로파일 전환 검사
- `live-automation-results.json`: 자동 전환·복원 검사
- `device-write-verification.json`: 장치 설정 변경 후 원래 값 복원 검사
- `install-results.json`: 설치·재설치·백업 검사
- `tui-results.json`: TUI 화면·취소·종료 검사

기술 분석 설명은 [`docs/reverse-engineering.md`](../docs/reverse-engineering.md)에 있습니다.

`payload/`, `decompiled/`, `msi/`, 디스어셈블·문자열 덤프, 원시 오디오·장치·터미널 기록은 로컬 자료이며 Git에서 제외됩니다. `python3 tools/fetch_assets.py`는 실행에 필요한 원본 파일·일부 디컴파일 결과·`assets/`를 재생성합니다. 과거의 원시 진단 기록을 다운로드하거나 재생성하지는 않습니다.

새 분석 보고서를 공개하려면 `.gitignore`에 해당 파일을 명시적으로 추가하세요. `analysis/` 아래에 새로 생기는 파일은 기본적으로 제외됩니다.
