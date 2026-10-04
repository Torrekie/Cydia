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
background_bundle_id=com.apple.Preferences
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

remove_probe() {
    simctl 10 terminate "$simulator" "$bundle_id" >/dev/null 2>&1 || true
    simctl 10 uninstall "$simulator" "$bundle_id" >/dev/null 2>&1 || true
}

cleanup() {
    original_status=$?
    cleanup_status=0
    trap - EXIT HUP INT TERM
    remove_probe
    if simctl 10 get_app_container "$simulator" "$bundle_id" app >/dev/null 2>&1 ||
       simctl 10 get_app_container "$simulator" "$bundle_id" data >/dev/null 2>&1; then
        echo "[verify-progress-simulator][cleanup] stale CoreSimulator registration; rebooting only $simulator" >&2
        simctl 30 shutdown "$simulator" >"$artifact_dir/cleanup-reboot.log" 2>&1 || true
        simctl 30 boot "$simulator" >>"$artifact_dir/cleanup-reboot.log" 2>&1 || true
        simctl 90 bootstatus "$simulator" -b >>"$artifact_dir/cleanup-reboot.log" 2>&1 ||
            cleanup_status=1
    fi
    if simctl 10 get_app_container "$simulator" "$bundle_id" app >/dev/null 2>&1 ||
       simctl 10 get_app_container "$simulator" "$bundle_id" data >/dev/null 2>&1; then
        echo "[verify-progress-simulator][cleanup] probe registration remains" >&2
        cleanup_status=1
    fi
    rm -rf -- "$temporary"
    if [ "$original_status" -eq 0 ] && [ "$cleanup_status" -ne 0 ]; then
        original_status=$cleanup_status
    fi
    exit "$original_status"
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

assert_state() {
    file=$1
    key=$2
    expected=$3
    message=$4
    actual=$(read_state "$file" "$key" || true)
    [ "$actual" = "$expected" ] ||
        fail "$message ($key=$actual, expected=$expected)"
}

assert_files_equal() {
    left_file=$1
    right_file=$2
    key=$3
    message=$4
    left_value=$(read_state "$left_file" "$key" || true)
    right_value=$(read_state "$right_file" "$key" || true)
    [ "$left_value" = "$right_value" ] ||
        fail "$message ($key changed from $left_value to $right_value)"
}

assert_real_form_sheet() {
    form_state=$1
    assert_state "$form_state" formSheetPresentation true \
        "Progress did not retain its requested form-sheet style"
    assert_state "$form_state" requestedPresentationStyle formSheet \
        "UIKit did not create the requested form-sheet presentation controller"
    assert_state "$form_state" navigationDepth 2 \
        "Progress form-sheet navigation depth changed"
    assert_state "$form_state" progressIsTopController true \
        "Progress is not the top form-sheet controller"
    assert_state "$form_state" confirmationPlaceholderIsRoot true \
        "the Confirmation placeholder is not the form-sheet navigation root"
    assert_state "$form_state" confirmationPlaceholderUsesCellBackground true \
        "the Confirmation placeholder lost its independent elevated surface"
    assert_state "$form_state" terminalCanvasUsesFixedPalette true \
        "form-sheet Progress did not retain its fixed terminal canvas"
    assert_state "$form_state" eventCellsUseTerminalSurface true \
        "form-sheet Progress event rows did not retain the terminal canvas"
    assert_equal "$form_state" confirmationPlaceholderIdentifier \
        expectedConfirmationPlaceholderIdentifier \
        "the Confirmation placeholder identity changed"
    [ -n "$(read_state "$form_state" confirmationPlaceholderTitle)" ] ||
        fail "the Confirmation placeholder lost its navigation title"
    assert_state "$form_state" actualModalPresentation true \
        "Progress probe did not use a real modal presentation controller"
    form_size_class=$(read_state "$form_state" horizontalSizeClass)
    case "$form_size_class" in
        regular)
            assert_state "$form_state" presentationAttached true \
                "Progress form sheet is not attached to the presenter window"
            assert_state "$form_state" presenterUsesGroupedBackground true \
                "regular-width form-sheet presenter did not use its grouped surface"
            assert_state "$form_state" formSheetFrameInset true \
                "regular-width Progress form sheet is not inset"
            assert_state "$form_state" backdropInterceptsOutsideSheet true \
                "regular-width Progress form sheet has no live dimming backdrop"
            assert_state "$form_state" dimmingEvidenceEligible true \
                "regular-width form sheet was not classified as closing dimming evidence"
            ;;
        compact)
            # UIKit adapts a requested form sheet to full-screen on compact
            # width. The canvas remains elevated, but there is no inset sheet
            # or closing dimming surface to claim as evidence.
            compact_adaptive=$(read_state "$form_state" adaptivePresentationStyle)
            case "$compact_adaptive" in
                none|fullScreen) ;;
                *) fail "compact Progress reported an unknown UIKit adaptation ($compact_adaptive)" ;;
            esac
            assert_state "$form_state" dimmingEvidenceEligible false \
                "compact adapted presentation was misclassified as closing dimming evidence"
            assert_state "$form_state" formSheetFrameInset false \
                "compact adapted Progress unexpectedly reported an inset sheet"
            assert_state "$form_state" backdropInterceptsOutsideSheet false \
                "compact adapted Progress unexpectedly reported a dimming backdrop"
            ;;
        *) fail "unknown presenter horizontal size class: $form_size_class" ;;
    esac
}

