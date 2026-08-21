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
build_dir=${3-build/progress-simulator}
source_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P) || exit 2
case "$build_dir" in
    /*) ;;
    *) build_dir=$source_root/$build_dir ;;
esac

bundle_id=com.saurik.Cydia.ProgressProbe.$$
artifact_dir=$build_dir/progress-artifacts
temporary=$(mktemp -d "${TMPDIR:-/tmp}/cydia-progress.XXXXXX")
probe_app=$temporary/CydiaProgressProbe.app

fail() {
    echo "[verify-progress-simulator][FAIL] $*" >&2
    exit 1
}

pass() {
    echo "[verify-progress-simulator][ ok ] $*"
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
    fail "could not install progress probe"
simctl 30 launch --stdout="$artifact_dir/stdout.log" --stderr="$artifact_dir/stderr.log" \
    "$simulator" "$bundle_id" --cydia-appearance-probe --cydia-progress-probe \
    >"$artifact_dir/launch.log" 2>&1 || fail "could not launch progress probe"

data_container=$(simctl 20 get_app_container "$simulator" "$bundle_id" data) ||
    fail "could not locate probe data container"
state=$data_container/tmp/cydia-progress-probe.plist
wait_for_state "$state" running light || fail "running light state did not become ready"

[ "$(read_state "$state" rows)" = "5" ] || fail "event table did not render five ordered rows"
assert_equal "$state" rows modelEvents "table/model event counts differ"
assert_equal "$state" title expectedTitle "native title diverged from immutable state"
assert_equal "$state" status expectedStatus "native status diverged from immutable state"
[ "$(read_state "$state" status)" = "Downloading Runtime Native" ] ||
    fail "qualified status identity was not display-name substituted"
assert_equal "$state" firstVisibleText firstEvent \
    "first event row diverged from the ordered model"
assert_equal "$state" carriageReturnVisibleText expectedCarriageReturnVisibleText \
    "terminal CR output was not normalized by the installed controller"
[ "$(read_state "$state" carriageReturnVisibleText)" = "Configuring files" ] ||
    fail "terminal CR fixture did not retain its final visible line"
[ "$(read_state "$state" multiarchIdentity)" = "runtime:iphoneos-arm64" ] ||
    fail "qualified package identity was lost"
[ "$(read_state "$state" multiarchCellIdentifier)" = \
    "cydia.progress.event.runtime:iphoneos-arm64" ] ||
    fail "event cell did not retain its qualified package identity"
[ "$(read_state "$state" visibleWebViews)" = "0" ] ||
    fail "native progress hierarchy contains a WebView"
assert_equal "$state" warningVisibleText expectedWarningVisibleText \
    "Warning lost its localized visible type affordance"
assert_equal "$state" unknownVisibleText expectedUnknownVisibleText \
    "unknown event lost its raw type affordance"
assert_equal "$state" unknownCellAccessibilityLabel expectedUnknownAccessibilityLabel \
    "VoiceOver lost the unknown event's raw type"
assert_equal "$state" errorVisibleText expectedErrorVisibleText \
    "Error lost its localized visible type affordance"
[ "$(read_state "$state" warningUsesSemanticColor)" = "true" ] &&
[ "$(read_state "$state" errorUsesSemanticColor)" = "true" ] ||
    fail "Warning/Error rows do not use their semantic colors"
[ "$(read_state "$state" titleAdjustsFont)" = "true" ] &&
[ "$(read_state "$state" statusAdjustsFont)" = "true" ] ||
    fail "progress title/status do not participate in Dynamic Type"
[ "$(read_state "$state" cancelTitle)" != "" ] || fail "running cancel action is absent"
[ "$(read_state "$state" finishTitle)" = "" ] || fail "finish action appeared while running"
light_luminance=$(read_state "$state" backgroundLuminance)
last_height=$(read_state "$state" lastRowHeight)
[ "$last_height" -gt 56 ] || fail "long event row did not self-size"
error_height=$(read_state "$state" errorMessageHeight)
error_required_height=$(read_state "$state" errorRequiredHeight)
[ $((error_height + 1)) -ge "$error_required_height" ] ||
    fail "long event text is clipped at the default content size"
assert_equal "$state" progressAccessibilityLabel expectedRunningAccessibilityLabel \
    "running progress accessibility label changed"
assert_equal "$state" progressAccessibilityValue expectedProgressAccessibilityValue \
    "running progress accessibility value changed"
assert_equal "$state" contentSizeCategory expectedDefaultContentSizeCategory \
    "running light probe did not use the default content size"
default_last_height=$last_height
default_error_point_size=$(read_state "$state" errorPointSize)
cp "$state" "$artifact_dir/running-light-default-state.plist"
sleep 1
simctl 30 io "$simulator" screenshot "$artifact_dir/running-light-default.png" >/dev/null ||
    fail "could not capture running light screenshot"

: >"$data_container/tmp/cydia-progress-probe-dark"
wait_for_state "$state" running dark || fail "live dark trait state did not become ready"
dark_luminance=$(read_state "$state" backgroundLuminance)
[ "$light_luminance" -gt "$dark_luminance" ] ||
    fail "progress background did not respond to the live dark trait"
assert_equal "$state" contentSizeCategory expectedDefaultContentSizeCategory \
    "running dark probe did not use the default content size"
cp "$state" "$artifact_dir/running-dark-default-state.plist"
sleep 1
simctl 30 io "$simulator" screenshot "$artifact_dir/running-dark-default.png" >/dev/null ||
    fail "could not capture running dark screenshot"

: >"$data_container/tmp/cydia-progress-probe-accessibility"
wait_for_state "$state" running-accessibility dark ||
    fail "Accessibility Large state did not become ready"
assert_equal "$state" contentSizeCategory expectedAccessibilityContentSizeCategory \
    "probe did not apply Accessibility Large"
accessibility_last_height=$(read_state "$state" lastRowHeight)
accessibility_error_point_size=$(read_state "$state" errorPointSize)
[ "$accessibility_last_height" -gt "$default_last_height" ] ||
    fail "Accessibility Large did not expand the long event row"
awk -v accessibility="$accessibility_error_point_size" -v normal="$default_error_point_size" \
    'BEGIN { exit !(accessibility > normal) }' ||
    fail "Accessibility Large did not increase the event font"
accessibility_error_height=$(read_state "$state" errorMessageHeight)
accessibility_error_required_height=$(read_state "$state" errorRequiredHeight)
[ $((accessibility_error_height + 1)) -ge "$accessibility_error_required_height" ] ||
    fail "Accessibility Large event text is clipped"
cp "$state" "$artifact_dir/running-dark-accessibility-large-state.plist"
sleep 1
simctl 30 io "$simulator" screenshot \
    "$artifact_dir/running-dark-accessibility-large.png" >/dev/null ||
    fail "could not capture Accessibility Large screenshot"

: >"$data_container/tmp/cydia-progress-probe-finish"
wait_for_state "$state" complete dark || fail "completed state did not become ready"
[ "$(read_state "$state" cancelTitle)" = "" ] || fail "cancel action remained after completion"
assert_equal "$state" finishTitle expectedFinishTitle "finish action title diverged from state"
assert_equal "$state" progressAccessibilityLabel expectedCompleteAccessibilityLabel \
    "completed progress accessibility still announces Running"
assert_equal "$state" progressAccessibilityValue expectedProgressAccessibilityValue \
    "completed progress accessibility value omits its finish action"
[ "$(read_state "$state" rows)" = "5" ] ||
    fail "completion discarded or reordered the in-process event log"
complete_error_height=$(read_state "$state" errorMessageHeight)
complete_error_required_height=$(read_state "$state" errorRequiredHeight)
[ $((complete_error_height + 1)) -ge "$complete_error_required_height" ] ||
    fail "completion redraw clipped the terminal diagnostic"
assert_equal "$state" contentSizeCategory expectedDefaultContentSizeCategory \
    "completed parity screenshot did not return to the default content size"
cp "$state" "$artifact_dir/complete-dark-default-state.plist"
sleep 1
simctl 30 io "$simulator" screenshot "$artifact_dir/complete-dark-default.png" >/dev/null ||
    fail "could not capture completed dark screenshot"

pass "installed controller preserved order, multiarch identity, live color, default parity, Dynamic Type, and completion accessibility"
echo "[verify-progress-simulator][evidence] $artifact_dir"
