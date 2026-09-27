#!/bin/sh
# Cydia Refurbished native Home controller contract.
# Copyright (C) 2026 Torrekie
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
controller="$root/Cydia/HomeController.mm"
split="$root/Cydia/HomeSplitDisclosure.mm"
split_header="$root/Cydia/HomeSplitDisclosure.h"
probe="$root/Cydia/HomeControllerProbe.mm"
header="$root/Cydia/HomeController.h"
route="$root/Cydia/Application+Navigation.mm"
localization_test="$root/tests/HomeLocalizationTests.sh"

fail() {
    echo "[verify-home-controller][FAIL] $*" >&2
    exit 1
}

test -f "$controller" || fail "Home controller source is missing"
test -f "$split" || fail "Home split disclosure source is missing"
test -f "$split_header" || fail "Home split disclosure header is missing"
test -f "$probe" || fail "Home controller probe source is missing"
test -f "$header" || fail "Home controller header is missing"
test -f "$root/Cydia/HomeViewModel.h" || fail "Home view model header is missing"
test -f "$root/Cydia/HomeViewModel.mm" || fail "Home view model implementation is missing"
test -x "$localization_test" || fail "Home localization contract is missing"

grep -q '@interface HomeController : CyteViewController' "$header" ||
    fail "Home controller still uses a web-backed superclass"
grep -Fq 'initWithDatabase:(Database *)database' "$header" ||
    fail "Home controller lost its database initializer"
grep -q 'navigationURL' "$controller" ||
    fail "Home controller lost its navigation URL"
grep -q 'UITableViewStyleGrouped' "$controller" ||
    fail "Home controller does not use a grouped native table"
grep -q 'CydiaHomeSplitLinkCell' "$controller" ||
    fail "Home lost its native paired social/discovery controls"
grep -q 'UIStackViewDistributionFillEqually' "$controller" ||
    fail "Home paired controls no longer share the row evenly"
grep -Fq 'CydiaHomeSystemDisclosureAccessory' "$controller" ||
    fail "Home paired controls lost their UIKit disclosure accessory host"
grep -Fq 'UITableViewCellAccessoryDisclosureIndicator' "$split" ||
    fail "Home split disclosure accessory is not supplied by UIKit"
grep -Fq 'accessibilityElementsHidden = YES' "$split" ||
    fail "Home disclosure accessory host entered the accessibility tree"
grep -Fq 'backgroundConfiguration = [UIBackgroundConfiguration clearConfiguration]' \
        "$split" ||
    fail "Home disclosure accessory host can obscure split-row content"
if grep -Eq 'HomeDisclosureImage|UIBezierPath|leftDisclosure_\.tintColor|rightDisclosure_\.tintColor' \
        "$controller" "$split"; then
    fail "Home split disclosures regressed to custom drawing or tinting"
fi
grep -Fq 'CydiaHomeApplySplitButtonInsets' "$controller" ||
    fail "Home split controls do not normalize their directional content margins"
grep -Fq 'UIEdgeInsetsMake(7, 15, 7, 34)' "$split" ||
    fail "Home split controls lost the normal 15pt leading margin"
grep -Fq 'UIEdgeInsetsMake(7, 34, 7, 15)' "$split" ||
    fail "Home split controls lost their mirrored RTL margin"
grep -Fq 'UIEdgeInsetsMake(0, 15, 0, -15)' "$split" ||
    fail "Home split controls lost the regular icon/title spacing"
grep -Fq 'UIEdgeInsetsMake(0, -15, 0, 15)' "$split" ||
    fail "Home split controls lost their mirrored RTL icon/title spacing"
grep -Fq 'preservesSuperviewLayoutMargins = NO' "$split" ||
    fail "Home disclosure hosts inherit an unrelated superview margin"
grep -Fq 'UIEdgeInsetsMake(0, 16, 0, 16)' "$split" ||
    fail "Home disclosure hosts lost the regular cell trailing margin"
grep -Fq 'UIControlContentHorizontalAlignmentLeading' "$controller" ||
    fail "Home split titles do not reserve leading content space in RTL"
for suffix in DisclosureCount DisclosuresDecorative \
        DisclosuresInsideControls DisclosuresAtTrailingEdge \
        DisclosureTintSynchronized DisclosuresSystemOwned \
        ContentLeadingAligned; do
    grep -Fq "split${suffix}" "$probe" ||
        fail "Home probe does not verify split-row ${suffix}"
