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
background_bundle_id=com.apple.Preferences
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
        echo "[verify-confirmation-simulator][cleanup] stale CoreSimulator registration; rebooting only $simulator" >&2
        simctl 30 shutdown "$simulator" >"$artifact_dir/cleanup-reboot.log" 2>&1 || true
        simctl 30 boot "$simulator" >>"$artifact_dir/cleanup-reboot.log" 2>&1 || true
        simctl 90 bootstatus "$simulator" -b >>"$artifact_dir/cleanup-reboot.log" 2>&1 ||
            cleanup_status=1
    fi
    if simctl 10 get_app_container "$simulator" "$bundle_id" app >/dev/null 2>&1 ||
       simctl 10 get_app_container "$simulator" "$bundle_id" data >/dev/null 2>&1; then
        echo "[verify-confirmation-simulator][cleanup] probe registration remains" >&2
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
        "Confirmation did not retain its requested form-sheet style"
    assert_state "$form_state" requestedPresentationStyle formSheet \
        "UIKit did not create the requested Confirmation form-sheet presentation"
    assert_state "$form_state" navigationDepth 1 \
        "Confirmation form-sheet navigation depth changed"
    assert_state "$form_state" confirmationIsTopController true \
        "Confirmation is not the top form-sheet controller"
    assert_state "$form_state" actualModalPresentation true \
        "Confirmation probe did not use a real modal presentation controller"
    assert_state "$form_state" presentationAttached true \
        "Confirmation form sheet is not attached to the presenter window"
    assert_state "$form_state" sheetUsesCellBackground true \
        "Confirmation form sheet did not use its elevated cell surface"
    assert_state "$form_state" navigationBarUsesPresentedSurface true \
        "Confirmation navigation bar lost its elevated semantic surface"
    assert_state "$form_state" navigationBarOpaque true \
        "Confirmation navigation bar is not opaque"
    assert_state "$form_state" navigationBarTranslucent false \
        "Confirmation navigation bar became translucent"
    assert_state "$form_state" rowsMeetTouchTarget true \
        "Confirmation form-sheet rows fell below the 44-point touch target"

    form_size_class=$(read_state "$form_state" horizontalSizeClass)
    case "$form_size_class" in
        regular)
            assert_state "$form_state" presenterUsesGroupedBackground true \
                "regular-width Confirmation presenter did not use its grouped surface"
            assert_state "$form_state" formSheetFrameInset true \
                "regular-width Confirmation form sheet is not inset"
            assert_state "$form_state" backdropInterceptsOutsideSheet true \
                "regular-width Confirmation form sheet has no live dimming backdrop"
            assert_state "$form_state" dimmingEvidenceEligible true \
                "regular-width Confirmation form sheet was not classified as closing dimming evidence"
            ;;
        compact)
            # UIKit adapts a requested form sheet to full-screen/page-sheet on
            # compact width. It must not be reported as inset/dimmed evidence.
            assert_state "$form_state" formSheetFrameInset false \
                "compact adapted Confirmation unexpectedly reported an inset sheet"
            assert_state "$form_state" backdropInterceptsOutsideSheet false \
                "compact adapted Confirmation unexpectedly reported a dimming backdrop"
            assert_state "$form_state" dimmingEvidenceEligible false \
                "compact adapted Confirmation was misclassified as closing dimming evidence"
            ;;
        *) fail "unknown Confirmation presenter horizontal size class: $form_size_class" ;;
    esac
}

