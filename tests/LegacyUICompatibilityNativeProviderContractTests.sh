#!/bin/sh
# Copyright (C) 2026 Torrekie
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
provider=$root/Cydia/LegacyUICompatibilityNativeProvider.mm
rendering_provider=$root/Cydia/LegacyUICompatibilityNativeRenderingProvider.mm
header=$root/Cydia/LegacyUICompatibilityNativeProvider.h
provider_application=$root/Cydia/LegacyUICompatibilityNativeProvider+Application.mm
external_policy_header=$root/Cydia/ExternalURLPolicy.h
external_policy_source=$root/Cydia/ExternalURLPolicy.mm
application=$root/Cydia/Application.h
mobile=$root/MobileCydia.mm
lifecycle=$root/Cydia/Application+Lifecycle.mm

fail() {
    echo "[verify-legacy-ui-compatibility-native-provider][FAIL] $*" >&2
    exit 1
}

command -v rg >/dev/null 2>&1 || fail "rg is required"
for file in "$provider" "$rendering_provider" "$header" \
        "$provider_application" "$external_policy_header" "$external_policy_source" \
        "$application" "$mobile" "$lifecycle"; do
    test -f "$file" || fail "missing provider/wiring source: $file"
done

for token in \
        'CydiaLegacyUICompatibilityNativeProvider' \
        'sessionForPackage:' \
        'sessionForSource:' \
        'sessionForApplicationWithPresenter:' \
        'sessionForRenderingWithPresenter:' \
        'valueForPackageScope:' \
        'valueForSourceMember:' \
        'valueForSessionMember:' \
        'valueForRenderingMember:' \
        'RenderingSafeString' \
        'RenderingSafeReachabilityName' \
        'supports' \
        'isReachable' \
        'getMetadataKeys' \
        'getMetadataValue' \
        'CopyMetadataKeys' \
        'CopyMetadataReadValue' \
        'kMaximumMetadataReadKeyCount' \
        'requestMetadataMutationForKey:' \
        'CydiaLegacyUICompatibilityCopyMetadataValue' \
        'CydiaLegacyUICompatibilityCopyMetadataKey' \
        'commitGate' \
        'committed' \
        'Values_' \
        'legacyValues' \
        '[legacyValues isKindOfClass:[NSDictionary class]]' \
        '[legacyValues mutableCopy]' \
        '_saveConfig' \
        'getPackageById' \
        'CanonicalPackageForIdentifier' \
        'packageWithName:identifier' \
        '[lookup parse]' \
        'return package ?: [NSNull null]' \
        'substitutePackageNames' \
        'componentsSeparatedByString:@" "' \
        '[database hasPackages]' \
        'OwnedPackageDisplayName' \
        'getSessionValue' \
        'SessionData_' \
        'CopySessionValue' \
        'localize' \
        'format' \
        'CydiaLegacyUICompatibilityLocalizedStringInBundle' \
        'CydiaLegacyUICompatibilityFormatString' \
        'requestPackageMutation:' \
        'handoffRouteDescriptor:' \
        'CydiaManagedSourceKeyIsOwned' \
        'CydiaExternalURLIsValidWebURL' \
        'CydiaUIDispatchRouteURL' \
        'PresentNativeConfirmation' \
        'UIAlertController' \
        '_addSection:' \
        '_removeSection:' \
        '_remove' \
        'sessionIsOwnedAndActive:' \
        'NSPointerFunctionsObjectPointerPersonality' \
        'effectivePresenter != presenter_' \
        'context != [session context]' \
        'presenter != [session presenter]' \
        'legacyCompatibilityProvider_' \
        'legacyCompatibilityCaller_' \
        'issueCapabilityForApplication:' \
        'invalidateLegacyUICompatibility'; do
    rg -Fq "$token" "$provider" "$rendering_provider" "$header" \
        "$provider_application" "$application" "$mobile" "$lifecycle" ||
        fail "missing app-owned provider contract: $token"
done

if rg -n 'UIWebView|WebView|WebScript|WebFrame|valueForKey:|performSelector:|system:' \
        "$provider" "$rendering_provider" "$header" >/dev/null; then
    fail "provider exposes browser, shell, generic KVC, or selector dispatch"
