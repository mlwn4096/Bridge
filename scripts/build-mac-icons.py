#!/usr/bin/env python3
"""Compile the app identity with Apple's asset compiler for all macOS surfaces."""
import json
import pathlib
import plistlib
import subprocess
import sys
import tempfile

root = pathlib.Path(__file__).resolve().parent.parent
resources = pathlib.Path(sys.argv[1]).resolve()
resources.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='bridge-native-icons-', dir=root / '.build') as directory:
    stage = pathlib.Path(directory)
    catalog = stage / 'BridgeAssets.xcassets'
    iconset = catalog / 'BridgeAppIcon.appiconset'
    iconset.mkdir(parents=True)
    info = {'author': 'xcode', 'version': 1}
    (catalog / 'Contents.json').write_text(json.dumps({'info': info}))
    images = []
    for size in [16, 32, 128, 256, 512]:
        for scale in [1, 2]:
            name = f'icon_{size}x{size}' + ('@2x' if scale == 2 else '') + '.png'
            subprocess.run(['sips', '-z', str(size * scale), str(size * scale), str(root / 'mac/Resources/BridgeAppIcon.png'),
                            '--out', str(iconset / name)], check=True, stdout=subprocess.DEVNULL)
            images.append({'idiom': 'mac', 'size': f'{size}x{size}', 'scale': f'{scale}x', 'filename': name})
    (iconset / 'Contents.json').write_text(json.dumps({'info': info, 'images': images}, indent=2))
    partial = stage / 'IconInfo.plist'
    subprocess.run(['xcrun', 'actool', str(catalog), '--compile', str(resources), '--platform', 'macosx',
                    '--minimum-deployment-target', '13.0', '--app-icon', 'BridgeAppIcon',
                    '--output-partial-info-plist', str(partial), '--output-format', 'human-readable-text'], check=True)
    result = plistlib.loads(partial.read_bytes())
    assert result['CFBundleIconName'] == 'BridgeAppIcon' and result['CFBundleIconFile'] == 'BridgeAppIcon'
    assert (resources / 'Assets.car').is_file() and (resources / 'BridgeAppIcon.icns').is_file()
    # actool's companion ICNS contains only a small legacy subset on this
    # toolchain. Supply a complete standalone fallback for consumers that do
    # not resolve the CoreUI catalog (Finder/Launch Services included).
    subprocess.run([sys.executable, str(root / 'scripts/make-icns.py'), str(iconset),
                    str(resources / 'BridgeLauncherIcon.icns')], check=True)
print('Compiled native app icon catalog and complete standalone launcher ICNS')
