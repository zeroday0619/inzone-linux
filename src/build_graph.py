#!/usr/bin/python3
"""Generate a native PipeWire 7.1 to binaural graph from locally decoded Sony filters."""
import argparse
import json
from pathlib import Path
from sony_filters import CHANNELS

GAME = 'alsa_output.usb-Sony_INZONE_H9_II-00.stereo-game'
SINK = 'inzone.sony-surround'
DEFAULT_PLUGIN = Path(__file__).resolve().parents[1]/'native/inzone_dsp.so'

def build(assets, plugin=DEFAULT_PLUGIN, drc=0):
    plugin = Path(plugin).resolve()
    if not plugin.is_file():
        raise ValueError("Build native/inzone_dsp.so before generating the graph")
    if drc not in (0,1,2):
        raise ValueError("DRC mode must be 0, 1, or 2")
    assets = Path(assets).resolve()
    coefficients = json.loads((assets/'h9-ii-biquads.json').read_text())
    nodes,links = [],[]
    def node(name,label,**args):
        nodes.append(dict(type='builtin',name=name,label=label,**args))
    def link(output,input):
        links.append(dict(output=output,input=input))
    for index,channel in enumerate(CHANNELS,1):
        node('copy'+channel,'copy')
        for ear in range(2):
            name = f'conv{channel}_{ear}'
            node(name,'convolver',config={'filename':str(assets/(channel+'.wav')),'channel':ear,'blocksize':128})
            link('copy'+channel+':Out',name+':In')
            link(name+':Out',f'mix{ear}:In {index}')
    for ear in range(2):
        node(f'mix{ear}','mixer')
        previous = f'mix{ear}:Out'
        for index,(b0,b1,b2,a1,a2) in enumerate(coefficients):
            name = f'eq{ear}_{index}'
            nodes.append(dict(type='ladspa',name=name,plugin=str(plugin),label='inzone_biquad',control=dict(b0=b0,b1=b1,b2=b2,a1=a1,a2=a2)))
            link(previous,name+':Input')
            previous = name+':Output'
        link(previous,'spatial_alc:Input '+('L' if ear==0 else 'R'))
    nodes.append(dict(type='ladspa',name='spatial_alc',plugin=str(plugin),label='inzone_spatial_alc',control={'Boost':1}))
    nodes.append(dict(type='ladspa',name='drc',plugin=str(plugin),label='inzone_drc',control={'Mode':drc}))
    for ear in ('L','R'):
        link('spatial_alc:Output '+ear,'drc:Input '+ear)
    return {
      'node.description':'INZONE H9 II - Sony Surround (experimental)',
      'audio.rate':48000,
      'filter.graph':{'nodes':nodes,'links':links,'inputs':['copy'+ch+':In' for ch in CHANNELS],
                      'outputs':['drc:Output L','drc:Output R']},
      'capture.props':{'node.name':SINK,'node.description':'INZONE H9 II - Sony Surround (experimental)',
        'media.class':'Audio/Sink','audio.channels':8,'audio.position':list(CHANNELS),
        'node.latency':'256/48000','node.rate':'1/48000','priority.session':1500,
        'stream.dont-remix':True,'channelmix.upmix':False},
      'playback.props':{'node.name':'inzone.sony-surround.output','node.description':'Sony HRTF to INZONE Game',
        'audio.channels':2,'audio.position':['FL','FR'],'node.passive':True,
        'target.object':GAME,'node.dont-fallback':True,'node.dont-reconnect':True,'stream.dont-remix':True}
    }

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('assets',type=Path)
    parser.add_argument('output',type=Path)
    args=parser.parse_args()
    args.output.write_text(json.dumps(build(args.assets),indent=2)+'\n')
