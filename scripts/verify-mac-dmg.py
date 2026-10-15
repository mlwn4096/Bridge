#!/usr/bin/env python3
"""Verify a read-only mounted installer contains the exact signed source app."""
import argparse
import hashlib
import os
import pathlib
import subprocess
import sys
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('dmg', type=pathlib.Path)
parser.add_argument('app', type=pathlib.Path)
parser.add_argument('--arch', required=True, choices=['arm64', 'x86_64'])
args = parser.parse_args()
root = pathlib.Path(__file__).resolve().parent.parent
mount = pathlib.Path(tempfile.mkdtemp(prefix='dmg-inspect-', dir=root / '.build'))
attached = False


def contents(app):
    result = {}
    for path in app.rglob('*'):
        relative = str(path.relative_to(app))
        if path.is_symlink():
            result[relative] = ('link', os.readlink(path))
        elif path.is_file():
            result[relative] = ('file', hashlib.sha256(path.read_bytes()).hexdigest())
        elif path.is_dir():
            result[relative] = ('directory',)
    return result


try:
    subprocess.run(['hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', str(mount), str(args.dmg.resolve())], check=True)
    attached = True
    packaged = mount / 'Bridge.app'
    subprocess.run([sys.executable, str(root / 'scripts/verify-mac-bundle.py'), str(packaged), '--arch', args.arch], check=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(packaged)], check=True)
    assert contents(packaged) == contents(args.app), 'DMG app differs from the signed source bundle'
    assert (mount / 'Applications').is_symlink() and os.readlink(mount / 'Applications') == '/Applications'
    assert f'Bridge-{ "Intel" if args.arch == "x86_64" else "AppleSilicon" }.dmg' in (mount / 'Install Bridge.txt').read_text()
    print(f'Verified {args.arch} DMG payload matches the signed source app')
finally:
    if attached:
        subprocess.run(['hdiutil', 'detach', str(mount)], check=True)
    mount.rmdir()
