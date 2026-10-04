#!/bin/sh
# Copyright (C) 2026 Torrekie
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
data=$root/Cydia/Application+Data.mm
mobile=$root/MobileCydia.mm
application=$root/Cydia/Application.h
provider=$root/Cydia/LegacyUICompatibilityNativeProvider.mm
rendering_provider=$root/Cydia/LegacyUICompatibilityNativeRenderingProvider.mm
provider_application=$root/Cydia/LegacyUICompatibilityNativeProvider+Application.mm
mutation_diagnostic=$root/Cydia/NativeMutationDiagnostic.mm
lifetime_diagnostic=$root/Cydia/LegacyUICompatibilityLifetimeDiagnostic.mm

fail() {
    echo "[verify-legacy-ui-compatibility-native-consumer][FAIL] $*" >&2
    exit 1
}

command -v rg >/dev/null 2>&1 || fail "rg is required"
for file in "$data" "$mobile" "$application" "$provider" "$rendering_provider" "$provider_application" "$mutation_diagnostic" "$lifetime_diagnostic"; do
    test -f "$file" || fail "missing native consumer source: $file"
done

for token in \
        'CYDIA_NATIVE_COMPATIBILITY_DIAGNOSTIC' \
        'CYDIA_NATIVE_COMPATIBILITY_MUTATION_DIAGNOSTIC' \
        'CydiaNativeCompatibilityDiagnosticRequested' \
        'CydiaNativeCompatibilityMutationDiagnosticMode' \
        'CydiaNativeCompatibilityMutationDiagnosticRevokeBeforeConfirm' \
        'CYDIA_NATIVE_COMPATIBILITY_MUTATION_REVOKE_BEFORE_CONFIRM' \
        'CydiaNativeCompatibilityMutationDiagnosticRevokeBoundary' \
        'CYDIA_NATIVE_COMPATIBILITY_MUTATION_REVOKE_BOUNDARY' \
        'revokeAuthorityForDiagnosticBoundary:' \
        'revoking session after presentation' \
        'CydiaNativeCompatibilityMutationDiagnosticKey' \
        'CydiaNativeCompatibilityMutationDiagnosticValue' \
        'CYDIA_NATIVE_COMPATIBILITY_B17_FIXTURE' \
        'CydiaNativeCompatibilityB17FixtureRequested' \
        'CydiaNativeCompatibilityMutationDiagnosticSourceURL' \
        'CydiaNativeCompatibilityMutationDiagnosticMetadataKey' \
        'legacyCompatibilityApplicationSession_' \
        'legacyCompatibilityApplicationSession_ = nil' \
        'legacyUICompatibilitySessionForApplicationWithPresenter:tabbar_' \
        'legacyUICompatibilitySessionForRenderingWithPresenter:' \
        'sessionForRenderingWithPresenter:' \
        'getAllSources' \
        'getInstalledPackages' \
        'getMetadataKeys' \
        'getMetadataValue' \
        'metadataKeyCount' \
        'metadataValueDefined' \
        'CydiaNativeCompatibilityDiagnosticMaximumMetadataKeys' \
        'CydiaNativeCompatibilityDiagnosticSafeMetadataKey' \
        'object_getClass(candidate) == [Package class]' \
        'object_getClass(candidate) == [Source class]' \
        'legacyUICompatibilitySessionForPackage:canonicalPackage' \
        'packageSessionRetained' \
        'packageSessionInvalidationDenied' \
        'packageTargetLiveAfterRelease' \
        'legacyUICompatibilitySessionForSource:canonicalSource' \
        'metadataSessionRetained' \
        'metadataSessionRead' \
        'metadataSessionInvalidationDenied' \
        'metadataTargetLiveAfterRelease' \
        'b17LifetimeCases' \
        'sessionIdentity' 'targetIdentity' 'presenterIdentity' \
        'retainedReadMatches' 'ownerInvalidationDenied' \
        'sessionDeallocated' 'ownerDeallocated' 'postReleaseReadRejected' \
        'legacyUICompatibilityMutationDiagnosticRequested' \
        'performSelector:@selector(consumeLegacyUICompatibilityMutationDiagnosticIfRequested)' \
        'memberName:@"id"' \
        'memberName:@"key"' \
        'handoffRouteURL:' \
        'native-compatibility-diagnostic.invalid' \
        'invalidationSession' \
        'CydiaLegacyUICompatibilityNativeDenialReasonInvalidCapability' \
        'consumeLegacyUICompatibilityApplicationSessionIfRequested' \
        'consumeLegacyUICompatibilityMutationDiagnosticIfRequested' \
        'memberName:@"setMetadataValue"'; do
    rg -Fq "$token" "$data" "$mobile" "$application" "$provider" \
        "$rendering_provider" "$provider_application" "$mutation_diagnostic" "$lifetime_diagnostic" ||
        fail "missing native consumer contract: $token"
