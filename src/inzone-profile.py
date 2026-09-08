#!/usr/bin/python3
"""Switch persistent, device-specific INZONE H9 II listening profiles."""
import curses
import fcntl
import locale
import unicodedata
import json
import os
from pathlib import Path
import subprocess
import sys
import time

BASE = Path.home()
sys.path.insert(0,str(BASE/'.local/share/inzone-linux/python'))
import inzone_settings as settings
from personalization import import_files
DATA = BASE / ".config/inzone-h9-ii"
ACTIVE = BASE / ".config/wireplumber/wireplumber.conf.d/51-inzone-h9-ii.conf"
LABELS = {"fps": "FPS · 저음 감소 / 발소리 대역 강조", "music": "음악 · 원음 / 안정성 우선", "voice": "통화 · 말소리 강조 / 마이크 저역 정리", "balanced": "기본 · EQ 없음 / 균형 설정", "surround": "서라운드 · Sony 기본 HRTF / 실험 구현", "restore": "변경 전 음색·지연 설정 복원"}

def run(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT, timeout=15)

def status():
    first = ACTIVE.read_text().splitlines()[0]
    return first.removeprefix("# INZONE profile: ") if first.startswith("# INZONE profile: ") else "original"

def write_active(text):
    tmp = ACTIVE.with_suffix(".conf.tmp")
    tmp.write_text(text)
    tmp.replace(ACTIVE)

def nodes():
    return [n for n in json.loads(run("pw-dump")) if n.get("type") == "PipeWire:Interface:Node" and "Sony_INZONE_H9_II" in n.get("info", {}).get("props", {}).get("node.name", "")]

GAME = "alsa_output.usb-Sony_INZONE_H9_II-00.stereo-game"
CHAT = "alsa_output.usb-Sony_INZONE_H9_II-00.stereo-chat"
SURROUND = "inzone.sony-surround"
CARD = "alsa_card.usb-Sony_INZONE_H9_II-00"
CARD_PROFILE = "output:stereo-game+output:stereo-chat+input:mono-chat"


def all_nodes():
    return [n for n in json.loads(run("pw-dump")) if n.get("type") == "PipeWire:Interface:Node"]


def choose_output(name):
    target = SURROUND if name == "surround" else (CHAT if name == "voice" else GAME)
    run("pactl", "set-default-sink", target)
    return target


def restart_wireplumber():
    # Rapid deliberate switches can reach systemd's restart burst limit.
    try:
        run("systemctl", "--user", "restart", "wireplumber.service")
    except subprocess.CalledProcessError:
        if run("systemctl", "--user", "show", "wireplumber.service", "-p", "Result", "--value").strip() != "start-limit-hit":
            raise
        run("systemctl", "--user", "reset-failed", "wireplumber.service")
        run("systemctl", "--user", "restart", "wireplumber.service")


