#!/bin/sh
# Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
controller="$root/Cydia/CopyingFilesGuideController.mm"
renderer="$root/Cydia/HomeGuideController.mm"
fail() { echo "[copying-files][FAIL] $*" >&2; exit 1; }
python3 "$root/tests/CopyingFilesGuideContentTests.py"
for token in UITableViewStyleGrouped UITableViewAutomaticDimension adjustsFontForContentSizeCategory \
    traitCollectionDidChange CydiaColorAppearanceDidChange CydiaColorRoleCellBackground \
    'heightAnchor constraintGreaterThanOrEqualToConstant:44.0' UIAccessibilityTraitButton \
    UIAccessibilityTraitHeader UIAccessibilityTraitStaticText \
    'pageForURL:context:withReferrer:' 'CydiaExternalURLRouteURL' 'CydiaUIRouteKindPackage' \
    'cydia://home/copying-files'; do
    rg -Fq "$token" "$controller" "$renderer" || fail "missing native contract: $token"
done
rg -Fq '@interface CopyingFilesGuideController : HomeGuideController' "$root/Cydia/CopyingFilesGuideController.h" || fail 'copying no longer uses the shared native rich guide'
rg -Fq 'initWithPageIdentifier:@"copying-files" page:page' "$controller" || fail 'bundled copying data is not integrated with the native guide'
rg -Fq 'NSLinkAttributeName' "$renderer" || fail 'inline first-party links lost their native attributed text'
if rg -n 'WKWebView|UIWebView|performSelector:|NSTask|system\(|installPackages|runCommand' "$controller" "$renderer"; then
    fail 'owned content must be UIKit and instructions inert'
fi
rg -Fq 'controller = [[CopyingFilesGuideController alloc] init];' "$root/Cydia/Application+Navigation.mm" || fail 'missing application route'
rg -Fq 'action == HomeActionCopying' "$root/Cydia/HomeController.mm" || fail 'Home action bypasses native route'
echo '[copying-files][ ok ] finite content/native source contract; not runtime UI evidence'