launch_pid() {
    sed -n "s/^$bundle_id: //p" "$1" | tail -n 1
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
# Keep this probe's internal build serial; the caller may be running beside
# other read-only checks, but never beside another compiler or simulator.
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
assert_state "$state" hasChanges true \
    "normal transaction lost its change state"
assert_state "$state" hasBlockingIssues false \
    "normal transaction reported blocking issues"
assert_state "$state" showsConfirmAction true \
    "normal transaction lost its confirmable state"
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
assert_state "$state" rowsMeetTouchTarget true \
    "normal confirmation rows fell below the 44-point touch target"
assert_state "$state" navigationBarHidden false "normal confirmation navigation bar is hidden"
assert_state "$state" navigationBarUsesPresentedSurface true \
    "normal confirmation navigation bar lost its semantic surface"
assert_state "$state" navigationBarOpaque true \
    "normal confirmation navigation bar is not opaque"
assert_state "$state" navigationBarTranslucent false \
    "normal confirmation navigation bar became translucent"
assert_state "$state" formSheetPresentation false \
    "ordinary Confirmation unexpectedly entered form-sheet mode"
assert_state "$state" actualModalPresentation false \
    "ordinary Confirmation unexpectedly claimed modal presentation"
assert_state "$state" legacyChangeKeyCount 5 \
    "legacy confirmation change-key schema changed"
assert_state "$state" legacyChangesIvarPresent true \
    "legacy ConfirmationController changes_ ivar is absent at runtime"
assert_state "$state" legacySubstrateIvarPresent true \
    "legacy ConfirmationController substrate_ ivar is absent at runtime"
assert_state "$state" legacyChangeKeys.0 downgrades \
    "legacy confirmation contract lost downgrades"
assert_state "$state" legacyChangeKeys.1 installs \
    "legacy confirmation contract lost installs"
assert_state "$state" legacyChangeKeys.2 reinstalls \
    "legacy confirmation contract lost reinstalls"
assert_state "$state" legacyChangeKeys.3 removes \
    "legacy confirmation contract lost removes"
assert_state "$state" legacyChangeKeys.4 upgrades \
    "legacy confirmation contract lost upgrades"
assert_state "$state" legacyInstallsCount 1 \
    "legacy confirmation installs count changed"
assert_state "$state" legacyInstalls.0 runtime-native \
    "legacy confirmation installs lost canonical identity"
assert_state "$state" legacyReinstallsCount 1 \
    "legacy confirmation reinstalls count changed"
assert_state "$state" legacyReinstalls.0 same-package \
    "legacy confirmation reinstalls lost canonical identity"
assert_state "$state" legacyUpgradesCount 1 \
    "legacy confirmation upgrades count changed"
assert_state "$state" legacyUpgrades.0 foreign-package:iphoneos-arm \
    "legacy confirmation upgrades normalized a foreign identity"
assert_state "$state" legacyDowngradesCount 1 \
    "legacy confirmation downgrades count changed"
assert_state "$state" legacyDowngrades.0 independent-package \
    "legacy confirmation downgrades lost canonical identity"
assert_state "$state" legacyRemovesCount 1 \
    "legacy confirmation removes count changed"
assert_state "$state" legacyRemoves.0 old-package \
    "legacy confirmation removes lost canonical identity"
assert_state "$state" legacySubstrate true \
    "legacy confirmation substrate flag was not initialized"
[ "$(read_state "$state" continueTitle)" != "" ] ||
    fail "Continue Queuing action is absent"
assert_equal "$state" continueTitle expectedContinueTitle \
    "Continue Queuing title was not localized through the production path"
cp "$state" "$artifact_dir/normal-light-state.plist"
sleep 1
simctl 30 io "$simulator" screenshot "$artifact_dir/normal-light.png" >/dev/null ||
    fail "could not capture normal light screenshot"

# Exercise the legacy empty-transaction shell explicitly.  A zero-change
# transaction still exposes Queue/Modifications sections and a confirmable
# navigation action; it must not inherit rows, sizes, or issue state from the
# preceding mixed-operation fixture.
: >"$data_container/tmp/cydia-confirmation-probe-empty"
wait_for_state "$state" empty light || fail "empty transaction state did not become ready"
assert_state "$state" sections 2 \
    "empty transaction lost the Queue/Modifications shell"
assert_state "$state" sectionKinds.0 queue \
    "empty transaction lost Continue Queuing"
assert_state "$state" sectionKinds.1 modifications \
    "empty transaction lost the Modifications section"
assert_state "$state" modificationRowCount 0 \
    "empty transaction invented a modification row"
assert_state "$state" hasChanges false \
    "empty transaction reported changes"
assert_state "$state" hasBlockingIssues false \
    "empty transaction reported blocking issues"
assert_state "$state" showsConfirmAction true \
    "empty transaction lost its confirmable state"
assert_state "$state" hasConfirm true \
    "empty transaction lost Confirm"
assert_state "$state" hasCancel true \
    "empty transaction lost Cancel"
assert_state "$state" hasCannotComplyHeader false \
    "empty transaction showed an issue header"
assert_state "$state" downloadingDetail "" \
    "empty transaction retained a downloading-size row"
assert_state "$state" resumingDetail "" \
    "empty transaction retained a resuming-size row"
assert_state "$state" cellIdentifiers.0 cydia.confirmation.continue-queuing \
    "empty transaction lost the Queue disclosure row"
cp "$state" "$artifact_dir/empty-light-state.plist"

# Restore the mixed fixture before the lifecycle and appearance phases so the
# following receipts continue to compare against the established normal state.
: >"$data_container/tmp/cydia-confirmation-probe-normal"
wait_for_state "$state" normal light ||
    fail "normal state did not restore after empty transaction"

: >"$data_container/tmp/cydia-confirmation-probe-arm-lifecycle"
wait_for_value "$state" lifecycleArmed true ||
    fail "confirmation lifecycle observer did not arm"
wait_for_value "$state" lifecycleNotificationCount 0 ||
    fail "confirmation lifecycle observer did not start empty"
wait_for_state "$state" normal light ||
    fail "confirmation did not settle before backgrounding"
cp "$state" "$artifact_dir/normal-light-lifecycle-before-state.plist"
initial_pid=$(read_state "$state" processID)
simctl 30 launch "$simulator" "$background_bundle_id" \
    >"$artifact_dir/background-settings-launch.log" 2>&1 ||
    fail "could not foreground Settings to background confirmation"
wait_for_value "$state" lastLifecycleNotification UIApplicationDidEnterBackgroundNotification ||
    fail "confirmation did not receive the real background notification"
assert_state "$state" applicationState background \
    "confirmation did not reach UIApplicationStateBackground"
assert_state "$state" lifecycleNotificationCount 2 \
    "confirmation background notification count changed"
assert_state "$state" lifecycleNotifications.0 UIApplicationWillResignActiveNotification \
    "confirmation missed UIApplicationWillResignActiveNotification"
assert_state "$state" lifecycleNotifications.1 UIApplicationDidEnterBackgroundNotification \
    "confirmation missed UIApplicationDidEnterBackgroundNotification"
cp "$state" "$artifact_dir/normal-light-lifecycle-background-state.plist"
simctl 30 io "$simulator" screenshot \
    "$artifact_dir/normal-light-lifecycle-background-settings.png" >/dev/null ||
    fail "could not capture Settings while confirmation was backgrounded"
simctl 30 launch "$simulator" "$bundle_id" \
    >"$artifact_dir/foreground-launch.log" 2>&1 ||
    fail "could not foreground the running confirmation probe"
wait_for_value "$state" lifecycleComplete true ||
    fail "confirmation did not complete the real foreground transition"
assert_state "$state" applicationState active \
    "confirmation did not return to UIApplicationStateActive"
assert_state "$state" lifecycleNotificationCount 4 \
    "confirmation foreground notification count changed"
assert_state "$state" lifecycleNotifications.2 UIApplicationWillEnterForegroundNotification \
    "confirmation missed UIApplicationWillEnterForegroundNotification"
assert_state "$state" lifecycleNotifications.3 UIApplicationDidBecomeActiveNotification \
    "confirmation missed UIApplicationDidBecomeActiveNotification"
foreground_pid=$(launch_pid "$artifact_dir/foreground-launch.log")
[ -n "$foreground_pid" ] && [ "$foreground_pid" = "$initial_pid" ] ||
    fail "plain relaunch did not foreground the same confirmation process"
cp "$state" "$artifact_dir/normal-light-lifecycle-foreground-state.plist"
for retained_state in \
        "$artifact_dir/normal-light-lifecycle-background-state.plist" \
        "$artifact_dir/normal-light-lifecycle-foreground-state.plist"; do
    for key in processID controllerToken modelToken phase sections modificationRowCount \
               installTitle installDetail hasConfirm hasCancel; do
        assert_files_equal "$artifact_dir/normal-light-lifecycle-before-state.plist" \
            "$retained_state" "$key" \
            "confirmation visible/model state was not retained"
    done
done
simctl 30 io "$simulator" screenshot \
    "$artifact_dir/normal-light-lifecycle-foreground.png" >/dev/null ||
    fail "could not capture confirmation after foregrounding"

light_luminance=$(read_state "$state" backgroundLuminance)
light_table_luminance=$(read_state "$state" tableBackgroundLuminance)
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
dark_table_luminance=$(read_state "$state" tableBackgroundLuminance)
case "$light_luminance:$light_table_luminance:$dark_luminance:$dark_table_luminance" in
    *[!0-9:]*) fail "confirmation surface luminance evidence is not numeric" ;;