def apply(name, quiet=False):
    candidate = DATA / ("original.conf" if name == "restore" else name + ".conf")
    previous = ACTIVE.read_text()
    was_connected = bool(nodes())
    previous_default = run("pactl", "get-default-sink").strip()
    write_active(settings.render(BASE,name,candidate.read_text()))
    try:
        restart_wireplumber()
        run("systemctl", "--user", "is-active", "wireplumber.service")
        if was_connected:
            expected = {"fps":128,"music":512,"voice":256,"balanced":256,"restore":256,"surround":256}[name]
            for _ in range(40):
                snapshot = all_nodes()
                outputs = [n for n in snapshot if n["info"]["props"].get("node.name") in (GAME, CHAT)]
                spatial = [n for n in snapshot if n["info"]["props"].get("node.name") == SURROUND]
                correct_latency = len(outputs) == 2 and all(n["info"]["props"].get("node.latency") == str(expected)+"/48000" for n in outputs)
                if correct_latency and bool(spatial) == (name == "surround"):
                    break
                time.sleep(.25)
            else:
                raise RuntimeError("H9 II Game/Chat 출력 또는 DSP 로드 확인 실패")
            target = choose_output(name)
            dsp=settings.options(BASE,name)
            if name in ("fps", "voice", "surround") or dsp["drc"] or dsp["output_alc"] or dsp["eq_enable"] or any(dsp["eq"]) or dsp["sound_mode"]=="immersive":
                # Activate DSP with silence; no audible test tones.
                subprocess.run(["pw-cat", "-p", "--raw", "--format", "f32", "--rate", "48000", "--channels", "2", "--latency", "256", "--target", target, "-"], input=bytes(4096*8), stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, check=True, timeout=8)
            if name in ("fps", "voice") and dsp["base_eq"]:
                output = next(n for n in outputs if n["info"]["props"]["node.name"] == target)
                if "eq0:" not in run("pw-cli", "enum-params", str(output["id"]), "Props"):
                    raise RuntimeError("EQ 로드 확인 실패")
            if dsp['drc'] or dsp['output_alc'] or dsp['eq_enable'] or any(dsp['eq']) or dsp['sound_mode']=='immersive':
                sink=CHAT if name=='voice' else GAME
                output=next(n for n in outputs if n['info']['props']['node.name']==sink)
                props=run('pw-cli','enum-params',str(output['id']),'Props')
                required=[]
                if dsp['drc']:required.append('game_drc:')
                if dsp['output_alc']:required.append('output_alc:')
                if dsp['eq_enable'] or any(dsp['eq']):required.append('custom')
                if dsp['sound_mode']=='immersive':required.append('immersive')
                if any(k not in props for k in required):raise RuntimeError('추가 출력 DSP 로드 확인 실패')
            if name == "surround":
                # A failed target link must never silently fall back to another device.
                snapshot = json.loads(run("pw-dump"))
                names = {n["id"]:n.get("info",{}).get("props",{}).get("node.name") for n in snapshot if n.get("type") == "PipeWire:Interface:Node"}
                links = [n["info"] for n in snapshot if n.get("type") == "PipeWire:Interface:Link"]
                if not any(names.get(l.get("output-node-id")) == "inzone.sony-surround.output" and names.get(l.get("input-node-id")) == GAME for l in links):
                    raise RuntimeError("서라운드 → Game 연결 확인 실패")
        if not quiet:
            print("적용: " + LABELS[name])
    except Exception:
        write_active(previous)
        restart_wireplumber()
        for _ in range(40):
            try:
                run("pactl", "set-default-sink", previous_default)
                break
            except subprocess.CalledProcessError:
                time.sleep(.25)
        raise

TITLES = {"fps": "FPS", "music": "음악", "voice": "통화", "balanced": "기본", "surround": "서라운드 · Sony / 실험", "restore": "이전 음색·지연 복원"}
DESCRIPTIONS = {
    "fps": "저음을 줄이고 발소리 대역을 강조합니다.",
    "music": "EQ를 끄고 음악 감상용 변환 설정을 사용합니다.",
    "voice": "말소리를 강조하고 마이크 저역을 정리합니다.",
    "balanced": "EQ 없이 게임·음악·통화에 두루 사용합니다.",
    "surround": "Sony 기본/개인화 공간 필터로 7.1 입력을 처리합니다.",
    "restore": "프로파일을 나누기 전 음색·지연 설정으로 되돌립니다.",
}


def activate(name, quiet=False, automatic=False, auto_token=None):
    with (DATA / "switch.lock").open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError("다른 창에서 프로파일을 전환하고 있습니다.") from None
        if automatic:
            from profile_automation import manual_token
            if manual_token(BASE)!=auto_token:raise RuntimeError('수동 선택이 변경되어 자동 전환을 취소합니다')
        apply(name, quiet=quiet)
        if not automatic:
            from profile_automation import mark_manual
            mark_manual(BASE)


def cell_clip(text, width):
    """Clip by terminal cells, including double-width Korean characters."""
    result = []
    used = 0
    for char in str(text):
        if unicodedata.category(char).startswith("C"):
            char = " "
        size = 0 if unicodedata.combining(char) else (2 if unicodedata.east_asian_width(char) in "WF" else 1)
        if used + size > width:
            break
        result.append(char)
        used += size
    return "".join(result)


