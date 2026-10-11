#!/usr/bin/env python3
"""Pin immutable CodeDirectory identity after final application signing."""
# Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later
import hashlib
import pathlib
import struct
import subprocess
import sys


def be32(data, offset):
    return struct.unpack_from('>I', data, offset)[0]


def canonical_directory(data):
    if not 44 <= len(data) <= 1048576 or be32(data, 0) != 0xfade0c02 or be32(data, 4) != len(data):
        raise ValueError('invalid CodeDirectory bounds')
    header = {0x20001: 44, 0x20100: 48, 0x20200: 52, 0x20300: 64,
              0x20400: 88, 0x20500: 96, 0x20600: 108}.get(be32(data, 8))
    size, kind = data[36:38]
    if header is None or len(data) < header or (kind, size) not in {(1, 20), (2, 32), (3, 20), (4, 48)}:
        raise ValueError('unsupported CodeDirectory format')
    offset, identifier, special, code = struct.unpack_from('>4I', data, 16)
    special_start = offset - special * size
    if special > 64 or code == 0 or offset > len(data) or special_start < header or code > (len(data) - offset) // size or not header <= identifier < special_start:
        raise ValueError('invalid CodeDirectory hash coverage')
    end = data.find(b'\0', identifier)
    if end < 0 or end >= special_start:
        raise ValueError('invalid CodeDirectory identifier')
    canonical = bytearray(data)
    canonical[8:12] = bytes(4)
    for slot in (5, 7):
        if special >= slot:
            canonical[offset - slot * size:offset - (slot - 1) * size] = bytes(size)
    return bytes(canonical)


def canonical_blob(data):
    if not 8 <= len(data) <= 1048576 or be32(data, 4) != len(data):
        raise ValueError('invalid signature bounds')
    if be32(data, 0) == 0xfade0c02:
        return [canonical_directory(data)]
    if len(data) < 12 or be32(data, 0) != 0xfade0cc0:
        raise ValueError('invalid signature header')
    count = be32(data, 8)
    if not 1 <= count <= 64 or count > (len(data) - 12) // 8:
        raise ValueError('invalid signature index')
    table = 12 + count * 8
    slots, ranges, directories = set(), [], []
    for index in range(count):
        slot, offset = struct.unpack_from('>II', data, 12 + index * 8)
        if slot in slots or not table <= offset <= len(data) - 8:
            raise ValueError('duplicate or invalid signature slot')
        slots.add(slot)
        length = be32(data, offset + 4)
        if length < 8 or length > len(data) - offset or any(offset < end and start < offset + length for start, end in ranges):
            raise ValueError('overlapping signature blobs')
        ranges.append((offset, offset + length))
        executable = slot == 0 or 0x1000 <= slot < 0x1005
        if executable != (be32(data, offset) == 0xfade0c02):
            raise ValueError('unexpected CodeDirectory slot')
        if executable:
            directories.append(canonical_directory(data[offset:offset + length]))
    if 0 not in slots or not directories:
        raise ValueError('missing primary CodeDirectory')
    return directories


def executable_directories(data, nested=False):
    if len(data) < 8:
        raise ValueError('truncated executable')
    magic = data[:4]
    if magic in (b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf') and not nested:
        count = be32(data, 4)
        width = 20 if magic[-1] == 0xbe else 32
        if not 1 <= count <= 64 or 8 + count * width > len(data):
            raise ValueError('invalid universal executable')
        result, ranges = [], []
        for index in range(count):
            at = 8 + index * width
            offset, size = struct.unpack_from('>II' if width == 20 else '>QQ', data, at + 8)
            if offset < 8 + count * width or not size or offset + size > len(data) or any(offset < end and start < offset + size for start, end in ranges):
                raise ValueError('invalid executable slice')
            ranges.append((offset, offset + size))
            result.extend(executable_directories(data[offset:offset + size], True))
        return result
    formats = {b'\xcf\xfa\xed\xfe': ('<', 32), b'\xfe\xed\xfa\xcf': ('>', 32),
               b'\xce\xfa\xed\xfe': ('<', 28), b'\xfe\xed\xfa\xce': ('>', 28)}
    if magic not in formats:
        raise ValueError('unsupported executable format')
    endian, header = formats[magic]
    if len(data) < header:
        raise ValueError('truncated Mach-O header')
    count, size = struct.unpack_from(endian + 'II', data, 16)
    if count > 65536 or size > len(data) - header:
        raise ValueError('invalid load commands')
    offset, result = header, None
    for _ in range(count):
        if offset + 8 > header + size:
            raise ValueError('truncated load command')
        command, length = struct.unpack_from(endian + 'II', data, offset)
        if length < 8 or offset + length > header + size:
            raise ValueError('invalid load command')
        if command == 0x1d:
            if length < 16 or result is not None:
                raise ValueError('invalid signature command')
            start, span = struct.unpack_from(endian + 'II', data, offset + 8)
            if start < header + size or start + span > len(data):
                raise ValueError('invalid embedded signature')
            if span < 8:
                raise ValueError('truncated embedded signature')
            declared = be32(data, start + 4)
            if declared > span or any(data[start + declared:start + span]):
                raise ValueError('invalid signature padding')
            result = canonical_blob(data[start:start + declared])
        offset += length
    if offset != header + size or result is None:
        raise ValueError('missing embedded signature')
    return result


def main():
    if len(sys.argv) != 4:
        sys.exit('usage: write-application-identity.py <ldid> <signed-executable> <manifest>')
    subprocess.check_output([sys.argv[1], '-h', sys.argv[2]])
    hashes = {hashlib.sha256(data).hexdigest()[:40] for data in executable_directories(pathlib.Path(sys.argv[2]).read_bytes())}
    if not hashes or len(hashes) > 64:
        sys.exit('signed application has no usable code identity')
    destination = pathlib.Path(sys.argv[3])
    destination.write_text('CYDIA-APPLICATION-IDENTITY-1\n' + ''.join(value + '\n' for value in sorted(hashes)), encoding='ascii')
    destination.chmod(0o644)


if __name__ == '__main__':
    try:
        main()
    except ValueError as error:
        sys.exit(str(error))