done

for operation in \
        'Source.addSection' 'Source.removeSection' 'Source.remove' \
        'CydiaObject.refreshSources' 'CydiaObject.saveConfig' \
        'CydiaObject.addTrivialSource' 'CydiaObject.addSource' \
        'Package.clear' 'Package.install' 'Package.remove' \
        'CydiaObject.installPackages'; do
    rg -Fq "$operation" "$mutation_diagnostic" ||
        fail "trusted mutation harness is missing allowlisted operation: $operation"
done
rg -Fq 'CYDIA_NATIVE_COMPATIBILITY_MUTATION_OPERATION' "$data" ||
    fail "trusted mutation harness is not environment-gated"
rg -Fq 'CydiaNativeCompatibilityMutationDiagnosticOperation' "$data" ||
    fail "trusted mutation harness has no bounded operation parser"

package_lane=$(sed -n '/^- (void) consumeLegacyUICompatibilityMutationDiagnosticIfRequested {/,/^}/p' "$data")
for token in 'CydiaNativeCompatibilityMutationDiagnosticPackage(database_)' \
        'fixed-fixture-not-found' 'legacyUICompatibilitySessionForPackage:canonicalPackage' \
        'arguments = @[@[canonicalPackage]]' 'fixed-package-mutation-boundary' \
        'CydiaNativeCompatibilityMutationDiagnosticPreparePackage(' \
        'CydiaNativeCompatibilityPackageMutationObservation(operation, session,'; do
    printf '%s\n' "$package_lane" | rg -Fq "$token" ||
        fail "fixed package mutation driver lacks $token"
done
for token in 'executorEntryCount] - entriesBefore' 'denialCount] - rejectionsBefore' \
        'packageModeBefore' 'packageModeAfter' 'in-memory-fixture-install-mark-not-API-evidence' \
        'native transaction and disk outcome require independent evidence'; do
    rg -Fq "$token" "$mutation_diagnostic" || fail "package observation lacks $token"
done
if printf '%s\n' "$package_lane" | rg '\[self (clearPackage|installPackage|removePackage|installPackages):' >/dev/null; then
    fail "fixed package driver bypasses the native-session API boundary"
fi

# Both fixed diagnostic lanes must apply revocation after submitting the real
# provider request. Otherwise metadata tests silently exercise an ordinary
# accepted mutation even with the revocation environment set.
test "$(rg -F -c 'CydiaNativeCompatibilityMutationDiagnosticRevokeAuthority(' "$data" || true)" = 3 ||
    fail "operation and metadata lanes must share the post-request revocation hook"
authority_guard=$(sed -n '/^- (BOOL) sessionIsOwnedAndActive:.* {/,/^}/p' "$provider")
for token in 'application = application_' 'database = database_' \
        'application != nil' 'database != nil' '_isIssuedForApplication:application'; do
    printf '%s\n' "$authority_guard" | rg -Fq "$token" ||
        fail "deferred authority guard does not revalidate $token"
done
revocation_hook=$(sed -n '/^- (void) revokeAuthorityForDiagnosticBoundary:.* {/,/^}/p' "$provider")
for token in 'CYDIA_NATIVE_COMPATIBILITY_MUTATION_REVOKE_BOUNDARY' \
        '[NSThread isMainThread]' '[boundary isEqualToString:requested]'; do
    printf '%s\n' "$revocation_hook" | rg -Fq "$token" ||
        fail "native revocation hook lacks its own opt-in guard: $token"
done

# A flat ./ suite cannot have components in APT.  Source.addSection and
# removeSection must target the same component-based source created by
# addSource, not the separate flat source used by addTrivialSource.
rg -Fq 'CydiaNativeCompatibilityMutationDiagnosticSourceKey' "$data" ||
    fail "source section diagnostic must use the bounded transport helper"
rg -Fq 'CydiaNativeCompatibilityMutationDiagnosticSourceURL' "$data" ||
    fail "addSource diagnostic must use the bounded transport URL helper"
rg -Fq '@"https://native-compatibility-diagnostic.invalid/"' "$mutation_diagnostic" ||
    fail "default diagnostic source URL disappeared"
rg -Fq '@"https://native-compatibility.invalid/"' "$mutation_diagnostic" ||
    fail "B1.7 diagnostic source URL disappeared"
