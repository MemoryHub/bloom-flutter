#!/usr/bin/env python3
"""Check fields defined in the actual minified APK, including mapping omissions."""
from pathlib import Path
import re
import struct
import zipfile

app = Path(__file__).resolve().parents[3]
mapping = app / 'build/app/outputs/mapping/release/mapping.txt'
apk = app / 'build/app/outputs/flutter-apk/app-release.apk'
classes = dict(re.findall(r'^(espressif\.[^ ]+) -> ([^ :]+):$', mapping.read_text(), re.M))
critical = {
    'espressif.Sec1$SessionCmd0': {'clientPubkey_'},
    'espressif.Sec1$SessionResp0': {'devicePubkey_', 'deviceRandom_'},
    'espressif.Sec1$SessionCmd1': {'clientVerifyData_'},
    'espressif.Sec1$SessionResp1': {'deviceVerifyData_'},
    'espressif.Session$SessionData': {'secVer_', 'proto_', 'protoCase_'},
}

def definitions(data):
    assert data[:4] == b'dex\n'
    def uint(at): return struct.unpack_from('<I', data, at)[0]
    def leb(at):
        value = shift = 0
        while True:
            byte = data[at]; at += 1
            value |= (byte & 127) << shift
            if byte < 128: return value, at
            shift += 7
    strings = []
    for i in range(uint(56)):
        at = uint(uint(60) + 4 * i)
        _, at = leb(at)
        strings.append(data[at:data.index(0, at)].decode('utf-8', errors='replace'))
    types = [strings[uint(uint(68) + 4 * i)] for i in range(uint(64))]
    fields = [strings[uint(uint(84) + 8 * i + 4)] for i in range(uint(80))]
    result = {}
    for i in range(uint(96)):
        at = uint(100) + i * 32
        name = types[uint(at)]
        pos = uint(at + 24)
        if not pos: continue
        counts = []
        for _ in range(4):
            count, pos = leb(pos); counts.append(count)
        defined = set()
        for count in counts[:2]:
            index = 0
            for _ in range(count):
                delta, pos = leb(pos); index += delta
                _, pos = leb(pos)
                defined.add(fields[index])
        result[name] = defined
    return result

all_fields = {}
with zipfile.ZipFile(apk) as archive:
    for entry in archive.namelist():
        if re.fullmatch(r'classes\d*\.dex', entry):
            all_fields.update(definitions(archive.read(entry)))
for name, required in critical.items():
    descriptor = 'L' + classes[name].replace('.', '/') + ';'
    missing = required - all_fields.get(descriptor, set())
    assert not missing, f'{name}: missing APK instance fields {missing}'
print('PASS actual release APK defines all 8 Security1/session reflective fields with original names')
