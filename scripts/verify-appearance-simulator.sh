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

run_with_timeout() {
    rwt_seconds=$1
    shift
    "$@" &
    rwt_pid=$!
    (
        rwt_remaining=$rwt_seconds
        while [ "$rwt_remaining" -gt 0 ] && kill -0 "$rwt_pid" 2>/dev/null; do
            sleep 1
            rwt_remaining=$((rwt_remaining - 1))
        done
        if kill -0 "$rwt_pid" 2>/dev/null; then
            kill -TERM "$rwt_pid" 2>/dev/null || true
            sleep 1
            kill -KILL "$rwt_pid" 2>/dev/null || true
        fi
    ) &
    rwt_watchdog=$!
    wait "$rwt_pid"
    rwt_status=$?
    kill "$rwt_watchdog" 2>/dev/null || true
    wait "$rwt_watchdog" 2>/dev/null || true
    return "$rwt_status"
}

simctl_with_timeout() {
    swt_seconds=$1
    shift
    run_with_timeout "$swt_seconds" xcrun simctl "$@"
}

terminate_and_uninstall() {
    udid=$1
    [ -n "$udid" ] || return 0
    simctl_with_timeout 10 terminate "$udid" "$bundle_id" >/dev/null 2>&1 || true
    simctl_with_timeout 10 uninstall "$udid" "$bundle_id" >/dev/null 2>&1 || true
}

install_probe() {
    udid=$1
    name=$2
    log=$artifact_dir/$name.install.log
    attempt=1
    : >"$log"
    while [ "$attempt" -le 2 ]; do
        if simctl_with_timeout 30 install "$udid" "$probe_app" >>"$log" 2>&1; then
            return 0
        fi
        terminate_and_uninstall "$udid"
        attempt=$((attempt + 1))
        sleep 1
    done
    cat "$log" >&2
    return 1
}

