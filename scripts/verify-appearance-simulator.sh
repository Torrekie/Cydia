#!/bin/sh
# Build and install Cydia's real appearance probe using the existing Make graph.
# The modern simulator is switched light -> dark without relaunching; an
# optional iOS 12 simulator verifies the calibrated fallback and API safety.

set -u

if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
    echo "usage: $0 MODERN_UDID IOS12_UDID MAKE BUILD_DIR" >&2
    echo "       IOS12_UDID may be empty" >&2
    exit 2
fi

modern_udid=$1
ios12_udid=$2
make_program=$3
build_dir=${4-build/appearance-simulator}
source_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P) || exit 2
case "$build_dir" in
    /*) ;;
    *) build_dir=$source_root/$build_dir ;;
esac

bundle_id=com.saurik.Cydia.AppearanceProbe
artifact_dir=$build_dir/appearance-artifacts
temporary=$(mktemp -d "${TMPDIR:-/tmp}/cydia-appearance.XXXXXX") || exit 2
probe_app=$temporary/CydiaAppearanceProbe.app
original_appearance=

fail() {
    echo "[verify-appearance][FAIL] $*" >&2
    exit 1
}

pass() {
    echo "[verify-appearance][ ok ] $*"
}

terminate_and_uninstall() {
    udid=$1
    [ -n "$udid" ] || return 0
    xcrun simctl terminate "$udid" "$bundle_id" >/dev/null 2>&1 || true
    xcrun simctl uninstall "$udid" "$bundle_id" >/dev/null 2>&1 || true
}

cleanup() {
    if [ -n "$original_appearance" ]; then
        xcrun simctl ui "$modern_udid" appearance "$original_appearance" >/dev/null 2>&1 || true
    fi
    terminate_and_uninstall "$modern_udid"
    terminate_and_uninstall "$ios12_udid"
    rm -rf -- "$temporary"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

read_state() {
    file=$1
    key=$2
    plutil -extract "$key" raw -o - "$file" 2>/dev/null
}

wait_for_style() {
    file=$1
    expected=$2
    minimum_updates=$3
    attempts=0
    while [ "$attempts" -lt 40 ]; do
        if [ -f "$file" ]; then
            style=$(read_state "$file" style || true)
            updates=$(read_state "$file" updates || true)
            case "$updates" in ''|*[!0-9]*) updates=0 ;; esac
            if [ "$style" = "$expected" ] && [ "$updates" -ge "$minimum_updates" ]; then
                return 0
            fi
        fi
        attempts=$((attempts + 1))
        sleep 0.25
    done
    return 1
}

launch_probe() {
    udid=$1
    stdout_file=$2
    stderr_file=$3
    result=$(xcrun simctl launch --terminate-running-process \
        --stdout="$stdout_file" --stderr="$stderr_file" \
        "$udid" "$bundle_id" --cydia-appearance-probe) || return 1
    printf '%s\n' "$result" | sed -n 's/.*: //p'
}

mkdir -p "$artifact_dir"
"$make_program" --no-print-directory -B -j6 -C "$source_root" \
    doIA=yes BUILD_DIR="$build_dir" all >"$artifact_dir/build.log" 2>&1 || {
        grep -n -E 'error:|fatal error:|undefined reference|ld:|make: \*\*\*' \
            "$artifact_dir/build.log" | head -80 >&2 || true
        fail "simulator Make build failed; see $artifact_dir/build.log"
    }
pass "Make produced the x86_64 Cydia simulator binary"

cp -a "$source_root/MobileCydia.app" "$probe_app"
cp "$build_dir/bin/MobileCydia" "$probe_app/Cydia"
plutil -replace CFBundleIdentifier -string "$bundle_id" "$probe_app/Info.plist"

original_appearance=$(xcrun simctl ui "$modern_udid" appearance 2>/dev/null) ||
    fail "modern simulator $modern_udid does not support appearance switching"
xcrun simctl install "$modern_udid" "$probe_app" || fail "could not install on modern simulator"
xcrun simctl ui "$modern_udid" appearance light || fail "could not select light appearance"
modern_pid=$(launch_probe "$modern_udid" "$artifact_dir/modern.stdout.log" "$artifact_dir/modern.stderr.log") ||
    fail "could not launch appearance probe on modern simulator"

modern_data=$(xcrun simctl get_app_container "$modern_udid" "$bundle_id" data) ||
    fail "could not locate modern probe data container"
modern_state=$modern_data/tmp/cydia-appearance-probe.plist
wait_for_style "$modern_state" light 1 || fail "modern light trait was not reported"
palette=$(read_state "$modern_state" paletteAssertions || true)
[ "$palette" = "true" ] || fail "explicit light/dark palette assertions failed"
light_updates=$(read_state "$modern_state" updates)
xcrun simctl io "$modern_udid" screenshot "$artifact_dir/modern-light.png" >/dev/null ||
    fail "could not capture light appearance"

xcrun simctl ui "$modern_udid" appearance dark || fail "could not select dark appearance"
wait_for_style "$modern_state" dark $((light_updates + 1)) ||
    fail "already-visible probe did not receive a live dark trait update"
kill -0 "$modern_pid" 2>/dev/null || fail "probe relaunched or exited during live appearance switch"
xcrun simctl io "$modern_udid" screenshot "$artifact_dir/modern-dark.png" >/dev/null ||
    fail "could not capture dark appearance"
cmp -s "$artifact_dir/modern-light.png" "$artifact_dir/modern-dark.png" &&
    fail "light and dark screenshots are byte-identical"
pass "same process redrew already-visible Cydia cells from light to dark"

if [ -n "$ios12_udid" ]; then
    xcrun simctl install "$ios12_udid" "$probe_app" || fail "could not install on iOS 12 simulator"
    ios12_pid=$(launch_probe "$ios12_udid" "$artifact_dir/ios12.stdout.log" "$artifact_dir/ios12.stderr.log") ||
        fail "could not launch appearance probe on iOS 12 simulator"
    ios12_data=$(xcrun simctl get_app_container "$ios12_udid" "$bundle_id" data) ||
        fail "could not locate iOS 12 probe data container"
    ios12_state=$ios12_data/tmp/cydia-appearance-probe.plist
    wait_for_style "$ios12_state" light 1 || fail "iOS 12 light fallback was not reported"
    palette=$(read_state "$ios12_state" paletteAssertions || true)
    [ "$palette" = "true" ] || fail "iOS 12 explicit trait fallback assertions failed"
    kill -0 "$ios12_pid" 2>/dev/null || fail "appearance probe exited on iOS 12"
    xcrun simctl io "$ios12_udid" screenshot "$artifact_dir/ios12-light.png" >/dev/null ||
        fail "could not capture iOS 12 fallback"
    pass "iOS 12 launched safely and resolved calibrated light/dark fallbacks"
fi

pass "appearance artifacts: $artifact_dir"
