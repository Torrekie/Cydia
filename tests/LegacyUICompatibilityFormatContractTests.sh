#!/bin/sh
# Copyright (C) 2026 Torrekie
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
header=$root/Cydia/LegacyUICompatibility.h
source=$root/Cydia/LegacyUICompatibility.mm
test_source=$root/tests/LegacyUICompatibilityFormatTests.mm

fail() {
    echo "[verify-legacy-ui-format-contract][FAIL] $*" >&2
    exit 1
}

command -v rg >/dev/null 2>&1 || fail "rg is required"
for file in "$header" "$source" "$test_source"; do
    test -f "$file" || fail "missing format compatibility source: $file"
done

rg -Fq 'CydiaLegacyUICompatibilityFormatString' "$header" "$source" "$test_source" ||
    fail "format helper is not exposed and exercised"
for token in \
        'kMaximumFormatLength' \
        'kMaximumFormatArgumentCount' \
        'kMaximumFormatValueLength' \
        'kMaximumFormattedResultLength' \
        'IsSupportedFormatValue' \
        'FormatValueDescription' \
        'token == '\''%'\''' \
        'token == '\''@'\''' \
        'argumentIndex == [values count]'; do
    rg -Fq "$token" "$source" || fail "missing bounded format contract: $token"
done

if rg -n 'va_list|WebScriptObject|WebKit|UIWebView|WKWebView|NSInvocation|initWithFormat:' \
        "$source" >/dev/null; then
    fail "format helper depends on variadic, browser, or dynamic invocation APIs"
fi

rg -Fq 'NSArray or NSOrderedSet' "$header" ||
    fail "format sequence contract is not documented"
rg -Fq 'NSString, NSNumber,' "$header" ||
    fail "format string/number value allowlist is not documented"
rg -Fq 'NSNull, or CydiaLegacyUIUndefinedValue' "$header" ||
    fail "format null/undefined value allowlist is not documented"
rg -Fq 'unsupported printf grammar' "$header" ||
    fail "format rejection contract is not documented"

echo "[verify-legacy-ui-format-contract][ ok ] bounded Foundation format grammar"
