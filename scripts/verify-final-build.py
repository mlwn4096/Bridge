#!/usr/bin/env python3
"""Verify the real 1.0 artifacts, including removal of experimental mirroring."""
import os
import pathlib
import plistlib
import subprocess
import zipfile

root = pathlib.Path(__file__).resolve().parent.parent
app = root / 'dist/Bridge.app'
apk = root / 'dist/Bridge-1.0.apk'
sdk = pathlib.Path(os.environ.get('ANDROID_HOME', pathlib.Path.home() / 'Library/Android/sdk'))
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
assert info['CFBundleShortVersionString'] == '1.0' and info['CFBundleVersion'] == '21'
assert info['LSUIElement'] is True
extension_info = plistlib.loads((app / 'Contents/PlugIns/BridgeShare.appex/Contents/Info.plist').read_bytes())
assert extension_info['CFBundleVersion'] == info['CFBundleVersion']
assert (app / 'Contents/Resources' / info['CFBundleIconFile']).is_file()
assert (app / 'Contents/Resources/BridgeNotification.png').is_file()
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
cli = (app / 'Contents/Resources/Tools/bridge-cli').read_text()
assert 'scrcpy' not in cli and "'mirror'" not in cli
binary = (app / 'Contents/MacOS/Bridge').read_bytes()
for removed in [b'PhoneControlSession', b'NativeMirrorState', b'PhoneControlEngine', b'scrcpy']:
    assert removed not in binary, f'Mac still includes {removed!r}'
manifest = subprocess.check_output([str(sdk / 'build-tools/36.0.0/aapt2'), 'dump', 'xmltree', str(apk), '--file', 'AndroidManifest.xml'], text=True)
assert 'versionName(0x0101021c)="1.0"' in manifest
assert 'versionCode(0x0101021b)=12' in manifest
assert 'debuggable(0x0101000f)=false' in manifest
assert 'dev.bridge.companion.MainActivity' in manifest
for removed in ['MirrorBindingReceiver', 'PointerAssistanceService', 'BIND_ACCESSIBILITY_SERVICE', 'pointer_assistance']:
    assert removed not in manifest, f'Android manifest still includes {removed}'
with zipfile.ZipFile(apk) as archive:
    assert not any('pointer_assistance' in name for name in archive.namelist())
    for name in archive.namelist():
        if name.endswith('.dex'):
            data = archive.read(name)
            assert b'PointerAssistanceService' not in data and b'MirrorBindingReceiver' not in data
print('Verified 1.0 versions, menu-bar mode, non-debuggable Android build and absence of mirroring in both packages')
