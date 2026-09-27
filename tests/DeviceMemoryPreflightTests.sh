#!/bin/sh
# Copyright (C) 2026 Torrekie
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
verifier=$root/scripts/verify-device-memory-preflight.sh
fixtures=$root/tests/fixtures/ui/device-memory-preflight
fake_ssh_path=$fixtures/fake-bin

fail() {
    echo "[verify-device-preflight-tests][FAIL] $*" >&2
    exit 1
}

expect_pass() {
    layout=$1
    fixture=$2
    "$verifier" --layout "$layout" --report "$fixtures/$fixture" >/dev/null ||
        fail "$fixture should pass as $layout"
}

expect_fail() {
    layout=$1
    fixture=$2
    if "$verifier" --layout "$layout" --report "$fixtures/$fixture" \
            >/dev/null 2>&1; then
        fail "$fixture should fail as $layout"
    fi
}

expect_pass rootless healthy-rootless.txt
expect_pass rootful healthy-rootful.txt
expect_pass rootless boundary-pass.txt
expect_fail rootful healthy-rootless.txt
expect_fail rootless healthy-rootful.txt
expect_fail rootless low-memory.txt
expect_fail rootless active-dpkg.txt
expect_fail rootless active-dpkg-helper.txt
expect_fail rootless impossible-memory.txt
expect_fail rootless missing-memory-percent-token.txt
expect_fail rootless duplicate-memory-percent-token.txt
expect_fail rootless fractional-swap-overflow.txt
expect_fail rootless duplicate-memory-values.txt
expect_fail rootless duplicate-swap-values.txt
expect_fail rootless duplicate-architecture-values.txt
expect_fail rootless duplicate-layout-values.txt
expect_fail rootless nonroot-uid.txt
expect_fail rootless unknown-section-marker.txt
expect_fail rootless extra-swap-output.txt
expect_fail rootless empty-processes.txt
expect_fail rootless malformed-processes.txt
expect_fail rootless malformed.txt
expect_fail rootless out-of-order.txt
expect_fail rootless boundary-fail.txt

offline_result=$($verifier --layout rootless --report "$fixtures/healthy-rootless.txt")
case "$offline_result" in
    *"offline root-UID rootless report validated"*"not current device evidence"*) ;;
    *) fail "offline validation must not claim current device evidence" ;;
esac

test_directory=$(mktemp -d "${TMPDIR:-/tmp}/cydia-preflight-tests.XXXXXX") ||
    fail "could not create test directory"
cleanup() {
    rm -rf "$test_directory"
}
on_signal() {
    trap - EXIT
    cleanup
    exit 1
}
trap cleanup EXIT
trap on_signal HUP INT TERM

live_report=$test_directory/live-report.txt
live_result=$(PATH="$fake_ssh_path:/usr/bin:/bin" \
    CYDIA_PREFLIGHT_FAKE_REPORT="$fixtures/healthy-rootless.txt" \
    CYDIA_PREFLIGHT_FAKE_TARGET=root@device.test \
    "$verifier" --layout rootless --host root@device.test \
        --output "$live_report") || fail "fake live collection should pass"
case "$live_result" in
    *"live root-UID rootless capture for root@device.test"*"no apt/dpkg/cydo process observed"*) ;;
    *) fail "live collection result is missing its bounded evidence label" ;;
esac
[ "$(grep -Fxc __CYDIA_CAPTURE__ "$live_report")" -eq 1 ] ||
    fail "live report is missing capture metadata"
grep -Fxq target=root@device.test "$live_report" ||
    fail "live report is missing its target"
grep -Eq '^captured_at_utc=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' \
    "$live_report" || fail "live report is missing its UTC capture time"

failure_report=$test_directory/failure-report.txt
printf '%s\n' sentinel >"$failure_report"
if PATH="$fake_ssh_path:/usr/bin:/bin" \
        CYDIA_PREFLIGHT_FAKE_REPORT="$fixtures/healthy-rootless.txt" \
        CYDIA_PREFLIGHT_FAKE_TARGET=root@device.test \
        CYDIA_PREFLIGHT_FAKE_MODE=fail \
        "$verifier" --layout rootless --host root@device.test \
            --output "$failure_report" >/dev/null 2>&1; then
    fail "failed SSH collection should fail"
fi
grep -Fxq sentinel "$failure_report" ||
    fail "failed SSH collection replaced its output"

hang_report=$test_directory/hang-report.txt
if PATH="$fake_ssh_path:/usr/bin:/bin" \
        CYDIA_PREFLIGHT_FAKE_REPORT="$fixtures/healthy-rootless.txt" \
        CYDIA_PREFLIGHT_FAKE_TARGET=root@device.test \
        CYDIA_PREFLIGHT_FAKE_MODE=hang \
        "$verifier" --layout rootless --host root@device.test \
            --output "$hang_report" --timeout-seconds 1 >/dev/null 2>&1; then
    fail "hanging SSH collection should time out"
fi
[ ! -e "$hang_report" ] || fail "timed-out SSH collection persisted partial output"

echo "[verify-device-preflight-tests][ ok ] fail-closed parser and bounded fake-SSH collection"
