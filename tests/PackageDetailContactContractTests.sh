#!/bin/sh
# Cydia native package-detail contact-row contract.
# Copyright (C) 2026 Torrekie
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source="$root/Cydia/PackageDetailController.mm"

fail() {
    echo "[verify-package-detail-contact][FAIL] $*" >&2
    exit 1
}

test -f "$source" || fail "package-detail controller source is missing"

grep -Fq 'UCLocalizeEx(@"PACKAGE_SUPPORT", @"Package Support")' "$source" ||
    fail "package-support title lost its localization fallback"

locale_count=0
for strings in "$root"/MobileCydia.app/*.lproj/Localizable.strings; do
    test -f "$strings" || fail "package localization set is missing"
    count=$(grep -Ec '^"PACKAGE_SUPPORT" = ".+";$' "$strings")
    test "$count" -eq 1 ||
        fail "PACKAGE_SUPPORT must have one nonempty value in $strings"
    locale_count=$((locale_count + 1))
done
test "$locale_count" -eq 21 ||
    fail "PACKAGE_SUPPORT coverage changed ($locale_count != 21 locales)"
grep -Fqx '"PACKAGE_SUPPORT" = "Package Support";' \
    "$root/MobileCydia.app/en.lproj/Localizable.strings" ||
    fail "English PACKAGE_SUPPORT no longer matches the source fallback"

title=$(sed -n '/NSString \*ContactTitle(/,/^}/p' "$source")
printf '%s\n' "$title" | grep -Fq \
    'case CydiaPackageDetailContactKindAuthor:' ||
    fail "author contact title branch is missing"
printf '%s\n' "$title" | grep -Fq \
    'case CydiaPackageDetailContactKindMaintainer:' ||
    fail "maintainer fallback title branch is missing"
author_case=$(printf '%s\n' "$title" | grep -n -F \
    'case CydiaPackageDetailContactKindAuthor:' | cut -d: -f1)
maintainer_case=$(printf '%s\n' "$title" | grep -n -F \
    'case CydiaPackageDetailContactKindMaintainer:' | cut -d: -f1)
author_title=$(printf '%s\n' "$title" | grep -n -F \
    'return UCLocalize("AUTHOR");' | cut -d: -f1)
support_title=$(printf '%s\n' "$title" | grep -n -F \
    'return UCLocalizeEx(@"PACKAGE_SUPPORT", @"Package Support");' | cut -d: -f1)
test -n "$author_case" && test -n "$maintainer_case" && \
    test -n "$author_title" && test -n "$support_title" && \
    test "$author_case" -lt "$maintainer_case" && \
    test "$maintainer_case" -lt "$author_title" && \
    test "$author_title" -lt "$support_title" ||
    fail "maintainer data no longer retains the legacy Author row title"

configure=$(sed -n '/} else if (row == 1) {/,/} else {/p' "$source")
printf '%s\n' "$configure" | grep -Fq 'ContactURLString(_viewModel)' ||
    fail "contact cell does not resolve its URL"
printf '%s\n' "$configure" | grep -Fq 'UITableViewCellSelectionStyleNone' ||
    fail "contact cell remains selectable without a URL"

selection_line=$(printf '%s\n' "$configure" | grep -n -F \
    'UITableViewCellSelectionStyleNone : UITableViewCellSelectionStyleDefault;' | \
    cut -d: -f1)
return_line=$(printf '%s\n' "$configure" | grep -n -F 'return;' | tail -1 | cut -d: -f1)
test -n "$selection_line" && test -n "$return_line" && \
    test "$selection_line" -lt "$return_line" ||
    fail "contact selection style can be overwritten by the shared default"

dispatch=$(sed -n '/} else if (indexPath.row == 1) {/,/} else {/p' "$source")
printf '%s\n' "$dispatch" | grep -Fq 'URLString = ContactURLString(_viewModel);' ||
    fail "contact dispatch does not resolve its URL"
printf '%s\n' "$dispatch" | grep -Fq 'if ([URLString length] == 0)' ||
    fail "contact dispatch lacks its nil/empty URL guard"

guard_line=$(printf '%s\n' "$dispatch" | grep -n -F 'if ([URLString length] == 0)' | cut -d: -f1)
identifier_line=$(printf '%s\n' "$dispatch" | grep -n -F 'identifier = [_viewModel identity];' | cut -d: -f1)
test "$guard_line" -lt "$identifier_line" ||
    fail "contact dispatch identifies a contact before validating its URL"

echo "[verify-package-detail-contact][ ok ] contact row is localized and fail-closed"