launch_pid() {
    sed -n "s/^$bundle_id: //p" "$1" | tail -n 1
}

rm -rf -- "$artifact_dir"
mkdir -p "$artifact_dir"
"$make_program" --no-print-directory -j1 -C "$source_root" \
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

remove_probe
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
    "Warning message diverged from the legacy event stream"
[ "$(read_state "$state" warningMarkerHidden)" = "false" ] &&
[ "$(read_state "$state" warningMarker)" != "" ] ||
    fail "Warning lost its visible non-color marker"
assert_equal "$state" unknownVisibleText expectedUnknownVisibleText \
    "unknown event lost its raw type affordance"
assert_equal "$state" unknownCellAccessibilityLabel expectedUnknownAccessibilityLabel \
    "VoiceOver lost the unknown event's raw type"
assert_equal "$state" errorVisibleText expectedErrorVisibleText \
    "Error message diverged from the legacy event stream"
[ "$(read_state "$state" errorMarkerHidden)" = "false" ] &&
[ "$(read_state "$state" errorMarker)" != "" ] ||
    fail "Error lost its visible non-color marker"
[ "$(read_state "$state" warningUsesSemanticColor)" = "true" ] &&
[ "$(read_state "$state" errorUsesSemanticColor)" = "true" ] ||
    fail "Warning/Error rows do not use their semantic colors"
[ "$(read_state "$state" statusAdjustsFont)" = "true" ] &&
[ "$(read_state "$state" finishAdjustsFont)" = "true" ] ||
    fail "progress controls do not participate in Dynamic Type"
[ "$(read_state "$state" statusUsesTerminalSecondaryColor)" = "true" ] &&
[ "$(read_state "$state" navigationUsesTerminalPalette)" = "true" ] &&
[ "$(read_state "$state" footerUsesTerminalBackground)" = "true" ] &&
[ "$(read_state "$state" progressUsesTerminalPalette)" = "true" ] &&
[ "$(read_state "$state" finishUsesTerminalLabelColor)" = "true" ] ||
    fail "Progress status, navigation, footer, or controls left the terminal palette"
[ "$(read_state "$state" preferredStatusBarStyle)" = "1" ] ||
    fail "terminal Progress did not retain light status-bar content"
