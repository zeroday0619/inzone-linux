"""Persistent per-profile DSP options and reversible WirePlumber configuration rendering."""
import copy
import json
import math
import os
import re
from pathlib import Path
from build_graph import build, GAME
PROFILES=('fps','music','voice','balanced','surround')
FREQUENCIES=(31.5,63,125,250,500,1000,2000,4000,8000,16000)
# Original Amplifier::SetParameters powf(10, float(db / 20)), measured from DLL.
ATTENUATE=float.fromhex('0x1.01d3f4p-3')
RECOVER=float.fromhex('0x1.fc5ebcp+2')
DEFAULT={'drc':0,'output_alc':False,'mic_agc':False,'hrtf':'standard','eq':[0.0]*10,'eq_enable':False,'sound_mode':'standard','base_eq':True}

def validate(value):
    if not isinstance(value,dict) or set(value)-set(PROFILES):raise ValueError('잘못된 프로파일 설정')
    result={}
    for name,options in value.items():
        if not isinstance(options,dict) or set(options)-set(DEFAULT):raise ValueError('알 수 없는 DSP 설정')
        o=copy.deepcopy(DEFAULT);o.update(options)
        if type(o['drc']) is not int or o['drc'] not in (0,1,2):raise ValueError('DRC 범위: 0–2')
        if any(type(o[k]) is not bool for k in ('output_alc','mic_agc','eq_enable','base_eq')):raise ValueError('자동 게인 값은 boolean이어야 합니다')
        if o['hrtf'] not in ('standard','personal'):raise ValueError('잘못된 HRTF 선택')
        if o['sound_mode'] not in ('standard','immersive'):raise ValueError('음장 모드: standard / immersive')
        eq=o['eq']
        if not isinstance(eq,list) or len(eq)!=10 or any(type(v) not in (int,float) or not math.isfinite(v) or not -12<=v<=12 or not float(v).is_integer() for v in eq):raise ValueError('EQ: 10개 대역, 각각 −12~+12 dB, 1 dB 간격')
        result[name]=o
    return result

def load(home):
    p=Path(home)/'.config/inzone-h9-ii/profile-settings.json'
    return validate(json.loads(p.read_text())) if p.exists() else {}

def options(home,name):return copy.deepcopy(load(home).get(name,DEFAULT))

def save(home,value):
    value=validate(value);p=Path(home)/'.config/inzone-h9-ii/profile-settings.json'
    tmp=p.with_suffix('.tmp');tmp.write_text(json.dumps(value,ensure_ascii=False,indent=2)+'\n');tmp.chmod(0o600);tmp.replace(p)

def add_stereo_dynamics(graph,plugin,o):
    """Expand an existing one-channel EQ for stereo, then append linked DSP ports."""
    if len(graph['inputs'])!=1 or len(graph['outputs'])!=1:raise ValueError('기존 EQ는 mono 그래프여야 합니다')
    nodes=[];links=[];inputs=[];outputs=[]
    for ear in ('L','R'):
        prefix=ear+'_'
        for node in graph['nodes']:
            n=copy.deepcopy(node);n['name']=prefix+n['name'];nodes.append(n)
        links.extend({'output':prefix+l['output'],'input':prefix+l['input']} for l in graph['links'])
        inputs.append(prefix+graph['inputs'][0]);previous=prefix+graph['outputs'][0]
        outputs.append(previous)
    def link(a,b):links.append(dict(output=a,input=b))
    if o['output_alc']:
        nodes.append(dict(type='ladspa',name='output_alc',plugin=str(plugin),label='inzone_alc',control={'Enable':1,'Threshold':-18,'Ratio':1000,'Attack':.001,'Release':1}))
        for i,ear in enumerate(('L','R')):
            for stage,gain in (('recover',RECOVER),):
                nodes.append(dict(type='builtin',name=stage+ear,label='linear',control={'Mult':gain,'Add':0}))
            link(outputs[i],'output_alc:Input '+ear)
            link('output_alc:Output '+ear,'recover'+ear+':In');outputs[i]='recover'+ear+':Out'
    if o['drc']:
        nodes.append(dict(type='ladspa',name='game_drc',plugin=str(plugin),label='inzone_drc',control={'Mode':o['drc']}))
        for i,ear in enumerate(('L','R')):link(outputs[i],'game_drc:Input '+ear);outputs[i]='game_drc:Output '+ear
    return dict(nodes=nodes,links=links,inputs=inputs,outputs=outputs)

def add_mono_eq(graph,plugin,o):
    graph=copy.deepcopy(graph)
    if not (o['eq_enable'] or any(o['eq'])):return graph
    table=json.loads((Path(__file__).resolve().parents[1]/'assets/sony-eq-tables.json').read_text())['tables']
    bands=('31_5','63','125','250','500','1000','2000','4000','8000','16000')
    previous=graph['outputs'][0]
    for index,gain in enumerate(o['eq']):
        name='custom'+str(index);coefficients=table[bands[index]][12-int(gain)][2:]
        graph['nodes'].append(dict(type='ladspa',name=name,plugin=plugin,label='inzone_eq_biquad',control=dict(zip(('b0','b1','b2','a1','a2'),coefficients))))
        graph['links'].append(dict(output=previous,input=name+':Input'));previous=name+':Output'
    graph['outputs']=[previous]
    return graph

