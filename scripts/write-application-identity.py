#!/usr/bin/env python3
"""Record only code hashes of the final signed application for cydo authorization."""
# Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later
import pathlib
import re
import subprocess
import sys

if len(sys.argv) != 4:
    sys.exit("usage: write-application-identity.py <ldid> <signed-executable> <manifest>")
output = subprocess.check_output([sys.argv[1], "-h", sys.argv[2]], text=True)
hashes = set()
for line in output.splitlines():
    if line.startswith("CDHash=") or line.startswith("CandidateCDHash "):
        value = line.rsplit("=", 1)[-1]
        if not re.fullmatch(r"[0-9a-fA-F]{40}", value):
            sys.exit("invalid application code hash reported by ldid")
        hashes.add(value.lower())
if not hashes or len(hashes) > 64:
    sys.exit("signed application has no usable code identity")
destination = pathlib.Path(sys.argv[3])
destination.write_text("".join(value + "\n" for value in sorted(hashes)), encoding="ascii")
destination.chmod(0o644)
