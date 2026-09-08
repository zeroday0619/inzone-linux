"""Exercise all channels on a separate PipeWire core, without headset/hardware access."""
import array
import json
import os
from pathlib import Path
import signal
import math
import random
import struct
import subprocess as sp
import sys
import tempfile
import time
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'src'))
from build_graph import build
from sony_filters import CHANNELS
ROOT=Path(__file__).resolve().parents[1]

def main():
    processes=[]
    with tempfile.TemporaryDirectory(prefix='inzone-dsp-test-') as tmp:
        tmp=Path(tmp)
        env=dict(os.environ,PIPEWIRE_RUNTIME_DIR=str(tmp),XDG_RUNTIME_DIR=str(tmp),PIPEWIRE_REMOTE='inzone-test')
        graph=build(ROOT/'assets')
        graph['playback.props'].pop('target.object')
        graph['playback.props']['node.passive']=False
        graph['playback.props']['node.always-process']=True
        config={
          'context.properties':{'core.daemon':True,'core.name':'inzone-test','default.clock.rate':48000,'default.clock.quantum':256},
          'context.spa-libs':{'audio.convert.*':'audioconvert/libspa-audioconvert','support.*':'support/libspa-support'},
          'context.modules':[{'name':'libpipewire-module-'+m} for m in ('protocol-native','access','metadata','spa-node-factory','client-node','adapter','link-factory')]+[{'name':'libpipewire-module-filter-chain','args':graph}],
          'context.objects':[{'factory':'spa-node-factory','args':{'factory.name':'support.node.driver','node.name':'Dummy-Driver','node.group':'pipewire.dummy','priority.driver':200000}}]}
        def spa(value):
            if isinstance(value,dict):return '{ '+ ' '.join(json.dumps(k)+' = '+spa(v) for k,v in value.items())+' }'
            if isinstance(value,list):return '[ '+' '.join(spa(v) for v in value)+' ]'
            return json.dumps(value,ensure_ascii=False)
        (tmp/'server.conf').write_text('\n'.join(k+' = '+spa(v) for k,v in config.items()))
        log=(ROOT/'analysis/pipewire-impulse.log').open('w')
        def start(args,**kwargs):
            p=sp.Popen(args,env=env,stderr=log,**kwargs);processes.append(p);return p
        def run(*args):return sp.check_output(args,env=env,text=True,stderr=log,timeout=8)
        def wait_for(predicate):
            for _ in range(100):
                if predicate():return
                time.sleep(.05)
            (ROOT/'analysis/test-dump.json').write_text(run('pw-dump'))
            raise RuntimeError('Timed out waiting for isolated graph')
        try:
            daemon=start(['pipewire','-c',str(tmp/'server.conf')])
            wait_for(lambda:(tmp/'inzone-test').exists() or daemon.poll() is not None)
            if daemon.poll() is not None:raise RuntimeError('Test server failed to start')
            # Eight distinct impulses, one channel every 4096 samples, after one second silence.
            frames=48000+8*4096+96000
            samples=array.array('f',[0])*(frames*8)
            for index in range(8):samples[(48000+index*4096)*8+index]=0.125
            rng=random.Random(2987)
            start_signal=48000+8*4096
            for i in range(48000):
                level=(.05,.4,2.,.1)[i//12000]
                for ch in range(8):samples[(start_signal+i)*8+ch]=level*rng.uniform(-1,1)
            (tmp/'input.raw').write_bytes(samples.tobytes())
            record=(tmp/'output.raw').open('wb')
            rec=start(['pw-cat','-r','--raw','--format','f32','--rate','48000','--channels','2','--target','0','--latency','256','-P','{ node.name = test-record node.always-process = true }','-'],stdout=record)
            player=start(['pw-cat','-p','--raw','--format','f32','--rate','48000','--channels','8','--channel-map',','.join(CHANNELS),'--target','0','--latency','256','-P','{ node.name = test-play }',str(tmp/'input.raw')])
            wait_for(lambda:any(n.get('info',{}).get('props',{}).get('node.name')=='test-play' for n in json.loads(run('pw-dump'))))
            for n in json.loads(run('pw-dump')):
                if n['type']!='PipeWire:Interface:Node':continue
                name=n['info']['props'].get('node.name')
                if name not in ('test-play','test-record','inzone.sony-surround','inzone.sony-surround.output'):continue
                direction='Output' if name in ('test-play','inzone.sony-surround.output') else 'Input'
                positions=list(CHANNELS) if name in ('test-play','inzone.sony-surround') else ['FL','FR']
                param={'direction':direction,'mode':'dsp','format':{'mediaType':'audio','mediaSubtype':'raw','format':'F32P','rate':48000,'channels':len(positions),'position':positions}}
                run('pw-cli','set-param',str(n['id']),'PortConfig',json.dumps(param))
            wait_for(lambda:'test-record' in run('pw-link','-i') and 'test-play' in run('pw-link','-o'))
            for ch in ('FL','FR'):run('pw-link',f'inzone.sony-surround.output:output_{ch}',f'test-record:input_{ch}')
            for ch in CHANNELS:run('pw-link',f'test-play:output_{ch}',f'inzone.sony-surround:playback_{ch}')
            player.wait(timeout=12)
            time.sleep(.2)
            rec.send_signal(signal.SIGINT);rec.wait(timeout=3);record.close()
            values=array.array('f');values.frombytes((tmp/'output.raw').read_bytes())
            if not values or max(map(abs,values))<1e-5:raise AssertionError('No output from graph')
            # Independently check eight audible DSP responses, finite limiting,
            # and recovery into silence. No external implementation is used.
            assert all(math.isfinite(v) for v in values)
            first=next(i for i,v in enumerate(values[::2]) if abs(v)>1e-5)
            peaks=[]
            for index in range(8):
                start=max(0,first+index*4096-128);end=first+index*4096+2048
                segment=values[start*2:end*2]
                peaks.append(max(map(abs,segment)))
            assert all(v>1e-5 for v in peaks),peaks
            peak=max(map(abs,values));assert peak<=1.000001,peak
            tail=max(map(abs,values[-24000:]));assert tail<1e-5,tail
            result={'samples':len(values),'channel_impulse_peaks':peaks,'peak':peak,'silence_tail_peak':tail,'checks':'finite output, eight channel responses, ALC bound and silence recovery'}
            (ROOT/'analysis/impulse-results.json').write_text(json.dumps(result,indent=2)+'\n')
            print('PASS: Linux PipeWire spatial processing:',result)
        finally:
            for p in reversed(processes):
                if p.poll() is None:
                    p.terminate()
                    try:p.wait(timeout=3)
                    except sp.TimeoutExpired:p.kill();p.wait()
            log.close()

if __name__=='__main__':main()