def immersive_graph(plugin):
    from sony_presets import bank
    rows=bank()['immersive_coefficients'];graph=identity();previous=graph['outputs'][0]
    for i,row in enumerate(rows):
        name='immersive'+str(i)
        graph['nodes'].append(dict(type='ladspa',name=name,plugin=plugin,label='inzone_eq_biquad',control=dict(zip(('b0','b1','b2','a1','a2'),row))))
        graph['links'].append(dict(output=previous,input=name+':Input'));previous=name+':Output'
    graph['outputs']=[previous]
    return graph

def attenuate_graph():
    return {'nodes':[dict(type='builtin',name='sony_amp1',label='linear',control={'Mult':ATTENUATE,'Add':0})],'links':[],'inputs':['sony_amp1:In'],'outputs':['sony_amp1:Out']}

def identity():return {'nodes':[dict(type='builtin',name='copy',label='copy')],'links':[],'inputs':['copy:In'],'outputs':['copy:Out']}

def render(home,name,text):
    if name not in PROFILES:return text
    home=Path(home);o=options(home,name);library=home/'.local/lib/ladspa/inzone_dsp.so'
    config=json.loads('\n'.join(l for l in text.splitlines() if not l.lstrip().startswith('#')))
    if name=='surround':
        assets=home/'.local/share/inzone-linux'/('personal' if o['hrtf']=='personal' else 'assets')
        if not (assets/'manifest.json').is_file():raise ValueError('개인화 필터를 먼저 가져오세요')
        graph=build(assets,library)
        config['wireplumber.profiles']={'main':{'node.software-dsp':'required'}}
        config['node.software-dsp.rules']=[{'matches':[{'node.name':GAME}],'actions':{'create-filter':{'filter-graph':json.dumps(graph),'hide-parent':False}}}]
    plugin_manifest=home/'.local/share/inzone-linux/assets/plugin.json'
    daemon_plugin=json.loads(plugin_manifest.read_text())['name'] if plugin_manifest.exists() else 'inzone_dsp'
    if not re.fullmatch(r'inzone_dsp(?:_[a-f0-9]{16})?',daemon_plugin):raise ValueError('잘못된 플러그인 이름')
    rules=config.setdefault('node.filter-graph.rules',[])
    target='alsa_output.usb-Sony_INZONE_H9_II-00.stereo-chat' if name=='voice' else GAME
    # Hub sound effects belong to Game. The Linux voice profile targets Chat.
    for rule in rules:
        for match in rule['matches']:
            if 'alsa_output' in match.get('node.name',''):match['node.name']=target
    if not o['base_eq']:
        for rule in rules:
            if any('alsa_output' in m.get('node.name','') for m in rule['matches']):rule['actions']['create-filter-graph']=[json.dumps(identity())]
    for category,enabled in (('output',o['output_alc'] or o['drc'] or o['eq_enable'] or any(o['eq']) or o['sound_mode']=='immersive'),('input',o['mic_agc'])):
        if not enabled:continue
        matching=[r for r in rules if any('alsa_'+category in m.get('node.name','') for m in r['matches'])]
        if not matching:
            r={'matches':[{'node.name':target if category=='output' else '~alsa_input[.]usb-Sony_INZONE_H9_II-00[.].*'}],'actions':{'create-filter-graph':[json.dumps(identity())]}}
            rules.append(r);matching=[r]
        for r in matching:
            graphs=r['actions']['create-filter-graph']
            if len(graphs)!=1:raise ValueError('지원하지 않는 기존 DSP 그래프')
            g=json.loads(graphs[0])
            if category=='output':
                # Audioconvert replicates this mono EQ for both output channels.
                # Keep stereo dynamics in the next graph, avoiding duplicate EQ controls.
                rendered=[g]
                if o['output_alc']:rendered.append(attenuate_graph())
                if o['sound_mode']=='immersive':rendered.append(immersive_graph(daemon_plugin))
                if o['eq_enable'] or any(o['eq']):rendered.append(add_mono_eq(identity(),daemon_plugin,o))
                if o['output_alc'] or o['drc']:rendered.append(add_stereo_dynamics(identity(),daemon_plugin,o))
                # PipeWire 1.6.8 runs higher filter-graph indices first.
                encoded=[json.dumps(item,separators=(',',':')) for item in reversed(rendered)]
                # parse_prop_params copies each value into a 4096-byte buffer.
                if len(encoded)>8 or any(len(g.encode('utf-8'))>=4096 for g in encoded):raise ValueError('PipeWire 인라인 그래프 크기 제한을 초과했습니다')
                r['actions']['create-filter-graph']=encoded
                continue
            else:
                g['nodes'].append(dict(type='ladspa',name='mic_agc',plugin=daemon_plugin,label='inzone_mic_agc',control={'Enable':1}))
                g['links'].append(dict(output=g['outputs'][0],input='mic_agc:Input'));g['outputs']=['mic_agc:Output']
            r['actions']['create-filter-graph']=[json.dumps(g)]
    return '# INZONE profile: '+name+'\n'+json.dumps(config,ensure_ascii=False,indent=2)+'\n'
