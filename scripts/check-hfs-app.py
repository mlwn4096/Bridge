#!/usr/bin/env python3
"""Inspect/clean only Bridge.app Finder metadata in an unmounted HFS+ hybrid.

The fallback image builder adds default Finder icon-location bytes (ffffffff),
which strict code signing rejects. HFS+ catalog layout follows Apple TN1150.
Never edits signed file contents. Unsupported images fail closed.
"""
import argparse
import pathlib
import stat
import struct

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('operation', choices=['clean', 'verify'])
parser.add_argument('image', type=pathlib.Path)
parser.add_argument('source', type=pathlib.Path)
parser.add_argument('--extract', type=pathlib.Path)
args = parser.parse_args()
data = bytearray(args.image.read_bytes())
assert len(data) <= 128 * 1024 * 1024, 'Hybrid image exceeds inspection bound'
def u16(offset): return struct.unpack_from('>H', data, offset)[0]
def u32(offset): return struct.unpack_from('>I', data, offset)[0]
def u64(offset): return struct.unpack_from('>Q', data, offset)[0]
assert data[512:514] == b'PM', 'Expected Apple partition map'
partitions = u32(516)
assert 1 <= partitions <= 64
hfs = []
for index in range(1, partitions + 1):
    offset = index * 512
    assert data[offset:offset+2] == b'PM'
    if data[offset+48:offset+80].rstrip(b'\0') == b'Apple_HFS':
        hfs.append((u32(offset+8)*512, u32(offset+12)*512))
assert len(hfs) == 1, 'Expected one HFS+ partition'
base, volume_size = hfs[0]
assert base + volume_size <= len(data)
header = base + 1024
assert data[header:header+2] == b'H+', 'Expected unwrapped HFS+'
assert not (u32(header+4) & (1 << 13)), 'Journaled images cannot be edited offline'
block = u32(header+40)
assert 512 <= block <= 65536 and block & (block-1) == 0

def fork(offset):
    size = u64(offset)
    assert size <= 64 * 1024 * 1024
    spans = []
    for index in range(8):
        start, count = u32(offset+16+index*8), u32(offset+20+index*8)
        if not count: continue
        assert start*block + count*block <= volume_size
        spans.append((base + start*block, count*block))
    assert sum(length for _, length in spans) >= size, 'Overflow extents are unsupported'
    return size, spans

def read_fork(offset):
    size, spans = fork(offset)
    return b''.join(data[start:start+length] for start,length in spans)[:size]

catalog_size, spans = fork(header+272)
# Catalog needs a bounded contiguous extent for record edits.
assert len(spans) == 1, 'Fragmented catalog is unsupported'
catalog = spans[0][0]
node_size = u16(catalog+32)
assert node_size in [512,1024,2048,4096,8192,16384,32768]
assert catalog_size % node_size == 0
folders = {}
records = []
for node in range(catalog_size // node_size):
    offset = catalog + node*node_size
    if data[offset+8] != 255: continue  # Leaf descriptor kind == -1.
    count = u16(offset+10)
    assert count <= (node_size-14)//4
    for record in range(count):
        start = offset + u16(offset+node_size-2*(record+1))
        end = offset + u16(offset+node_size-2*(record+2))
        assert offset+14 <= start < end <= offset+node_size-2*(count+1)
        key_length = u16(start)
        parent = u32(start+2)
        name_length = u16(start+6)
        assert key_length == 6 + 2*name_length
        name = bytes(data[start+8:start+8+2*name_length]).decode('utf-16be')
        body = start+2+key_length
        kind = u16(body)
        if kind not in [1,2]: continue  # Skip folder/file thread records.
        assert body + (88 if kind==1 else 248) <= end
        identifier = u32(body+8)
        if kind == 1: folders[identifier] = (parent,name)
        records.append((parent,name,body,kind,identifier))

def relative_path(parent, name):
    parts = [name]
    seen = set()
    while parent != 2:
        assert parent not in seen and parent in folders, 'Invalid catalog ancestry'
        seen.add(parent)
        parent, ancestor = folders[parent]
        parts.insert(0,ancestor)
    assert all(part and part not in ['.','..'] and '/' not in part and '\0' not in part for part in parts)
    return pathlib.PurePosixPath(*parts)

files = {}
app_records = []
for parent,name,body,kind,identifier in records:
    if identifier == 2: continue
    path = relative_path(parent,name)
    if path.parts[0] != 'Bridge.app': continue
    app_records.append((path,body,kind))
    if kind == 2:
        mode = u16(body+42)
        assert stat.S_ISREG(mode), 'Nonregular app payload unsupported'
        assert u64(body+168) == 0, f'Resource fork in {path}'
        contents = read_fork(body+88)
        relative = pathlib.Path(*path.parts[1:])
        assert relative not in files
        files[relative] = (contents, mode)
assert app_records and files, 'Missing Bridge.app'
source_files = {path.relative_to(args.source): path for path in args.source.rglob('*') if path.is_file()}
assert set(files) == set(source_files), 'Image and signed-source file inventories differ'
for path,(contents,mode) in files.items():
    source = source_files[path]
    assert not source.is_symlink()
    assert contents == source.read_bytes(), f'Signed bytes changed in {path}'
    assert mode & 0o111 == source.stat().st_mode & 0o111, f'Executable permissions changed in {path}'
changed = 0
for path,body,kind in app_records:
    if any(data[body+48:body+80]):
        assert args.operation == 'clean', f'Nonzero Finder information in {path}'
        data[body+48:body+80] = bytes(32)
        changed += 1
if args.operation == 'clean': args.image.write_bytes(data)
if args.extract:
    assert not args.extract.exists(), 'Extraction target must be new'
    args.extract.mkdir(parents=True)
    for path,body,kind in app_records:
        relative = pathlib.Path(*path.parts[1:])
        target = args.extract / relative
        if kind == 1: target.mkdir(parents=True, exist_ok=True)
    for path,(contents,mode) in files.items():
        target = args.extract / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(contents)
        target.chmod(mode & 0o777)
print(f'{args.operation}: {len(files)} signed files match source; {changed} Finder metadata records cleared')
