#!/usr/bin/env python3
# Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later
"""Check generator/runtime parity and immutable code pins under signing rewrites."""
import importlib.util
import pathlib
import struct
import subprocess
import sys

spec = importlib.util.spec_from_file_location('application_identity', pathlib.Path(__file__).resolve().parents[1] / 'scripts/write-application-identity.py')
identity = importlib.util.module_from_spec(spec)
spec.loader.exec_module(identity)


def put(data, offset, value):
    struct.pack_into('>I', data, offset, value)


def directory():
    identifier = b'org.example.application\0'
    offset = 88 + len(identifier) + 7 * 32
    data = bytearray(offset + 2 * 32)
    for at, value in ((0, 0xfade0c02), (4, len(data)), (8, 0x20400), (16, offset), (20, 88), (24, 7), (28, 2), (32, 8192)):
        put(data, at, value)
    data[36:40] = bytes((32, 2, 0, 12))
    data[88:88 + len(identifier)] = identifier
    data[offset - 7 * 32:] = bytes((i % 251 for i in range(9 * 32)))
    return data


def blob(entries):
    data = bytearray(12 + len(entries) * 8)
    put(data, 0, 0xfade0cc0)
    put(data, 8, len(entries))
    for index, (slot, value) in enumerate(entries):
        put(data, 12 + index * 8, slot)
        put(data, 16 + index * 8, len(data))
        data.extend(value)
    put(data, 4, len(data))
    return data


def parity(data, valid=True):
    try:
        canonical = identity.canonical_blob(bytes(data))
    except ValueError:
        canonical = None
    result = subprocess.run([sys.argv[1], '--canonicalize'], input=data, capture_output=True)
    assert bool(canonical) == valid and (result.returncode == 0) == valid, 'generator/runtime rejection differs'
    if valid:
        assert result.stdout.decode().splitlines() == [value.hex() for value in canonical], 'generator/runtime canonical bytes differ'
    return canonical


def kernel(data, valid=True):
    result = subprocess.run([sys.argv[1], '--canonicalize-kernel'], input=data, capture_output=True)
    assert (result.returncode == 0) == valid, 'kernel signing frame rejection differs'
    return result.stdout.decode().splitlines() if valid else None


original = directory()
expected = parity(original)
expected_hex = [value.hex() for value in expected]
for padding in (0, 1, 7, 4096, 16384):
    assert kernel(original + bytes(padding)) == expected_hex, 'zero padding changed executable identity'
for bad in (original + b'X', original + bytes(7) + b'X', original[:-1],
            b'\0' * 8, original + bytes(1048577)):
    kernel(bad, False)
rewritten = bytearray(original)
put(rewritten, 8, 0x20100)
offset = identity.be32(rewritten, 16)
for slot in (5, 7):
    rewritten[offset - slot * 32:offset - (slot - 1) * 32] = bytes([0x9c] * 32)
assert parity(rewritten) == expected, 'allow only signature-loader metadata rewrite'
for at in (12, 32, 38, 40, offset - 6 * 32, offset - 4 * 32, offset, len(original) - 1):
    changed = bytearray(original)
    changed[at] ^= 1
    assert parity(changed) != expected, 'immutable signature or executable coverage changed'
alternates = blob([(0, original), (0x1000, rewritten)])
alternate_expected = parity(alternates)
assert kernel(alternates + bytes(4096)) == [value.hex() for value in alternate_expected]
foreign = bytearray(original)
foreign[-1] ^= 1
foreign_blob = blob([(0, original), (0x1000, foreign)])
assert kernel(foreign_blob + bytes(7)) != [expected_hex[0], expected_hex[0]], 'padding hid a foreign alternate directory'
kernel(blob([(0, original)]) + foreign, False)
parity(blob([(0, original), (5, struct.pack('>II', 0xfade7171, 8))]))
for entries in ([(0, original), (0, rewritten)], [(0x1000, original)], [(0, original), (42, rewritten)], [(0, struct.pack('>II', 0xfade7171, 8))]):
    parity(blob(entries), False)
for at, value in ((4, 0), (8, 0x20700), (16, 12), (20, 0), (24, 65), (28, 0xffffffff)):
    bad = bytearray(original)
    put(bad, at, value)
    parity(bad, False)
bad = bytearray(original)
bad[36] = 20
parity(bad, False)
bad = blob([(0, original), (5, struct.pack('>II', 0xfade7171, 8))])
put(bad, 24, 28)
parity(bad, False)
for bad in (b'', b'\0' * 8, original[:-1], original + b'\0', b'\0' * 1048577):
    parity(bad, False)
kernel(blob([(0, original), (42, rewritten)]) + bytes(7), False)
kernel(blob([(0, original), (0, rewritten)]) + bytes(7), False)
signed = blob([(0, original)])
macho = struct.pack('<8I', 0xfeedfacf, 0x100000c, 0, 2, 1, 16, 0, 0)
macho += struct.pack('<4I', 0x1d, 16, 48, len(signed)) + signed
assert identity.executable_directories(macho) == expected
padded = macho[:32] + struct.pack('<4I', 0x1d, 16, 48, len(signed) + 7) + signed + bytes(7)
assert identity.executable_directories(padded) == expected
try:
    identity.executable_directories(padded[:-1] + b'X')
except ValueError:
    pass
else:
    raise AssertionError('accepted nonzero signature padding')
fat = struct.pack('>II', 0xcafebabe, 2)
fat += struct.pack('>5I', 0x100000c, 0, 48, len(macho), 0)
fat += struct.pack('>5I', 0x100000c, 2, 48 + len(macho), len(macho), 0)
assert identity.executable_directories(fat + macho + macho) == expected + expected
print('[application-signing-identity] PASS: signing rewrites, immutable coverage, kernel zero padding, malformed/decoy directories and generator/runtime parity')