fi

rg -Fq 'dispatch_sync(dispatch_get_main_queue()' "$provider" ||
    fail "provider does not serialize mutations/routes onto main queue"
rg -Fq '[NSBundle mainBundle]' "$rendering_provider" ||
    fail "localize provider is not bound to the application bundle"
rg -Fq '[arguments count] == 3' "$rendering_provider" ||
    fail "localize provider does not enforce its three-argument signature"
rg -Fq '[arguments count] == 2' "$rendering_provider" ||
    fail "format provider does not enforce its two-argument signature"
rg -Fq '[NSThread isMainThread]' "$provider" ||
    fail "metadata confirmation commit does not require the main thread"
rg -Fq 'return OnMain(^BOOL {' "$provider" ||
    fail "metadata confirmation presentation is not main-thread serialized"
rg -Fq 'application_ != application' "$provider" ||
    fail "metadata confirmation lacks an exact application recheck"
rg -Fq 'database_ != database' "$provider" ||
    fail "metadata confirmation lacks an exact database recheck"
rg -Fq 'strongSelf->database_ != database' "$provider" ||
    fail "deferred metadata commit lacks a captured database recheck"
rg -Fq 'strongSelf->presenter_ != presenter' "$provider" ||
    fail "deferred metadata commit lacks a captured presenter recheck"
rg -Fq '@synchronized (commitGate)' "$provider" ||
    fail "metadata confirmation commit has no one-shot gate"
rg -Fq 'canonicalRemoving' "$provider" ||
    fail "metadata mutation does not preserve the explicit remove convention"
rg -Fq '[values setObject:canonicalValue forKey:canonicalKey]' "$provider" ||
    fail "metadata mutation does not write the normalized property-list value"
rg -Fq '[values removeObjectForKey:canonicalKey]' "$provider" ||
    fail "metadata mutation does not remove undefined/null values"
if rg -n 'NSURLRequest|NSURLConnection|URLSession|WebKit|UIWebView|WebScript|CyteIsReachable|SCNetworkReachability' \
        "$provider" "$rendering_provider" >/dev/null; then
    fail "localize provider gained a network or browser dependency"
fi
rg -Fq 'sessionForScope:@"CyteObject" target:application' "$rendering_provider" ||
    fail "rendering factory is not bound to the exact live application target"
rg -Fq 'object_getClass(application) != NSClassFromString(@"Cydia")' "$rendering_provider" ||
    fail "rendering factory does not require exact Cydia application identity"
rg -Fq 'effectivePresenter != self.presenter' "$rendering_provider" ||
    fail "rendering factory does not bind the exact live presenter"
rg -Fq 'first-party origin contract' "$rendering_provider" ||
    fail "reachability fail-closed policy is undocumented at the provider boundary"
rg -Fq 'target] != application' "$rendering_provider" ||
    fail "rendering provider does not recheck the exact application target"
rg -Fq '[arguments count] == 1' "$rendering_provider" ||
    fail "supports/isReachable provider callbacks do not enforce one argument"
rg -Fq 'ExactClass(package, [Package class])' "$provider" ||
    fail "package target is not exact-class validated"
rg -Fq 'ExactClass(source, [Source class])' "$provider" ||
    fail "source target is not exact-class validated"
rg -Fq 'CopyPackageMutationSnapshot' "$provider" ||
    fail "installPackages does not retain a validated package snapshot"
rg -Fq 'RevalidatePackageMutationSnapshot' "$provider" ||
    fail "installPackages lacks a main-thread package revalidation"
rg -Fq '!CurrentPackage(database, (Package *)target, &currentIdentity)' "$provider" ||
    fail "package mutation lacks a main-thread canonical target recheck"
rg -Fq 'initWithArray:values copyItems:NO' "$provider" ||
    fail "package mutation does not detach the caller package array"
rg -Fq 'CopySourceMutationPayload' "$provider" ||
    fail "addSource does not materialize its confirmation payload"
rg -Fq 'initWithArray:ownedSections copyItems:YES' "$provider" ||
    fail "addSource sections are not deeply copied before confirmation"
