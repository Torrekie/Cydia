#!/bin/sh
# Copyright (C) 2026 Torrekie
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
header=$root/Cydia/PackageDepictionView.h
source=$root/Cydia/PackageDepictionView.mm
facade_header=$root/Cydia/PackageDepictionJavaScriptFacade.h
facade_source=$root/Cydia/PackageDepictionJavaScriptFacade.mm
policy=$root/Cydia/PackageDepictionPolicy.mm
cyte_header=$root/CyteKit/extern.h
cyte_source=$root/CyteKit/extern.mm

fail() {
    echo "[verify-package-depiction-view][FAIL] $*" >&2
    exit 1
}

for token in \
        '#import <WebKit/WebKit.h>' \
        'PackageDepictionView : UIView' \
        'WKWebViewConfiguration' \
        'CydiaPackageDepictionURLSchemeHandler' \
        'WKURLSchemeHandler' \
        'CydiaPackageDepictionMaximumResourceTasks = 128' \
        'setURLSchemeHandler:_resourceSchemeHandler' \
        'forURLScheme:@"cydia"' \
        'CydiaURLResourcePathForURL(URL)' \
        'CydiaResolveURLResourcePath(path, &data)' \
        'MIMEType:@"image/png"' \
        'nonPersistentDataStore' \
        'configuration.applicationNameForUserAgent' \
        'CyteApplicationNameForUserAgent()' \
        'self.accessibilityElements = @[_depictionWebView]' \
        'mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeAll' \
        'scrollView.scrollEnabled = NO' \
        'scrollView addObserver:self' \
        'CydiaPackageDepictionMaximumHeight = 100000.0' \
        'CydiaPackageDepictionMaximumHeightRevisions = 128' \
        'CydiaPackageDepictionViewportTolerance = 2.0' \
        'CydiaPackageDepictionHeightScript' \
        'document.documentElement.scrollHeight' \
        'evaluateJavaScript:CydiaPackageDepictionHeightScript' \
        'CydiaPackageDepictionTouchRecognizer' \
        'touchesEnded:' \
        'std::hypot' \
        'UIGestureRecognizerDelegate' \
        'consumeUserTouchForNavigationType' \
        'CydiaPackageDepictionGestureLifetime' \
        'decisionForURL:navigationAction.request.URL' \
        'allowsResponseURL:navigationResponse.response.URL' \
        'NSHTTPURLResponse' \
        'statusCode >= 200' \
        'statusCode < 300' \
        'didRequestURLHandoff' \
        'CydiaPackageDepictionViewStatePathologicalContent'; do
    grep -Fq "$token" "$header" "$source" ||
        fail "missing depiction adapter contract: $token"
done

for token in \
        'CydiaPackageDepictionJavaScriptFacade : NSObject' \
        'WKUserScriptInjectionTimeAtDocumentStart' \
        'forMainFrameOnly:YES' \
        'addScriptMessageHandler:self name:@"cydiaDepictionBridge"' \
        'removeScriptMessageHandlerForName:@"cydiaDepictionBridge"' \
        'removeAllUserScripts' \
        'securityOrigin' \
        '[frame isMainFrame]' \
        'generation' \
        'binding' \
        'allowlistedReachabilityURL'; do
    grep -Fq "$token" "$facade_header" "$facade_source" ||
        fail "missing bounded facade contract: $token"
done

if grep -Eq 'WebScriptObject|UIApplication|openURL:|X-Unique-ID|serial|ecid|installPackages|setMetadataValue' \
        "$facade_header" "$facade_source"; then
    fail "depiction facade exposes a privileged or identity-bearing surface"
fi

probe_method=$(sed -n '/#if TARGET_OS_SIMULATOR/,/^#endif/p' "$source")
printf '%s\n' "$probe_method" | grep -Fq '#if TARGET_OS_SIMULATOR' ||
    fail "resource DOM observation escaped simulator-only compilation"
printf '%s\n' "$probe_method" | grep -Fq "getElementById('cydia-resource')" ||
    fail "resource DOM observation lost the deterministic positive image"
printf '%s\n' "$probe_method" | grep -Fq "getElementById('cydia-resource-rejected')" ||
    fail "resource DOM observation lost the deterministic negative image"
