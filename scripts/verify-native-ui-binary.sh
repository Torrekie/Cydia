#!/bin/sh
# Copyright (C) 2026 Torrekie
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

fail() {
    echo "[verify-native-ui-binary][FAIL] $*" >&2
    exit 1
}

if [ "$#" -ne 1 ]; then
    echo "usage: $0 <MobileCydia-binary>" >&2
    exit 2
fi

binary=$1
[ -f "$binary" ] || fail "binary does not exist: $binary"

file_output=$(file -b "$binary")
printf '%s\n' "$file_output" | grep -Eq 'Mach-O 64-bit executable arm64' ||
    fail "binary is not a 64-bit arm64 Mach-O: $file_output"

load_commands=$(otool -l "$binary")
printf '%s\n' "$load_commands" | awk '
    /cmd LC_BUILD_VERSION/ { in_version = 1; next }
    in_version && /platform/ { platform = $2; next }
    in_version && /minos/ { minos = $2; next }
    in_version && /sdk/ { sdk = $2; next }
    END {
        if (platform != 2 || minos != "12.0") exit 1
        printf "platform=%s minos=%s sdk=%s\n", platform, minos, sdk
    }
' >/dev/null || fail "binary does not declare iPhoneOS minimum iOS 12.0"

printf '%s\n' "$load_commands" | grep -F "/System/Library/Frameworks/WebKit.framework/WebKit" >/dev/null ||
    fail "public WebKit framework load is missing"
if printf '%s\n' "$load_commands" | grep -Eq '@rpath/WebKit.framework/WebKit|/System/Library/PrivateFrameworks/WebKit.framework/WebKit'; then
    fail "private or rewritten WebKit install name remains"
fi

for source in undefined defined strings; do
    case "$source" in
        undefined)
            if nm -u "$binary" 2>/dev/null | grep -Eq 'UIWebView|CyteWebView|CydiaWebViewController|WebScriptObject|WebFrame|WebDataSource|WebPreferences|WebThread|WebPolicyDecisionListener|UIWebDocumentView|UIWebBrowserView|WAK(View|Window)|WebCore|DOM[A-Za-z0-9_]*|applicationCache|_documentView'; then
                fail "retired private-WebKit symbol or string remains in $source dump"
            fi
            ;;
        defined)
            if nm -a "$binary" 2>/dev/null | grep -Eq 'UIWebView|CyteWebView|CydiaWebViewController|WebScriptObject|WebFrame|WebDataSource|WebPreferences|WebThread|WebPolicyDecisionListener|UIWebDocumentView|UIWebBrowserView|WAK(View|Window)|WebCore|DOM[A-Za-z0-9_]*|applicationCache|_documentView'; then
                fail "retired private-WebKit symbol or string remains in $source dump"
            fi
            ;;
        strings)
            if strings "$binary" 2>/dev/null | grep -Eq 'UIWebView|CyteWebView|CydiaWebViewController|WebScriptObject|WebFrame|WebDataSource|WebPreferences|WebThread|WebPolicyDecisionListener|UIWebDocumentView|UIWebBrowserView|WAK(View|Window)|WebCore|DOM[A-Za-z0-9_]*|applicationCache|_documentView'; then
                fail "retired private-WebKit symbol or string remains in $source dump"
            fi
            ;;
    esac
done

echo "[verify-native-ui-binary][ ok ] arm64 iOS 12 binary has public depiction-only WebKit linkage and no retired private-WebKit symbols"
