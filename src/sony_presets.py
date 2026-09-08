"""Shipped Sony presets and INZONE Hub SoundProfile.json interoperability."""
import json
import re
import uuid
from pathlib import Path
import inzone_settings as settings
LABELS={'flat':'Flat','fps1':'FPS 1','fps2':'FPS 2','fps3':'FPS 3','immersion_flat':'RPG / Adventure','bass_boost':'Bass Boost','music_video':'Music / Video'}
FIELDS=('31_5Hz','63Hz','125Hz','250Hz','500Hz','1kHz','2kHz','4kHz','8kHz','16kHz')
ENUMS=('CUSTOM','FLAT','BASS_BOOST','MUSIC_VIDEO','FPS1','FPS2','FPS3','IMMERSION_FLAT')

def bank():return json.loads((Path(__file__).resolve().parents[1]/'assets/sony-presets.json').read_text())
def preset(name):
    if name not in LABELS:raise ValueError('프리셋: '+', '.join(LABELS))
    return bank()['presets'][name]

def enum(value,names):
    if type(value) is int and 0<=value<len(names):return names[value]
    if isinstance(value,str) and value.upper() in names:return value.upper()
    if isinstance(value,str) and value.isdecimal():return enum(int(value),names)
    raise ValueError('알 수 없는 Windows 설정 값: '+str(value))

def jsonc(text):
    # Preserve strings verbatim while removing .NET's permitted comments/commas.
    pattern=r'"(?:\\.|[^"\\])*"|//[^\r\n]*|/\*[\s\S]*?\*/'
    clean=re.sub(pattern,lambda m:' ' if m[0].startswith(('/','/*')) else m[0],text)
    clean=re.sub(r'"(?:\\.|[^"\\])*"|,\s*(?=[}\]])',lambda m:'' if m[0].startswith(',') else m[0],clean)
    return json.loads(clean)

def read_windows(path):
    path=Path(path).expanduser()
    if not path.is_file() or path.stat().st_size>1024*1024:raise ValueError('1 MiB 이하 Windows JSON 파일이 필요합니다')
    with path.open('rb') as f:raw=f.read(1024*1024+1)
    if len(raw)>1024*1024:raise ValueError('파일이 너무 큽니다')
    data=jsonc(raw.decode('utf-8-sig'))
    if not isinstance(data,list) or not 1<=len(data)<=256:raise ValueError('Windows 프로파일 배열이 필요합니다 (1–256개)')
    result=[]
    for item in data:
        if not isinstance(item,dict):raise ValueError('잘못된 프로파일 항목')
        value={k.lower():v for k,v in item.items()}
        kind=enum(value.get('eqpreset','FLAT'),ENUMS)
        if kind=='CUSTOM':
            gains=[]
            for field in FIELDS:
                v=value.get(('EQGain_'+field).lower(),0)
                if isinstance(v,str):v=int(v)
                gains.append(v)
            options={'eq':gains,'eq_enable':True,'sound_mode':enum(value.get('eqaxis','STANDARD'),('STANDARD','IMMERSIVE')).lower(),'output_alc':True,'base_eq':False}
        else:options=preset(kind.lower())
        options['drc']=('OFF','LOW','HIGH').index(enum(value.get('dynamicrangecompression','OFF'),('OFF','LOW','HIGH')))
        surround=value.get('surround',False)
        if type(surround) is not bool:raise ValueError('Surround 값은 boolean이어야 합니다')
        title=value.get('profilename','Windows profile')
        if not isinstance(title,str) or len(title)>256:raise ValueError('잘못된 프로파일 이름')
        settings.validate({'balanced':options})
        result.append({'name':title,'surround':surround,'options':options})
    return result

def export_windows(home,name,path):
    if name not in settings.PROFILES:raise ValueError('DSP 프로파일을 선택하세요')
    options=settings.options(home,name)
    if options['base_eq'] and name in ('fps','voice'):raise ValueError('Linux 기본 EQ는 Windows 파일로 표현할 수 없습니다. Sony 프리셋을 먼저 적용하세요')
    if options['mic_agc'] or options['hrtf']=='personal':raise ValueError('Windows SoundProfile에는 마이크 AGC·개인화 필터 선택이 저장되지 않습니다')
    enabled=options['eq_enable'] or any(options['eq'])
    if options['output_alc'] != bool(enabled or options['sound_mode']=='immersive'):
        raise ValueError('이 ALC/EQ 조합은 Windows SoundProfile로 표현할 수 없습니다')
    kind='CUSTOM' if enabled else ('IMMERSION_FLAT' if options['sound_mode']=='immersive' else 'FLAT')
    item={'ProfileID':str(uuid.uuid4()),'ProfileName':name,'EQPreset':kind,'EQAxis':options['sound_mode'].upper(),'Surround':name=='surround','DynamicRangeCompression':('OFF','LOW','HIGH')[options['drc']]}
    item.update({'EQGain_'+k:int(v) for k,v in zip(FIELDS,options['eq'])})
    Path(path).expanduser().write_text(json.dumps([item],ensure_ascii=False,indent=2)+'\n')

def show(screen,clip,apply,name):
    import curses
    keys=list(LABELS);index=0
    while True:
        screen.erase();h,w=screen.getmaxyx()
        def put(y,text,attr=0):
            if 0<=y<h-1:
                try:screen.addstr(y,2,clip(text,max(0,w-4)),attr)
                except curses.error:pass
        put(1,'Sony EQ 프리셋 / '+name,curses.A_BOLD)
        for i,key in enumerate(keys):put(3+i,LABELS[key],curses.A_REVERSE if i==index else 0)
        put(h-4,'Sony 프리셋은 기존 Linux 음색 EQ를 대체합니다.')
        put(h-3,'↑↓ 선택 · Enter 적용 · Esc 취소')
        key=screen.getch()
        if key==27:return
        if key==curses.KEY_UP:index=(index-1)%len(keys)
        elif key==curses.KEY_DOWN:index=(index+1)%len(keys)
        elif key in (10,13,curses.KEY_ENTER):apply(name,preset(keys[index]));return
