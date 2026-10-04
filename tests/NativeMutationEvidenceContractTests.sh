#!/bin/sh
# Copyright (C) 2026 Torrekie
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
provider=$root/Cydia/LegacyUICompatibilityNativeProvider.mm
confirmation=$root/Cydia/NativeMutationConfirmation.mm
evidence=$root/Cydia/NativeMutationEvidence.mm
fail() {
    echo "[native-mutation-evidence-contract][FAIL] $*" >&2
    exit 1
}
for token in '[guard cancel]' '[guard accept]' '[guard presentationRequested]' \
        '[guard presented]' '[guard presentationRejected]' \
        'runtimeVersion:Cydia_' 'session, target, operation, action, effectKind'; do
    rg -Fq "$token" "$confirmation" || fail "missing real confirmation wiring: $token"
done
for token in 'session, source, [@"Source." stringByAppendingString:memberName]' \
        '@"Source.remove"' '@"CydiaObject.refreshSources"' '@"CydiaObject.saveConfig"' \
        '@"CydiaObject.addTrivialSource"' '@"CydiaObject.addSource"' \
        '@"CydiaObject.setMetadataValue"' \
        'canonicalRemoving ? @"metadata-remove" : @"metadata-set"'; do
    rg -Fq "$token" "$provider" || fail "unobserved confirmation path: $token"
done
metadata=$(sed -n '/   requestMetadataMutationForKey:/,/^}/p' "$provider")
printf '%s\n' "$metadata" | rg -Uq \
    '\[values removeObjectForKey:canonicalKey\];[\s\S]*\[values setObject:canonicalValue forKey:canonicalKey\];[\s\S]*\[strongApplication _saveConfig\];\n[[:space:]]*return YES;' ||
    fail 'metadata completion must follow the actual write and save attempt'
for token in 'strongSelf->database_ != database' 'strongSelf->presenter_ != presenter' \
        '[strongSession presenter] != presenter' '![strongSelf sessionIsOwnedAndActive:strongSession]'; do
    printf '%s\n' "$metadata" | rg -Fq "$token" || fail 'metadata authority recheck missing'
done
for token in 'CYDIA_NATIVE_COMPATIBILITY_MUTATION_EVIDENCE_PATH' \
        'O_EXCL | O_NOFOLLOW | O_CLOEXEC' '0600' 'MaximumEvents' 'MaximumRequests' \
        'MaximumBytes' 'journal_incomplete' 'duplicate_callback_suppressed' \
        'authority_rejected' 'effect_returned' 'request_finished' \
        '@"persistence": @"unverified"' '@"installedAcceptance": @"not_claimed"'; do
    rg -Fq "$token" "$evidence" || fail "missing bounded observation rule: $token"
done
rg -Fq 'CYDIA_NATIVE_COMPATIBILITY_MUTATION_REPLAY' "$confirmation" ||
    fail 'confirmation replay trigger missing'
rg -Fq 'dispatch_async(dispatch_get_main_queue()' "$confirmation" ||
    fail 'installed replay trigger must be main-queue bounded'
rg -Fq '[guard accept];' "$confirmation" ||
    fail 'confirmation must retain the one-shot guard for replay suppression'
if rg -n 'invokeScope:|setMetadataValue|Values_|NSURLConnection|NSURLSession|UIWebView|WebScript' \
        "$evidence" >/dev/null; then
    fail 'journal gained mutation dispatch, metadata contents, or network/browser access'
fi
if rg -n 'NativeMutationEvidence|NativeMutationAction|MUTATION_EVIDENCE_PATH' \
        "$root/Cydia/LegacyBridgeOperations.def" "$root/Cydia/LegacyBridgeProperties.def" \
        "$root/Cydia/UIRouteDispatch.mm" "$root/Cydia/PackageDepictionPolicy.mm" >/dev/null; then
    fail 'observation is reachable through the compatibility or depiction/route boundary'
fi
echo '[native-mutation-evidence-contract][ ok ] native confirmation/effect wiring; no runtime acceptance claim'
