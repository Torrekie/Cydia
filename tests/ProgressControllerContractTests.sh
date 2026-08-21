#!/bin/sh
# Copyright (C) 2026 Torrekie
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
header=$root/Cydia/ProgressController.h
source=$root/Cydia/ProgressController.mm
cell=$root/Cydia/ProgressEventCell.mm
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
        'CydiaColorRoleGroupedBackground' \
        'CydiaColorAppearanceDidChange' \
        'cydia.progress.percent' \
        'state.running ?' \
        'UCLocalize("COMPLETE")' \
        'CydiaProgressEffectiveFinishAction' \
        'CydiaProgressFinishPlanForAction' \
        'redrawCompletedHierarchy' \
        'UpdateExternalStatus(Finish_ == 0 ? 0 : 2)' \
        'setProgressDelegate:progressModel_'; do
    grep -Fq "$token" "$source" || fail "missing native controller contract: $token"
done

for token in \
        'numberOfLines = 0' \
        'layoutMarginsGuide' \
        'adjustsFontForContentSizeCategory = YES' \
        'event.packageIdentifier' \
        'event.accessibilityLabel' \
        'event.rawType' \
        'CydiaColorRoleWarningLabel' \
        'CydiaColorRoleErrorLabel' \
        'CydiaColorRoleSecondaryLabel'; do
    grep -Fq "$token" "$cell" || fail "missing event-cell contract: $token"
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
