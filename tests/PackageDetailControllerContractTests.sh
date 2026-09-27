#!/bin/sh
# Copyright (C) 2026 Torrekie
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
header=$root/Cydia/PackageDetailController.h
source=$root/Cydia/PackageDetailController.mm
model=$root/Cydia/PackageDetailViewModel.mm
probe=$root/Cydia/PackageDetailControllerProbe.mm
depiction_fixture=$root/tests/simulator/package_depiction_server.py
simulator_verifier=$root/scripts/verify-package-detail-simulator.sh
verify_makefile=$root/mk/verify.mk
appearance=$root/Cydia/AppearanceProbe.mm
navigation=$root/Cydia/Application+Navigation.mm
legacy=$root/Cydia/PackageControllers.mm
legacy_header=$root/Cydia/PackageControllers.h
legacy_icon_loader=$root/Cydia/PackageLegacyIconLoader.mm
legacy_icon_policy=$root/Cydia/PackageLegacyMetadataPolicy.mm
legacy_icon_fixture=$root/tests/fixtures/ui/package-api/choicy.response
assets=$root/MobileCydia.app

fail() {
    echo "[verify-package-detail-controller][FAIL] $*" >&2
    exit 1
}

grep -Fq 'PackageDetailController : CyteViewController' "$header" ||
    fail "package shell is not a native CyteViewController"

if grep -Eq 'CydiaWebViewController|UIWebView|WK[A-Z]|WebScriptObject|WebFrame|JavaScript|(^|[^A-Za-z0-9_])UI_([^A-Za-z0-9_]|$)' "$header" "$source"; then
    fail "package shell contains app-owned browser, script, or remote-UI dependencies"
fi

for token in \
        'UITableViewStyleGrouped' \
        'table.tableHeaderView = _packageHeaderView' \
        'table.tableFooterView = footer' \
        'widthAnchor constraintLessThanOrEqualToConstant:414.0' \
        'widthAnchor constraintEqualToConstant:64.0' \
        'preferredHeightForWidth' \
        'CGSizeMake(29.0, 29.0)' \
        'preferredFontForTextStyle' \
        'adjustsFontForContentSizeCategory = YES' \
        'UITableViewAutomaticDimension' \
        'CydiaColorAppearanceDidChange' \
        'CydiaColorRoleCellBackground' \
        'CydiaColorRoleRemovingBackground' \
        'UIAccessibilityTraitButton' \
        'UIAccessibilityTraitStaticText' \
        'cydia.package.header' \
        'cydia.package.table' \
        'cydia.package.description' \
        'cydia.package.footer' \
        'cydia.package.modify' \
        'CydiaPackageDetailSectionKindDepiction' \
        '_depictionEligible' \
        '[[PackageDepictionView alloc]' \
        'cydia.package.depiction.cell' \
        'cydia.package.depiction.retry' \
        'cydia.package.depiction.external' \
        'CydiaPackageDetailNavigationKindDepictionLink' \
        'didRequestURLHandoff' \
        'scheduleDepictionTableUpdate' \
        'UCLocalizeEx(@"PACKAGE_SUPPORT", @"Package Support")' \
        'NSString *contactURL(ContactURLString(_viewModel))' \
        'UITableViewCellSelectionStyleNone' \
        'if ([URLString length] == 0)' \
        'didSelectModifyAction' \
        'didSelectNavigationKind' \
        '@property(nonatomic, weak) id<PackageDetailControllerDelegate> packageDelegate' \
        '_packageDelegate = delegate' \
        'cydia://package/%@/settings' \
        'cydia://package/%@/files'; do
    grep -Fq "$token" "$source" "$header" ||
        fail "missing native package-shell contract: $token"
done

if grep -Fq '[self setDelegate:delegate]' "$source"; then
    fail "package callback delegate still overwrites the application coordinator"
fi

grep -Fq 'if (_depictionEligible)' "$source" ||
    fail "validated depiction does not replace the native description branch"
