#!/bin/sh
# Copyright (C) 2026 Torrekie
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
snapshot_header=$root/Cydia/LegacyUICompatibilityNativeSnapshot.h
snapshot_source=$root/Cydia/LegacyUICompatibilityNativeSnapshot.mm
caller_header=$root/Cydia/LegacyUICompatibilityNativeCaller.h
caller_source=$root/Cydia/LegacyUICompatibilityNativeCaller.mm
provider_source=$root/Cydia/LegacyUICompatibilityNativeProvider.mm

fail() {
    echo "[verify-legacy-ui-compatibility-native-snapshot][FAIL] $*" >&2
    exit 1
}

command -v rg >/dev/null 2>&1 || fail "rg is required"
for file in "$snapshot_header" "$snapshot_source" "$caller_header" \
            "$caller_source" "$provider_source"; do
    test -f "$file" || fail "missing nested snapshot source: $file"
done

for token in \
        'CydiaLegacyUICompatibilityNativeSnapshot' \
        'CydiaLegacyUICompatibilityNativeSnapshotParent' \
        'CydiaLegacyUICompatibilityNativeSnapshotKindOperation' \
        'CydiaLegacyUICompatibilityNativeSnapshotKindClause' \
        'CydiaLegacyUICompatibilityNativeSnapshotKindRelation' \
        'CydiaLegacyUICompatibilityNativeSnapshotKindMIMEAddress' \
        'operationOperator' 'operationValue' 'clausePackage' 'clauseVersion' \
        'relationClauses' 'relationRelationship' 'mimeAddressAddress' \
        'mimeAddressName' 'isBoundToSession:' 'invokeSnapshot:' \
        'decisionForSnapshot:' 'valueForNestedSnapshotMember:' \
        'SnapshotPackageRelations' 'SnapshotMIMEAddress' \
        'CurrentPackage(database' 'snapshotTargets_' 'removeAllObjects'; do
    rg -Fq "$token" "$snapshot_header" "$snapshot_source" \
        "$caller_header" "$caller_source" "$provider_source" ||
        fail "missing nested snapshot contract: $token"
done

if rg -n 'Package\.h|Relations\.h|MIMEAddress\.h|UIKit/|WebKit/|WebScriptObject|WebFrame|UIWebView|WKWebView|valueForKey:|setValue:.*forKey:|performSelector:|system:' \
        "$snapshot_header" "$snapshot_source" "$caller_header" "$caller_source" >/dev/null; then
    fail "snapshot/caller boundary exposes model, browser, shell, or generic KVC access"
fi

for name in operator value package version clauses relationship address; do
    rg -Fq "@\"$name\"" "$caller_source" "$provider_source" ||
        fail "nested attribute is not explicitly allowlisted: $name"
done
rg -Fq 'isActive' "$snapshot_source" ||
    fail "snapshot validity is not tied to parent session activity"
rg -Fq 'SnapshotAllowsInvocation' "$caller_source" ||
    fail "caller does not bind nested scope to the parent snapshot"
rg -Fq 'SanitizedNestedResult' "$caller_source" ||
    fail "caller does not sanitize provider Foundation values"
rg -Fq 'ExactClass(target, [CydiaLegacyUICompatibilityNativeSnapshot class])' \
    "$provider_source" || fail "provider does not exact-class validate snapshot targets"

echo "[verify-legacy-ui-compatibility-native-snapshot][ ok ] immutable nested compatibility snapshot boundary"
