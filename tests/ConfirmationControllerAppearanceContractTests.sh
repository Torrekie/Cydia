#!/bin/sh
# Cydia Refurbished native Confirmation appearance/accessibility contract.
# Copyright (C) 2026 Torrekie
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
header="$root/Cydia/ConfirmationController.h"
source="$root/Cydia/ConfirmationController.mm"
probe="$root/Cydia/ConfirmationControllerProbe.mm"
simulator="$root/scripts/verify-confirmation-simulator.sh"

fail() {
    echo "[verify-confirmation-appearance][FAIL] $*" >&2
    exit 1
}

test -f "$header" || fail "Confirmation controller header is missing"
test -f "$source" || fail "Confirmation controller source is missing"
test -f "$probe" || fail "Confirmation controller probe source is missing"

grep -Fq 'ConfirmationController : CyteViewController' "$header" ||
    fail "Confirmation is not a native CyteViewController"
if grep -Eq 'CydiaWebViewController|UIWebView|WebScriptObject|WebFrame|WebCore|applicationCache|(^|[^A-Za-z0-9_])UI_([^A-Za-z0-9_]|$)' \
        "$header" "$source"; then
    fail "Confirmation appearance contract retains a retired web/private-UI dependency"
fi

for token in \
        'CydiaConfirmationTargetButton' \
        'intrinsicContentSize' \
        'CGSizeMake(MAX(44.0, size.width), MAX(44.0, size.height))' \
        'button.widthAnchor constraintGreaterThanOrEqualToConstant:44.0' \
        'button.heightAnchor constraintGreaterThanOrEqualToConstant:44.0' \
        'cydia.confirmation.cancel' \
        'cydia.confirmation.confirm' \
        'UIAccessibilityIsVoiceOverRunning' \
        'UIAccessibilityScreenChangedNotification' \
        'accessibilityViewIsModal = YES' \
        'self.navigationController.view.accessibilityViewIsModal = YES' \
        'dispatch_async(dispatch_get_main_queue()' \
        'dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC)' \
        'forControlEvents:UIControlEventTouchUpInside' \
        'UITableViewStyleGrouped' \
        'UITableViewAutomaticDimension' \
        'preferredFontForTextStyle' \
        'adjustsFontForContentSizeCategory = YES' \
        'traitCollectionDidChange:' \
        'CydiaColorAppearanceDidChange' \
        'CydiaColorRoleCellBackground' \
        'CydiaColorRoleRemovingBackground' \
        'CydiaColorRoleSeparator' \
        'CydiaColorRoleAccent' \
        'heightAnchor constraintGreaterThanOrEqualToConstant:44.0' \
        'UIAccessibilityTraitButton' \
        'cydia.confirmation.table' \
        'cydia.confirmation.continue-queuing' \
        'cydia.confirmation.issue-note' \
        'CydiaConfirmationCellLayout'; do
    grep -Fq "$token" "$source" ||
        fail "missing native Confirmation appearance/accessibility contract: $token"
done

appearance=$(mktemp "${TMPDIR:-/tmp}/cydia-confirmation-appearance.XXXXXX")
trap 'rm -f "$appearance"' EXIT HUP INT TERM
sed -n '/^- (void) applyColorAppearance {/,/^}/p' "$source" >"$appearance"

for token in \
        'presentedSurface' \
        'self.navigationController.view.backgroundColor = presentedSurface' \
        'self.navigationController.view.opaque = YES' \
        'navigationBar.translucent = NO' \
        'navigationBar.barTintColor = presentedSurface' \
        'navigationBar.backgroundColor = presentedSurface' \
        'navigationBar.tintColor = accent' \
        'navigationBar.titleTextAttributes'; do
    grep -Fq "$token" "$appearance" ||
        fail "Confirmation navigation chrome is missing opaque semantic surface: $token"
done

# The modern appearance API must never be emitted into an iOS 12 binary.
grep -Fq '#if defined(__IPHONE_OS_VERSION_MAX_ALLOWED) && __IPHONE_OS_VERSION_MAX_ALLOWED >= 130000' \
    "$source" || fail "iOS 13 navigation appearance path is not SDK guarded"
grep -Fq 'if (@available(iOS 13.0, *))' "$source" ||
    fail "iOS 13 navigation appearance path is not runtime guarded"