def details(name):
    path = DATA / ("original.conf" if name == "restore" else name + ".conf")
    if name == "restore":
        return ["저장된 음색·지연을 복원합니다. Game/Chat은 유지합니다.", "음색 보정: 없음", "출력: 48 kHz / 16 bit"]
    raw = "\n".join(line for line in path.read_text().splitlines() if not line.lstrip().startswith("#"))
    config = json.loads(raw)
    props = config["monitor.alsa.rules"][0]["actions"]["update-props"]
    samples, rate = map(int, props["node.latency"].split("/"))
    suspend = props.get("session.suspend-timeout-seconds", 5)
    lines = [
        "출력: 48 kHz / 16 bit · 스테레오",
        f"처리 주기 요청: {samples} 샘플 ({samples / rate * 1000:.2f} ms)",
        "출력 절전: " + (f"{suspend}초 후" if suspend else "해제"),
    ]
    if name == "surround":
        lines[0] = "7.1 입력 → Sony HRTF → Game 출력"
        lines.append("H9 II 보정 EQ · Sony 자동 음량 제어")
    elif name == "music":
        lines.append("음색 보정 없음 · 16 bit 디더링 적용")
    elif name == "voice":
        lines.append("말소리 EQ · 마이크 80 Hz 저역 필터")
    elif name == "fps":
        lines.append("150 Hz -4 dB · 2.5 kHz +2 dB")
    else:
        lines.append("음색 보정 없음")
    o=settings.options(BASE,name)
    if not o['base_eq'] and name in ('fps','voice'):lines[3]='기본 출력 EQ 해제'
    if o['sound_mode']=='immersive':lines[3]='Sony 몰입 음장'+(' · 10밴드 EQ' if o['eq_enable'] or any(o['eq']) else '')
    elif o['eq_enable'] or any(o['eq']):lines[3]+=' · Sony 10밴드 EQ'
    lines.append('DRC: '+('끔','낮음','높음')[o['drc']]+' · 출력 ALC: '+('켬' if o['output_alc'] else '끔')+' · 마이크 AGC: '+('켬' if o['mic_agc'] else '끔'))
    if name=='surround':lines[0]='7.1 입력 → '+('개인화 HRTF' if o['hrtf']=='personal' else 'Sony 기본 HRTF')+' → Game 출력'
    return lines


def change_options(name,updates):
    if name not in settings.PROFILES:raise ValueError('복원 항목에서는 DSP를 편집할 수 없습니다')
    with (DATA/'switch.lock').open('w') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        previous=settings.load(BASE);new=dict(previous)
        value=settings.options(BASE,name);value.update(updates);new[name]=value
        settings.save(BASE,new)
        try:
            apply(name,quiet=True)
            from profile_automation import mark_manual
            mark_manual(BASE)
        except Exception:
            settings.save(BASE,previous);raise


def prompt(screen,title):
    screen.erase();screen.addstr(2,2,cell_clip(title,screen.getmaxyx()[1]-4));screen.addstr(4,2,'> ')
    curses.echo();curses.curs_set(1);screen.timeout(-1)
    try:return screen.getstr(4,4,1024).decode('utf-8').strip()
    finally:curses.noecho();curses.curs_set(0);screen.timeout(500)


def edit_eq(screen,name):
    if name not in settings.PROFILES:raise ValueError('편집할 프로파일을 선택하세요')
    eq=settings.options(BASE,name)['eq'];index=0
    while True:
        screen.erase();h,w=screen.getmaxyx()
        if h<18 or w<40:
            screen.addstr(0,0,'Resize terminal or press Esc')
        else:
            screen.addstr(1,2,'10-band EQ / '+TITLES[name],curses.A_BOLD)
            for i,(frequency,gain) in enumerate(zip(settings.FREQUENCIES,eq)):
                screen.addstr(3+i,2,f'{frequency:5g} Hz   {gain:+5.1f} dB',curses.A_REVERSE if i==index else 0)
            screen.addstr(h-3,2,cell_clip('↑↓: 대역  ←→: 1 dB  0: 초기화',w-4))
            screen.addstr(h-2,2,cell_clip('Enter: 저장·적용  Esc: 취소',w-4))
        key=screen.getch()
        if key==27:return
        if key==curses.KEY_UP:index=(index-1)%10
        elif key==curses.KEY_DOWN:index=(index+1)%10
        elif key==curses.KEY_LEFT:eq[index]=max(-12,eq[index]-1)
        elif key==curses.KEY_RIGHT:eq[index]=min(12,eq[index]+1)
        elif key==ord('0'):eq=[0.]*10
        elif key in (10,13,curses.KEY_ENTER):change_options(name,{'eq':eq,'eq_enable':True});return


