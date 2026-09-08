"""Drive 24x80 curses screens without applying settings or changing device values."""
import fcntl,json,os,pty,select,signal,struct,termios,time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
pid,fd=pty.fork()
if pid==0:
    fcntl.ioctl(0,termios.TIOCSWINSZ,struct.pack('HHHH',24,80,0,0))
    os.environ.update(TERM='xterm-256color',LANG='C.UTF-8')
    os.execv(str(Path.home()/'.local/bin/inzone-profile'),['inzone-profile','--tui'])
out=bytearray();status=None
try:
    def drain(seconds):
        end=time.monotonic()+seconds
        while time.monotonic()<end:
            if select.select([fd],[],[],max(0,end-time.monotonic()))[0]:
                try:b=os.read(fd,65536)
                except OSError:return
                if not b:return
                out.extend(b)
    drain(1)
    for key in (b'S',b'\x1b',b'E',b'\x1b',b'U',b'\x1b',b'H',b'R',b'\x1b',b'I',b'\n',b'L',b'Q'):
        os.write(fd,key);drain(1.5)
    done,status=os.waitpid(pid,os.WNOHANG)
    if done!=pid:raise AssertionError('TUI did not exit')
    assert os.waitstatus_to_exitcode(status)==0,status
    for token in ('Sony EQ','10-band EQ','자동 프로파일','INZONE H9 II / 장치 설정','개인화 HKI 파일 경로'):
        assert token.encode() in out,token
    assert '로그인'.encode() not in out
    assert b'Traceback' not in out
    assert b'Invalid non-ASCII character' not in out, 'pactl diagnostics leaked into the TUI'
    (ROOT/'analysis/tui-session.txt').write_bytes(out)
    (ROOT/'analysis/tui-results.json').write_text(json.dumps({'terminal':[24,80],'screens':['profiles','Sony presets','EQ editor','automation','hardware','local HRTF import'],'applied_changes':False,'exit_code':0},indent=2)+'\n')
    print('PASS: 24x80 TUI screens, uppercase keys, cancel and exit')
finally:
    if status is None:
        try:os.kill(pid,signal.SIGTERM);os.waitpid(pid,0)
        except ProcessLookupError:pass
    os.close(fd)
