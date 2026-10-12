#!/usr/bin/env python3
"""Reject English fallbacks in authored native additions, preserving old gaps."""
import json
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent
ENTRY = re.compile(r'("(?:[^"\\]|\\.)*")\s*=\s*("(?:[^"\\]|\\.)*")\s*;')
TABLES = (
    "Settings", "Sources", "Actions", "Recovery", "RuntimeAccess",
    "BootstrapAccess", "InfoPlist", "Localizable",
)
# These words are correct in both English and the named language. Approve the
# exact word, rather than exempting a key from future English-prose checks.
SHARED_WORDS = {
    ("de", "Recovery", "RECOVERY_DETAILS"): "Details",
    ("nl", "Recovery", "RECOVERY_DETAILS"): "Details",
    ("de", "Sources", "SOURCE_STATUS"): "Status",
    ("nl", "Sources", "SOURCE_STATUS"): "Status",
    ("sv", "Sources", "SOURCE_STATUS"): "Status",
    ("es", "Settings", "SECURITY_ERROR"): "Error",
    ("fr", "Localizable", "ERROR_DESTINATION"): "destination",
}


def title_keys(value):
    if isinstance(value, dict):
        if "title_key" in value:
            yield value["title_key"]
        for child in value.values():
            yield from title_keys(child)
    elif isinstance(value, list):
        for child in value:
            yield from title_keys(child)


def read(path):
    content = re.sub(r'/\*.*?\*/', '', path.read_text(encoding="utf-8-sig"), flags=re.S)
    result = {}
    end = 0
    for match in ENTRY.finditer(content):
        assert not content[end:match.start()].strip(), f"Invalid entry in {path}"
        key, value = (json.loads(part) for part in match.groups())
        assert key not in result, f"Duplicate entry in {path}: {key}"
        assert value.strip(), f"Empty entry in {path}: {key}"
        result[key] = value
        end = match.end()
    assert not content[end:].strip(), f"Invalid trailing entry in {path}"
    return result


def main():
    app = ROOT / "MobileCydia.app"
    baseline = json.loads((ROOT / "tests/fixtures/ui/native-localization-baseline.json").read_text())
    locales = sorted(p.name[:-6] for p in app.glob("*.lproj"))
    assert locales == sorted(baseline["locales"]), "Locale baseline changed"
    legacy = set(baseline["legacy_full_keys"])
    additions = 0
    for table in TABLES:
        english = read(app / "en.lproj" / (table + ".strings"))
        keys = set(english) - legacy if table == "Localizable" else set(english)
        additions += len(keys)
        for locale in locales:
            values = read(app / (locale + ".lproj") / (table + ".strings"))
            for key in sorted(keys):
                value = values.get(key)
                assert value and value.strip() and (locale == "en" or value != key), \
                    f"{locale}/{table}/{key}: missing translation"
                if locale != "en" and value == english[key]:
                    assert SHARED_WORDS.get((locale, table, key)) == value, \
                        f"{locale}/{table}/{key}: English fallback needs language review"
    # HomeGuideController resolves explicit JSON title keys in Localizable.
    # Coverage alone cannot catch a page wired to a nonexistent key.
    guide_keys = set()
    for name in ("HomeGuides", "FAQGuide", "CopyingFilesGuide"):
        guide_keys.update(title_keys(json.loads((app / (name + ".json")).read_text())))
    for locale in locales:
        values = read(app / (locale + ".lproj") / "Localizable.strings")
        for key in sorted(guide_keys):
            assert values.get(key), f"{locale}/guide title/{key}: unresolved localization key"
    print(f"[localization-additions] PASS: {additions} additions and {len(guide_keys)} guide title keys in {len(locales)} locales; reviewed shared words only")


if __name__ == "__main__":
    main()
