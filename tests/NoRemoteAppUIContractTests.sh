#!/bin/sh
# Copyright (C) 2026 Torrekie
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

fail() {
    echo "[verify-no-remote-app-ui][FAIL] $*" >&2
    exit 1
}

command -v rg >/dev/null 2>&1 || fail "rg is required"

app_ui_files="
$root/Cydia/Application+Navigation.mm
$root/Cydia/HomeController.h
$root/Cydia/HomeController.mm
$root/Cydia/ConfirmationController.h
$root/Cydia/ConfirmationController.mm
$root/Cydia/ProgressController.h
$root/Cydia/ProgressController.mm
$root/Cydia/PackageControllers.h
$root/Cydia/PackageControllers.mm
$root/Cydia/PackageDetailController.h
$root/Cydia/PackageDetailController.mm
$root/Cydia/ExternalURLController.h
$root/Cydia/ExternalURLController.mm
$root/Cydia/ErrorViewController.h
$root/Cydia/ErrorViewController.mm
$root/Cydia/ChangeControllers.mm
$root/Cydia/SectionControllers.mm
$root/Cydia/PackageFeatureControllers.mm
"

for file in $app_ui_files; do
    test -f "$file" || fail "app-owned UI source is missing: $file"
done

if rg -n 'CydiaWebViewController|CyteWebViewController|UIWebView|WebScriptObject|WebFrame|applicationCache|/appcache/|#!/|(^|[^A-Za-z0-9_])UI_([^A-Za-z0-9_]|$)' \
        $app_ui_files >/dev/null; then
    fail "an app-owned route still depends on the legacy remote/private-WebKit UI"
fi

if rg -n '(^|[^A-Za-z])loadRequest:|(^|[^A-Za-z])setURL:' \
        $app_ui_files >/dev/null; then
    fail "an app-owned controller still starts a web document load"
fi

if rg -n '(^|[^A-Za-z0-9_])UI_([^A-Za-z0-9_]|$)|AppCacheController|/appcache/' \
        "$root/Cydia/AppState.h" "$root/MobileCydia.mm" >/dev/null; then
    fail "application bootstrap retains a remote UI/AppCache base"
fi

if rg -n 'CyteWebViewController|WebPreferences|WebCoreThread|registerURLSchemeAsLocal' \
        "$root/MobileCydia.mm" >/dev/null; then
    fail "application bootstrap still initializes the private WebKit stack"
fi

if rg -n 'CydiaWebViewController[[:space:]]+alloc|CyteWebViewController[[:space:]]+alloc' \
        "$root/Cydia" "$root/CyteKit" "$root/MobileCydia.mm" \
        --glob '*.{h,m,mm,cpp,hpp}' >/dev/null; then
    fail "production source still allocates a generic private-WebKit controller"
fi

webkit_files=$(rg -l 'WebKit/WebKit|WKWebView' \
    "$root/Cydia" "$root/CyteKit" "$root/MobileCydia.mm" \
    --glob '*.{h,m,mm,cpp,hpp}' | sort)
expected_webkit_files=$(printf '%s\n' \
    "$root/Cydia/PackageDepictionView.h" \
    "$root/Cydia/PackageDepictionView.mm" \
    "$root/Cydia/PackageDepictionJavaScriptFacade.h" \
    "$root/Cydia/PackageDepictionJavaScriptFacade.mm" | sort)
test "$webkit_files" = "$expected_webkit_files" ||
    fail "public WebKit escaped the package depiction adapter"

rg -Fq 'controller = [[ExternalURLController alloc]' \
    "$root/Cydia/Application+Navigation.mm" ||
    fail "external routes no longer enter the native external coordinator"
rg -Fq 'CydiaExternalURLRouteURL(url)' "$root/Cydia/HomeController.mm" ||
    fail "Home external actions bypass the typed native URL route"

for asset in error.html localize.js menes/menes.js; do
    test ! -e "$root/MobileCydia.app/$asset" ||
        fail "retired app-owned HTML asset remains: $asset"
done

echo "[verify-no-remote-app-ui][ ok ] every app-owned route is native"
echo "[verify-no-remote-app-ui][ ok ] public WebKit is depiction-only"
