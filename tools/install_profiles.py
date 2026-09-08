#!/usr/bin/python3
"""Install the local INZONE implementation; run as the desktop user after extraction."""
import argparse
import hashlib
import datetime
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'src'))
from build_graph import build,GAME
from sony_filters import export


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--home',type=Path,default=Path.home())
    parser.add_argument('--payload',type=Path,default=ROOT/'analysis/payload')
    args=parser.parse_args()
    required=[args.payload/name for name in ('inzonevirtualizer.dll','shp_for_game_v2.0_512tap.hki','wh_g910n_standard.ba')]
    required.extend(ROOT/'assets'/name for name in ('sony-eq-tables.json','sony-presets.json'))
    if any(not path.is_file() for path in required):
        raise SystemExit('Assets are missing. Run: python3 tools/fetch_assets.py')
    base=args.home.resolve();data=base/'.config/inzone-h9-ii'
    assets=base/'.local/share/inzone-linux/assets'
    wp=base/'.config/wireplumber/wireplumber.conf.d'
    stamp=datetime.datetime.now().strftime('%Y%m%dT%H%M%S%f')
    backup=base/'.local/state/inzone-linux/backups'/stamp
    for rel in ['.config/wireplumber/wireplumber.conf.d/51-inzone-h9-ii.conf','.local/lib/ladspa/inzone_dsp.so','.local/share/inzone-linux/python','.config/inzone-h9-ii','.local/bin/inzone-profile','.config/wireplumber/wireplumber.conf.d/52-inzone-game-chat.conf','.config/mpv/mpv.conf','.config/systemd/user/inzone-profile-auto.service']:
        src=base/rel
        if src.exists():
            dst=backup/rel;dst.parent.mkdir(parents=True,exist_ok=True)
            if src.is_dir():shutil.copytree(src,dst)
            else:shutil.copy2(src,dst)
    subprocess.run(['make','-C',str(ROOT/'native')],check=True)
    digest=hashlib.sha256((ROOT/'native/inzone_dsp.so').read_bytes()).hexdigest()
    plugin_name='inzone_dsp_'+digest[:16]
    system_library=Path('/usr/lib/ladspa')/(plugin_name+'.so')
    if os.getuid()==0:
        shutil.copy2(ROOT/'configs/udev/70-inzone-h9-ii.rules','/etc/udev/rules.d/70-inzone-h9-ii.rules')
        subprocess.run(['udevadm','control','--reload-rules'],check=True)
        system_library.parent.mkdir(parents=True,exist_ok=True)
        temporary=system_library.with_suffix('.so.tmp');shutil.copy2(ROOT/'native/inzone_dsp.so',temporary);temporary.chmod(0o755);temporary.replace(system_library)
    elif not system_library.exists() or hashlib.sha256(system_library.read_bytes()).hexdigest()!=digest:
        raise SystemExit('Install the trusted daemon plugin first: sudo make -C native install')
    library=base/'.local/lib/ladspa/inzone_dsp.so';library.parent.mkdir(parents=True,exist_ok=True)
    temporary=library.with_suffix('.so.tmp');shutil.copy2(ROOT/'native/inzone_dsp.so',temporary);temporary.replace(library)
    modules=base/'.local/share/inzone-linux/python';modules.mkdir(parents=True,exist_ok=True)
    for module in ('build_graph.py','sony_filters.py','inzone_settings.py','personalization.py','inzone_device.py','device_tui.py','sony_presets.py','profile_automation.py'):
        if (ROOT/'src'/module).exists():shutil.copy2(ROOT/'src'/module,modules/module)
    payload_copy=base/'.local/share/inzone-linux/decoder';payload_copy.mkdir(parents=True,exist_ok=True)
    shutil.copy2(args.payload/'inzonevirtualizer.dll',payload_copy/'inzonevirtualizer.dll')
    # Reject unrecognized assets before touching the live WirePlumber configuration.
    export(args.payload,assets)
    shutil.copy2(ROOT/'assets/sony-eq-tables.json',assets/'sony-eq-tables.json')
    shutil.copy2(ROOT/'assets/sony-presets.json',assets/'sony-presets.json')
    (assets/'plugin.json').write_text(json.dumps({'name':plugin_name,'sha256':digest})+'\n')
    data.mkdir(parents=True,exist_ok=True);wp.mkdir(parents=True,exist_ok=True)
    for name in ['fps','music','voice','balanced','original']:
        dst=data/(name+'.conf')
        if not dst.exists():shutil.copy2(ROOT/'configs'/(name+'.conf'),dst)
    graph=build(assets,library)
    (data/'sony-surround.json').write_text(json.dumps(graph,ensure_ascii=False,indent=2)+'\n')
    config=json.loads('\n'.join(l for l in (data/'balanced.conf').read_text().splitlines() if not l.startswith('#')))
    config['wireplumber.profiles']={'main':{'node.software-dsp':'required'}}
    config['node.software-dsp.rules']=[{'matches':[{'node.name':GAME}], 'actions':{'create-filter':{'filter-graph':json.dumps(graph,ensure_ascii=False),'hide-parent':False}}}]
    (data/'surround.conf').write_text('# INZONE profile: surround\n'+json.dumps(config,ensure_ascii=False,indent=2)+'\n')
    shutil.copy2(ROOT/'configs/52-inzone-game-chat.conf',wp/'52-inzone-game-chat.conf')
    if not (wp/'51-inzone-h9-ii.conf').exists():shutil.copy2(data/'balanced.conf',wp/'51-inzone-h9-ii.conf')
    shutil.copy2(ROOT/'README.md',data/'README.md')
    shutil.copytree(ROOT/'docs',data/'docs',dirs_exist_ok=True)
    executable=base/'.local/bin/inzone-profile';executable.parent.mkdir(parents=True,exist_ok=True)
    shutil.copy2(ROOT/'src/inzone-profile.py',executable);executable.chmod(0o755)
    unit=base/'.config/systemd/user/inzone-profile-auto.service';unit.parent.mkdir(parents=True,exist_ok=True)
    shutil.copy2(ROOT/'configs/systemd/inzone-profile-auto.service',unit)
    mpv=base/'.config/mpv/mpv.conf'
    if mpv.exists():mpv.write_text(mpv.read_text().replace('alsa_output.usb-Sony_INZONE_H9_II-00.iec958-stereo',GAME))
    if os.getuid()==0:
        owner=base.stat()
        for directory in (data,assets,backup,modules,payload_copy,library.parent):
            if not directory.exists():continue
            for path in [directory,*directory.rglob('*')]:
                if not path.is_symlink():os.chown(path,owner.st_uid,owner.st_gid)
        for path in (executable,unit,unit.parent,wp/'52-inzone-game-chat.conf',wp/'51-inzone-h9-ii.conf'):
            os.chown(path,owner.st_uid,owner.st_gid)
    print('Installed. In the desktop user session run: inzone-profile surround')
    print('Backup:',backup)

if __name__=='__main__':main()
