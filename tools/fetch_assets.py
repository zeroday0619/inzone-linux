#!/usr/bin/env python3
"""Download the pinned Sony installer and regenerate local assets without executing it."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request

ROOT=Path(__file__).resolve().parents[1]
ILSPY_VERSION='11.0.0.9375'
BLOCK=1024*1024


def sha256(path):
    digest=hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda:stream.read(BLOCK),b''):digest.update(block)
    return digest.hexdigest()


def verify(path, expected, size=None):
    path=Path(path)
    if size is not None and path.stat().st_size!=size:
        raise ValueError(f'Unexpected file size: {path.name}')
    if sha256(path)!=expected:raise ValueError(f'SHA-256 mismatch: {path.name}')


class HTTPSRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self,req,fp,code,msg,headers,newurl):
        if urllib.parse.urlsplit(newurl).scheme!='https':
            raise ValueError('Download redirect must use HTTPS')
        return super().redirect_request(req,fp,code,msg,headers,newurl)


def download(url, target, expected, size):
    """Publish a cache entry only after its length and digest have been checked."""
    target=Path(target)
    if urllib.parse.urlsplit(url).scheme!='https':raise ValueError('Download must use HTTPS')
    target.parent.mkdir(parents=True,exist_ok=True)
    fd,temporary=tempfile.mkstemp(prefix='.'+target.name+'-',suffix='.tmp',dir=target.parent)
    try:
        with os.fdopen(fd,'wb') as output:
            opener=urllib.request.build_opener(HTTPSRedirect())
            with opener.open(url,timeout=60) as response:
                total=0
                while block:=response.read(BLOCK):
                    total+=len(block)
                    if total>size:raise ValueError('Download exceeds pinned file size')
                    output.write(block)
        verify(temporary,expected,size)
        os.replace(temporary,target)
    finally:
        Path(temporary).unlink(missing_ok=True)


def run(command, **kwargs):
    result=subprocess.run([str(p) for p in command],text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,**kwargs)
    if result.returncode:
        detail=(result.stderr or result.stdout).strip()[-3000:]
        raise RuntimeError(f'{Path(command[0]).name} failed: {detail}')
    return result.stdout


def decompiler(path, offline):
    path=Path(path)
    if not path.exists():
        if offline:raise RuntimeError('Offline mode requires an installed ilspycmd; use --ilspycmd PATH')
        if not shutil.which('dotnet'):raise RuntimeError('Install the .NET 10 SDK to obtain ilspycmd')
        print(f'Installing ilspycmd {ILSPY_VERSION} from NuGet...',flush=True)
        run(['dotnet','tool','install','ilspycmd','--tool-path',path.parent,'--version',ILSPY_VERSION,
             '--source','https://api.nuget.org/v3/index.json'],timeout=240,
            env=dict(os.environ,DOTNET_CLI_TELEMETRY_OPTOUT='1',DOTNET_NOLOGO='1'))
    output=run([path,'--version'],timeout=30)
    if f'ilspycmd: {ILSPY_VERSION}' not in output:
        raise ValueError(f'Expected ilspycmd {ILSPY_VERSION}: {path}')
    return path.resolve()


def publish_file(source, destination):
    destination.parent.mkdir(parents=True,exist_ok=True)
    fd,tmp=tempfile.mkstemp(prefix='.'+destination.name+'-',dir=destination.parent)
    os.close(fd)
    try:
        shutil.copyfile(source,tmp)
        os.chmod(tmp,0o644)
        os.replace(tmp,destination)
    finally:Path(tmp).unlink(missing_ok=True)


def prepare(installer, metadata, sevenzip, ilspy):
    # Temporary extraction prevents malformed downloads or decompiler failures from
    # changing the working asset set. Existing reports/decompilations are preserved.
    analysis=ROOT/'analysis';analysis.mkdir(parents=True,exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.fetch-assets-',dir=analysis) as tmp:
        stage=Path(tmp);msi=stage/'INZONEHub.msi'
        with installer.open('rb') as source,msi.open('wb') as output:
            source.seek(metadata['msi']['offset']);remaining=metadata['msi']['size']
            while remaining:
                block=source.read(min(BLOCK,remaining))
                if not block:raise ValueError('Truncated embedded MSI')
                output.write(block);remaining-=len(block)
        verify(msi,metadata['msi']['sha256'],metadata['msi']['size'])
        print('Extracting MSI and CAB without running Windows code...',flush=True)
        run([sevenzip,'x','-y','-bd','-o'+str(stage/'msi'),msi,'Data1.cab'],timeout=120)
        payload=stage/'payload'
        run([sevenzip,'x','-y','-bd','-o'+str(payload),stage/'msi/Data1.cab'],timeout=120)
        for name,entry in metadata['payload'].items():verify(payload/name,entry['sha256'],entry['size'])
        import export_eq_tables,export_presets
        decompiled=stage/'decompiled';decompiled.mkdir()
        for typename in (export_eq_tables.TYPE,export_presets.TYPE):
            print('Extracting '+typename.rsplit('.',1)[-1]+'...',flush=True)
            content=run([ilspy,'--disable-updatecheck','-t',typename,payload/'inzonehub.dll'],timeout=180)
            (decompiled/(typename+'.decompiled.cs')).write_text(content)
        sys.path.insert(0,str(ROOT/'src'))
        from sony_filters import export
        assets=stage/'assets'
        export(payload,assets)
        export_eq_tables.export(payload,decompiled,assets)
        export_presets.export(payload,decompiled,assets)
        # Copy only known runtime inputs, not every unrelated component in the CAB.
        for name in metadata['payload']:publish_file(payload/name,analysis/'payload'/name)
        for source in decompiled.iterdir():publish_file(source,analysis/'decompiled'/source.name)
        for source in assets.iterdir():publish_file(source,ROOT/'assets'/source.name)
    print('Ready: analysis/payload, analysis/decompiled, assets (all ignored by Git).')


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--installer',type=Path,help='Use an existing, hash-verified installer')
    parser.add_argument('--offline',action='store_true',help='Use cached installer/tools; never download')
    parser.add_argument('--download-only',action='store_true',help='Only download and verify the installer')
    parser.add_argument('--ilspycmd',type=Path,help='Existing ilspycmd '+ILSPY_VERSION)
    args=parser.parse_args()
    metadata=json.loads((ROOT/'evidence/installer.json').read_text())
    installer=(args.installer or ROOT/'downloads'/Path(urllib.parse.urlsplit(metadata['url']).path).name).resolve()
    if not args.download_only:
        if importlib.util.find_spec('cryptography') is None:raise RuntimeError('Install Python cryptography first')
        sevenzip=shutil.which('7zz') or shutil.which('7z')
        if not sevenzip:raise RuntimeError('Install 7-Zip (7zz or 7z) first')
        ilspy=decompiler((args.ilspycmd or ROOT/'tools/ilspycmd').resolve(),args.offline)
    if installer.exists():
        verify(installer,metadata['sha256'],metadata['size'])
        print('Verified cached installer: '+installer.name,flush=True)
    else:
        if args.installer or args.offline:raise FileNotFoundError(f'Installer not found: {installer}')
        print('Downloading INZONE Hub '+metadata['version']+' from Sony...',flush=True)
        download(metadata['url'],installer,metadata['sha256'],metadata['size'])
        print('Installer SHA-256 verified.',flush=True)
    if not args.download_only:prepare(installer,metadata,sevenzip,ilspy)


if __name__=='__main__':
    try:main()
    except KeyboardInterrupt:raise SystemExit(130)
    except Exception as exc:raise SystemExit(str(exc))
