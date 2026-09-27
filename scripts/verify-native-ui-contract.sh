#!/bin/sh
# Copyright (C) 2026 Torrekie
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
baseline="$root/mk/ui-webkit-legacy.txt"
legacy_api="$root/tests/fixtures/ui/legacy-api.tsv"
legacy_properties="$root/tests/fixtures/ui/legacy-properties.tsv"
routes="$root/tests/fixtures/ui/routes.tsv"
legacy_policy="$root/Cydia/LegacyBridgeOperations.def"
legacy_property_policy="$root/Cydia/LegacyBridgeProperties.def"
legacy_ui_signatures="$root/Cydia/LegacyUICompatibilitySignatures.def"
route_dispatch="$root/tests/fixtures/ui/route-dispatch.tsv"
legacy_route_callers="$root/mk/ui-route-legacy-callers.txt"
mode=${1:-all}

tmp_root=${TMPDIR:-/tmp}
work=$(mktemp -d "$tmp_root/cydia-native-ui.XXXXXX")
cleanup() {
    rm -rf -- "$work"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

fail() {
    echo "[verify-native-ui][FAIL] $*" >&2
    exit 1
}

legacy_pattern='UIWebView|CyteWebView|CydiaWebViewController|(^|[^A-Za-z0-9_])WebView([^A-Za-z0-9_]|$)|WebScriptObject|WebFrame|WebDataSource|WebPreferences|WebThread|WebPolicyDecisionListener|WAKView|WAKWindow|UIWebDocumentView|UIWebBrowserView|UIScroller|DOM[A-Za-z0-9_]*|applicationCache|_documentView|isKeyExcludedFromWebScript|isSelectorExcludedFromWebScript|webScriptNameForSelector'
public_webkit_pattern='WK[A-Z][A-Za-z0-9_]*|WebKit/[^>"[:space:]]+|@import[[:space:]]+WebKit'

production_files() {
    find "$root/Cydia" "$root/CyteKit" "$root/Menes" "$root/SDURLCache" -type f \
        \( -name '*.h' -o -name '*.hpp' -o -name '*.m' -o -name '*.mm' \
           -o -name '*.c' -o -name '*.cpp' \) -print
    for relative in MobileCydia.mm Version.mm iPhonePrivate.h Cytore.hpp \
            lookup3.c Sources.h Sources.mm DiskUsage.cpp; do
        test ! -f "$root/$relative" || echo "$root/$relative"
    done
}

verify_policy() {
    test -f "$baseline" || fail "missing legacy WebKit baseline"
    : >"$work/current-webkit.tsv"

    production_files | sort -u |
    while IFS= read -r absolute; do
        relative=${absolute#"$root/"}
        count=$(grep -Eo "$legacy_pattern" "$absolute" 2>/dev/null | wc -l | tr -d ' ')
        if test "$count" -gt 0; then
            printf '%s\t%s\n' "$relative" "$count" >>"$work/current-webkit.tsv"
        fi
    done

    sort -o "$work/current-webkit.tsv" "$work/current-webkit.tsv"

    while IFS="$(printf '\t')" read -r relative maximum; do
        case "$relative" in ''|'#'*) continue;; esac
        test -f "$root/$relative" || fail "legacy baseline path disappeared without review: $relative"
        current=$(awk -F '\t' -v path="$relative" '$1 == path { print $2; exit }' "$work/current-webkit.tsv")
        test -n "$current" || fail "legacy baseline is stale after retiring $relative"
        test "$current" -le "$maximum" ||
            fail "legacy WebKit debt increased in $relative ($current > $maximum)"
    done <"$baseline"

    while IFS="$(printf '\t')" read -r relative count; do
        maximum=$(awk -F '\t' -v path="$relative" '$1 == path { print $2; exit }' "$baseline")
        test -n "$maximum" || fail "new legacy WebKit dependency in $relative"
    done <"$work/current-webkit.tsv"

    test ! -s "$work/current-webkit.tsv" ||
        fail "retired private-WebKit dependency remains in production sources"

    : >"$work/public-webkit.txt"
    production_files | sort -u |
    while IFS= read -r absolute; do
        if grep -Eq "$public_webkit_pattern" "$absolute"; then
            relative=${absolute#"$root/"}
            case "$relative" in
                Cydia/PackageDepictionView.h|Cydia/PackageDepictionView.mm) ;;
                *) fail "public WebKit is allowed only in PackageDepictionView: $relative";;
            esac
            echo "$relative" >>"$work/public-webkit.txt"
        fi
    done

    if grep -Eq 'Wno-deprecated-declarations' "$root/mk/toolchain.mk"; then
        fail "global WebKit-era deprecation suppression remains"
    fi
    if grep -Eq 'install_name_tool.*WebKit|INSTALL_NAME_TOOL.*WebKit|add_rpath.*/System/Library/(Private)?Frameworks' \
            "$root/mk/rules.mk"; then
        fail "private-WebKit install-name or framework rpath rewrite remains"
    fi
    grep -Fq 'libs += -framework WebKit' "$root/mk/toolchain.mk" ||
        fail "public WebKit link for PackageDepictionView is missing"

    echo "[verify-native-ui][ ok ] retired private WebKit is absent; public WebKit is depiction-only"
}

