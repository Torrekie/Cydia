#!/bin/sh
# Copyright (C) 2026 Torrekie
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

if [ "$#" -ne 4 ]; then
    echo "usage: $0 CASE UDID MAKE BUILD_DIR" >&2
    exit 2
fi

case_name=$1
simulator_udid=$2
make_program=$3
build_dir=$4
source_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P) || exit 2
case "$build_dir" in
    /*) ;;
    *) build_dir=$source_root/$build_dir ;;
esac

case "$case_name" in
    ios12) expected_runtime=12.0 ;;
    ios15) expected_runtime=15.5 ;;
    *)
        echo "[verify-package-detail-simulator][FAIL] CASE must be ios12 or ios15" >&2
        exit 2
        ;;
esac
[ -n "$simulator_udid" ] || {
    echo "[verify-package-detail-simulator][FAIL] simulator UDID is required" >&2
    exit 2
}
[ -z "$(git -C "$source_root" status --porcelain --untracked-files=all)" ] || {
    echo "[verify-package-detail-simulator][FAIL] source worktree must be clean" >&2
    exit 2
}
command -v idb >/dev/null 2>&1 || {
    echo "[verify-package-detail-simulator][FAIL] idb is unavailable" >&2
    exit 2
}
command -v idb_companion >/dev/null 2>&1 || {
    echo "[verify-package-detail-simulator][FAIL] idb_companion is unavailable" >&2
    exit 2
}

bundle_id=com.saurik.Cydia.PackageDetailProbe.p$$
artifact_dir=$build_dir/package-detail-artifacts
temporary=$(mktemp -d "${TMPDIR:-/tmp}/cydia-package-detail.XXXXXX")
probe_app=$temporary/CydiaPackageDetailProbe.app
installed_simulators=
current_companion=
current_developer_dir=
source_head=
binary_sha=
bundle_short_version=
bundle_version=
depiction_server_pid=
depiction_port=
depiction_origin=
depiction_log=$artifact_dir/depiction-server.jsonl

fail() {
    echo "[verify-package-detail-simulator][FAIL] $*" >&2
    exit 1
}

pass() {
    echo "[verify-package-detail-simulator][ ok ] $*"
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

device_is_booted() {
    xcrun simctl list devices | grep -F "($1) (Booted)" >/dev/null 2>&1
}

remove_probe() {
    simulator=$1
    simctl 10 terminate "$simulator" "$bundle_id" >/dev/null 2>&1 || true
    simctl 15 uninstall "$simulator" "$bundle_id" >/dev/null 2>&1 || true
}

container_is_live() {
    simulator=$1
    kind=$2
    if path=$(simctl 10 get_app_container "$simulator" "$bundle_id" "$kind" 2>/dev/null); then
        [ "$(printf '%s\n' "$path" | awk 'END { print NR }')" -eq 1 ] || return 2
        case "$path" in
            /*) ;;
            *) return 2 ;;
        esac
        [ -e "$path" ] && return 0
        return 1
    else
        status=$?
        [ "$status" -eq 2 ] && return 1
        return 2
    fi
}

containers_are_removed() {
    simulator=$1
    for kind in app data; do
        if container_is_live "$simulator" "$kind"; then
            return 1
        else
            status=$?
            [ "$status" -eq 1 ] || return 2
        fi
    done
    return 0
}

app_is_registered() {
    simulator=$1
    applications=$(simctl 15 listapps "$simulator" 2>/dev/null) || return 2
    printf '%s\n' "$applications" | grep -F '"'"$bundle_id"'"' >/dev/null 2>&1
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
            $2 == parent && $1 != previous && $NF ~ /\/usr\/libexec\/lsd$/ {
                print $1
            }
        ')
        case "$replacement" in
            ''|*[!0-9]*) replacement= ;;
            *) break ;;
        esac
        attempts=$((attempts + 1))
        sleep 0.25
    done
    [ -n "$replacement" ] || return 1
    printf '%s device=%s launchd_sim=%s old_lsd=%s new_lsd=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$simulator" "$launchd_pid" \
        "$lsd_pid" "$replacement" >>"$destination/cleanup.log"
}

wait_for_removal() {
    simulator=$1
    destination=$2
    attempts=0
    while [ "$attempts" -lt 60 ]; do
        if containers_are_removed "$simulator"; then
            break
        else
            status=$?
            [ "$status" -eq 1 ] || return 1
        fi
        attempts=$((attempts + 1))
        sleep 0.25
    done
    containers_are_removed "$simulator" || return 1
    if app_is_registered "$simulator"; then
        refresh_simulator_lsd "$simulator" "$destination" || return 1
    else
        status=$?
        [ "$status" -eq 1 ] || return 1
        return 0
    fi
    attempts=0
    while [ "$attempts" -lt 60 ]; do
        if app_is_registered "$simulator"; then
            :
        else
            status=$?
            [ "$status" -eq 1 ] && return 0
            return 1
        fi
        attempts=$((attempts + 1))
        sleep 0.25
    done
    return 1
}

stop_companion() {
    if [ -n "$current_companion" ]; then
        kill -TERM "$current_companion" 2>/dev/null || true
        attempts=0
        while kill -0 "$current_companion" 2>/dev/null && [ "$attempts" -lt 40 ]; do
            sleep 0.25
            attempts=$((attempts + 1))
        done
        kill -KILL "$current_companion" 2>/dev/null || true
        wait "$current_companion" 2>/dev/null || true
        current_companion=
        current_developer_dir=
    fi
}

cleanup() {
    original_status=$?
    cleanup_status=0
    trap - EXIT HUP INT TERM
    stop_companion
    if [ -n "$depiction_server_pid" ]; then
        kill -TERM "$depiction_server_pid" 2>/dev/null || true
        wait "$depiction_server_pid" 2>/dev/null || true
        depiction_server_pid=
    fi
    for simulator in $installed_simulators; do
        destination=$artifact_dir/unknown
        [ "$simulator" = "$ios12_udid" ] && destination=$artifact_dir/ios12
        [ "$simulator" = "$ios15_udid" ] && destination=$artifact_dir/ios15
        mkdir -p "$destination"
        remove_probe "$simulator"
        if ! wait_for_removal "$simulator" "$destination"; then
            echo "[verify-package-detail-simulator][cleanup] stale probe on $simulator" >&2
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

free_port() {
    /usr/bin/python3 - <<'PY'
import socket
sock = socket.socket()
sock.bind(("127.0.0.1", 0))
print(sock.getsockname()[1])
sock.close()
PY
}

start_depiction_server() {
    depiction_port=$(free_port)
    : >"$depiction_log"
    /usr/bin/python3 "$source_root/tests/simulator/package_depiction_server.py" \
        --port "$depiction_port" --log "$depiction_log" \
        >"$artifact_dir/depiction-server.stdout.log" \
        2>"$artifact_dir/depiction-server.stderr.log" &
    depiction_server_pid=$!
    attempts=0
    while [ "$attempts" -lt 80 ]; do
        kill -0 "$depiction_server_pid" 2>/dev/null || return 1
        if /usr/bin/curl --noproxy '*' --fail --silent \
                "http://127.0.0.1:$depiction_port/ready" >/dev/null 2>&1; then
            depiction_origin=http://127.0.0.1:$depiction_port
            return 0
        fi
        attempts=$((attempts + 1))
        sleep 0.25
    done
    return 1
}

start_companion() {
    simulator=$1
    destination=$2
    default_developer=$(xcode-select -p 2>/dev/null || true)
    preferred_developer=${CYDIA_PACKAGE_XCODE_PATH:-}
    case "$preferred_developer" in
        *.app) preferred_developer=$preferred_developer/Contents/Developer ;;
    esac
    alternate_developer=$HOME/Downloads/Xcode.app/Contents/Developer
    attempted=
    for developer in "$preferred_developer" "$default_developer" "$alternate_developer"; do
        [ -n "$developer" ] || continue
        [ -d "$developer" ] || continue
        case " $attempted " in
            *" $developer "*) continue ;;
        esac
        attempted="$attempted $developer"
        port=$(free_port)
        env -i HOME="$HOME" \
            PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
            DEVELOPER_DIR="$developer" LC_ALL=C.UTF-8 \
            idb_companion --udid "$simulator" --grpc-port "$port" --log-level info \
            >"$destination/idb-companion.log" 2>&1 &
        current_companion=$!
        attempts=0
        connected=
        while [ "$attempts" -lt 80 ]; do
            kill -0 "$current_companion" 2>/dev/null || break
            if run_with_timeout 5 idb connect localhost "$port" \
                    >"$destination/idb-connect.log" 2>&1; then
                connected=1
                break
            fi
            attempts=$((attempts + 1))
            sleep 0.25
        done
        if [ -n "$connected" ]; then
            idb list-targets >"$destination/idb-targets.log" 2>&1 || connected=
        fi
        if [ -n "$connected" ] &&
           grep -F "$simulator" "$destination/idb-targets.log" >/dev/null 2>&1; then
            current_developer_dir=$developer
            printf '%s\n' "$port" >"$destination/idb-port.txt"
            return 0
        fi
        stop_companion
    done
    return 1
}

read_state() {
    plutil -extract "$2" raw -o - "$1" 2>/dev/null
}

wait_for_state() {
    file=$1
    phase=$2
    style=$3
    content_size=$4
    expected_pid=$5
    snapshot=$temporary/package-detail-wait-state.plist
    attempts=0
    while [ "$attempts" -lt 180 ]; do
        if [ -f "$file" ] && cp "$file" "$snapshot" 2>/dev/null; then
            ready=$(read_state "$snapshot" ready || true)
            actual_phase=$(read_state "$snapshot" phase || true)
            actual_style=$(read_state "$snapshot" style || true)
            actual_size=$(read_state "$snapshot" contentSize || true)
            actual_pid=$(read_state "$snapshot" processID || true)
            if [ "$ready" = true ] && [ "$actual_phase" = "$phase" ] &&
               [ "$actual_style" = "$style" ] &&
               [ "$actual_size" = "$content_size" ] &&
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

wait_for_value() {
    file=$1
    key=$2
    expected=$3
    attempts=0
    while [ "$attempts" -lt 100 ]; do
        actual=$(read_state "$file" "$key" || true)
        [ "$actual" = "$expected" ] && return 0
        attempts=$((attempts + 1))
        sleep 0.25
    done
    return 1
}

wait_for_offset_at_top() {
    file=$1
    attempts=0
    while [ "$attempts" -lt 100 ]; do
        offset=$(read_state "$file" tableOffset || true)
        if awk -v value="$offset" 'BEGIN { exit !(value >= -1.0 && value <= 1.0) }'; then
            return 0
        fi
        attempts=$((attempts + 1))
        sleep 0.25
    done
    return 1
}

wait_for_depiction_link_position() {
    file=$1
    attempts=0
    while [ "$attempts" -lt 100 ]; do
        frame_y=$(read_state "$file" depictionFrameY || true)
        offset=$(read_state "$file" tableOffset || true)
        visible=$(read_state "$file" depictionVisible || true)
        screen_height=$(read_state "$file" screenHeight || true)
        if [ "$visible" = true ] &&
           awk -v y="$frame_y" -v offset="$offset" -v height="$screen_height" 'BEGIN {
               exit !(y >= 0.0 && y + 74.0 <= height && offset > 100.0)
           }'; then
            return 0
        fi
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
    [ "$actual" = "$expected" ] ||
        fail "$message ($key=$actual, expected=$expected)"
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
    }' || fail "$message ($key=$actual, expected $operator $expected)"
}

assert_files_equal() {
    left_file=$1
    right_file=$2
    key=$3
    message=$4
    left=$(read_state "$left_file" "$key" || true)
    right=$(read_state "$right_file" "$key" || true)
    [ "$left" = "$right" ] || fail "$message ($key changed from $left to $right)"
}

copy_phase() {
    state=$1
    destination=$2
    name=$3
    cp "$state" "$destination/$name-state.plist"
    plutil -convert json -r -o "$destination/$name-ui-tree.json" "$state"
    simctl 30 io "$4" screenshot "$destination/$name.png" >/dev/null ||
        fail "could not capture $name screenshot"
}

screenshot_point_size() {
    image=$1
    scale=$2
    /usr/bin/python3 - "$image" "$scale" <<'PY'
import struct
import sys
with open(sys.argv[1], "rb") as stream:
    header = stream.read(24)
if len(header) != 24 or header[:8] != b"\x89PNG\r\n\x1a\n" or header[12:16] != b"IHDR":
    raise SystemExit(1)
width, height = struct.unpack(">II", header[16:24])
scale = float(sys.argv[2])
if scale <= 0:
    raise SystemExit(1)
print(f"{width / scale:.6f} {height / scale:.6f}")
PY
}

verify_full_state() {
    state=$1
    expected_runtime=$2
    launched_pid=$3
    assert_state "$state" schema 5 "package probe schema changed"
    assert_state "$state" fixtureVersion production-package-shell-and-depiction-v4 \
        "fixture version changed"
    assert_state "$state" systemVersion "$expected_runtime" "runtime version changed"
    assert_state "$state" processID "$launched_pid" "state PID differs from launch"
    assert_state "$state" buildEvidence.sourceHEAD "$source_head" "state HEAD is stale"
    assert_state "$state" buildEvidence.binarySHA256 "$binary_sha" "state binary is stale"
    assert_state "$state" buildEvidence.bundleShortVersion "$bundle_short_version" \
        "short version evidence changed"
    assert_state "$state" buildEvidence.bundleVersion "$bundle_version" \
        "bundle version evidence changed"
    assert_state "$state" controllerClass CYPackageController \
        "retained production package controller was not installed"
    assert_state "$state" probeOnly false "production probe regressed to renderer-only"
    assert_state "$state" productionRoute CYPackageController \
        "production package route class changed"
    assert_state "$state" identity runtime:iphoneos-arm64 \
        "qualified package identity changed"
    assert_state "$state" navigationURL cydia://package/runtime:iphoneos-arm64 \
        "package route no longer round-trips"
    assert_state "$state" multiArch same "multiarch state changed"
    assert_state "$state" primaryModifyKey MODIFY "Modify action title changed"
    assert_state "$state" sectionCount 7 "native package section count changed"
    assert_state "$state" rowIdentifiers 12 "native package row count changed"
    assert_state "$state" rowIdentifiers.0 cydia.package.queue "queue is not first"
    assert_state "$state" rowIdentifiers.1 cydia.package.action.settings \
        "settings row moved"
    assert_state "$state" rowIdentifiers.5 cydia.package.warning.0 "warning row moved"
    assert_state "$state" rowIdentifiers.6 cydia.package.description "description row moved"
    assert_state "$state" rowIdentifiers.8 cydia.package.installed.version \
        "installed details moved"
    assert_state "$state" rowIdentifiers.10 cydia.package.source.name "source details moved"
    assert_state "$state" nativeRegionOrder.0 topper "topper region moved"
    assert_state "$state" nativeRegionOrder.1 native-body "native body region moved"
    assert_state "$state" nativeRegionOrder.2 footer "footer region moved"
    assert_state "$state" headerPresent true "package topper is absent"
    assert_number "$state" headerIconWidth ge 63.9 "package icon is below 64 points"
    assert_number "$state" headerIconWidth le 64.1 "package icon exceeds 64 points"
    assert_state "$state" headerLabelsFit true "package topper clips metadata"
    assert_state "$state" footerPresent true "package footer is absent"
    assert_state "$state" tableCentered true "package table is not centered"
    assert_number "$state" tableWidth le 414 "package table exceeded legacy maximum width"
    assert_state "$state" scrollOwnerCount 1 "package shell has multiple scroll owners"
    assert_state "$state" scrollViewCount 1 "depiction-less shell gained a hidden scroll view"
    assert_state "$state" embeddedBrowserCount 0 "native shell contains a browser"
    assert_state "$state" depictionRegionPresent false \
        "depiction island appeared before its checkpoint"
    assert_state "$state" depictionState idle "depiction-less shell gained depiction state"
    assert_state "$state" depictionStarted false "depiction-less shell started a web request"
    assert_state "$state" descriptionRegionPresent true \
        "depiction-less description fallback disappeared"
    assert_state "$state" homepageRegionPresent true \
        "depiction-less homepage fallback disappeared"
    assert_state "$state" rowsFit true "package rows clip text"
    assert_state "$state" rowsMeetTouchTarget true "package rows are below 44 points"
    assert_state "$state" rowIconsFit true "package row icons exceed 29 points"
    assert_state "$state" legacyRowIcons 8 "legacy package row icon count changed"
    assert_state "$state" legacyRowIcons.0.row cydia.package.queue \
        "queue row lost its historical mode icon"
    assert_state "$state" legacyRowIcons.0.asset Modes/INSTALL.png \
        "queue row mode icon asset changed"
    assert_state "$state" legacyRowIcons.1.row cydia.package.action.settings \
        "settings row lost its historical icon"
    assert_state "$state" legacyRowIcons.1.asset settings.png \
        "settings row icon asset changed"
    assert_state "$state" legacyRowIcons.2.row cydia.package.action.contact \
        "contact row lost its historical icon"
    assert_state "$state" legacyRowIcons.2.asset email.png \
        "contact row icon asset changed"
    assert_state "$state" legacyRowIcons.3.row cydia.package.action.console \
        "console row lost its historical icon"
    assert_state "$state" legacyRowIcons.3.asset console.png \
        "console row icon asset changed"
    assert_state "$state" legacyRowIcons.4.row cydia.package.warning.0 \
        "warning row lost its historical icon"
    assert_state "$state" legacyRowIcons.4.asset warning.png \
        "warning row icon asset changed"
    assert_state "$state" legacyRowIcons.5.row cydia.package.action.homepage \
        "homepage row lost its historical icon"
    assert_state "$state" legacyRowIcons.5.asset web.png \
        "homepage row icon asset changed"
    assert_state "$state" legacyRowIcons.6.row cydia.package.installed.version \
        "version row lost its historical icon"
    assert_state "$state" legacyRowIcons.6.asset version.png \
        "version row icon asset changed"
    assert_state "$state" legacyRowIcons.7.row cydia.package.action.files \
        "filesystem row lost its historical icon"
    assert_state "$state" legacyRowIcons.7.asset filesystem.png \
        "filesystem row icon asset changed"
    assert_state "$state" navigationBarHidden false "package navigation bar is hidden"
    assert_state "$state" accessibilityOrder 17 "accessibility order count changed"
    assert_state "$state" accessibilityOrder.0 cydia.package.header.icon \
        "header icon is not first in accessibility order"
    assert_state "$state" accessibilityOrder.4 cydia.package.queue \
        "queue is not first after the topper"
    assert_state "$state" accessibilityOrder.16 cydia.package.footer \
        "footer is not last in accessibility order"
    localized_queue=$(read_state "$state" localizedQueueTitle)
    localized_mode=$(read_state "$state" localizedModeTitle)
    assert_state "$state" accessibilityElements.4.label "$localized_queue" \
        "queue accessibility label changed"
    assert_state "$state" accessibilityElements.4.value "$localized_mode" \
        "queue accessibility value changed"
    assert_state "$state" accessibilityElements.9.identifier cydia.package.warning.0 \
        "warning accessibility identity changed"
    warning_label=$(read_state "$state" accessibilityElements.9.label || true)
    localized_warning=$(read_state "$state" localizedWarningTitle)
    printf '%s\n' "$warning_label" | grep -F "$localized_warning" >/dev/null ||
        fail "warning accessibility label omitted its localized warning role"
    printf '%s\n' "$warning_label" | grep -F "Runtime package warning" >/dev/null ||
        fail "warning accessibility label omitted its visible warning text"
}

verify_depiction_loaded_state() {
    state=$1
    phase=$2
    minimum_height=$3
    maximum_height=$4
    assert_state "$state" schema 5 "depiction probe schema changed"
    assert_state "$state" fixtureVersion production-package-shell-and-depiction-v4 \
        "depiction fixture version changed"
    assert_state "$state" phase "$phase" "depiction phase changed"
    assert_state "$state" identity runtime:iphoneos-arm64 \
        "depiction package identity changed"
    assert_state "$state" productionRoute CYPackageController \
        "production package route switched during depiction probe"
    assert_state "$state" sectionCount 6 "depiction hierarchy section count changed"
    assert_state "$state" rowIdentifiers 11 "depiction hierarchy row count changed"
    assert_state "$state" rowIdentifiers.5 cydia.package.warning.0 \
        "warning no longer precedes depiction"
    assert_state "$state" rowIdentifiers.6 cydia.package.depiction.cell \
        "depiction does not follow native package information"
    assert_state "$state" rowIdentifiers.7 cydia.package.installed.version \
        "installed details do not follow depiction"
    assert_state "$state" rowIdentifiers.9 cydia.package.source.name \
        "source details do not remain in the native footer region"
    assert_state "$state" nativeRegionOrder 4 "depiction region count changed"
    assert_state "$state" nativeRegionOrder.0 topper "depiction moved before topper"
    assert_state "$state" nativeRegionOrder.1 native-body "native details moved"
    assert_state "$state" nativeRegionOrder.2 depiction "depiction is not expanded in place"
    assert_state "$state" nativeRegionOrder.3 native-footer "native footer moved before depiction"
    assert_state "$state" depictionRegionPresent true "depiction region is absent"
    assert_state "$state" depictionDocumentPresent true "depiction document view is absent"
    assert_state "$state" depictionState loaded "depiction did not finish loading"
    assert_state "$state" depictionStarted true "depiction request never started"
    assert_state "$state" depictionLoadError false "loaded depiction reports an error"
    assert_number "$state" depictionContentHeight gt "$minimum_height" \
        "depiction did not expand to document height"
    assert_number "$state" depictionContentHeight lt "$maximum_height" \
        "depiction exceeded its expected bounded height"
    assert_number "$state" depictionFrameHeight gt "$minimum_height" \
        "depiction table row did not adopt document height"
    assert_state "$state" descriptionRegionPresent false \
        "web depiction duplicated native description fallback"
    assert_state "$state" homepageRegionPresent false \
        "web depiction duplicated legacy-suppressed homepage fallback"
    assert_state "$state" embeddedBrowserCount 1 \
        "depiction shell created zero or multiple embedded browsers"
    assert_number "$state" scrollViewCount ge 2 \
        "depiction engine scroll surface was not observable"
    assert_state "$state" scrollOwnerCount 1 \
        "depiction introduced a second enabled scrolling owner"
    assert_state "$state" accessibilityOrder.10 cydia.package.depiction.document \
        "accessibility order does not enter the depiction after native details"
    assert_state "$state" accessibilityOrder.15 cydia.package.footer \
        "accessibility order does not return to the native footer"
    if [ "$phase" = depiction-short ]; then
        assert_state "$state" depictionResourceProbeStarted true \
            "custom depiction resource probe never started"
        assert_state "$state" depictionResourceProbeComplete true \
            "custom depiction resource probe did not settle"
        assert_state "$state" depictionResourceProbeError "" \
            "custom depiction resource probe reported an error"
        assert_number "$state" depictionResourceProbeAttempts ge 1 \
            "custom depiction resource probe recorded no attempt"
        assert_number "$state" depictionResourceProbeAttempts le 20 \
            "custom depiction resource probe exceeded its bounded retries"
        assert_state "$state" depictionResourcePositiveSource \
            cydia://section-icon/System \
            "custom depiction resource source changed"
        assert_state "$state" depictionResourcePositiveComplete true \
            "custom depiction resource did not finish"
        assert_state "$state" depictionResourcePositiveNaturalWidth 120 \
            "custom depiction resource did not render the bundled 120px icon"
        assert_state "$state" depictionResourcePositiveNaturalHeight 120 \
            "custom depiction resource height changed"
        assert_state "$state" depictionResourceRejectedSource \
            cydia://section-icon/%2Fetc \
            "rejected depiction resource source changed"
        assert_state "$state" depictionResourceRejectedComplete true \
            "rejected depiction resource did not settle"
        assert_state "$state" depictionResourceRejectedNaturalWidth 0 \
            "path-like depiction resource unexpectedly rendered"
    fi
}

verify_depiction_failure_state() {
    state=$1
    phase=$2
    assert_state "$state" phase "$phase" "failed depiction phase changed"
    assert_state "$state" depictionRegionPresent true "failed depiction row disappeared"
    assert_state "$state" depictionState failed "rejected depiction did not enter native error state"
    assert_state "$state" depictionLoadError true "failed depiction omitted typed error state"
    assert_state "$state" depictionErrorRegionPresent true "native depiction error actions are hidden"
    assert_state "$state" descriptionRegionPresent false \
        "failed validated depiction silently changed to package description"
    assert_state "$state" scrollOwnerCount 1 \
        "failed depiction left a second enabled scroll owner"
    assert_state "$state" lastAction "" "automatic hostile depiction reached native delegate"
    assert_state "$state" lastURLString "" "automatic hostile depiction requested a URL handoff"
}

verify_depiction_hostile_state() {
    state=$1
    assert_state "$state" phase depiction-hostile "hostile depiction phase changed"
    assert_state "$state" depictionRegionPresent true "hostile depiction row disappeared"
    actual_state=$(read_state "$state" depictionState || true)
    case "$actual_state" in
        failed)
            assert_state "$state" depictionLoadError true \
                "adapter-rejected hostile depiction omitted its error"
            assert_state "$state" depictionErrorRegionPresent true \
                "adapter-rejected hostile depiction hid native recovery actions"
            ;;
        loaded)
            assert_state "$state" depictionLoadError false \
                "engine-blocked hostile depiction invented a load error"
            assert_state "$state" depictionErrorRegionPresent false \
                "engine-blocked hostile depiction showed false recovery actions"
            ;;
        *) fail "hostile depiction reached unexpected state $actual_state" ;;
    esac
    assert_state "$state" lastAction "" \
        "automatic hostile depiction reached native delegate"
    assert_state "$state" lastURLString "" \
        "automatic hostile depiction requested a URL handoff"
    assert_state "$state" depictionLastNavigationUserActivated false \
        "automatic hostile route acquired user activation"
    custom_url=$(read_state "$state" depictionLastNavigationURLString || true)
    if [ "$custom_url" = cydia://launch/com.apple.Preferences ]; then
        assert_state "$state" depictionLastNavigationDisposition 0 \
            "adapter did not reject the observed automatic custom route"
    fi
}

verify_depiction_server_log() {
    log=$1
    /usr/bin/python3 - "$log" <<'PY'
import json
import sys

entries = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
paths = {entry["path"].split("?", 1)[0] for entry in entries}
required = {"/short", "/long", "/frame", "/pixel.png", "/hostile",
            "/hostile-fired", "/cross-redirect"}
missing = sorted(required - paths)
if missing:
    raise SystemExit("missing depiction requests: " + ", ".join(missing))
controlled = {"x-cydia-id", "x-cydia-cf", "x-machine", "x-unique-id"}
for entry in entries:
    headers = {key.lower(): value for key, value in entry.get("headers", {}).items()}
    leaked = sorted(controlled & set(headers))
    if leaked:
        raise SystemExit(f"identity header leak on {entry['path']}: {', '.join(leaked)}")
    if headers.get("host", "").lower().startswith("localhost:"):
        raise SystemExit("cross-origin main redirect reached transport")
print("[verify-package-detail-simulator][ ok ] depiction transport has no Cydia identity headers")
PY
}

write_parity_note() {
    destination=$1
    cat >"$destination/parity-note.md" <<'EOF'
# Native package shell and depiction-island calibration

- Preserved hierarchy: 64-point package topper, queued mode, settings/contact/console/application actions, warnings, expanded description, homepage, installed details, source details, and identity footer.
- Preserved geometry: centered content capped at 414 points, compact 29-point field icons, roughly 44-point interactive rows, and one outer scrolling table.
- Depiction exception: a validated repository document replaces only the legacy description/homepage branch, expands between native warnings and native installed/source/footer information, and leaves the embedded engine's own scrolling disabled.
- Deterministic evidence: short and long pages include images, a same-origin iframe, and a qualified package link; a real HID tap hands that link to the typed native delegate. A cross-origin main redirect enters native Retry/external controls. An automatic custom-scheme click is either blocked by WebKit before policy or explicitly rejected by the adapter, and never reaches the native delegate.
- Privacy boundary: the fixture transport receives none of X-Cydia-Id, X-Cydia-Cf, X-Machine, or X-Unique-ID. The adapter contains no Cydia bridge or script message handler.
- Intentional modern differences: UIKit safe-area/navigation metrics, Dynamic Type wrapping, semantic light/dark colors, and bundled local icon substitutes for the retired remote template assets.
- Production compatibility: the retained public `CYPackageController` now subclasses the native shell; both typed package routes and package-list selection continue to construct it, while the former remote `#!/package` UI and private-WebKit superclass are absent.
- Remaining acceptance: same-package legacy/native comparison and rooted/rootless device package-route evidence remain separate gates before P1.1 closes.
EOF
    grep -Fq 'retained public `CYPackageController` now subclasses the native shell' \
        "$destination/parity-note.md" || fail "$label production parity note is stale"
}

write_checksums() {
    destination=$1
    : >"$destination/SHA256SUMS"
    find "$destination" -type f ! -name SHA256SUMS -print | LC_ALL=C sort |
    while IFS= read -r file; do
        shasum -a 256 "$file"
    done >"$destination/SHA256SUMS"
}

run_probe() {
    simulator=$1
    label=$2
    expected_runtime=$3
    device_is_booted "$simulator" || fail "$label simulator is not booted"
    destination=$artifact_dir/$label
    mkdir -p "$destination"
    : >"$depiction_log"
    touch "$destination/launch-marker"
    remove_probe "$simulator"
    simctl 30 install "$simulator" "$probe_app" >"$destination/install.log" 2>&1 ||
        fail "could not install on $label"
    installed_simulators="$installed_simulators $simulator"
    app_container=$(simctl 20 get_app_container "$simulator" "$bundle_id" app) ||
        fail "could not locate $label app container"
    installed_sha=$(shasum -a 256 "$app_container/Cydia" | awk '{ print $1 }')
    [ "$installed_sha" = "$binary_sha" ] || fail "$label installed binary hash mismatch"
    start_companion "$simulator" "$destination" || fail "$label idb companion failed"
    {
        echo "source-head=$source_head"
        echo "binary-sha256=$binary_sha"
        echo "installed-binary-sha256=$installed_sha"
        echo "bundle-short-version=$bundle_short_version"
        echo "bundle-version=$bundle_version"
        echo "depiction-origin=$depiction_origin"
        echo "developer-dir=$current_developer_dir"
        DEVELOPER_DIR="$current_developer_dir" xcodebuild -version
    } >"$destination/provenance.txt"
    run_with_timeout 30 env \
        SIMCTL_CHILD_CYDIA_PROBE_SOURCE_HEAD="$source_head" \
        SIMCTL_CHILD_CYDIA_PROBE_BINARY_SHA256="$binary_sha" \
        SIMCTL_CHILD_CYDIA_PROBE_BUNDLE_SHORT_VERSION="$bundle_short_version" \
        SIMCTL_CHILD_CYDIA_PROBE_BUNDLE_VERSION="$bundle_version" \
        SIMCTL_CHILD_CYDIA_PROBE_DEPICTION_ORIGIN="$depiction_origin" \
        xcrun simctl launch --stdout="$destination/stdout.log" \
        --stderr="$destination/stderr.log" "$simulator" "$bundle_id" \
        --cydia-appearance-probe --cydia-package-detail-probe \
        >"$destination/launch.log" 2>&1 || fail "could not launch on $label"
    launched_pid=$(awk -F ': ' '/: [0-9]+$/ { value=$NF } END { print value }' \
        "$destination/launch.log")
    case "$launched_pid" in
        ''|*[!0-9]*) fail "$label launch did not report a PID" ;;
    esac
    data_container=$(simctl 20 get_app_container "$simulator" "$bundle_id" data) ||
        fail "could not locate $label data container"
    state=$data_container/tmp/cydia-package-detail-probe.plist
    wait_for_state "$state" full light large "$launched_pid" ||
        fail "$label full light state did not become ready"
    verify_full_state "$state" "$expected_runtime" "$launched_pid"
    cp "$state" "$destination/full-light-state.plist"
    light_state=$destination/full-light-state.plist
    light_controller=$(read_state "$light_state" controllerToken)
    light_model=$(read_state "$light_state" modelToken)
    light_luminance=$(read_state "$light_state" backgroundLuminance)
    light_font=$(read_state "$light_state" nameFontSize)
    copy_phase "$state" "$destination" full-light "$simulator"

    width=$(read_state "$state" screenWidth)
    height=$(read_state "$state" screenHeight)
    screen_scale=$(read_state "$state" screenScale)
    set -- $(screenshot_point_size "$destination/full-light.png" "$screen_scale")
    hid_width=$1
    hid_height=$2
    modify_x=$(awk -v app="$width" -v hid="$hid_width" \
        'BEGIN { printf "%d", (app - 35.0) * hid / app }')
    modify_y=$(awk -v app="$height" -v hid="$hid_height" \
        'BEGIN { printf "%d", 66.0 * hid / app }')
    run_with_timeout 15 idb ui tap --udid "$simulator" "$modify_x" "$modify_y" \
        >"$destination/hid-interactions.log" 2>&1 || fail "$label Modify HID tap failed"
    printf 'tap modify x=%s y=%s app=%sx%s hid=%sx%s\n' "$modify_x" "$modify_y" \
        "$width" "$height" "$hid_width" "$hid_height" \
        >>"$destination/hid-interactions.log"
    wait_for_value "$state" modifySheetVisible true || fail "$label Modify sheet did not open"
    assert_state "$state" modifyActionTitles 5 "Modify sheet action count changed"
    copy_phase "$state" "$destination" modify-sheet "$simulator"
    touch "$data_container/tmp/cydia-package-detail-probe-dismiss"
    wait_for_value "$state" modifySheetVisible false || fail "$label Modify sheet did not dismiss"

    swipe_x=$(awk -v hid="$hid_width" 'BEGIN { printf "%d", hid / 2.0 }')
    swipe_start=$(awk -v app="$height" -v hid="$hid_height" \
        'BEGIN { printf "%d", (app - 115.0) * hid / app }')
    swipe_end=$(awk -v app="$height" -v hid="$hid_height" \
        'BEGIN { printf "%d", 180.0 * hid / app }')
    swipes=0
    while [ "$swipes" -lt 4 ]; do
        run_with_timeout 15 idb ui swipe --udid "$simulator" --duration 0.4 \
            "$swipe_x" "$swipe_start" "$swipe_x" "$swipe_end" \
            >>"$destination/hid-interactions.log" 2>&1 || fail "$label HID swipe failed"
        swipes=$((swipes + 1))
        printf 'swipe=%s x=%s y1=%s y2=%s\n' "$swipes" "$swipe_x" \
            "$swipe_start" "$swipe_end" >>"$destination/hid-interactions.log"
        wait_for_value "$state" footerVisible true && break
    done
    assert_state "$state" footerVisible true "real HID scrolling did not expose footer"
    assert_number "$state" tableOffset gt 0 "real HID scrolling did not move the table"
    copy_phase "$state" "$destination" full-light-footer "$simulator"

    touch "$data_container/tmp/cydia-package-detail-probe-top"
    wait_for_offset_at_top "$state" || fail "$label table did not return to its topper"
    touch "$data_container/tmp/cydia-package-detail-probe-dark"
    wait_for_state "$state" full dark large "$launched_pid" ||
        fail "$label dark state did not become ready"
    assert_state "$state" controllerToken "$light_controller" \
        "dark transition replaced the controller"
    assert_state "$state" modelToken "$light_model" "dark transition replaced the model"
    assert_number "$state" backgroundLuminance lt "$light_luminance" \
        "dark transition did not darken the grouped background"
    copy_phase "$state" "$destination" full-dark "$simulator"

    touch "$data_container/tmp/cydia-package-detail-probe-accessibility"
    wait_for_state "$state" full dark accessibility-large "$launched_pid" ||
        fail "$label Accessibility Large state did not become ready"
    assert_state "$state" controllerToken "$light_controller" \
        "Dynamic Type transition replaced the controller"
    assert_state "$state" modelToken "$light_model" \
        "Dynamic Type transition replaced the model"
    assert_number "$state" nameFontSize gt "$light_font" \
        "Accessibility Large did not increase the package title font"
    assert_state "$state" headerLabelsFit true \
        "Accessibility Large clips package topper metadata"
    assert_state "$state" rowsFit true "Accessibility Large clips package text"
    assert_state "$state" rowsMeetTouchTarget true \
        "Accessibility Large reduced a touch target"
    copy_phase "$state" "$destination" full-dark-accessibility "$simulator"

    touch "$data_container/tmp/cydia-package-detail-probe-sparse"
    wait_for_state "$state" sparse light large "$launched_pid" ||
        fail "$label sparse state did not become ready"
    assert_state "$state" identity tool:iphoneos-arm "sparse identity changed"
    assert_state "$state" navigationURL cydia://package/tool:iphoneos-arm \
        "sparse package route changed"
    assert_state "$state" multiArch foreign "foreign package identity was normalized"
    assert_state "$state" sectionCount 1 "sparse package invented metadata sections"
    assert_state "$state" rowIdentifiers 2 "sparse package action count changed"
    assert_state "$state" rowIdentifiers.1 cydia.package.action.contact \
        "maintainer fallback contact row moved"
    localized_author=$(read_state "$state" localizedAuthorTitle)
    assert_state "$state" accessibilityElements.5.label "$localized_author" \
        "maintainer fallback no longer displays the legacy Author title"
    assert_state "$state" accessibilityElements.5.value "Runtime Maintainer" \
        "maintainer fallback lost its visible contact value"
    assert_state "$state" embeddedBrowserCount 0 "sparse shell contains a browser"
    assert_state "$state" depictionRegionPresent false "sparse shell invented depiction chrome"
    sparse_controller=$(read_state "$state" controllerToken)
    sparse_model=$(read_state "$state" modelToken)
    [ "$sparse_controller" != "$light_controller" ] ||
        fail "$label sparse phase did not create a fresh controller"
    [ "$sparse_model" != "$light_model" ] || fail "$label sparse phase reused the model"
    copy_phase "$state" "$destination" sparse-light "$simulator"

    touch "$data_container/tmp/cydia-package-detail-probe-depiction-short"
    wait_for_state "$state" depiction-short light large "$launched_pid" ||
        fail "$label short depiction did not settle"
    verify_depiction_loaded_state "$state" depiction-short 300 1200
    assert_state "$state" depictionInitialURL "$depiction_origin/short" \
        "short depiction URL changed"
    short_controller=$(read_state "$state" controllerToken)
    short_model=$(read_state "$state" modelToken)
    copy_phase "$state" "$destination" depiction-short-light "$simulator"

    touch "$data_container/tmp/cydia-package-detail-probe-depiction-top"
    if ! wait_for_depiction_link_position "$state"; then
        cp "$state" "$destination/depiction-position-failure-state.plist"
        fail "$label depiction did not reach a visible post-scroll link position"
    fi
    frame_x=$(read_state "$state" depictionFrameX)
    frame_y=$(read_state "$state" depictionFrameY)
    frame_width=$(read_state "$state" depictionFrameWidth)
    link_x=$(awk -v x="$frame_x" -v w="$frame_width" -v app="$width" -v hid="$hid_width" \
        'BEGIN { printf "%d", (x + w / 2.0) * hid / app }')
    link_y=$(awk -v y="$frame_y" -v app="$height" -v hid="$hid_height" \
        'BEGIN { printf "%d", (y + 37.0) * hid / app }')
    run_with_timeout 15 idb ui tap --udid "$simulator" "$link_x" "$link_y" \
        >>"$destination/hid-interactions.log" 2>&1 ||
        fail "$label depiction-link HID tap failed"
    printf 'tap depiction-link x=%s y=%s frame=%s,%s,%s\n' \
        "$link_x" "$link_y" "$frame_x" "$frame_y" "$frame_width" \
        >>"$destination/hid-interactions.log"
    if ! wait_for_value "$state" lastAction navigation-6; then
        cp "$state" "$destination/depiction-link-failure-state.plist"
        for key in depictionUserTouchSequence depictionInvalidatedTouchSequence \
                depictionLastNavigationType depictionLastNavigationUserActivated \
                depictionLastNavigationDisposition depictionLastNavigationURLString \
                lastAction lastURLString; do
            printf '%s=%s\n' "$key" "$(read_state "$state" "$key" || true)" >&2
        done
        fail "$label real depiction link did not reach typed delegate"
    fi
    assert_number "$state" depictionUserTouchSequence ge 1 \
        "depiction link had no physical touch activation"
    assert_state "$state" depictionLastNavigationType 0 \
        "depiction link was not a WK link-activation navigation"
    assert_state "$state" depictionLastNavigationUserActivated true \
        "depiction link did not consume physical activation"
    assert_state "$state" depictionLastNavigationDisposition 2 \
        "depiction link was not handed out of the island"
    assert_state "$state" depictionLastNavigationURLString \
        cydia://package/linked:iphoneos-arm64 \
        "depiction adapter changed the qualified target URL"
    assert_state "$state" lastActionIdentity runtime:iphoneos-arm64 \
        "depiction handoff lost current package identity"
    assert_state "$state" lastURLString cydia://package/linked:iphoneos-arm64 \
        "depiction handoff changed the qualified target package URL"
    assert_state "$state" lastReferrer cydia://package/runtime:iphoneos-arm64 \
        "depiction handoff lost its native package referrer"
    assert_state "$state" lastRouteCaller 3 \
        "depiction handoff was promoted above repository authority"
    assert_state "$state" lastRouteNavigationKind 0 \
        "depiction handoff did not enter direct typed dispatch"
    assert_state "$state" lastRouteMainFrame true \
        "depiction handoff lost its initiating main-frame scope"
    assert_state "$state" lastRouteUserGesture true \
        "depiction handoff lost the consumed physical gesture"
    assert_state "$state" controllerToken "$short_controller" \
        "depiction link replaced its native controller"
    assert_state "$state" modelToken "$short_model" \
        "depiction link replaced its package snapshot"
    copy_phase "$state" "$destination" depiction-link-handoff "$simulator"

    touch "$data_container/tmp/cydia-package-detail-probe-depiction-long"
    wait_for_state "$state" depiction-long light large "$launched_pid" ||
        fail "$label long depiction did not settle"
    verify_depiction_loaded_state "$state" depiction-long 2400 10000
    assert_state "$state" depictionInitialURL "$depiction_origin/long" \
        "long depiction URL changed"
    long_controller=$(read_state "$state" controllerToken)
    long_model=$(read_state "$state" modelToken)
    long_luminance=$(read_state "$state" backgroundLuminance)
    long_font=$(read_state "$state" nameFontSize)
    copy_phase "$state" "$destination" depiction-long-light "$simulator"

    swipes=0
    while [ "$swipes" -lt 12 ]; do
        run_with_timeout 15 idb ui swipe --udid "$simulator" --duration 0.35 \
            "$swipe_x" "$swipe_start" "$swipe_x" "$swipe_end" \
            >>"$destination/hid-interactions.log" 2>&1 ||
            fail "$label long-depiction HID swipe failed"
        swipes=$((swipes + 1))
        printf 'long-depiction-swipe=%s x=%s y1=%s y2=%s\n' "$swipes" \
            "$swipe_x" "$swipe_start" "$swipe_end" \
            >>"$destination/hid-interactions.log"
        wait_for_value "$state" footerVisible true && break
    done
    assert_state "$state" footerVisible true \
        "one outer scroll did not reach native footer after long depiction"
    assert_state "$state" scrollOwnerCount 1 \
        "long depiction gained a nested enabled scroll"
    assert_state "$state" depictionState loaded \
        "long depiction sizing became pathological while outer table scrolled"
    assert_number "$state" depictionHeightRevisionCount lt 128 \
        "long depiction exhausted its bounded height revisions"
    copy_phase "$state" "$destination" depiction-long-footer "$simulator"

    touch "$data_container/tmp/cydia-package-detail-probe-top"
    wait_for_offset_at_top "$state" || fail "$label long depiction did not return to topper"
    touch "$data_container/tmp/cydia-package-detail-probe-dark"
    wait_for_state "$state" depiction-long dark large "$launched_pid" ||
        fail "$label long depiction dark state did not settle"
    assert_state "$state" controllerToken "$long_controller" \
        "depiction dark transition replaced the controller"
    assert_state "$state" modelToken "$long_model" \
        "depiction dark transition replaced the model"
    assert_state "$state" depictionState loaded \
        "depiction dark transition lost the loaded document"
    assert_number "$state" backgroundLuminance lt "$long_luminance" \
        "depiction dark transition did not update native chrome"
    copy_phase "$state" "$destination" depiction-long-dark "$simulator"

    touch "$data_container/tmp/cydia-package-detail-probe-accessibility"
    wait_for_state "$state" depiction-long dark accessibility-large "$launched_pid" ||
        fail "$label long depiction Accessibility Large state did not settle"
    assert_state "$state" controllerToken "$long_controller" \
        "depiction Dynamic Type transition replaced the controller"
    assert_state "$state" modelToken "$long_model" \
        "depiction Dynamic Type transition replaced the model"
    assert_number "$state" nameFontSize gt "$long_font" \
        "depiction shell native title did not adopt Accessibility Large"
    assert_state "$state" depictionState loaded \
        "depiction Dynamic Type transition lost the document"
    assert_state "$state" scrollOwnerCount 1 \
        "depiction Dynamic Type transition enabled nested scrolling"
    copy_phase "$state" "$destination" depiction-long-dark-accessibility "$simulator"

    touch "$data_container/tmp/cydia-package-detail-probe-depiction-failed"
    wait_for_state "$state" depiction-failed light large "$launched_pid" ||
        fail "$label cross-origin redirect failure did not settle"
    verify_depiction_failure_state "$state" depiction-failed
    assert_state "$state" depictionInitialURL "$depiction_origin/cross-redirect" \
        "failed depiction URL changed"
    copy_phase "$state" "$destination" depiction-failed "$simulator"

    touch "$data_container/tmp/cydia-package-detail-probe-depiction-hostile"
    wait_for_state "$state" depiction-hostile light large "$launched_pid" ||
        fail "$label hostile depiction did not settle"
    verify_depiction_hostile_state "$state"
    assert_state "$state" depictionInitialURL "$depiction_origin/hostile" \
        "hostile depiction URL changed"
    copy_phase "$state" "$destination" depiction-hostile "$simulator"

    cp "$depiction_log" "$destination/depiction-server.jsonl"
    verify_depiction_server_log "$destination/depiction-server.jsonl"

    kill -0 "$launched_pid" 2>/dev/null || fail "$label process exited after capture"
    : >"$destination/crash-check.txt"
    for crash_root in "$HOME/Library/Logs/DiagnosticReports" \
        "$HOME/Library/Developer/CoreSimulator/Devices/$simulator/data/Library/Logs/CrashReporter"; do
        [ -d "$crash_root" ] || continue
        find "$crash_root" -type f -newer "$destination/launch-marker" -print 2>/dev/null |
        while IFS= read -r report; do
            grep -Fq "$bundle_id" "$report" && printf '%s\n' "$report"
        done >>"$destination/crash-check.txt"
    done
    [ ! -s "$destination/crash-check.txt" ] || fail "$label produced a crash report"
    write_parity_note "$destination"
    stop_companion
    remove_probe "$simulator"
    wait_for_removal "$simulator" "$destination" || fail "$label probe remained registered"
    installed_simulators=$(printf '%s\n' "$installed_simulators" |
        tr ' ' '\n' | grep -Fvx "$simulator" | tr '\n' ' ' || true)
    write_checksums "$destination"
    pass "$label installed package-shell evidence: $destination"
}

rm -rf -- "$artifact_dir"
mkdir -p "$artifact_dir"
start_depiction_server || fail "could not start deterministic depiction server"
pass "deterministic depiction server is ready at $depiction_origin"
"$make_program" --no-print-directory -j1 -C "$source_root" doIA=yes \
    BUILD_DIR="$build_dir" all >"$artifact_dir/build.log" 2>&1 || {
        grep -n -E 'error:|fatal error:|undefined reference|ld:|make: \*\*\*' \
            "$artifact_dir/build.log" | head -100 >&2 || true
        fail "simulator Make build failed; see $artifact_dir/build.log"
    }
pass "Make produced the simulator package-shell application"

cp -a "$source_root/MobileCydia.app" "$probe_app"
cp "$build_dir/bin/MobileCydia" "$probe_app/Cydia"
plutil -replace CFBundleIdentifier -string "$bundle_id" "$probe_app/Info.plist"
plutil -lint "$probe_app/Info.plist" >/dev/null || fail "probe Info.plist is invalid"
source_head=$(git -C "$source_root" rev-parse HEAD)
binary_sha=$(shasum -a 256 "$probe_app/Cydia" | awk '{ print $1 }')
bundle_short_version=$(plutil -extract CFBundleShortVersionString raw -o - "$probe_app/Info.plist")
bundle_version=$(plutil -extract CFBundleVersion raw -o - "$probe_app/Info.plist")

run_probe "$simulator_udid" "$case_name" "$expected_runtime"

echo "[verify-package-detail-simulator][evidence] $artifact_dir"