rg -Fq '@"com.torrekie.cydia-ui-transaction-fixture"' "$mutation_diagnostic" ||
    fail "default diagnostic package disappeared"
rg -Fq '@"com.example.native-compatibility"' "$mutation_diagnostic" ||
    fail "B1.7 diagnostic package disappeared"

if rg -n '\[\[(Package|Source) alloc\]|newPackageWithHandle|initWithHandle:' "$data" >/dev/null; then
    fail "diagnostic consumer synthesizes package/source targets"
fi

if rg -n 'UIWebView|WebScript|WebFrame|WAKView|WebCore|applicationCache' "$data" >/dev/null; then
    fail "diagnostic consumer depends on a retired web/private UI surface"
fi

loaded_line=$(rg -n '^[-] \(void\) _loaded \{' "$data" | cut -d: -f1 | head -n 1)
consumer_line=$(rg -n '\[self consumeLegacyUICompatibilityApplicationSessionIfRequested\];' "$data" | cut -d: -f1 | tail -n 1)
disemulate_line=$(rg -n '\[self disemulate\];' "$mobile" | cut -d: -f1 | tail -n 1)
mutation_requested_line=$(rg -n 'BOOL mutationDiagnosticRequested\(\[self legacyUICompatibilityMutationDiagnosticRequested\]\);' "$mobile" | cut -d: -f1 | head -n 1)
mutation_hook_line=$(rg -n 'performSelector:@selector\(consumeLegacyUICompatibilityMutationDiagnosticIfRequested\)' "$mobile" | cut -d: -f1 | head -n 1)
loaded_end=$(awk -v start="$loaded_line" 'NR > start && /^- \(void\) / { print NR; exit }' "$data")
test -n "$loaded_line" && test -n "$consumer_line" && test -n "$loaded_end" && test -n "$disemulate_line" &&
    test -n "$mutation_requested_line" && test -n "$mutation_hook_line" ||
    fail "cannot locate post-load hook ordering"
test "$consumer_line" -gt "$loaded_line" ||
    fail "consumer runs before the _loaded completion point"
test "$consumer_line" -lt "$loaded_end" ||
    fail "consumer is not invoked inside _loaded"
test "$mutation_hook_line" -gt "$disemulate_line" ||
    fail "mutation harness is scheduled before the native tab bar is attached"
printf '%s\n' "$(sed -n '1,9999p' "$mobile")" | sed -n "${mutation_requested_line},${mutation_hook_line}p" | rg -Fq 'if (!mutationDiagnosticRequested)' ||
    fail "normal refresh is not guarded by the opt-in mutation mode"
printf '%s\n' "$(sed -n '1,9999p' "$mobile")" | sed -n "${mutation_requested_line},${mutation_hook_line}p" | rg -Fq 'if (mutationDiagnosticRequested)' ||
    fail "mutation harness is not conditionally scheduled"

method_start=$(rg -n '^[-] \(void\) consumeLegacyUICompatibilityApplicationSessionIfRequested \{' "$data" | cut -d: -f1 | head -n 1)
method_end=$(awk -v start="$method_start" 'NR > start && /^- \(void\) syncData \{/ { print NR; exit }' "$data")
test -n "$method_start" && test -n "$method_end" ||
    fail "cannot isolate diagnostic consumer method"
method=$(sed -n "${method_start},$((method_end - 1))p" "$data")
execution_start=$(rg -n '^[-] \(void\) consumeLegacyUICompatibilityExecutionEvidenceIfRequested \{' "$data" | cut -d: -f1 | head -n 1)
execution_end=$(awk -v start="$execution_start" 'NR > start && /^[-] \(void\) / { print NR; exit }' "$data")
test -n "$execution_start" && test -n "$execution_end" || fail "cannot isolate execution consumer method"
execution_method=$(sed -n "${execution_start},$((execution_end - 1))p" "$data")
printf '%s\n' "$execution_method" | rg -Fq '[candidate id]' &&
printf '%s\n' "$execution_method" | rg -Fq 'isEqualToString:requestedPackage' ||
    fail "execution selector does not match the stable package identity"
printf '%s\n' "$execution_method" | rg -Fq ' > 30' ||
    fail "execution retry window is not bounded at the startup-safe limit"
printf '%s\n' "$execution_method" | rg -Fq 'CydiaNativeCompatibilityWriteExecutionDiagnostic' ||
    fail "execution retry state is not captured by the opt-in diagnostic"
printf '%s\n' "$execution_method" | rg -Fq 'session-inactive' ||
    fail "execution diagnostic does not record inactive provider sessions"
if printf '%s\n' "$execution_method" | rg -n '\[candidate cyname\].*requestedPackage' >/dev/null; then
    fail "execution selector compares a display name instead of package identity"