[ "$(read_state "$state" eventTableAboveFooter)" = "true" ] &&
[ "$(read_state "$state" footerInLowerHalf)" = "true" ] ||
    fail "event stream and bottom controls drifted from the legacy hierarchy"
[ "$(read_state "$state" cancelTitle)" != "" ] || fail "running cancel action is absent"
[ "$(read_state "$state" cancellationState)" = "1" ] ||
    fail "running progress did not expose an available cancellation state"
[ "$(read_state "$state" progressCancelled)" = "false" ] ||
    fail "running progress reported a pending cancellation"
[ "$(read_state "$state" finishTitle)" = "" ] || fail "finish action appeared while running"
[ "$(read_state "$state" finishButtonHidden)" = "true" ] ||
    fail "bottom finish action appeared while running"
light_luminance=$(read_state "$state" backgroundLuminance)
[ "$(read_state "$state" terminalCanvasUsesFixedPalette)" = "true" ] ||
    fail "full-screen light Progress did not use its fixed terminal palette"
[ "$(read_state "$state" eventCellsUseTerminalSurface)" = "true" ] ||
    fail "full-screen light Progress event rows did not use the terminal palette"
[ "$(read_state "$state" confirmationPlaceholderUsesCellBackground)" = "true" ] ||
    fail "full-screen Progress incorrectly claimed Confirmation placeholder ownership"
[ "$light_luminance" -eq "$(read_state "$state" expectedTerminalBackgroundLuminance)" ] ||
    fail "full-screen light Progress canvas is not terminal-dark"
[ "$(read_state "$state" formSheetPresentation)" = "false" ] ||
    fail "ordinary Progress unexpectedly entered form-sheet mode"
[ "$(read_state "$state" navigationDepth)" = "1" ] &&
[ "$(read_state "$state" progressIsTopController)" = "true" ] ||
    fail "ordinary Progress navigation shape changed"
last_height=$(read_state "$state" lastRowHeight)
[ "$last_height" -gt 30 ] || fail "long event row did not self-size"
message_line_spacing=$(read_state "$state" messageLineSpacing)
awk -v spacing="$message_line_spacing" 'BEGIN { exit !(spacing == 0) }' ||
    fail "default Progress event line spacing is not compact (messageLineSpacing=$message_line_spacing)"
error_line_spacing=$(read_state "$state" errorLineSpacing)
awk -v spacing="$error_line_spacing" 'BEGIN { exit !(spacing == 0) }' ||
    fail "default Progress diagnostic line spacing is not compact (errorLineSpacing=$error_line_spacing)"
default_message_line_height=$(read_state "$state" messageLineHeight)
default_message_max_line_height=$(read_state "$state" messageMaximumLineHeight)
default_message_min_line_height=$(read_state "$state" messageMinimumLineHeight)
awk -v line="$default_message_line_height" -v minimum="$default_message_min_line_height" \
    'BEGIN { exit !(line == minimum) }' ||
    fail "default Progress event minimum line height drifted from its font"
awk -v line="$default_message_line_height" -v maximum="$default_message_max_line_height" \
    'BEGIN { exit !(line == maximum) }' ||
    fail "default Progress event maximum line height drifted from its font"
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
[ "$light_luminance" -eq "$dark_luminance" ] ||
    fail "full-screen Progress canvas changed across system traits"
[ "$(read_state "$state" terminalCanvasUsesFixedPalette)" = "true" ] ||
    fail "full-screen dark Progress did not use its fixed terminal palette"
assert_equal "$state" contentSizeCategory expectedDefaultContentSizeCategory \
    "running dark probe did not use the default content size"
cp "$state" "$artifact_dir/running-dark-default-state.plist"
sleep 1
simctl 30 io "$simulator" screenshot "$artifact_dir/running-dark-default.png" >/dev/null ||
    fail "could not capture running dark screenshot"

: >"$data_container/tmp/cydia-progress-probe-form-sheet"
wait_for_value "$state" formSheetPresentation true ||
    fail "Progress did not enter the Confirmation form-sheet stack"
