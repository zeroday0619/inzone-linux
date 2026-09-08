"""H9 II HID control, reconstructed from INZONE Hub's HCI packet classes."""
from dataclasses import dataclass
import fcntl
import json
import os
from pathlib import Path
import secrets
import select
import struct
import time
VID_PID='0003:0000054C:00000FA8'
# name: (event ID, minimum payload length); RX except dongle connection status.
EVENTS={'connection':(1,1),'model':(2,6),'firmware':(3,8),'battery':(4,2),'headphone':(33,3),'balance':(34,1),'sidetone':(35,2),'microphone':(36,3),'ambient':(65,4),'nc_toggle':(66,3),'nc_startup':(67,1),'bluetooth':(97,2),'bt_startup':(99,1),'auto_power':(129,2),'language':(131,1),'guidance':(132,1),'mic_attached':(143,1)}
@dataclass(frozen=True)
class Field:
    event:str
    index:int
    values:tuple
    label:str
    labels:tuple=()
FIELDS={
 'anc':Field('ambient',0,(0,1,2),'소음 제어',('끔','노이즈 캔슬링','주변 소리')),
 'ambient_level':Field('ambient',1,tuple(range(1,21)),'주변 소리 크기'),
 'voice_focus':Field('ambient',3,(0,1),'주변 소리 음성 집중',('끔','켬')),
 'game_chat':Field('balance',0,tuple(range(101)),'게임/채팅 균형 (50: 중앙)'),
 'sidetone':Field('sidetone',0,tuple(range(11)),'내 목소리 듣기'),
 'toggle_off':Field('nc_toggle',0,(0,1),'버튼 전환: 소음 제어 끔',('제외','포함')),
 'toggle_nc':Field('nc_toggle',1,(0,1),'버튼 전환: NC',('제외','포함')),
 'toggle_ambient':Field('nc_toggle',2,(0,1),'버튼 전환: 주변 소리',('제외','포함')),
 'nc_startup':Field('nc_startup',0,(0,1,2,3),'전원을 켰을 때 소음 제어',('끔','NC','주변 소리','이전 상태')),
 'bt_startup':Field('bt_startup',0,(0,1,2),'전원을 켰을 때 Bluetooth',('끔','켬','이전 상태')),
 'auto_power':Field('auto_power',0,(0,5,15,30,60,180),'자동 전원 끄기 (분, 0: 해제)'),
 'language':Field('language',0,(0,1,2),'음성 안내 언어',('영어','일본어','중국어')),
 'guidance':Field('guidance',0,(0,1),'음성 안내·알림음',('끔','켬')),
}

def discover():
    result=[]
    for p in Path('/sys/class/hidraw').glob('hidraw*'):
        try:
            fields=dict(line.split('=',1) for line in (p/'device/uevent').read_text().splitlines() if '=' in line)
            if fields.get('HID_ID','').upper()==VID_PID:result.append(Path('/dev')/p.name)
        except OSError:continue
    if len(result)!=1:raise RuntimeError('H9 II USB 동글을 하나 연결하세요')
    return result[0]

def command(event,kind,sequence,payload=b''):
    if event not in {v[0] for v in EVENTS.values()} or kind not in (1,2):raise ValueError('지원하지 않는 H9 II 명령')
    if len(payload)>50 or not 1<=sequence<=65535:raise ValueError('잘못된 명령 길이/번호')
    address=0x21 if event==1 else 0x41
    packet=bytearray(struct.pack('<BHBHBBBH',1,0xfc00,8+len(payload),0xc396,address,event,kind,sequence)+payload+b'\0')
    packet[-1]=sum(packet[4:-1])&255
    return bytes((2,len(packet)))+packet+bytes(62-len(packet))

def parse_packet(packet):
    if len(packet)<12 or packet[0:2]!=b'\x04\xff' or len(packet)!=packet[2]+3 or packet[3]!=0:raise ValueError('잘못된 HCI 응답 길이')
    if sum(packet[3:-1])&255!=packet[-1]:raise ValueError('HCI 체크섬 오류')
    if packet[4:6]!=b'\x96\xc3' or packet[6] not in (0x12,0x14) or packet[8] not in (0x10,0x20,0xa0):raise ValueError('잘못된 Sony HCI 응답')
    return dict(event=packet[7],kind=packet[8],sequence=int.from_bytes(packet[9:11],'little'),source=packet[6]&15,payload=packet[11:-1])