esac
[ "$light_luminance" -gt "$dark_luminance" ] ||
    fail "confirmation background did not respond to the live dark trait"
[ "$light_table_luminance" -gt "$dark_table_luminance" ] ||
    fail "confirmation table did not respond to the live dark trait"
[ "$dark_luminance" -ge 30 ] ||
    fail "dark Confirmation sheet collapses into the black presenting field"
[ "$dark_table_luminance" -ge 30 ] ||
    fail "dark Confirmation table collapses into the black presenting field"
[ "$dark_luminance" -eq "$dark_table_luminance" ] ||
    fail "dark Confirmation root and table do not share the presented surface"
cp "$state" "$artifact_dir/normal-dark-state.plist"
sleep 1
simctl 30 io "$simulator" screenshot "$artifact_dir/normal-dark.png" >/dev/null ||
    fail "could not capture normal dark screenshot"

: >"$data_container/tmp/cydia-confirmation-probe-form-sheet"
wait_for_value "$state" formSheetPresentation true ||
    fail "Confirmation did not enter the real form-sheet presentation"
wait_for_state "$state" normal dark ||
    fail "form-sheet Confirmation did not settle"
assert_real_form_sheet "$state"
form_sheet_luminance=$(read_state "$state" backgroundLuminance)
form_sheet_table_luminance=$(read_state "$state" tableBackgroundLuminance)
expected_cell_luminance=$(read_state "$state" expectedCellBackgroundLuminance)
expected_background_luminance=$(read_state "$state" expectedBackgroundLuminance)
presenter_luminance=$(read_state "$state" presenterBackgroundLuminance)
[ "$form_sheet_luminance" -eq "$form_sheet_table_luminance" ] &&
[ "$form_sheet_luminance" -eq "$expected_cell_luminance" ] ||
    fail "form-sheet Confirmation root and table do not share the elevated surface"
