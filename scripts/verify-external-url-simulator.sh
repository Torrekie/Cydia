#!/bin/sh
# Cydia Refurbished native external URL simulator evidence.
# Copyright (C) 2026 Torrekie
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

if [ "$#" -ne 4 ]; then
    echo "usage: $0 IOS12_UDID IOS15_UDID MAKE BUILD_DIR" >&2
    exit 2
fi

ios12_udid=$1
ios15_udid=$2
make_program=$3
build_dir=$4
source_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
case "$build_dir" in
    /*) ;;
    *) build_dir=$source_root/$build_dir ;;
esac

[ "$ios12_udid" != "$ios15_udid" ] || {
    echo "[verify-external-url-simulator][FAIL] runtimes need distinct UDIDs" >&2
    exit 2
}
[ -z "$(git -C "$source_root" status --porcelain --untracked-files=all)" ] || {
    echo "[verify-external-url-simulator][FAIL] source worktree must be clean" >&2
    exit 2
}
for program in xcrun plutil shasum; do
    command -v "$program" >/dev/null 2>&1 || {
        echo "[verify-external-url-simulator][FAIL] $program is unavailable" >&2
        exit 2
    }
done

bundle_id=com.saurik.Cydia.ExternalURLProbe.p$$
artifact_dir=$build_dir/external-url-simulator-artifacts
temporary=$(mktemp -d "${TMPDIR:-/tmp}/cydia-external-url.XXXXXX")
probe_app=$temporary/CydiaExternalURLProbe.app
installed_simulators=
source_head=
binary_sha=
bundle_short_version=
bundle_version=

fail() {
    echo "[verify-external-url-simulator][FAIL] $*" >&2
    exit 1
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
    set +e
    wait "$command_pid"
    status=$?
    set -e
    kill "$watchdog" 2>/dev/null || true
    wait "$watchdog" 2>/dev/null || true
    return "$status"
}

simctl() {
    seconds=$1
    shift
    run_with_timeout "$seconds" xcrun simctl "$@"
}

device_is_booted() {
    xcrun simctl list devices | grep -F "($1) (Booted)" >/dev/null 2>&1
}

remove_probe() {
    simulator=$1
    simctl 10 terminate "$simulator" "$bundle_id" >/dev/null 2>&1 || true
    simctl 15 uninstall "$simulator" "$bundle_id" >/dev/null 2>&1 || true
}

container_absent() {
    simulator=$1
    kind=$2
    path=$(simctl 10 get_app_container "$simulator" "$bundle_id" "$kind" 2>/dev/null) || {
        status=$?
        [ "$status" -eq 2 ] && return 0
        return 1
    }
    [ -n "$path" ] || return 0
    [ ! -e "$path" ]
}

app_registered() {
    simulator=$1
    simctl 15 listapps "$simulator" 2>/dev/null | grep -F "\"$bundle_id\"" \
        >/dev/null 2>&1
}

refresh_simulator_lsd() {
    simulator=$1
    destination=$2
    device_is_booted "$simulator" || return 1
    launchd_pid=$(ps -axo pid=,ppid=,command= | awk -v device="$simulator" '
        $2 == 1 && $3 == "launchd_sim" && index($0, device) { print $1 }
    ')
    case "$launchd_pid" in
        ''|*[!0-9]*) return 1 ;;
    esac
    lsd_pid=$(ps -axo pid=,ppid=,command= | awk -v parent="$launchd_pid" '
        $2 == parent && $NF ~ /\/usr\/libexec\/lsd$/ { print $1 }
    ')
    case "$lsd_pid" in
        ''|*[!0-9]*) return 1 ;;
    esac
    kill -TERM "$lsd_pid" 2>/dev/null || return 1
    replacement=
    attempts=0
    while [ "$attempts" -lt 40 ]; do
        replacement=$(ps -axo pid=,ppid=,command= | awk -v parent="$launchd_pid" \
            -v previous="$lsd_pid" '
            $2 == parent && $1 != previous && $NF ~ /\/usr\/libexec\/lsd$/ { print $1 }
        ')
        case "$replacement" in
            ''|*[!0-9]*) replacement= ;;
            *) break ;;
        esac
        attempts=$((attempts + 1))
        sleep 0.25
    done
    [ -n "$replacement" ] || return 1
    printf '%s simulator=%s launchd_sim=%s old_lsd=%s new_lsd=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$simulator" "$launchd_pid" \
        "$lsd_pid" "$replacement" >>"$destination/cleanup.log"
}

wait_for_removal() {
    simulator=$1
    destination=$2
    attempts=0
    while [ "$attempts" -lt 80 ]; do
        if container_absent "$simulator" app && container_absent "$simulator" data; then
            if app_registered "$simulator"; then
                refresh_simulator_lsd "$simulator" "$destination" || return 1
                attempts=0
                while [ "$attempts" -lt 80 ]; do
                    if app_registered "$simulator"; then
                        attempts=$((attempts + 1))
                        sleep 0.25
                    else
                        status=$?
                        [ "$status" -eq 1 ] && return 0
                        return 1
                    fi
                done
                return 1
            fi
            return 0
        fi
        attempts=$((attempts + 1))
        sleep 0.25
    done
    return 1
}

cleanup() {
    original_status=$?
    trap - EXIT HUP INT TERM
    cleanup_status=0
    for simulator in $installed_simulators; do
        destination=$artifact_dir/unknown
        [ "$simulator" = "$ios12_udid" ] && destination=$artifact_dir/ios12
        [ "$simulator" = "$ios15_udid" ] && destination=$artifact_dir/ios15
        mkdir -p "$destination"
        remove_probe "$simulator"
        if ! wait_for_removal "$simulator" "$destination"; then
            echo "[verify-external-url-simulator][cleanup] probe remains on $simulator" >&2
            cleanup_status=1
        fi
    done
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

assert_state() {
    file=$1
    key=$2
    expected=$3
    message=$4
    actual=$(read_state "$file" "$key" || true)
    [ "$actual" = "$expected" ] ||
        fail "$message ($key=$actual expected=$expected)"
}

assert_number() {
    file=$1
    key=$2
    operator=$3
    expected=$4
    message=$5
    actual=$(read_state "$file" "$key" || true)
    awk -v left="$actual" -v right="$expected" -v op="$operator" 'BEGIN {
        if (op == "gt") ok = left > right;
        else if (op == "ge") ok = left >= right;
        else if (op == "lt") ok = left < right;
        else if (op == "le") ok = left <= right;
        else ok = 0;
        exit !ok;
    }' || fail "$message ($key=$actual expected $operator $expected)"
}

wait_for_state() {
    file=$1
    style=$2
    content_size=$3
    controller_state=$4
    safari_presented=$5
    presentation_count=$6
    expected_pid=$7
    attempts=0
    while [ "$attempts" -lt 160 ]; do
        if [ -f "$file" ]; then
            ready=$(read_state "$file" ready || true)
            actual_style=$(read_state "$file" style || true)
            actual_size=$(read_state "$file" contentSize || true)
            actual_state=$(read_state "$file" state || true)
            actual_safari=$(read_state "$file" safariPresented || true)
            actual_count=$(read_state "$file" safariPresentationCount || true)
            actual_pid=$(read_state "$file" processID || true)
            if [ "$ready" = true ] && [ "$actual_style" = "$style" ] &&
               [ "$actual_size" = "$content_size" ] &&
               [ "$actual_state" = "$controller_state" ] &&
               [ "$actual_safari" = "$safari_presented" ] &&
               [ "$actual_count" = "$presentation_count" ] &&
               [ "$actual_pid" = "$expected_pid" ]; then
                return 0
            fi
        fi
        attempts=$((attempts + 1))
        sleep 0.25
    done
    [ ! -f "$file" ] || plutil -p "$file" >&2 || true
    return 1
}

assert_accessibility() {
    state=$1
    temporary_json=$2
    plutil -convert json -o "$temporary_json" "$state" ||
        fail "could not convert external URL accessibility state"
    for identifier in external-url.status external-url.destination external-url.retry; do
        grep -Fq "$identifier" "$temporary_json" ||
            fail "accessibility identifier is missing: $identifier"
    done
}

capture_phase() {
    state=$1
    destination=$2
    name=$3
    simulator=$4
    cp "$state" "$destination/$name-state.plist"
    plutil -convert json -r -o "$destination/$name-ui-tree.json" "$state"
    simctl 30 io "$simulator" screenshot "$destination/$name.png" >/dev/null ||
        fail "could not capture $name screenshot"
}

verify_base() {
    state=$1
    expected_runtime=$2
    launched_pid=$3
    expected_state=$4
    expected_safari=$5
    expected_count=$6
    assert_state "$state" schema 2 "external URL probe schema changed"
    assert_state "$state" fixtureVersion native-external-url-v2 \
        "external URL fixture version changed"
    assert_state "$state" systemVersion "$expected_runtime" \
        "external URL runtime changed"
    assert_state "$state" processID "$launched_pid" \
        "external URL state PID differs from launch"
    assert_state "$state" buildEvidence.sourceHEAD "$source_head" \
        "external URL source HEAD evidence is stale"
    assert_state "$state" buildEvidence.binarySHA256 "$binary_sha" \
        "external URL binary evidence is stale"
    assert_state "$state" buildEvidence.bundleShortVersion "$bundle_short_version" \
        "external URL short version evidence changed"
    assert_state "$state" buildEvidence.bundleVersion "$bundle_version" \
        "external URL bundle version evidence changed"
    assert_state "$state" controllerClass ExternalURLController \
        "native external URL controller was not installed"
    assert_state "$state" navigationURL \
        'cydia://url/https%3A%2F%2Fexample.com%2Fcydia-external-runtime%3Fx%3D1%23top' \
        "canonical external route changed"
    assert_state "$state" destinationURL \
        'https://example.com/cydia-external-runtime?x=1#top' \
        "external destination changed"
    assert_state "$state" state "$expected_state" \
        "external URL controller state changed"
    assert_state "$state" safariPresented "$expected_safari" \
        "Safari presentation state changed"
    assert_state "$state" safariPresentationCount "$expected_count" \
        "Safari presentation count changed"
    assert_state "$state" navigationDepth 1 \
        "external URL coordinator changed its navigation stack"
    assert_state "$state" navigationBarHidden false \
        "external URL navigation bar is hidden"
    assert_state "$state" labelsFit true \
        "external URL native labels clip"
    assert_state "$state" retryMeetsTouchTarget true \
        "external URL retry action is below 44 points"
    assert_state "$state" uiWebViewCount 0 \
        "external URL coordinator embedded UIWebView"
    assert_state "$state" wkWebViewCount 0 \
        "external URL coordinator embedded WKWebView"
    [ -n "$(read_state "$state" statusText || true)" ] ||
        fail "external URL status text is empty"
    assert_state "$state" detailText example.com \
        "external URL destination label changed"
    [ -n "$(read_state "$state" retryTitle || true)" ] ||
        fail "external URL Reload title is empty"
    assert_accessibility "$state" "$temporary/accessibility.json"
}

verify_visible_app_chrome() {
    state=$1
    assert_state "$state" navigationBarWindowPresent true \
        "external URL navigation bar is detached from its window"
    assert_number "$state" navigationBarAlpha ge 1 \
        "external URL navigation bar is translucent or invisible"
    assert_number "$state" navigationBarVisibleHeight gt 40 \
        "external URL navigation bar is outside the visible window"
    assert_state "$state" navigationTitleMatchesController true \
        "external URL navigation title does not match its controller"
    [ -n "$(read_state "$state" navigationTitle || true)" ] ||
        fail "external URL navigation title is empty"
}

run_probe() {
    simulator=$1
    label=$2
    expected_runtime=$3
    device_is_booted "$simulator" || fail "$label simulator is not booted"
    destination=$artifact_dir/$label
    mkdir -p "$destination"
    remove_probe "$simulator"
    simctl 30 install "$simulator" "$probe_app" >"$destination/install.log" 2>&1 ||
        fail "could not install on $label"
    installed_simulators="$installed_simulators $simulator"
    app_container=$(simctl 20 get_app_container "$simulator" "$bundle_id" app) ||
        fail "could not locate $label app container"
    installed_sha=$(shasum -a 256 "$app_container/Cydia" | awk '{print $1}')
    [ "$installed_sha" = "$binary_sha" ] ||
        fail "$label installed binary hash mismatch"
    {
        echo "source-head=$source_head"
        echo "binary-sha256=$binary_sha"
        echo "installed-binary-sha256=$installed_sha"
        echo "bundle-short-version=$bundle_short_version"
        echo "bundle-version=$bundle_version"
        xcode-select -p 2>/dev/null || true
        xcrun simctl list runtimes | grep -F "$expected_runtime" || true
    } >"$destination/provenance.txt"
    run_with_timeout 30 env \
        SIMCTL_CHILD_CYDIA_PROBE_SOURCE_HEAD="$source_head" \
        SIMCTL_CHILD_CYDIA_PROBE_BINARY_SHA256="$binary_sha" \
        SIMCTL_CHILD_CYDIA_PROBE_BUNDLE_SHORT_VERSION="$bundle_short_version" \
        SIMCTL_CHILD_CYDIA_PROBE_BUNDLE_VERSION="$bundle_version" \
        xcrun simctl launch --stdout="$destination/stdout.log" \
        --stderr="$destination/stderr.log" "$simulator" "$bundle_id" \
        --cydia-appearance-probe --cydia-external-url-probe \
        >"$destination/launch.log" 2>&1 || fail "could not launch on $label"
    launched_pid=$(awk -F ': ' '/: [0-9]+$/ {value=$NF} END {print value}' \
        "$destination/launch.log")
    case "$launched_pid" in
        ''|*[!0-9]*) fail "$label launch did not report a PID" ;;
    esac
    data_container=$(simctl 20 get_app_container "$simulator" "$bundle_id" data) ||
        fail "could not locate $label data container"
    state=$data_container/tmp/cydia-external-url-probe.plist

    wait_for_state "$state" light large 2 true 1 "$launched_pid" ||
        fail "$label Safari presentation did not settle"
    verify_base "$state" "$expected_runtime" "$launched_pid" 2 true 1
    assert_state "$state" navigationBarStyle 0 \
        "light external URL navigation bar style changed"
    assert_number "$state" navigationTitleLuminance lt 64 \
        "light external URL navigation title has insufficient contrast"
    assert_state "$state" presentedClass SFSafariViewController \
        "HTTP(S) did not use Safari Services"
    assert_state "$state" retryHidden true \
        "retry remains visible behind Safari"
    capture_phase "$state" "$destination" safari-light "$simulator"

    touch "$data_container/tmp/cydia-external-url-probe-dismiss"
    wait_for_state "$state" light large 3 false 1 "$launched_pid" ||
        fail "$label Safari dismissal did not settle"
    verify_base "$state" "$expected_runtime" "$launched_pid" 3 false 1
    verify_visible_app_chrome "$state"
    assert_state "$state" navigationBarStyle 0 \
        "light completion navigation bar style changed"
    assert_state "$state" presentedClass '' \
        "Safari remains presented after Done"
    assert_state "$state" retryHidden false \
        "native completion state has no retry action"
    light_luminance=$(read_state "$state" surfaceLuminance)
    assert_number "$state" surfaceLuminance ge 0 \
        "native light surface has no measurable color"
    capture_phase "$state" "$destination" complete-light "$simulator"

    touch "$data_container/tmp/cydia-external-url-probe-dark"
    wait_for_state "$state" dark large 3 false 1 "$launched_pid" ||
        fail "$label dark completion state did not settle"
    verify_base "$state" "$expected_runtime" "$launched_pid" 3 false 1
    verify_visible_app_chrome "$state"
    assert_state "$state" preferredStatusBarStyle 1 \
        "dark external URL chrome uses dark status-bar content"
    assert_state "$state" navigationBarStyle 1 \
        "dark external URL navigation bar did not adopt UIBarStyleBlack"
    assert_number "$state" navigationTitleLuminance gt 191 \
        "dark external URL navigation title has insufficient contrast"
    assert_number "$state" surfaceLuminance lt "$light_luminance" \
        "dark external URL surface did not change"
    capture_phase "$state" "$destination" complete-dark "$simulator"

    touch "$data_container/tmp/cydia-external-url-probe-accessibility"
    wait_for_state "$state" dark accessibility-large 3 false 1 "$launched_pid" ||
        fail "$label Accessibility Large state did not settle"
    verify_base "$state" "$expected_runtime" "$launched_pid" 3 false 1
    verify_visible_app_chrome "$state"
    capture_phase "$state" "$destination" complete-dark-accessibility "$simulator"

    touch "$data_container/tmp/cydia-external-url-probe-retry"
    wait_for_state "$state" dark accessibility-large 2 true 2 "$launched_pid" ||
        fail "$label Safari retry did not settle"
    verify_base "$state" "$expected_runtime" "$launched_pid" 2 true 2
    assert_state "$state" presentedClass SFSafariViewController \
        "retry did not return to Safari Services"
    capture_phase "$state" "$destination" safari-dark-accessibility-retry "$simulator"

    kill -0 "$launched_pid" 2>/dev/null || fail "$label external URL process exited"
    : >"$destination/crash-check.txt"
    for crash_root in "$HOME/Library/Logs/DiagnosticReports" \
        "$HOME/Library/Developer/CoreSimulator/Devices/$simulator/data/Library/Logs/CrashReporter"; do
        [ -d "$crash_root" ] || continue
        find "$crash_root" -type f -newer "$destination/launch.log" -print 2>/dev/null |
        while IFS= read -r report; do
            grep -Fq "$bundle_id" "$report" && printf '%s\n' "$report"
        done >>"$destination/crash-check.txt"
    done
    [ ! -s "$destination/crash-check.txt" ] || fail "$label produced a crash report"
    {
        echo "# Native external URL evidence"
        echo
        echo "- The canonical cydia://url route round-trips the exact HTTP(S) destination."
        echo "- HTTP(S) presentation is an OS-owned SFSafariViewController; the native coordinator contains zero UIWebView and WKWebView instances."
        echo "- Done returns to a native completion/retry state; retry presents Safari exactly once more."
        echo "- Light, dark, and Accessibility Large states use the same process and native controller."
        echo "- Network page completion is deliberately not an acceptance dependency."
    } >"$destination/parity-note.md"

    remove_probe "$simulator"
    wait_for_removal "$simulator" "$destination" ||
        fail "$label external URL probe remained registered"
    installed_simulators=$(printf '%s\n' "$installed_simulators" |
        tr ' ' '\n' | grep -Fvx "$simulator" | tr '\n' ' ' || true)
    find "$destination" -type f ! -name SHA256SUMS -print | LC_ALL=C sort |
    while IFS= read -r file; do shasum -a 256 "$file"; done \
        >"$destination/SHA256SUMS"
    echo "[verify-external-url-simulator][ ok ] $label evidence: $destination"
}

rm -rf -- "$artifact_dir"
mkdir -p "$artifact_dir"
"$make_program" --no-print-directory -j6 -C "$source_root" \
    doIA=yes doExternalURLProbe=yes BUILD_DIR="$build_dir" all \
    >"$artifact_dir/build.log" 2>&1 || {
        grep -n -E 'error:|fatal error:|undefined reference|ld:|make: \*\*\*' \
            "$artifact_dir/build.log" | head -100 >&2 || true
        fail "simulator Make build failed; see $artifact_dir/build.log"
    }
echo "[verify-external-url-simulator][ ok ] Make produced the native external URL probe"

cp -a "$source_root/MobileCydia.app" "$probe_app"
cp "$build_dir/bin/MobileCydia" "$probe_app/Cydia"
plutil -replace CFBundleIdentifier -string "$bundle_id" "$probe_app/Info.plist"
plutil -lint "$probe_app/Info.plist" >/dev/null || fail "probe Info.plist is invalid"
source_head=$(git -C "$source_root" rev-parse HEAD)
binary_sha=$(shasum -a 256 "$probe_app/Cydia" | awk '{print $1}')
bundle_short_version=$(plutil -extract CFBundleShortVersionString raw -o - \
    "$probe_app/Info.plist")
bundle_version=$(plutil -extract CFBundleVersion raw -o - "$probe_app/Info.plist")

run_probe "$ios12_udid" ios12 12.0
run_probe "$ios15_udid" ios15 15.5

echo "[verify-external-url-simulator][evidence] $artifact_dir"
