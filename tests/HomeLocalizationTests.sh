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