if rg -n '\[application\] installPackages:\[arguments objectAtIndex:0\]' \
        "$provider" >/dev/null; then
    fail "installPackages captures the mutable caller argument array"
fi
rg -Fq 'CydiaManagedSourceKeyIsOwned(key)' "$provider" ||
    fail "source mutation lacks managed-source ownership gate"
rg -Fq 'ExactClass(session, [CydiaLegacyUICompatibilityNativeSession class])' "$provider" ||
    fail "provider session membership is not exact-class bound"
rg -Fq 'ExactClass(candidate, [Package class])' "$provider" ||
    fail "package lookup does not return an exact canonical Package object"
rg -Fq '@synchronized (values)' "$provider" ||
    fail "session value reads are not synchronized"
rg -Fq 'return CopyMetadataKeys(values)' "$provider" ||
    fail "metadata-key reads do not return a detached bounded snapshot"
rg -Fq 'return CopyMetadataReadValue([values objectForKey:key])' "$provider" ||
    fail "metadata-value reads do not return a validated immutable snapshot"
rg -Fq '[rawKeys count] > kMaximumMetadataReadKeyCount' "$provider" ||
    fail "metadata-key reads do not enforce a bounded key count"
rg -Fq '[session target] != application_' "$provider" ||
    fail "session value reads are not bound to the exact application target"
rg -Fq 'return [words componentsJoinedByString:@" "]' "$provider" ||
    fail "package-name substitution does not preserve literal-space semantics"
rg -Fq 'object_getClass(object) == expected' "$provider" ||
    fail "provider exact-class checks use overridable Objective-C identity"
rg -Fq '_isIssuedForApplication:application_' "$provider" ||
    fail "provider caller capability is not bound to its Cydia application"
rg -Fq 'active && application != nil && database != nil && presenter != nil' "$provider" ||
    fail "provider activity does not require a live presenter"
rg -Fq 'SafeSourceKey(sourceKey)' "$provider" ||
    fail "route source lookup does not validate the source key"
rg -Fq '#include "Cydia/ExternalURLPolicy.h"' "$provider" ||
    fail "source mutation provider does not import the shared URL policy"
source_url_method=$(sed -n '/^BOOL SafeSourceURL/,/^}/p' "$provider")
printf '%s\n' "$source_url_method" | rg -Fq \
    'CydiaExternalURLIsValidWebURL([NSURL URLWithString:value])' ||
    fail "source mutation URL validation does not use the shared web policy"
if printf '%s\n' "$source_url_method" | rg -n \
        '\[url (scheme|host|port|user|password)|isEqualToString:@"http"|isEqualToString:@"https"'; then
    fail "source mutation URL validation retains a duplicate weak predicate"
fi
test "$(rg -F -c 'SafeSourceURL([arguments objectAtIndex:0])' "$provider")" -ge 2 ||
    fail "both source mutation commands do not share strict URL validation"
rg -Fq '[self legacyNativeSession:session sourceKeyExists:sourceKey]' "$provider" ||
    fail "route parser bypasses the validated source lookup"
rg -Uq 'return OnMain\(\^BOOL \{\n[[:space:]]*if \(!\[self sessionIsOwnedAndActive:session\]\) return NO;\n[[:space:]]*/\* VerifySource may present[\s\S]*NSString \*href\(VerifySource\(candidate\)\)' "$provider" ||
    fail "alert-producing source verification is not main-thread serialized"
test "$(rg -F -c 'PresentNativeConfirmation(' "$provider")" -ge 6 ||
    fail "source/configuration mutations do not pass through native confirmation"
rg -Fq 'CydiaLegacyUICompatibilityNativeSession *strongSession(weakSession)' "$provider" ||
    fail "deferred confirmation does not retain a revocation-checkable session"
rg -Fq '!CydiaManagedSourceKeyIsOwned(currentKey)' "$provider" ||
    fail "deferred source mutation lacks an ownership recheck"
test "$(rg -F -c '[self sessionIsOwnedAndActive:session]' "$provider")" -ge 10 ||
    fail "provider callbacks do not recheck session liveness"

echo "[verify-legacy-ui-compatibility-native-provider][ ok ] app-owned typed provider and lifecycle wiring"
