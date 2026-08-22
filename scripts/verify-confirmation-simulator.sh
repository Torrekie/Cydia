#!/bin/sh
# Copyright (C) 2026 Torrekie
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
    echo "usage: $0 SIMULATOR_UDID MAKE [BUILD_DIR]" >&2
    exit 2
fi

simulator=$1
make_program=$2
build_dir=${3-build/confirmation-simulator}
source_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P) || exit 2
case "$build_dir" in
    /*) ;;
    *) build_dir=$source_root/$build_dir ;;
esac

bundle_id=com.saurik.Cydia.ConfirmationProbe.$$
artifact_dir=$build_dir/confirmation-artifacts
temporary=$(mktemp -d "${TMPDIR:-/tmp}/cydia-confirmation.XXXXXX")
probe_app=$temporary/CydiaConfirmationProbe.app

fail() {
    echo "[verify-confirmation-simulator][FAIL] $*" >&2
    exit 1
}

pass() {
    echo "[verify-confirmation-simulator][ ok ] $*"
}

run_with_timeout() {
    seconds=$1
    shift
    "$@" &
    command_pid=$!
    (
        remaining=$seconds
        while [ "$remaining" -gt 0 ] && kill -0 "$command_pid" 2>/dev/null; do
            sleep 1
            remaining=$((remaining - 1))
        done
        if kill -0 "$command_pid" 2>/dev/null; then
            kill -TERM "$command_pid" 2>/dev/null || true
            sleep 1
            kill -KILL "$command_pid" 2>/dev/null || true
        fi
    ) &
    watchdog=$!
    wait "$command_pid"
    status=$?
    kill "$watchdog" 2>/dev/null || true
    wait "$watchdog" 2>/dev/null || true
    return "$status"
}

simctl() {
    seconds=$1
    shift
    run_with_timeout "$seconds" xcrun simctl "$@"
}

cleanup() {
    simctl 10 terminate "$simulator" "$bundle_id" >/dev/null 2>&1 || true
    simctl 10 uninstall "$simulator" "$bundle_id" >/dev/null 2>&1 || true
    rm -rf -- "$temporary"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

read_state() {
    plutil -extract "$2" raw -o - "$1" 2>/dev/null
}

wait_for_state() {
    file=$1
    phase=$2
    style=$3
    attempts=0
    while [ "$attempts" -lt 160 ]; do
        if [ -f "$file" ]; then
            ready=$(read_state "$file" ready || true)
            actual_phase=$(read_state "$file" phase || true)
            actual_style=$(read_state "$file" style || true)
            if [ "$ready" = "true" ] && [ "$actual_phase" = "$phase" ] &&
               [ "$actual_style" = "$style" ]; then
                return 0
            fi
        fi
        attempts=$((attempts + 1))
        sleep 0.25
    done
    [ ! -f "$file" ] || plutil -p "$file" >&2 || true
    return 1
}

wait_for_value() {
    file=$1
    key=$2
    expected=$3
    attempts=0
    while [ "$attempts" -lt 80 ]; do
        actual=$(read_state "$file" "$key" || true)
        [ "$actual" = "$expected" ] && return 0
        attempts=$((attempts + 1))
        sleep 0.25
    done
    return 1
}

assert_state() {
    file=$1
    key=$2
    expected=$3
    message=$4
    actual=$(read_state "$file" "$key" || true)
    [ "$actual" = "$expected" ] || fail "$message ($key=$actual, expected=$expected)"
}

assert_equal() {
    file=$1
    left=$2
    right=$3
    message=$4
    left_value=$(read_state "$file" "$left" || true)
    right_value=$(read_state "$file" "$right" || true)
    [ "$left_value" = "$right_value" ] ||
        fail "$message ($left=$left_value, $right=$right_value)"
}

assert_array_contains() {
    file=$1
    key=$2
    value=$3
    message=$4
    plutil -p "$file" | grep -F "\"$value\"" >/dev/null ||
        fail "$message ($key did not contain $value)"
}

rm -rf -- "$artifact_dir"
mkdir -p "$artifact_dir"
"$make_program" --no-print-directory -j6 -C "$source_root" \
    doIA=yes BUILD_DIR="$build_dir" all >"$artifact_dir/build.log" 2>&1 || {
        grep -n -E 'error:|fatal error:|undefined reference|ld:|make: \*\*\*' \
            "$artifact_dir/build.log" | head -100 >&2 || true
        fail "simulator Make build failed; see $artifact_dir/build.log"
    }
pass "Make produced the x86_64 simulator application"

cp -a "$source_root/MobileCydia.app" "$probe_app"
cp "$build_dir/bin/MobileCydia" "$probe_app/Cydia"
plutil -replace CFBundleIdentifier -string "$bundle_id" "$probe_app/Info.plist"
plutil -lint "$probe_app/Info.plist" >/dev/null || fail "probe Info.plist is invalid"

simctl 20 terminate "$simulator" "$bundle_id" >/dev/null 2>&1 || true
simctl 20 uninstall "$simulator" "$bundle_id" >/dev/null 2>&1 || true
simctl 40 install "$simulator" "$probe_app" >"$artifact_dir/install.log" 2>&1 ||
    fail "could not install confirmation probe"
simctl 30 launch --stdout="$artifact_dir/stdout.log" --stderr="$artifact_dir/stderr.log" \
    "$simulator" "$bundle_id" --cydia-appearance-probe --cydia-confirmation-probe \
    >"$artifact_dir/launch.log" 2>&1 || fail "could not launch confirmation probe"

data_container=$(simctl 20 get_app_container "$simulator" "$bundle_id" data) ||
    fail "could not locate probe data container"
state=$data_container/tmp/cydia-confirmation-probe.plist
wait_for_state "$state" normal light || fail "normal light state did not become ready"

assert_state "$state" sections 3 "legacy queue/statistics/modifications hierarchy did not render"
assert_state "$state" sectionKinds.0 queue "Continue Queuing is not the first fieldset"
assert_state "$state" sectionKinds.1 statistics "Statistics did not follow Continue Queuing"
assert_state "$state" sectionKinds.2 modifications "Modifications did not follow Statistics"
assert_state "$state" hasConfirm true "normal transaction lost Confirm"
assert_state "$state" hasCancel true "normal transaction lost Cancel"
assert_state "$state" hasCannotComplyHeader false "normal transaction showed an issue header"
assert_state "$state" hasQualifiedCell true "foreign package identity was normalized"
assert_state "$state" modificationRowCount 5 \
    "Modifications did not retain one row per legacy operation"
assert_equal "$state" installTitle expectedInstallTitle \
    "Install operation title was not localized through the production path"
assert_state "$state" installDetail "Runtime Native" \
    "Install operation lost its legacy multiline detail column"
assert_state "$state" downloadingDetail "4.0 kB" \
    "Downloading size drifted from the legacy formatter"
assert_state "$state" resumingDetail "1024.0 B" \
    "Resuming size drifted from the legacy formatter"
assert_state "$state" queueAccessory 1 \
    "Continue Queuing lost the legacy disclosure affordance"
assert_state "$state" visibleWebViews 0 "native confirmation contains a WebView"
assert_state "$state" visibleRowsFit true "normal confirmation rows clip their labels"
assert_state "$state" navigationBarHidden false "normal confirmation navigation bar is hidden"
[ "$(read_state "$state" continueTitle)" != "" ] ||
    fail "Continue Queuing action is absent"
assert_equal "$state" continueTitle expectedContinueTitle \
    "Continue Queuing title was not localized through the production path"
cp "$state" "$artifact_dir/normal-light-state.plist"
sleep 1
simctl 30 io "$simulator" screenshot "$artifact_dir/normal-light.png" >/dev/null ||
    fail "could not capture normal light screenshot"

light_luminance=$(read_state "$state" backgroundLuminance)
: >"$data_container/tmp/cydia-confirmation-probe-issues"
wait_for_state "$state" issues light || fail "light issue state did not become ready"
assert_state "$state" hasConfirm false "blocking issue exposed Confirm"
assert_state "$state" hasCancel true "blocking issue lost Cancel"
assert_state "$state" hasCannotComplyHeader true "blocking issue lost CANNOT_COMPLY"
assert_state "$state" sections 4 "legacy issue/queue/modifications/detail hierarchy did not render"
assert_state "$state" sectionKinds.0 issue-notice "dependency note is not first"
assert_state "$state" sectionKinds.1 queue "Continue Queuing did not follow dependency note"
assert_state "$state" sectionKinds.2 modifications "Modifications did not precede issue details"
assert_state "$state" sectionKinds.3 issue-details "dependency fieldset is missing"
assert_state "$state" issueHeaderAccessibilityIdentity consumer:iphoneos-arm64 \
    "issue header lost the qualified package identity"
assert_state "$state" issueRelationship Depends \
    "dependency row lost its legacy relationship label"
assert_state "$state" issueDetail "runtime:any >=2:1.0" \
    "dependency row drifted from the legacy target/version rendering"
assert_state "$state" visibleRowsFit true "blocking issue rows clip their labels"
assert_array_contains "$state" cellValues \
    "foreign-package:iphoneos-arm" \
    "issue view lost qualified package identity"
cp "$state" "$artifact_dir/issues-light-state.plist"
sleep 1
simctl 30 io "$simulator" screenshot "$artifact_dir/issues-light.png" >/dev/null ||
    fail "could not capture light issue screenshot"

: >"$data_container/tmp/cydia-confirmation-probe-dark"
wait_for_state "$state" issues dark || fail "live dark issue state did not become ready"
cp "$state" "$artifact_dir/issues-dark-state.plist"
sleep 1
simctl 30 io "$simulator" screenshot "$artifact_dir/issues-dark.png" >/dev/null ||
    fail "could not capture dark issue screenshot"

: >"$data_container/tmp/cydia-confirmation-probe-normal"
wait_for_state "$state" normal dark || fail "normal dark state did not become ready"
dark_luminance=$(read_state "$state" backgroundLuminance)
[ "$light_luminance" -gt "$dark_luminance" ] ||
    fail "confirmation background did not respond to the live dark trait"
cp "$state" "$artifact_dir/normal-dark-state.plist"
sleep 1
simctl 30 io "$simulator" screenshot "$artifact_dir/normal-dark.png" >/dev/null ||
    fail "could not capture normal dark screenshot"

: >"$data_container/tmp/cydia-confirmation-probe-accessibility"
wait_for_state "$state" normal-accessibility dark ||
    fail "accessibility state did not become ready"
assert_equal "$state" contentSizeCategory expectedAccessibilityContentSizeCategory \
    "confirmation did not apply Accessibility Large"
assert_state "$state" visibleRowsFit true "Accessibility Large clips confirmation labels"
assert_state "$state" navigationBarHidden false \
    "Accessibility Large hides the confirmation navigation bar"
cp "$state" "$artifact_dir/normal-dark-accessibility-state.plist"
sleep 1
simctl 30 io "$simulator" screenshot "$artifact_dir/normal-dark-accessibility.png" >/dev/null ||
    fail "could not capture accessibility screenshot"

for action in confirm continue cancel; do
    : >"$data_container/tmp/cydia-confirmation-probe-normal-$action"
    wait_for_state "$state" "normal-$action" dark ||
        fail "$action action state did not become ready"
    : >"$data_container/tmp/cydia-confirmation-probe-$action"
    case "$action" in
        confirm) expected=confirm ;;
        continue) expected=continue-queuing ;;
        cancel) expected=cancel-clear ;;
    esac
    wait_for_value "$state" lastAction "$expected" ||
        fail "$action did not dispatch the expected production delegate outcome"
    if [ "$action" = continue ]; then
        assert_state "$state" lastInteraction queue-selection \
            "Continue Queuing bypassed the installed table-row interaction path"
    fi
done

: >"$data_container/tmp/cydia-confirmation-probe-essential-blocked"
wait_for_state "$state" essential-blocked dark ||
    fail "essential blocked state did not become ready"
assert_state "$state" hasConfirm true "essential blocked transaction lost Confirm"
: >"$data_container/tmp/cydia-confirmation-probe-confirm"
attempts=0
while [ "$attempts" -lt 80 ]; do
    alert=$(read_state "$state" alertVisible || true)
    [ "$alert" = "true" ] && break
    attempts=$((attempts + 1))
    sleep 0.25
done
assert_state "$state" alertVisible true "blocked essential confirmation did not present an alert"
[ "$(read_state "$state" alertActionCount)" -ge 1 ] ||
    fail "blocked essential alert has no acknowledgement action"
cp "$state" "$artifact_dir/essential-blocked-alert-state.plist"
sleep 1
simctl 30 io "$simulator" screenshot "$artifact_dir/essential-blocked-alert.png" >/dev/null ||
    fail "could not capture essential alert screenshot"

: >"$data_container/tmp/cydia-confirmation-probe-essential-force"
wait_for_state "$state" essential-force dark ||
    fail "essential force state did not become ready"
: >"$data_container/tmp/cydia-confirmation-probe-confirm"
wait_for_value "$state" alertVisible true ||
    fail "advanced essential confirmation did not present an alert"
assert_state "$state" alertActionCount 2 \
    "advanced essential alert did not preserve safe cancel and unsafe force actions"
cp "$state" "$artifact_dir/essential-force-alert-state.plist"
sleep 1
simctl 30 io "$simulator" screenshot "$artifact_dir/essential-force-alert.png" >/dev/null ||
    fail "could not capture advanced essential alert screenshot"

pass "installed controller preserved grouped transaction UI, delegate outcomes, multiarch identity, live color, Dynamic Type, issue blocking, and essential warning chrome"
echo "[verify-confirmation-simulator][evidence] $artifact_dir"
