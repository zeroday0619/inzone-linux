"""Extract shipped Hub presets and the effective ModeEqualizer coefficient bank."""
import argparse
import hashlib
import json
from pathlib import Path
import re
ROOT=Path(__file__).resolve().parents[1]
TYPE='PCWidget.ViewModel.SoundQualitySettingsViewModel'


def export(payload, decompiled, destination):
    payload,decompiled,destination=map(Path,(payload,decompiled,destination))
    source=(decompiled/(TYPE+'.decompiled.cs')).read_text()
    fields=('31_5Hz','63Hz','125Hz','250Hz','500Hz','1kHz','2kHz','4kHz','8kHz','16kHz')
    items={}
    for name in ('FLAT','FPS1','FPS2','FPS3','IMMERSION_FLAT','BASS_BOOST','MUSIC_VIDEO'):
        body=source.split('case EQ_PRESET.'+name+':')[-1].split('break;')[0]
        gains=[int(re.search(r'EQGain_'+field+r' = (-?\d+);',body)[1]) for field in fields]
        items[name.lower()]={'eq':gains,'sound_mode':'immersive' if name=='IMMERSION_FLAT' else 'standard','output_alc':name!='FLAT','eq_enable':name not in ('FLAT','IMMERSION_FLAT'),'base_eq':False}
    control=payload/'control.yaml'
    mode=control.read_text().split('mode_equalizer:')[1].split('\nequalizer:')[0].split('params:')[0]
    columns={name:json.loads(re.search(r'- '+name+r': (\[[^\]]+\])',mode)[1]) for name in ('b0','b1','b2','a1','a2')}
    # SetEqEnable enables both arrays. Equalizer::SetParameters gives coeffs precedence.
    rows=[[columns[k][i] for k in ('b0','b1','b2','a1','a2')] for i in range(10)]
    value={'managed_dll_sha256':hashlib.sha256((payload/'inzonehub.dll').read_bytes()).hexdigest(),'control_yaml_sha256':hashlib.sha256(control.read_bytes()).hexdigest(),'rate':48000,'presets':items,'immersive_coefficients':rows}
    destination.mkdir(parents=True,exist_ok=True)
    (destination/'sony-presets.json').write_text(json.dumps(value,indent=2)+'\n')


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--payload',type=Path,default=ROOT/'analysis/payload')
    parser.add_argument('--decompiled',type=Path,default=ROOT/'analysis/decompiled')
    parser.add_argument('--output',type=Path,default=ROOT/'assets')
    args=parser.parse_args()
    export(args.payload,args.decompiled,args.output)
    print('Extracted seven presets and ten effective immersive EQ sections')