grep -Fq 'configureWithOpaqueBackground' "$appearance" ||
    fail "iOS 13 navigation appearance does not configure an opaque background"
grep -Fq 'navigationBar.standardAppearance = appearance' "$appearance" ||
    fail "iOS 13 standard navigation appearance is not assigned"
grep -Fq 'navigationBar.scrollEdgeAppearance = appearance' "$appearance" ||
    fail "iOS 13 scroll-edge navigation appearance is not assigned"

# Trait changes must repaint visible rows and reflow Dynamic Type rather than
# relying on a process-global color/font value.
trait_body=$(sed -n '/^- (void) traitCollectionDidChange:/,/^}/p' "$source")
printf '%s\n' "$trait_body" | grep -Fq 'CydiaColorAppearanceDidChange' ||
    fail "trait changes do not refresh semantic Confirmation colors"
printf '%s\n' "$trait_body" | grep -Fq '[_tableView reloadData]' ||
    fail "trait changes do not reflow Confirmation Dynamic Type rows"

# The probe records semantic-surface, accessibility-size, and presentation
# state; this static contract checks the evidence seam but does not claim an
# installed presentation by itself.
for token in \
        'cydia-confirmation-probe-accessibility' \
        '@"empty"' \
        'expectedAccessibilityContentSizeCategory' \
        'visibleRowsFit' \
        'rowsMeetTouchTarget' \
        'visibleWebViews' \
        '@"hasChanges"' \
        '@"hasBlockingIssues"' \
        '@"showsConfirmAction"' \
        'UIContentSizeCategoryAccessibilityLarge'; do
    grep -Fq "$token" "$probe" ||
        fail "Confirmation probe is missing P1 evidence seam: $token"
done

# The runtime seam must be able to prove that Confirmation is actually
# presented as a UIKit form sheet, including the presenter/dimming geometry;
# luminance-only state from a full-window child is not sufficient evidence.
for token in \
        'formSheet_' \
        'formSheetPresentationComplete_' \
        'cydia-confirmation-probe-form-sheet' \
        'UIModalPresentationFormSheet' \
        '[self presentViewController:presentedNavigation animated:NO completion:^{' \
        'navigation_.presentationController.overrideTraitCollection = traits' \
        'frameOfPresentedViewInContainerView' \
        'adaptivePresentationStyle' \
        'rowsMeetTouchTarget' \
        'navigationBarUsesPresentedSurface' \
        'navigationBarOpaque' \
        'navigationBarTranslucent' \
        'sheetUsesCellBackground' \
        'presenterUsesGroupedBackground' \
        '@"actualModalPresentation"' \
        '@"dismissalInFlight"' \
        'navigation_.presentingViewController == nil' \
        '@"presentationAttached"' \
        '@"formSheetFrameInset"' \
        '@"backdropInterceptsOutsideSheet"' \
        '@"dimmingEvidenceEligible"'; do
    grep -Fq "$token" "$probe" ||
        fail "Confirmation probe is missing real form-sheet evidence contract: $token"
done
for token in \
        'assert_real_form_sheet' \
        'empty-light-state.plist' \
        'cydia-confirmation-probe-form-sheet' \
        'cydia-confirmation-probe-empty' \
        'modificationRowCount 0' \
        'hasChanges true' \
        'hasBlockingIssues false' \
        'showsConfirmAction true' \
        'hasChanges false' \
        'requestedPresentationStyle' \
        'horizontalSizeClass' \
        'formSheetFrameInset' \
        'backdropInterceptsOutsideSheet' \
        'dimmingEvidenceEligible' \
        'rowsMeetTouchTarget'; do
    grep -Fq "$token" "$simulator" ||
        fail "Confirmation simulator verifier is missing form-sheet assertion: $token"
done

for token in \
        'wait_for_value "$state" actualModalPresentation false' \
        'wait_for_value "$state" dismissalInFlight false' \
        'dismissed-$action-state.plist'; do
    grep -Fq "$token" "$simulator" ||
        fail "Confirmation verifier does not observe completed dismissal: $token"
done

echo "[verify-confirmation-appearance][ ok ] native opaque semantic chrome, Dynamic Type, and accessibility contract"
