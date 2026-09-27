#!/bin/sh
# Cydia shared web-origin validation and route-scope contract.
# Copyright (C) 2026 Torrekie
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
external_header="$root/Cydia/ExternalURLPolicy.h"
external_source="$root/Cydia/ExternalURLPolicy.mm"
depiction_source="$root/Cydia/PackageDepictionPolicy.mm"
context_source="$root/Cydia/UIRouteContext.mm"
dispatch_source="$root/Cydia/UIRouteDispatch.mm"
dispatch_fixture="$root/tests/fixtures/ui/route-dispatch.tsv"

fail() {
    echo "[verify-url-origin-validation][FAIL] $*" >&2
    exit 1
}

command -v rg >/dev/null 2>&1 || fail "rg is required"
for file in "$external_header" "$external_source" "$depiction_source" \
        "$context_source" "$dispatch_source" "$dispatch_fixture"; do
    test -f "$file" || fail "missing URL boundary input: $file"
done

grep -Fq \
    'FOUNDATION_EXPORT BOOL CydiaExternalURLIsValidWebURL(NSURL * _Nullable URL);' \
    "$external_header" || fail "shared web URL validator is not declared"

validator=$(sed -n '/^BOOL CydiaExternalURLIsValidWebURL/,/^}/p' "$external_source")
test -n "$validator" || fail "shared web URL validator implementation is missing"
for token in \
        '!IsStandaloneURL(URL)' \
        'HasCredentials(URL)' \
        'HasEmptyExplicitPort(URL)' \
        'componentsWithURL:URL resolvingAgainstBaseURL:NO' \
        'HasControlCharacters([components host])' \
        'whitespaceAndNewlineCharacterSet' \
        'integerValue] < 1' \
        'integerValue] > 65535'; do
    printf '%s\n' "$validator" | grep -Fq "$token" ||
        fail "shared validator lost strict web URL check: $token"
done

depiction_validator=$(sed -n '/^BOOL IsWebDocumentURL/,/^}/p' "$depiction_source")
printf '%s\n' "$depiction_validator" | grep -Fq \
    'CydiaExternalURLIsValidWebURL(URL)' ||
    fail "depiction policy does not use the shared validator"
if printf '%s\n' "$depiction_validator" | grep -Eq \
        '\[URL (scheme|host|port)|isEqualToString:@"http"'; then
    fail "depiction policy retains a duplicate weak web-origin predicate"
fi

repository_validator=$(sed -n '/^BOOL IsRepositoryDepictionOrigin/,/^}/p' "$context_source")
printf '%s\n' "$repository_validator" | grep -Fq \
    'CydiaExternalURLIsValidWebURL(origin)' ||
    fail "repository depiction context does not use the shared validator"
if printf '%s\n' "$repository_validator" | grep -Eq \
        '\[origin (scheme|host|port|user|password)|isEqualToString:@"http"'; then
    fail "repository depiction context retains a duplicate weak origin predicate"
fi

trusted_validator=$(sed -n '/^BOOL IsTrustedLegacyOrigin/,/^}/p' "$context_source")
printf '%s\n' "$trusted_validator" | grep -Fq \
    'CydiaExternalURLIsValidWebURL(origin)' ||
    fail "first-party HTTPS legacy origin bypasses the shared validator"

dispatch_boundary=$(sed -n \
    '/CydiaUIRouteDispatchResult \*CydiaUIDispatchRouteURL/,/^}/p' "$dispatch_source")
printf '%s\n' "$dispatch_boundary" | grep -Fq \
    'if (!IsApplicationRouteURL(url))' ||
    fail "route dispatcher no longer identifies app-owned schemes"
printf '%s\n' "$dispatch_boundary" | grep -Fq \
    'CydiaUIRouteDispatchOutcomeUnhandled' ||
    fail "direct non-app URLs no longer remain outside typed dispatch"
awk -F '\t' '
    $1 == "https://example.com/guide" && $2 == "trusted-native" &&
    $4 == "unhandled" { found = 1 }
    END { exit found ? 0 : 1 }
' "$dispatch_fixture" ||
    fail "route fixture does not document direct web URL scope"

echo "[verify-url-origin-validation][ ok ] shared strict web URL boundary and route scope"
