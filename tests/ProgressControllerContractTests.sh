#!/bin/sh
# Copyright (C) 2026 Torrekie
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
header=$root/Cydia/ProgressController.h
source=$root/Cydia/ProgressController.mm
cell=$root/Cydia/ProgressEventCell.mm
cell_header=$root/Cydia/ProgressEventCell.h
model=$root/Cydia/ProgressViewModel.mm
operations=$root/Cydia/Application+Operations.mm
temporary=$(mktemp -d "${TMPDIR:-/tmp}/cydia-progress-controller.XXXXXX")
trap 'rm -rf -- "$temporary"' EXIT HUP INT TERM

fail() {
    echo "[verify-progress-controller][FAIL] $*" >&2
    exit 1
}

grep -Fq 'ProgressController : CyteViewController' "$header" ||
    fail "ProgressController is not a native CyteViewController"

if grep -Eq 'CydiaWebViewController|WebScriptObject|WebFrame|cydiaProgress|CydiaProgressUpdate|dispatchEvent:|setURL:|NetDragon|netdragon' "$header" "$source"; then
    fail "retired progress WebView, JavaScript, URL, or telemetry dependency remains"
fi
if grep -Eq '(^|[^A-Za-z0-9_])UI_([^A-Za-z0-9_]|$)' "$source"; then
    fail "the remote first-party UI root remains referenced"
fi

for token in \
        'UIProgressView' \
        'UITableViewAutomaticDimension' \
        'preferredFontForTextStyle' \
        'adjustsFontForContentSizeCategory' \
        'CydiaProgressTerminalTraits' \
        'UIUserInterfaceStyleDark' \
        'CydiaColorRoleBackground' \
        'CydiaColorAppearanceDidChange' \
        'cydia.progress.footer' \
        'cydia.progress.finish' \
        'contentInset = UIEdgeInsetsMake(20.0' \
        'cydia.progress.percent' \
        'state.percentIsHistorical' \
        'historicalProgressTextForState:' \
        'LAST_REPORTED_PROGRESS' \
        'statusLabel_.hidden = !state.running && !state.percentIsHistorical' \
        'finishButton_.hidden = !finished' \
        'self.navigationItem.rightBarButtonItem = nil' \
        'state.running ?' \
        'UCLocalize("COMPLETE")' \
        'CydiaProgressEffectiveFinishAction' \
        'CydiaProgressFinishPlanForAction' \
        'finishDispatchInFlight_' \
        'if (finishDispatchInFlight_)' \
        'finishDispatchInFlight_ = YES' \
        'redrawCompletedHierarchy' \
        'invokeWhenVisible:' \
        'schedulePendingInvocationIfVisible' \
        'startPendingInvocationIfVisible' \
        'viewDidAppear:' \
        'performSelector:@selector(startPendingInvocationIfVisible)' \
        'afterDelay:0.0' \
        'UpdateExternalStatus(Finish_ == 0 ? 0 : 2)' \
        'setProgressDelegate:progressModel_'; do
    grep -Fq "$token" "$source" || fail "missing native controller contract: $token"
done

terminal_action_assignments=$(grep -F -c \
    'self.navigationItem.rightBarButtonItem = nil' \
    "$source")
[ "$terminal_action_assignments" -eq 1 ] ||
    fail "Progress does not expose exactly one navigation terminal action assignment"
footer_hidden_assignments=$(sed -n '/^- (void) renderState:/,/^- (void) updateNavigationActionsForState:/p' "$source" |
    grep -F -c 'finishButton_.hidden = !finished')
[ "$footer_hidden_assignments" -eq 1 ] ||
    fail "Progress footer terminal action visibility policy is not unique"

sed -n '/^- (void) applyColorAppearance {/,/^- (void) applyTypography {/p' \
    "$source" >"$temporary/appearance.mm"
for token in \
        'CydiaProgressTerminalTraits()' \
        'CydiaColorRoleBackground' \
        'self.view.backgroundColor = canvas' \
        'footerView_.backgroundColor = canvas' \
        'eventsView_.backgroundColor = canvas' \
        'statusLabel_.textColor = secondary' \
        'navigationBar.barStyle = UIBarStyleBlack' \
        'navigationBar.backgroundColor = canvas'; do
    grep -Fq "$token" "$temporary/appearance.mm" ||
        fail "missing fixed-dark Progress terminal contract: $token"
done
if grep -Fq 'formSheet ? CydiaColorRoleCellBackground' "$temporary/appearance.mm"; then
    fail "Progress still switches to a light/elevated form-sheet canvas"
fi

grep -Fq '[progress invokeWhenVisible:invocation withTitle:title]' "$operations" ||
    fail "application does not defer acquisition until native Progress is visible"
if grep -Fq '[progress invoke:invocation withTitle:title]' "$operations"; then
    fail "application still starts acquisition before the Progress transition commits"
fi

probe=$root/Cydia/ProgressControllerProbe.mm
simulator=$root/scripts/verify-progress-simulator.sh
grep -Fq '"$make_program" --no-print-directory -j1' "$simulator" ||
    fail "installed Progress evidence is not serialized at one build job"
