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
# Full Cydia presents the destination from its visible page. The isolated
# coordinator probe can still exercise its legacy pushed/status-page path.
external_entry=$(sed -n '/- (BOOL)_openExternalRoute:/,/^- (void) disemulate/p' "$application")
printf '%s\n' "$external_entry" | grep -Fq '[route isAllowed]' &&
    printf '%s\n' "$external_entry" | grep -Fq 'CydiaUIRouteKindExternalOpen' ||
    fail "direct external handoff lacks its typed allowed-route guard"
printf '%s\n' "$external_entry" | grep -Fq 'CydiaExternalPresentationHost([window_ rootViewController])' &&
    printf '%s\n' "$external_entry" | grep -Fq 'openFromViewController:presenter completion:' ||
    fail "external destination is not opened directly from its visible origin"
visible_host=$(sed -n '/static UIViewController \*CydiaExternalPresentationHost(/,/^}/p' "$application")
printf '%s\n' "$visible_host" | grep -Fq 'controller.presentedViewController' &&
    printf '%s\n' "$visible_host" | grep -Fq 'visibleViewController' &&
    printf '%s\n' "$visible_host" | grep -Fq 'UISplitViewController' ||
    fail "visible Support modal or guide detail is excluded from external presentation"
if printf '%s\n' "$external_entry" | grep -Eq 'pushViewController:|setUnselectedViewController:|loadView'; then
    fail "direct external handoff still inserts a loading/navigation page"
fi
factory_entry=$(sed -n '/- (CyteViewController \*) pageForURL:(NSURL \*)url$/,/^- (CyteViewController \*) pageForURL:.*forExternal:/p' "$application")
command_entry=$(sed -n '/- (BOOL) openCydiaURL:.*context:/,/^- (BOOL) openCydiaURL:.*forExternal:/p' "$application")
for entry in "$factory_entry" "$command_entry"; do
    allowed_line=$(printf '%s\n' "$entry" | grep -n -F 'if (![route isAllowed])' | cut -d: -f1)
    open_line=$(printf '%s\n' "$entry" | grep -n -F '[self _openExternalRoute:route]' | cut -d: -f1)
    test -n "$allowed_line" && test -n "$open_line" &&
        test "$allowed_line" -lt "$open_line" ||
        fail "external presentation occurs before typed route authorization"
done
factory_external=$(printf '%s\n' "$factory_entry" | sed -n '/if (\[\[route descriptor\] kind\] == CydiaUIRouteKindExternalOpen)/,/^    }/p')
printf '%s\n' "$factory_external" | grep -Fq '[self _openExternalRoute:route];' &&
    printf '%s\n' "$factory_external" | grep -Fq 'return nil;' ||
    fail "full-app page factory still returns an external loading controller"
grep -Fq 'openFromViewController:' "$header" &&
    grep -Fq '[[self handoffPresenter] presentViewController:controller' "$controller" &&
    grep -Fq '[[self handoffPresenter] presentViewController:alert' "$controller" ||
    fail "direct Safari/confirmation does not use the originating presenter"
grep -Fq '_handoffCompletion = nil;' "$controller" &&
    grep -Fq 'presentationControllerDidDismiss:' "$controller" &&
    grep -Fq 'reportDirectHandoffFailure' "$controller" ||
    fail "direct handoff lacks completion, dismissal or failure cleanup"
printf '%s\n' "$external_entry" | grep -q '\[pending hasPendingOpenRequest\]' &&
    printf '%s\n' "$external_entry" | grep -q 'return \[pending coalescePendingDestinationURL:' ||
    fail "overlapping system handoffs can stack duplicate coordinators"
pending_state=$(sed -n '/- (BOOL)hasPendingOpenRequest/,/^- (BOOL)coalescePendingDestinationURL:/p' "$controller")
printf '%s\n' "$pending_state" | grep -q 'CydiaExternalURLControllerStateReady && !_attempted' &&
    printf '%s\n' "$pending_state" | grep -q 'CydiaExternalURLControllerStateOpening' &&
    printf '%s\n' "$pending_state" | grep -q 'CydiaExternalURLControllerStatePresented' ||
    fail "pending handoff omits the pre-appearance, opening or presented state"
pending_match=$(sed -n '/- (BOOL)coalescePendingDestinationURL:/,/^- (void)presentSafari/p' "$controller")
printf '%s\n' "$pending_match" | grep -Fq '[[_policy destinationURL] isEqual:URL]' &&
    printf '%s\n' "$pending_match" | grep -q 'duplicate-open-coalesced' &&
    printf '%s\n' "$pending_match" | grep -q 'overlapping-open-rejected' ||
    fail "pending handoff does not distinguish an identical delivery from a different destination"
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
