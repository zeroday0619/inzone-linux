#!/usr/bin/python3
"""Decode locally supplied INZONE Hub 1.0.19.0 filter assets; no Windows execution."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import struct
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

DLL_SHA256 = 'd3fb1a9619335af6f8256029714ac57ba53d643fb4ce9f43d8d50e3a20179860'
CHANNELS = {'FL': (330,90), 'FR': (30,90), 'FC': (0,90), 'LFE': (0,0),
            'RL': (210,90), 'RR': (150,90), 'SL': (250,90), 'SR': (110,90)}

def u32(data, offset=0):
    return struct.unpack_from('<I', data, offset)[0]

class Decoder:
    def __init__(self, dll):
        self.dll = Path(dll).read_bytes()
        if hashlib.sha256(self.dll).hexdigest() != DLL_SHA256:
            raise ValueError('Unsupported DLL: offsets are pinned to INZONE Hub 1.0.19.0')
        pe = u32(self.dll, 60)
        opt = pe + 24
        self.base = struct.unpack_from('<Q', self.dll, opt + 24)[0]
        section = opt + struct.unpack_from('<H', self.dll, pe + 20)[0]
        count = struct.unpack_from('<H', self.dll, pe + 6)[0]
        self.sections = [struct.unpack_from('<IIII', self.dll, section+i*40+8) for i in range(count)]

    def read(self, rva, length):
        for _, start, size, offset in self.sections:
            if start <= rva and rva + length <= start + size:
                return self.dll[offset+rva-start:offset+rva-start+length]
        raise ValueError('Invalid PE address')

    def key(self, marker, table):
        index = table.index(marker)
        seed = table[(index+7)%len(table)] ^ table[(index+11)%len(table)]
        low, mid, high, top = seed&255, (seed>>8)&255, (seed>>16)&255, seed>>24
        state, key = marker, bytearray()
        for k in range(1,17):
            mix = low + 3*high + 2*mid + 4*(top+1)
            signed = state if state < 0x80000000 else state - 0x100000000
            value = ((signed >> 8) + 10 + mix*k) & 0xffffffff
            byte = state & 255
            low, mid, high, top = byte^mid, byte^high, byte^top, mid
            state = value
            key.append(value & 255)
        return b''.join(key[i:i+4][::-1] for i in range(0,16,4))

    def decrypt(self, data, offset, table):
        if len(data) <= offset or (len(data)-offset)%16:
            raise ValueError('Invalid encrypted body length')
        iv = data[8:24]
        decryptor = Cipher(algorithms.AES(self.key(u32(data,4), table)), modes.CBC(iv)).decryptor()
        raw = decryptor.update(data[offset:]) + decryptor.finalize()
        pad = raw[-1]
        if not 1 <= pad <= 16 or raw[-pad:] != bytes([pad])*pad:
            raise ValueError('Invalid padding')
        plain = raw[:-pad]
        if hashlib.md5(plain).digest() != iv:
            raise ValueError('Filter checksum mismatch')
        return plain

    def hki(self, data):
        if len(data) < 144 or data[:4] != b'hki2' or data[76:78] not in (b'\x05\x00',b'\x07\x00'):
            raise ValueError('Unsupported HKI header/cipher')
        selector = struct.unpack_from('<H',data,78)[0]
        if selector != 1:
            raise ValueError('Unsupported key selector')
        count = u32(self.read(0x1f6ab0+selector*4,4))
        ptr = struct.unpack('<Q',self.read(0x1f6ab8+selector*8,8))[0]
        table = struct.unpack('<'+'I'*count,self.read(ptr-self.base,count*4))
        plain = self.decrypt(data,144,table)
        if data[76] == 7:
            checksum=u32(data,80);seed=(checksum+0x52276af7)&0xffffffff
            decoded=bytearray()
            for offset in range(0,len(plain),4):
                word=u32(plain,offset)^((seed+(seed>>24))&0xffffffff)
                decoded.extend(struct.pack('<I',word));seed=(seed*0x80849+0x2a3b5)&0xffffffff
            plain=bytes(decoded)
            if sum(plain)&255 != checksum&255:raise ValueError('HKI inner checksum mismatch')
        rate, ears, taps, directions = u32(data,56),u32(data,60),u32(data,88),u32(data,92)
        if (rate,ears,taps) != (48000,2,512) or not 8<=directions<=1024:
            raise ValueError('Unsupported filter dimensions')
        size = 16 + taps*4
        if len(plain) != size*ears*directions:
            raise ValueError('Invalid record count')
        records = {}
        for offset in range(0,len(plain),size):
            azimuth, polar, kind, ear = struct.unpack_from('<4I',plain,offset)
            values = struct.unpack_from('<'+'f'*taps,plain,offset+16)
            key = azimuth,polar,ear
            if ear not in (0,1) or kind not in (1,2) or key in records or not all(map(math.isfinite,values)):
                raise ValueError('Invalid or duplicate HRTF record')
            records[key] = values
        if len({k[:2] for k in records}) != directions or any((a,p,1-e) not in records for a,p,e in records):
            raise ValueError('Unpaired HRTF records')
        return records

    def ba(self, data):
        if len(data)<48 or data[:4] != b'ba00' or (u32(data,24),u32(data,28),u32(data,32)) != (48000,7,1):
            raise ValueError('Unsupported BA header')
        table = struct.unpack('<20I',self.read(0x1f7d80,80))
        plain = self.decrypt(data,48,table)
        if len(plain) != 140:
            raise ValueError('Invalid BA coefficient count')
        coefficients = [struct.unpack_from('<5f',plain,i*20) for i in range(7)]
        if not all(math.isfinite(v) and abs(v)<=64 for row in coefficients for v in row):
            raise ValueError('Non-finite or out-of-range BA coefficients')
        import cmath
        for b0,b1,b2,a1,a2 in coefficients:
            roots=((-a1+cmath.sqrt(a1*a1-4*a2))/2,(-a1-cmath.sqrt(a1*a1-4*a2))/2)
            if any(abs(root)>=1 for root in roots):raise ValueError('Unstable BA filter')
        return coefficients

def normalize_hrtf(records):
    """Sony bounds the largest 1024-point complex-bin magnitude to 18.

    The shipped 512-tap bank is one FFT partition. Use double intermediate FFT
    arithmetic and native float gain/tap rounding; FFT-backend rounding may differ.
    """
    import cmath
    def fft(values):
        n=len(values)
        if n==1:return values
        even=fft(values[::2]);odd=fft(values[1::2])
        products=[cmath.exp(-2j*math.pi*k/n)*odd[k] for k in range(n//2)]
        return [even[k]+products[k] for k in range(n//2)]+[even[k]-products[k] for k in range(n//2)]
    def f32(value):return struct.unpack('<f',struct.pack('<f',value))[0]
    peak=max(abs(v) for taps in records.values() for v in fft(list(taps)+[0.]*512))
    if not math.isfinite(peak) or peak>3.4e38:raise ValueError('HRTF magnitude is out of range')
    gain=f32(18/f32(peak)) if peak>18 else 1.0
    return ({key:tuple(f32(v*gain) for v in taps) for key,taps in records.items()} if gain!=1 else records),gain

def write_float_wav(path, left, right):
    if len(left)!=len(right):
        raise ValueError('Unmatched ear lengths')
    interleaved = [v for pair in zip(left,right) for v in pair]
    body = struct.pack('<'+'f'*len(interleaved),*interleaved)
    fmt = struct.pack('<HHIIHH',3,2,48000,48000*8,8,32)
    chunks = b'fmt '+struct.pack('<I',16)+fmt+b'fact'+struct.pack('<II',4,len(left))+b'data'+struct.pack('<I',len(body))+body
    Path(path).write_bytes(b'RIFF'+struct.pack('<I',len(chunks)+4)+b'WAVE'+chunks)

def export(payload, destination):
    payload, destination = Path(payload),Path(destination)
    decoder = Decoder(payload/'inzonevirtualizer.dll')
    records = decoder.hki((payload/'shp_for_game_v2.0_512tap.hki').read_bytes())
    coefficients = decoder.ba((payload/'wh_g910n_standard.ba').read_bytes())
    records,normalization=normalize_hrtf(records)
    destination.mkdir(parents=True,exist_ok=True)
    for channel,(azimuth,polar) in CHANNELS.items():
        write_float_wav(destination/(channel+'.wav'),records[azimuth,polar,0],records[azimuth,polar,1])
    (destination/'h9-ii-biquads.json').write_text(json.dumps(coefficients,indent=2)+'\n')
    manifest = {'hrtf_normalization_gain':normalization,'dll_sha256':DLL_SHA256,'rate':48000,'taps':512,'channels':CHANNELS,
      'assets':{name:hashlib.sha256((payload/name).read_bytes()).hexdigest() for name in ('shp_for_game_v2.0_512tap.hki','wh_g910n_standard.ba')},
      'limitations':['Personalized filters require local HKI/BA files supplied by the user.']}
    (destination/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('payload',type=Path)
    parser.add_argument('destination',type=Path)
    args = parser.parse_args()
    export(args.payload,args.destination)
