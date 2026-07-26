#!/usr/bin/env python3

#  Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
#  SPDX-License-Identifier: BSD-3-Clause-Clear

"""Extract a tarball with --strip-components=1 semantics via tarfile.

GNU tar 1.35 (Ubuntu 24.04, used by debian-pkg/Dockerfile) fails with
"Cannot change mode ...: Operation not permitted" on ordinary directories
when extracting large archives under rootless podman / overlay storage.
This is a regression in tar 1.35's fchmodat(..., AT_SYMLINK_NOFOLLOW)
hardening, which some overlayfs + user-namespace combinations reject even
for non-symlink targets. GNU tar 1.34 (Ubuntu 22.04) does not hit this;
neither does Python's tarfile module, which uses plain chmod().

Usage:
    python3 strip1-extract.py <archive> <dest-dir>
"""

import sys
import tarfile


def main():
    archive, dest = sys.argv[1], sys.argv[2]
    with tarfile.open(archive) as t:
        members = []
        for m in t.getmembers():
            parts = m.name.split('/', 1)
            if len(parts) != 2 or not parts[1]:
                continue
            m.name = parts[1]
            members.append(m)
        t.extractall(dest, members=members, filter='tar')


if __name__ == '__main__':
    main()
