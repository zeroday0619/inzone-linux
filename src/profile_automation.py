"""Opt-in process-associated profiles; manual choices override until matches change."""
import fcntl,json,os,signal,subprocess,time
from pathlib import Path
PROFILES=('fps','music','voice','balanced','surround')
UNIT='inzone-profile-auto.service'
def validate(data):
    if not isinstance(data,list) or len(data)>128:raise ValueError('자동 전환 규칙은 최대 128개입니다')
    result=[];seen=set()
    for rule in data:
        if not isinstance(rule,dict) or set(rule)!={'app','profile','priority'}:raise ValueError('잘못된 자동 전환 규칙')
        app=rule['app']
        if not isinstance(app,str) or not app or len(app)>1024 or any(ord(c)<32 for c in app) or app in seen:raise ValueError('실행 파일 이름/경로는 비어 있지 않은 고유 문자열이어야 합니다')
        if rule['profile'] not in PROFILES:raise ValueError('잘못된 자동 전환 프로파일')
        if type(rule['priority']) is not int or not -1000<=rule['priority']<=1000:raise ValueError('우선순위 범위: −1000~1000')
        result.append(dict(rule));seen.add(app)
    return result

def file(home):return Path(home)/'.config/inzone-h9-ii/auto-profiles.json'
def load(home):return validate(json.loads(file(home).read_text())) if file(home).exists() else []
def save(home,data):
    data=validate(data);p=file(home);tmp=p.with_suffix('.tmp');tmp.write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n');tmp.chmod(0o600);tmp.replace(p)
def edit(home,app,profile=None,priority=0):
    with (file(home).parent/'auto-rules.lock').open('w') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX)
        rules=[r for r in load(home) if r['app']!=app]
        if profile is not None:rules.append({'app':app,'profile':profile,'priority':priority})
        save(home,rules)
def mark_manual(home):
    (file(home).parent/'manual-switch').write_text(str(time.time_ns()))
def manual_token(home):
    try:return (file(home).parent/'manual-switch').read_text()
    except FileNotFoundError:return ''

def processes(proc=Path('/proc'),uid=None):
    """Only this user's executable identity; never match arbitrary argument substrings."""
    uid=os.getuid() if uid is None else uid;names=set()
    for entry in proc.iterdir():
        if not entry.name.isdecimal():continue
        try:
            if entry.stat().st_uid!=uid:continue
            exe=os.readlink(entry/'exe');names.update((exe,Path(exe).name))
            # Wine/Proton exposes the actual Windows executable as argv[0].
            with (entry/'cmdline').open('rb') as f:first=f.read(4096).split(b'\0',1)[0].decode('utf-8','replace')
            if first.lower().endswith('.exe'):
                names.update((first,first.replace('\\','/').rsplit('/',1)[-1]))
        except (OSError,ValueError):continue
    return names

def matches(rules,names):
    # Highest priority wins; configuration order breaks ties.
    return tuple((r['app'],r['profile'],r['priority']) for _,r in sorted(enumerate(rules),key=lambda item:(-item[1]['priority'],item[0])) if r['app'] in names)

class Decision:
    def __init__(self,current,token):
        self.baseline=current;self.applied=None;self.token=token;self.group=();self.candidate=None;self.since=0;self.hold=False
    def step(self,group,current,token,now):
        if token!=self.token or (self.applied is not None and current!=self.applied):
            self.token=token;self.baseline=current;self.applied=None;self.hold=True
            # Remember the current set even when manual selection interrupts debounce.
            self.group=group;self.candidate=group;self.since=now
        if group!=self.candidate:self.candidate=group;self.since=now
        if now-self.since<2:return None
        if group!=self.group:self.group=group;self.hold=False
        if self.hold:return None
        target=group[0][1] if group else self.baseline
        if target==current:return None
        return target
    def committed(self,target):self.applied=target

def service(action):
    subprocess.run(['systemctl','--user','daemon-reload'],check=True,timeout=15)
    subprocess.run(['systemctl','--user',action,'--now',UNIT],check=True,timeout=20)

def watch(home,status,activate,connected):
    home=Path(home);stopping=False
    def stop(*_):
        nonlocal stopping
        stopping=True
    for sig in (signal.SIGTERM,signal.SIGINT):signal.signal(sig,stop)
    with (file(home).parent/'auto-watch.lock').open('w') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        initial=status();initial='restore' if initial=='original' else initial
        decision=Decision(initial,manual_token(home));retry=0;last_error=None
        while not stopping:
            try:
                now=time.monotonic();group=matches(load(home),processes())
                target=decision.step(group,status(),manual_token(home),now)
                if target and now>=retry and connected():
                    activate(target,quiet=True,automatic=True,auto_token=decision.token);decision.committed(target)
                    print('자동 전환: '+target,flush=True)
                last_error=None
            except Exception as exc:
                error=str(exc)
                if error!=last_error:print('자동 전환 대기: '+error,flush=True)
                last_error=error;retry=time.monotonic()+15
            time.sleep(1)
        # Restore only a profile we still own; respect manual switches on shutdown.
        if decision.applied and manual_token(home)==decision.token and status()==decision.applied and decision.baseline!=decision.applied:
            activate(decision.baseline,quiet=True,automatic=True,auto_token=decision.token)

def show(screen,clip,prompt,home):
    import curses
    index=0;message='등록한 실행 파일이 2초 이상 감지되면 전환합니다.'
    while True:
        screen.erase();h,w=screen.getmaxyx();rules=load(home);index=min(index,max(0,len(rules)-1))
        def put(y,text,attr=0):
            if 0<=y<h-1:
                try:screen.addstr(y,2,clip(text,max(0,w-4)),attr)
                except curses.error:pass
        active=subprocess.run(['systemctl','--user','is-active','--quiet',UNIT],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=5).returncode==0
        put(1,'자동 프로파일 / '+('실행 중' if active else '꺼짐'),curses.A_BOLD)
        start=max(0,index-max(1,h-10)+1)
        for i,r in enumerate(rules[start:start+max(1,h-10)],start):put(3+i-start,f"{r['priority']:4}  {r['app']} → {r['profile']}",curses.A_REVERSE if i==index else 0)
        put(h-5,message);put(h-4,'A: 규칙 추가/수정  D: 삭제  Space: 자동 전환 켜기/끄기')
        put(h-3,'높은 우선순위 먼저 · 동률은 목록 순서 · Esc: 돌아가기')
        key=screen.getch()
        if 65<=key<=90:key+=32
        if key==27:return
        if key==curses.KEY_UP:index=max(0,index-1)
        elif key==curses.KEY_DOWN:index=min(max(0,len(rules)-1),index+1)
        else:
            try:
                if key==ord('a'):
                    app=prompt(screen,'실행 파일 이름/경로 (예: game.exe, 빈 입력: 취소)')
                    if app:
                        profile=prompt(screen,'대상: fps / music / voice / balanced / surround')
                        if profile:
                            rank=prompt(screen,'우선순위 −1000~1000 (기본 0)');edit(home,app,profile,int(rank or '0'))
                elif key==ord('d') and rules:edit(home,rules[index]['app'])
                elif key==ord(' '):service('disable' if active else 'enable')
                else:continue
                message='처리 완료'
            except Exception as exc:message='실패: '+' '.join(str(exc).split())