wait_for_state "$state" running dark ||
    fail "form-sheet Progress did not settle"
assert_real_form_sheet "$state"
form_sheet_luminance=$(read_state "$state" backgroundLuminance)
form_sheet_table_luminance=$(read_state "$state" tableBackgroundLuminance)
form_sheet_footer_luminance=$(read_state "$state" footerBackgroundLuminance)
expected_terminal_luminance=$(read_state "$state" expectedTerminalBackgroundLuminance)
expected_presenter_luminance=$(read_state "$state" expectedPresenterBackgroundLuminance)
presenter_luminance=$(read_state "$state" presenterBackgroundLuminance)
[ "$form_sheet_luminance" -eq "$form_sheet_table_luminance" ] &&
[ "$form_sheet_luminance" -eq "$form_sheet_footer_luminance" ] &&
[ "$form_sheet_luminance" -eq "$expected_terminal_luminance" ] ||
    fail "form-sheet Progress root, table, and footer are not one terminal-dark canvas"
[ "$presenter_luminance" -eq "$expected_presenter_luminance" ] ||
    fail "form-sheet presenter changed its independent grouped surface"
if [ "$(read_state "$state" horizontalSizeClass)" = "regular" ]; then
    form_sheet_artifact=running-dark-form-sheet
else
    form_sheet_artifact=running-dark-adapted-form-sheet-nonclosing
fi
cp "$state" "$artifact_dir/$form_sheet_artifact-state.plist"
sleep 1
simctl 30 io "$simulator" screenshot \
    "$artifact_dir/$form_sheet_artifact.png" >/dev/null ||
    fail "could not capture dark form-sheet Progress screenshot"

: >"$data_container/tmp/cydia-progress-probe-light"
wait_for_state "$state" running light ||
    fail "form-sheet Progress did not settle under a Light trait"
assert_real_form_sheet "$state"
[ "$(read_state "$state" backgroundLuminance)" = "$expected_terminal_luminance" ] ||
    fail "form-sheet Light Progress became a light canvas"
[ "$(read_state "$state" terminalCanvasUsesFixedPalette)" = "true" ] ||
    fail "form-sheet Light Progress lost its fixed terminal palette"
cp "$state" "$artifact_dir/running-light-form-sheet-state.plist"

: >"$data_container/tmp/cydia-progress-probe-dark"
wait_for_state "$state" running dark ||
    fail "form-sheet Progress did not restore its dark trait after Light check"

: >"$data_container/tmp/cydia-progress-probe-arm-lifecycle"
wait_for_value "$state" lifecycleArmed true ||
    fail "progress lifecycle observer did not arm"
wait_for_value "$state" lifecycleNotificationCount 0 ||
    fail "progress lifecycle observer did not start empty"
wait_for_state "$state" running dark ||
    fail "progress did not settle before backgrounding"
cp "$state" "$artifact_dir/running-dark-lifecycle-before-state.plist"
initial_pid=$(read_state "$state" processID)
simctl 30 launch "$simulator" "$background_bundle_id" \
    >"$artifact_dir/background-settings-launch.log" 2>&1 ||
    fail "could not foreground Settings to background progress"
wait_for_value "$state" lastLifecycleNotification UIApplicationDidEnterBackgroundNotification ||
    fail "progress did not receive the real background notification"
assert_state "$state" applicationState background \
    "progress did not reach UIApplicationStateBackground"
assert_state "$state" lifecycleNotificationCount 2 \
    "progress background notification count changed"
assert_state "$state" lifecycleNotifications.0 UIApplicationWillResignActiveNotification \
    "progress missed UIApplicationWillResignActiveNotification"
assert_state "$state" lifecycleNotifications.1 UIApplicationDidEnterBackgroundNotification \
    "progress missed UIApplicationDidEnterBackgroundNotification"
