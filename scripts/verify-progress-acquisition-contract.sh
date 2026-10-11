#!/bin/sh
# Copyright (C) 2026 Torrekie
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
database=$root/Cydia/Database.mm
status=$root/Cydia/DatabaseStatus.mm
controller=$root/Cydia/ProgressController.mm

fail() {
    echo "[verify-progress-acquisition][FAIL] $*" >&2
    exit 1
}

work=$(mktemp "${TMPDIR:-/tmp}/cydia-progress-acquisition.XXXXXX")
cleanup() {
    rm -f -- "$work"
}
trap cleanup EXIT HUP INT TERM

sed -n '/^- (bool) perform {/,/^- (bool) delocked/p' "$database" >"$work"

line() {
    result=$(grep -n -F "$1" "$work" | sed -n '1s/:.*//p')
    test -n "$result" || fail "missing Database perform boundary: $1"
    printf '%s\n' "$result"
}

test "$(grep -c -F '@selector(retainNetworkActivityIndicator)' "$work")" -eq 1 ||
    fail "Database perform must retain exactly one network activity lease"
test "$(grep -c -F '@selector(releaseNetworkActivityIndicator)' "$work")" -eq 1 ||
    fail "Database perform must release exactly one network activity lease"

retain=$(line '@selector(retainNetworkActivityIndicator)')
fetch=$(line 'CydiaAPT::FetchResultData fetch(apt_->runFetcher(PulseInterval_));')
release=$(line '@selector(releaseNetworkActivityIndicator)')
incomplete=$(line 'if (!fetch.completed) {')
failures=$(line 'if (!fetch.failures.empty() || !requireUnchanged()) return false;')

test "$retain" -lt "$fetch" && test "$fetch" -lt "$release" &&
    test "$release" -lt "$incomplete" && test "$incomplete" -lt "$failures" ||
    fail "network activity lease is not balanced before every acquisition exit"

grep -Fq 'return ![delegate_ isProgressCancelled];' "$status" ||
    fail "pkgAcquire Pulse no longer consumes native cancellation"
grep -Fq '@selector(setProgressCancellable:) withObject:[NSNumber numberWithBool:YES]' "$status" ||
    fail "pkgAcquire Start no longer exposes native Cancel"
grep -Fq '@selector(setProgressCancellable:) withObject:[NSNumber numberWithBool:NO]' "$status" ||
    fail "pkgAcquire Stop no longer retires native Cancel"
grep -A3 '^- (void) cancel {' "$controller" |
    grep -Fq '[progressModel_ requestCancellation];' ||
    fail "native Cancel no longer reaches the progress model"

echo "[verify-progress-acquisition][ ok ] cancellation stops acquisition before a balanced exit"
