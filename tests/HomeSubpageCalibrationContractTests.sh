#!/bin/sh
# Finite native Home-subpage calibration contract.
# Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later

set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
fail() { echo "[home-subpages][FAIL] $*" >&2; exit 1; }

# Reuse the existing frozen-content and controller contracts for every
# authored guide page rather than creating a second content/evidence model.
sh "$root/tests/HomeGuideControllerContractTests.sh"
sh "$root/tests/CopyingFilesGuideControllerContractTests.sh"
sh "$root/tests/FAQControllerContractTests.sh"

storage="$root/Cydia/HomeStorageController.mm"
test -f "$storage" || fail "Home Storage controller is missing"
for token in \
    'UITableViewStyleGrouped' 'UITableViewAutomaticDimension' \
    'traitCollectionDidChange' 'CydiaColorAppearanceDidChange' \
    'CydiaColorRoleCellBackground' 'CydiaColorRoleSecondaryLabel' \
    'statfs("/"' 'statfs("/private/var"' 'cydia://home/storage' \
    'CydiaCaptureNativeAccessibility'; do
    grep -Fq "$token" "$storage" || fail "Storage native contract missing: $token"
done
if grep -Eq 'WKWebView|UIWebView|performSelector:|NSTask|system\(|installPackages|runCommand' \
        "$storage"; then
    fail "Storage subpage retains a web or command execution path"
fi

for route in \
    'cydia://home/faq' 'cydia://home/copying-files' \
    'cydia://home/openssh' 'cydia://home/root-password' \
    'cydia://home/storage' 'cydia://home/developer-resources' \
    'cydia://home/credits' 'cydia://home/privacy'; do
    grep -Fq "$route" "$root/Cydia/HomeController.mm" \
        || fail "Home route missing: $route"
done

echo '[home-subpages][ ok ] FAQ, copying, guide, storage, and route calibration contracts'