cp "$state" "$artifact_dir/running-dark-lifecycle-background-state.plist"
simctl 30 io "$simulator" screenshot \
    "$artifact_dir/running-dark-lifecycle-background-settings.png" >/dev/null ||
    fail "could not capture Settings while progress was backgrounded"
simctl 30 launch "$simulator" "$bundle_id" \
    >"$artifact_dir/foreground-launch.log" 2>&1 ||
    fail "could not foreground the running progress probe"
wait_for_value "$state" lifecycleComplete true ||
    fail "progress did not complete the real foreground transition"
wait_for_state "$state" running dark ||
    fail "form-sheet Progress did not become ready after foregrounding"
assert_real_form_sheet "$state"
assert_state "$state" applicationState active \
    "progress did not return to UIApplicationStateActive"
assert_state "$state" lifecycleNotificationCount 4 \
    "progress foreground notification count changed"
assert_state "$state" lifecycleNotifications.2 UIApplicationWillEnterForegroundNotification \
    "progress missed UIApplicationWillEnterForegroundNotification"
assert_state "$state" lifecycleNotifications.3 UIApplicationDidBecomeActiveNotification \
    "progress missed UIApplicationDidBecomeActiveNotification"
foreground_pid=$(launch_pid "$artifact_dir/foreground-launch.log")
[ -n "$foreground_pid" ] && [ "$foreground_pid" = "$initial_pid" ] ||
    fail "plain relaunch did not foreground the same progress process"
cp "$state" "$artifact_dir/running-dark-lifecycle-foreground-state.plist"
for retained_state in \
        "$artifact_dir/running-dark-lifecycle-background-state.plist" \
        "$artifact_dir/running-dark-lifecycle-foreground-state.plist"; do
    for key in processID controllerToken modelToken revision phase rows modelEvents \
               title status progress cancelTitle finishTitle; do
        assert_files_equal "$artifact_dir/running-dark-lifecycle-before-state.plist" \
            "$retained_state" "$key" \
            "progress visible/model state was not retained"
    done
done
for key in actualModalPresentation presentationAttached navigationDepth \
           progressIsTopController confirmationPlaceholderIsRoot \
           confirmationPlaceholderIdentifier requestedPresentationStyle \
           adaptivePresentationStyle horizontalSizeClass formSheetFrameInset \
           backdropInterceptsOutsideSheet dimmingEvidenceEligible \
           terminalCanvasUsesFixedPalette eventCellsUseTerminalSurface \
           confirmationPlaceholderUsesCellBackground \
           presenterUsesGroupedBackground presentationFrame; do
    assert_files_equal "$artifact_dir/running-dark-lifecycle-before-state.plist" \
        "$artifact_dir/running-dark-lifecycle-foreground-state.plist" "$key" \
        "Progress form-sheet presentation was not retained"
done
simctl 30 io "$simulator" screenshot \
    "$artifact_dir/running-dark-lifecycle-foreground.png" >/dev/null ||
    fail "could not capture progress after foregrounding"

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
accessibility_line_spacing=$(read_state "$state" messageLineSpacing)
awk -v spacing="$accessibility_line_spacing" 'BEGIN { exit !(spacing == 0) }' ||
    fail "Accessibility Large event line spacing is no longer compact (messageLineSpacing=$accessibility_line_spacing)"
accessibility_message_line_height=$(read_state "$state" messageLineHeight)
awk -v accessibility="$accessibility_message_line_height" \
    -v normal="$default_message_line_height" \
    'BEGIN { exit !(accessibility > normal) }' ||
    fail "Accessibility Large unexpectedly shrank the terminal line height"
cp "$state" "$artifact_dir/running-dark-accessibility-large-state.plist"
sleep 1
simctl 30 io "$simulator" screenshot \
    "$artifact_dir/running-dark-accessibility-large.png" >/dev/null ||
    fail "could not capture Accessibility Large screenshot"