if [ "$(read_state "$state" horizontalSizeClass)" = "regular" ]; then
    [ "$form_sheet_luminance" -gt "$expected_background_luminance" ] &&
    [ "$form_sheet_luminance" -gt "$presenter_luminance" ] ||
        fail "regular-width Confirmation form sheet does not contrast with its presenter"
    form_sheet_artifact=normal-dark-form-sheet
else
    form_sheet_artifact=normal-dark-adapted-form-sheet-nonclosing
fi
cp "$state" "$artifact_dir/$form_sheet_artifact-state.plist"
sleep 1
simctl 30 io "$simulator" screenshot \
    "$artifact_dir/$form_sheet_artifact.png" >/dev/null ||
    fail "could not capture Confirmation form-sheet screenshot"

: >"$data_container/tmp/cydia-confirmation-probe-light"
wait_for_state "$state" normal light ||
    fail "form-sheet Confirmation did not settle under a Light trait"
assert_real_form_sheet "$state"
light_form_sheet_luminance=$(read_state "$state" backgroundLuminance)
light_form_sheet_table_luminance=$(read_state "$state" tableBackgroundLuminance)
light_expected_cell_luminance=$(read_state "$state" expectedCellBackgroundLuminance)
[ "$light_form_sheet_luminance" -eq "$light_form_sheet_table_luminance" ] &&
[ "$light_form_sheet_luminance" -eq "$light_expected_cell_luminance" ] ||
    fail "Light form-sheet Confirmation root and table lost their elevated surface"
