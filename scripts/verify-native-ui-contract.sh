#!/bin/sh
# Copyright (C) 2026 Torrekie
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
baseline="$root/mk/ui-webkit-legacy.txt"
legacy_api="$root/tests/fixtures/ui/legacy-api.tsv"
legacy_properties="$root/tests/fixtures/ui/legacy-properties.tsv"
routes="$root/tests/fixtures/ui/routes.tsv"
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

legacy_pattern='UIWebView|CyteWebView|CydiaWebViewController|(^|[^A-Za-z0-9_])WebView([^A-Za-z0-9_]|$)|WebScriptObject|WebFrame|WebDataSource|WebPreferences|WebThread|WebPolicyDecisionListener|WAKView|WAKWindow|UIWebDocumentView|UIWebBrowserView|UIScroller|DOM[A-Za-z0-9_]*|applicationCache|_documentView'
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

    echo "[verify-native-ui][ ok ] legacy WebKit debt cannot grow"
}

extract_methods() {
    awk '
        /^@implementation[[:space:]]+/ {
            scope=$2
            sub(/\(.*/, "", scope)
        }
        /^[+][[:space:]]*\(NSString[[:space:]]*\*\)[[:space:]]*webScriptNameForSelector/ {
            methods=1
            next
        }
        methods && /isSelectorExcludedFromWebScript/ { methods=0 }
        methods && /return[[:space:]]+@"/ {
            name=$0
            sub(/^.*@"/, "", name)
            sub(/".*$/, "", name)
            print scope "\tmethod\t" name
        }
    ' "$root/Cydia/CydiaWebViewController.mm" \
      "$root/CyteKit/CyteObject.mm" \
      "$root/Cydia/Package.mm" \
      "$root/Cydia/Source.mm"
}

extract_attributes() {
    awk '
        function emit_attributes(line, start, stop, name) {
            while ((start=index(line, "@\"")) != 0) {
                line=substr(line, start + 2)
                stop=index(line, "\"")
                if (stop == 0) return
                name=substr(line, 1, stop - 1)
                print scope "\tattribute\t" name "\tattribute-keys"
                line=substr(line, stop + 1)
            }
        }
        /^@implementation[[:space:]]+/ {
            scope=$2
            sub(/\(.*/, "", scope)
        }
        /^[+][[:space:]]*\(NSArray[[:space:]]*\*\)[[:space:]]*_attributeKeys/ {
            attributes=1
            next
        }
        /^-[[:space:]]*\(NSArray[[:space:]]*\*\)[[:space:]]*attributeKeys/ {
            if (scope == "CyteObject" || scope == "CydiaObject")
                attributes=1
            next
        }
        attributes && /@"/ {
            emit_attributes($0)
        }
        attributes && /nil\]/ { attributes=0 }
    ' "$root/CyteKit/CyteObject.mm" \
      "$root/Cydia/CydiaWebViewController.mm" \
      "$root/Cydia/Package.mm" "$root/Cydia/Source.mm" \
      "$root/Cydia/Relations.mm" "$root/Cydia/MIMEAddress.mm" \
      "$root/Cydia/ProgressData.mm" "$root/Cydia/ProgressEvent.mm"
}

extract_window_globals() {
    awk '
        function emit_globals(line, marker, start, stop, name) {
            marker="forKey:@\""
            while ((start=index(line, marker)) != 0) {
                line=substr(line, start + length(marker))
                stop=index(line, "\"")
                if (stop == 0) return
                name=substr(line, 1, stop - 1)
                print "Window\tglobal\t" name "\twindow-injection"
                line=substr(line, stop + 1)
            }
        }
        /forKey:@"/ {
            emit_globals($0)
        }
    ' "$root/Cydia/CydiaWebViewController.mm" \
      "$root/Cydia/ConfirmationController.mm" \
      "$root/Cydia/ProgressController.mm"
}