class Device:
    def __init__(self):self.fd=None;self.lock=None;self.buffer=bytearray();self.sequence=secrets.randbelow(65534)+1
    def __enter__(self):
        lockpath=Path.home()/'.config/inzone-h9-ii/device.lock';lockpath.parent.mkdir(parents=True,exist_ok=True)
        self.lock=lockpath.open('a')
        try:
            fcntl.flock(self.lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
            self.fd=os.open(discover(),os.O_RDWR|os.O_NONBLOCK|os.O_CLOEXEC)
            return self
        except Exception:self.__exit__(None,None,None);raise
    def __exit__(self,*args):
        if self.fd is not None:os.close(self.fd);self.fd=None
        if self.lock:self.lock.close();self.lock=None
    def transact(self,name,kind=1,payload=b'',timeout=1.5):
        event,minimum=EVENTS[name];self.sequence=self.sequence%65535+1;sequence=self.sequence
        report=command(event,kind,sequence,payload)
        if os.write(self.fd,report)!=len(report):raise OSError('HID 명령 전송이 짧게 끝났습니다')
        deadline=time.monotonic()+timeout;parts=bytearray()
        while time.monotonic()<deadline:
            if not select.select([self.fd],[],[],max(0,deadline-time.monotonic()))[0]:break
            report=os.read(self.fd,4096)
            if not report:raise OSError('H9 II USB 연결이 끊겼습니다')
            if report[0]!=2:continue
            if len(report)<2 or report[1]>62 or len(report)<report[1]+2:raise ValueError('잘못된 HID 보고서')
            self.buffer.extend(report[2:2+report[1]])
            if len(self.buffer)>2048:self.buffer.clear();raise ValueError('HID 응답 크기 초과')
            while len(self.buffer)>=3:
                if self.buffer[0:2]!=b'\x04\xff':self.buffer.clear();break
                size=self.buffer[2]+3
                if len(self.buffer)<size:break
                raw=bytes(self.buffer[:size]);del self.buffer[:size]
                response=parse_packet(raw)
                if response['event']!=event or response['sequence']!=sequence or response['source']!=(2 if event==1 else 4):continue
                if response['kind'] not in ((0x10,) if kind==1 else (0x10,0x20)):continue
                parts.extend(response['payload'])
                if len(parts)>1024:raise ValueError('명령 응답 크기 초과')
                if len(response['payload'])<50:
                    if len(parts)<minimum:raise ValueError('장치가 불완전한 파라미터를 반환했습니다')
                    return bytes(parts)
        raise TimeoutError('H9 II 응답 없음: '+name)
    def get(self,name):return self.transact(name)
    def snapshot(self):
        data={'connection':list(self.get('connection'))}
        if data['connection'][0]!=1:return {'connected':False,'raw':data}
        for name in EVENTS:
            if name=='connection':continue
            try:data[name]=list(self.get(name))
            except TimeoutError:data[name]=None
        return describe(data)
    def set_field(self,name,value):
        field=FIELDS[name]
        if type(value) is not int or value not in field.values:raise ValueError('설정 값 범위 초과')
        payload=bytearray(self.get(field.event))
        if payload[field.index]==value:return bytes(payload)
        payload[field.index]=value
        if field.event=='nc_toggle' and sum(payload[:3])<2:raise ValueError('버튼 전환에는 두 가지 이상을 포함하세요')
        if field.event=='auto_power' and value:payload[1]=value
        # Native UI adjusts the value field while preserving the other parameters.
        self.transact(field.event,2,bytes(payload))
        observed=self.get(field.event)
        if observed[field.index]!=value:raise RuntimeError('장치가 요청한 값을 적용하지 않았습니다')
        return observed

def describe(data):
    result={'connected':True,'fields':{}}
    for name,field in FIELDS.items():
        p=data.get(field.event)
        if p and len(p)>field.index:result['fields'][name]=p[field.index]
    if data.get('battery'):
        state,percent=data['battery'][:2]
        result['battery']={'percent':percent if percent<=100 else None,'state':{0:'discharging',1:'charging',2:'error'}.get(state,'unknown')}
    if data.get('firmware'):
        values=struct.unpack('<II',bytes(data['firmware'][:8]))
        result['firmware']=dict(zip(('headset','dongle'),(f'{v&255:02}.{(v>>8)&4095:03}.{v>>20:03}' for v in values)))
    if data.get('microphone'):result['microphone_muted']=data['microphone'][0]==1
    if data.get('mic_attached'):result['microphone_attached']=data['mic_attached'][0]==0
    if data.get('bluetooth'):result['bluetooth']=data['bluetooth']
    # Serial/model-identifying bytes are deliberately excluded from display/export.
    return result

if __name__=='__main__':
    with Device() as device:print(json.dumps(device.snapshot(),ensure_ascii=False,indent=2))
