#!/bin/sh
# Cydia Refurbished installed native error evidence.
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
build_jobs=${NATIVE_ERROR_BUILD_JOBS:-1}
source_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
case "$build_dir" in /*) ;; *) build_dir=$source_root/$build_dir ;; esac

[ "$ios12_udid" != "$ios15_udid" ] || {
    echo "[verify-native-error-simulator][FAIL] runtimes need distinct UDIDs" >&2
    exit 2
}
[ -z "$(git -C "$source_root" status --porcelain --untracked-files=all)" ] || {
    echo "[verify-native-error-simulator][FAIL] source worktree must be clean" >&2
    exit 2
}
for program in xcrun plutil shasum; do
    command -v "$program" >/dev/null 2>&1 || {
        echo "[verify-native-error-simulator][FAIL] $program is unavailable" >&2
        exit 2
    }
done

bundle_id=com.saurik.Cydia.NativeErrorProbe.p$$
artifact_dir=$build_dir/native-error-simulator-artifacts
temporary=$(mktemp -d "${TMPDIR:-/tmp}/cydia-native-error.XXXXXX")
probe_app=$temporary/CydiaNativeErrorProbe.app
installed_simulators=
source_head=
binary_sha=
bundle_short_version=
bundle_version=

fail() {
    echo "[verify-native-error-simulator][FAIL] $*" >&2
    exit 1
}

case "$build_jobs" in
    ''|*[!0-9]*|0) fail "NATIVE_ERROR_BUILD_JOBS must be a positive integer" ;;
esac

run_with_timeout() {
    seconds=$1
    shift
    "$@" & command_pid=$!
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
    ) & watchdog=$!
    set +e
    wait "$command_pid"; status=$?
    set -e
    kill "$watchdog" 2>/dev/null || true
    wait "$watchdog" 2>/dev/null || true
    return "$status"
}

simctl() { seconds=$1; shift; run_with_timeout "$seconds" xcrun simctl "$@"; }
device_is_booted() {
    xcrun simctl list devices | grep -F "($1) (Booted)" >/dev/null 2>&1
}
remove_probe() {
    simctl 10 terminate "$1" "$bundle_id" >/dev/null 2>&1 || true
    simctl 15 uninstall "$1" "$bundle_id" >/dev/null 2>&1 || true
}
container_absent() {
    simulator=$1; kind=$2
    path=$(simctl 10 get_app_container "$simulator" "$bundle_id" "$kind" 2>/dev/null) || {
        status=$?; [ "$status" -eq 2 ] && return 0; return 1;
    }
    [ -z "$path" ] || [ ! -e "$path" ]
}
app_registered() {
    simctl 15 listapps "$1" 2>/dev/null |
        grep -F "\"$bundle_id\"" >/dev/null 2>&1
}
refresh_simulator_lsd() {
    simulator=$1; destination=$2
    launchd_pid=$(ps -axo pid=,ppid=,command= | awk -v device="$simulator" '
        $2 == 1 && $3 == "launchd_sim" && index($0, device) { print $1 }
    ')
    case "$launchd_pid" in ''|*[!0-9]*) return 1 ;; esac
    lsd_pid=$(ps -axo pid=,ppid=,command= | awk -v parent="$launchd_pid" '
        $2 == parent && $NF ~ /\/usr\/libexec\/lsd$/ { print $1 }
    ')
    case "$lsd_pid" in ''|*[!0-9]*) return 1 ;; esac
    kill -TERM "$lsd_pid" 2>/dev/null || return 1
    attempts=0; replacement=
    while [ "$attempts" -lt 40 ]; do
        replacement=$(ps -axo pid=,ppid=,command= | awk -v parent="$launchd_pid" \
            -v previous="$lsd_pid" '
            $2 == parent && $1 != previous && $NF ~ /\/usr\/libexec\/lsd$/ { print $1 }
        ')
        case "$replacement" in ''|*[!0-9]*) replacement= ;; *) break ;; esac
        attempts=$((attempts + 1)); sleep 0.25
    done
    [ -n "$replacement" ] || return 1
    printf '%s simulator=%s launchd_sim=%s old_lsd=%s new_lsd=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$simulator" "$launchd_pid" \
        "$lsd_pid" "$replacement" >>"$destination/cleanup.log"
}
wait_for_removal() {
    simulator=$1; destination=$2; attempts=0
    while [ "$attempts" -lt 80 ]; do
        if container_absent "$simulator" app && container_absent "$simulator" data; then
            if app_registered "$simulator"; then
                refresh_simulator_lsd "$simulator" "$destination" || return 1
                attempts=0
                while [ "$attempts" -lt 80 ]; do
                    app_registered "$simulator" || return 0
                    attempts=$((attempts + 1)); sleep 0.25
                done
                return 1
            fi
            return 0
        fi
        attempts=$((attempts + 1)); sleep 0.25
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
        wait_for_removal "$simulator" "$destination" || cleanup_status=1
    done
    rm -rf -- "$temporary"
    [ "$original_status" -ne 0 ] || original_status=$cleanup_status
    exit "$original_status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

read_state() { plutil -extract "$2" raw -o - "$1" 2>/dev/null; }
assert_state() {
    actual=$(read_state "$1" "$2" || true)
    [ "$actual" = "$3" ] || fail "$4 ($2=$actual expected=$3)"
}
assert_number() {
    actual=$(read_state "$1" "$2" || true)
    awk -v left="$actual" -v right="$4" -v op="$3" 'BEGIN {
        if (op == "gt") ok=left>right; else if (op == "ge") ok=left>=right;
        else if (op == "lt") ok=left<right; else if (op == "le") ok=left<=right;
        exit !ok
    }' || fail "$5 ($2=$actual expected $3 $4)"
}
wait_for_state() {
    file=$1; style=$2; size=$3; details=$4; overlay=$5; retry=$6; pid=$7
    attempts=0
    while [ "$attempts" -lt 160 ]; do
        if [ -f "$file" ] && [ "$(read_state "$file" ready || true)" = true ] &&
           [ "$(read_state "$file" style || true)" = "$style" ] &&
           [ "$(read_state "$file" contentSize || true)" = "$size" ] &&
           [ "$(read_state "$file" detailsVisible || true)" = "$details" ] &&
           [ "$(read_state "$file" overlayVisible || true)" = "$overlay" ] &&
           [ "$(read_state "$file" retryCount || true)" = "$retry" ] &&
           [ "$(read_state "$file" processID || true)" = "$pid" ]; then return 0; fi
        attempts=$((attempts + 1)); sleep 0.25
    done
    [ ! -f "$file" ] || plutil -p "$file" >&2 || true
    return 1
}
assert_accessibility() {
    state=$1; output=$2
    plutil -convert json -o "$output" "$state" || fail "could not export tree"
    for identifier in native-error.title native-error.summary native-error.details \
            native-error.retry native-error.more-information; do
        grep -Fq "$identifier" "$output" || fail "missing accessibility $identifier"
    done
}
capture_phase() {
    state=$1; destination=$2; name=$3; simulator=$4
    cp "$state" "$destination/$name-state.plist"
    plutil -convert json -r -o "$destination/$name-ui-tree.json" "$state"
    simctl 30 io "$simulator" screenshot "$destination/$name.png" >/dev/null ||
        fail "could not capture $name"
}
verify_visible_error() {
    state=$1
    assert_state "$state" controllerClass ErrorViewController \
        "native error controller missing"
    assert_state "$state" overlayVisible true "native error overlay is absent"
    assert_state "$state" accessibilityModal true "error accessibility is not modal"
    assert_state "$state" uiWebViewCountInError 0 "native error embeds UIWebView"
    assert_state "$state" wkWebViewCountInError 0 "native error embeds WKWebView"
    assert_state "$state" titleFits true "native error title clips"
    assert_state "$state" summaryFits true "native error summary clips"
    assert_state "$state" detailsFits true "native error details clip"
    assert_number "$state" retryHeight ge 44 "Retry action is below 44 points"
    assert_number "$state" moreHeight ge 44 "More Information is below 44 points"
    assert_number "$state" retryHeight le 96 "Retry action stretches vertically"
    assert_number "$state" moreHeight le 96 "More Information stretches vertically"
    [ -n "$(read_state "$state" title || true)" ] || fail "error title is empty"
    [ -n "$(read_state "$state" summary || true)" ] || fail "error summary is empty"
    [ -n "$(read_state "$state" retryTitle || true)" ] || fail "Retry title is empty"
    [ -n "$(read_state "$state" moreTitle || true)" ] || fail "More title is empty"
    assert_accessibility "$state" "$temporary/accessibility.json"
    plutil -convert json -o "$temporary/sanitized.json" "$state"
    if grep -Eqi 'secret|abc123|private/index|Authorization|Bearer|https://' \
            "$temporary/sanitized.json"; then
        fail "native error evidence leaks request secrets"
    fi
}
verify_base() {
    state=$1; runtime=$2; pid=$3
    assert_state "$state" schema 1 "native error schema changed"
    assert_state "$state" fixtureVersion native-error-v2 "native error fixture changed"
    assert_state "$state" systemVersion "$runtime" "native error runtime changed"
    assert_state "$state" processID "$pid" "native error PID changed"
    assert_state "$state" buildEvidence.sourceHEAD "$source_head" "source HEAD is stale"
    assert_state "$state" buildEvidence.binarySHA256 "$binary_sha" "binary hash is stale"
    assert_state "$state" buildEvidence.bundleShortVersion "$bundle_short_version" \
        "short version changed"
    assert_state "$state" buildEvidence.bundleVersion "$bundle_version" \
        "bundle version changed"
}

run_probe() {
    simulator=$1; label=$2; runtime=$3; destination=$artifact_dir/$label
    device_is_booted "$simulator" || fail "$label simulator is not booted"
    mkdir -p "$destination"; remove_probe "$simulator"
    simctl 30 install "$simulator" "$probe_app" >"$destination/install.log" 2>&1 ||
        fail "could not install on $label"
    installed_simulators="$installed_simulators $simulator"
    app_container=$(simctl 20 get_app_container "$simulator" "$bundle_id" app) ||
        fail "could not locate $label app"
    installed_sha=$(shasum -a 256 "$app_container/Cydia" | awk '{print $1}')
    [ "$installed_sha" = "$binary_sha" ] || fail "$label installed hash mismatch"
    {
        echo "source-head=$source_head"; echo "binary-sha256=$binary_sha"
        echo "installed-binary-sha256=$installed_sha"
        echo "bundle-short-version=$bundle_short_version"; echo "bundle-version=$bundle_version"
    } >"$destination/provenance.txt"
    run_with_timeout 30 env \
        SIMCTL_CHILD_CYDIA_PROBE_SOURCE_HEAD="$source_head" \
        SIMCTL_CHILD_CYDIA_PROBE_BINARY_SHA256="$binary_sha" \
        SIMCTL_CHILD_CYDIA_PROBE_BUNDLE_SHORT_VERSION="$bundle_short_version" \
        SIMCTL_CHILD_CYDIA_PROBE_BUNDLE_VERSION="$bundle_version" \
        xcrun simctl launch --stdout="$destination/stdout.log" \
        --stderr="$destination/stderr.log" "$simulator" "$bundle_id" \
        --cydia-appearance-probe --cydia-native-error-probe \
        >"$destination/launch.log" 2>&1 || fail "could not launch on $label"
    pid=$(awk -F ': ' '/: [0-9]+$/ {value=$NF} END {print value}' "$destination/launch.log")
    case "$pid" in ''|*[!0-9]*) fail "$label launch did not report PID" ;; esac
    data_container=$(simctl 20 get_app_container "$simulator" "$bundle_id" data) ||
        fail "could not locate $label data"
    state=$data_container/tmp/cydia-native-error-probe.plist

    wait_for_state "$state" light large false true 0 "$pid" || fail "$label light failure did not settle"
    verify_base "$state" "$runtime" "$pid"; verify_visible_error "$state"
    assert_state "$state" detailsLabelHidden true "details start visible"
    light_luminance=$(read_state "$state" surfaceLuminance)
    if [ "$runtime" = 12.0 ]; then light_status=0; else light_status=3; fi
    assert_state "$state" preferredStatusBarStyle "$light_status" \
        "light status-bar style changed"
    assert_number "$state" titleLuminance lt 64 "light title contrast changed"
    capture_phase "$state" "$destination" failure-light "$simulator"

    touch "$data_container/tmp/cydia-native-error-probe-details"
    wait_for_state "$state" light large true true 0 "$pid" || fail "$label details did not settle"
    verify_base "$state" "$runtime" "$pid"; verify_visible_error "$state"
    assert_state "$state" detailsLabelHidden false "details remain hidden"
    assert_state "$state" details 'NSURLErrorDomain (-1009)
example.com' "technical details schema changed"
    capture_phase "$state" "$destination" details-light "$simulator"

    touch "$data_container/tmp/cydia-native-error-probe-dark"
    wait_for_state "$state" dark large true true 0 "$pid" || fail "$label dark error did not settle"
    verify_base "$state" "$runtime" "$pid"; verify_visible_error "$state"
    assert_state "$state" preferredStatusBarStyle 1 "dark status-bar style changed"
    assert_number "$state" titleLuminance gt 191 "dark title contrast changed"
    assert_number "$state" surfaceLuminance lt "$light_luminance" "dark surface did not change"
    capture_phase "$state" "$destination" details-dark "$simulator"

    touch "$data_container/tmp/cydia-native-error-probe-accessibility"
    wait_for_state "$state" dark accessibility-large true true 0 "$pid" ||
        fail "$label Accessibility Large error did not settle"
    verify_base "$state" "$runtime" "$pid"; verify_visible_error "$state"
    capture_phase "$state" "$destination" details-dark-accessibility "$simulator"

    touch "$data_container/tmp/cydia-native-error-probe-retry"
    wait_for_state "$state" dark accessibility-large true false 1 "$pid" ||
        fail "$label Retry did not settle"
    verify_base "$state" "$runtime" "$pid"
    assert_state "$state" retryMethod GET "Retry method changed"
    assert_state "$state" retryURLMatches true "Retry lost exact request URL"
    assert_state "$state" retryHeaderPreserved true "Retry lost request header"
    assert_state "$state" retrySucceeded true "Retry replacement load did not succeed"
    kill -0 "$pid" 2>/dev/null || fail "$label process exited after Retry"
    capture_phase "$state" "$destination" retry-succeeded "$simulator"

    : >"$destination/crash-check.txt"
    for crash_root in "$HOME/Library/Logs/DiagnosticReports" \
        "$HOME/Library/Developer/CoreSimulator/Devices/$simulator/data/Library/Logs/CrashReporter"; do
        [ -d "$crash_root" ] || continue
        find "$crash_root" -type f -newer "$destination/launch.log" -print 2>/dev/null |
        while IFS= read -r report; do
            grep -Fq "$bundle_id" "$report" && printf '%s\n' "$report"
        done >>"$destination/crash-check.txt"
    done
    [ ! -s "$destination/crash-check.txt" ] || fail "$label produced crash report"
    {
        echo "# Native error evidence"; echo
        echo "- A native UIKit host owns an opaque ErrorViewController child."
        echo "- Summary/details contain no request URL, credentials, query, fragment, headers, or body."
        echo "- Retry crosses the public delegate once, preserves the exact GET snapshot, and reaches a deterministic native success surface."
        echo "- Light, dark, and Accessibility Large phases retain one PID."
    } >"$destination/parity-note.md"

    remove_probe "$simulator"
    wait_for_removal "$simulator" "$destination" || fail "$label probe remained registered"
    installed_simulators=$(printf '%s\n' "$installed_simulators" | tr ' ' '\n' |
        grep -Fvx "$simulator" | tr '\n' ' ' || true)
    find "$destination" -type f ! -name SHA256SUMS -print | LC_ALL=C sort |
    while IFS= read -r file; do shasum -a 256 "$file"; done >"$destination/SHA256SUMS"
    echo "[verify-native-error-simulator][ ok ] $label evidence: $destination"
}

rm -rf -- "$artifact_dir"; mkdir -p "$artifact_dir"
"$make_program" --no-print-directory -j"$build_jobs" -C "$source_root" doIA=yes \
    doErrorViewProbe=yes BUILD_DIR="$build_dir" all >"$artifact_dir/build.log" 2>&1 || {
    grep -n -E 'error:|fatal error:|undefined reference|ld:|make: \*\*\*' \
        "$artifact_dir/build.log" | head -100 >&2 || true
    fail "simulator Make build failed; see $artifact_dir/build.log"
}
echo "[verify-native-error-simulator][ ok ] Make produced the native error probe"
cp -a "$source_root/MobileCydia.app" "$probe_app"
cp "$build_dir/bin/MobileCydia" "$probe_app/Cydia"
plutil -replace CFBundleIdentifier -string "$bundle_id" "$probe_app/Info.plist"
plutil -lint "$probe_app/Info.plist" >/dev/null || fail "probe Info.plist is invalid"
source_head=$(git -C "$source_root" rev-parse HEAD)
binary_sha=$(shasum -a 256 "$probe_app/Cydia" | awk '{print $1}')
bundle_short_version=$(plutil -extract CFBundleShortVersionString raw -o - "$probe_app/Info.plist")
bundle_version=$(plutil -extract CFBundleVersion raw -o - "$probe_app/Info.plist")

run_probe "$ios12_udid" ios12 12.0
run_probe "$ios15_udid" ios15 15.5
echo "[verify-native-error-simulator][evidence] $artifact_dir"
