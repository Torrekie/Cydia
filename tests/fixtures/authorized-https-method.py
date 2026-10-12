#!/usr/bin/env python3
"""Offline APT method fixture for Cydia's authorized archive acquisition.

Implements the acquire protocol, not TLS: the production pkgAcqFile owns the
request, expected hashes, destination and completion processing. No network
request or repository authentication is simulated by this fixture.
"""
import hashlib
import os
from pathlib import Path
import shutil
import stat
import sys


def message(header, **fields):
    sys.stdout.write(header + "\n")
    for key, value in fields.items():
        sys.stdout.write(f"{key}: {value}\n")
    sys.stdout.write("\n")
    sys.stdout.flush()


message("100 Capabilities", Version="1.0", **{
    "Single-Instance": "true", "Send-Config": "true",
})
while True:
    header = sys.stdin.readline()
    if not header:
        break
    fields = {}
    for line in sys.stdin:
        if not line.strip():
            break
        key, separator, value = line.partition(":")
        if separator:
            fields[key] = value.strip()
    if header.startswith("601 "):
        continue
    uri = fields.get("URI", "")
    try:
        if not header.startswith("600 ") or uri != "https://authorized.invalid/archive.deb?token=fixture":
            raise ValueError("Unexpected fixture request")
        destination = Path(fields["Filename"])
        cache = Path(os.environ["CYDIA_APT_AUTHORIZED_CACHE"]).resolve()
        directory = destination.parent
        if (destination.name != "payload.deb" or directory.parent.resolve() != cache or
                not directory.name.startswith(".cydia-authorized.") or
                stat.S_IMODE(directory.stat().st_mode) != 0o700 or directory.is_symlink()):
            raise ValueError("Acquisition did not use a private staging destination")
        source = Path(os.environ["CYDIA_APT_AUTHORIZED_PAYLOAD"])
        payload = source.read_bytes()
        hashes = {name + "-Hash": hashlib.new(algorithm, payload).hexdigest()
                  for name, algorithm in (("MD5Sum", "md5"), ("SHA1", "sha1"),
                                          ("SHA256", "sha256"), ("SHA512", "sha512"))}
        hashes["Checksum-FileSize-Hash"] = str(len(payload))
        message("200 URI Start", URI=uri, Size=len(payload))
        shutil.copyfile(source, destination)
        with open(os.environ["CYDIA_APT_AUTHORIZED_MARKER"], "a", encoding="ascii") as marker:
            marker.write("private\n")
        message("201 URI Done", URI=uri, Filename=str(destination), Size=len(payload), **hashes)
    except (KeyError, OSError, ValueError) as error:
        message("400 URI Failure", URI=uri, Message=str(error))
