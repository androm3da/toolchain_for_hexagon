#!/usr/bin/env python3
"""Streaming tar filter that zeroes symlink mode fields.

Reads a tar stream on stdin and writes the modified stream to stdout.
Symlink entries (typeflag '2') get their mode field set to 0000000\\0,
which causes GNU tar to skip lchmod() on extraction -- preventing EPERM
failures under rootless podman / user-namespace overlay storage.

Usage:
    tar c -C dir tree | python3 tar-strip-symlink-modes.py | zstd ...
"""

import sys

BLOCK = 512
MODE_OFF = 100
MODE_LEN = 8
TYPE_OFF = 156
CHKSUM_OFF = 148
CHKSUM_LEN = 8
SYMTYPE = ord('2')


def recompute_checksum(header):
    """Unsigned sum of header bytes with chksum field treated as spaces."""
    pre = header[:CHKSUM_OFF]
    post = header[CHKSUM_OFF + CHKSUM_LEN:]
    s = sum(pre) + ord(' ') * CHKSUM_LEN + sum(post)
    return b'%06o\x00 ' % s


def main():
    stdin = sys.stdin.buffer
    stdout = sys.stdout.buffer

    while True:
        header = stdin.read(BLOCK)
        if len(header) < BLOCK:
            if header:
                stdout.write(header)
            break

        if header == b'\x00' * BLOCK:
            stdout.write(header)
            continue

        if header[TYPE_OFF] == SYMTYPE:
            header = bytearray(header)
            header[MODE_OFF:MODE_OFF + MODE_LEN] = b'0000000\x00'
            header[CHKSUM_OFF:CHKSUM_OFF + CHKSUM_LEN] = recompute_checksum(header)
            header = bytes(header)

        stdout.write(header)

        # Copy data blocks for this entry
        size_field = header[124:124 + 12]
        try:
            size = int(size_field.strip(b'\x00 '), 8)
        except ValueError:
            size = 0

        data_blocks = (size + BLOCK - 1) // BLOCK
        for _ in range(data_blocks):
            block = stdin.read(BLOCK)
            if len(block) < BLOCK:
                stdout.write(block)
                return
            stdout.write(block)


if __name__ == '__main__':
    main()
