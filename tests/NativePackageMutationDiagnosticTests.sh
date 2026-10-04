#!/bin/sh
# Copyright (C) 2026 Torrekie
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ "$(uname -s)" != Darwin ]; then
    echo '[native-package-mutation-diagnostic][skip] Foundation host test requires macOS'
    exit 0
fi
scratch=$(mktemp -d "${TMPDIR:-/tmp}/cydia-package-driver.XXXXXX")
cleanup() {
    rm -f "$scratch/NativePackageMutationDiagnostic.inc" "$scratch/tests"
    rmdir "$scratch"
}
trap cleanup EXIT HUP INT TERM
data=$root/Cydia/NativeMutationDiagnostic.mm
sed -n '/^BOOL CydiaNativeCompatibilityB17FixtureRequested(/,/^}/p' "$data" > "$scratch/NativePackageMutationDiagnostic.inc"
sed -n '/^NSString \*CydiaNativeCompatibilityMutationDiagnosticOperationForValue(/,/^}/p' "$data" >> "$scratch/NativePackageMutationDiagnostic.inc"
sed -n '/^NSString \*CydiaNativeCompatibilityMutationDiagnosticPackageIdentifier(/,/^}/p' "$data" >> "$scratch/NativePackageMutationDiagnostic.inc"
sed -n '/^Package \*CydiaNativeCompatibilityMutationDiagnosticPackage(/,/^}/p' "$data" >> "$scratch/NativePackageMutationDiagnostic.inc"
sed -n '/^BOOL CydiaNativeCompatibilityMutationDiagnosticPreparePackage(/,/^}/p' "$data" >> "$scratch/NativePackageMutationDiagnostic.inc"
test "$(rg -c '^((NSString|Package) \*|BOOL )Cydia' "$scratch/NativePackageMutationDiagnostic.inc")" = 5
compiler=$(xcrun --sdk macosx --find clang++)
sdk=$(xcrun --sdk macosx --show-sdk-path)
"$compiler" -std=c++17 -fobjc-arc -fblocks -isysroot "$sdk" -framework Foundation \
    -I "$scratch" "$root/tests/NativePackageMutationDiagnosticTests.mm" -o "$scratch/tests"
"$scratch/tests"
