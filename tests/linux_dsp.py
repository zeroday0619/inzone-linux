"""Linux-only LADSPA graph runner and deterministic stress signals."""
import array,copy,ctypes as c,json,math,random,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'src'))
from sony_presets import preset,LABELS
from test_dsp import Descriptor

def stress_signal():
    rng=random.Random(2987);samples=array.array('f')
    for level in (0,1e-5,1e-4,.001,.01,.1,.5,1,2,.1,0):
        for i in range(24000):samples.extend((level*math.sin(i*.1309),level*.7*math.sin(i*.0471)))
    for i in range(48000):samples.extend((rng.uniform(-1,1)*.9,rng.uniform(-1,1)*.08))
    for i in range(48000):samples.extend((1.5 if i%4096==0 else 0,-.9 if i%5000==0 else 0))
    return samples

def execute(graph,data,lib):
    """Execute the rendered graph topology through real LADSPA descriptors."""
    source=[array.array('f',channel) for channel in data];last={}
    graph=copy.deepcopy(graph)
    streams=len(source)//len(graph['inputs'])
    if len(source)%len(graph['inputs']):raise ValueError('Channel count')
    result=[]
    for stream in range(streams):
        values={port:source[stream*len(graph['inputs'])+i] for i,port in enumerate(graph['inputs'])}
        pending={node['name']:node for node in graph['nodes']};done=set()
        while pending:
            progress=False
            for name,node in list(pending.items()):
                for link in graph['links']:
                    if link['output'] in values:values[link['input']]=values[link['output']]
                if node['type']=='builtin':
                    port=name+':In'
                    if port not in values:continue
                    x=values[port]
                    if node['label']=='copy':y=array.array('f',x)
                    elif node['label']=='linear':
                        mult=c.c_float(node['control']['Mult']).value;add=c.c_float(node['control']['Add']).value
                        y=array.array('f',(c.c_float(v*mult).value+add for v in x))
                    else:raise ValueError(node['label'])
                    values[name+':Out']=y
                else:
                    index={'inzone_eq_biquad':5,'inzone_alc':2,'inzone_drc':1}[node['label']]
                    pointer=lib.ladspa_descriptor(index);d=pointer.contents
                    names=c.cast(d.names,c.POINTER(c.c_char_p));flags=c.cast(d.ports,c.POINTER(c.c_int))
                    inputs=[i for i in range(d.count) if flags[i]&8 and flags[i]&1]
                    if any(name+':'+names[i].decode() not in values for i in inputs):continue
                    outputs=[i for i in range(d.count) if flags[i]&8 and flags[i]&2]
                    h=d.instantiate(pointer,48000);assert h
                    controls=[];buffers={}
                    for i in range(d.count):
                        if flags[i]&4:
                            v=c.c_float(node['control'].get(names[i].decode(),0));controls.append(v);d.connect(h,i,c.pointer(v))
                    for i in inputs:buffers[i]=values[name+':'+names[i].decode()]
                    for i in outputs:buffers[i]=array.array('f',[0])*len(source[0])
                    d.activate(h)
                    try:
                        offset=0;block=0
                        while offset<len(source[0]):
                            n=min((1,3,7,8,127,256,513)[block%7],len(source[0])-offset);views=[]
                            for i,buffer in buffers.items():
                                view=(c.c_float*n).from_buffer(buffer,offset*4);views.append(view);d.connect(h,i,view)
                            d.run(h,n);offset+=n;block+=1
                    finally:d.cleanup(h)
                    for i in outputs:values[name+':'+names[i].decode()]=buffers[i]
                pending.pop(name);done.add(name);progress=True
            if not progress:raise RuntimeError('Unresolved graph dependencies: '+str(pending))
        result.extend(values[port] for port in graph['outputs'])
    return result

def cases():
    items=[]
    for name in LABELS:
        for drc in (0,1,2):
            o=preset(name);o['drc']=drc;items.append((name+'-drc'+str(drc),o))
    for mode in ('standard','immersive'):
        for alc in (False,True):
            for drc in (0,1,2):
                o={'base_eq':False,'sound_mode':mode,'eq':[12,-12,6,-6,3,-3,10,-10,1,-1],'eq_enable':True,'output_alc':alc,'drc':drc}
                items.append(('custom-'+mode+'-alc'+str(alc)+'-drc'+str(drc),o))
    return items
