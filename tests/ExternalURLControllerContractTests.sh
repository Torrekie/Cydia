#!/bin/sh
# Cydia Refurbished native external URL coordinator contract.
# Copyright (C) 2026 Torrekie
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
header="$root/Cydia/ExternalURLController.h"
controller="$root/Cydia/ExternalURLController.mm"
policy="$root/Cydia/ExternalURLPolicy.mm"
application="$root/Cydia/Application+Navigation.mm"

fail() {
    echo "[verify-external-url-controller][FAIL] $*" >&2
    exit 1
}

for file in "$header" "$controller" "$policy" "$application"; do
    test -f "$file" || fail "missing ${file#"$root/"}"
done

grep -q '@interface ExternalURLController : CyteViewController' "$header" ||
    fail "external coordinator is not native UIKit"
grep -q 'initWithRouteDescriptor:' "$header" ||
    fail "external coordinator lost its typed route initializer"
grep -q '<SafariServices/SafariServices.h>' "$controller" &&
    grep -q 'SFSafariViewController' "$controller" ||
    fail "HTTP(S) external content does not use Safari Services"
grep -q 'openURL:URL options:@{} completionHandler:completion' "$controller" ||
    fail "system mail/App Store handoff has no completion result"
grep -A8 'void (\^completion)(BOOL)' "$controller" | grep -q 'returnToPreviousController' ||
    fail "successful system handoff does not return to its originating page"
grep -q 'navigationURL' "$controller" ||
    fail "external coordinator does not preserve its canonical route"
grep -q 'retryButtonClicked' "$controller" ||
    fail "open failure has no native retry action"
grep -q 'CydiaColorRoleGroupedBackground' "$controller" &&
    grep -q 'preferredFontForTextStyle' "$controller" &&
    grep -q 'constraintGreaterThanOrEqualToConstant:44.0' "$controller" ||
    fail "native external state lacks semantic color, Dynamic Type, or touch target"
grep -q 'navigationBar.barStyle' "$controller" &&
    grep -q 'navigationBar.titleTextAttributes' "$controller" &&
    grep -q 'UCLocalize("RELOAD")' "$controller" ||
    fail "native external state lacks calibrated navigation chrome or Reload"
grep -q 'external-url.status' "$controller" &&
    grep -q 'external-url.destination' "$controller" &&
    grep -q 'external-url.retry' "$controller" ||
    fail "native external state lacks stable accessibility identifiers"

if grep -Eq 'UIWebView|CydiaWebViewController|CyteWebView|WKWebView|WebFrame|WebScriptObject' \
        "$header" "$controller" "$policy"; then
    fail "external URL boundary embeds or depends on a WebView"
fi

grep -Fq '[[ExternalURLController alloc]' "$application" &&
    grep -q 'initWithRouteDescriptor:descriptor' "$application" ||
    fail "typed external route does not construct the native coordinator"
if grep -q 'CydiaWebViewController' "$application"; then
    fail "application external routing still constructs the legacy browser"
fi
grep -q 'CydiaExternalURLRouteURL(url)' "$root/Cydia/HomeController.mm" ||
    fail "Home external links bypass the shared typed route"
grep -q 'CydiaExternalURLRouteURL(destination)' "$root/Cydia/PackageControllers.mm" ||
    fail "package external links bypass the shared typed route"
for retired in \
        Cydia/CydiaWebViewController.h Cydia/CydiaWebViewController.mm \
        CyteKit/WebViewController.h CyteKit/WebViewController.mm \
        CyteKit/WebViewController+Navigation.mm \
        CyteKit/WebViewController+WebDelegate.mm; do
    test ! -e "$root/$retired" ||
        fail "retired generic web controller remains: $retired"
done
grep -q 'libs += -framework SafariServices' "$root/mk/toolchain.mk" ||
    fail "Safari Services is not linked by the Make build"

echo "[verify-external-url-controller][ ok ] native Safari/system routing contract"
