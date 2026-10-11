#!/usr/bin/env python3
"""Reject local session records and workstation captures in tracked inputs."""
import pathlib
import re
import subprocess
import sys


PRIVATE_ROOTS = (b".agent-workbench/", b".codex/", b"handoff/", b"evidence/",
                 b"artifacts/", b"local-artifacts/", b"docs/checkpoints/")
CAPTURE_SUFFIXES = (b".receipt", b".receipt.json", b".jsonl", b".log",
                    b".bundle", b".ipa", b".deb")
WORKSTATION_PATH = re.compile(rb"(?<![:A-Za-z0-9/])/(?:Users|home)/[^/\s\"']+/[^\s\"']+")


def main():
    root = pathlib.Path(__file__).resolve().parent.parent
    rows = subprocess.check_output(
        ["git", "ls-files", "--stage", "-z"], cwd=root).split(b"\0")
    violations = []
    for row in rows:
        if not row:
            continue
        metadata, name = row.split(b"\t", 1)
        mode, oid, stage = metadata.split()
        if name.startswith(PRIVATE_ROOTS) or name.endswith(CAPTURE_SUFFIXES):
            violations.append((name, "local capture or session record"))
            continue
        if stage != b"0" or mode not in (b"100644", b"100755"):
            continue
        data = subprocess.check_output(["git", "cat-file", "blob", oid], cwd=root)
        if WORKSTATION_PATH.search(data):
            violations.append((name, "workstation-specific path"))
    for name, reason in violations:
        # Do not echo captured contents or private path values into build logs.
        print("[repository-hygiene] FAIL: {} ({})".format(
            name.decode(errors="replace"), reason), file=sys.stderr)
    if violations:
        return 1
    print("[repository-hygiene] PASS: tracked inputs exclude local captures")
    return 0


if __name__ == "__main__":
    sys.exit(main())
