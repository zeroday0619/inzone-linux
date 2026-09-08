"""Check download integrity and Git publication rules without vendor downloads."""
import hashlib
import io
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
import fetch_assets


class FetchAssetsTest(unittest.TestCase):
    def test_verified_download_is_published(self):
        data=b'pinned installer fixture'
        with tempfile.TemporaryDirectory() as tmp:
            target=Path(tmp)/'installer.exe'
            with patch.object(fetch_assets.urllib.request,'build_opener') as opener:
                opener.return_value.open.return_value=io.BytesIO(data)
                fetch_assets.download('https://example.invalid/installer.exe',target,hashlib.sha256(data).hexdigest(),len(data))
            self.assertEqual(target.read_bytes(),data)
            self.assertEqual(list(Path(tmp).iterdir()),[target])

    def test_invalid_download_does_not_replace_cache(self):
        expected=b'expected installer'
        for received in (expected[:-1],expected+b'extra',b'wrong integrity!!!'):
            with self.subTest(received=received),tempfile.TemporaryDirectory() as tmp:
                target=Path(tmp)/'installer.exe';target.write_bytes(b'existing cache')
                with patch.object(fetch_assets.urllib.request,'build_opener') as opener:
                    opener.return_value.open.return_value=io.BytesIO(received)
                    with self.assertRaises(ValueError):
                        fetch_assets.download('https://example.invalid/installer.exe',target,hashlib.sha256(expected).hexdigest(),len(expected))
                self.assertEqual(target.read_bytes(),b'existing cache')
                self.assertEqual(list(Path(tmp).iterdir()),[target])

    def test_http_redirect_is_refused(self):
        with self.assertRaisesRegex(ValueError,'HTTPS'):
            fetch_assets.HTTPSRedirect().redirect_request(None,None,302,'',{},'http://example.invalid/file')

    def test_publication_rules_keep_reports_and_exclude_raw_data(self):
        paths={
            'docs/reverse-engineering.md':False,
            'analysis/README.md':False,
            'analysis/pipewire-sfx-results.json':False,
            'evidence/installer.json':False,
            'src/personalization.py':False,
            'native/ladspa.c':False,
            'tools/fetch_assets.py':False,
            'downloads/installer.exe':True,
            'analysis/decompiled/Example.cs':True,
            'analysis/new-unreviewed-report.json':True,
            'analysis/virtualizer.asm':True,
            'analysis/payload/control.yaml':True,
            'analysis/tui-session.txt':True,
            'assets/sony-eq-tables.json':True,
            'assets/FL.wav':True,
            'tools/ilspycmd':True,
            'tools/.store/ilspycmd/tool.nuspec':True,
            'evidence/usb-descriptors.bin':True,
            'backups/audio-state.json':True,
            'native/inzone_dsp.so':True,
            'copied.decompiled.cs':True,
        }
        with tempfile.TemporaryDirectory() as tmp:
            subprocess.run(['git','init','--quiet',tmp],check=True)
            shutil.copyfile(ROOT/'.gitignore',Path(tmp)/'.gitignore')
            result=subprocess.run(['git','-C',tmp,'check-ignore','--stdin','--no-index'],input='\n'.join(paths)+'\n',capture_output=True,text=True,check=True)
            ignored=set(result.stdout.splitlines())
            self.assertEqual(ignored,{p for p,excluded in paths.items() if excluded})


if __name__=='__main__':unittest.main()
