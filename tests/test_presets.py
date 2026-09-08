import copy,json,sys,tempfile,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'src'))
import inzone_settings as settings
from sony_presets import LABELS,preset,read_windows,export_windows
class Presets(unittest.TestCase):
    def test_shipped_values(self):
        self.assertEqual(preset('bass_boost')['eq'],[12,12,8,0,0,0,0,0,0,0])
        for key in LABELS:settings.validate({'music':preset(key)})
        self.assertFalse(preset('flat')['output_alc'])
        self.assertEqual(preset('immersion_flat')['sound_mode'],'immersive')
    def test_windows_roundtrip_all_presets(self):
        with tempfile.TemporaryDirectory() as d:
            home=Path(d);(home/'.config/inzone-h9-ii').mkdir(parents=True);path=home/'windows.json'
            for name in LABELS:
                o=preset(name);settings.save(home,{'music':o});export_windows(home,'music',path)
                loaded=read_windows(path)[0]
                for k,v in o.items():self.assertEqual(loaded['options'][k],v,(name,k))
                self.assertFalse(loaded['surround'])
    def test_windows_jsonc_and_invalid(self):
        with tempfile.TemporaryDirectory() as d:
            path=Path(d)/'input.json'
            path.write_text('[/* test */ {"ProfileName":"a,//x", "EQPreset":"4", "Surround":true, "DynamicRangeCompression":"2",},]')
            o=read_windows(path)[0]
            self.assertEqual(o['name'],'a,//x');self.assertEqual(o['options']['drc'],2)
            self.assertEqual(o['options']['eq'],preset('fps1')['eq'])
            for item in ({'EQPreset':88},{'Surround':1},{'EQPreset':'CUSTOM','EQGain_1kHz':50},{'EQPreset':'CUSTOM','EQGain_1kHz':True}):
                path.write_text(json.dumps([item]))
                with self.assertRaises(ValueError):read_windows(path)
    def test_render_immersive_and_custom_in_separate_graphs(self):
        with tempfile.TemporaryDirectory() as d:
            home=Path(d);(home/'.config/inzone-h9-ii').mkdir(parents=True)
            o=preset('fps1');o['sound_mode']='immersive';settings.save(home,{'fps':o})
            rendered=settings.render(home,'fps',(ROOT/'configs/fps.conf').read_text())
            c=json.loads('\n'.join(rendered.splitlines()[1:]));graphs=[json.loads(g) for g in c['node.filter-graph.rules'][0]['actions']['create-filter-graph']]
            self.assertEqual(c['node.filter-graph.rules'][0]['matches'][0]['node.name'],settings.GAME)
            self.assertEqual(len(graphs),5)
            # Higher PipeWire graph indices run first; verify signal order.
            names=[[n['name'] for n in g['nodes']] for g in reversed(graphs)]
            self.assertIn('sony_amp1',names[1])
            self.assertIn('immersive0',names[2])
            self.assertIn('custom0',names[3])
            self.assertIn('output_alc',names[4])
            self.assertFalse(any(n['name']=='eq0' for g in graphs for n in g['nodes']))
            self.assertTrue(any(n['name']=='immersive9' for g in graphs for n in g['nodes']))
            self.assertTrue(any(n['name']=='custom9' for g in graphs for n in g['nodes']))
    def test_export_refuses_loss_of_supported_options(self):
        with tempfile.TemporaryDirectory() as d:
            home=Path(d);(home/'.config/inzone-h9-ii').mkdir(parents=True)
            for o in ({'mic_agc':True},{'output_alc':True},{'hrtf':'personal'}):
                settings.save(home,{'music':o})
                with self.assertRaises(ValueError):export_windows(home,'music',home/'export.json')
if __name__=='__main__':unittest.main()
