#!/usr/bin/env python3
# Copyright (C) 2026 Torrekie
# SPDX-License-Identifier: GPL-3.0-or-later
"""Verify the complete pinned upstream inventory without a network dependency."""
import hashlib
import json
import re
import subprocess
from pathlib import Path

reference = json.loads(Path("tests/fixtures/FirmwareDiscoveryZebra.json").read_text())
source = Path("firmware-discovery.mm").read_text()
inventory = source.split("CydiaGestaltKeys[] = {", 1)[1].split("};", 1)[0]
keys = re.findall(r'"([^"]+)"', inventory)
assert len(keys) == 371 and len(set(keys)) == 371
assert keys == reference["keys"], "MobileGestalt coverage differs from pinned Zebra inventory"
assert hashlib.sha256(("\n".join(keys) + "\n").encode()).hexdigest() == reference["key_sha256"]
assert reference["commit"] in source
result = subprocess.run(
    ["/bin/bash", "-c", '. Library/firmware.sh; while IFS= read -r key; do hyphenate "$key"; done'],
    input="\n".join(keys) + "\n", text=True, check=True, capture_output=True
)
packages = ["gsc." + name for name in result.stdout.splitlines()]
assert packages == reference["package_names"], "capability package mapping changed"
for key, package, zebra in zip(keys, packages, reference["zebra_package_names"]):
    assert re.fullmatch(r"[a-z0-9][a-z0-9+.-]*", package), key
    if package != zebra:
        assert "_" in zebra and package == zebra.replace("_", "-"), key
for name in ("arm", "arm64", "arm64v8", "arm64e", "armv6", "armv7", "armv7s", "armv7k"):
    assert f'@"{name}"' in source, f"missing hardware CPU identity: {name}"
for api in ("hw.cputype", "hw.cpusubtype", "MGCopyAnswer", "MGGetBoolAnswer"):
    assert api in source
assert "CPU_SUBTYPE_MASK" in source, "CPU feature bits must not change the identity"
assert "writePackagesToStatusFile" not in source
assert "setupUserSymbolicLink" not in source
print("firmware discovery coverage passed (371 pinned MobileGestalt keys)")
