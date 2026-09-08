# Linux 구현 현황

자동 음량 제어·DRC·마이크 AGC·EQ·공간 음향·로컬 개인화 파일 가져오기·프로파일 TUI를 구현했습니다. 검사 범위는 Linux의 DSP 동작, PipeWire 연결, 파일 가져오기, 장치 제어입니다.

| 항목 | 근거 |
|---|---|
| DSP·LADSPA | `tests/test_dsp.py` |
| PipeWire 공간 처리·효과 결합 | `tests/pipewire_impulse.py`, `tests/pipewire_sfx.py` |
| 개인화 형식·정규화·가져오기 | `tests/test_personalization.py`, `tests/test_filters.py` |
| 프로파일·TUI·자동 전환 | `tests/live_profiles.py`, `tests/tui_smoke.py`, `tests/live_automation.py` |
| 장치 통신·설정 | `tests/test_device.py`, `analysis/device-write-verification.json` |

개인화는 본인 HKI/BA 파일을 로컬에서 가져온 뒤 사용할 수 있습니다. 현재 선택한 기본 프로파일은 그대로 유지합니다. 전체 기능과 사용 조건은 [기능 추적](features.md)에 있습니다.
