import hashlib,json,shutil,struct,sys,tempfile,unittest
from pathlib import Path
from cryptography.hazmat.primitives.ciphers import Cipher,algorithms,modes
ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'src'))
from personalization import import_files
from sony_filters import Decoder,normalize_hrtf,CHANNELS
from inzone_settings import validate,render,save
class PersonalTest(unittest.TestCase):
    def test_cipher7_and_atomic_import(self):
        decoder=Decoder(ROOT/'analysis/payload/inzonevirtualizer.dll')
        original=(ROOT/'analysis/payload/shp_for_game_v2.0_512tap.hki').read_bytes()
        table=struct.unpack('<20I',decoder.read(0x1f6a60,80))
        plain=decoder.decrypt(original,144,table);header=bytearray(original[:144]);header[76]=7
        checksum=0x37290000|(sum(plain)&255);struct.pack_into('<I',header,80,checksum);seed=(checksum+0x52276af7)&0xffffffff
        encoded=bytearray()
        for offset in range(0,len(plain),4):
            word=struct.unpack_from('<I',plain,offset)[0]^((seed+(seed>>24))&0xffffffff)
            encoded.extend(struct.pack('<I',word));seed=(seed*0x80849+0x2a3b5)&0xffffffff
        header[8:24]=hashlib.md5(encoded).digest();encrypt=Cipher(algorithms.AES(decoder.key(struct.unpack_from('<I',header,4)[0],table)),modes.CBC(bytes(header[8:24]))).encryptor()
        pad=16-len(encoded)%16;data=bytes(header)+encrypt.update(bytes(encoded)+bytes([pad])*pad)+encrypt.finalize()
        self.assertEqual(decoder.hki(data),decoder.hki(original))
        # Fixture derives entirely from the shipped generic HRTF, never user data.
        with tempfile.TemporaryDirectory() as tmp:
            home=Path(tmp);directory=home/'.local/share/inzone-linux/decoder';directory.mkdir(parents=True)
            shutil.copy2(ROOT/'analysis/payload/inzonevirtualizer.dll',directory/'inzonevirtualizer.dll')
            hki=home/'personal.hki';hki.write_bytes(bytes(52)+data)
            destination=import_files(home,hki,ROOT/'analysis/payload/wh_g910n_standard.ba')
            old=(destination/'manifest.json').read_bytes();hki.write_bytes(b'corrupt')
            with self.assertRaises(ValueError):import_files(home,hki,ROOT/'analysis/payload/wh_g910n_standard.ba')
            self.assertEqual(old,(destination/'manifest.json').read_bytes());self.assertEqual(destination.stat().st_mode&0o777,0o700)
    def test_hrtf_normalization_bound(self):
        # An impulse has a constant FFT magnitude, providing an analytic bound.
        records={(0,90,0):(64.0,)+(0.0,)*511,(0,90,1):(32.0,)+(0.0,)*511}
        normalized,gain=normalize_hrtf(records)
        self.assertEqual(gain,18/64)
        self.assertEqual(normalized[0,90,0],(18.0,)+(0.0,)*511)
        self.assertEqual(normalized[0,90,1],(9.0,)+(0.0,)*511)
        unchanged,gain=normalize_hrtf(normalized)
        self.assertEqual(gain,1);self.assertEqual(unchanged,normalized)
    def test_settings_validation_and_graph(self):
        for settings in ({'music':{'drc':True}},{'fps':{'eq':[float('nan')]*10}},{'voice':{'mic_agc':'yes'}},{'surround':{'hrtf':'../../x'}}):
            with self.assertRaises(ValueError):validate(settings)
        with tempfile.TemporaryDirectory() as tmp:
            home=Path(tmp);(home/'.config/inzone-h9-ii').mkdir(parents=True)
            save(home,{'voice':{'output_alc':True,'mic_agc':True,'drc':2}})
            config=json.loads('\n'.join(render(home,'voice',(ROOT/'configs/voice.conf').read_text()).splitlines()[1:]))
            rules=config['node.filter-graph.rules'];graphs=[json.loads(r['actions']['create-filter-graph'][-1]) for r in rules]
            self.assertEqual([len(g['inputs']) for g in graphs],[1,1])
            output_graphs=[json.loads(g) for g in rules[0]['actions']['create-filter-graph']]
            dynamics=next(g for g in output_graphs if any(n.get('label')=='inzone_alc' for n in g['nodes']))
            self.assertEqual(len(dynamics['inputs']),2)
            self.assertTrue(any(n['label']=='inzone_mic_agc' for n in graphs[1]['nodes']))
if __name__=='__main__':unittest.main()
