#!/bin/sh
# Copyright (C) 2026 Torrekie
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
evidence="$root/Cydia/LegacyUICompatibilityRuntimeEvidence.mm"
header="$root/Cydia/LegacyUICompatibilityRuntimeEvidence.h"
data="$root/Cydia/Application+Data.mm"
matrix="$root/Cydia/LegacyUICompatibilityMatrix.mm"
application="$root/Cydia/Application.h"
verify_inventory="$root/tests/LegacyUICompatibilityInventoryContractTests.sh"

fail() {
    echo "[verify-legacy-runtime-evidence-contract][FAIL] $*" >&2
    exit 1
}

command -v rg >/dev/null 2>&1 || fail "rg is required"
for file in "$evidence" "$header" "$data" "$matrix" "$application" "$verify_inventory"; do
    test -f "$file" || fail "missing runtime evidence file: $file"
done

"$verify_inventory" >/dev/null || fail "authoritative inventory accounting failed"

lines=$(wc -l <"$evidence")
test "$lines" -le 1200 || fail "runtime evidence source exceeds 1200 lines"

for token in \
        'CYDIA_NATIVE_COMPATIBILITY_EVIDENCE_PATH' \
        'CydiaLegacyUICompatibilityRuntimeEvidenceBuildReceipt' \
        'CydiaLegacyUICompatibilityRuntimeEvidenceWriteReceipt' \
        'return path != nil && IsSafePath(path);' \
        'decisionForScope:memberKind:memberName:arguments:targetOrigin:' \
        'legacyUICompatibilitySessionForRenderingWithPresenter:' \
        'renderingSession' \
        'policyDecision' \
        'dispatchStatus' \
        'not_dispatched_mutation_disabled' \
        'not_dispatched_no_production_target' \
        'missing-canonical-package-snapshot' \
        'expectedSourceCommit' \
        'expectedSourceTreeSHA256' \
        'sourceIdentityAttestation' \
        'NSJSONWritingSortedKeys' \
        'NSDataWritingAtomic' \
        'lstat' \
        'kMaximumEvidenceBytes'; do
    rg -Fq "$token" "$evidence" "$header" "$data" "$matrix" || fail "missing evidence contract token: $token"
done

for token in \
        'CYDIA_NATIVE_COMPATIBILITY_MATRIX_PATH' \
        'installed-boundary-matrix' \
        'boundaryAttempted' \
        'executorEntries == 0 && typedUnavailable' \
        'executorEntries == 1 && nativeRejections == 0' \
        'application-compatibility-service' \
        'not_dispatched_mutation_boundary' \
        'trusted_in_process'; do
    rg -Fq "$token" "$matrix" || fail "missing installed matrix contract token: $token"
done

if rg -n 'invoked = value|invoked =.*Undefined' "$matrix" >/dev/null; then
    fail "matrix conflates a boundary attempt with its return value"
fi

# The manifest source is decision-only.  These dispatch/route entry points may
# not appear in it, and its application hook must remain environment-gated.
for forbidden in \
        'invokeScope:' \
        'handoffRouteURL:' \
        'requestNativeConfirmationForInvocation:' \
        'enqueueMainThreadInvocation:' \
        'requestPackageMutation:' \
        'requestSourceMutation:' \
        'requestApplicationMutation:' \
        'requestMetadataMutationForKey:'; do
    if rg -Fq "$forbidden" "$evidence"; then
        fail "decision-only source contains dispatch entry point: $forbidden"
    fi
done

method_start=$(rg -n '^[-] \(void\) consumeLegacyUICompatibilityRuntimeEvidenceIfRequested \{' \
    "$data" | cut -d: -f1 | head -n 1)
method_end=$(awk -v start="$method_start" 'NR > start && /^- \(void\) / { print NR; exit }' "$data")
test -n "$method_start" && test -n "$method_end" || fail "cannot isolate runtime evidence hook"
method=$(sed -n "${method_start},$((method_end - 1))p" "$data")
printf '%s\n' "$method" | rg -Fq 'CydiaLegacyUICompatibilityRuntimeEvidenceRequested()' ||
    fail "runtime evidence hook is not opt-in"
if printf '%s\n' "$method" | rg -n 'invokeScope:|handoffRouteURL:|requestNativeConfirmation|enqueueMainThreadInvocation|addSource:|installPackage|removePackage|_saveConfig|refreshSources' >/dev/null; then
    fail "runtime evidence hook contains mutation, route, or member dispatch"
fi
printf '%s\n' "$method" | rg -Fq 'respondsToSelector:' ||
    fail "rendering target lookup is not guarded for older factories"

loaded_line=$(rg -n '^[-] \(void\) _loaded \{' "$data" | cut -d: -f1 | head -n 1)
hook_line=$(rg -n '\[self consumeLegacyUICompatibilityRuntimeEvidenceIfRequested\];' "$data" | head -n 1 | cut -d: -f1)
test -n "$loaded_line" && test -n "$hook_line" && test "$hook_line" -gt "$loaded_line" ||
    fail "runtime evidence hook is not called after _loaded begins"

# Keep the identity/receipt surface free of raw model payload names and paths.
if rg -n '@"(metadataValueDefined|installedPackageCount|sourceCount|canonicalPackageIdentity|sourceKey|targetOrigin)"' "$evidence" >/dev/null; then
    fail "runtime receipt source exposes raw model or origin payload fields"
fi

echo "[verify-legacy-runtime-evidence-contract][ ok ] decision-only hook, schema, bounds, and 152-row accounting"
