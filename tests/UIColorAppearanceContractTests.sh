#!/bin/sh
# Cydia semantic-color contract for iOS 12 fallbacks and iOS 13+ traits.
# Copyright (C) 2026 Torrekie
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source="$root/Cydia/UIColor+Cydia.m"

fail() {
    echo "[verify-ui-color][FAIL] $*" >&2
    exit 1
}

test -f "$source" || fail "UIColor+Cydia.m is missing"

fixed=$(sed -n '/static UIColor \*FixedColor/,/^}/p' "$source")
printf '%s\n' "$fixed" | grep -Fq 'case CydiaColorRoleErrorLabel:' ||
    fail "fixed error role is missing"
printf '%s\n' "$fixed" | grep -Fq 'dark ? RGBA8(255, 105, 97, 255) : RGBA8(176, 0, 32, 255)' ||
    fail "error role does not retain calibrated Light/Dark fallback colors"

dynamic=$(sed -n '/static UIColor \*DynamicColor/,/^}/p' "$source")
error_case=$(printf '%s\n' "$dynamic" | awk '
    /case CydiaColorRoleErrorLabel:/ { inside = 1 }
    inside { print }
    inside && /return CustomDynamicColor\(role\);/ { exit }
')
printf '%s\n' "$error_case" | grep -Fq 'return CustomDynamicColor(role);' ||
    fail "dynamic error role does not use the calibrated trait-driven fallback"
if printf '%s\n' "$error_case" | grep -Fq '@selector(systemRedColor)'; then
    fail "dynamic error role still uses low-contrast systemRedColor"
fi

grep -Fq 'CydiaColorRoleErrorLabel' "$source" ||
    fail "error role is not declared in the color implementation"
echo "[verify-ui-color][ ok ] Light/Dark error role uses the iOS12-compatible trait-driven fallback"
