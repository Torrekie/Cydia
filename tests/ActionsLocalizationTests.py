#!/usr/bin/env python3
"""Check package-action text and placeholders in every shipped locale."""
from SettingsLocalizationTests import ROOT, FORMAT, read_table


def main():
    english = read_table(ROOT / "MobileCydia.app/en.lproj/Actions.strings")
    assert english, "Actions table is empty"
    bundles = sorted((ROOT / "MobileCydia.app").glob("*.lproj"))
    for bundle in bundles:
        table = read_table(bundle / "Actions.strings")
        assert table.keys() == english.keys(), f"Actions keys differ in {bundle.name}"
        for key, value in table.items():
            expected = sorted(FORMAT.findall(english[key].replace("%%", "")))
            actual = sorted(FORMAT.findall(value.replace("%%", "")))
            assert actual == expected, f"Format arguments differ: {bundle.name}/{key}"
    print(f"[actions-localization] PASS: {len(english)} keys in {len(bundles)} locales")


if __name__ == "__main__":
    main()
