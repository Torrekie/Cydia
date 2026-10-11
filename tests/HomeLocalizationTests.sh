#!/bin/sh
# Copyright (C) 2026 Torrekie
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
controller="$root/Cydia/HomeController.mm"
english="$root/MobileCydia.app/en.lproj/Localizable.strings"

fail() {
    echo "[verify-home-localization][FAIL] $*" >&2
    exit 1
}

test -f "$controller" || fail "Home controller source is missing"
test -f "$english" || fail "English localization is missing"

work=$(mktemp -d "${TMPDIR:-/tmp}/cydia-home-localization.XXXXXX") ||
    fail "unable to create a temporary directory"
cleanup() {
    rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM

descriptor_pairs="$work/descriptor-pairs.tsv"
ipad_pairs="$work/ipad-pairs.tsv"
pairs="$work/home-pairs.tsv"
source_home_keys="$work/source-home-keys.txt"
localized_home_keys="$work/localized-home-keys.txt"

# HomeLinkDescriptor records keep the localization key and English fallback in
# the second and third quoted fields. Social records intentionally use NULL.
awk -F '"' '
    /^[[:space:]]*\{HomeAction/ && index($0, ", NULL,") == 0 {
        if ($2 ~ /^[A-Z][A-Z0-9_]*$/)
            print $2 "\t" $4
    }
' "$controller" >"$descriptor_pairs"

# The two iPad column headers use the same localization helper outside the
# descriptor arrays, so keep them under the same all-locales contract.
awk -F '"' '
    /HomeLocalized\("HOME_IPAD_[A-Z0-9_]+"/ {
        print $2 "\t" $4
    }
' "$controller" >"$ipad_pairs"

LC_ALL=C sort "$descriptor_pairs" "$ipad_pairs" >"$pairs"

descriptor_count=$(wc -l <"$descriptor_pairs" | tr -d '[:space:]')
test "$descriptor_count" -eq 14 ||
    fail "Home descriptor localization count changed ($descriptor_count != 14)"
ipad_count=$(wc -l <"$ipad_pairs" | tr -d '[:space:]')
test "$ipad_count" -eq 2 ||
    fail "Home iPad localization count changed ($ipad_count != 2)"

duplicates=$(cut -f 1 "$pairs" | LC_ALL=C sort | uniq -d)
test -z "$duplicates" || fail "duplicate Home localization key: $duplicates"

# Any new HOME_* use must be represented by a descriptor or the explicit iPad
# header pair above. This keeps future Home additions inside the locale audit.
awk '
    {
        line = $0
        while (match(line, /"HOME_[A-Z0-9_]+"/)) {
            print substr(line, RSTART + 1, RLENGTH - 2)
            line = substr(line, RSTART + RLENGTH)
        }
    }
' "$controller" | LC_ALL=C sort -u >"$source_home_keys"
cut -f 1 "$pairs" | grep '^HOME_' | LC_ALL=C sort -u >"$localized_home_keys"
cmp -s "$source_home_keys" "$localized_home_keys" ||
    fail "not every HOME_* source key is covered by the locale contract"

home_key_count=$(wc -l <"$source_home_keys" | tr -d '[:space:]')
test "$home_key_count" -eq 14 ||
    fail "Home custom localization count changed ($home_key_count != 14)"

entry_count() {
    strings=$1
    key=$2
    awk -F '"' -v key="$key" '
        $1 ~ /^[[:space:]]*$/ && $2 == key { count++ }
        END { print count + 0 }
    ' "$strings"
}

entry_value() {
    strings=$1
    key=$2
    awk -F '"' -v key="$key" '
        $1 ~ /^[[:space:]]*$/ && $2 == key {
            print $4
            found = 1
        }
        END { if (!found) exit 1 }
    ' "$strings"
}

tab=$(printf '\t')
while IFS="$tab" read -r key fallback; do
    count=$(entry_count "$english" "$key")
    test "$count" -eq 1 ||
        fail "English Home key must appear once: $key ($count found)"
    value=$(entry_value "$english" "$key")
    test "$value" = "$fallback" ||
        fail "English value does not match the source fallback: $key"
done <"$pairs"

locale_count=0
for strings in "$root"/MobileCydia.app/*.lproj/Localizable.strings; do
    test -f "$strings" || fail "no bundled locale files were found"
    locale_dir=${strings%/Localizable.strings}
    locale=${locale_dir##*/}
    locale=${locale%.lproj}
    locale_count=$((locale_count + 1))
    has_translated_home_value=no

    while IFS="$tab" read -r key fallback; do
        count=$(entry_count "$strings" "$key")
        test "$count" -eq 1 ||
            fail "$locale must define $key exactly once ($count found)"
        value=$(entry_value "$strings" "$key")
        test -n "$value" || fail "$locale defines an empty Home value: $key"
        test "$value" != "$key" ||
            fail "$locale resolves a Home key to its key name: $key"

        if [ "$locale" != en ]; then
            english_value=$(entry_value "$english" "$key")
            if [ "$value" != "$english_value" ]; then
                has_translated_home_value=yes
            fi
        fi
    done <"$pairs"

    if [ "$locale" != en ]; then
        test "$has_translated_home_value" = yes ||
            fail "$locale contains only English Home fallback values"
    fi
done

test "$locale_count" -gt 0 || fail "no bundled locale files were audited"

pair_count=$(wc -l <"$pairs" | tr -d '[:space:]')
echo "[verify-home-localization][ ok ] $pair_count Home keys resolve in $locale_count bundled locales"

# The first-party Home table supersedes authored app translations only on Home.
# Check the offline dump, partial coverage and language/script mappings without
# requiring the original server or changing simulator language preferences.
python3 - "$root" <<'PY'
import json
import hashlib
import re
import subprocess
import sys
from pathlib import Path

root = Path(sys.argv[1])
app = root / "MobileCydia.app"
catalog = json.loads((app / "HomeLocalizationCatalog.json").read_text())
expected = {
    "en-us": "en", "ar": "ar", "de": "de", "el": "el", "es": "es",
    "fr": "fr", "he": "he", "it": "it", "ja": "ja", "ko": "ko",
    "nl": "nl", "pl": "pl", "pt-br": "pt", "pt-pt": "pt-PT", "ru": "ru",
    "sv": "sv", "th": "th", "tr": "tr", "vi": "vi", "zh-cn": "zh-Hans",
    "zh-tw": "zh-Hant",
}
assert {entry["source_locale"]: entry["native_locale"]
        for entry in catalog["locales"]} == expected, "source/native locale mapping changed"
keys = set(catalog["keys"])
assert len(keys) == 21, "first-party Home label count changed"
quoted = r'"(?:[^"\\]|\\.)*"'
entry_pattern = re.compile(r'(' + quoted + r')\s*=\s*(' + quoted + r')\s*;')
tables = {}
for locale in expected.values():
    content = (app / (locale + ".lproj") / "Home.strings").read_text()
    entries = [(json.loads(key), json.loads(value))
               for key, value in entry_pattern.findall(content)]
    values = dict(entries)
    assert len(entries) == len(values), locale + ": duplicate Home key"
    assert set(values) == keys, locale + ": incomplete Home table"
    assert all(value and value != key for key, value in entries), locale + ": invalid value"
    assert values["BY"].count("%@") == 1, locale + ": byline must preserve one author slot"
    assert values["HOME_FIND_EXTENSIONS"] == "Find Extensions for Applications", locale + ": invented source translation"
    tables[locale] = values
for entry in catalog["locales"]:
    values = tables[entry["native_locale"]]
    translated = {key for key in keys if values[key] != tables["en"][key]}
    assert translated == set(entry["translated_keys"]), "incorrect translation coverage"
    assert keys - translated == set(entry["untranslated_keys"]), "incorrect fallback coverage"
assert "WELCOME_TO_CYDIA" in next(entry for entry in catalog["locales"]
                                  if entry["native_locale"] == "ja")["untranslated_keys"]
assert tables["pt"] != tables["pt-PT"], "Brazilian and European Portuguese were collapsed"
controller = (root / "Cydia" / "HomeController.mm").read_text()
assert 'table:@"Home"' in controller, "native Home bypasses first-party strings"
for key in ("WELCOME_TO_CYDIA", "BY", "USER_GUIDES", "DEVELOPERS_ONLY"):
    assert re.search(r'HomeLocalized\("' + key + r'"', controller), key + ": not wired to Home"
print("[verify-home-localization][ ok ] 21 first-party labels in 21 native locale tables; partial coverage and regional mappings preserved")

# The 2023 baseline was captured from Git into this fixture so this check also
# works in exported source trees. Only existing baseline entries contribute to
# its digests; historical missing translations remain outside the repair scope.
baseline = json.loads((root / "tests/fixtures/ui/native-localization-baseline.json").read_text())
locales = sorted(path.name[:-6] for path in app.glob("*.lproj"))
assert locales == sorted(baseline["locales"]), "native locale baseline changed"
assert set(locales) == set(expected.values()), "Home/native locale baselines differ"
full_keys = set(baseline["legacy_full_keys"])
missing_keys = set(baseline["legacy_partial_missing_keys"])
partial_locales = set(baseline["legacy_partial_locales"])
additions = baseline["native_additions"]
identical_translations = baseline["native_identical_translations"]
format_pattern = re.compile(r'%(?:\d+\$)?[-+#0 ]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|ll|[hljztL])?[@diuoxXfFeEgGaAcCsSpn%]')
for locale in locales:
    path = app / (locale + ".lproj") / "Localizable.strings"
    entries = [(json.loads(key), json.loads(value))
               for key, value in entry_pattern.findall(path.read_text())]
    values = dict(entries)
    assert len(values) == len(entries), locale + ": duplicate native localization key"
    legacy_keys = full_keys - missing_keys if locale in partial_locales else full_keys
    assert legacy_keys <= set(values), locale + ": lost original localization"
    legacy = {key: values[key] for key in legacy_keys}
    digest = hashlib.sha256(json.dumps(legacy, ensure_ascii=False, sort_keys=True,
                                      separators=(",", ":")).encode()).hexdigest()
    assert digest == baseline["legacy_table_sha256"][locale], locale + ": original translations changed"
    for key, english in additions.items():
        value = values.get(key)
        assert value and value != key, locale + ": missing native addition " + key
        assert format_pattern.findall(value) == format_pattern.findall(english), locale + ": incompatible format slots in " + key
        if locale == "en":
            assert value == english, key + ": English catalog differs from audited copy"
        else:
            identical = key in identical_translations.get(locale, [])
            assert (value == english) == identical, locale + ": unexpected English native addition " + key
    # Apple validates the actual .strings grammar, beyond the coverage parser.
    if sys.platform == "darwin":
        result = subprocess.run(["plutil", "-lint", "--", str(path)], capture_output=True, text=True)
        assert result.returncode == 0, result.stdout + result.stderr
print("[verify-home-localization][ ok ] %d native additions in %d locales; format slots and 2023 translations preserved" % (len(additions), len(locales)))
PY