grep -Fq 'if ([[_viewModel displayDescription] length] != 0)' "$source" ||
    fail "depiction-less native description fallback disappeared"
grep -Fq 'if ([[_viewModel homepageURLString] length] != 0)' "$source" ||
    fail "depiction-less native homepage fallback disappeared"

for specification in \
        'settings.png:ac8f20d57e915c30fd3fad87d9ed960e09d0456237d0f83147dbf5b7417bbcb7' \
        'email.png:8f743163c06185177b7b66adaac6c75748413946696735023c77cefc6c24bfee' \
        'console.png:554e5d52c41aa0a929b052e6d5cac4ac1ef86b25d62cd1669c7ab7b1cab6c945' \
        'warning.png:144eb369b0bc645861e9c54ddbff2fdfde5c7b00cdc60fe05843951687737334' \
        'web.png:a3570bc334607c3ab5ad367e22636ebb14cdcbbf0d88153423e0e54b6e6ef4c0' \
        'version.png:692cae56121c4f20b70ea0a7471635b59f6b9ef9e04bd38fa35e556d298baa6e' \
        'filesystem.png:5aed3ee1be240579fbc694c41f7ded52c26ad245fca3f3fd076908514fed6298'; do
    asset=${specification%%:*}
    expected=${specification#*:}
    test -s "$assets/$asset" || fail "historical package icon is absent: $asset"
    actual=$(shasum -a 256 "$assets/$asset" | awk '{ print $1 }')
    test "$actual" = "$expected" || fail "historical package icon changed: $asset"
    grep -Fq "SetLegacyPackageRowImage(cell, @\"$asset\")" "$source" ||
        fail "native package rows do not use historical icon: $asset"
done

for specification in \
        'Modes/DOWNGRADE.png:0df7639a5166d6c3d9b316a2b9e8a5ebfa55519d79a26a9de2eb3a9ef96e0ec3' \
        'Modes/INSTALL.png:4643d0109ad350607468ddf932422902e734d50bf41a748fc21ab2e9093645e5' \
        'Modes/PURGE.png:759cedad7d62e516fc806a6df43178b00d752fb9a60f0b65c51cd74bee076c7c' \
        'Modes/REINSTALL.png:789f442e9ac142ed975352f36e5c8ca958299bf646dce35b1ee9b07b1abfa7d2' \
        'Modes/REMOVE.png:35f8348dee6875a4868ab8d367abcfa80fbcb2be8c65ec6e1646b8b08cb36000' \
        'Modes/UPGRADE.png:d12b7efae393b7a27cfed3700bba9c771ffc5ecded7382b4195b7c34bdba2904'; do
    asset=${specification%%:*}
    expected=${specification#*:}
    test -s "$assets/$asset" || fail "historical mode icon is absent: $asset"
    actual=$(shasum -a 256 "$assets/$asset" | awk '{ print $1 }')
    test "$actual" = "$expected" || fail "historical mode icon changed: $asset"
done

for token in \
        'NSString *PackageModeAsset(NSString *mode)' \
        'normalized isEqualToString:@"NEW_INSTALL"' \
        'Modes/%@.png' \
        'PackageModeAsset([_viewModel modeLocalizationKey])' \
        'cell.imageView.accessibilityIdentifier = modeAsset'; do
    grep -Fq "$token" "$source" ||
        fail "queued mode icon contract is missing: $token"
done

for token in \
        'production-package-shell-and-depiction-v4' \
        'nativeRegionOrder' \
        'accessibilityElements' \
        'rowsMeetTouchTarget' \
        'rowIconsFit' \
        'legacyRowIcons' \
        'headerLabelsFit' \
        'uikitNativePixelWidth' \
        'uikitNativePixelHeight' \
        'buildEvidence' \
        'depictionRegionPresent' \
        'depictionState' \
        'depictionContentHeight' \
        'depictionHeightRevisionCount' \
        'depictionUserTouchSequence' \
        'depictionLastNavigationUserActivated' \
        'depictionLastNavigationDisposition' \
        'depictionDocumentPresent' \
        'depictionErrorRegionPresent' \
        'depictionResourceProbeAttempts' \
        'depictionResourcePositiveNaturalWidth' \
        'depictionResourceRejectedNaturalWidth' \
        'scrollViewCount' \
        'cydia-package-detail-probe-depiction-short' \
        'cydia-package-detail-probe-depiction-long' \
        'cydia-package-detail-probe-depiction-hostile' \
        'cydia-package-detail-probe-depiction-failed' \
        'cydia-package-detail-probe-depiction-top' \
        'productionRoute' \
        'cydia-package-detail-probe-dark' \
        'cydia-package-detail-probe-accessibility' \
        'cydia-package-detail-probe-sparse'; do
    grep -Fq "$token" "$probe" || fail "missing installed package probe contract: $token"
done
for token in \
        'id="cydia-resource"' \
        'src="cydia://section-icon/System"' \
        'id="cydia-resource-rejected"' \
        'src="cydia://section-icon/%2Fetc"'; do
    grep -Fq "$token" "$depiction_fixture" ||
        fail "missing installed depiction resource fixture: $token"
done
grep -Fq 'containsObject:@"--cydia-package-detail-probe"' "$appearance" ||
    fail "appearance application no longer routes the package-detail probe flag"

for token in \
        'usage: $0 CASE UDID MAKE BUILD_DIR' \
        'ios12) expected_runtime=12.0' \
        'ios15) expected_runtime=15.5' \
        'run_probe "$simulator_udid" "$case_name" "$expected_runtime"' \
        '"$make_program" --no-print-directory -j1'; do
    grep -Fq "$token" "$simulator_verifier" ||
        fail "package-detail runtime is not single-case and one-job: $token"
done
if grep -Eq 'run_probe "\$ios12_udid"|run_probe "\$ios15_udid"' "$simulator_verifier"; then
    fail "package-detail verifier still runs both simulator runtimes"
fi
for token in \
        'PACKAGE_DETAIL_SIMULATOR_CASE' \
        'ios12) simulator="$(IOS12_SIMULATOR_UDID)"' \
        'ios15) simulator="$(IOS15_SIMULATOR_UDID)"' \
        'package-detail-simulator/$$case_name'; do
    grep -Fq "$token" "$verify_makefile" ||
        fail "Make target does not select one package-detail runtime: $token"
done

table_allocations=$(grep -Fc '[[UITableView alloc]' "$source")
test "$table_allocations" -eq 1 ||
    fail "single-scroll table allocation count changed ($table_allocations != 1)"
grep -Fq '@property(nonatomic, strong) UITableView *tableView;' "$source" ||
    fail "controller no longer owns its single table explicitly"
if grep -Fq 'UIScrollView' "$source"; then
    fail "package shell introduced a nested scrolling owner"
fi

for token in \
        '- (void)updateHeaderIcon:(nullable UIImage *)headerIcon' \
        '_packageHeaderView.iconView.image = _headerIcon' \
        'CydiaPackageLegacyIconLoader' \
        '[viewModel baseIdentity] ?: [viewModel identity]' \
        '[strongSelf updateHeaderIcon:image]' \
        'CydiaPackageLegacyAlternateIconURL' \
        'ephemeralSessionConfiguration' \
        'configuration.HTTPShouldSetCookies = NO' \
        'configuration.URLCredentialStorage = nil' \
        'configuration.HTTPMaximumConnectionsPerHost = 1' \
        'completionHandler(nil)' \
        'CydiaPackageLegacyIconPNGDataIsAllowed' \
        '@"https://cydia.saurik.com/api/package/%@"' \
        '@"/icon@2x/"' \
        'components.scheme = @"https"'; do
    grep -Fq -- "$token" "$header" "$source" "$legacy_header" "$legacy" \
        "$legacy_icon_loader" "$legacy_icon_policy" ||
        fail "missing bounded legacy alternate-icon contract: $token"
done
test "$(cat "$legacy_icon_fixture")" = \
    '({"icon":"http://cydia.saurik.com/icon@2x/com.opa334.choicy.png"})' ||
    fail "captured Choicy alternate-icon response changed"
icon_update=$(sed -n '/^- (void)updateHeaderIcon:/,/^}/p' "$source")
printf '%s\n' "$icon_update" | grep -Fq '_packageHeaderView.iconView.image = _headerIcon' ||
    fail "alternate icon does not update the existing header image"
if printf '%s\n' "$icon_update" | grep -Eq 'reloadData|rebuildSections|_depiction'; then
    fail "alternate icon update mutates package sections, depiction, or scroll state"
fi
if grep -Eq 'eval\(|UIWebView|WKWebView|WebScriptObject|X-Cydia|X-Machine|@"Authorization"|@"Cookie"' \
        "$legacy_icon_loader" "$legacy_icon_policy"; then
    fail "alternate icon loader contains script, browser, identity, or cookie authority"
fi

for token in \
        'CydiaPackageDetailModifyActionKindClear' \
        'CydiaPackageDetailModifyActionKindUpgrade' \
        'CydiaPackageDetailModifyActionKindInstall' \
        'CydiaPackageDetailModifyActionKindReinstall' \
        'CydiaPackageDetailModifyActionKindRemove' \
        'CydiaPackageDetailModifyActionKindDowngrade' \
        '_contactKind = CydiaPackageDetailContactKindAuthor' \
        '_contactKind = contact == nil ? CydiaPackageDetailContactKindPackageSupport' \
        '_displayDescription = [_longDescription ?: _shortDescription copy]'; do
    grep -Fq "$token" "$model" || fail "missing immutable model contract: $token"
done

# The public CYPackageController class and both route entry points remain, but
# its visible implementation is now the same native shell proven by the probe.
grep -Fq 'CYPackageController : PackageDetailController' \
    "$root/Cydia/PackageControllers.h" ||
    fail "production CYPackageController is not backed by the native shell"
if grep -Eq 'CydiaWebViewController|UIWebView|WebScriptObject|WebFrame|(^|[^A-Za-z0-9_])UI_([^A-Za-z0-9_]|$)|#!/package' \
        "$root/Cydia/PackageControllers.h" "$legacy"; then
    fail "production package controller still contains remote/private-WebKit UI"
fi
grep -Fq 'CYPackageController *view([[CYPackageController alloc]' "$legacy" ||
    fail "package-list selection no longer uses the retained production controller"
grep -Fq '[[CYPackageController alloc] initWithDatabase:database_' "$navigation" ||
    fail "typed package routes no longer use the retained production controller"
for token in \
        'initWithViewModel:viewModel' \
        'updateWithViewModel:viewModel' \
        'didSelectModifyAction' \
        'didSelectNavigationKind' \
        '_allowJavaScriptPanel' \
        'if (view == nil)' \
        'if (versionChoice == nil)' \
        'repositoryDepictionContextWithOrigin' \
        'pageForURL:route context:context' \
        'launchApplicationWithIdentifier:identifier suspended:NO'; do
    grep -Fq "$token" "$legacy" ||
        fail "missing production package adapter contract: $token"
done
package_allocations=$(find "$root/Cydia" -type f -name '*.mm' \
    -exec grep -h -F '[[PackageDetailController alloc]' {} + | wc -l | tr -d ' ')
test "$package_allocations" -eq 0 ||
    fail "a direct package-shell allocation bypasses CYPackageController ($package_allocations != 0)"
grep -Fq 'controller_ = [[CYPackageController alloc]' "$probe" ||
    fail "installed package probe does not exercise the retained production class"

echo "[verify-package-detail-controller][ ok ] native shell and retained production routes"
