"""Explicit live integration check; preserves initial profile, options, and output mute."""
import importlib.util,json,os,subprocess as sp,time
from pathlib import Path
BASE=Path.home();ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('selector',BASE/'.local/bin/inzone-profile');module=importlib.util.module_from_spec(spec) if spec else None
# Installed executable has no .py suffix.
from importlib.machinery import SourceFileLoader
if module is None:
    spec=importlib.util.spec_from_loader('selector',SourceFileLoader('selector',str(BASE/'.local/bin/inzone-profile')));module=importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
initial=module.status();initial='restore' if initial=='original' else initial
options=module.settings.load(BASE)
mute=module.run('pactl','get-sink-mute',module.GAME).strip().endswith('yes')
results=[]
try:
    module.run('pactl','set-sink-mute',module.GAME,'1')
    for profile in ('surround','fps','music','voice','balanced','restore'):
        module.activate(profile,quiet=True);results.append({'profile':profile,'result':'loaded and routed'})
    for profile,changes in (('balanced',{'drc':2,'output_alc':True}),('voice',{'mic_agc':True}),('surround',{'drc':1,'output_alc':True,'eq':[0,0,0,0,0,1,0,0,0,0],'sound_mode':'immersive','base_eq':False}),('fps',{'drc':1,'output_alc':True,'eq':[-6,-2,2,3,2,0,2,3,1,-2],'sound_mode':'standard','base_eq':False})):
        print("Checking",profile,changes,flush=True)
        module.change_options(profile,changes)
        target=module.SURROUND if profile=='surround' else module.GAME
        sp.run(['pw-cat','-p','--raw','--format','f32','--rate','48000','--channels','2','--latency','256','--target',target,'-'],input=bytes(4096*8),stdout=sp.DEVNULL,stderr=sp.PIPE,check=True,timeout=8)
        if profile=='voice':
            target='alsa_input.usb-Sony_INZONE_H9_II-00.mono-chat'
            rec=sp.Popen(['pw-cat','-r','--raw','--format','f32','--rate','48000','--channels','1','--target',target,'-'],stdout=sp.DEVNULL,stderr=sp.DEVNULL)
            try:
                time.sleep(.4);node=next(n for n in module.nodes() if n['info']['props']['node.name']==target)
                assert 'mic_agc:' in module.run('pw-cli','enum-params',str(node['id']),'Props')
            finally:rec.terminate();rec.wait(timeout=3)
        else:
            node=next(n for n in module.nodes() if n['info']['props']['node.name']==module.GAME)
            props=module.run('pw-cli','enum-params',str(node['id']),'Props')
            assert 'output_alc:' in props and 'game_drc:' in props
            chat=next(n for n in module.nodes() if n['info']['props']['node.name']==module.CHAT)
            chat_props=module.run('pw-cli','enum-params',str(chat['id']),'Props')
            assert all(key not in chat_props for key in ('output_alc:','game_drc:','custom0:','immersive0:')),chat_props
        results.append({'profile':profile,'settings':changes,'result':'DSP ports verified'})
finally:
    module.settings.save(BASE,options)
    module.activate(initial,quiet=True)
    module.run('pactl','set-sink-mute',module.GAME,'1' if mute else '0')
(ROOT/'analysis/live-profile-results.json').write_text(json.dumps(results,indent=2)+'\n')
print('PASS',len(results),'live profile/DSP checks; restored',initial)