printf '%s\n' "$probe_method" | grep -Fq 'evaluateJavaScript:script' ||
    fail "resource DOM observation does not inspect the installed document"
if printf '%s\n' "$probe_method" | grep -Fq 'script:'; then
    fail "resource DOM observation accepts caller-supplied JavaScript"
fi

grep -Fq '@property(nonatomic, strong) CydiaPackageDepictionURLSchemeHandler *resourceSchemeHandler' \
    "$source" || fail "depiction does not retain its resource scheme handler"
start_method=$(sed -n '/startURLSchemeTask:/,/stopURLSchemeTask:/p' "$source")
printf '%s\n' "$start_method" | grep -Fq \
    '[_activeTasks count] < CydiaPackageDepictionMaximumResourceTasks' ||
    fail "depiction can queue unbounded custom-scheme tasks"
printf '%s\n' "$start_method" | grep -Fq 'NSURLErrorDataLengthExceedsMaximum' ||
    fail "custom-scheme task overflow does not fail explicitly"
active_checks=$(printf '%s\n' "$start_method" | grep -Fc \
    '[_activeTasks containsObject:task]')
[ "$active_checks" -ge 3 ] ||
    fail "scheme handler can deliver callbacks after cancellation"
printf '%s\n' "$start_method" | grep -Fq 'dispatch_async(dispatch_get_main_queue()' ||
    fail "resource lookup is not serialized onto the UIKit main thread"
stop_method=$(sed -n '/stopURLSchemeTask:/,/^}/p' "$source")
printf '%s\n' "$stop_method" | grep -Fq 'PerformOnMainThreadSynchronously' ||
    fail "scheme-task cancellation is not serialized with delivery"
printf '%s\n' "$stop_method" | grep -Fq '[_activeTasks removeObject:task]' ||
    fail "stopped scheme tasks remain eligible for delivery"
if grep -Fq 'Access-Control-Allow-Origin' "$source"; then
    fail "depiction resources became script-readable across origins"
fi

for token in \
        'void CyteSetApplicationNameForUserAgent(NSString *agent)' \
        'NSString *CyteApplicationNameForUserAgent(void)' \
        'CyteSetApplicationNameForUserAgent(agent);'; do
    grep -Fq "$token" "$cyte_header" "$cyte_source" ||
        fail "missing controller-independent user-agent contract: $token"
done

if grep -Eq 'WebViewController|setApplicationNameForUserAgent:' "$cyte_source"; then
    fail "Cyte user-agent bootstrap still depends on the private WebView controller"
fi

touch_handler_line=$(grep -nF '_activationHandler();' "$source" | cut -d: -f1)
touch_end_line=$(grep -nF 'touchesEnded:' "$source" | cut -d: -f1)
[ -n "$touch_handler_line" ] && [ -n "$touch_end_line" ] &&
    [ "$touch_handler_line" -lt "$touch_end_line" ] ||
    fail "touch token is not recorded before touch-end navigation policy"
grep -Fq '[weakSelf invalidatedUserTouch]' "$source" ||
    fail "dragged or cancelled touches do not revoke user activation"

if grep -Eq 'CydiaObject|CyteObject|WebScriptObject|addScriptMessageHandler|WKScriptMessageHandler|X-Cydia|X-Machine|X-Unique-ID|UIApplication|openURL:|SFSafariViewController|CydiaWebViewController|UIWebView|WebFrame|WebDataSource' "$header" "$source"; then
    fail "depiction adapter gained a bridge, identity header, private WebKit, or direct browser/router side effect"
fi

height_evaluations=$(grep -Fc 'evaluateJavaScript:CydiaPackageDepictionHeightScript' "$source")
[ "$height_evaluations" -eq 1 ] ||
    fail "depiction gained an unbounded JavaScript evaluation surface"

grep -Fq 'CydiaPackageDepictionNavigationDispositionHandOff' "$policy" ||
    fail "Foundation policy no longer distinguishes URL handoff"
grep -Fq 'decisionHandler(WKNavigationActionPolicyCancel)' "$source" ||
    fail "rejected or handed-off actions are not cancelled in the island"
grep -Fq 'decisionHandler(WKNavigationResponsePolicyCancel)' "$source" ||
    fail "rejected responses are not cancelled in the island"

echo "[verify-package-depiction-view][ ok ] public depiction-only adapter boundary"
