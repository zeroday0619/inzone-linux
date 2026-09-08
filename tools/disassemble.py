#!/usr/bin/python3
import re,sys
from pathlib import Path
start,end=(int(a,0)+0x180000000 for a in sys.argv[1:3])
for line in (Path(__file__).resolve().parents[1]/'analysis/virtualizer.asm').read_text().splitlines():
 m=re.match(r'\s*([0-9a-f]+):',line)
 if m and start<=int(m[1],16)<end:
  parts=line.split('\t')
  if len(parts)>2 and parts[-1]!='int3':print(m[1],parts[-1])
