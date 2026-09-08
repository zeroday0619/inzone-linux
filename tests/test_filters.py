import hashlib
import json
from pathlib import Path
import struct
import sys
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'src'))
from sony_filters import Decoder,CHANNELS
from build_graph import build
ROOT=Path(__file__).resolve().parents[1]

class FiltersTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.payload=ROOT/'analysis/payload'
        cls.decoder=Decoder(cls.payload/'inzonevirtualizer.dll')
        cls.data=(cls.payload/'shp_for_game_v2.0_512tap.hki').read_bytes()
    def test_reference_and_ears(self):
        records=self.decoder.hki(self.data)
        self.assertEqual(len(records),28)
        # Pin the decoded stock bank without distributing its raw sample data.
        plain=b''.join(struct.pack('<4I512f',az,polar,2,ear,*taps)
                       for (az,polar,ear),taps in records.items())
        self.assertEqual(hashlib.sha256(plain).hexdigest(),
                         '626d8ac6b7fa32f5ba97ea19fa87467cbdaeb5873894e37e9690b8c3eb5dc9fe')
        self.assertEqual(hashlib.md5(plain).digest(),self.data[8:24])
    def test_downmix_channel_orientation(self):
        records=self.decoder.hki((self.payload/'downmix.hki').read_bytes())
        for channel in ('FL','SL','RL'):
            a,p=CHANNELS[channel]
            self.assertGreater(records[a,p,0][0],0)
            self.assertEqual(sum(map(abs,records[a,p,1])),0)
        for channel in ('FR','SR','RR'):
            a,p=CHANNELS[channel]
            self.assertGreater(records[a,p,1][0],0)
            self.assertEqual(sum(map(abs,records[a,p,0])),0)
    def test_corruption_is_rejected(self):
        for offset in (0,8,56,60,76,78,88,92,144,len(self.data)-1):
            data=bytearray(self.data);data[offset]^=1
            with self.subTest(offset=offset),self.assertRaises(ValueError):
                self.decoder.hki(bytes(data))
        with self.assertRaises(ValueError):self.decoder.hki(self.data[:-1])
    def test_biquads_are_stable(self):
        import cmath
        rows=self.decoder.ba((self.payload/'wh_g910n_standard.ba').read_bytes())
        self.assertEqual(len(rows),7)
        for b0,b1,b2,a1,a2 in rows:
            roots=((-a1+cmath.sqrt(a1*a1-4*a2))/2,(-a1-cmath.sqrt(a1*a1-4*a2))/2)
            self.assertTrue(all(abs(root)<1 for root in roots))
    def test_export_exact_float_samples(self):
        records=self.decoder.hki(self.data)
        for channel,(a,p) in CHANNELS.items():
            data=(ROOT/'assets'/(channel+'.wav')).read_bytes()
            offset=data.index(b'data')+8
            values=struct.unpack('<1024f',data[offset:])
            self.assertEqual(values[::2],records[a,p,0])
            self.assertEqual(values[1::2],records[a,p,1])
    def test_graph_channel_routes(self):
        graph=build(ROOT/'assets')['filter.graph']
        self.assertEqual(graph['inputs'],['copy'+ch+':In' for ch in CHANNELS])
        convolvers=[n for n in graph['nodes'] if n['label']=='convolver']
        self.assertEqual(len(convolvers),16)
        self.assertEqual(len([n for n in graph['nodes'] if n['label']=='inzone_biquad']),14)
        self.assertEqual(len({l['input'] for l in graph['links']}),len(graph['links']))

if __name__=='__main__':unittest.main()
