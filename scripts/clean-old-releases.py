#!/usr/bin/env python3
"""Remove superseded packages for one platform after its new release succeeds."""
import pathlib
import re
import sys

current = pathlib.Path(sys.argv[1]).resolve()
if current.suffix not in {'.dmg', '.apk'} or not current.is_file():
    raise SystemExit('An existing DMG or APK is required before cleanup')
pattern = re.compile(r'Bridge-\d+\.\d+(?:\.\d+)?(?:[-+][A-Za-z0-9.-]+)?' + re.escape(current.suffix))
for package in sorted(current.parent.iterdir()):
    if package == current or not package.is_file() or not pattern.fullmatch(package.name):
        continue
    for path in [package, *(pathlib.Path(str(package) + suffix) for suffix in ('.sha256', '.idsig', '.build.json'))]:
        if path.is_file():
            path.unlink()
            print('Removed', path.name)