extract_legacy_policy() {
    awk '
        function trim(value) {
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
            return value
        }
        /^CYDIA_LEGACY_BRIDGE_OPERATION\(/ {
            line=$0
            sub(/^CYDIA_LEGACY_BRIDGE_OPERATION\(/, "", line)
            sub(/\)[[:space:]]*$/, "", line)
            count=split(line, field, /,[[:space:]]*/)
            if (count != 5) {
                bad=1
                next
            }
            for (i=1; i <= count; ++i)
                field[i]=trim(field[i])
            gsub(/_/, "-", field[3])
            gsub(/_/, "-", field[4])
            gsub(/_/, "-", field[5])
            print field[1] "\tmethod\t" field[2] "\t" field[3] "\t" field[4] "\t" field[5]
        }
        END { exit bad }
    ' "$legacy_policy"
}

extract_legacy_ui_signatures() {
    awk '
        function trim(value) {
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
            return value
        }
        /^CYDIA_LEGACY_UI_SIGNATURE\(/ {
            line=$0
            sub(/^CYDIA_LEGACY_UI_SIGNATURE\(/, "", line)
            sub(/\)[[:space:]]*$/, "", line)
            count=split(line, field, /,[[:space:]]*/)
            if (count != 9) { bad=1; next }
            for (i=1; i <= count; ++i) field[i]=trim(field[i])
            print field[1] "\tmethod\t" field[2]
        }
        END { exit bad }
    ' "$legacy_ui_signatures"
}

extract_legacy_property_policy() {
    awk '
        function trim(value) {
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
            return value
        }
        /^CYDIA_LEGACY_BRIDGE_PROPERTY\(/ {
            line=$0
            sub(/^CYDIA_LEGACY_BRIDGE_PROPERTY\(/, "", line)
            sub(/\)[[:space:]]*$/, "", line)
            count=split(line, field, /,[[:space:]]*/)
            if (count != 7) {
                bad=1
                next
            }
            for (i=1; i <= count; ++i) {
                field[i]=trim(field[i])
                if (i != 1 && i != 3)
                    gsub(/_/, "-", field[i])
            }
            print field[1] "\t" field[2] "\t" field[3] "\t" field[4] "\t" \
                field[5] "\t" field[6] "\t" field[7]
        }
        END { exit bad }
    ' "$legacy_property_policy"
}

verify_contracts() {
    test -f "$legacy_api" || fail "missing legacy API fixture"
    test -f "$legacy_properties" || fail "missing legacy property fixture"
    test -f "$routes" || fail "missing route fixture"
    test -f "$legacy_policy" || fail "missing typed legacy bridge policy inventory"
    test -f "$legacy_property_policy" || fail "missing typed legacy property policy inventory"
    test -f "$legacy_ui_signatures" || fail "missing per-call compatibility signature inventory"
    if grep -Eq 'UIKit/|WebKit/|WebScriptObject|WebFrame|WKWebView|UIWebView' \
            "$root/Cydia/LegacyBridgePolicy.h" "$root/Cydia/LegacyBridgePolicy.mm" \
            "$root/Cydia/LegacyUICompatibility.h" \
            "$root/Cydia/LegacyUICompatibility.mm"; then
        fail "retained legacy policy and compatibility service must remain Foundation-only"
    fi
    test -f "$route_dispatch" || fail "missing route-dispatch fixture"
    test -f "$legacy_route_callers" || fail "missing transitional route-caller baseline"

    appearance_probe="$root/Cydia/AppearanceProbe.mm"
    if grep -Eq 'CydiaAppearanceProbeWebController|webReady|webAppearanceEvents|Cyte Web Appearance Event|stringByEvaluatingJavaScriptFromString' \
            "$appearance_probe"; then
        fail "ordinary appearance evidence still renders a private-WebKit fixture"
    fi
    grep -Fq '@"nativeSurfaceBackgroundLuminance"' "$appearance_probe" ||
        fail "appearance probe does not measure the native UIKit surface"
    if grep -Eq 'legacyWebProbe|CyteWebViewController|\[_initialize\]' \
            "$appearance_probe"; then
        fail "native appearance routes still initialize private WebKit"
    fi
    grep -Fq 'nativeSurfaceIdentifier' \
            "$root/scripts/verify-appearance-simulator.sh" ||
        fail "appearance verifier does not require the native UIKit surface"

    grep -Fq -- '- (void) system:(NSString *)command;' \
            "$root/Cydia/Application.h" ||
        fail "legacy Cydia system: extension selector is not declared"
    grep -Fq -- '- (void) system:(NSString *)command {' \
            "$root/Cydia/Application+Lifecycle.mm" ||
        fail "legacy Cydia system: extension selector is not implemented"
    grep -Fq '(void) ::system([command UTF8String]);' \
            "$root/Cydia/Application+Lifecycle.mm" ||
        fail "legacy Cydia system: extension selector lost synchronous semantics"
    grep -Fq '_H<NSDictionary> changes_;' \
            "$root/Cydia/ConfirmationController.h" ||
        fail "legacy ConfirmationController changes_ ivar is not declared"
    grep -Fq 'BOOL substrate_;' \
            "$root/Cydia/ConfirmationController.h" ||
        fail "legacy ConfirmationController substrate_ ivar is not declared"
    grep -Fq 'changes_ = LegacyChanges(viewModel);' \
            "$root/Cydia/ConfirmationController.mm" ||
        fail "legacy ConfirmationController changes_ ivar is not populated"
    grep -Fq 'substrate_ = [viewModel requiresSubstrateRestart];' \
            "$root/Cydia/ConfirmationController.mm" ||
        fail "legacy ConfirmationController substrate_ ivar is not populated"
    grep -Fq 'if (substrate_)' \
            "$root/Cydia/ConfirmationController.mm" ||
        fail "native Confirm ignores the extension-mutable substrate_ ivar"

    for retired_stack in \
        Cydia/CydiaWebViewController.h \
        Cydia/CydiaWebViewController.mm \
        Cydia/LegacyBridgeSession.h \
        Cydia/LegacyBridgeSession.mm \
        Cydia/LegacyRequestPolicy.h \
        Cydia/LegacyRequestPolicy.mm \
        Cydia/LegacyRequestSession.h \
        Cydia/LegacyRequestSession.mm \
        Cydia/LegacyUICompatibilityAdapter.h \
        Cydia/LegacyUICompatibilityAdapter.mm \
        Cydia/LegacyUICompatibilityCommandBackend.h \
        Cydia/LegacyUICompatibilityCommandBackend.mm \
        CyteKit/CyteObject.h \
        CyteKit/CyteObject.mm \
        CyteKit/Diversion.h \
        CyteKit/Diversion.mm \
        CyteKit/IOKitCompat.h \
        CyteKit/IndirectDelegate.h \
        CyteKit/IndirectDelegate.mm \
        CyteKit/WebCore/WebCoreThread.h \
        CyteKit/WebFrame+Cydia.h \
        CyteKit/WebFrame+Cydia.mm \
        CyteKit/WebThreadLocked.hpp \
        CyteKit/WebView.h \
        CyteKit/WebView.mm \
        CyteKit/WebViewController+Appearance.mm \
        CyteKit/WebViewController+Navigation.mm \
        CyteKit/WebViewController+WebDelegate.mm \
        CyteKit/WebViewController.h \
        CyteKit/WebViewController.mm \
        CyteKit/WebViewControllerHooks.mm \
        CyteKit/WebViewControllerPrivate.h \
        CyteKit/countByEnumeratingWithState.h \
        CyteKit/countByEnumeratingWithState.mm \
        CyteKit/dispatchEvent.h \
        CyteKit/dispatchEvent.mm \
        tests/LegacyBridgeSessionTests.mm \
        tests/LegacyRequestSessionTests.mm \
        tests/LegacyUICompatibilityAdapterTests.mm
    do
        test ! -e "$root/$retired_stack" ||
            fail "retired legacy web stack remains: $retired_stack"
    done
    for retired_probe in \
        tests/simulator/LegacyRequestRuntimeProbe.h \
        tests/simulator/LegacyRequestRuntimeProbe.mm \
        tests/simulator/LegacyBridgeRuntimeProbe.h \
        tests/simulator/LegacyBridgeRuntimeProbe.mm \
        tests/simulator/LegacyPopupRuntimeProbe.h \
        tests/simulator/LegacyPopupRuntimeProbe.mm \
        scripts/verify-legacy-request-simulator.sh \
        scripts/verify-legacy-bridge-simulator.sh \
        scripts/verify-legacy-popup-simulator.sh \
        scripts/verify-legacy-popup-device.sh
    do
        test ! -e "$root/$retired_probe" ||
            fail "retired private-WebKit runtime probe remains: $retired_probe"
    done
    if grep -ERn \
            'Legacy(Request|Bridge|Popup)RuntimeProbe|verify-legacy-(request|bridge)-simulator|verify-legacy-popup-(simulator|device)|CYDIA_LEGACY_(REQUEST_SIMULATOR|POPUP_DEVICE)_PROBE|doLPD' \
            "$root/makefile" "$root/mk" "$root/Cydia/AppearanceProbe.mm" \
            "$root/MobileCydia.mm" >/dev/null; then
        fail "retired private-WebKit runtime probe wiring was reintroduced"
    fi
    grep -Fq 'CYDIA_APPEARANCE_SIMULATOR_PROBE=1' "$root/mk/toolchain.mk" ||
        fail "native appearance probe lacks its simulator-only compiler flag"

    grep -q 'CydiaUIRestorationState' "$root/MobileCydia.mm" ||
        fail "MobileCydia must validate saved state before indexing it"
    grep -q 'stateWithDictionary:rawState standardStacks:standard' "$root/MobileCydia.mm" ||
        fail "MobileCydia bypasses the whole-state restoration validator"
    grep -q 'CydiaUIBuildRestorationStateDictionary' "$root/Cydia/Application+Lifecycle.mm" ||
        fail "application lifecycle bypasses the typed saved-state writer"
    grep -q 'interfaceState, @"InterfaceState"' "$root/Cydia/UIRestorationState.mm" ||
        fail "saved-state writer does not use value/key ordering"

    if grep -Eq 'AppCacheController|appcache_|CydiaAppCacheLifecycleReloading|/appcache/' \
            "$root/MobileCydia.mm" "$root/Cydia/Application.h" \
            "$root/Cydia/Application+Lifecycle.mm"; then
        fail "retired AppCache controller or hidden preload remains in production"
    fi
    grep -q '\[tabbar_ beginUpdate\]' "$root/Cydia/Application+Lifecycle.mm" ||
        fail "foreground source refresh was lost with AppCache retirement"
    if grep -q 'reloadURLWithCache' "$root/Cydia/Application+Lifecycle.mm"; then
        fail "foreground lifecycle still reloads legacy HTML"
    fi
    test -f "$root/Cydia/HomeViewModel.h" && test -f "$root/Cydia/HomeViewModel.mm" ||
        fail "native Home view model is missing"
    grep -q 'CyteViewController' "$root/Cydia/HomeController.h" ||
        fail "native Home does not use CyteViewController"
    grep -q 'UITableViewStyleGrouped' "$root/Cydia/HomeController.mm" ||
        fail "native Home does not use a grouped UIKit table"
    grep -q 'CydiaHomeSplitLinkCell' "$root/Cydia/HomeController.mm" ||
        fail "native Home lost its paired social/discovery rows"
    grep -q 'cydia.home.help.upgrading' "$root/Cydia/HomeController.mm" ||
        fail "native Home lost the historical help hierarchy"
    grep -q 'cydia.home.guide.openssh' "$root/Cydia/HomeController.mm" ||
        fail "native Home lost the historical guide hierarchy"
    grep -q 'HomeIPadExtensions' "$root/Cydia/HomeController.mm" ||
        fail "native Home lost its iPad companion column"
    grep -q 'Home/cydia7.png' "$root/Cydia/HomeController.mm" ||
        fail "native Home does not use the familiar flat topper"
    grep -q 'pageForURL:context:withReferrer:' "$root/Cydia/HomeController.mm" ||
        fail "native Home bypasses the typed route factory"
    grep -q 'trustedNativeContext' "$root/Cydia/HomeController.mm" ||
        fail "native Home routes lack trusted-native capability"
    grep -q 'SCNetworkReachability' "$root/Cydia/HomeController.mm" ||
        fail "native Home lost reachability state handling"
    if grep -Eq 'CydiaWebViewController|UI_/|dispatchEvent|applicationCache|setURL:' \
            "$root/Cydia/HomeController.h" "$root/Cydia/HomeController.mm"; then
        fail "native Home retains a remote HTML or WebView dependency"
    fi
    if grep -Eq 'cydia\.home\.(sources|sections|changes|installed|search)|UITableViewCellStyleValue1' \
            "$root/Cydia/HomeController.mm"; then
        fail "native Home retains the replacement database dashboard"
    fi
    test -f "$root/Cydia/ErrorViewController.h" &&
        test -f "$root/Cydia/ErrorViewController.mm" &&
        test -f "$root/Cydia/ErrorViewModel.mm" ||
        fail "native error presentation source is missing"
    grep -q '@protocol ErrorViewControllerDelegate' \
            "$root/Cydia/ErrorViewController.h" ||
        fail "native error Retry lacks a typed delegate boundary"
    grep -q '<ErrorViewControllerDelegate>' \
            "$root/tests/simulator/ErrorViewRuntimeProbe.mm" ||
        fail "installed native-error evidence bypasses the typed delegate"
    if grep -Eq 'CydiaWebViewController|CyteWebViewController|WebViewControllerPrivate|loadRequest:|stringByEvaluatingJavaScript' \
            "$root/tests/simulator/ErrorViewRuntimeProbe.mm"; then
        fail "installed native-error evidence still depends on a web controller"
    fi
    if grep -Eq 'UIWebView|WKWebView|WebKit|javascript:' \
            "$root/Cydia/ErrorViewController.mm" \
            "$root/Cydia/ErrorViewModel.mm"; then
        fail "native error presentation contains web rendering"
    fi
    for asset in error.html localize.js menes/menes.js; do
        test ! -e "$root/MobileCydia.app/$asset" ||
            fail "retired bundled error asset remains: $asset"
    done
    test ! -e "$root/CyteKit/WebViewTableViewCell.h" &&
        test ! -e "$root/CyteKit/WebViewTableViewCell.mm" ||
        fail "dead private-WebKit table cell remains"
    test ! -e "$root/CyteKit/webScriptObjectInContext.h" &&
        test ! -e "$root/CyteKit/webScriptObjectInContext.mm" ||
        fail "dead WebScript object-conversion helper remains"
    if grep -Fq 'WebViewTableViewCell' "$root/CyteKit/CyteKit.h"; then
        fail "CyteKit umbrella still exports the dead private-WebKit table cell"
    fi
    if grep -Fq 'webScriptObjectInContext' "$root/CyteKit/CyteKit.h"; then
        fail "CyteKit umbrella still exports the dead WebScript helper"
    fi
    if grep -Fq 'setOfflineWebApplicationCacheEnabled' \
            "$root/iPhonePrivate.h"; then
        fail "production private WebKit still enables HTML5 Application Cache"
    fi
    if grep -Eq '(^|[^A-Za-z0-9_])UI_([^A-Za-z0-9_]|$)|#!/' \
            "$root/Cydia/ChangeControllers.mm" \
            "$root/Cydia/SectionControllers.mm" \
            "$root/Cydia/PackageFeatureControllers.mm"; then
        fail "native list referrers still emit the retired remote HTML UI"
    fi
    test "$(grep -F 'return [self navigationURL];' \
            "$root/Cydia/ChangeControllers.mm" | wc -l | tr -d ' ')" -ge 2 &&
        grep -Fq 'return [self navigationURL];' \
            "$root/Cydia/SectionControllers.mm" &&
        grep -Fq 'return [self navigationURL];' \
            "$root/Cydia/PackageFeatureControllers.mm" ||
        fail "retained referrerURL selectors do not return canonical native routes"
    awk -F '\t' '!/^#/ && NF >= 3 { print $1 "\t" $2 "\t" $3 }' "$legacy_api" |
        sort -u >"$work/fixture-api.tsv"

    extract_legacy_policy | LC_ALL=C sort >"$work/policy-api.tsv" ||
        fail "typed legacy bridge policy inventory is malformed"
    awk -F '\t' '!/^#/ && NF == 6 { print }' "$legacy_api" |
        LC_ALL=C sort -u >"$work/fixture-policy-api.tsv"
    if ! diff -u "$work/fixture-policy-api.tsv" "$work/policy-api.tsv" \
            >"$work/policy-api.diff"; then
        sed -n '1,120p' "$work/policy-api.diff" >&2
        fail "typed legacy bridge policy diverged from the public script inventory"
    fi

    extract_legacy_ui_signatures | LC_ALL=C sort -u >"$work/call-signatures.tsv" ||
        fail "per-call compatibility signature inventory is malformed"
    if ! diff -u "$work/fixture-api.tsv" "$work/call-signatures.tsv" \
            >"$work/call-signatures.diff"; then
        sed -n '1,120p' "$work/call-signatures.diff" >&2
        fail "per-call compatibility signatures do not cover every legacy method"
    fi
    grep -Fq 'for (CydiaLegacyBridgeMember *member in CydiaLegacyBridgeMembers())' \
            "$root/Cydia/LegacyUICompatibility.mm" &&
        grep -Fq 'if ([member kind] != CydiaLegacyBridgeMemberKindMethod)' \
            "$root/Cydia/LegacyUICompatibility.mm" ||
        fail "non-method compatibility members are not derived from the full policy inventory"
    grep -Fq 'CydiaLegacyUIEvaluateCompatibilityInvocation(invocation)' \
            "$root/Cydia/LegacyUICompatibility.mm" ||
        fail "compatibility calls bypass per-call policy and argument validation"
    grep -Fq 'requestNativeConfirmationForInvocation:invocation' \
            "$root/Cydia/LegacyUICompatibility.mm" ||
        fail "typed mutation calls do not use the native-confirmation backend"
    extract_legacy_property_policy | LC_ALL=C sort >"$work/policy-properties.tsv" ||
        fail "typed legacy property policy inventory is malformed"
    cut -f 1-4 "$work/policy-properties.tsv" >"$work/policy-property-identities.tsv"
    awk -F '\t' '!/^#/ && NF == 4 { print }' "$legacy_properties" |
        LC_ALL=C sort -u >"$work/fixture-property-identities.tsv"
    if ! diff -u "$work/fixture-property-identities.tsv" \
            "$work/policy-property-identities.tsv" >"$work/policy-properties.diff"; then
        sed -n '1,160p' "$work/policy-properties.diff" >&2
        fail "typed legacy property policy diverged from the public property inventory"
    fi
    awk -F '\t' '
        NF != 7 { bad=1; next }
        {
            key=$1 SUBSEP $2 SUBSEP $3
            if (seen[key]++) bad=1
            if ($5 != "sensitive" && $5 != "global-read" &&
                $5 != "package-read" && $5 != "source-read" &&
                $5 != "chrome" && $5 != "retired") bad=1
            if ($6 != "allow" && $6 != "retired") bad=1
            if ($7 != "deny" && $7 != "current-package" &&
                $7 != "current-source" && $7 != "retired") bad=1
            if ($7 == "current-package" && $5 != "package-read") bad=1
            if ($7 == "current-source" && $5 != "source-read") bad=1
            if (($5 == "sensitive" || $5 == "global-read" || $5 == "chrome") &&
                $7 != "deny") bad=1
            if ($5 == "retired" && ($6 != "retired" || $7 != "retired")) bad=1
            if ($5 != "retired" && ($6 == "retired" || $7 == "retired")) bad=1
            if ($2 == "key-policy" && ($5 != "retired" || $3 != "*")) bad=1
            if (($1 == "CydiaProgressData" || $1 == "CydiaProgressEvent") &&
                $5 != "retired") bad=1
        }
        END { exit bad }
    ' "$work/policy-properties.tsv" ||
        fail "typed legacy property policy has unsafe or duplicate rows"

    awk -F '\t' '
        /^#/ || NF == 0 { next }
        NF != 6 { bad=1; next }
        {
            key=$1 SUBSEP $2 SUBSEP $3
            if (seen[key]++) bad=1
            if ($2 != "method" && $2 != "attribute") bad=1
            if ($4 != "sensitive" && $4 != "mutation" &&
                $4 != "global-read" && $4 != "package-read" &&
                $4 != "source-read" && $4 != "session" &&
                $4 != "chrome" && $4 != "clipboard" &&
                $4 != "rendering") bad=1
            if ($5 != "allow" && $5 != "gesture" && $5 != "deny") bad=1
            if ($6 != "allow" && $6 != "deny" &&
                $6 != "current-package" && $6 != "current-source" &&
                $6 != "allowlisted") bad=1
            if ($5 == "deny") bad=1
            if ($5 == "gesture" && $4 != "clipboard") bad=1
            if ($4 == "clipboard" && $5 != "gesture") bad=1
            if ($6 == "allow" && $4 != "rendering") bad=1
            if ($6 == "allowlisted" && $4 != "rendering") bad=1
            if ($6 == "current-package" && $4 != "package-read") bad=1
            if ($6 == "current-source" && $4 != "source-read") bad=1
            if ($6 != "deny" && $4 != "rendering" &&
                $4 != "package-read" && $4 != "source-read") bad=1
        }
        END { exit bad }
    ' "$legacy_api" || fail "legacy API fixture has invalid or duplicate policy rows"

    properties_header=$(sed -n '1p' "$legacy_properties")
    expected_properties_header=$(printf '# scope\tmember-kind\tjavascript-name\tsource-form')
    test "$properties_header" = "$expected_properties_header" ||
        fail "legacy property fixture header changed"

    awk -F '\t' '
        /^#/ || NF == 0 { next }
        NF != 4 { bad=1; next }
        {
            key=$1 SUBSEP $2 SUBSEP $3
            if (seen[key]++) bad=1
            if ($2 != "attribute" && $2 != "global" &&
                $2 != "field" && $2 != "default-call" &&
                $2 != "dynamic-method" && $2 != "key-policy") bad=1
            if ($4 != "attribute-keys" && $4 != "window-injection" &&
                $4 != "confirmation-schema" && $4 != "invoke-default" &&
                $4 != "undefined-method" && $4 != "wildcard-unexcluded") bad=1
        }
        END { exit bad }
    ' "$legacy_properties" ||
        fail "legacy property fixture has invalid or duplicate rows"

    header=$(sed -n '1p' "$routes")
    expected_header=$(printf '# route\tkind\ttrusted-native\texternal-url\ttrusted-legacy\trepository-depiction\tuntrusted-web-popup')
    test "$header" = "$expected_header" ||
        fail "route fixture header changed"
    awk -F '\t' '
        /^#/ || NF == 0 { next }
        NF != 7 { bad=1; next }
        {
            if (seen[$1]++) bad=1
            if ($3 != "allow") bad=1
            if ($4 != "allow" && $4 != "deny" && $4 != "confirm") bad=1
            if ($5 != "allow" && $5 != "deny" && $5 != "temporary") bad=1
            if ($6 != "allow" && $6 != "deny" && $6 != "gesture") bad=1
            if ($7 != "allow" && $7 != "deny" && $7 != "gesture") bad=1
        }
        END { exit bad }
    ' "$routes" || fail "route fixture has invalid or duplicate policy rows"
    for required in home sources source-add source sections section search changes installed package package-settings package-files launch external-open; do
        awk -F '\t' -v kind="$required" '!/^#/ && $2 == kind { found=1 } END { exit !found }' "$routes" ||
            fail "route fixture does not cover $required"
    done

    dispatch_header=$(sed -n '1p' "$route_dispatch")
    expected_dispatch_header=$(printf '# route\tcaller\tsource-known\toutcome\tpolicy-enforced\tshadow-denied\tkind\trequired-source\texternal-url\trequires-confirmation')
    test "$dispatch_header" = "$expected_dispatch_header" ||
        fail "route-dispatch fixture header changed"

    : >"$work/current-route-callers.tsv"
    production_files | sort -u |
    while IFS= read -r absolute; do
        count=$(grep -Eo 'forExternal:' "$absolute" 2>/dev/null | wc -l | tr -d ' ')
        if test "$count" -gt 0; then
            relative=${absolute#"$root/"}
            printf '%s\t%s\n' "$relative" "$count" >>"$work/current-route-callers.tsv"
        fi
    done
    sort -o "$work/current-route-callers.tsv" "$work/current-route-callers.tsv"

    while IFS="$(printf '\t')" read -r relative count; do
        maximum=$(awk -F '\t' -v path="$relative" '$1 == path { print $2; exit }' "$legacy_route_callers")
        test -n "$maximum" || fail "new transitional forExternal selector in $relative"
        test "$count" -le "$maximum" ||
            fail "transitional forExternal selector count grew in $relative ($count > $maximum)"
    done <"$work/current-route-callers.tsv"

    application_navigation="$root/Cydia/Application+Navigation.mm"
    grep -q 'CydiaUIDispatchRouteURL' "$application_navigation" ||
        fail "application navigation bypasses the typed route dispatcher"
    grep -Fq 'controller = [[ExternalURLController alloc]' "$application_navigation" &&
        grep -q 'initWithRouteDescriptor:descriptor' "$application_navigation" ||
        fail "external route does not use the native typed coordinator"
    if grep -q 'CydiaWebViewController' "$application_navigation"; then
        fail "application external route still depends on the legacy browser"
    fi
    grep -q 'if (!\[route isAllowed\])' "$application_navigation" ||
        fail "application navigation no longer honors dispatch outcomes"
    grep -q '_pageForRoute:route' "$application_navigation" ||
        fail "allowed typed routes no longer reach the descriptor factory"
    grep -q 'CydiaUIRouteDispositionNativeCommand' "$application_navigation" ||
        fail "handled native command routes are not distinguished from nil controllers"
    grep -q 'return \[\[route decision\] disposition\] ==' "$application_navigation" ||
        fail "command route success is still inferred from a controller result"
    grep -q 'const BOOL policyEnforced(YES);' "$root/Cydia/UIRouteDispatch.mm" ||
        fail "typed web routes are no longer enforced"
    if grep -q 'CallerUsesEnforcedPolicy' "$root/Cydia/UIRouteDispatch.mm"; then
        fail "route dispatcher reintroduced caller-specific shadow mode"
    fi
    grep -q '\[decision requiresConfirmation\]' "$application_navigation" ||
        fail "external source-add no longer consumes the confirmation decision"
    if grep -Eq 'componentsSeparatedByString|stringByReplacingPercentEscapes' "$application_navigation"; then
        fail "application navigation reintroduced duplicate URL string parsing"
    fi

    echo "[verify-native-ui][ ok ] route policy, typed dispatch, and legacy inventories are explicit"
}

case "$mode" in
    all)
        verify_policy
        verify_contracts
        ;;
    policy) verify_policy;;
    contracts) verify_contracts;;
    *) fail "unknown mode: $mode";;
esac