done
grep -q 'UITableViewCellStyleSubtitle' "$controller" ||
    fail "iPad package recommendations lost their native detail text"
grep -q 'CydiaColorRoleCellBackground' "$controller" ||
    fail "Home rows do not use the native cell surface role"
grep -q 'CydiaColorRoleInstallingBackground' "$controller" ||
    fail "Home Manage Account row lost its familiar green surface"
grep -q 'CydiaColorRoleLabel' "$controller" ||
    fail "Home labels do not use semantic label colors"
grep -Fq 'HomeApplyCellSurface' "$controller" ||
    fail "Home rows do not centralize their native surface refresh"
grep -Fq 'HomeApplyTableSurface' "$controller" ||
    fail "Home tables do not own their grouped background surface"
grep -Fq 'overrideUserInterfaceStyle' "$controller" ||
    fail "Home UIKit surfaces do not receive the resolved interface style"
grep -Fq 'homeAppearanceTraits' "$controller" ||
    fail "Home colors do not follow the attached window appearance"
grep -Fq 'viewIfLoaded.window' "$controller" ||
    fail "Home appearance does not inspect the attached window trait"
grep -Fq 'cell.backgroundView' "$controller" ||
    fail "Home rows do not own the grouped background surface"
grep -Fq 'cell.contentView.backgroundColor' "$controller" ||
    fail "Home rows do not synchronize their content surface"
grep -Fq 'UIBackgroundConfiguration' "$controller" ||
    fail "Home rows do not configure iOS 14 background surfaces"
grep -Fq 'backgroundConfiguration' "$controller" ||
    fail "Home rows do not assign the iOS 14 background configuration"
grep -Fq '@available(iOS 14.0' "$controller" ||
    fail "Home iOS 14 background path is not availability guarded"
grep -Fq 'willDisplayCell' "$controller" ||
    fail "Home rows do not refresh their surface after UIKit display styling"
will_display_body=$(sed -n '/willDisplayCell:/,/^}/p' "$controller")
printf '%s\n' "$will_display_body" | grep -Fq \
    'HomeApplyCellAppearance(cell, [self homeAppearanceTraits]);' ||
    fail "Home display styling bypasses the attached window appearance"
grep -Fq 'HomeProbeCellSurfaceSynchronized' "$probe" ||
    fail "Home probe does not inspect all row surface layers"
grep -Fq 'HomeProbeEffectiveCellColor' "$probe" ||
    fail "Home probe does not inspect the rendered iOS 14 cell surface"
grep -Fq 'cellSurfaceSynchronized' "$probe" ||
    fail "Home probe does not record row surface synchronization"
grep -Fq 'HomeProbeBackgroundConfigurationSynchronized' "$probe" ||
    fail "Home probe does not inspect iOS 14 background configurations"
grep -Fq 'cellBackgroundConfigurationSynchronized' "$probe" ||
    fail "Home probe does not record iOS 14 background configuration state"
grep -q 'CydiaHomeViewModel' "$controller" ||
    fail "Home controller does not render an immutable snapshot"
grep -q 'SCNetworkReachabilityCreateWithName' "$controller" ||
    fail "Home controller lost reachability monitoring"
grep -q 'SCNetworkReachabilityGetFlags' "$controller" ||
    fail "Home controller does not seed initial reachability state"
grep -q 'pageForURL:context:withReferrer:' "$controller" ||
    fail "Home native links bypass the typed route factory"
grep -q 'trustedNativeContext' "$controller" ||
    fail "Home native links lack trusted-native route capability"
grep -q 'openExternalURL:' "$controller" ||
    fail "Home guide links have no external handoff boundary"
grep -q 'UIAlertController' "$controller" ||
    fail "Home About action still relies on deprecated UIAlertView"

if grep -Eq 'CydiaWebViewController|UI_/|dispatchEvent|applicationCache|setURL:' \
        "$header" "$controller"; then
    fail "Home controller retains a remote HTML/WebView dependency"
fi

grep -Fq '[[HomeController alloc] initWithDatabase:database_]' "$route" ||
    fail "Home route factory does not pass the application database"
grep -Fq 'cydia://home' "$controller" ||
    fail "Home canonical URL is missing"