extract_confirmation_schema() {
    awk '
        function emit_schema_keys(line, stop, name) {
            while (match(line, /,[[:space:]]*@"/)) {
                line=substr(line, RSTART + RLENGTH)
                stop=index(line, "\"")
                if (stop == 0) return
                name=substr(line, 1, stop - 1)
                print scope "\tfield\t" name "\tconfirmation-schema"
                line=substr(line, stop + 1)
            }
        }
        /\[window setValue:\[\[NSDictionary dictionaryWithObjectsAndKeys:/ {
            scope="ConfirmationRoot"
        }
        /NSDictionary \*version\(.*\[NSDictionary dictionaryWithObjectsAndKeys:/ {
            scope="ConfirmationVersion"
        }
        /\[clauses addObject:\[NSDictionary dictionaryWithObjectsAndKeys:/ {
            scope="ConfirmationClause"
        }
        /\[reasons addObject:\[NSDictionary dictionaryWithObjectsAndKeys:/ {
            scope="ConfirmationReason"
        }
        /\[issues_ addObject:\[NSDictionary dictionaryWithObjectsAndKeys:/ {
            scope="ConfirmationIssue"
        }
        /changes_ = \[NSDictionary dictionaryWithObjectsAndKeys:/ {
            scope="ConfirmationChanges"
        }
        /sizes_ = \[NSDictionary dictionaryWithObjectsAndKeys:/ {
            scope="ConfirmationSizes"
        }
        scope != "" && /,[[:space:]]*@"/ {
            emit_schema_keys($0)
        }
        scope != "" && /nil\]/ { scope="" }
    ' "$root/Cydia/ConfirmationController.mm"
}

extract_misc_properties() {
    awk '
        function emit_dynamic(line, marker, start, stop, name) {
            marker="isEqualToString:@\""
            while ((start=index(line, marker)) != 0) {
                line=substr(line, start + length(marker))
                stop=index(line, "\"")
                if (stop == 0) return
                name=substr(line, 1, stop - 1)
                print "NSDictionary\tdynamic-method\t" name "\tundefined-method"
                line=substr(line, stop + 1)
            }
        }
        /^@implementation NSDictionary \(Cydia\)/ { dictionary=1 }
        dictionary && /isEqualToString:@"/ {
            emit_dynamic($0)
        }
        dictionary && /@end/ { dictionary=0 }

        /^@implementation CyteObject/ { cyte=1 }
        cyte && /^\+[[:space:]]*\(BOOL\)[[:space:]]*isKeyExcludedFromWebScript/ {
            keypolicy=1
        }
        keypolicy && /return false;/ {
            print "CyteObject\tkey-policy\t*\twildcard-unexcluded"
            keypolicy=0
        }
        cyte && /@end/ { cyte=0; keypolicy=0 }
    ' "$root/CyteKit/CyteObject.mm"

    if grep -q 'invokeDefaultMethodWithArguments:' \
            "$root/Cydia/ConfirmationController.mm"; then
        printf 'ConfirmationController\tdefault-call\tqueue\tinvoke-default\n'
    fi
}

extract_properties() {
    extract_attributes
    extract_window_globals
    extract_confirmation_schema
    extract_misc_properties
}

verify_contracts() {
    test -f "$legacy_api" || fail "missing legacy API fixture"
    test -f "$legacy_properties" || fail "missing legacy property fixture"
    test -f "$routes" || fail "missing route fixture"

    extract_methods | sort -u >"$work/source-api.tsv"
    awk -F '\t' '!/^#/ && NF >= 3 { print $1 "\t" $2 "\t" $3 }' "$legacy_api" |
        sort -u >"$work/fixture-api.tsv"
    if ! diff -u "$work/fixture-api.tsv" "$work/source-api.tsv" >"$work/api.diff"; then
        sed -n '1,120p' "$work/api.diff" >&2
        fail "legacy script method inventory changed"
    fi

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
        }
        END { exit bad }
    ' "$legacy_api" || fail "legacy API fixture has invalid or duplicate policy rows"

    properties_header=$(sed -n '1p' "$legacy_properties")
    expected_properties_header=$(printf '# scope\tmember-kind\tjavascript-name\tsource-form')
    test "$properties_header" = "$expected_properties_header" ||
        fail "legacy property fixture header changed"

    extract_properties >"$work/source-properties.raw"
    awk -F '\t' '
        NF != 4 { bad=1; next }
        { key=$1 SUBSEP $2 SUBSEP $3; if (seen[key]++) bad=1 }
        END { exit bad }
    ' "$work/source-properties.raw" ||
        fail "source exposes duplicate or malformed legacy property rows"
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

    awk -F '\t' '!/^#/ && NF == 4 { print }' "$legacy_properties" >"$work/fixture-properties.raw"
    LC_ALL=C sort "$work/source-properties.raw" >"$work/source-properties.tsv"
    LC_ALL=C sort "$work/fixture-properties.raw" >"$work/fixture-properties.tsv"
    if ! diff -u "$work/fixture-properties.tsv" "$work/source-properties.tsv" \
            >"$work/properties.diff"; then
        sed -n '1,160p' "$work/properties.diff" >&2
        fail "legacy script property/schema inventory changed"
    fi

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

    echo "[verify-native-ui][ ok ] route policy and legacy method/property/schema inventories are explicit"
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
