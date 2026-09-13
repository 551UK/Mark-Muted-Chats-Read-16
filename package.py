#!/usr/bin/env python3
"""Build a root-owned DEB with standard-library tar/ar support, then verify it."""
import gzip
import io
import pathlib
import plistlib
import struct
import tarfile

ROOT = pathlib.Path(__file__).resolve().parent
fields = dict(line.split(': ', 1) for line in (ROOT / 'control').read_text().splitlines())
assert fields['Architecture'] == 'iphoneos-arm64'
assert 'com.apple.MobileSMS' in (ROOT / 'MutedRead.plist').read_text()
def validate_macho(image_bytes):
    assert image_bytes[:4] == b'\xca\xfe\xba\xbe', 'Expected universal signed Mach-O'
    arch_count = struct.unpack_from('>I', image_bytes, 4)[0]
    arches = [struct.unpack_from('>IIIII', image_bytes, 8 + 20*i) for i in range(arch_count)]
    assert {(a[0], a[1] & 0xffffff) for a in arches} == {(0x100000c, 0), (0x100000c, 2)}
    for cpu, subtype, offset, size, align in arches:
        image = image_bytes[offset:offset + size]
        assert image[:4] == b'\xcf\xfa\xed\xfe'
        assert struct.unpack_from('<I', image, 12)[0] == 6  # MH_DYLIB
        ncmds = struct.unpack_from('<I', image, 16)[0]
        pos = 32
        signed = ios = False
        for _ in range(ncmds):
            cmd, cmdsize = struct.unpack_from('<II', image, pos)
            assert cmdsize >= 8
            if cmd == 0x1d:
                sigoff, sigsize = struct.unpack_from('<II', image, pos + 8)
                signed = sigsize > 0 and sigoff + sigsize <= len(image)
            if cmd == 0x32:
                ios = struct.unpack_from('<I', image, pos + 8)[0] == 2
            if cmd == 0x25:
                ios = True
            pos += cmdsize
        assert signed and ios, 'Each slice must be signed for iOS'

def tar_gz(entries, include_directories=False):
    stream = io.BytesIO()
    with tarfile.open(fileobj=stream, mode='w', format=tarfile.USTAR_FORMAT) as archive:
        if include_directories:
            directories = {'.'}
            for name, _, _ in entries:
                parent = pathlib.PurePosixPath(name).parent
                while str(parent) != '.':
                    directories.add('./' + str(parent))
                    parent = parent.parent
            for name in sorted(directories, key=lambda d: (d.count('/'), d)):
                item = tarfile.TarInfo(name + '/')
                item.type = tarfile.DIRTYPE
                item.mode = 0o755
                item.uid = item.gid = 0
                item.uname = item.gname = 'root'
                item.mtime = 0
                archive.addfile(item)
        for name, data, mode in entries:
            item = tarfile.TarInfo(name)
            item.size, item.mode = len(data), mode
            item.uid = item.gid = 0
            item.uname = item.gname = 'root'
            item.mtime = 0
            archive.addfile(item, io.BytesIO(data))
    return gzip.compress(stream.getvalue(), mtime=0)


binary = (ROOT / 'build/MutedRead.dylib').read_bytes()
validate_macho(binary)
control = tar_gz([('./control', (ROOT / 'control').read_bytes(), 0o644)])
base = './var/jb/Library/MobileSubstrate/DynamicLibraries/'
entries = [(base + 'MutedRead.dylib', binary, 0o755),
           (base + 'MutedRead.plist', (ROOT / 'MutedRead.plist').read_bytes(), 0o644)]
assert len({e[0] for e in entries}) == len(entries)
data = tar_gz(entries, include_directories=True)
out = bytearray(b'!<arch>\n')
for name, body in [('debian-binary', b'2.0\n'), ('control.tar.gz', control), ('data.tar.gz', data)]:
    header = f'{name + "/":<16}{0:<12}{0:<6}{0:<6}{"100644":<8}{len(body):<10}`\n'.encode('ascii')
    assert len(header) == 60
    out.extend(header + body)
    if len(body) % 2:
        out.extend(b'\n')
path = ROOT / 'packages' / f'{fields["Package"]}_{fields["Version"]}_{fields["Architecture"]}.deb'
path.parent.mkdir(exist_ok=True)
path.write_bytes(out)
# Confirm payload inventory and byte identity; never ship the supplied Glow DEB.
with tarfile.open(fileobj=io.BytesIO(data), mode='r:gz') as archive:
    assert [m.name for m in archive.getmembers() if m.isfile()] == [e[0] for e in entries]
    members = {m.name: m for m in archive.getmembers()}
    for name, _, _ in entries:
        parent = pathlib.PurePosixPath(name).parent
        while str(parent) != '.':
            directory = members['./' + str(parent)]
            assert directory.isdir() and directory.mode == 0o755
            assert directory.uid == directory.gid == 0
            parent = parent.parent
    for name, content, mode in entries:
        item = archive.getmember(name)
        assert item.uid == item.gid == 0 and item.mode == mode
        assert archive.extractfile(item).read() == content
print(f'Validated DEB: {path.name} ({path.stat().st_size} bytes)')