fi
diagnostic_start=$(rg -n '^static NSString \*CydiaNativeCompatibilityExecutionDiagnosticPath\(' "$data" | cut -d: -f1 | head -n 1)
diagnostic_end=$(awk -v start="$diagnostic_start" 'NR > start && /^static void CydiaNativeCompatibilityWriteExecutionDiagnostic\(/ { print NR; exit }' "$data")
test -n "$diagnostic_start" && test -n "$diagnostic_end" ||
    fail "cannot isolate execution diagnostic path helper"
diagnostic_path=$(sed -n "${diagnostic_start},$((diagnostic_end - 1))p" "$data")
for token in \
        'CYDIA_NATIVE_COMPATIBILITY_EXECUTION_DIAGNOSTIC_PATH' \
        'controlCharacterSet' \
        'stringByStandardizingPath' \
        'fileExistsAtPath:parent isDirectory:' \
        'receipt isEqualToString:path'; do
    printf '%s\n' "$diagnostic_path" | rg -Fq "$token" ||
        fail "execution diagnostic path is missing safety guard: $token"
done
for token in \
        '@"attempt"' \
        '@"requestedPackage"' \
        '@"packageFound"' \
        '@"sessionActive"' \
        '@"reason"' \
        'writeToFile:path atomically:YES'; do
    rg -Fq "$token" "$data" || fail "execution diagnostic payload missing: $token"
done
if printf '%s\n' "$method" | rg -n 'addSource:|addTrivialSource:|syncData|_saveConfig|installPackage|removePackage|clearPackage|refreshSources|saveConfig' >/dev/null; then
    fail "diagnostic consumer contains a mutation path"
fi
printf '%s\n' "$method" | rg -Fq 'if (!CydiaNativeCompatibilityDiagnosticRequested())' ||
    fail "diagnostic consumer is not environment-gated"
printf '%s\n' "$method" | rg -Fq 'if (![NSThread isMainThread])' ||
    fail "diagnostic consumer does not serialize to the main thread"
printf '%s\n' "$method" | rg -Fq 'memberName:@"getMetadataKeys"' ||
    fail "diagnostic does not exercise the metadata-key read"
printf '%s\n' "$method" | rg -Fq 'memberName:@"getMetadataValue"' ||
    fail "diagnostic does not exercise the metadata-value read"
printf '%s\n' "$method" | rg -Fq 'metadataKeyCount' ||
    fail "diagnostic does not record a bounded metadata-key count"
printf '%s\n' "$method" | rg -Fq 'metadataValueDefined' ||
    fail "diagnostic does not record metadata defined state"
printf '%s\n' "$method" | rg -Fq 'CydiaNativeCompatibilityDiagnosticMaximumMetadataKeys' ||
    fail "diagnostic metadata-key list is not bounded"
printf '%s\n' "$method" | rg -Fq 'CydiaNativeCompatibilityDiagnosticSafeMetadataKey' ||
    fail "diagnostic metadata key is not validated"

mutation_start=$(rg -n '^[-] \(void\) consumeLegacyUICompatibilityMutationDiagnosticIfRequested \{' "$data" | cut -d: -f1 | head -n 1)
test -n "$mutation_start" || fail "cannot isolate mutation diagnostic method"
for token in \
        'CydiaNativeCompatibilityMutationDiagnosticMode()' \
        'legacyCompatibilityMutationDiagnosticConsumed_' \
        'legacyUICompatibilitySessionForApplicationWithPresenter:tabbar_' \
        'memberName:@"getMetadataValue"' \
        'memberName:@"setMetadataValue"' \
        'CydiaNativeCompatibilityMutationDiagnosticKey()' \
        'CydiaLegacyUICompatibilityNativeDenialReasonNone' \
        'CydiaLegacyUIUndefinedValue'; do
    rg -Fq "$token" "$data" || fail "mutation diagnostic missing contract: $token"
done
if printf '%s\n' "$method" | rg -n 'memberName:@"setMetadataValue"|CYDIA_NATIVE_COMPATIBILITY_MUTATION_DIAGNOSTIC' >/dev/null; then
    fail "read-only diagnostic unexpectedly contains mutation invocation"
fi
if rg -n 'UIWebView|WebScript|WebFrame|WAKView|WebCore|applicationCache' "$data" >/dev/null; then
    fail "mutation diagnostic depends on a retired web/private UI surface"
fi

sh "$root/tests/NativePackageMutationDiagnosticTests.sh"
echo "[verify-legacy-ui-compatibility-native-consumer][ ok ] opt-in post-load native session consumer"
