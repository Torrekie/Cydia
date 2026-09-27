#!/bin/sh
# Copyright (C) 2026 Torrekie
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
controller=$root/Cydia/ErrorViewController.mm
header=$root/Cydia/ErrorViewController.h
model=$root/Cydia/ErrorViewModel.mm
probe=$root/tests/simulator/ErrorViewRuntimeProbe.mm

fail() {
    echo "[ErrorViewControllerContractTests][FAIL] $*" >&2
    exit 1
}

for file in "$header" "$controller" "$model" "$probe"; do
    test -f "$file" || fail "missing source: $file"
done

grep -q '@interface ErrorViewController : CyteViewController' \
    "$header" || fail "error surface is not native UIKit"
grep -q 'accessibilityViewIsModal = YES' "$controller" ||
    fail "native error does not isolate the hidden web accessibility tree"
for identifier in native-error.title native-error.summary native-error.details \
        native-error.retry native-error.more-information; do
    grep -Fq "@\"$identifier\"" "$controller" ||
        fail "missing accessibility identifier: $identifier"
done
test "$(grep -c 'constraintGreaterThanOrEqualToConstant:44.0' "$controller")" -ge 2 ||
    fail "Retry and More Information are below the 44-point contract"
grep -q 'traitCollectionDidChange:' "$controller" ||
    fail "native error does not update with live appearance"
grep -q 'CydiaColorRoleGroupedBackground' "$controller" ||
    fail "native error has no semantic surface"
if grep -Eq 'UIWebView|WKWebView|WebKit|javascript:|loadRequest:' \
        "$controller" "$model"; then
    fail "native error surface contains web rendering"
fi

grep -q '@protocol ErrorViewControllerDelegate' "$header" &&
    grep -q 'errorViewControllerDidRequestRetry:' "$header" "$controller" ||
    fail "native Retry lacks its public delegate boundary"
grep -q '<ErrorViewControllerDelegate>' "$probe" &&
    grep -q 'errorViewControllerDidRequestRetry:' "$probe" ||
    fail "installed native-error probe bypasses the public delegate boundary"
grep -q 'lastRetryRequest_ = \[originalRequest_ copy\]' "$probe" ||
    fail "native Retry probe does not preserve its exact request snapshot"
if grep -Eq 'CydiaWebViewController|CyteWebViewController|WebViewControllerPrivate|loadRequest:|stringByEvaluatingJavaScript' \
        "$probe"; then
    fail "installed native-error probe still depends on a web controller"
fi
for asset in error.html localize.js menes/menes.js; do
    test ! -e "$root/MobileCydia.app/$asset" ||
        fail "retired bundled error asset remains: $asset"
done
if grep -Eq 'userInfo|HTTPBody|allHTTPHeaderFields' "$model"; then
    fail "native error model snapshots request secrets"
fi
grep -q 'destinationDisplayName' "$model" ||
    fail "native error model has no host-only destination"
grep -q 'maximum' "$model" || fail "native diagnostic text is not bounded"

echo "[ErrorViewControllerContractTests][ ok ] native retry/details boundary"
