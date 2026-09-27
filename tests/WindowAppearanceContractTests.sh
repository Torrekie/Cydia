#!/bin/sh
# Cydia root-window appearance compatibility contract.
# Copyright (C) 2026 Torrekie
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
header="$root/Cydia/Appearance.h"
source="$root/Cydia/Appearance.mm"
info="$root/MobileCydia.app/Info.plist"
application="$root/MobileCydia.mm"
lifecycle="$root/Cydia/Application+Lifecycle.mm"
tab_bar="$root/Cydia/TabBarController.mm"

fail() {
    echo "[verify-window-appearance][FAIL] $*" >&2
    exit 1
}

compact() {
    tr -d '[:space:]'
}

for file in "$header" "$source" "$info" "$application" "$lifecycle" "$tab_bar"; do
    test -f "$file" || fail "missing source: ${file#"$root/"}"
done

style_key_count=$(grep -Fc '<key>UIUserInterfaceStyle</key>' "$info")
test "$style_key_count" -eq 1 ||
    fail "Info.plist does not contain exactly one UIUserInterfaceStyle policy"
style_key_line=$(grep -n -F '<key>UIUserInterfaceStyle</key>' "$info" |
    head -1 | cut -d: -f1)
style_value_line=$((style_key_line + 1))
sed -n "${style_value_line}p" "$info" |
    grep -Eq '^[[:space:]]*<string>Automatic</string>[[:space:]]*$' ||
    fail "Cydia does not request UIKit's automatic appearance"

grep -Fq 'CydiaApplyLegacyInterfaceStyleCompatibility(UIWindow *window)' "$header" ||
    fail "legacy appearance compatibility helper is not declared"
grep -Fq 'CydiaApplyLegacyInterfaceStyleCompatibility(window_);' "$application" ||
    fail "Cydia startup does not apply the legacy appearance compatibility"
grep -Fq 'applicationDidBecomeActive:' "$lifecycle" ||
    fail "Cydia does not refresh the legacy appearance at activation"
grep -Fq 'CydiaApplyLegacyInterfaceStyleCompatibility(window_);' "$lifecycle" ||
    fail "Cydia activation bypasses the legacy appearance compatibility"

init_line=$(grep -n -F 'window_ = [[CyteWindow alloc]' "$application" | head -1 | cut -d: -f1)
apply_line=$(grep -n -F 'CydiaApplyLegacyInterfaceStyleCompatibility(window_);' "$application" |
    head -1 | cut -d: -f1)
root_line=$(grep -n -F '[window_ setRootViewController:emulated_];' "$application" |
    head -1 | cut -d: -f1)
test -n "$init_line" && test -n "$apply_line" && test -n "$root_line" &&
    test "$init_line" -lt "$root_line" && test "$root_line" -lt "$apply_line" ||
    fail "legacy appearance is evaluated before the root trait environment is attached"

mode_lookup=$(sed -n \
    '/^static UIUserInterfaceStyle CydiaLegacyInterfaceStyleMode(void) {/,/^}/p' \
    "$source")
printf '%s\n' "$mode_lookup" | grep -Fq 'NSSearchPathForDirectoriesInDomains' ||
    fail "style mode lookup is not rooted in the current mobile user Library"
printf '%s\n' "$mode_lookup" |
    grep -Fq '@"Preferences/com.apple.uikitservices.userInterfaceStyleMode.plist"' ||
    fail "style mode lookup does not read UIKit's exact preference file"
printf '%s\n' "$mode_lookup" | grep -Fq 'dictionaryWithContentsOfFile:path' ||
    fail "style mode preference is not parsed as a plist"
printf '%s\n' "$mode_lookup" | grep -Fq 'objectForKey:@"UserInterfaceStyleMode"' ||
    fail "style mode lookup does not read the exact UIKit key"
printf '%s\n' "$mode_lookup" | grep -Fq 'isKindOfClass:[NSNumber class]' ||
    fail "style mode preference is not type checked"
printf '%s\n' "$mode_lookup" | grep -Fq 'CFGetTypeID(rawType) != CFNumberGetTypeID()' ||
    fail "plist booleans are not rejected as malformed style modes"
printf '%s\n' "$mode_lookup" | grep -Fq 'CFNumberIsFloatType' ||
    fail "floating-point style modes are not rejected"
