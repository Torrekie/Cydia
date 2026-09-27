#!/bin/sh
# Copyright (C) 2026 Torrekie
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
script=$root/scripts/verify-build-provenance.sh

fail() {
    echo "[verify-build-provenance-contract][FAIL] $*" >&2
    exit 1
}

test -x "$script" || fail "provenance script is not executable"
command -v git >/dev/null 2>&1 || fail "git is required"
command -v strings >/dev/null 2>&1 || fail "strings is required"

temporary=$(mktemp -d "${TMPDIR:-/tmp}/cydia-build-provenance-test.XXXXXX")
cleanup() {
    rm -rf -- "$temporary"
}
trap cleanup EXIT HUP INT TERM

fixture=$temporary/source
binary=$temporary/MobileCydia
header=$temporary/Version.h
stamp=$temporary/MobileCydia.provenance
mkdir -p "$fixture"
cp "$root/version.sh" "$fixture/version.sh"
chmod +x "$fixture/version.sh"
printf '%s\n' '#define ForRelease 1' >"$fixture/MobileCydia.mm"

git -C "$fixture" init -q
git -C "$fixture" config user.name 'Cydia provenance test'
git -C "$fixture" config user.email 'cydia-provenance@example.invalid'
git -C "$fixture" add version.sh MobileCydia.mm
git -C "$fixture" commit -qm baseline

version=$(cd "$fixture" && ./version.sh)
printf 'fixture binary\n%s\n' "$version" >"$binary"
printf '#define CYDIA_VERSION "%s"\n' "$version" >"$header"

"$script" record "$fixture" "$binary" "$header" "$stamp" >/dev/null
test -s "$stamp" || fail "record did not create a provenance stamp"
stamp_hash=$(shasum -a 256 "$stamp" | awk '{ print $1 }')
"$script" verify "$fixture" "$binary" "$header" "$stamp" >/dev/null
test "$(shasum -a 256 "$stamp" | awk '{ print $1 }')" = "$stamp_hash" ||
    fail "verify modified the provenance stamp"

expect_failure() {
    label=$1
    needle=$2
    shift 2
    log=$temporary/$label.log
    if "$@" >"$log" 2>&1; then
        fail "$label unexpectedly passed"
    fi
    grep -F "$needle" "$log" >/dev/null ||
        fail "$label did not report: $needle"
}

printf '#define CYDIA_VERSION "%s-drift"\n' "$version" >"$header"
expect_failure header-drift 'Version.h version' \
    "$script" verify "$fixture" "$binary" "$header" "$stamp"
printf '#define CYDIA_VERSION "%s"\n' "$version" >"$header"

printf '%s\n' 'wrong binary' >"$binary"
expect_failure binary-drift 'app binary does not embed current source version' \
    "$script" verify "$fixture" "$binary" "$header" "$stamp"
printf 'fixture binary\n%s\n' "$version" >"$binary"

printf '%s\n' '// source drift' >>"$fixture/MobileCydia.mm"
expect_failure source-drift 'source tree mismatch' \
    "$script" verify "$fixture" "$binary" "$header" "$stamp"

echo "[verify-build-provenance-contract][ ok ] record/verify binds version, binary, and source tree"