: >"$data_container/tmp/cydia-progress-probe-default"
wait_for_state "$state" running-default dark ||
    fail "default-size running state did not settle before completion"
assert_equal "$state" contentSizeCategory expectedDefaultContentSizeCategory \
    "default-size reset did not settle before completion"

# Drive cancellation through the controller's visible action and retain the
# requested state in the receipt.  Completion below must then clear that
# request before exposing its finish action.
: >"$data_container/tmp/cydia-progress-probe-cancel"
wait_for_state "$state" running-cancelled dark ||
    fail "running cancellation state did not become ready"
assert_state "$state" cancellationState 2 \
    "Cancel did not publish the requested cancellation state"
assert_state "$state" progressCancelled true \
    "Cancel did not reach the acquisition cancellation query"
assert_state "$state" cancelTitle "" \
    "Cancel remained available after its request was recorded"
assert_state "$state" finishTitle "" \
    "finish action appeared while cancellation was pending"
assert_state "$state" finishButtonHidden true \
    "bottom finish action appeared while cancellation was pending"
cp "$state" "$artifact_dir/running-dark-cancelled-state.plist"

: >"$data_container/tmp/cydia-progress-probe-finish"
wait_for_state "$state" complete dark || fail "completed state did not become ready"
[ "$(read_state "$state" cancelTitle)" = "" ] || fail "cancel action remained after completion"
assert_state "$state" cancellationState 0 \
    "completion did not clear the requested cancellation state"
assert_state "$state" progressCancelled false \
    "completion still reported a pending cancellation"
assert_state "$state" finishTitle "" "navigation terminal action was duplicated on completion"
assert_equal "$state" finishButtonTitle expectedFinishTitle \
    "bottom finish action title diverged from legacy completion"
[ "$(read_state "$state" finishButtonHidden)" = "false" ] ||
    fail "bottom finish action was not restored on completion"
finish_height=$(read_state "$state" finishButtonHeight)
awk -v height="$finish_height" 'BEGIN { exit !(height >= 44) }' ||
    fail "bottom finish action target is smaller than 44 points (height=$finish_height)"
assert_state "$state" finishDispatchCount 0 \
    "terminal footer dispatched before its visible activation"
assert_state "$state" percentIsHistorical true \
    "terminal backend estimate was not distinguished from live progress"
assert_state "$state" statusHidden false \
    "terminal footer omitted the visible last-reported-progress explanation"
assert_equal "$state" status expectedStatus \
    "terminal footer text does not describe the historical backend estimate"
assert_equal "$state" progressAccessibilityLabel expectedHistoricalAccessibilityLabel \
    "completed progress accessibility mislabels the last backend estimate"
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
: >"$data_container/tmp/cydia-progress-probe-activate-finish"
wait_for_value "$state" phase finish-activated ||
    fail "visible terminal finish action did not activate"
wait_for_value "$state" finishDispatchCount 1 ||
    fail "terminal finish action did not dispatch exactly once"
assert_state "$state" finishDispatchAction returnToCydia \
    "terminal finish action dispatched the wrong Return route"
sleep 1
assert_state "$state" finishDispatchCount 1 \
    "repeated terminal activation dispatched more than once"
activated_finish_height=$(read_state "$state" finishButtonHeight)
awk -v height="$activated_finish_height" 'BEGIN { exit !(height >= 44) }' ||
    fail "terminal finish target shrank below 44 points after activation (height=$activated_finish_height)"
cp "$state" "$artifact_dir/complete-dark-default-state.plist"
sleep 1
simctl 30 io "$simulator" screenshot "$artifact_dir/complete-dark-default.png" >/dev/null ||
    fail "could not capture completed dark screenshot"

pass "installed controller preserved order, real lifecycle retention, multiarch identity, live color, default parity, Dynamic Type, and completion accessibility"
echo "[verify-progress-simulator][evidence] $artifact_dir"
