#!/usr/bin/env python3
"""Check the source editor's dedicated table against Cydia's locale baseline."""
from pathlib import Path
import json
import re

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "MobileCydia.app"
ENTRY = re.compile(r'^("(?:\\.|[^"\\])*")\s*=\s*("(?:\\.|[^"\\])*");$', re.M)


def read_table(path):
    text = path.read_text(encoding="utf-8")
    pairs = [(json.loads(key), json.loads(value)) for key, value in ENTRY.findall(text)]
    assert len(pairs) == len(dict(pairs)), f"duplicate localization key: {path.name}"
    assert all(value.strip() for _, value in pairs), f"empty localization: {path.name}"
    return dict(pairs)


def main():
    locales = sorted(path.parent for path in APP.glob("*.lproj/Localizable.strings"))
    assert len(locales) == 21, "Cydia locale baseline changed; review the source editor tables"
    english = read_table(APP / "en.lproj/Sources.strings")
    used = set()
    for filename in [ROOT / "Sources.mm", *sorted((ROOT / "Cydia").glob("Source*.mm"))]:
        used.update(re.findall(r'@"(SOURCE_[A-Z_]+)"', filename.read_text()))
    assert used <= set(english), f"untranslated source editor keys: {sorted(used - set(english))}"
    for locale in locales:
        table = read_table(locale / "Sources.strings")
        assert set(table) == set(english), f"missing or extra source editor translation: {locale.name}"
        assert all("\x00" not in value for value in table.values()), f"invalid source editor text: {locale.name}"
    print(f"[sources-localization] PASS ({len(english)} keys, {len(locales)} locales)")


if __name__ == "__main__":
    main()
