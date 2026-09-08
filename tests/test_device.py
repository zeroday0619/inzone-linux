import sys,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'src'))
from inzone_device import command,parse_packet,describe
class DeviceTest(unittest.TestCase):
    def test_observed_wire_packets(self):
        self.assertEqual(command(4,1,1)[:14].hex(),'020c0100fc0896c34104010100a0')
        battery=parse_packet(bytes.fromhex('04ff0b0096c31404100100000d8f'))
        self.assertEqual(battery,dict(event=4,kind=16,sequence=1,source=4,payload=bytes([0,13])))
        ambient=parse_packet(bytes.fromhex('04ff0d0096c314411001000014ff00d2'))
        self.assertEqual(ambient['payload'],bytes([0,20,255,0]))
    def test_corruption_and_unsafe_commands(self):
        packet=bytearray.fromhex('04ff0b0096c31404100100000d8f')
        for i in range(len(packet)):
            copy=bytearray(packet);copy[i]^=1
            with self.subTest(i=i),self.assertRaises(ValueError):parse_packet(copy)
        with self.assertRaises(ValueError):command(160,2,1,b'')
        with self.assertRaises(ValueError):command(4,1,1,bytes(51))
    def test_status_excludes_serial(self):
        status=describe({'connection':[1],'model':[5,3,0x12,0x34,0,0],'battery':[0,13],'firmware':[1,1,0,0,1,1,0,0],'ambient':[0,20,255,0]})
        self.assertNotIn('model',status);self.assertEqual(status['firmware']['headset'],'01.001.000')
        self.assertEqual(status['fields']['ambient_level'],20)
if __name__=='__main__':unittest.main()
