"""Import local personalized HKI/BA files and generate validated HRTF assets."""
import hashlib
import json
from pathlib import Path
import secrets
import shutil
import tempfile
import time
from sony_filters import Decoder, CHANNELS, write_float_wav, normalize_hrtf
LIMIT=16*1024*1024

def import_files(home,hki,ba):
    home=Path(home);root=home/'.local/share/inzone-linux';root.mkdir(parents=True,exist_ok=True)
    def read_file(path):
        path=Path(path)
        if not path.is_file():raise ValueError('일반 필터 파일을 선택하세요')
        with path.open('rb') as stream:return stream.read(LIMIT+1)
    raw=read_file(hki);model=read_file(ba)
    if len(raw)>LIMIT or len(model)>LIMIT:raise ValueError('필터 파일 크기 제한 초과')
    if raw[:4]!=b'hki2' and raw[52:56]==b'hki2':raw=raw[52:]
    decoder=Decoder(root/'decoder/inzonevirtualizer.dll')
    records=decoder.hki(raw);coefficients=decoder.ba(model)
    records,normalization=normalize_hrtf(records)
    # Require the exact directions the verified 7.1 renderer consumes.
    if any((a,p,e) not in records for a,p in CHANNELS.values() for e in (0,1)):
        raise ValueError('개인화 HKI에 필요한 7.1 방향이 없습니다')
    stage=Path(tempfile.mkdtemp(prefix='.personal-',dir=root));destination=root/'personal'
    try:
        for ch,(a,p) in CHANNELS.items():write_float_wav(stage/(ch+'.wav'),records[a,p,0],records[a,p,1])
        (stage/'h9-ii-biquads.json').write_text(json.dumps(coefficients)+'\n')
        (stage/'personalized_hrtf.hki').write_bytes(raw);(stage/'YY2987.ba').write_bytes(model)
        (stage/'manifest.json').write_text(json.dumps({'kind':'personal','hrtf_normalization_gain':normalization,'rate':48000,'taps':512,'model':'YY2987','hki_sha256':hashlib.sha256(raw).hexdigest(),'ba_sha256':hashlib.sha256(model).hexdigest(),'imported_at':int(time.time())},indent=2)+'\n')
        for path in stage.iterdir():path.chmod(0o600)
        previous=None
        if destination.exists():
            previous=root/('.personal-backup-'+secrets.token_hex(6));destination.rename(previous)
        try:stage.rename(destination)
        except Exception:
            if previous is not None:previous.rename(destination)
            raise
        # Preserve the previous personalized assets for manual recovery.
        return destination
    finally:
        if stage.exists():shutil.rmtree(stage)