for token in \
        'navigation_.modalPresentationStyle = UIModalPresentationFormSheet' \
        '[self presentViewController:navigation_ animated:NO completion:^{' \
        '[navigation_ pushViewController:controller_ animated:NO]' \
        'navigation_.presentationController.overrideTraitCollection = traits' \
        'self.presentedViewController == navigation_' \
        'cydia.progress.confirmation-placeholder' \
        'frameOfPresentedViewInContainerView' \
        'adaptivePresentationStyle' \
        'cydia-progress-probe-cancel' \
        'running-cancelled' \
        '[controller_ cancel]' \
        '@"cancellationState"' \
        '@"progressCancelled"' \
        '@"actualModalPresentation"' \
        '@"presentationAttached"' \
        '@"formSheetPresentation": @(formSheet_)' \
        'formSheet_ ? UIModalPresentationFormSheet :' \
        'horizontalSizeClass == UIUserInterfaceSizeClassCompact ? actualModal' \
        'allVisibleRowsHaveTerminalSurface' \
        '@"finishButtonHeight"' \
        '@"finishDispatchCount"' \
        '@"finishDispatchAction"' \
        'cydia-progress-probe-activate-finish' \
        'sendActionsForControlEvents:UIControlEventTouchUpInside' \
        '@"formSheetFrameInset"' \
        '@"backdropInterceptsOutsideSheet"' \
        '@"dimmingEvidenceEligible"' \
        'cydia-progress-probe-light' \
        '@"terminalCanvasUsesFixedPalette"' \
        '@"eventCellsUseTerminalSurface"' \
        '@"confirmationPlaceholderUsesCellBackground"' \
        '@"messageLineHeight"' \
        '@"messageLineSpacing"' \
        '@"rowHeights"'; do
    grep -Fq "$token" "$probe" ||
        fail "missing real form-sheet Progress probe contract: $token"
done

for token in \
        'cydia-progress-probe-cancel' \
        'running-cancelled' \
        'cancellationState)" = "1"' \
        'cancellationState 2' \
        'progressCancelled true' \
        'cancellationState 0' \
        'progressCancelled false'; do
    grep -Fq "$token" "$simulator" ||
        fail "Progress simulator verifier is missing cancellation transition assertion: $token"
done

for token in \
        'height >= 44' \
        'finishDispatchCount 1' \
        'finishDispatchAction returnToCydia' \
        'repeated terminal activation dispatched more than once'; do
    grep -Fq "$token" "$simulator" ||
        fail "Progress simulator verifier is missing terminal activation assertion: $token"
done

view_did_appear=$(sed -n '/^- (void) viewDidAppear:/,/^}/p' "$source")
printf '%s\n' "$view_did_appear" | grep -Fq '[self schedulePendingInvocationIfVisible]' ||
    fail "viewDidAppear does not defer acquisition to a default-mode turn"
if printf '%s\n' "$view_did_appear" | grep -Fq '[self startPendingInvocationIfVisible]'; then
    fail "viewDidAppear still enters the nested acquisition run loop synchronously"
fi

for token in \
        'CydiaOwnedPackageDisplayName' \
        'NSMutableString' \
        '[owned appendString:name]' \
        'return CydiaOwnedPackageDisplayName(package)' \
        'numberOfLines = 0' \
        'lineBreakMode = NSLineBreakByWordWrapping' \
        'layoutMarginsGuide' \
        'CydiaProgressEventVerticalInset = 1.0' \
        'paragraph.lineSpacing = 0.0' \
        'paragraph.minimumLineHeight = lineHeight' \
        'paragraph.maximumLineHeight = lineHeight' \
        'adjustsFontForContentSizeCategory = YES' \
        'event.packageIdentifier' \
        'event.accessibilityLabel' \
        'event.rawType' \
        'CydiaColorRoleWarningLabel' \
        'CydiaColorRoleErrorLabel' \
        'CydiaColorRoleSecondaryLabel' \
        'CydiaColorRoleBackground'; do
    case "$token" in
        CydiaOwnedPackageDisplayName|NSMutableString|'[owned appendString:name]'|'return CydiaOwnedPackageDisplayName(package)')
            grep -Fq "$token" "$source" || fail "missing package-name ownership contract: $token" ;;
        *)
            grep -Fq "$token" "$cell" || fail "missing event-cell contract: $token" ;;
    esac
done

for token in messageLineHeight messageLineSpacing messageMinimumLineHeight \
             messageMaximumLineHeight eventLayoutMargins; do
    grep -Fq "$token" "$cell_header" ||
        fail "missing exposed event-line metric contract: $token"
done
for token in CydiaProgressVisibleCharacters 'character == 0' \
             'presentation.displayMessage = CydiaProgressLogMessage'; do
    grep -Fq "$token" "$model" ||
        fail "missing complete terminal-message boundary: $token"
done

sed -n '/^- (void) close {/,/^- (void) setTitle:/p' "$source" >"$temporary/close.mm"
line_of() {
    grep -n -F "$1" "$temporary/close.mm" | sed -n '1s/:.*//p'
}

external_line=$(line_of 'UpdateExternalStatus(0)')
effective_line=$(line_of 'CydiaProgressEffectiveFinishAction')
save_line=$(line_of 'plan.savesState')
switch_line=$(line_of 'switch (plan.sideEffect)')
test -n "$external_line" && test -n "$effective_line" &&
test -n "$save_line" && test -n "$switch_line" ||
    fail "close side-effect ordering markers are incomplete"
test "$external_line" -lt "$effective_line" &&
test "$effective_line" -lt "$save_line" &&
test "$save_line" -lt "$switch_line" ||
    fail "external status, live finish escalation, save, and execution order changed"

echo "[verify-progress-controller][ ok ] native controller and ordered finish contract"