for identifier in \
    cydia.home.social.facebook cydia.home.social.twitter \
    cydia.home.featured cydia.home.themes cydia.home.account \
    cydia.home.help.upgrading cydia.home.help.applications \
    cydia.home.help.sources cydia.home.guide.faq \
    cydia.home.guide.copying cydia.home.guide.openssh \
    cydia.home.guide.password cydia.home.guide.storage \
    cydia.home.developer.resources cydia.home.credits cydia.home.privacy; do
    grep -Fq "$identifier" "$controller" ||
        fail "Home historical action is missing: $identifier"
done

for URL in \
    https://www.saurik.com/ https://www.facebook.com/Cydia \
    https://twitter.com/saurik https://cydia.saurik.com/featured/ \
    https://cydia.saurik.com/themes/ https://cydia.saurik.com/account/ \
    https://cydia.saurik.com/upgrading/ \
    https://cydia.saurik.com/sources.html \
    https://cydia.saurik.com/questions.html \
    https://cydia.saurik.com/copying.html \
    https://cydia.saurik.com/openssh.html \
    https://cydia.saurik.com/password.html \
    https://cydia.saurik.com/storage.html \
    https://cydia.saurik.com/faq/developing.html \
    https://cydia.saurik.com/credits.html \
    https://cydia.saurik.com/policy/privacy/; do
    grep -Fq "$URL" "$controller" ||
        fail "Home historical destination is missing: $URL"
done

grep -Fq 'HomeIPadExtensions' "$controller" ||
    fail "Home lost the native iPad recommendation column"
grep -Fq 'HomeIPadProducts' "$controller" ||
    fail "Home lost the native iPad product column"
grep -Fq 'UIUserInterfaceIdiomPad' "$controller" ||
    fail "Home no longer adapts its hierarchy for iPad"
grep -Fq 'footerText' "$controller" ||
    fail "Home lost its historical system/version/device footer"
grep -Fq 'Machine_' "$controller" ||
    fail "Home footer no longer displays the hardware model"
grep -Fq 'CydiaHomeFooterText(machine, device.systemVersion' "$controller" ||
    fail "Home footer no longer displays the installed Cydia version"
grep -Fq 'Cydia_, language, UniqueID_' "$controller" ||
    fail "Home footer no longer displays the legacy on-device identifier"
if grep -A18 -F -- '- (NSString *) footerText' "$controller" |
        grep -Fq 'CFBundleShortVersionString'; then
    fail "Home footer regressed to the unrelated bundle version"
fi

grep -Fq 'CyteInitialize(' "$root/Cydia/AppearanceProbe.mm" ||
    fail "Home appearance probe does not initialize production platform fields"
grep -Fq 'identifierForVendor' "$root/Cydia/AppearanceProbe.mm" ||
    fail "Home appearance probe does not initialize its simulator identifier fixture"

if grep -Eq 'cydia\.home\.(sources|sections|changes|installed|search)|web\.png|UITableViewCellStyleValue1' \
        "$controller"; then
    fail "Home still exposes the replacement database dashboard"
fi

asset_dir="$root/MobileCydia.app/Home"
test -f "$asset_dir/ASSETS.md" || fail "Home asset provenance is missing"
check_asset() {
    file=$1
    expected=$2
    test -f "$asset_dir/$file" || fail "Home asset is missing: $file"
    actual=$(shasum -a 256 "$asset_dir/$file" | awk '{print $1}')
    test "$actual" = "$expected" || fail "Home asset hash changed: $file"
}
check_asset cydia7.png 485df5d3321c535838175071f5177220f582a5922ee1f9665902657db6453e68
check_asset facebook.png d7ebfd9ec12af05f530d063e05ba45d99b4302a66fa0be00eeadcaf49bfb8602
check_asset twitter.png a676bde1ec6f72c2728a7871bb1d19c55fbad3031e2e051ac91d97a6d52651fb
check_asset featured.png 34ffb699a5d023a7263a2192b365e032bfc9f96c2c3e5b6c551e61c39ccabb15
check_asset themes.png bded7b700e40df5734e77c515b4e1caa6bd5b6a08cf2d478bb1a5714034256b1
check_asset account.png a50dadccaa4aa6e64c4dc350710f3489ec0196661bdaa632adb4488b60e70989

"$localization_test"

echo "[verify-home-controller][ ok ] native legacy Home hierarchy, route, and asset contract"
