"""Run rendered SFX through real PipeWire audioconvert graphs on a private core.
Connect only test streams. The desktop session and all physical devices are absent.
"""
import array,ctypes as c,json,math,os,signal,subprocess as sp,sys,tempfile,time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'src'))
import inzone_settings as settings
from linux_dsp import cases,execute,stress_signal,Descriptor

def spa(value):
    if isinstance(value,dict):return '{ '+' '.join(json.dumps(k)+' = '+spa(v) for k,v in value.items())+' }'
    if isinstance(value,list):return '[ '+' '.join(spa(v) for v in value)+' ]'
    return json.dumps(value)

def main():
    results=[];items=cases();signal_data=stress_signal()
    library=c.CDLL(str(ROOT/'native/inzone_dsp.so'));library.ladspa_descriptor.argtypes=[c.c_ulong];library.ladspa_descriptor.restype=c.POINTER(Descriptor)
    for index in ([int(x) for x in sys.argv[1:]] or (3,18,32)):
        name,options=items[index];processes=[]
        with tempfile.TemporaryDirectory(prefix='inzone-inline-') as folder:
            root=Path(folder);(root/'.config/inzone-h9-ii').mkdir(parents=True)
            (root/'input.f32').write_bytes(signal_data.tobytes())
            settings.save(root,{'balanced':options})
            config=json.loads('\n'.join(settings.render(root,'balanced',(ROOT/'configs/balanced.conf').read_text()).splitlines()[1:]))
            graphs=config['node.filter-graph.rules'][0]['actions']['create-filter-graph']
            # Inline LADSPA uses trusted system search paths, just as real sinks do.
            installed=json.loads((Path.home()/'.local/share/inzone-linux/assets/plugin.json').read_text())['name']
            graphs=[g.replace('"plugin":"inzone_dsp"','"plugin":"'+installed+'"') for g in graphs]
            env=dict(os.environ,PIPEWIRE_RUNTIME_DIR=str(root),XDG_RUNTIME_DIR=str(root),PIPEWIRE_REMOTE='inzone-sfx')
            server={
                'context.properties':{'core.daemon':True,'core.name':'inzone-sfx','default.clock.rate':48000,'default.clock.quantum':256},
                'context.spa-libs':{'audio.convert.*':'audioconvert/libspa-audioconvert','support.*':'support/libspa-support'},
                'context.modules':[{'name':'libpipewire-module-'+m} for m in ('protocol-native','access','metadata','spa-node-factory','client-node','adapter','link-factory')],
                'context.objects':[{'factory':'spa-node-factory','args':{'factory.name':'support.node.driver','node.name':'Dummy-Driver','node.group':'pipewire.dummy','priority.driver':200000}}]}
            (root/'server.conf').write_text('\n'.join(k+' = '+spa(v) for k,v in server.items()))
            with (ROOT/'analysis'/('pipewire-sfx-'+str(index)+'.log')).open('w') as log:
                def start(args,**kwargs):
                    p=sp.Popen(args,env=env,stderr=log,**kwargs);processes.append(p);return p
                def run(*args):return sp.check_output(args,env=env,text=True,stderr=log,timeout=8)
                def wait_for(predicate):
                    for _ in range(120):
                        if predicate():return
                        time.sleep(.05)
                    raise RuntimeError('Timed out waiting for '+name)
                try:
                    daemon=start(['pipewire','-c',str(root/'server.conf')])
                    wait_for(lambda:(root/'inzone-sfx').exists() or daemon.poll() is not None)
                    if daemon.poll() is not None:raise RuntimeError('Test server failed')
                    with (root/'output.raw').open('wb') as out:
                        record=start(['pw-cat','-r','--raw','--format','f32','--rate','48000','--channels','2','--target','0','--latency','256','-P','{ node.name = test-record node.always-process = true }','-'],stdout=out)
                        player=start(['pw-cat','-p','--raw','--format','f32','--rate','48000','--channels','2','--target','0','--latency','256','-P','{ node.name = test-play }',str(root/'input.f32')])
                        def nodes():return {n['info']['props']['node.name']:n for n in json.loads(run('pw-dump')) if n['type']=='PipeWire:Interface:Node'}
                        wait_for(lambda:'test-play' in nodes() and 'test-record' in nodes())
                        snapshot=nodes();player_id=snapshot['test-play']['id']
                        params=[]
                        for i,g in enumerate(graphs):params.extend(['audioconvert.filter-graph.'+str(i),g])
                        run('pw-cli','set-param',str(player_id),'Props',json.dumps({'params':params}))
                        for node in ('test-record','test-play'):
                            param={'direction':'Output' if node=='test-play' else 'Input','mode':'dsp','format':{'mediaType':'audio','mediaSubtype':'raw','format':'F32P','rate':48000,'channels':2,'position':['FL','FR']}}
                            run('pw-cli','set-param',str(snapshot[node]['id']),'PortConfig',json.dumps(param))
                        wait_for(lambda:'test-record' in run('pw-link','-i') and 'test-play' in run('pw-link','-o'))
                        for ch in ('FL','FR'):run('pw-link',f'test-play:output_{ch}',f'test-record:input_{ch}')
                        # Props prove the real audioconvert loader instantiated every stage.
                        time.sleep(.1);props=run('pw-cli','enum-params',str(player_id),'Props')
                        for required in ('sony_amp1:','custom9:','output_alc:'):
                            assert required in props,required
                        if options['sound_mode']=='immersive':assert 'immersive9:' in props
                        player.wait(timeout=12);time.sleep(.2)
                        record.send_signal(signal.SIGINT);record.wait(timeout=3)
                    actual=array.array('f');actual.frombytes((root/'output.raw').read_bytes())
                    (ROOT/f'analysis/pipewire-sfx-{index}.f32').write_bytes(actual.tobytes())
                    (ROOT/f'analysis/pipewire-sfx-{index}-graphs.json').write_text(json.dumps([json.loads(g) for g in graphs],indent=2))
                    (ROOT/f'analysis/pipewire-sfx-{index}-props.txt').write_text(props)
                    native=[signal_data[::2],signal_data[1::2]]
                    for g in reversed(graphs):native=execute(json.loads(g),native,library)
                    expected=array.array('f',(v for pair in zip(*native) for v in pair))
                    assert actual and all(math.isfinite(x) for x in actual)
                    start_a=next(i for i,x in enumerate(actual[::2]) if abs(x)>1e-12)
                    start_b=next(i for i,x in enumerate(expected[::2]) if abs(x)>1e-12)
                    offset=start_a-start_b
                    observed=actual[2*offset:2*offset+len(expected)] if offset>=0 else actual
                    compare=expected if offset>=0 else expected[-2*offset:]
                    assert len(observed)==len(compare),(len(observed),len(compare),offset)
                    error=max(abs(a-b) for a,b in zip(observed,compare));rms=math.sqrt(sum((a-b)**2 for a,b in zip(observed,compare))/len(compare))
                    result={'case':name,'samples':len(compare),'max_absolute_error':error,'rms_error':rms,'transport_offset_frames':offset}
                    results.append(result)
                    (ROOT/'analysis/pipewire-sfx-results.json').write_text(json.dumps({'baseline':'same Linux LADSPA graph outside PipeWire','pipewire':'real audioconvert.filter-graph.N in isolated stream','cases':results},indent=2)+'\n')
                    print(result,flush=True)
                    assert error<1e-6,result
                finally:
                    for p in reversed(processes):
                        if p.poll() is None:
                            p.terminate()
                            try:p.wait(timeout=3)
                            except sp.TimeoutExpired:p.kill();p.wait()
    print('PASS: three real PipeWire SFX combinations')
if __name__=='__main__':main()
