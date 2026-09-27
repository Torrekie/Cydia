#!/bin/sh
# Cydia URL-protocol production integration contract.
# Copyright (C) 2026 Torrekie
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
protocol="$root/Cydia/URLProtocol.mm"
base="$root/CyteKit/URLProtocol.mm"
policy="$root/Cydia/URLProtocolPolicy.mm"
resolver="$root/Cydia/URLResourceResolver.mm"

fail() {
    echo "[verify-url-protocol-policy][FAIL] $*" >&2
    exit 1
}

for source in "$protocol" "$base" "$policy" "$resolver"; do
    test -f "$source" || fail "missing production source: $source"
done

grep -Fq '#include "Cydia/URLResourceResolver.h"' "$protocol" ||
    fail "legacy protocol does not use the shared resource resolver"
grep -Fq '#include "Cydia/URLProtocolPolicy.h"' "$resolver" ||
    fail "shared resolver does not import the typed policy"
if grep -Fq 'stringByReplacingPercentEscapesUsingEncoding' "$protocol" "$resolver"; then
    fail "production resource loading still performs untyped percent decoding"
fi

for specification in \
        'application-icon:CydiaURLResourceKindApplicationIcon' \
        'package-icon:CydiaURLResourceKindPackageIcon' \
        'uikit-image:CydiaURLResourceKindUIKitImage' \
        'section-icon:CydiaURLResourceKindSectionIcon'; do
    command=${specification%%:*}
    kind=${specification#*:}
    grep -Fq "[command isEqualToString:@\"$command\"]" "$policy" ||
        fail "$command lost its typed policy mapping"
    grep -Fq "case $kind:" "$resolver" ||
        fail "$command lost its shared resolver branch"
done

decode_count=$(grep -Fc \
    'CydiaURLResourceDecodeIdentifier(rawIdentifier, kind)' "$resolver")
test "$decode_count" -eq 1 ||
    fail "shared resolver does not decode exactly one typed identifier"
grep -Fq 'if (identifier == nil)' "$resolver" ||
    fail "shared resolver does not fail closed on rejected identifiers"

for result in \
        CydiaURLResourceResolutionUnhandled \
        CydiaURLResourceResolutionFailed \
        CydiaURLResourceResolutionSucceeded; do
    grep -Fq "case $result:" "$protocol" ||
        fail "legacy protocol lost shared resolver result: $result"
done
grep -Fq '[self _returnPNGData:data forRequest:request]' "$protocol" ||
    fail "legacy protocol does not deliver shared validated PNG data"
grep -Fq '[self _returnPNGData:nil forRequest:request]' "$protocol" ||
    fail "legacy protocol does not fail recognized invalid resources"

decode_method=$(sed -n \
    '/NSString \*CydiaURLResourceDecodeIdentifier/,/BOOL CydiaURLResourceImageDimensionsAreAllowed/p' \
    "$policy")
length_line=$(printf '%s\n' "$decode_method" | grep -n -F \
    '[rawIdentifier length] > kMaximumIdentifierBytes' | head -1 | cut -d: -f1)
encode_line=$(printf '%s\n' "$decode_method" | grep -n -F \
    'dataUsingEncoding:NSUTF8StringEncoding' | head -1 | cut -d: -f1)
test -n "$length_line" && test -n "$encode_line" && test "$length_line" -lt "$encode_line" ||
    fail "raw identifier is copied before its character bound"

image_method=$(sed -n '/NSData \*EncodeImage/,/UIImage \*ApplicationIcon/p' "$resolver")
dimension_line=$(printf '%s\n' "$image_method" | grep -n -F \
    'CydiaURLResourceImageDimensionsAreAllowed' | head -1 | cut -d: -f1)
encode_line=$(printf '%s\n' "$image_method" | grep -n -F \
    'UIImagePNGRepresentation(image)' | head -1 | cut -d: -f1)
data_line=$(printf '%s\n' "$image_method" | grep -n -F \
    'CydiaURLResourcePNGDataIsAllowed(data)' | head -1 | cut -d: -f1)
test -n "$dimension_line" && test -n "$encode_line" && test -n "$data_line" && \
    test "$dimension_line" -lt "$encode_line" && test "$encode_line" -lt "$data_line" ||
    fail "shared PNG resolver no longer bounds dimensions before encoding and bytes before return"

application_method=$(sed -n '/UIImage \*ApplicationIcon/,/UIImage \*PackageIcon/p' "$resolver")
provider_line=$(printf '%s\n' "$application_method" | grep -n -F \
    '$SBSCopyIconImagePNGDataForDisplayIdentifier(identifier)' | head -1 | cut -d: -f1)
validate_line=$(printf '%s\n' "$application_method" | grep -n -F \
    'CydiaURLResourcePNGDataIsAllowed(data)' | head -1 | cut -d: -f1)
decode_line=$(printf '%s\n' "$application_method" | grep -n -F \
    '[UIImage imageWithData:data]' | head -1 | cut -d: -f1)
test -n "$provider_line" && test -n "$validate_line" && test -n "$decode_line" && \
    test "$provider_line" -lt "$validate_line" && test "$validate_line" -lt "$decode_line" ||
    fail "private icon bytes are decoded before the PNG bound"

if grep -Eq 'UIImagePNGRepresentation|packageWithName:|_UIImageWithName|CydiaCopyIconImagePath' "$protocol"; then
    fail "legacy protocol duplicated shared image resolution"
fi

data_method=$(sed -n '/- (void) _returnPNGData:/,/- (bool) loadForPath:/p' "$base")
nil_line=$(printf '%s\n' "$data_method" | grep -n -F \
    'if (data == nil)' | head -1 | cut -d: -f1)
load_line=$(printf '%s\n' "$data_method" | grep -n -F \
    'didLoadData:data' | head -1 | cut -d: -f1)
test -n "$nil_line" && test -n "$load_line" && test "$nil_line" -lt "$load_line" ||
    fail "base protocol can deliver nil data instead of failing the request"

echo "[verify-url-protocol-policy][ ok ] production resource loading is typed and bounded"
