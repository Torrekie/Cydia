#!/usr/bin/env python3
"""Check the invented Settings table against every shipped locale."""
import json
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent
ENTRY = re.compile(r'("(?:[^"\\]|\\.)*")\s*=\s*("(?:[^"\\]|\\.)*")\s*;')
FORMAT = re.compile(r'%(?!%)(?:\d+\$)?[-+#0 ]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|ll|[hljztL])?[@diouxXfFeEgGaAcCsSp]')


def read_table(path, allow_equal=False):
    text = path.read_text(encoding="utf-8-sig")
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    result = {}
    end = 0
    for match in ENTRY.finditer(text):
        assert not text[end:match.start()].strip(), f"Invalid entry in {path.name}"
        key, value = (json.loads(part) for part in match.groups())
        assert key not in result, f"Duplicate key: {key}"
        assert value and (allow_equal or value != key), f"Untranslated key: {key}"
        result[key] = value
        end = match.end()
    assert not text[end:].strip(), f"Invalid trailing entry in {path.name}"
    return result


def main():
    bundles = sorted((ROOT / "MobileCydia.app").glob("*.lproj"))
    assert len(bundles) == 21, "Review changes to the shipped locale baseline"
    english = read_table(ROOT / "MobileCydia.app/en.lproj/Settings.strings")
    assert english, "Settings table is empty"
    for bundle in bundles:
        assert (bundle / "Localizable.strings").is_file(), "Locale baseline missing"
        table = read_table(bundle / "Settings.strings")
        assert table.keys() == english.keys(), f"Settings keys differ in {bundle.name}"
        for key, value in table.items():
            expected = sorted(FORMAT.findall(english[key].replace("%%", "")))
            actual = sorted(FORMAT.findall(value.replace("%%", "")))
            assert actual == expected, f"Format arguments differ: {bundle.name}/{key}"
    accounts = read_table(ROOT / "MobileCydia.app/en.lproj/Accounts.strings")
    assert {"ACCOUNT_BUY", "ACCOUNT_DOWNLOAD", "ACCOUNT_CHECK_AGAIN", "ACCOUNT_WEBSITE"} <= accounts.keys(), \
        "Package account actions are missing"
    for bundle in bundles:
        table = read_table(bundle / "Accounts.strings")
        assert table.keys() == accounts.keys(), f"Account keys differ in {bundle.name}"
        for key, value in table.items():
            assert sorted(FORMAT.findall(value.replace("%%", ""))) == sorted(FORMAT.findall(accounts[key].replace("%%", ""))), \
                f"Account arguments differ: {bundle.name}/{key}"
            assert key not in {"ACCOUNT_BUY", "ACCOUNT_DOWNLOAD", "ACCOUNT_CHECK_AGAIN", "ACCOUNT_WEBSITE"} or \
                bundle.name == "en.lproj" or value != accounts[key], \
                f"English account fallback: {bundle.name}/{key}"
    runtime_provider = read_table(ROOT / "MobileCydia.app/en.lproj/RuntimeProvider.strings")
    runtime_provider_keys = {
        "REVIEW_OPERATIONS", "REVIEW_UNPACK", "REVIEW_CONFIGURE", "REVIEW_REMOVE",
        "REVIEW_PURGE", "REVIEW_TRIGGERS", "REVIEW_DECONFIGURE", "RECOVERY_REVIEW",
        "REVIEW_PROCESSING", "REVIEW_PROCESSING_HELP",
        "RUNTIME_TITLE", "AUTOMATIC", "RECOVERY", "AUTOMATIC_HELP", "RECOVERY_HELP",
        "CURRENT_RUNTIME", "PROVIDER_VERSION", "APT_VERSION", "CHECK_AGAIN", "CHECKING",
        "STATUS_UNCHECKED", "STATUS_EXTERNAL", "STATUS_RECOVERY", "STATUS_MISSING",
        "STATUS_UNSUPPORTED", "STATUS_BROKEN", "UNCHECKED_HELP", "MISSING_HELP",
        "UNSUPPORTED_HELP", "BROKEN_HELP", "REVIEW_RESET_HELP", "ARCHIVE_REVIEW_LIMITS",
        "REVIEW_UNAVAILABLE", "OPERATION_FAILED",
    }
    assert runtime_provider.keys() == runtime_provider_keys, "Runtime provider English keys differ from the UI contract"
    for bundle in bundles:
        table = read_table(bundle / "RuntimeProvider.strings")
        assert table.keys() == runtime_provider.keys(), f"Runtime provider keys differ in {bundle.name}"
        for key, value in table.items():
            assert sorted(FORMAT.findall(value.replace("%%", ""))) == sorted(FORMAT.findall(runtime_provider[key].replace("%%", ""))), \
                f"Runtime provider arguments differ: {bundle.name}/{key}"
        for key in {"REVIEW_UNAVAILABLE", "OPERATION_FAILED", "REVIEW_PROCESSING", "REVIEW_PROCESSING_HELP"}:
            assert bundle.name == "en.lproj" or table[key] != runtime_provider[key], \
                f"English runtime failure fallback: {bundle.name}/{key}"
    file_types = read_table(ROOT / "MobileCydia.app/en.lproj/InfoPlist.strings", allow_equal=True)
    for bundle in bundles:
        assert read_table(bundle / "InfoPlist.strings", allow_equal=True).keys() == file_types.keys(), \
            f"File type labels differ in {bundle.name}"
    access = read_table(ROOT / "MobileCydia.app/en.lproj/RuntimeAccess.strings")
    for bundle in bundles:
        table = read_table(bundle / "RuntimeAccess.strings")
        assert table.keys() == access.keys(), f"Access check keys differ in {bundle.name}"
        for key, value in table.items():
            assert sorted(FORMAT.findall(value.replace("%%", ""))) == sorted(FORMAT.findall(access[key].replace("%%", ""))), \
                f"Access check arguments differ: {bundle.name}/{key}"
    bootstrap = read_table(ROOT / "MobileCydia.app/en.lproj/BootstrapAccess.strings")
    for bundle in bundles:
        table = read_table(bundle / "BootstrapAccess.strings")
        assert table.keys() == bootstrap.keys(), f"Bootstrap access keys differ in {bundle.name}"
        for key, value in table.items():
            assert sorted(FORMAT.findall(value.replace("%%", ""))) == sorted(FORMAT.findall(bootstrap[key].replace("%%", ""))), \
                f"Bootstrap access arguments differ: {bundle.name}/{key}"
    outcomes = {"TRANSACTION_FAILED_TITLE", "TRANSACTION_CANCELLED"}
    outcome_english = read_table(ROOT / "MobileCydia.app/en.lproj/Localizable.strings", allow_equal=True)
    assert outcomes <= outcome_english.keys(), "Progress outcome titles missing in English"
    for bundle in bundles:
        table = read_table(bundle / "Localizable.strings", allow_equal=True)
        for key in outcomes:
            value = table.get(key)
            assert value and value != key, f"Progress outcome title missing: {bundle.name}/{key}"
            assert not FORMAT.findall(value.replace("%%", "")), f"Unexpected progress title argument: {bundle.name}/{key}"
            assert bundle.name == "en.lproj" or value != outcome_english[key], \
                f"English progress outcome fallback: {bundle.name}/{key}"
    print(f"[settings-localization] PASS: {len(english)} keys in {len(bundles)} locales")
    print(f"[accounts-localization] PASS: {len(accounts)} keys in {len(bundles)} locales")
    print(f"[runtime-provider-localization] PASS: {len(runtime_provider)} keys in {len(bundles)} locales")
    print(f"[runtime-access-localization] PASS: {len(access)} keys in {len(bundles)} locales")
    print(f"[bootstrap-access-localization] PASS: {len(bootstrap)} keys in {len(bundles)} locales")
    print(f"[transaction-outcome-localization] PASS: {len(outcomes)} keys in {len(bundles)} locales")


if __name__ == "__main__":
    main()
