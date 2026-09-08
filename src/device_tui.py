"""Device controls and explicit microphone monitoring for the profile TUI."""
import curses,json,subprocess as sp,time
from inzone_device import Device,FIELDS
GAME='alsa_output.usb-Sony_INZONE_H9_II-00.stereo-game'
CHAT='alsa_output.usb-Sony_INZONE_H9_II-00.stereo-chat'
MIC='alsa_input.usb-Sony_INZONE_H9_II-00.mono-chat'
HOST={'game_volume':('sinks',GAME,'게임 출력 음량'), 'chat_volume':('sinks',CHAT,'채팅 출력 음량'), 'mic_volume':('sources',MIC,'마이크 입력 음량')}
def host_levels():
    result={}
    for kind in ('sinks','sources'):
        # pactl can warn about non-ASCII descriptions even when its JSON is usable.
        # Capture diagnostics so they cannot corrupt the curses screen.
        try:
            output=sp.check_output(['pactl','-f','json','list',kind],text=True,stderr=sp.PIPE,timeout=5)
        except sp.CalledProcessError as exc:
            detail=' '.join((exc.stderr or str(exc)).split())
            raise RuntimeError('오디오 상태 조회 실패: '+detail) from exc
        nodes=json.loads(output)
        for key,(category,target,label) in HOST.items():
            if category!=kind:continue
            node=next((n for n in nodes if n['name']==target),None)
            if node:
                volume=next(iter(node['volume'].values()))
                result[key]=int(volume['value_percent'].rstrip('%'))
                if key=='mic_volume':result['mic_mute']=int(node['mute'])
    return result

def set_host(key,value):
    if key=='mic_mute':args=['set-source-mute',MIC,str(value)]
    else:
        category,target,_=HOST[key];args=['set-sink-volume' if category=='sinks' else 'set-source-volume',target,str(value)+'%']
    sp.run(['pactl',*args],check=True,stdout=sp.DEVNULL,stderr=sp.PIPE,timeout=5)

def show(screen,clip):
    selected=0;pending=None;message='←→: 값 선택 후 Enter로 적용합니다.';snapshot={};levels={};monitor=None;monitor_started=0;next_refresh=0
    try:
        with Device() as device:
            while True:
                now=time.monotonic()
                if now>=next_refresh:
                    try:snapshot=device.snapshot();levels=host_levels();next_refresh=now+5
                    except Exception as exc:message=str(exc);next_refresh=now+5
                if monitor and (monitor.poll() is not None or now-monitor_started>30):
                    if monitor.poll() is None:monitor.terminate();monitor.wait(timeout=3)
                    monitor=None
                keys=[k for k in FIELDS if k in snapshot.get('fields',{})]+[k for k in (*HOST,'mic_mute') if k in levels]
                if selected>=len(keys):selected=max(0,len(keys)-1)
                h,w=screen.getmaxyx();screen.erase()
                def put(y,text,attr=0):
                    if 0<=y<h:
                        try:screen.addstr(y,2,clip(text,w-4),attr)
                        except curses.error:pass
                put(1,'INZONE H9 II / 장치 설정',curses.A_BOLD)
                battery=snapshot.get('battery',{});firmware=snapshot.get('firmware',{})
                put(2,'배터리: '+str(battery.get('percent','?'))+'%  ·  '+('충전 중' if battery.get('state')=='charging' else '배터리 사용'))
                put(3,'펌웨어: 헤드셋 '+firmware.get('headset','?')+' / 동글 '+firmware.get('dongle','?'))
                put(4,'장치 설정은 모든 프로파일에 공통으로 적용됩니다.',curses.A_DIM)
                rows=max(1,h-11);first=max(0,min(selected-rows+1,max(0,len(keys)-rows)))
                for offset,key in enumerate(keys[first:first+rows]):
                    idx=first+offset;active=idx==selected
                    if key in FIELDS:
                        field=FIELDS[key];value=snapshot['fields'][key];label=field.label
                        if active and pending is not None:value=pending
                        display=field.labels[field.values.index(value)] if field.labels and value in field.values else str(value)
                    else:
                        value=levels[key];label='마이크 음소거' if key=='mic_mute' else HOST[key][2]
                        if active and pending is not None:value=pending
                        display=('켬' if value else '끔') if key=='mic_mute' else str(value)+'%'
                    put(6+offset,('> ' if active else '  ')+label+': '+display+(' *' if active and pending is not None else ''),curses.A_REVERSE if active else 0)
                if not snapshot.get('connected'):put(6,'헤드셋 연결을 기다리고 있습니다.')
                put(h-4,('마이크 테스트 재생 중 (최대 30초)' if monitor else message))
                put(h-3,'↑↓: 항목  ←→: 값  Enter: 적용  R: 새로 읽기',curses.A_DIM)
                put(h-2,'T: 마이크 듣기 시작/중지  Esc / Q: 돌아가기',curses.A_DIM)
                screen.refresh();key=screen.getch()
                if 65<=key<=90:key+=32
                if key in (27,ord('q')):return
                if key==ord('r'):next_refresh=0;pending=None;continue
                if key==ord('t'):
                    if monitor:monitor.terminate();monitor.wait(timeout=3);monitor=None
                    else:
                        guard='{ node.dont-fallback = true node.dont-reconnect = true }'
                        monitor=sp.Popen(['pw-loopback','-n','inzone.mic-test','-c','1','-m','MONO','-C',MIC,'-P',GAME,'-i',guard,'-o',guard],stdout=sp.DEVNULL,stderr=sp.DEVNULL);monitor_started=now
                    continue
                if not keys:continue
                if key==curses.KEY_UP:selected=(selected-1)%len(keys);pending=None
                elif key==curses.KEY_DOWN:selected=(selected+1)%len(keys);pending=None
                elif key in (curses.KEY_LEFT,curses.KEY_RIGHT):
                    fieldkey=keys[selected]
                    values=FIELDS[fieldkey].values if fieldkey in FIELDS else ((0,1) if fieldkey=='mic_mute' else tuple(range(101)))
                    current=pending if pending is not None else (snapshot['fields'][fieldkey] if fieldkey in FIELDS else levels[fieldkey])
                    index=values.index(current) if current in values else min(range(len(values)),key=lambda i:abs(values[i]-current))
                    pending=values[max(0,min(len(values)-1,index+(1 if key==curses.KEY_RIGHT else -1)))]
                elif key in (10,13,curses.KEY_ENTER) and pending is not None:
                    try:
                        fieldkey=keys[selected]
                        if fieldkey in FIELDS:device.set_field(fieldkey,pending)
                        else:set_host(fieldkey,pending)
                        message='적용·조회 확인 완료';pending=None;next_refresh=0
                    except Exception as exc:message=str(exc)
    finally:
        if monitor and monitor.poll() is None:monitor.terminate();monitor.wait(timeout=3)
