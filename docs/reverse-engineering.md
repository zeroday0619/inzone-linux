# INZONE Hub 1.0.19.0 및 H9 II 정적/동적 역분석 기술 분석서

이 문서는 Sony 공식 유틸리티인 **INZONE Hub 1.0.19.0**과 **INZONE H9 II (MDR-G900N / 모델 코드 YY2987)** 게이밍 헤드셋의 오디오 DSP 알고리즘 및 USB HID 제어 프로토콜을 분석하여 Linux (PipeWire / WirePlumber / LADSPA) 환경에 완벽히 재구현하기 위해 정리한 기술 보고서입니다.

---

## 1. 출처 및 자산 무결성 (Provenance)

- **공식 지원 페이지**: [Sony MDR-G600/G900N Software](https://support.sony.jp/electronics/support/headphones-gaming-headphones/mdr-g600/software/00384248)
- **공식 설치 파일 URL**: `https://info.update.sony.net/HP002/APID001WN00/contents/0011/INZONEHub_Setup_1.0.19.0.exe`

### 핵심 파일 SHA-256 및 크기 검증 표

| 파일명 | 크기 (Bytes) | SHA-256 해시 | 비고 |
|---|---|---|---|
| `INZONEHub_Setup_1.0.19.0.exe` | 144,916,520 | `8cb73e7524281905ec3e5f52679bb757557ee069571ec8c68ceff89d0edd2540` | 공식 설치 실행 파일 |
| 내부 내장 MSI (`Data1.msi`) | 136,132,608 | `4c4ad6278dbbf29f231c091697c2a73e279ad211acadc4ee5edb5be85f22e35b` | 오프셋 7,212,312 |
| `inzonehub.dll` | 38,122,120 | `77082a578f25b2ef6722e256fd7f53de0d69678a8c852a7aaf4e8f569c542a5f` | .NET Core 관리형 UI/로직 |
| `inzonevirtualizer.dll` | 2,453,600 | `d3fb1a9619335af6f8256029714ac57ba53d643fb4ce9f43d8d50e3a20179860` | x86-64 네이티브 오디오 DSP 엔진 |
| `shp_for_game_v2.0_512tap.hki` | 57,952 | `1a5ab53581ddb5320c2475fcb85cd6243c0b7472bbe339f14dc03c90bd8cf62d` | 기본 7.1 공간 음향 HRTF |
| `wh_g910n_standard.ba` | 192 | `9d9faae35a2db1ed16d277dbb73ea0e4e2bd96d85df5258593acf1dabf0797e2` | H9 II 하드웨어 보정 IIR 필터 |
| `downmix.hki` | 57,952 | `7f4bdc12b3885435a6305c9c138f3d66ee7da00874bdce7b5f0e12c21da9cdac` | 스테레오 다운믹스 필터 |
| `control.yaml` | 3,283 | `859c9cc66538ab11156783199c2dcd19687895e72e48e4693799389c9aab4621` | 몰입 음장 계수 정의 |

### 인스톨러 및 페이로드 추출 메커니즘
InstallShield 실행 파일은 오프셋 `7,212,312` 위치에 길이 `136,132,608` 바이트의 MSI 데이터베이스를 포함하고 있습니다. 이 MSI 내의 `Data1.cab` 압축을 해제하면 런타임에 필요한 파일들을 얻을 수 있습니다.

MSI File 테이블(568개 행, 행당 18바이트, 열 기준 정렬) 분석 결과:
- `shp_for_game_v2.0_512tap.hki`는 파일 시스템 설치 시 `SHP_FO~1.HKI|standard_hrtf.hki`로 매핑됩니다.
- 관리형 어셈블리의 `ApoFileCommunication.SetVirtualizer`는 비개인화 서라운드가 활성화되었을 때 `standard_hrtf.hki`와 모델 보정용 `wh_g910n_standard.ba`를 쌍으로 선택합니다.
- 서라운드가 꺼진 일반 상태에서는 `downmix.hki`가 선택되고 모델 BA 필터는 적용되지 않습니다.
- 공간 ALC(Automatic Level Control) 설정은 가상화 필터 적용 이후의 독립 파이프라인 스테이지로 처리됩니다.

> 본 프로젝트에서는 Windows 바이너리나 인스톨러를 직접 실행하지 않고, Python 스크립트(`tools/fetch_assets.py` 또는 `make assets`)를 통해 정적 오프셋 검증 및 무결성 검사 후 필요한 리소스만을 추출하여 사용합니다.

---

## 2. 네이티브 엔진 분석 (INZONEVirtualizer.dll)

`inzonevirtualizer.dll`의 기본 로드 가상 주소(Image Base)는 `0x180000000`입니다. 주요 네이티브 함수 및 데이터 테이블의 상대 가상 주소(RVA)는 다음과 같습니다.

### 주요 함수 및 데이터 테이블 RVA 매핑

| 기능 및 서브루틴 | RVA | 설명 |
|---|---|---|
| HKI 키 유도 (Key Derivation) | `0x9480` | 셀렉터 길이 테이블: `0x1f6ab0`, 포인터 테이블: `0x1f6ab8` |
| BA 키 유도 (Key Derivation) | `0x10c80` | 20-워드 상수 테이블: `0x1f7d80` |
| AES-128-CBC 복호화 래퍼 | `0x11520` | 표준 AES-CBC 복호화 및 PKCS#7 패딩 처리 |
| MD5 평문 해시 비교 | `0x117f0` | 복호화 결과의 무결성 검증 루틴 |
| HKI 레코드 파싱 및 FFT 준비 | `0x79c0` | `0x7c50`에서 16바이트 메타데이터 건너뛰고 512 float 복사 |
| 공간 음향 엔진 생성 / 초기화 | `0x1840` / `0x2610` | 내부 컨볼루션 엔진 메모리 할당 및 파라미터 초기화 |
| 공간 음향 리셋 / 샘플 처리 | `0x2b80` / `0x2c90` | 컨볼루션 링버퍼 초기화 및 실시간 필터링 |
| 공간 음향 셧다운 / 해제 | `0x29f0` / `0x2420` | 리소스 정리 및 인스턴스 소멸 |
| 내부 공간 ALC 초기화 / 설정 | `0xd5e0` / `0xd610` | 8-프레임 블록 크기 및 룩어헤드 지연 버퍼 설정 |
| 내부 공간 ALC 8-프레임 처리 | `0xd8b0` | 로그 근사식 기반 동적 게인 조절 |
| 외부 ALC 생성 / 설정 / 처리 | `0x11a90` / `0x11df0` / `0x11be0` | 10ms 피크 감쇠 기반 출력 자동 레벨 제어 |
| Peak DRC 생성 / 설정 / 처리 | `0x18880` / `0x18da0` / `0x18af0` | 상향 압축 및 확장 구간을 갖는 동적 범위 제어 |
| Model BA 바이쿼드 커널 | `0x11210` | 7단 직렬 IIR Biquad (내부 double 정밀도 상태 연산) |
| User EQ float 바이쿼드 커널 | `0x155c0` | 10밴드 파라메트릭 EQ (float32 정밀도 연산) |
| Equalizer::SetParameters | `0x19ae0` | 파라미터와 계수 중 계수(`coefficients`) 우선 적용 |
| HRTF 크기 정규화 루틴 | `0x8b10` / `0x8fd0` | 복소 FFT 빈(bin) 최댓값 정규화 (상한: 18) |

### 암호화 키 유도 알고리즘 (Key Derivation)
소니의 암호화 키는 바이너리에 평문으로 하드코딩되어 있지 않으며, 바이너리 내부의 난독화 테이블과 헤더 정보를 결합하여 런타임에 동적으로 유도합니다.

1. **테이블 조회**: 파일 헤더의 `uint32` 마커를 읽어 DLL 데이터 섹션의 셀렉터 테이블에서 오프셋을 찾습니다.
2. **XOR 연산**: 테이블 길이로 나눈 나머지 연산(`modulo table length`)을 통해 `+7`, `+11` 위치의 테이블 엔트리와 마커를 XOR합니다.
3. **상태 점화식 (Recurrence)**: 16단계 바이트/상태 순환 루프를 실행하여 16바이트(128비트) 키 블록을 생성합니다.
4. **엔디안 변환**: AES 연산에 투입하기 전 매 4바이트 그룹을 역순(Endian swap)으로 정렬합니다.
5. **초기화 벡터 (IV) 및 복호화**: 파일 헤더의 16바이트 체크섬 필드를 AES-128-CBC의 IV(Initialization Vector)로 직접 사용합니다. 복호화 후 PKCS#7 패딩을 검증하고 평문의 MD5 해시를 헤더의 체크섬과 비교합니다.

---

## 3. 필터 파일 포맷 구조 (HKI 및 BA)

### 3.1. HKI (Head-Related Impulse Response Container)

HKI 파일은 머리전달함수(HRTF) FIR 필터 계수를 담고 있는 독점 바이너리 포맷입니다.

| 오프셋 (Byte) | 데이터 타입 | 설명 |
|---|---|---|
| `0` | `char[4]` | 매직 넘버 (`hki2`) |
| `4` | `uint32_le` | 키 테이블 마커 (Key derivation selector) |
| `8` | `uint8[16]` | 평문 MD5 해시값 겸 AES-128-CBC IV |
| `24–55` | - | 타임스탬프 및 내부 빌드 메타데이터 |
| `56` | `uint32_le` | 샘플레이트 (`48000` Hz) |
| `60` | `uint32_le` | 채널/귀 수 (`2`: Left, Right) |
| `76` | `uint16_le` | 암호화 모드 (`5`: 번들 기본 파일, `7`: 사용자 개인화 파일) |
| `78` | `uint16_le` | 셀렉터 모드 (`1`) |
| `80` | `uint32_le` | 개인화 Cipher 7용 의사난수 초기 시드 (Seed offset) |
| `88` | `uint32_le` | 탭(Tap) 수 (`512`) |
| `92` | `uint32_le` | 방향 수 (`14`) |
| `144` | `uint8[]` | AES-128-CBC 암호화된 FIR 계수 페이로드 |

- **평문 크기**: 57,792 바이트 = 14방향 × 2귀 × (16바이트 메타데이터 + 512탭 × 4바이트 float32).
- **레코드 구조**: 각 레코드는 16바이트 헤더(`azimuth`, `polar angle`, `kind`, `ear`: 각 `uint32`)와 뒤따르는 512개의 리틀엔디안 `float32` FIR 탭 계수로 구성됩니다.
- **필터 종류 (`kind`)**: 기본 공간 필터(`shp_for_game`)는 `kind = 2`, 스테레오 다운믹스는 `kind = 1`을 가집니다.

### 3.2. BA (Biquad Array Correction Filter)

BA 파일은 헤드셋 하드웨어의 음향 특성을 평탄화하고 공간감을 최적화하기 위한 다단 IIR 바이쿼드(Biquad) 보정 필터입니다.

- **헤더 크기**: 48바이트
  - `0`: 매직 넘버 (`ba00`)
  - `4`: 키 테이블 마커 (`uint32`)
  - `8`: 평문 MD5 해시 겸 AES IV (`16바이트`)
  - `24`: 샘플레이트 (`48000`)
  - `28`: 바이쿼드 섹션 수 (`7`)
  - `32`: 플래그 값 (`1`)
- **암호화 페이로드**: 오프셋 `48`부터 시작. 복호화 평문 크기는 정확히 140바이트입니다.
- **계수 구조**: 7개 스테이지 × 5개의 `float32` 계수(`b0, b1, b2, a1, a2`).
- **안정성 분석**: 전달함수 $H(z) = \frac{b_0 + b_1 z^{-1} + b_2 z^{-2}}{1 + a_1 z^{-1} + a_2 z^{-2}}$의 모든 극점(Poles)이 단위 원(Unit circle) 내부에 위치함을 검증하여 무조건적 안정(Unconditionally Stable) 상태임을 확인했습니다.

---

## 4. 오디오 채널 매핑 및 PipeWire 통합

### 4.1. 7.1ch 서라운드 채널과 HKI 각도 매핑

Linux PipeWire 7.1 오디오 스트림은 아래 표와 같이 HKI 파일의 방위각(Azimuth) 및 극각(Polar)에 1:1로 매핑됩니다.

| PipeWire 채널 | HKI Azimuth (도) | HKI Polar (도) | 네이티브 슬롯 번호 | 음향적 위치 |
|---|---|---|---|---|
| **FL** (Front Left) | 330 | 90 | 1 | 전방 좌측 30° |
| **FR** (Front Right) | 30 | 90 | 2 | 전방 우측 30° |
| **FC** (Front Center) | 0 | 90 | 0 | 전방 중앙 |
| **LFE** (Low Frequency Effect) | 0 | 0 | 13 | 서브우퍼 (무지향성 저역) |
| **RL** (Rear Left) | 210 | 90 | 5 | 후방 좌측 150° |
| **RR** (Rear Right) | 150 | 90 | 6 | 후방 우측 150° |
| **SL** (Side Left) | 250 | 90 | 3 | 측면 좌측 110° |
| **SR** (Side Right) | 110 | 90 | 4 | 측면 우측 110° |

- **LFE 처리**: HKI 내 유일하게 좌우 대칭 무지향성 특성을 지닌 레코드(0/0)를 사용합니다.
- **슬롯 배열**: 네이티브 C 엔진(`native/ladspa.c`)의 14개 입력 배열 중 7.1ch 슬롯은 `[1, 2, 0, 13, 5, 6, 3, 4]`로 초기화됩니다.

### 4.2. USB 하드웨어 엔드포인트 및 ALSA 구성
INZONE H9 II USB 동글(VID `054c`, PID `0fa8`)은 2개의 독립된 재생 PCM 디바이스와 1개의 녹음 PCM 디바이스를 제공합니다.

- **PCM 0 (인터페이스 1)**: Chat 스트림 (음성 통화용, 16-bit 48kHz 스테레오)
- **PCM 1 (인터페이스 4)**: Game 스트림 (게임 및 메인 오디오용, 16-bit 48kHz 스테레오)
- **기존 문제 해결**: 기본 Linux ALSA는 간혹 PCM 0을 메인 싱크로 잡아 음장 효과가 엉뚱한 출력에 걸리는 현상이 발생합니다. 본 프로젝트에서는 `52-inzone-game-chat.conf`와 `usb-gaming-headset.conf` 매핑을 통해 Game(`PCM 1`)과 Chat(`PCM 0`)을 분리 지정하여 완전히 격리합니다.

---

## 5. DSP 신호 처리 파이프라인 복원

실시간 오디오 처리는 네이티브 C 공유 라이브러리(`native/inzone_dsp.so`)와 PipeWire filter-chain 모듈을 통해 수행됩니다.

```
[7.1ch Audio Stream]
        │
        ▼
┌─────────────────────────────────────────────────────────────┐
│ 1. Sony Spatial Audio Convolution (FIR 512-tap)             │
│    - 8채널 가상 음장 렌더링 (각도별 좌/우 전달함수 합성)      │
└─────────────────────────────────────────────────────────────┘
        │
        ▼
┌─────────────────────────────────────────────────────────────┐
│ 2. Model BA Equalization (7-stage IIR Biquad)               │
│    - H9 II 하드웨어 음향 특성 보정 (Double 정밀도 내부 연산) │
└─────────────────────────────────────────────────────────────┘
        │
        ▼
┌─────────────────────────────────────────────────────────────┐
│ 3. Internal Spatial ALC (Lookahead Dynamic Limiter)         │
│    - 32-샘플 룩어헤드 지연 (8-frame 블록 단위 연산)          │
│    - 공간 처리 후 피크 왜곡 방지 및 레벨 유지 (+1 dB 게인)  │
└─────────────────────────────────────────────────────────────┘
        │
        ▼
┌─────────────────────────────────────────────────────────────┐
│ 4. Optional Post-Processing Stages                          │
│    - Amp1 Attenuation (-18 dB: 0.1258925497531891)          │
│    - Sony ModeEqualizer (몰입 음장 Biquad)                  │
│    - Sony 10-band User EQ (-12 ~ +12 dB 사전 계산 테이블)    │
│    - Output ALC (Threshold -18dB, Ratio 1000, 1ms/1s)       │
│    - Amp2 Recovery (+18 dB: 7.943282127380371)              │
│    - Peak Dynamic Range Control (DRC Low / High)            │
└─────────────────────────────────────────────────────────────┘
        │
        ▼
[Hardware ALSA Endpoint: Game PCM 1 (16-bit 48kHz Stereo)]
```

### 5.1. 내부 공간 ALC (Internal Spatial ALC)
- **블록 크기**: 8프레임 고정 블록 단위로 좌우 채널 링크(Stereo-linked) 처리.
- **룩어헤드 버퍼링**: 외곽 8프레임 버퍼 + 내부 24프레임 선독 버퍼 = **총 32샘플(48kHz 기준 약 0.667ms)의 미세 지연**.
- **파라미터**:
  - 서라운드 모드: `alc.cfg` 기준 `+1.0 dB` 정규화 게인.
  - 다운믹스 모드: `alc_for_downmix.cfg` 기준 `0.0 dB` 게인.
  - 엔벨로프 추종: Attack = `0x67d2ec9b / 2^31`, Release = `0x7ac6b85a / 2^31`.
  - 수학적 로그 근사 및 하드웨어 게인 클램프 로직 완전 일치(`native/spatial_alc.c`).

### 5.2. 10밴드 하드웨어 EQ 및 ModeEqualizer
- **사전 계산 테이블 구조**: 일반적인 고정 Q 공식 대신, 소니가 튜닝한 10개 중심 주파수(31.5, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000 Hz)별 -12 dB ~ +12 dB(1 dB 간격, 25행)의 사전 계산된 Biquad 계수 테이블을 그대로 추출하여 사용합니다(`tools/export_eq_tables.py`).
- **ModeEqualizer 우선순위**: `Control.yaml`의 `mode_equalizer.coeffs`가 활성화될 때, 네이티브 함수 `Equalizer::SetParameters` (RVA `0x19ae0`)는 단순 파라미터 재계산값보다 YAML 계수 데이터를 최우선 적용합니다.
- **수치 정밀도(ULP) 문제**:
  - $\text{Amp1} = 10^{-18/20} \approx 0.1258925497531891$
  - $\text{Amp2} = 10^{+18/20} \approx 7.943282127380371$
  - `double`로 계산 후 `float`로 캐스팅할 경우 단정밀도 부동소수점 최하위 비트(1 ULP) 오차가 발생하므로, 소니 원본의 `powf(10.0f, -18.0f / 20.0f)` 수치 값을 정확히 보존합니다.

---

## 6. Linux PipeWire 1.6.8 연동 특이점 및 제약 해결

PipeWire의 `filter-chain` 및 `audioconvert` 모듈 연동 과정에서 발견된 두 가지 핵심 커널/라이브러리 제약 사항과 해결책입니다.

### 6.1. filter-graph의 내림차순 실행 버그 (Descending Execution Order)
PipeWire 1.6.8의 `audioconvert` 모듈 소스 코드 분석 결과:
```c
/* spa/plugins/audioconvert/audioconvert.c: insert_graph() */
// 그래프 인덱스 N을 기준으로 내림차순(역순)으로 정렬하여 실행
```
- **문제**: `audioconvert.filter-graph.1`, `.2`, `.3` 순으로 등록하면 실제 오디오 처리는 `.3` → `.2` → `.1` 순으로 실행되어 EQ와 DRC 순서가 뒤집히는 문제가 발생했습니다.
- **해결책**: WirePlumber 설정 빌더(`src/build_graph.py`)에서 의도한 신호 처리 순서의 역순으로 그래프 인덱스를 정렬 배치하여 실제 파이프라인이 정방향(`Amp1` → `ModeEQ` → `EQ` → `ALC` → `Amp2` → `DRC`)으로 처리되도록 보정했습니다.

### 6.2. 4096바이트 문자열 버퍼 한계
- **문제**: PipeWire의 `parse_prop_params()` 함수는 인라인 노드 속성 문자열을 파싱할 때 4096바이트 고정 버퍼를 사용합니다. 10단 Biquad 계수와 DRC, ALC 설정이 하나의 거대한 JSON 문자열로 전달되면 버퍼 오버플로로 인해 파싱이 실패했습니다.
- **해결책**: 신호 그래프를 단위 기능별(Spatial Virtualizer, ModeEQ, Output Dynamics 등)로 4096바이트 미만의 독립 하위 그래프로 분할하여 안정적으로 로드합니다.

---

## 7. USB HID 하드웨어 제어 프로토콜

H9 II 헤드셋의 ANC, 주변 소리 크기, 배터리 잔량 조회 등은 USB 엔드포인트의 Vendor-Specific HID 리포트를 통해 이루어집니다.

### 7.1. 패킷 레이아웃 및 제어 구조
- **USB 디바이스**: `054c:0fa8`, 인터페이스 5, Usage Page `0xff04`.
- **리포트 형식**: 고정 64바이트 길이, Report ID `2`.
- **Command 패킷 구조 (PC → 동글/헤드셋)**:

```
[0x02] [Length] [0x01] [0x00, 0xFC] [ParamLen] [0x96, 0xC3] [Address] [EventID] [Type] [TxID_LE] [Payload...] [Checksum] [0x00...]
```

1. `Report ID`: 고정 `0x02`
2. `Length`: 패킷 유효 길이
3. `Packet Type`: 고정 `0x01`
4. `Opcode`: `0xFC00` (리틀엔디안: `0x00, 0xFC`)
5. `ParamLen`: `8 + payload_length`
6. `Sony Key`: `0xC396` (리틀엔디안: `0x96, 0xC3`)
7. `Address`: `(Destination << 4) | Source`
   - `PC` = 1, `Dongle TX` = 2, `Headset RX` = 4
   - 헤드셋 대상 명령: `(4 << 4) | 1 = 0x41`
   - 동글 대상 명령: `(2 << 4) | 1 = 0x21`
8. `Event ID`: 제어 대상 기능 ID (1~143)
9. `Event Type`: `0x01` (GET), `0x02` (SET)
10. `Transaction ID`: 16비트 순차 증가 번호
11. `Payload`: 설정 파라미터 바이트
12. `Checksum`: `Sony Key`부터 `Payload` 끝까지의 바이트 합 modulo 256

- **Response 패킷 구조 (헤드셋 → PC)**:
  - 응답 헤더: `0x04, 0xFF`, 길이, 더미 `0x00`
  - 이벤트 종류: `0x10` (GET 성공 응답), `0x20` (SET 성공 통지), `0xA0` (비동기 상태 통지)

### 7.2. 주요 하드웨어 제어 이벤트 ID

| 필드 식별자 | Event ID | 인덱스 | 값 범위 | 기능 설명 |
|---|---|---|---|---|
| `anc` | 65 (`ambient`) | 0 | 0, 1, 2 | 0: 끔, 1: 노이즈 캔슬링(NC), 2: 주변 소리 |
| `ambient_level` | 65 (`ambient`) | 1 | 1 ~ 20 | 주변 소리 크기 조절 (20단계) |
| `voice_focus` | 65 (`ambient`) | 3 | 0, 1 | 0: 음성 집중 끔, 1: 음성 집중 켬 |
| `game_chat` | 34 (`balance`) | 0 | 0 ~ 100 | 게임/채팅 음량 균형 (50: 중앙) |
| `sidetone` | 35 (`sidetone`) | 0 | 0 ~ 10 | 내 목소리 듣기 (사이드톤 11단계) |
| `toggle_off` | 66 (`nc_toggle`) | 0 | 0, 1 | 물리 NC 버튼 순환: '끔' 포함 여부 |
| `toggle_nc` | 66 (`nc_toggle`) | 1 | 0, 1 | 물리 NC 버튼 순환: 'NC' 포함 여부 |
| `toggle_ambient` | 66 (`nc_toggle`) | 2 | 0, 1 | 물리 NC 버튼 순환: '주변 소리' 포함 여부 |
| `nc_startup` | 67 (`nc_startup`) | 0 | 0, 1, 2, 3 | 전원 켤 때 NC 모드: 0: 끔, 1: NC, 2: 주변소리, 3: 이전상태 |
| `bt_startup` | 99 (`bt_startup`) | 0 | 0, 1, 2 | 전원 켤 때 Bluetooth: 0: 끔, 1: 켬, 2: 이전상태 |
| `auto_power` | 129 (`auto_power`) | 0 | 0, 5, 15, 30, 60, 180 | 자동 전원 끄기 타이머 (분, 0: 비활성) |
| `language` | 131 (`language`) | 0 | 0, 1, 2 | 음성 안내 언어 (0: 영어, 1: 일본어, 2: 중국어) |
| `guidance` | 132 (`guidance`) | 0 | 0, 1 | 알림음 및 음성 안내 켬/끔 |
| `battery` | 4 (`battery`) | - | 0 ~ 100 | 배터리 잔량 퍼센트 (조회 전용) |
| `firmware` | 3 (`firmware`) | - | 문자열 | 헤드셋 및 동글 펌웨어 버전 (조회 전용) |

---

## 8. 개인화(Personalization) Cipher 7 알고리즘 역공학

스마트폰 모바일 앱에서 귀 사진을 촬영하여 생성된 개인화 프로파일(`personalized_hrtf.hki`)은 일반 암호화(Cipher 5)와 다른 독자적인 **Cipher 7** 스트림 암호화가 적용되어 있습니다.

### 8.1. Cipher 7 복호화 루프
1. AES-128-CBC 1차 복호화는 Cipher 5와 동일한 키 유도 및 IV로 수행합니다.
2. 복호화된 중간 데이터 블록에 대해 워드 단위 XOR 마스킹을 수행합니다.
3. **의사난수 생성기(PRNG) 점화식**:
   - 초기 시드: HKI 헤더 오프셋 `80`의 `uint32` 값 + `0x52276af7`
   - 매 워드(4바이트) 복호화 시 마스크: `mask = seed + (seed >> 24)`
   - 시드 업데이트:
     $$\text{seed}_{n+1} = (\text{seed}_n \times 0x80849 + 0x2a3b5) \pmod{2^{32}}$$
4. 전체 복호화된 바이트 합 modulo 256이 헤더의 체크섬 바이트와 일치해야 정상적인 개인화 프로파일로 승인됩니다.

### 8.2. 개인화 필터 정규화 및 무결성 검증
- **FFT 빈 정규화**: 14개 전 방향 및 양쪽 귀에 대해 1024-포인트 복소 FFT를 수행하고, 최대 크기가 `18.0`을 초과하지 않도록 자동 스케일링합니다.
- **안전 검증**: 잘못되었거나 손상된 HKI/BA 파일이 주입될 경우 기존의 정상 프로파일을 덮어쓰지 않고 즉시 거부(Rejection)하는 무결성 검증 로직이 구현되어 있습니다.

---

## 9. 프리셋과 ModeEqualizer

`SoundQualitySettingsViewModel.EQPresetItem`에서 Flat, FPS1/2/3, Immersion Flat(RPG/Adventure), Bass Boost, Music/Video의 10밴드 값을 추출했습니다. `EQAxis`는 Standard/Immersive 두 종류이며 별도 연속 보간 모드가 아닙니다.

`Control.yaml`의 `mode_equalizer.coeffs`가 몰입 음장의 실제 계수입니다. UI의 `SetEqEnable`은 coefficients와 parameters 양쪽의 첫 10개 enable을 모두 켜고, 네이티브 `Equalizer::SetParameters`(RVA 0x19ae0)는 coefficients를 우선 선택합니다. 따라서 기본 생성자에 있는 다른 주파수·Q·gain 값이나 YAML의 params에서 다시 계산한 값을 사용하면 UI 동작과 달라집니다. 효과적인 10단 계수와 Sony 프리셋은 `tools/export_presets.py`로 추출하고 `assets/sony-presets.json`에 원본 SHA-256과 함께 저장했습니다.

PipeWire inline 필터의 신호 순서는 기존 Linux EQ(선택) → Amp1 → ModeEQ → EQ → ALC → Amp2 → DRC입니다. Sony 프리셋은 기존 Linux EQ를 끕니다. Amp1은 원본 `powf(10, float(-18 / 20))`에서 얻은 0.1258925497531891, Amp2는 7.943282127380371을 사용합니다. double로 계산한 뒤 float로 변환하면 Amp1이 1 ULP 달라집니다.

Windows `SoundProfileCollection`은 최대 256개의 `SoundProfile` 배열을 JSON으로 읽고 씁니다. enum은 `CustomEnumConverter`로 이름 문자열을 쓰며 숫자·숫자 문자열도 읽습니다. 별도 CLI 변환은 이 필드 구조를 사용하고, 표현할 수 없는 Linux 전용 옵션을 조용히 삭제하지 않습니다. Linux에서 합성 파일·모든 기본 프리셋의 JSON 왕복 검사를 수행합니다.

---

## 10. 결론 및 클린룸 재구현 요약

본 프로젝트의 모든 런타임 구성 요소는 Sony의 라이선스 계약과 리눅스 시스템 보안 가이드라인을 준수하도록 설계되었습니다.

1. **바이너리 비배포 원칙**: Sony의 저작물인 EXE, DLL, HKI, BA 파일은 일체 저장소에 포함되지 않습니다.
2. **클린룸 재작성 (Clean-room Implementation)**: C 소스 코드(`native/`) 및 Python 모듈(`src/`)은 역분석된 동작 스펙에 기반하여 완전히 새로 작성된 순수 오픈소스 코드입니다.
3. **루트 권한 최소화**: 오디오 신호 처리는 일반 사용자 세션(PipeWire)에서 동작하며, udev 장치 규칙 등록에만 관리자 권한(`sudo`)이 1회 사용됩니다.
