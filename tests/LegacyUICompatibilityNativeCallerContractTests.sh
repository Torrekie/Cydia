#!/bin/sh
# Copyright (C) 2026 Torrekie
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
header=$root/Cydia/LegacyUICompatibilityNativeCaller.h
source=$root/Cydia/LegacyUICompatibilityNativeCaller.mm
policy=$root/Cydia/LegacyBridgePolicy.mm
context=$root/Cydia/UIRouteContext.mm
lifecycle=$root/Cydia/Application+Lifecycle.mm

fail() {
    echo "[verify-legacy-ui-compatibility-native-contract][FAIL] $*" >&2
    exit 1
}

command -v rg >/dev/null 2>&1 || fail "rg is required"
for file in "$header" "$source" "$policy" "$context" "$lifecycle"; do
    test -f "$file" || fail "missing native compatibility source: $file"
done

for token in \
        'CydiaLegacyUICompatibilityNativeCapability' \
        'CydiaUIRouteCallerTrustedInProcess' \
        '_isValidForLegacyBridge' \
        'inProcessCapability' \
        'targetScope' \
        'IsInheritedCyteObjectLocalize' \
        'IsInheritedCyteObjectFormat' \
        'IsExactCydiaApplicationTarget' \
        'CydiaObject' \
        'CyteObject' \
        'localize' \
        'format' \
        '_isIssuedForApplication:target' \
        'valueForSessionMember:' \
        'CydiaLegacyBridgeOperationFamilySession' \
        'requestMetadataMutationForKey:' \
        'setMetadataValue' \
        'metadataMutation' \
        'CydiaLegacyUICompatibilityCopyMetadataValue' \
        'CydiaLegacyUICompatibilityCopyMetadataKey' \
        'requestedInvocations_' \
        'BOOL accepted(NO)' \
        '[requestedInvocations_ removeObject:invocation]' \
        'CydiaLegacyBridgeOperationFamilySensitive' \
        'CydiaLegacyBridgeOperationFamilyChrome' \
        'CydiaLegacyBridgeOperationFamilyClipboard' \
        'CydiaLegacyBridgeOperationFamilyRetired'; do
    rg -Fq "$token" "$source" "$policy" "$context" ||
        fail "missing capability/policy contract: $token"
done

if rg -n 'valueForKey:|setValue:.*forKey:|WebScriptObject|WebFrame|UIWebView|WKWebView|system:' \
        "$header" "$source" >/dev/null; then
    fail "native caller exposes generic KVC, shell, or browser access"
fi

rg -Fq 'contextForRedirectWithOrigin' "$context" ||
    fail "route context has no web-demotion path"
rg -Fq 'inProcessCapability:nil' "$context" ||
    fail "web navigation does not strip the in-process capability"
rg -Fq '[request inProcessCapability] != contextCapability' "$policy" ||
    fail "policy does not bind request capability identity"
rg -Fq 'cydiaLegacyUICompatibilityApplicationMayIssueCapability' "$source" ||
    fail "native caller does not require the app-owned issuer predicate"
rg -Fq 'cydiaLegacyUICompatibilityApplicationMayIssueCapability' "$lifecycle" ||
    fail "application lifecycle does not implement the issuer predicate"

if rg -n 'IsInheritedCyteObjectLocalize\([^)]*' "$source" >/dev/null; then
    :
else
    fail "inherited CyteObject localize scope helper is missing"
fi
rg -Fq 'memberKind == CydiaLegacyBridgeMemberKindMethod' "$source" ||
    fail "inherited rendering scope is not restricted to methods"
rg -Fq '[memberName isEqualToString:@"localize"]' "$source" ||
    fail "inherited rendering scope is not restricted to localize"
rg -Fq '[memberName isEqualToString:@"format"]' "$source" ||
    fail "inherited rendering scope is not restricted to format"
rg -Fq '[arguments count] == 2' "$source" ||
    fail "inherited format scope does not require its exact two-argument shape"
rg -Fq '[member family] == CydiaLegacyBridgeOperationFamilySession' "$source" &&
rg -Fq 'valueForSessionMember:name' "$source" ||
    fail "session-family CydiaObject reads do not use the typed session callback"

echo "[verify-legacy-ui-compatibility-native-contract][ ok ] capability and closed member surface"
