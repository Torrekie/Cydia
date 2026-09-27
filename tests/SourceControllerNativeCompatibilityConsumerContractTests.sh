#!/bin/sh
# Copyright (C) 2026 Torrekie
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
header=$root/Cydia/SourceControllers.h
source=$root/Cydia/SourceControllers.mm

fail() {
    echo "[verify-source-controller-native-consumer][FAIL] $*" >&2
    exit 1
}

command -v rg >/dev/null 2>&1 || fail "rg is required"
for file in "$header" "$source"; do
    test -f "$file" || fail "missing source controller source: $file"
done

for token in \
        'LegacyUICompatibilityNativeCaller.h' \
        'CydiaLegacyUICompatibilityNativeSession' \
        'SourcesControllerApplicationDelegate' \
        'legacyCompatibilitySession_' \
        'invalidateLegacyCompatibilitySession' \
        'sourceIsCanonical:' \
        'bindLegacyCompatibilitySessionForSource:' \
        'object_getClass(source) == [Source class]' \
        '[database_ sources]' \
        'candidate == source' \
        'legacyUICompatibilitySessionForSource:' \
        'respondsToSelector:@selector(' \
        'presenter:nil' \
        'invokeScope:@"Source"' \
        'memberKind:CydiaLegacyBridgeMemberKindAttribute' \
        'memberName:@"key"' \
        'legacyCompatibilitySession_ = session' \
        '[session target] != source' \
        '[session isActive]' \
        'tableView:(UITableView *)tableView didSelectRowAtIndexPath:' \
        '[self bindLegacyCompatibilitySessionForSource:source]' \
        'NSString *boundSourceKey' \
        'sourceToRebind'; do
    rg -Fq "$token" "$header" "$source" ||
        fail "missing source controller consumer contract: $token"
done

if rg -n '\[\[(Source|Package) alloc\]|newSourceWithHandle|initWithHandle:' "$source" >/dev/null; then
    fail "source controller synthesizes model targets"
fi

if rg -n 'UIWebView|WebScript|WebFrame|WAKView|WebCore|applicationCache' "$source" >/dev/null; then
    fail "source controller consumer depends on a retired web/private UI surface"
fi

canonical_start=$(rg -n '^[-] \(BOOL\) sourceIsCanonical:' "$source" | cut -d: -f1 | head -n 1)
canonical_end=$(awk -v start="$canonical_start" 'NR > start && /^[-] / { print NR; exit }' "$source")
test -n "$canonical_start" && test -n "$canonical_end" || fail "cannot isolate canonical source check"
canonical_method=$(sed -n "${canonical_start},$((canonical_end - 1))p" "$source")
printf '%s\n' "$canonical_method" | rg -Fq '@synchronized (database_)' || fail "canonical source check is not synchronized"
printf '%s\n' "$canonical_method" | rg -Fq '[database_ sources]' || fail "canonical source check does not inspect the database array"
printf '%s\n' "$canonical_method" | rg -Fq 'object_getClass(source) == [Source class]' || fail "canonical source check does not require exact Source class"
printf '%s\n' "$canonical_method" | rg -Fq 'candidate == source' || fail "canonical source check does not require pointer identity"
printf '%s\n' "$canonical_method" | rg -Fq '[database_ era] != era_' || fail "canonical source check does not reject an era change"

bind_start=$(rg -n '^[-] \(void\) bindLegacyCompatibilitySessionForSource:' "$source" | cut -d: -f1 | head -n 1)
bind_end=$(awk -v start="$bind_start" 'NR > start && /^[-] / { print NR; exit }' "$source")
test -n "$bind_start" && test -n "$bind_end" || fail "cannot isolate source session binder"
bind_method=$(sed -n "${bind_start},$((bind_end - 1))p" "$source")
test "$(printf '%s\n' "$bind_method" | rg -F -c 'memberName:@"key"')" -eq 1 || fail "source binder does not perform exactly one typed key read"
printf '%s\n' "$bind_method" | rg -Fq 'delegate == nil' || fail "source binder lacks missing delegate guard"
printf '%s\n' "$bind_method" | rg -Fq '![delegate respondsToSelector:@selector(' || fail "source binder lacks non-Cydia delegate guard"
printf '%s\n' "$bind_method" | rg -Fq '[self sourceIsCanonical:source]' || fail "source binder lacks canonical target guard"
printf '%s\n' "$bind_method" | rg -Fq '[legacyCompatibilitySession_ target] == source' || fail "source binder lacks target identity binding"
printf '%s\n' "$bind_method" | rg -Fq '[session target] != source' || fail "source binder lacks returned target identity check"
printf '%s\n' "$bind_method" | rg -Fq '[session isActive]' || fail "source binder lacks active-session check"
printf '%s\n' "$bind_method" | rg -Fq '[self invalidateLegacyCompatibilitySession]' || fail "source binder lacks stale-session invalidation"
if printf '%s\n' "$bind_method" | rg -n 'addSource:|addTrivialSource:|CydiaRemoveSource|syncData|_saveConfig|installPackage|removePackage|clearPackage' >/dev/null; then
    fail "source binder contains a mutation path"
