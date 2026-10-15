#!/usr/bin/env python3
"""Verify the real 1.0 artifacts, including removal of experimental mirroring."""
import os
import re
import pathlib
import plistlib
import subprocess
import zipfile

root = pathlib.Path(__file__).resolve().parent.parent
apk = root / 'dist/Bridge-1.0.apk'
sdk = pathlib.Path(os.environ.get('ANDROID_HOME', pathlib.Path.home() / 'Library/Android/sdk'))
source_info = plistlib.loads((root / 'mac/Info.plist').read_bytes())
for label, architecture in [('AppleSilicon', 'arm64'), ('Intel', 'x86_64')]:
    app = root / f'dist/macos/{label}/Bridge.app'
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    assert info['CFBundleShortVersionString'] == source_info['CFBundleShortVersionString']
    assert info['CFBundleVersion'] == source_info['CFBundleVersion']
    assert info['LSUIElement'] is True
    subprocess.run(['python3', str(root / 'scripts/verify-mac-bundle.py'), str(app), '--arch', architecture], check=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    cli = (app / 'Contents/Resources/Tools/bridge-cli').read_text()
    assert 'scrcpy' not in cli and "'mirror'" not in cli
    binary = (app / 'Contents/MacOS/Bridge').read_bytes()
    for removed in [b'PhoneControlSession', b'NativeMirrorState', b'PhoneControlEngine', b'scrcpy']:
        assert removed not in binary, f'Mac still includes {removed!r}'
    dmg = root / f'dist/Bridge-{label}.dmg'
    assert dmg.is_file() and pathlib.Path(str(dmg) + '.sha256').is_file(), f'Missing {label} installer/checksum'
manifest = subprocess.check_output([str(sdk / 'build-tools/36.0.0/aapt2'), 'dump', 'xmltree', str(apk), '--file', 'AndroidManifest.xml'], text=True)
assert 'versionName(0x0101021c)="1.0"' in manifest
android_config = (root / 'android/app/build.gradle.kts').read_text()
version_code = re.search(r'versionCode = (\d+)', android_config).group(1)
assert f'versionCode(0x0101021b)={version_code}' in manifest
badging = subprocess.check_output([str(sdk / 'build-tools/36.0.0/aapt2'), 'dump', 'badging', str(apk)], text=True)
assert "minSdkVersion:'29'" in badging, 'Android minimum must remain API 29'
debuggable = re.search(r'debuggable\(0x0101000f\)=([^\s]+)', manifest)
assert debuggable is None or debuggable.group(1) == 'false', 'Android release is debuggable'
assert 'dev.bridge.companion.MainActivity' in manifest
for removed in ['MirrorBindingReceiver', 'PointerAssistanceService', 'BIND_ACCESSIBILITY_SERVICE', 'pointer_assistance']:
    assert removed not in manifest, f'Android manifest still includes {removed}'
with zipfile.ZipFile(apk) as archive:
    assert not any('pointer_assistance' in name for name in archive.namelist())
    for name in archive.namelist():
        if name.endswith('.dex'):
            data = archive.read(name)
            assert b'PointerAssistanceService' not in data and b'MirrorBindingReceiver' not in data
print('Verified both native macOS 13 editions, installers, menu-bar mode, Android 10 minimum, release versions and absence of mirroring')
