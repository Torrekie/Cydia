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

fail() {
    echo "[verify-legacy-ui-compatibility-native-consumer][FAIL] $*" >&2
    exit 1
}

command -v rg >/dev/null 2>&1 || fail "rg is required"
for file in "$data" "$mobile" "$application" "$provider" "$rendering_provider" "$provider_application"; do
    test -f "$file" || fail "missing native consumer source: $file"
done

for token in \
        'CYDIA_NATIVE_COMPATIBILITY_DIAGNOSTIC' \
        'CydiaNativeCompatibilityDiagnosticRequested' \
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
        'legacyUICompatibilitySessionForSource:canonicalSource' \
        'memberName:@"id"' \
        'memberName:@"key"' \
        'handoffRouteURL:' \
        'native-compatibility-diagnostic.invalid' \
        'invalidationSession' \
        'CydiaLegacyUICompatibilityNativeDenialReasonInvalidCapability' \
        'consumeLegacyUICompatibilityApplicationSessionIfRequested'; do
    rg -Fq "$token" "$data" "$mobile" "$application" "$provider" \
        "$rendering_provider" "$provider_application" ||
        fail "missing native consumer contract: $token"
done

if rg -n '\[\[(Package|Source) alloc\]|newPackageWithHandle|initWithHandle:' "$data" >/dev/null; then
    fail "diagnostic consumer synthesizes package/source targets"
fi

if rg -n 'UIWebView|WebScript|WebFrame|WAKView|WebCore|applicationCache' "$data" >/dev/null; then
    fail "diagnostic consumer depends on a retired web/private UI surface"
fi

loaded_line=$(rg -n '^[-] \(void\) _loaded \{' "$data" | cut -d: -f1 | head -n 1)
consumer_line=$(rg -n '\[self consumeLegacyUICompatibilityApplicationSessionIfRequested\];' "$data" | cut -d: -f1 | tail -n 1)
disemulate_line=$(rg -n '\[self disemulate\];' "$mobile" | cut -d: -f1 | tail -n 1)
loaded_end=$(awk -v start="$loaded_line" 'NR > start && /^- \(void\) / { print NR; exit }' "$data")
test -n "$loaded_line" && test -n "$consumer_line" && test -n "$loaded_end" && test -n "$disemulate_line" ||
    fail "cannot locate post-load hook ordering"
test "$consumer_line" -gt "$loaded_line" ||
    fail "consumer runs before the _loaded completion point"
test "$consumer_line" -lt "$loaded_end" ||
    fail "consumer is not invoked inside _loaded"
if rg -n '\[self consumeLegacyUICompatibilityApplicationSessionIfRequested\];' "$mobile" >/dev/null; then
    fail "consumer is invoked from loadData before refresh completion"
fi

method_start=$(rg -n '^[-] \(void\) consumeLegacyUICompatibilityApplicationSessionIfRequested \{' "$data" | cut -d: -f1 | head -n 1)
method_end=$(awk -v start="$method_start" 'NR > start && /^- \(void\) syncData \{/ { print NR; exit }' "$data")
test -n "$method_start" && test -n "$method_end" ||
    fail "cannot isolate diagnostic consumer method"
method=$(sed -n "${method_start},$((method_end - 1))p" "$data")
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

echo "[verify-legacy-ui-compatibility-native-consumer][ ok ] opt-in post-load native session consumer"
