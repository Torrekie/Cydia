#!/bin/sh
# Copyright (C) 2026 Torrekie
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
capture=$root/Cydia/NativeAccessibilityTrace.mm
fail() { echo "[native-accessibility-trace][FAIL] $*" >&2; exit 1; }
for spec in PackageDetailController:package ConfirmationController:confirmation ProgressController:progress UpgradingGuideController:upgrading-guide ApplicationExtensionsController:application-extensions MoreSourcesController:more-sources CopyingFilesGuideController:copying-files HomeGuideController:home-guide; do
    file=${spec%:*}; surface=${spec#*:}
    rg -Fq "CydiaCaptureNativeAccessibility(self, @\"$surface\");" "$root/Cydia/$file.mm" || fail "missing $surface hook"
done
rg -Fq '![@[@"package", @"confirmation", @"progress", @"upgrading-guide", @"application-extensions", @"more-sources", @"copying-files", @"home-guide"] containsObject:surface]' "$capture" || fail 'surface allowlist changed'
for token in 'UIAccessibilityElementFocusedNotification' 'UIAccessibilityFocusedElementKey' \
    'UIAccessibilityAssistiveTechnologyKey' 'UIAccessibilityFocusedElement(technology)' \
    'MaximumViews' 'MaximumElements' 'MaximumDepth' 'MaximumTextLength' \
    '@"truncated"' '@"textTruncated"' '@"not-frontmost"' 'registeredFrontController' \
    '@"visible-native-subviews-not-effective-AX-order"' '@"requiresVisualBackgroundValidation"'; do
    rg -Fq "$token" "$capture" || fail "missing observation guard: $token"
done
if rg -n 'UIAccessibilityPostNotification|accessibilityActivate|setAccessibility|setVoiceOver|setenv|UIWebView|WebScript|invokeScope:|performSelector:' "$capture"; then
    fail 'observation must not mutate focus, input, settings or provider dispatch'
fi
rg -Uq 'if \(observer == nil\)\n        return;[\s\S]*dispatch_async' "$capture" || fail 'opt-out queued work'
echo '[native-accessibility-trace][ ok ] eight surfaces, bounded capture, actual notification subscription; static only'
