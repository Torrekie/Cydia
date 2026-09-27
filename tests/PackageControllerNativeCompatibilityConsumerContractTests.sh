#!/bin/sh
# Copyright (C) 2026 Torrekie
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
header=$root/Cydia/PackageControllers.h
source=$root/Cydia/PackageControllers.mm

fail() {
    echo "[verify-package-controller-native-consumer][FAIL] $*" >&2
    exit 1
}

command -v rg >/dev/null 2>&1 || fail "rg is required"
for file in "$header" "$source"; do
    test -f "$file" || fail "missing package controller source: $file"
done

for token in \
        'CydiaLegacyUICompatibilityNativeSession' \
        'legacyCompatibilitySession_' \
        'legacyUICompatibilitySessionForPackage:' \
        'bindLegacyCompatibilitySessionForPackage:' \
        'packageWithName:name' \
        'object' \
        'presenter:nil' \
        'invokeScope:@"Package"' \
        'memberKind:CydiaLegacyBridgeMemberKindAttribute' \
        'memberName:@"id"' \
        'legacyCompatibilitySession_ = session' \
        'legacyCompatibilitySession_ invalidate' \
        'respondsToSelector:@selector(' \
        'synchronizeLegacyStateWithPackage:package'; do
    rg -Fq "$token" "$header" "$source" ||
        fail "missing package consumer contract: $token"
done

if rg -n '\[\[(Package|Source) alloc\]|newPackageWithHandle|initWithHandle:' "$source" >/dev/null; then
    fail "package consumer synthesizes model targets"
fi

if rg -n 'UIWebView|WebScript|WebFrame|WAKView|WebCore|applicationCache|addSource:|syncData|_saveConfig' "$source" >/dev/null; then
    fail "package consumer reaches a web/private or configuration mutation path"
fi

bind_start=$(rg -n '^[-] \(void\) bindLegacyCompatibilitySessionForPackage:' "$source" |
    cut -d: -f1 | head -n 1)
bind_end=$(awk -v start="$bind_start" 'NR > start && /^[-] \(/ { print NR; exit }' "$source")
test -n "$bind_start" && test -n "$bind_end" ||
    fail "cannot isolate package session binder"
bind_method=$(sed -n "${bind_start},$((bind_end - 1))p" "$source")
test "$(printf '%s\n' "$bind_method" | rg -F -c 'memberName:@"id"')" -eq 1 ||
    fail "package binder does not perform exactly one typed id read"
printf '%s\n' "$bind_method" | rg -Fq 'if (package == nil || delegate == nil' ||
    fail "package binder does not fail closed for missing target/delegate"
printf '%s\n' "$bind_method" | rg -Fq '![delegate respondsToSelector:@selector(' ||
    fail "package binder does not guard non-Cydia delegates"
printf '%s\n' "$bind_method" | rg -Fq '[legacyCompatibilitySession_ target] == package' ||
    fail "package binder does not retain target identity binding"
printf '%s\n' "$bind_method" | rg -Fq '[session isActive]' ||
    fail "package binder does not require an active session"

reload_line=$(rg -n '^[-] \(void\) reloadData \{' "$source" | head -n 1 | cut -d: -f1)
view_line=$(rg -n '^[-] \(void\)viewDidLoad \{' "$source" | head -n 1 | cut -d: -f1)
bind_lines=$(rg -n '\[self bindLegacyCompatibilitySessionForPackage:' "$source" | wc -l | tr -d ' ')
test -n "$reload_line" && test -n "$view_line" && test "$bind_lines" -ge 2 ||
    fail "package session is not rebound from reload/view lifecycle"
reload_branch=$(awk -v start="$reload_line" 'NR > start && /if \(viewModel != nil\)/ { print NR; exit }' "$source")
reload_bind=$(awk -v start="$reload_line" 'NR > start && /\[self bindLegacyCompatibilitySessionForPackage:package\]/ { print NR; exit }' "$source")
test -n "$reload_branch" && test -n "$reload_bind" && test "$reload_bind" -lt "$reload_branch" ||
    fail "reload does not invalidate a stale session before the nil-model branch"

echo "[verify-package-controller-native-consumer][ ok ] canonical package session read and lifecycle invalidation"