cleanup() {
    if [ -n "$original_appearance" ]; then
        simctl_with_timeout 10 ui "$modern_udid" appearance "$original_appearance" >/dev/null 2>&1 || true
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

require_integer() {
    name=$1
    value=$2
    case "$value" in
        -*) digits=${value#-} ;;
        *) digits=$value ;;
    esac
    case "$digits" in
        ''|*[!0-9]*) fail "$name was not recorded as an integer" ;;
    esac
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
            web_ready=$(read_state "$file" webReady || true)
            web_style=$(read_state "$file" webStyle || true)
            web_events=$(read_state "$file" webAppearanceEvents || true)
            case "$updates" in ''|*[!0-9]*) updates=0 ;; esac
            case "$web_events" in ''|*[!0-9]*) web_events=0 ;; esac
            if [ "$style" = "$expected" ] && [ "$updates" -ge "$minimum_updates" ] && \
               [ "$web_ready" = "true" ] && [ "$web_style" = "$expected" ] && \
               [ "$web_events" -ge 1 ]; then
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
    result=$(simctl_with_timeout 30 launch --terminate-running-process \
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
plutil -lint "$probe_app/Info.plist" >/dev/null || fail "probe Info.plist is invalid"
[ -x "$probe_app/Cydia" ] || fail "probe executable is missing or not executable"

original_appearance=$(simctl_with_timeout 15 ui "$modern_udid" appearance 2>/dev/null) ||
    fail "modern simulator $modern_udid does not support appearance switching"
install_probe "$modern_udid" modern || fail "could not install on modern simulator"
simctl_with_timeout 15 ui "$modern_udid" appearance light || fail "could not select light appearance"
modern_pid=$(launch_probe "$modern_udid" "$artifact_dir/modern.stdout.log" "$artifact_dir/modern.stderr.log") ||
    fail "could not launch appearance probe on modern simulator"

modern_data=$(simctl_with_timeout 15 get_app_container "$modern_udid" "$bundle_id" data) ||
    fail "could not locate modern probe data container"
modern_state=$modern_data/tmp/cydia-appearance-probe.plist
wait_for_style "$modern_state" light 1 || fail "modern light trait was not reported"
palette=$(read_state "$modern_state" paletteAssertions || true)
[ "$palette" = "true" ] || fail "explicit light/dark palette assertions failed"
light_updates=$(read_state "$modern_state" updates)
light_package=$(read_state "$modern_state" packageBackgroundLuminance)
light_section=$(read_state "$modern_state" sectionBackgroundLuminance)
light_source=$(read_state "$modern_state" sourceBackgroundLuminance)
light_loading=$(read_state "$modern_state" loadingBackgroundLuminance)
light_web=$(read_state "$modern_state" webBackgroundLuminance)
light_web_events=$(read_state "$modern_state" webAppearanceEvents)
require_integer light_package "$light_package"
require_integer light_section "$light_section"
require_integer light_source "$light_source"
require_integer light_loading "$light_loading"
require_integer light_web "$light_web"
require_integer light_web_events "$light_web_events"
sleep 1
simctl_with_timeout 30 io "$modern_udid" screenshot "$artifact_dir/modern-light.png" >/dev/null ||
    fail "could not capture light appearance"

simctl_with_timeout 15 ui "$modern_udid" appearance dark || fail "could not select dark appearance"
wait_for_style "$modern_state" dark $((light_updates + 1)) ||
    fail "already-visible probe did not receive a live dark trait update"
dark_package=$(read_state "$modern_state" packageBackgroundLuminance)
dark_section=$(read_state "$modern_state" sectionBackgroundLuminance)
dark_source=$(read_state "$modern_state" sourceBackgroundLuminance)
dark_loading=$(read_state "$modern_state" loadingBackgroundLuminance)
dark_web=$(read_state "$modern_state" webBackgroundLuminance)
dark_web_events=$(read_state "$modern_state" webAppearanceEvents)
require_integer dark_package "$dark_package"
require_integer dark_section "$dark_section"
require_integer dark_source "$dark_source"
require_integer dark_loading "$dark_loading"
require_integer dark_web "$dark_web"
require_integer dark_web_events "$dark_web_events"
if [ "$light_package" -le "$dark_package" ] || \
   [ "$light_section" -le "$dark_section" ] || \
   [ "$light_source" -le "$dark_source" ]; then
    fail "custom cell backgrounds did not resolve through their own trait hooks"
fi
if [ "$light_loading" -le "$dark_loading" ]; then
    fail "native loading view did not resolve through its own trait hook"
fi
if [ "$light_web" -le "$dark_web" ] || [ "$dark_web_events" -le "$light_web_events" ]; then
    fail "Cyte web content did not receive and render the live appearance event"
fi
kill -0 "$modern_pid" 2>/dev/null || fail "probe relaunched or exited during live appearance switch"
sleep 1
simctl_with_timeout 30 io "$modern_udid" screenshot "$artifact_dir/modern-dark.png" >/dev/null ||
    fail "could not capture dark appearance"
cmp -s "$artifact_dir/modern-light.png" "$artifact_dir/modern-dark.png" &&
    fail "light and dark screenshots are byte-identical"
pass "same process redrew already-visible cells, UIKit, and web content from light to dark"

if [ -n "$ios12_udid" ]; then
    install_probe "$ios12_udid" ios12 || fail "could not install on iOS 12 simulator"
    ios12_pid=$(launch_probe "$ios12_udid" "$artifact_dir/ios12.stdout.log" "$artifact_dir/ios12.stderr.log") ||
        fail "could not launch appearance probe on iOS 12 simulator"
    ios12_data=$(simctl_with_timeout 15 get_app_container "$ios12_udid" "$bundle_id" data) ||
        fail "could not locate iOS 12 probe data container"
    ios12_state=$ios12_data/tmp/cydia-appearance-probe.plist
    wait_for_style "$ios12_state" light 1 || fail "iOS 12 light fallback was not reported"
    palette=$(read_state "$ios12_state" paletteAssertions || true)
    [ "$palette" = "true" ] || fail "iOS 12 explicit trait fallback assertions failed"
    ios12_loading=$(read_state "$ios12_state" loadingBackgroundLuminance)
    ios12_web=$(read_state "$ios12_state" webBackgroundLuminance)
    require_integer ios12_loading "$ios12_loading"
    require_integer ios12_web "$ios12_web"
    [ "$ios12_loading" -ge 0 ] && [ "$ios12_web" -ge 0 ] ||
        fail "iOS 12 UIKit/web fallbacks did not resolve"
    kill -0 "$ios12_pid" 2>/dev/null || fail "appearance probe exited on iOS 12"
    sleep 1
    simctl_with_timeout 30 io "$ios12_udid" screenshot "$artifact_dir/ios12-light.png" >/dev/null ||
        fail "could not capture iOS 12 fallback"
    pass "iOS 12 launched safely and resolved calibrated light/dark fallbacks"
fi

pass "appearance artifacts: $artifact_dir"
