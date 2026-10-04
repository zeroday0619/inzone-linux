#!/usr/bin/env python3
"""Finalize documentation and permissions in an existing Debian staging tree."""
import argparse
from datetime import datetime, timezone
from email.utils import format_datetime
import gzip
import os
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--staging-root', type=Path, required=True)
parser.add_argument('--version', required=True)
arguments = parser.parse_args()
root = arguments.staging_root.resolve(strict=True)
if root == Path('/') or not (root / 'usr/bin/inzone-gui').is_file():
    parser.error('The staging root must contain the packaged application.')
epoch = int(os.environ.get('SOURCE_DATE_EPOCH') or subprocess.check_output(
    ['git', '-C', str(Path(__file__).resolve().parent.parent), 'log', '-1', '--format=%ct'], text=True).strip())
changelog = f'''inzone-linux ({arguments.version}) unstable; urgency=medium

  * Package the Swift desktop, command-line tools, D-Bus service,
    and DSP plugin.
  * Keep desktop-user setup and Sony asset acquisition explicit.

 -- Euiseo Cha <escha@zeroday0619.dev>  {format_datetime(datetime.fromtimestamp(epoch, timezone.utc))}
'''
(root / 'usr/share/doc/inzone-linux/changelog.Debian.gz').write_bytes(gzip.compress(changelog.encode(), mtime=0))
for path in (root / 'usr/share/man/man1').glob('*.1'):
    path.with_suffix('.1.gz').write_bytes(gzip.compress(path.read_bytes(), mtime=0))
    path.unlink()
for path in root.rglob('*'):
    if path.is_symlink():
        continue
    if path.is_dir():
        path.chmod(0o755)
    elif path.is_file():
        path.chmod(0o755 if path.stat().st_mode & 0o111 else 0o644)