printf '%s\n' "$mode_lookup" |
    grep -Fq 'switch ([(NSNumber *) rawMode integerValue])' ||
    fail "style mapping is not driven by the validated numeric mode"
light_case=$(printf '%s\n' "$mode_lookup" | awk '
    /case 1:/ { inside = 1; next }
    /case [0-9]+:|default:/ { if (inside) exit }
    inside { print }
')
dark_case=$(printf '%s\n' "$mode_lookup" | awk '
    /case 2:/ { inside = 1; next }
    /case [0-9]+:|default:/ { if (inside) exit }
    inside { print }
')
default_case=$(printf '%s\n' "$mode_lookup" | awk '
    /default:/ { inside = 1; next }
    inside && /^[[:space:]]*}/ { exit }
    inside { print }
')
test "$(printf '%s\n' "$light_case" | compact)" = \
    'returnUIUserInterfaceStyleLight;' ||
    fail "UIKit mode 1 does not map directly to Light"
test "$(printf '%s\n' "$dark_case" | compact)" = \
    'returnUIUserInterfaceStyleDark;' ||
    fail "UIKit mode 2 does not map directly to Dark"
test "$(printf '%s\n' "$default_case" | compact)" = \
    'returnUIUserInterfaceStyleUnspecified;' ||
    fail "unknown UIKit modes do not map directly to inherited appearance"
printf '%s\n' "$mode_lookup" | grep -Fq 'return UIUserInterfaceStyleUnspecified' ||
    fail "unknown or automatic modes do not fall back to UIKit inheritance"
available_line=$(printf '%s\n' "$mode_lookup" | grep -n -F '@available(iOS 13.0, *)' |
    head -1 | cut -d: -f1)
read_line=$(printf '%s\n' "$mode_lookup" | grep -n -F 'dictionaryWithContentsOfFile:path' |
    head -1 | cut -d: -f1)
test -n "$available_line" && test -n "$read_line" && test "$available_line" -lt "$read_line" ||
    fail "private compatibility read is not contained by the iOS 13 guard"
if printf '%s\n' "$source" | grep -Eq \
    'AppleInterfaceStyle|NSUserDefaults|CFPreferences|persistentDomainForName|/var/mobile|writeToFile:'; then
    fail "stale tokens, hard-coded homes, or preference writes escaped into production"
fi

apply_body=$(sed -n \
    '/^void CydiaApplyLegacyInterfaceStyleCompatibility(UIWindow \*window) {/,/^}/p' \
    "$source")
clear_body=$(sed -n \
    '/^static void CydiaClearManagedLegacyAppearance(void) {/,/^}/p' \
    "$source")
clear_executable=$(printf '%s\n' "$clear_body" |
    sed -e '1d' -e '$d' -e '/^#if /d' -e '/^#endif/d')
test "$(printf '%s\n' "$clear_executable" | compact)" = \
    'CydiaManagedLegacyAppearanceWindow=nil;CydiaManagedLegacyAppearanceStyle=UIUserInterfaceStyleUnspecified;' ||
    fail "managed appearance clear helper is not exactly the two ownership resets"
printf '%s\n' "$apply_body" | grep -Fq '@available(iOS 13.0, *)' ||
    fail "legacy compatibility is not guarded to iOS 13+"
rootful_gate=$(printf '%s\n' "$apply_body" | sed -n \
    '/if (CydiaRuntime::PackageDatabasePaths::Current().layout() !=/,/^[[:space:]]*return;/p')
printf '%s\n' "$rootful_gate" |
    grep -Fq 'CydiaRuntime::PackageDatabaseLayout::Rootful' ||
    fail "legacy compatibility does not positively require the rootful layout"
test "$(printf '%s\n' "$rootful_gate" | compact)" = \
    'if(CydiaRuntime::PackageDatabasePaths::Current().layout()!=CydiaRuntime::PackageDatabaseLayout::Rootful)return;' ||
    fail "rootless layout is not excluded before compatibility arbitration"
gate_line=$(printf '%s\n' "$apply_body" |
    grep -n -F 'CydiaRuntime::PackageDatabasePaths::Current().layout() !=' |
    head -1 | cut -d: -f1)
lookup_line=$(printf '%s\n' "$apply_body" |
    grep -n -F 'CydiaLegacyInterfaceStyleMode()' | head -1 | cut -d: -f1)
test -n "$gate_line" && test -n "$lookup_line" && test "$gate_line" -lt "$lookup_line" ||
    fail "style preference can be read before the rootful-only gate"
printf '%s\n' "$apply_body" | grep -Fq 'current != UIUserInterfaceStyleUnspecified' ||
    fail "caller-owned explicit root styles are not preserved"
current_declaration=$(printf '%s\n' "$apply_body" |
    grep -F 'UIUserInterfaceStyle current(' | head -1)
same_window_declaration=$(printf '%s\n' "$apply_body" |
    grep -F 'BOOL sameWindow(' | head -1)
test "$(printf '%s\n' "$current_declaration" | compact)" = \
    'UIUserInterfaceStylecurrent(window.overrideUserInterfaceStyle);' ||
    fail "current style is not bound to the supplied window override"
test "$(printf '%s\n' "$same_window_declaration" | compact)" = \
    'BOOLsameWindow(window==CydiaManagedLegacyAppearanceWindow);' ||
    fail "ownership is not bound to the supplied window"
managed_predicate=$(printf '%s\n' "$apply_body" | sed -n '/BOOL managed(/,/);/p')
test "$(printf '%s\n' "$managed_predicate" | compact)" = \
    'BOOLmanaged(sameWindow&&current==CydiaManagedLegacyAppearanceStyle&&current!=UIUserInterfaceStyleUnspecified);' ||
    fail "managed ownership is not bound to window, style, and explicit fallback"
caller_change=$(printf '%s\n' "$apply_body" | sed -n \
    '/if (sameWindow && !managed) {/,/^[[:space:]]*return;/p')
test "$(printf '%s\n' "$caller_change" | compact)" = \
    'if(sameWindow&&!managed){CydiaClearManagedLegacyAppearance();return;' ||
    fail "caller-owned style change is overwritten"
explicit_owner_guard=$(printf '%s\n' "$apply_body" | sed -n \
    '/if (!managed && current != UIUserInterfaceStyleUnspecified)/,/^[[:space:]]*return;/p')
test "$(printf '%s\n' "$explicit_owner_guard" | compact)" = \
    'if(!managed&&current!=UIUserInterfaceStyleUnspecified)return;' ||
    fail "an untracked caller-owned explicit style can be overwritten"
managed_refresh=$(printf '%s\n' "$apply_body" | sed -n \
    '/if (managed) {/,/^[[:space:]]*return;/p')
managed_refresh_full=$(printf '%s\n' "$apply_body" | sed -n \
    '/if (managed) {/,/^[[:space:]]*}[[:space:]]*$/p')
test "$(printf '%s\n' "$managed_refresh_full" | compact)" = \
    'if(managed){window.overrideUserInterfaceStyle=UIUserInterfaceStyleUnspecified;CydiaClearManagedLegacyAppearance();dispatch_async(dispatch_get_main_queue(),^{CydiaApplyLegacyInterfaceStyleCompatibility(window);});return;}' ||
    fail "managed fallback is not exactly release, clear, defer, and return"
printf '%s\n' "$managed_refresh" |
    grep -Fq 'window.overrideUserInterfaceStyle = UIUserInterfaceStyleUnspecified' ||
    fail "helper-owned fallback is not released before reevaluation"
printf '%s\n' "$managed_refresh" |
    grep -Fq 'CydiaClearManagedLegacyAppearance();' ||
    fail "helper ownership is not cleared before reevaluation"
managed_dispatch=$(printf '%s\n' "$managed_refresh" | sed -n \
    '/dispatch_async(dispatch_get_main_queue(), \^{/,/^[[:space:]]*});/p')
printf '%s\n' "$managed_dispatch" |
    grep -Fq 'CydiaApplyLegacyInterfaceStyleCompatibility(window);' ||
    fail "fallback reevaluation is not inside the deferred main-queue block"
reapply_count=$(grep -Fc 'CydiaApplyLegacyInterfaceStyleCompatibility(window);' "$source")
test "$reapply_count" -eq 1 ||
    fail "fallback reevaluation is not bounded to one deferred call"
managed_release_line=$(printf '%s\n' "$managed_refresh" |
    grep -n -F 'window.overrideUserInterfaceStyle = UIUserInterfaceStyleUnspecified' |
    head -1 | cut -d: -f1)
managed_clear_line=$(printf '%s\n' "$managed_refresh" |
    grep -n -F 'CydiaClearManagedLegacyAppearance();' | head -1 | cut -d: -f1)
managed_dispatch_line=$(printf '%s\n' "$managed_refresh" |
    grep -n -F 'dispatch_async(dispatch_get_main_queue()' | head -1 | cut -d: -f1)
managed_call_line=$(printf '%s\n' "$managed_refresh" |
    grep -n -F 'CydiaApplyLegacyInterfaceStyleCompatibility(window);' |
    head -1 | cut -d: -f1)
managed_close_line=$(printf '%s\n' "$managed_refresh" |
    grep -n -E '^[[:space:]]*}\);' | head -1 | cut -d: -f1)
managed_return_line=$(printf '%s\n' "$managed_refresh" |
    grep -n -F 'return;' | tail -1 | cut -d: -f1)
test -n "$managed_release_line" && test -n "$managed_clear_line" &&
    test -n "$managed_dispatch_line" && test -n "$managed_call_line" &&
    test -n "$managed_close_line" && test -n "$managed_return_line" &&
    test "$managed_release_line" -lt "$managed_clear_line" &&
    test "$managed_clear_line" -lt "$managed_dispatch_line" &&
    test "$managed_dispatch_line" -lt "$managed_call_line" &&
    test "$managed_call_line" -lt "$managed_close_line" &&
    test "$managed_close_line" -lt "$managed_return_line" ||
    fail "managed fallback is not released, deferred, reevaluated, and returned in order"
printf '%s\n' "$apply_body" | grep -Fq 'desired == UIUserInterfaceStyleLight' ||
    fail "Light mode cannot reach the root window"
printf '%s\n' "$apply_body" | grep -Fq 'desired == UIUserInterfaceStyleDark' ||
    fail "Dark mode cannot reach the root window"
printf '%s\n' "$apply_body" |
    grep -Fq 'inherited(window.traitCollection.userInterfaceStyle)' ||
    fail "compatibility does not inspect the attached inherited window trait"
valid_mode=$(printf '%s\n' "$apply_body" | sed -n \
    '/if (desired == UIUserInterfaceStyleLight ||/,/^[[:space:]]*}/p')
inherited_match=$(printf '%s\n' "$valid_mode" | sed -n \
    '/if (inherited == desired)/,/^[[:space:]]*return;/p')
test "$(printf '%s\n' "$inherited_match" | compact)" = \
    'if(inherited==desired)return;' ||
    fail "a correctly inheriting UIKit window is still pinned explicitly"
match_return_line=$(printf '%s\n' "$valid_mode" |
    grep -n -F 'if (inherited == desired)' | head -1 | cut -d: -f1)
valid_return_line=$(printf '%s\n' "$valid_mode" |
    grep -n -F 'return;' | head -1 | cut -d: -f1)
valid_override_line=$(printf '%s\n' "$valid_mode" |
    grep -n -F 'window.overrideUserInterfaceStyle = desired' | head -1 | cut -d: -f1)
test -n "$match_return_line" && test -n "$valid_return_line" &&
    test -n "$valid_override_line" && test "$match_return_line" -lt "$valid_return_line" &&
    test "$valid_return_line" -lt "$valid_override_line" ||
    fail "inherited-match return does not precede the compatibility override"
printf '%s\n' "$valid_mode" | grep -Fq 'window.overrideUserInterfaceStyle = desired' ||
    fail "validated style is not applied to the root window"
test "$(printf '%s\n' "$valid_mode" | compact)" = \
    'if(desired==UIUserInterfaceStyleLight||desired==UIUserInterfaceStyleDark){if(inherited==desired)return;window.overrideUserInterfaceStyle=desired;CydiaManagedLegacyAppearanceWindow=window;CydiaManagedLegacyAppearanceStyle=desired;}' ||
    fail "valid mismatch does not exclusively apply and track the fallback"
grep -Fq 'CydiaManagedLegacyAppearanceWindow' "$source" ||
    fail "helper-owned root-window appearance is not tracked"
grep -Fq 'CydiaManagedLegacyAppearanceStyle' "$source" ||
    fail "helper-owned root-window style is not tracked"
grep -Fq '(void) window;' "$source" ||
    fail "iOS 12 compile path is not an explicit no-op"
override_write_count=$(grep -Fc 'window.overrideUserInterfaceStyle =' "$source")
managed_window_write_count=$(grep -Ec \
    'CydiaManagedLegacyAppearanceWindow = (nil|window);' "$source")
managed_style_write_count=$(grep -Ec \
    'CydiaManagedLegacyAppearanceStyle = (UIUserInterfaceStyleUnspecified|desired);' "$source")
test "$override_write_count" -eq 2 ||
    fail "unexpected root-window override write escaped the gated state machine"
test "$managed_window_write_count" -eq 2 && test "$managed_style_write_count" -eq 2 ||
    fail "unexpected or missing managed-ownership write escaped the state machine"

tab_bar_appearance=$(sed -n \
    '/^- (void) applyTabBarAppearance {/,/^}/p' "$tab_bar")
printf '%s\n' "$tab_bar_appearance" | grep -Fq 'self.tabBar.barStyle' ||
    fail "tab bar chrome does not refresh its native bar style"
printf '%s\n' "$tab_bar_appearance" | grep -Fq 'UIBarStyleBlack' ||
    fail "tab bar appearance does not select native Dark chrome"
printf '%s\n' "$tab_bar_appearance" | grep -Fq 'UIBarStyleDefault' ||
    fail "tab bar appearance does not select native Light chrome"
if printf '%s\n' "$tab_bar_appearance" | grep -Eq \
    'barTintColor|backgroundColor|standardAppearance|scrollEdgeAppearance'; then
    fail "tab bar appearance replaces native chrome instead of selecting its style"
fi

tab_bar_init=$(sed -n '/^- (id) initWithDatabase:/,/^}/p' "$tab_bar")
printf '%s\n' "$tab_bar_init" | grep -Fq '[[self view] setAutoresizingMask:' ||
    fail "tab bar initialization no longer forces the native bar to load"
printf '%s\n' "$tab_bar_init" | grep -Fq '[self applyTabBarAppearance];' ||
    fail "initial tab bar appearance is not applied after loading the bar"

tab_bar_trait=$(sed -n \
    '/^- (void) traitCollectionDidChange:/,/^}/p' "$tab_bar")
printf '%s\n' "$tab_bar_trait" | grep -Fq 'CydiaColorAppearanceDidChange' ||
    fail "tab bar does not detect a live appearance change"
printf '%s\n' "$tab_bar_trait" | grep -Fq '[self applyTabBarAppearance];' ||
    fail "live appearance changes do not refresh tab bar chrome"

if test "$(uname -s)" = Darwin; then
    developer_dir=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
    if test ! -d "$developer_dir"; then
        developer_dir="$HOME/Downloads/Xcode.app/Contents/Developer"
    fi
    clang_path=$(DEVELOPER_DIR="$developer_dir" /usr/bin/xcrun --sdk iphoneos -f clang++ 2>/dev/null || true)
    sdk_path=$(DEVELOPER_DIR="$developer_dir" /usr/bin/xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || true)
    if test -x "$clang_path" && test -d "$sdk_path"; then
        "$clang_path" -fsyntax-only -fobjc-arc -target arm64-apple-ios12.0 \
            -isysroot "$sdk_path" -I"$root" -include system.h \
            "$source" >/dev/null 2>&1 ||
            fail "iPhoneOS syntax check failed"
        echo "[verify-window-appearance][ ok ] iPhoneOS helper syntax check"
    else
        echo "[verify-window-appearance][ ok ] iPhoneOS SDK unavailable; static contract checked"
    fi
else
    echo "[verify-window-appearance][ ok ] host is not Darwin; static contract checked"
fi

echo "[verify-window-appearance][ ok ] Automatic UIKit appearance remains the default"
echo "[verify-window-appearance][ ok ] exact legacy Light and Dark modes refresh safely"
echo "[verify-window-appearance][ ok ] tab bar follows live native Light and Dark chrome"