fi

select_start=$(rg -n '^[-] \(void\) tableView:\(UITableView \*\)tableView didSelectRowAtIndexPath:' "$source" | cut -d: -f1 | head -n 1)
select_end=$(awk -v start="$select_start" 'NR > start && /^[-] / { print NR; exit }' "$source")
test -n "$select_start" && test -n "$select_end" || fail "cannot isolate source selection handler"
select_method=$(sed -n "${select_start},$((select_end - 1))p" "$source")
printf '%s\n' "$select_method" | rg -Fq '[self bindLegacyCompatibilitySessionForSource:source]' || fail "selection does not bind the selected source"
select_bind_line=$(printf '%s\n' "$select_method" | rg -n '\[self bindLegacyCompatibilitySessionForSource:source\]' | cut -d: -f1 | head -n 1)
select_push_line=$(printf '%s\n' "$select_method" | rg -n 'pushViewController:controller' | cut -d: -f1 | head -n 1)
test -n "$select_bind_line" && test -n "$select_push_line" && test "$select_bind_line" -lt "$select_push_line" || fail "selection does not bind before push"

reload_start=$(rg -n '^[-] \(void\) reloadData \{' "$source" | tail -n 1 | cut -d: -f1)
reload_end=$(awk -v start="$reload_start" 'NR > start && /^[-] / { print NR; exit }' "$source")
test -n "$reload_start" && test -n "$reload_end" || fail "cannot isolate source reload lifecycle"
reload_method=$(sed -n "${reload_start},$((reload_end - 1))p" "$source")
printf '%s\n' "$reload_method" | rg -Fq 'NSString *boundSourceKey' || fail "reload does not preserve bound source identity"
printf '%s\n' "$reload_method" | rg -Fq '[self invalidateLegacyCompatibilitySession]' || fail "reload does not invalidate before refresh"
printf '%s\n' "$reload_method" | rg -Fq 'sourceToRebind' || fail "reload does not resolve a canonical rebind target"
printf '%s\n' "$reload_method" | rg -Fq '[self bindLegacyCompatibilitySessionForSource:sourceToRebind]' || fail "reload does not rebind or clear a disappeared source"
reload_invalidate_line=$(printf '%s\n' "$reload_method" | rg -n '\[self invalidateLegacyCompatibilitySession\]' | cut -d: -f1 | head -n 1)
reload_super_line=$(printf '%s\n' "$reload_method" | rg -n '\[super reloadData\]' | cut -d: -f1 | head -n 1)
test -n "$reload_invalidate_line" && test -n "$reload_super_line" && test "$reload_invalidate_line" -lt "$reload_super_line" || fail "reload invalidation is not before superclass refresh"

dealloc_start=$(rg -n '^[-] \(void\) dealloc \{' "$source" | head -n 1 | cut -d: -f1)
dealloc_end=$(awk -v start="$dealloc_start" 'NR > start && /^[-] / { print NR; exit }' "$source")
test -n "$dealloc_start" && test -n "$dealloc_end" || fail "cannot isolate source controller dealloc"
dealloc_method=$(sed -n "${dealloc_start},$((dealloc_end - 1))p" "$source")
printf '%s\n' "$dealloc_method" | rg -Fq '[self invalidateLegacyCompatibilitySession]' || fail "dealloc does not invalidate source session"

if rg -n 'viewWillDisappear|viewDidDisappear' "$source" | rg 'LegacyCompatibility|legacyCompatibility' >/dev/null; then
    fail "source session is invalidated during ordinary view disappearance"
fi
if rg -n 'releaseSubviews' "$source" | rg 'LegacyCompatibility|legacyCompatibility' >/dev/null; then
    fail "source session is invalidated during view unloading"
fi

echo "[verify-source-controller-native-consumer][ ok ] canonical Source session read and lifecycle invalidation"
