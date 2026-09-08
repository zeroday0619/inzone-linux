"""Exercise the exported LADSPA ABI across irregular blocks and reactivation."""
import array,ctypes as c,math
from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parents[1]
F=c.POINTER(c.c_float)
class Descriptor(c.Structure):pass
Handle=c.c_void_p
Instantiate=c.CFUNCTYPE(Handle,c.POINTER(Descriptor),c.c_ulong)
Connect=c.CFUNCTYPE(None,Handle,c.c_ulong,F)
Activate=c.CFUNCTYPE(None,Handle)
Run=c.CFUNCTYPE(None,Handle,c.c_ulong)
Descriptor._fields_=[('id',c.c_ulong),('label',c.c_char_p),('properties',c.c_int),('name',c.c_char_p),('maker',c.c_char_p),('copyright',c.c_char_p),('count',c.c_ulong),('ports',c.c_void_p),('names',c.c_void_p),('hints',c.c_void_p),('implementation',c.c_void_p),('instantiate',Instantiate),('connect',Connect),('activate',Activate),('run',Run),('run_adding',c.c_void_p),('set_gain',c.c_void_p),('deactivate',c.c_void_p),('cleanup',Activate)]

def floats(path):
    a=array.array('f');a.frombytes(path.read_bytes());return a
class PluginTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lib=c.CDLL(str(ROOT/'native/inzone_dsp.so'));cls.lib.ladspa_descriptor.argtypes=[c.c_ulong];cls.lib.ladspa_descriptor.restype=c.POINTER(Descriptor)
    def test_irregular_blocks_reset_and_inplace(self):
        source=array.array('f',(v for i in range(48000) for v in (2*math.sin(i*.1309),.7*math.sin(i*.0471))))
        for index,controls,channels in [(2,[1,-18,1000,.001,1],2),(1,[0],2),(1,[1],2),(1,[2],2),(3,[1],1),(0,[1],2),(0,[0],2),(4,[.5,.25,0,-.5,.2],1),(5,[.5,.25,0,-.5,.2],1)]:
            with self.subTest(index=index,controls=controls):
                pointer=self.lib.ladspa_descriptor(index);d=pointer.contents;h=d.instantiate(pointer,48000);self.assertTrue(h)
                control_data=[c.c_float(v) for v in controls]
                for i,v in enumerate(control_data,2*channels):d.connect(h,i,c.pointer(v))
                latency=c.c_float()
                if index==0:d.connect(h,5,c.pointer(latency))
                def render(blocks,inplace):
                    d.activate(h)
                    inputs=[array.array('f',source[ch::2]) for ch in range(channels)]
                    outputs=inputs if inplace else [array.array('f',[0.])*len(inputs[0]) for _ in range(channels)]
                    at=0;block=0
                    while at<len(inputs[0]):
                        n=min(blocks[block%len(blocks)],len(inputs[0])-at);buffers=[]
                        for port,a in enumerate(inputs+outputs):
                            view=(c.c_float*n).from_buffer(a,at*4);buffers.append(view);d.connect(h,port,view)
                        d.run(h,n);at+=n;block+=1
                    return outputs
                try:
                    expected=render((48000,),False)
                    self.assertTrue(all(math.isfinite(v) for channel in expected for v in channel))
                    if index==1 and controls==[0]:self.assertEqual(expected,[source[ch::2] for ch in range(channels)])
                    if index==1 and controls!=[0]:self.assertLessEqual(max(abs(v) for ch in expected for v in ch),1)
                    if index==2:self.assertLess(max(map(abs,expected[0][-4800:])),.14)
                    for inplace in (False,True):
                        self.assertEqual(render((1,3,7,8,127,256,513),inplace),expected)
                    if index==0:
                        self.assertEqual(latency.value,32)
                        self.assertEqual(expected[0][:32],array.array('f',[0])*32)
                finally:d.cleanup(h)
    def test_unsupported_rate_rejected(self):
        for i in range(6):
            p=self.lib.ladspa_descriptor(i);self.assertFalse(p.contents.instantiate(p,44100))
        self.assertFalse(self.lib.ladspa_descriptor(6))
if __name__=='__main__':unittest.main()
