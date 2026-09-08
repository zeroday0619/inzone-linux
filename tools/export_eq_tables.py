"""Extract the shipped 48 kHz / integer dB tables from local decompilation."""
import argparse
import hashlib
import json
from pathlib import Path
import re
ROOT=Path(__file__).resolve().parents[1]
TYPE='PCWidget.ViewModel.ApoFileCommunication'


def export(payload, decompiled, destination):
    payload,decompiled,destination=map(Path,(payload,decompiled,destination))
    source=decompiled/(TYPE+'.decompiled.cs')
    tables={}
    for name,body in re.findall(r'decimal\[,] Table(\w+) = new decimal\[25, 7\]\s*\{(.*?)\n\s*\};',source.read_text(),re.S):
        rows=[[float(v.strip().removesuffix('m')) for v in row.split(',')] for row in re.findall(r'\{([^{}]+)\}',body)]
        if len(rows)!=25 or any(len(row)!=7 or row[0]!=12-i for i,row in enumerate(rows)):
            raise ValueError('Unexpected Sony EQ table')
        tables[name]=rows
    if len(tables)!=10:raise ValueError('Expected ten Sony EQ bands')
    result={'managed_dll_sha256':hashlib.sha256((payload/'inzonehub.dll').read_bytes()).hexdigest(),'rate':48000,'tables':tables}
    destination.mkdir(parents=True,exist_ok=True)
    (destination/'sony-eq-tables.json').write_text(json.dumps(result,indent=2)+'\n')


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--payload',type=Path,default=ROOT/'analysis/payload')
    parser.add_argument('--decompiled',type=Path,default=ROOT/'analysis/decompiled')
    parser.add_argument('--output',type=Path,default=ROOT/'assets')
    args=parser.parse_args()
    export(args.payload,args.decompiled,args.output)
    print('Extracted 250 original Sony EQ coefficient rows')