cp "$state" "$artifact_dir/normal-light-form-sheet-state.plist"
sleep 1
simctl 30 io "$simulator" screenshot \
    "$artifact_dir/normal-light-form-sheet.png" >/dev/null ||
    fail "could not capture Light Confirmation form-sheet screenshot"

: >"$data_container/tmp/cydia-confirmation-probe-dark"
wait_for_state "$state" normal dark ||
    fail "form-sheet Confirmation did not restore its Dark trait"
assert_real_form_sheet "$state"

: >"$data_container/tmp/cydia-confirmation-probe-accessibility"
wait_for_state "$state" normal-accessibility dark ||
    fail "accessibility state did not become ready"
assert_real_form_sheet "$state"
assert_equal "$state" contentSizeCategory expectedAccessibilityContentSizeCategory \
    "confirmation did not apply Accessibility Large"
assert_state "$state" visibleRowsFit true "Accessibility Large clips confirmation labels"
assert_state "$state" rowsMeetTouchTarget true \
    "Accessibility Large confirmation rows fell below the 44-point touch target"
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
    assert_real_form_sheet "$state"
    : >"$data_container/tmp/cydia-confirmation-probe-$action"
    case "$action" in
        confirm) expected=confirm ;;
        continue) expected=continue-queuing ;;
        cancel) expected=cancel-clear ;;
    esac
    wait_for_value "$state" lastAction "$expected" ||
        fail "$action did not dispatch the expected production delegate outcome"
    if [ "$action" = confirm ]; then
        assert_state "$state" restartSubstrate true \
            "normal Confirm ignored the legacy substrate flag"
    fi
    if [ "$action" = continue ]; then
        assert_state "$state" lastInteraction queue-selection \
            "Continue Queuing bypassed the installed table-row interaction path"
    fi
done

: >"$data_container/tmp/cydia-confirmation-probe-normal-confirm-substrate-cleared"
wait_for_state "$state" normal-confirm-substrate-cleared dark ||
    fail "extension-compatible Confirm state did not become ready"
assert_real_form_sheet "$state"
assert_state "$state" legacySubstrate false \
    "probe could not clear the legacy substrate flag"
: >"$data_container/tmp/cydia-confirmation-probe-confirm"
wait_for_value "$state" lastAction confirm ||
    fail "extension-compatible Confirm did not dispatch"
assert_state "$state" restartSubstrate false \
    "Confirm ignored an extension-cleared substrate flag"

: >"$data_container/tmp/cydia-confirmation-probe-legacy-sparse"
wait_for_state "$state" legacy-sparse dark ||
    fail "sparse legacy-change state did not become ready"
assert_real_form_sheet "$state"
assert_state "$state" legacyChangeKeyCount 5 \
    "sparse transaction omitted a legacy change key"
assert_state "$state" legacyInstallsCount 0 \
    "sparse transaction invented legacy installs"
assert_state "$state" legacyReinstallsCount 0 \
    "sparse transaction invented legacy reinstalls"
assert_state "$state" legacyUpgradesCount 0 \
    "sparse transaction invented legacy upgrades"
assert_state "$state" legacyDowngradesCount 0 \
    "sparse transaction invented legacy downgrades"
assert_state "$state" legacyRemovesCount 1 \
    "sparse transaction lost its legacy removal"
assert_state "$state" legacyRemoves.0 old-package \
    "sparse transaction lost its canonical removal identity"

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

pass "installed controller preserved grouped transaction UI, real lifecycle retention, delegate outcomes, multiarch identity, live color, Dynamic Type, issue blocking, and essential warning chrome"
echo "[verify-confirmation-simulator][evidence] $artifact_dir"
