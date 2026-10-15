#!/usr/bin/env python3
"""Verify runnable Mac executable headers, independently of codesigning."""
import json
import subprocess
import os
import pathlib
import plistlib
import struct
import sys
import tempfile
import argparse

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('bundle', type=pathlib.Path)
parser.add_argument('--arch', choices=['arm64', 'x86_64'])
args = parser.parse_args()
bundle = args.bundle
download_qr = bundle / "Contents/Resources/AndroidDownloadQR.png"
assert download_qr.read_bytes()[:8] == b'\x89PNG\r\n\x1a\n', "Missing companion-download QR"
for app in [bundle, *bundle.glob("Contents/PlugIns/*.appex")]:
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    executable = app / "Contents/MacOS" / info["CFBundleExecutable"]
    header = executable.read_bytes()[:16]
    assert len(header) == 16, f"Missing executable: {executable}"
    magic, cpu, subtype, filetype = struct.unpack("<IIII", header)
    expected_cpu = {'arm64': 0x0100000C, 'x86_64': 0x01000007}
    assert magic == 0xFEEDFACF and cpu in expected_cpu.values() and filetype == 2, (
        f"Expected a native Mac Mach-O executable: {executable}"
    )
    architecture = next(name for name, value in expected_cpu.items() if cpu == value)
    assert not args.arch or architecture == args.arch, f'Wrong architecture: {executable}'
    assert info['LSMinimumSystemVersion'] == '13.0', f'Wrong minimum OS: {app}'
    load_commands = subprocess.check_output(['otool', '-l', str(executable)], text=True)
    assert any(line.split() == ['minos', '13.0'] for line in load_commands.splitlines()), (
        f'Executable deployment target must be macOS 13.0: {executable}'
    )
    if app != bundle:
        parent = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
        assert info['CFBundleVersion'] == parent['CFBundleVersion'], 'Extension build mismatch'
        assert info['CFBundleShortVersionString'] == parent['CFBundleShortVersionString'], 'Extension version mismatch'
        parent_arch = subprocess.check_output(['lipo', '-archs', str(bundle / 'Contents/MacOS' / parent['CFBundleExecutable'])], text=True).strip()
        assert parent_arch == architecture, 'Extension architecture mismatch'
    assert os.access(executable, os.X_OK), f"Executable permission missing: {executable}"
    names = [p.name.casefold() for p in executable.parent.iterdir()]
    assert len(names) == len(set(names)), "Case-insensitive filename collision"
# Validate the standalone fallback independently of the named CoreUI catalog.
info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
assert info.get("CFBundleIconName") == "BridgeAppIcon", "Missing named app icon identity"
icon = bundle / "Contents/Resources" / info["CFBundleIconFile"]
data = icon.read_bytes()
assert data[:4] == b"icns" and struct.unpack(">I", data[4:8])[0] == len(data), "Invalid ICNS header"
expected_icns = {b'icp4': 16, b'icp5': 32, b'icp6': 64, b'ic07': 128,
                 b'ic08': 256, b'ic09': 512, b'ic10': 1024, b'ic11': 32,
                 b'ic12': 64, b'ic13': 256, b'ic14': 512}
representations = set()
offset = 8
while offset < len(data):
    kind, length = struct.unpack(">4sI", data[offset:offset + 8])
    assert length > 8 and offset + length <= len(data), "Invalid ICNS representation"
    payload = data[offset + 8:offset + length]
    assert kind in expected_icns and kind not in representations, "Unexpected ICNS representation"
    assert payload[:8] == b'\x89PNG\r\n\x1a\n' and payload[12:16] == b'IHDR', "Invalid ICNS PNG"
    assert struct.unpack('>II', payload[16:24]) == (expected_icns[kind],) * 2, "Wrong ICNS PNG dimensions"
    representations.add(kind); offset += length
assert offset == len(data) and representations == set(expected_icns), "Incomplete standalone ICNS"
with tempfile.TemporaryDirectory(prefix='bridge-icon-decode-') as temporary:
    decoded = pathlib.Path(temporary) / 'icon.png'
    subprocess.run(['sips', '-s', 'format', 'png', str(icon), '--out', str(decoded)],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    assert decoded.read_bytes()[:8] == b'\x89PNG\r\n\x1a\n', 'ICNS decoding failed'
assets = bundle / "Contents/Resources/Assets.car"
assert assets.is_file(), "Missing CoreUI catalog for notification icon resolution"
records = json.loads(subprocess.check_output(["/usr/bin/assetutil", "--info", str(assets)], text=True))
icons = [record for record in records if record.get("Name") == info["CFBundleIconName"] and record.get("AssetType") == "Icon Image"]
expected = {(size * scale, size * scale, scale) for size in [16, 32, 128, 256, 512] for scale in [1, 2]}
assert {(item["PixelWidth"], item["PixelHeight"], item["Scale"]) for item in icons} == expected, "Incomplete named app icon resolutions"
assert all(item.get("SizeOnDisk", 0) > 0 for item in icons), "Empty icon renditions"
metadata = json.loads((bundle / 'Contents/Resources/Metadata.appintents/extract.actionsdata').read_text())
expected_intents = {'RingPhoneIntent', 'StopRingingPhoneIntent', 'SendTextToPhoneIntent', 'SendLinkToPhoneIntent', 'PhoneBatteryIntent', 'PauseSendQueueIntent', 'ResumeSendQueueIntent'}
assert expected_intents <= set(metadata['actions']), 'Missing App Intents'
assert len(metadata['autoShortcuts']) == 6, 'Missing App Shortcuts'
print("Native named app icon catalog and 10 resolutions verified")
print("Native app and extension executable headers verified")