def tui(screen):
    try:
        curses.curs_set(0)
    except curses.error:
        pass
    screen.keypad(True)
    screen.timeout(500)
    accent = curses.A_BOLD
    active_attr = curses.A_BOLD
    selected_attr = curses.A_REVERSE
    if curses.has_colors():
        curses.start_color()
        curses.init_pair(1, curses.COLOR_CYAN, curses.COLOR_BLACK)
        curses.init_pair(2, curses.COLOR_GREEN, curses.COLOR_BLACK)
        curses.init_pair(3, curses.COLOR_BLACK, curses.COLOR_CYAN)
        accent = curses.color_pair(1) | curses.A_BOLD
        active_attr = curses.color_pair(2) | curses.A_BOLD
        selected_attr = curses.color_pair(3) | curses.A_BOLD
    keys = list(TITLES)
    current = status()
    selected = keys.index(current) if current in keys else 0
    message = "선택 후 Enter를 누르면 적용합니다."
    while True:
        height, width = screen.getmaxyx()
        screen.erase()

        def put(y, x, text, attr=0):
            if 0 <= y < height and 0 <= x < width - 1:
                try:
                    screen.addstr(y, x, cell_clip(text, width - x - 1), attr)
                except curses.error:
                    pass

        put(1, 2, "INZONE H9 II / 프로파일", accent)
        if height < 24 or width < 72:
            put(3, 2, "터미널을 72열 × 24행 이상으로 넓혀 주세요.")
            put(5, 2, "Q / Esc: 종료", curses.A_DIM)
            screen.refresh()
            key = screen.getch()
            if key in (ord("q"), ord("Q"), 27):
                return
            continue
        current = status()
        current_title = TITLES.get(current, "이전 공통 설정" if current == "original" else current)
        put(3, 2, "현재 적용: " + current_title, active_attr)
        for index, name in enumerate(keys):
            is_active = current == name or (name == "restore" and current == "original")
            text = ("> " if index == selected else "  ") + str(index + 1) + "  " + TITLES[name]
            if is_active:
                text += "  [적용 중]"
            put(5 + index, 2, text, selected_attr if index == selected else (active_attr if is_active else 0))
        name = keys[selected]
        detail_row = 6 + len(keys)
        put(detail_row, 2, DESCRIPTIONS[name], accent)
        try:
            for index, line in enumerate(details(name)[:max(0,height-6-(detail_row+1))]):
                put(detail_row + 1 + index, 2, line)
        except (OSError, ValueError, KeyError, IndexError) as exc:
            put(detail_row + 1, 2, "설정 파일 확인 실패: " + str(exc))
        put(height - 6, 2, "D: DRC  A: 출력 ALC  M: 마이크 AGC  P: 기본/개인화", curses.A_DIM)
        put(height - 5, 2, "E: EQ  S: 프리셋  H: 장치  U: 자동  I: 개인화 파일", curses.A_DIM)
        put(height - 4, 2, message)
        put(height - 2, 2, f"↑↓ / J K: 선택  1–{len(keys)}: 선택  Enter: 적용  Q: 종료", curses.A_DIM)
        screen.refresh()
        key = screen.getch()
        if 65<=key<=90:key+=32
        if key in (ord("q"), ord("Q"), 27):
            return
        if key in (curses.KEY_UP, ord("k")):
            selected = (selected - 1) % len(keys)
        elif key in (curses.KEY_DOWN, ord("j")):
            selected = (selected + 1) % len(keys)
        elif ord("1") <= key < ord("1") + len(keys):
            selected = key - ord("1")
        elif key in map(ord,'dampeihsu'):
            name=keys[selected]
            try:
                o=settings.options(BASE,name)
                if key==ord('h'):
                    import device_tui
                    device_tui.show(screen,cell_clip)
                elif key==ord('d'):change_options(name,{'drc':(o['drc']+1)%3})
                elif key==ord('a'):change_options(name,{'output_alc':not o['output_alc']})
                elif key==ord('m'):change_options(name,{'mic_agc':not o['mic_agc']})
                elif key==ord('p'):
                    if name!='surround':raise ValueError('서라운드 프로파일에서 HRTF를 선택하세요')
                    change_options(name,{'hrtf':'personal' if o['hrtf']=='standard' else 'standard'})
                elif key==ord('e'):edit_eq(screen,name)
                elif key==ord('u'):
                    import profile_automation
                    profile_automation.show(screen,cell_clip,prompt,BASE)
                elif key==ord('s'):
                    import sony_presets
                    sony_presets.show(screen,cell_clip,change_options,name)
                elif key==ord('i'):
                    hki=prompt(screen,'개인화 HKI 파일 경로 (빈 입력: 취소)')
                    if hki:
                        ba=prompt(screen,'H9 II 개인화용 YY2987.ba 파일 경로')
                        if ba:import_files(BASE,Path(hki).expanduser(),Path(ba).expanduser())
                message='설정 처리 완료'
            except (Exception,KeyboardInterrupt) as exc:message='중단/실패: '+' '.join(str(exc).split())
            curses.flushinp()
        elif key in (curses.KEY_ENTER, 10, 13):
            name = keys[selected]
            put(height - 4, 2, " " * (width - 4))
            put(height - 4, 2, TITLES[name] + " 적용 중…", accent)
            screen.refresh()
            try:
                activate(name, quiet=True)
                message = "적용 완료: " + TITLES[name]
            except Exception as exc:
                message = "실패: " + " ".join(str(exc).split())
            # Do not execute queued Enter keys again after a service restart.
            curses.flushinp()


