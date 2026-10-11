#!/usr/bin/env python3
"""Verify every existing Cydia locale covers the native recovery workflow."""
from pathlib import Path
from collections import Counter
import json
import re

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "MobileCydia.app"
ENTRY = re.compile(r'^("(?:\\.|[^"\\])*")\s*=\s*("(?:\\.|[^"\\])*");$', re.M)


def read_table(path):
    pairs = [(json.loads(key), json.loads(value)) for key, value in ENTRY.findall(path.read_text(encoding="utf-8"))]
    assert len(pairs) == len(dict(pairs)), "duplicate recovery localization key"
    assert all(value.strip() for _, value in pairs), "empty recovery localization"
    return dict(pairs)


def main():
    locales = sorted(path.parent for path in APP.glob("*.lproj/Localizable.strings"))
    assert len(locales) == 21, "review recovery tables after changing Cydia's locale baseline"
    english = read_table(APP / "en.lproj/Recovery.strings")
    used = set(re.findall(r'@"(RECOVERY_[A-Z_]+)"', (ROOT / "Cydia/RecoveryController.mm").read_text()))
    assert used == set(english), "recovery controller keys must match the English table"
    for locale in locales:
        table = read_table(locale / "Recovery.strings")
        assert set(table) == set(english), f"incomplete recovery table: {locale.name}"
        for key, value in table.items():
            assert Counter(re.findall(r"%(?:\d+\$)?[@diu]", value)) == Counter(re.findall(r"%(?:\d+\$)?[@diu]", english[key])), f"format mismatch: {locale.name}/{key}"
    print(f"[recovery-localization] PASS ({len(english)} keys, {len(locales)} locales)")


if __name__ == "__main__":
    main()
