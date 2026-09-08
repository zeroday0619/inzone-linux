"""Exercise actual process discovery and live switches; restore all saved user state."""
import importlib.machinery,importlib.util,json,os,shutil,subprocess as sp,tempfile,time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1];BASE=Path.home();BIN=BASE/'.local/bin/inzone-profile'
spec=importlib.util.spec_from_loader('selector',importlib.machinery.SourceFileLoader('selector',str(BIN)));m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
import profile_automation as auto
initial=m.status();initial='restore' if initial=='original' else initial
p=auto.file(BASE);old=p.read_bytes() if p.exists() else None
was_active=sp.run(['systemctl','--user','is-active','--quiet',auto.UNIT]).returncode==0
if was_active:raise SystemExit('Stop the existing automation service before running this explicit test')
mute=m.run('pactl','get-sink-mute',m.GAME).strip().endswith('yes')
watch=None;game=None;results=[]
def wait_profile(expected):
    end=time.monotonic()+40
    while time.monotonic()<end:
        if watch and watch.poll() is not None:raise RuntimeError('Watcher exited unexpectedly')
        if m.status()==expected:
            # Active file is written before the restart completes. Wait for its lock.
            import fcntl
            with (m.DATA/'switch.lock').open('w') as lock:fcntl.flock(lock,fcntl.LOCK_EX)
            return
        time.sleep(.25)
    raise AssertionError('Timed out waiting for '+expected+'; actual='+m.status())
try:
    m.run('pactl','set-sink-mute',m.GAME,'1');m.activate('music',quiet=True)
    with tempfile.TemporaryDirectory(prefix='inzone-auto-') as directory:
        executable=Path(directory)/'inzone-test-game';shutil.copy2('/usr/bin/sleep',executable)
        auto.save(BASE,[{'app':str(executable),'profile':'balanced','priority':10}])
        watch=sp.Popen([str(BIN),'--auto-watch'],stdout=sp.PIPE,stderr=sp.STDOUT,text=True)
        time.sleep(1);game=sp.Popen([str(executable),'180'])
        wait_profile('balanced');results.append('game start selects balanced')
        game.terminate();game.wait();game=None
        wait_profile('music');results.append('game exit restores music')
        game=sp.Popen([str(executable),'180']);wait_profile('balanced')
        m.activate('voice',quiet=True);time.sleep(4)
        assert m.status()=='voice';results.append('manual choice remains while game runs')
        game.terminate();game.wait();game=None;time.sleep(4)
        assert m.status()=='voice';results.append('manual baseline survives game exit')
        watch.terminate();out=watch.communicate(timeout=50)[0]
        assert watch.returncode==0,(watch.returncode,out);watch=None
        assert m.status()=='voice';results.append('watcher shutdown preserves manual choice')
finally:
    if game is not None:game.terminate();game.wait(timeout=5)
    if watch is not None:watch.terminate();watch.communicate(timeout=50)
    if old is None:p.unlink(missing_ok=True)
    else:p.write_bytes(old)
    m.activate(initial,quiet=True);m.run('pactl','set-sink-mute',m.GAME,'1' if mute else '0')
(ROOT/'analysis/live-automation-results.json').write_text(json.dumps({'checks':results,'restored_profile':initial},indent=2)+'\n')
print('PASS:',len(results),'live automation checks; restored',initial)