def main():
    name = sys.argv[1] if len(sys.argv) > 1 else "--tui"
    if name.startswith('--auto-'):
        import profile_automation as auto
        if name=='--auto-watch':auto.watch(BASE,status,activate,nodes)
        elif name=='--auto-bind':
            if len(sys.argv) not in (4,5):raise ValueError('Usage: --auto-bind APP PROFILE [PRIORITY]')
            auto.edit(BASE,sys.argv[2],sys.argv[3],int(sys.argv[4]) if len(sys.argv)==5 else 0)
        elif name=='--auto-remove':
            if len(sys.argv)!=3:raise ValueError('Usage: --auto-remove APP')
            auto.edit(BASE,sys.argv[2])
        elif name=='--auto-config':print(json.dumps(auto.load(BASE),ensure_ascii=False,indent=2))
        elif name in ('--auto-enable','--auto-disable'):auto.service(name.removeprefix('--auto-'))
        else:raise ValueError('자동 전환: --auto-config / --auto-bind / --auto-remove / --auto-enable / --auto-disable')
        return
    if name=='--preset':
        import sony_presets
        if len(sys.argv)==2:print(json.dumps(sony_presets.LABELS,ensure_ascii=False,indent=2));return
        if len(sys.argv)!=4:raise ValueError('Usage: --preset PROFILE PRESET')
        change_options(sys.argv[2],sony_presets.preset(sys.argv[3]));print('Sony 프리셋 적용 완료');return
    if name=='--windows-list':
        from sony_presets import read_windows
        if len(sys.argv)!=3:raise ValueError('Usage: --windows-list FILE.json')
        for i,item in enumerate(read_windows(sys.argv[2]),1):print(str(i)+': '+json.dumps(item,ensure_ascii=False))
        return
    if name=='--windows-import':
        from sony_presets import read_windows
        if len(sys.argv)!=5:raise ValueError('Usage: --windows-import PROFILE FILE.json INDEX')
        items=read_windows(sys.argv[3]);index=int(sys.argv[4])-1
        if not 0<=index<len(items):raise ValueError('프로파일 번호가 범위를 벗어났습니다')
        item=items[index]
        if item['surround']!=(sys.argv[2]=='surround'):raise ValueError('Windows Surround 값과 대상 프로파일의 공간 처리가 일치해야 합니다')
        change_options(sys.argv[2],item['options']);print('Windows 프로파일 가져오기 완료');return
    if name=='--windows-export':
        from sony_presets import export_windows
        if len(sys.argv)!=4:raise ValueError('Usage: --windows-export PROFILE FILE.json')
        export_windows(BASE,sys.argv[2],sys.argv[3]);print('Windows 프로파일 내보내기 완료');return
    if name=='--device-status':
        from inzone_device import Device
        with Device() as device:print(json.dumps(device.snapshot(),ensure_ascii=False,indent=2))
        return
    if name=='--device-set':
        if len(sys.argv)!=4:raise ValueError('Usage: --device-set FIELD VALUE')
        from inzone_device import Device,FIELDS
        if sys.argv[2] not in FIELDS:raise ValueError('장치 설정 키: '+', '.join(FIELDS))
        with Device() as device:device.set_field(sys.argv[2],int(sys.argv[3]))
        print('장치 설정·조회 확인 완료');return
    if name=='--set':
        if len(sys.argv)!=5:raise ValueError('Usage: --set PROFILE KEY JSON_VALUE')
        change_options(sys.argv[2],{sys.argv[3]:json.loads(sys.argv[4])});print('설정 적용 완료');return
    if name=='--settings':print(json.dumps(settings.load(BASE),ensure_ascii=False,indent=2));return
    if name=='--personalize-import':
        if len(sys.argv)!=4:raise ValueError('Usage: --personalize-import FILE.hki YY2987.ba')
        print(import_files(BASE,sys.argv[2],sys.argv[3]));return
    if name=='--export':
        if len(sys.argv)!=3:raise ValueError('Usage: --export FILE.json')
        Path(sys.argv[2]).write_text(json.dumps(settings.load(BASE),ensure_ascii=False,indent=2)+'\n');return
    if name=='--import':
        if len(sys.argv)!=3:raise ValueError('Usage: --import FILE.json')
        data=settings.validate(json.loads(Path(sys.argv[2]).read_text()))
        with (DATA/'switch.lock').open('w') as lock:
            fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB);old=settings.load(BASE);settings.save(BASE,data)
            try:
                current=status()
                if current in settings.PROFILES:
                    apply(current,quiet=True)
                    from profile_automation import mark_manual
                    mark_manual(BASE)
            except Exception:settings.save(BASE,old);raise
        print('프로파일 설정 가져오기 완료');return
    if name == "--status":
        print(status())
        return
    if name in ("--list", "--help", "-h"):
        print("Usage: inzone-profile [--tui|fps|music|voice|balanced|surround|restore|--status]")
        print("인수 없이 실행하면 TUI가 열립니다. --gui는 --tui의 호환 별칭입니다.")
        print("자동 전환: --auto-bind APP PROFILE [PRIORITY]; --auto-config; --auto-enable; --auto-disable; TUI에서 U")
        print("Sony EQ: --preset [PROFILE PRESET]; Windows: --windows-list FILE; --windows-import PROFILE FILE INDEX; --windows-export PROFILE FILE")
        print("장치: --device-status; --device-set FIELD VALUE; TUI에서 H")
        print("DSP: --set PROFILE drc 0|1|2; --set PROFILE output_alc true|false; --set PROFILE mic_agc true|false")
        print("개인화: --personalize-import FILE.hki YY2987.ba; TUI에서 I")
        print("설정: --settings; --export FILE.json; --import FILE.json")
        for key, label in LABELS.items():
            print(key + ": " + label)
        return
    if name in ("--tui", "--gui"):
        if not sys.stdin.isatty() or not sys.stdout.isatty():
            raise SystemExit("TUI는 터미널에서 실행하세요. 직접 적용: inzone-profile music")
        locale.setlocale(locale.LC_ALL, "")
        curses.wrapper(tui)
        return
    if name not in LABELS:
        raise SystemExit("Unknown profile. Use --list.")
    activate(name)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
    except Exception as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(1)
