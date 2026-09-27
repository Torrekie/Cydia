#!/bin/sh
# Cydia Refurbished native Home simulator evidence.
# Copyright (C) 2026 Torrekie
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

usage() {
    cat >&2 <<EOF
usage: $0 --prepare --make MAKE --build-dir DIR --developer-dir DIR [--jobs 1]
       $0 --case CASE --simulator UDID --build-dir DIR \\
          --developer-dir DIR [--jobs 1]
       $0 --finalize --build-dir DIR --developer-dir DIR

CASE is exactly one of: ios12-phone, ios15-phone, ios12-ipad.
Preparation is build-only. The matrix is then accumulated one shutdown
runtime at a time without an implicit build.
Set CYDIA_HOME_MEMORY_POLICY=observe to record host memory and swap without
using them as admission thresholds. Process and simulator isolation remain
mandatory.
EOF
    exit 2
}

mode=run
mode_option=
case_name=
simulator=
make_program=
build_dir=
developer_dir=
jobs=1
while [ "$#" -gt 0 ]; do
    case "$1" in
        --case) [ "$#" -ge 2 ] || usage; case_name=$2; shift 2 ;;
        --simulator) [ "$#" -ge 2 ] || usage; simulator=$2; shift 2 ;;
        --make) [ "$#" -ge 2 ] || usage; make_program=$2; shift 2 ;;
        --build-dir) [ "$#" -ge 2 ] || usage; build_dir=$2; shift 2 ;;
        --developer-dir) [ "$#" -ge 2 ] || usage; developer_dir=$2; shift 2 ;;
        --jobs) [ "$#" -ge 2 ] || usage; jobs=$2; shift 2 ;;
        --prepare)
            [ -z "$mode_option" ] || usage
            mode=prepare
            mode_option=prepare
            shift
            ;;
        --finalize)
            [ -z "$mode_option" ] || usage
            mode=finalize
            mode_option=finalize
            shift
            ;;
        *) usage ;;
    esac
done

[ -n "$build_dir" ] && [ -n "$developer_dir" ] || usage
case "$mode" in
    run)
        [ -n "$case_name" ] && [ -n "$simulator" ] &&
            [ -z "$make_program" ] || usage
        ;;
    prepare)
        [ -z "$case_name" ] && [ -z "$simulator" ] &&
            [ -n "$make_program" ] || usage
        ;;
    finalize)
        [ -z "$case_name" ] && [ -z "$simulator" ] &&
            [ -z "$make_program" ] && [ "$jobs" = 1 ] || usage
        ;;
    *) usage ;;
esac

case "$jobs" in
    1) ;;
    *) echo "[verify-home-simulator][FAIL] jobs must be exactly 1" >&2; exit 2 ;;
esac

memory_admission_policy=${CYDIA_HOME_MEMORY_POLICY:-strict}
case "$memory_admission_policy" in
    strict|observe) ;;
    *)
        echo "[verify-home-simulator][FAIL] memory policy must be strict or observe" >&2
        exit 2
        ;;
esac

# Keep the common build bounded even when a compiler or recursive make child
# stops making progress.  The test-only override is capped so it can shorten
# the bound but never turn it into an unbounded operation.
common_build_timeout_seconds=900
if [ "$mode" = prepare ]; then
    common_build_timeout_seconds=${CYDIA_HOME_BUILD_TIMEOUT_SECONDS:-900}
    case "$common_build_timeout_seconds" in
        ''|*[!0-9]*)
            echo "[verify-home-simulator][FAIL] build timeout must be an integer" >&2
            exit 2
            ;;
    esac
    [ "$common_build_timeout_seconds" -ge 1 ] &&
        [ "$common_build_timeout_seconds" -le 900 ] || {
            echo "[verify-home-simulator][FAIL] build timeout must be between 1 and 900 seconds" >&2
            exit 2
        }
fi

source_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
case "$build_dir" in
    /*) ;;
    *) build_dir=$source_root/$build_dir ;;
esac
[ -d "$developer_dir" ] || {
    echo "[verify-home-simulator][FAIL] developer directory is unavailable: $developer_dir" >&2
    exit 2
}
developer_dir=$(CDPATH= cd -- "$developer_dir" && pwd -P)

expected_runtime=
expected_runtime_identifier=
expected_layout=
expected_device_family=
label=
if [ "$mode" = run ]; then
    case "$case_name" in
        ios12-phone)
            expected_runtime=12.0
            expected_runtime_identifier=com.apple.CoreSimulator.SimRuntime.iOS-12-0-SyntheticSimulatorFixture
            expected_layout=phone
            expected_device_family=iPhone
            label=ios12-phone
            ;;
        ios15-phone)
            expected_runtime=15.5
            expected_runtime_identifier=com.apple.CoreSimulator.SimRuntime.iOS-15-5
            expected_layout=phone
            expected_device_family=iPhone
            label=ios15-phone
            ;;
        ios12-ipad)
            expected_runtime=12.0
            expected_runtime_identifier=com.apple.CoreSimulator.SimRuntime.iOS-12-0-SyntheticSimulatorFixture
            expected_layout=ipad
            expected_device_family=iPad
            label=ios12-ipad
            ;;
        *) echo "[verify-home-simulator][FAIL] unknown case: $case_name" >&2; exit 2 ;;
    esac
    case "$simulator" in
        ????????-????-????-????-????????????) ;;
        *) echo "[verify-home-simulator][FAIL] simulator UDID is malformed" >&2; exit 2 ;;
    esac
fi

[ -z "$(git -C "$source_root" status --porcelain --untracked-files=all)" ] || {
    echo "[verify-home-simulator][FAIL] source worktree must be clean" >&2
    exit 2
}
command -v plutil >/dev/null 2>&1 || {
    echo "[verify-home-simulator][FAIL] plutil is unavailable" >&2
    exit 2
}
command -v shasum >/dev/null 2>&1 || {
    echo "[verify-home-simulator][FAIL] shasum is unavailable" >&2
    exit 2
}

matrix_root=$build_dir/home-simulator-matrix
common_dir=$matrix_root/common
cases_dir=$matrix_root/cases
completion_file=$matrix_root/matrix-complete.json
completion_temporary=$matrix_root/.matrix-complete.json.tmp.$$
case_dir=$cases_dir/$case_name
case_temporary=$cases_dir/.$case_name.tmp.$$
common_temporary=$matrix_root/.common.tmp.$$
case "$mode" in
    prepare)
        if [ -e "$matrix_root" ] && [ ! -d "$matrix_root" ]; then
            echo "[verify-home-simulator][FAIL] Home matrix root is not a directory" >&2
            exit 1
        fi
        mkdir -p "$matrix_root"
        ;;
    run)
        [ -d "$matrix_root" ] || {
            echo "[verify-home-simulator][FAIL] Home matrix preparation is absent" >&2
            exit 1
        }
        ;;
    finalize)
        [ -d "$matrix_root" ] && [ -d "$cases_dir" ] || {
            echo "[verify-home-simulator][FAIL] Home matrix evidence is absent" >&2
            exit 1
        }
        ;;
esac
scratch=$(mktemp -d "${TMPDIR:-/tmp}/cydia-home-matrix.XXXXXX")
simulator_helper_baseline=$scratch/simulator-helper-baseline
preparation_admission_file=$scratch/host-admission-prebuild.txt
lock_dir=$matrix_root/.lock
if ! mkdir "$lock_dir" 2>/dev/null; then
    echo "[verify-home-simulator][FAIL] another Home matrix operation owns $lock_dir" >&2
    rm -rf -- "$scratch"
    exit 1
fi
lock_owned=1
initial_swap_used_mb=

bundle_id=
background_bundle_id=com.apple.Preferences
artifact_dir=$case_temporary
probe_app=
installed=0
shutdown_required=0
case_committed=0
common_committed=0
source_head=
source_tree=
binary_sha=
bundle_short_version=
bundle_version=
xcode_version=
xcode_build=
xcodebuild_sha=
xcrun_path=/usr/bin/xcrun
xcrun_sha=
build_xcrun_path=
build_xcrun_sha=
build_xcodebuild_path=/usr/bin/xcodebuild
build_xcodebuild_sha=
simctl_path=
simctl_sha=
simulator_sdk=
simulator_sdk_version=
simulator_compiler_path=
simulator_compiler_sha=
common_checksums_sha=
active_command_pid=
command_watchdog_pid=
command_timeout_marker=
command_cleanup_failure_marker=
active_build_pid=
build_watchdog_pid=
build_timeout_marker=
build_cleanup_failure_marker=
runtime_cleanup_deadline=

fail() {
    echo "[verify-home-simulator][FAIL] $*" >&2
    exit 1
}

verify_source_snapshot() {
    source_status=$(git -C "$source_root" status --porcelain --untracked-files=all) ||
        fail "could not inspect the source worktree"
    [ -z "$source_status" ] || fail "source worktree changed during Home verification"
    current_source_head=$(git -C "$source_root" rev-parse HEAD) ||
        fail "could not re-read the source HEAD"
    current_source_tree=$(git -C "$source_root" rev-parse 'HEAD^{tree}') ||
        fail "could not re-read the source tree"
    [ "$current_source_head" = "$source_head" ] &&
        [ "$current_source_tree" = "$source_tree" ] ||
        fail "source provenance changed during Home verification"
}

is_number() {
    awk -v value="$1" 'BEGIN {
        exit !(value ~ /^[0-9]+([.][0-9]+)?$/)
    }'
}

monotonic_seconds() {
    /usr/bin/python3 - <<'PY'
import time
print(int(time.monotonic()))
PY
}

deadline_available() {
    checked_deadline=$1
    case "$checked_deadline" in
        ''|*[!0-9]*) return 1 ;;
    esac
    checked_now=$(monotonic_seconds) || return 1
    case "$checked_now" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$checked_now" -lt "$checked_deadline" ]
}

deadline_timeout() {
    timeout_deadline=$1
    timeout_cap=$2
    case "$timeout_deadline:$timeout_cap" in
        *[!0-9:]*|:*|*:) return 1 ;;
    esac
    timeout_now=$(monotonic_seconds) || return 1
    case "$timeout_now" in ''|*[!0-9]*) return 1 ;; esac
    timeout_remaining=$((timeout_deadline - timeout_now))
    [ "$timeout_remaining" -gt 0 ] || return 1
    if [ "$timeout_remaining" -lt "$timeout_cap" ]; then
        printf '%s\n' "$timeout_remaining"
    else
        printf '%s\n' "$timeout_cap"
    fi
}

single_line_value() {
    single_line_file=$1
    awk '
        index($0, "\r") { bad = 1 }
        { count++; value = $0 }
        END {
            if (bad || count != 1 || value == "") exit 1
            print value
        }
    ' "$single_line_file"
}

manifest_value() {
    manifest=$1
    key=$2
    count=$(awk -F= -v key="$key" '$1 == key { count++ } END { print count + 0 }' \
        "$manifest")
    [ "$count" -eq 1 ] || fail "$manifest has $count values for $key"
    awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$manifest"
}

require_manifest_value() {
    manifest=$1
    key=$2
    expected=$3
    actual=$(manifest_value "$manifest" "$key")
    [ "$actual" = "$expected" ] ||
        fail "$manifest has $key=$actual, expected $expected"
}

write_checksums() {
    directory=$1
    checksum_find=$scratch/checksum-find.$$
    checksum_list=$scratch/checksum-list.$$
    checksum_output=$directory/.SHA256SUMS.tmp.$$
    if ! (cd "$directory" && find . -type f ! -name SHA256SUMS -print >"$checksum_find"); then
        return 1
    fi
    if ! LC_ALL=C sort "$checksum_find" >"$checksum_list"; then
        return 1
    fi
    if ! (
        cd "$directory" || exit 1
        while IFS= read -r file; do
            shasum -a 256 "$file" || exit 1
        done <"$checksum_list"
    ) >"$checksum_output"; then
        rm -f -- "$checksum_output"
        return 1
    fi
    mv -- "$checksum_output" "$directory/SHA256SUMS"
}

verify_checksums() {
    directory=$1
    [ ! -L "$directory" ] || fail "$directory must not be a symlink"
    symlink_list=$scratch/symlinks.$$
    if ! find "$directory" -type l -print -quit >"$symlink_list"; then
        fail "$directory symlink scan failed"
    fi
    if [ -s "$symlink_list" ]; then
        fail "$directory contains a symlink instead of exact evidence"
    fi
    [ -f "$directory/SHA256SUMS" ] || fail "$directory has no SHA256SUMS"
    expected_files=$scratch/expected-files.$$
    listed_files=$scratch/listed-files.$$
    expected_unsorted=$scratch/expected-files-unsorted.$$
    if ! (cd "$directory" && find . -type f ! -name SHA256SUMS -print >"$expected_unsorted"); then
        fail "$directory file scan failed"
    fi
    if ! LC_ALL=C sort "$expected_unsorted" >"$expected_files"; then
        fail "$directory file sort failed"
    fi
    awk '
        {
            digest = substr($0, 1, 64)
            separator = substr($0, 65, 2)
            path = substr($0, 67)
            if (length(digest) != 64 || digest ~ /[^0-9a-f]/ ||
                separator != "  " || substr(path, 1, 2) != "./") {
                bad = 1
                next
            }
            print path
        }
        END { exit bad }
    ' "$directory/SHA256SUMS" >"$listed_files" ||
        fail "$directory has a malformed SHA256SUMS"
    cmp -s "$expected_files" "$listed_files" ||
        fail "$directory SHA256SUMS does not exactly cover its files"
    (cd "$directory" && shasum -a 256 -c SHA256SUMS >/dev/null) ||
        fail "$directory checksum verification failed"
}

file_sha256() {
    shasum -a 256 "$1" 2>/dev/null | awk '
        {
            candidate = substr($0, 1, 64)
            separator = substr($0, 65, 2)
        }
        length(candidate) == 64 && candidate !~ /[^0-9a-f]/ &&
                separator == "  " {
            count++
            digest = candidate
        }
        END {
            if (count != 1) exit 1
            print digest
        }
    '
}

validate_preparation_build_lookup() {
    [ "$mode" = prepare ] || return 0
    preparation_xcrun=$(command -v xcrun || true)
    [ "$preparation_xcrun" = "$build_xcrun_path" ] ||
        fail "preparation xcrun lookup escaped $build_xcrun_path: $preparation_xcrun"
    preparation_xcodebuild=$(command -v xcodebuild || true)
    [ "$preparation_xcodebuild" = "$build_xcodebuild_path" ] ||
        fail "preparation xcodebuild lookup escaped $build_xcodebuild_path: $preparation_xcodebuild"
}

reject_partial_preparation() {
    partial_preparations=$scratch/partial-preparations.$$
    if ! find "$matrix_root" -mindepth 1 -maxdepth 1 -name '.common.tmp.*' \
            -print -quit >"$partial_preparations"; then
        fail "could not inspect Home matrix partial preparations"
    fi
    [ ! -s "$partial_preparations" ] ||
        fail "Home matrix contains a stale partial preparation"
}

validate_toolchain() {
    xcodebuild=$developer_dir/usr/bin/xcodebuild
    [ -x "$xcodebuild" ] || fail "xcodebuild is absent from $developer_dir"
    [ -x "$xcrun_path" ] || fail "host xcrun is unavailable at $xcrun_path"
    xcodebuild_sha=$(file_sha256 "$xcodebuild") ||
        fail "could not hash the explicit xcodebuild"
    xcrun_sha=$(file_sha256 "$xcrun_path") || fail "could not hash host xcrun"
    build_xcrun_path=$xcrun_path
    build_xcrun_sha=$xcrun_sha
    [ -x "$build_xcodebuild_path" ] ||
        fail "build xcodebuild is unavailable at $build_xcodebuild_path"
    build_xcodebuild_sha=$(file_sha256 "$build_xcodebuild_path") ||
        fail "could not hash build xcodebuild"
    version_output=$(DEVELOPER_DIR="$developer_dir" "$xcodebuild" -version) ||
        fail "could not inspect the explicit Xcode"
    xcode_version=$(printf '%s\n' "$version_output" |
        awk '$1 == "Xcode" { print $2; exit }')
    xcode_build=$(printf '%s\n' "$version_output" |
        awk '$1 == "Build" && $2 == "version" { print $3; exit }')
    [ "$xcode_version" = 13.4.1 ] && [ "$xcode_build" = 13F100 ] ||
        fail "Home evidence requires Xcode 13.4.1/13F100, got $xcode_version/$xcode_build"
    simctl_path=$(DEVELOPER_DIR="$developer_dir" "$xcrun_path" --find simctl) ||
        fail "the explicit Xcode has no simctl"
    [ "$simctl_path" = "$developer_dir/usr/bin/simctl" ] ||
        fail "simctl escaped the explicit developer directory: $simctl_path"
    [ -x "$simctl_path" ] || fail "resolved simctl is not executable: $simctl_path"
    simctl_sha=$(file_sha256 "$simctl_path") || fail "could not hash resolved simctl"
    simulator_sdk=$(DEVELOPER_DIR="$developer_dir" "$xcodebuild" \
        -sdk iphonesimulator -version Path) || fail "could not resolve the simulator SDK"
    simulator_sdk_version=$(DEVELOPER_DIR="$developer_dir" "$xcodebuild" \
        -sdk iphonesimulator -version SDKVersion) ||
        fail "could not resolve the simulator SDK version"
    [ -n "$simulator_sdk" ] && [ -n "$simulator_sdk_version" ] ||
        fail "explicit simulator SDK provenance is empty"
    case "$simulator_sdk" in "$developer_dir"/*) ;; *)
        fail "simulator SDK escaped the explicit developer directory: $simulator_sdk" ;;
    esac
    [ "$simulator_sdk_version" = 15.5 ] ||
        fail "Xcode 13.4.1 simulator SDK changed: $simulator_sdk_version"
    simulator_compiler_path=$(DEVELOPER_DIR="$developer_dir" "$xcrun_path" \
        --sdk iphonesimulator -f g++) ||
        fail "could not resolve the simulator compiler"
    case "$simulator_compiler_path" in "$developer_dir"/*) ;; *)
        fail "simulator compiler escaped the explicit Xcode: $simulator_compiler_path" ;;
    esac
    [ -x "$simulator_compiler_path" ] ||
        fail "resolved simulator compiler is not executable: $simulator_compiler_path"
    simulator_compiler_sha=$(file_sha256 "$simulator_compiler_path") ||
        fail "could not hash the simulator compiler"
    validate_preparation_build_lookup
}

verify_toolchain_snapshot() {
    [ -x "$developer_dir/usr/bin/xcodebuild" ] ||
        fail "prepared xcodebuild disappeared before publication"
    current_xcodebuild_sha=$(file_sha256 "$developer_dir/usr/bin/xcodebuild") ||
        fail "could not re-hash the explicit xcodebuild"
    [ "$current_xcodebuild_sha" = "$xcodebuild_sha" ] ||
        fail "xcodebuild changed during Home preparation"
    [ -x "$xcrun_path" ] || fail "host xcrun disappeared during Home preparation"
    current_xcrun_sha=$(file_sha256 "$xcrun_path") ||
        fail "could not re-hash host xcrun"
    [ "$current_xcrun_sha" = "$xcrun_sha" ] ||
        fail "host xcrun changed during Home preparation"
    current_build_xcodebuild_sha=$(file_sha256 "$build_xcodebuild_path") ||
        fail "could not re-hash build xcodebuild"
    [ "$current_build_xcodebuild_sha" = "$build_xcodebuild_sha" ] ||
        fail "build xcodebuild changed during Home preparation"
    current_version_output=$(DEVELOPER_DIR="$developer_dir" \
        "$developer_dir/usr/bin/xcodebuild" -version) ||
        fail "could not re-inspect the explicit Xcode"
    current_xcode_version=$(printf '%s\n' "$current_version_output" |
        awk '$1 == "Xcode" { print $2; exit }')
    current_xcode_build=$(printf '%s\n' "$current_version_output" |
        awk '$1 == "Build" && $2 == "version" { print $3; exit }')
    [ "$current_xcode_version" = "$xcode_version" ] &&
        [ "$current_xcode_build" = "$xcode_build" ] ||
        fail "Xcode version changed during Home preparation"
    current_simctl_path=$(DEVELOPER_DIR="$developer_dir" \
        "$xcrun_path" --find simctl) ||
        fail "could not re-resolve simctl from the explicit Xcode"
    [ "$current_simctl_path" = "$simctl_path" ] ||
        fail "simctl path changed during Home preparation: $current_simctl_path"
    [ -x "$current_simctl_path" ] ||
        fail "resolved simctl disappeared during Home preparation"
    current_simctl_sha=$(file_sha256 "$current_simctl_path") ||
        fail "could not re-hash resolved simctl"
    [ "$current_simctl_sha" = "$simctl_sha" ] ||
        fail "simctl changed during Home preparation"
    current_simulator_sdk=$(DEVELOPER_DIR="$developer_dir" \
        "$developer_dir/usr/bin/xcodebuild" -sdk iphonesimulator -version Path) ||
        fail "could not re-resolve the simulator SDK"
    current_simulator_sdk_version=$(DEVELOPER_DIR="$developer_dir" \
        "$developer_dir/usr/bin/xcodebuild" -sdk iphonesimulator \
        -version SDKVersion) || fail "could not re-read the simulator SDK version"
    [ "$current_simulator_sdk" = "$simulator_sdk" ] &&
        [ "$current_simulator_sdk_version" = "$simulator_sdk_version" ] ||
        fail "simulator SDK changed during Home preparation"
    current_simulator_compiler_path=$(DEVELOPER_DIR="$developer_dir" \
        "$xcrun_path" --sdk iphonesimulator -f g++) ||
        fail "could not re-resolve the simulator compiler"
    [ "$current_simulator_compiler_path" = "$simulator_compiler_path" ] ||
        fail "simulator compiler path changed during Home preparation"
    current_simulator_compiler_sha=$(file_sha256 \
        "$current_simulator_compiler_path") ||
        fail "could not re-hash the simulator compiler"
    [ "$current_simulator_compiler_sha" = "$simulator_compiler_sha" ] ||
        fail "simulator compiler changed during Home preparation"
    validate_preparation_build_lookup
}

run_with_timeout() {
    timeout_seconds=$1
    shift
    command_timeout_marker=$scratch/command-timeout.$$
    command_cleanup_failure_marker=$scratch/command-cleanup-failed.$$
    rm -f -- "$command_timeout_marker" "$command_cleanup_failure_marker"
    "$@" &
    active_command_pid=$!
    (
        timeout_remaining=$timeout_seconds
        while [ "$timeout_remaining" -gt 0 ] &&
                kill -0 "$active_command_pid" 2>/dev/null; do
            sleep 1
            timeout_remaining=$((timeout_remaining - 1))
        done
        if kill -0 "$active_command_pid" 2>/dev/null; then
            : >"$command_timeout_marker"
            if ! terminate_process_tree "$active_command_pid" \
                    "$scratch/timeout-processes.$$" \
                    "$scratch/timeout-descendants.$$"; then
                : >"$command_cleanup_failure_marker"
            fi
        fi
    ) &
    command_watchdog_pid=$!
    set +e
    wait "$active_command_pid"
    command_status=$?
    set -e
    if [ -e "$command_timeout_marker" ]; then
        wait "$command_watchdog_pid" 2>/dev/null || true
    else
        kill "$command_watchdog_pid" 2>/dev/null || true
        wait "$command_watchdog_pid" 2>/dev/null || true
    fi
    active_command_pid=
    command_watchdog_pid=
    if [ -e "$command_timeout_marker" ]; then
        [ ! -e "$command_cleanup_failure_marker" ] || return 125
        return 124
    fi
    return "$command_status"
}

# Return all descendants of a process from one validated process snapshot.
# Keeping the snapshot and the tree walk separate makes a failed ps command a
# hard failure instead of an empty, apparently-clean process list.
process_tree_descendants() (
    tree_root_pid=$1
    tree_snapshot=$2
    tree_descendants=$3
    case "$tree_root_pid" in
        ''|*[!0-9]*) return 1 ;;
    esac
    if ! ps -axo pid=,ppid= >"$tree_snapshot" 2>/dev/null; then
        return 1
    fi
    awk -v root="$tree_root_pid" '
        function valid(value) { return value ~ /^[0-9]+$/ }
        {
            if (NF < 2 || !valid($1) || !valid($2) || ($1 in parent)) {
                bad = 1
                next
            }
            pids[++count] = $1
            parent[$1] = $2
            if ($1 == root)
                root_seen = 1
        }
        END {
            if (bad || !root_seen) exit 2
            seen[root] = 1
            changed = 1
            while (changed) {
                changed = 0
                for (i = 1; i <= count; ++i) {
                    pid = pids[i]
                    if (!seen[pid] && seen[parent[pid]]) {
                        seen[pid] = 1
                        changed = 1
                    }
                }
            }
            for (i = count; i >= 1; --i)
                if (seen[pids[i]] && pids[i] != root)
                    print pids[i]
        }
    ' "$tree_snapshot" >"$tree_descendants"
)

# Terminate a process and every descendant observed in one snapshot.  A ps
# failure still terminates the direct child, but returns failure so callers can
# report that descendant cleanup was not proven.
terminate_process_tree() (
    tree_root_pid=$1
    tree_snapshot=$2
    tree_descendants=$3
    tree_status=0
    if ! process_tree_descendants "$tree_root_pid" "$tree_snapshot" \
            "$tree_descendants"; then
        : >"$tree_descendants" || tree_status=1
        tree_status=1
    fi
    if [ -s "$tree_descendants" ]; then
        while IFS= read -r tree_pid; do
            case "$tree_pid" in
                ''|*[!0-9]*) tree_status=1; continue ;;
            esac
            if kill -0 "$tree_pid" 2>/dev/null; then
                kill -TERM "$tree_pid" 2>/dev/null || tree_status=1
            fi
        done <"$tree_descendants"
    fi
    if kill -0 "$tree_root_pid" 2>/dev/null; then
        kill -TERM "$tree_root_pid" 2>/dev/null || tree_status=1
    fi
    sleep 1
    if [ -s "$tree_descendants" ]; then
        while IFS= read -r tree_pid; do
            case "$tree_pid" in
                ''|*[!0-9]*) tree_status=1; continue ;;
            esac
            if kill -0 "$tree_pid" 2>/dev/null; then
                kill -KILL "$tree_pid" 2>/dev/null || tree_status=1
            fi
        done <"$tree_descendants"
    fi
    if kill -0 "$tree_root_pid" 2>/dev/null; then
        kill -KILL "$tree_root_pid" 2>/dev/null || tree_status=1
    fi
    return "$tree_status"
)

run_bounded_build() {
    build_seconds=$1
    shift
    build_timeout_marker=$scratch/build-timeout.$$
    build_cleanup_failure_marker=$scratch/build-cleanup-failed.$$
    rm -f -- "$build_timeout_marker" "$build_cleanup_failure_marker"
    "$@" &
    active_build_pid=$!
    (
        build_remaining=$build_seconds
        while [ "$build_remaining" -gt 0 ] &&
                kill -0 "$active_build_pid" 2>/dev/null; do
            sleep 1
            build_remaining=$((build_remaining - 1))
        done
        if kill -0 "$active_build_pid" 2>/dev/null; then
            : >"$build_timeout_marker"
            if ! terminate_process_tree "$active_build_pid" \
                    "$scratch/build-timeout-processes.$$" \
                    "$scratch/build-timeout-descendants.$$"; then
                : >"$build_cleanup_failure_marker"
            fi
        fi
    ) &
    build_watchdog_pid=$!
    set +e
    wait "$active_build_pid"
    build_status=$?
    set -e
    if [ -e "$build_timeout_marker" ]; then
        wait "$build_watchdog_pid" 2>/dev/null || true
    else
        kill "$build_watchdog_pid" 2>/dev/null || true
        wait "$build_watchdog_pid" 2>/dev/null || true
    fi
    active_build_pid=
    build_watchdog_pid=
    if [ -e "$build_timeout_marker" ]; then
        [ ! -e "$build_cleanup_failure_marker" ] || return 125
        return 124
    fi
    return "$build_status"
}

cleanup_tracked_processes() {
    tracked_cleanup_status=0
    if [ -n "$command_watchdog_pid" ]; then
        terminate_process_tree "$command_watchdog_pid" \
            "$scratch/cleanup-command-watchdog-processes.$$" \
            "$scratch/cleanup-command-watchdog-descendants.$$" ||
            tracked_cleanup_status=1
        wait "$command_watchdog_pid" 2>/dev/null || true
        command_watchdog_pid=
    fi
    if [ -n "$active_command_pid" ]; then
        terminate_process_tree "$active_command_pid" \
            "$scratch/cleanup-command-processes.$$" \
            "$scratch/cleanup-command-descendants.$$" || tracked_cleanup_status=1
        active_command_pid=
    fi
    if [ -n "$build_watchdog_pid" ]; then
        terminate_process_tree "$build_watchdog_pid" \
            "$scratch/cleanup-build-watchdog-processes.$$" \
            "$scratch/cleanup-build-watchdog-descendants.$$" ||
            tracked_cleanup_status=1
        wait "$build_watchdog_pid" 2>/dev/null || true
        build_watchdog_pid=
    fi
    if [ -n "$active_build_pid" ]; then
        terminate_process_tree "$active_build_pid" \
            "$scratch/cleanup-build-processes.$$" \
            "$scratch/cleanup-build-descendants.$$" || tracked_cleanup_status=1
        active_build_pid=
    fi
    return "$tracked_cleanup_status"
}

simctl() {
    seconds=$1
    shift
    run_with_timeout "$seconds" env DEVELOPER_DIR="$developer_dir" \
        "$xcrun_path" simctl "$@"
}

device_is_booted() {
    device_timeout=15
    if [ -n "$runtime_cleanup_deadline" ]; then
        device_timeout=$(deadline_timeout "$runtime_cleanup_deadline" 15) || return 1
    fi
    device_list=$scratch/device-list.$$
    if ! simctl "$device_timeout" list devices >"$device_list" 2>/dev/null; then
        return 1
    fi
    grep -F "($1) (Booted)" "$device_list" >/dev/null 2>&1
}

load_device_metadata() {
    requested_state=$1
    metadata_json=$scratch/devices.json
    metadata_text=$scratch/device-metadata.txt
    simctl 20 list devices -j >"$metadata_json" ||
        fail "could not inspect simulator metadata"
    if ! /usr/bin/python3 - "$metadata_json" "$simulator" \
            >"$metadata_text" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    payload = json.load(handle)
matches = []
for runtime, devices in payload.get("devices", {}).items():
    for device in devices:
        if device.get("udid") == sys.argv[2]:
            matches.append((runtime, device))
if len(matches) != 1:
    raise SystemExit(2)
runtime, device = matches[0]
values = [
    runtime,
    device.get("deviceTypeIdentifier", ""),
    device.get("state", ""),
    "true" if device.get("isAvailable", False) else "false",
    device.get("name", ""),
]
if any("\t" in value or "\n" in value for value in values):
    raise SystemExit(2)
print("\t".join(values))
PY
    then
        fail "simulator $simulator is not uniquely registered"
    fi
    [ -s "$metadata_text" ] || fail "simulator $simulator is not uniquely registered"
    actual_runtime_identifier=$(awk -F '\t' '{ print $1 }' "$metadata_text")
    actual_device_type=$(awk -F '\t' '{ print $2 }' "$metadata_text")
    actual_device_state=$(awk -F '\t' '{ print $3 }' "$metadata_text")
    actual_device_available=$(awk -F '\t' '{ print $4 }' "$metadata_text")
    actual_device_name=$(awk -F '\t' '{ print $5 }' "$metadata_text")
    [ "$actual_runtime_identifier" = "$expected_runtime_identifier" ] ||
        fail "$case_name uses $actual_runtime_identifier instead of $expected_runtime_identifier"
    case "$expected_device_family:$actual_device_type" in
        iPhone:com.apple.CoreSimulator.SimDeviceType.iPhone-*) ;;
        iPad:com.apple.CoreSimulator.SimDeviceType.iPad-*) ;;
        *) fail "$case_name has the wrong device family: $actual_device_type" ;;
    esac
    [ "$actual_device_available" = true ] || fail "$simulator is unavailable"
    [ "$actual_device_state" = "$requested_state" ] ||
        fail "$simulator state is $actual_device_state, expected $requested_state"
}

booted_simulator_count() {
    metadata_json=$scratch/host-devices.json
    simctl 20 list devices -j >"$metadata_json" || return 1
    /usr/bin/python3 - "$metadata_json" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as handle:
    payload = json.load(handle)
print(sum(device.get("state") == "Booted"
          for devices in payload.get("devices", {}).values()
          for device in devices))
PY
}

host_admission() {
    destination=$1
    expected_booted_count=${2:-0}
    case "$expected_booted_count" in
        0|1) ;;
        *) fail "host admission boot-count expectation is invalid" ;;
    esac
    memory_pressure_command=$(command -v memory_pressure || true)
    [ -n "$memory_pressure_command" ] || fail "memory_pressure is unavailable"
    memory_report=$($memory_pressure_command -Q 2>&1) ||
        fail "could not inspect host memory pressure"
    free_count=$(printf '%s\n' "$memory_report" |
        awk '/^System-wide memory free percentage: [0-9]+([.][0-9]+)?%$/ { count++ }
             END { print count + 0 }')
    [ "$free_count" -eq 1 ] || fail "host memory report is ambiguous"
    free_percent=$(printf '%s\n' "$memory_report" |
        awk '/^System-wide memory free percentage: [0-9]+([.][0-9]+)?%$/ {
            value = $NF; sub(/%$/, "", value); print value
        }')
    is_number "$free_percent" &&
        awk -v value="$free_percent" 'BEGIN { exit !(value >= 0 && value <= 100) }' ||
        fail "host memory report is invalid: $free_percent%"
    if [ "$memory_admission_policy" = strict ]; then
        awk -v value="$free_percent" 'BEGIN { exit !(value >= 40) }' ||
            fail "host memory admission requires at least 40% free; observed $free_percent%"
    fi
    swap_report=$(sysctl vm.swapusage 2>&1) || fail "could not inspect host swap usage"
    swap_count=$(printf '%s\n' "$swap_report" |
        awk '/^vm[.]swapusage:/ { count++ } END { print count + 0 }')
    [ "$swap_count" -eq 1 ] || fail "host swap report is ambiguous"
    swap_token=$(printf '%s\n' "$swap_report" | awk '
        /^vm[.]swapusage:/ {
            for (field = 1; field <= NF; ++field)
                if ($field == "used" && $(field + 1) == "=") {
                    print $(field + 2)
                    exit
                }
        }
    ')
    case "$swap_token" in *M) swap_used_mb=${swap_token%M} ;; *)
        fail "host swap usage is malformed: $swap_token" ;; esac
    is_number "$swap_used_mb" || fail "host swap usage is malformed: $swap_token"
    awk -v value="$swap_used_mb" 'BEGIN { exit !(value >= 0) }' ||
        fail "host swap usage is invalid: $swap_used_mb MB"
    if [ "$memory_admission_policy" = strict ]; then
        awk -v value="$swap_used_mb" 'BEGIN { exit !(value <= 3072) }' ||
            fail "host swap admission allows at most 3072 MB; observed $swap_used_mb MB"
    fi
    if [ -z "$initial_swap_used_mb" ]; then
        initial_swap_used_mb=$swap_used_mb
    elif [ "$memory_admission_policy" = strict ]; then
        awk -v initial="$initial_swap_used_mb" -v current="$swap_used_mb" \
            'BEGIN { exit !(current - initial <= 128) }' ||
            fail "host swap grew from $initial_swap_used_mb MB to $swap_used_mb MB"
    fi
    booted_count_file=$scratch/booted-simulator-count.$$
    booted_simulator_count >"$booted_count_file" ||
        fail "could not count booted simulators"
    booted_count=$(single_line_value "$booted_count_file") ||
        fail "booted simulator count is malformed"
    case "$booted_count" in ''|*[!0-9]*) fail "booted simulator count is malformed" ;; esac
    [ "$booted_count" -eq "$expected_booted_count" ] ||
        fail "$booted_count simulator(s) are booted; expected $expected_booted_count"
    ancestor_pids=" $$"
    ancestor=$PPID
    while [ -n "$ancestor" ] && [ "$ancestor" -gt 1 ] 2>/dev/null; do
        ancestor_pids="$ancestor_pids $ancestor"
        ancestor_file=$scratch/ancestor.$$
        if ! ps -o ppid= -p "$ancestor" >"$ancestor_file" 2>/dev/null; then
            fail "could not inspect the Home verifier process ancestry"
        fi
        ancestor=$(tr -d ' ' <"$ancestor_file") ||
            fail "could not parse the Home verifier process ancestry"
        case "$ancestor" in
            '') ancestor=1 ;;
            *[!0-9]*) fail "Home verifier process ancestry is malformed: $ancestor" ;;
        esac
    done
    competing_snapshot=$scratch/competing-processes.$$
    if ! ps -axo pid=,ucomm=,command= >"$competing_snapshot" 2>/dev/null; then
        fail "could not inspect competing build or Home-probe processes"
    fi
    process_records=$scratch/process-records.$$
    helper_current=$scratch/simulator-helpers.$$
    unsafe_current=$scratch/unsafe-processes.$$
    if ! awk -v ancestors="$ancestor_pids" \
            -v expected_booted="$expected_booted_count" \
            -v target_device="$simulator" '
        {
            if (NF < 3 || $1 !~ /^[0-9]+$/ || $2 == "") {
                bad = 1
                next
            }
            records++
            pid = $1
            command = $2
            executable = $2
            full_command = $0
            if (index(" " ancestors " ", " " pid " ") == 0) {
                launchd_helper = command == "launchd_sim" ||
                    executable == "launchd_sim"
                core_helper = index(full_command,
                    "CoreSimulator.CoreSimulatorService") ||
                    index(full_command, "SimLaunchHost") ||
                    index(full_command, "simdiskimaged") ||
                    index(full_command, "SimulatorTrampoline") ||
                    index(full_command, "SimAudioProcessorService") ||
                    index(full_command, "SimStreamProcessorService")
                simulator_app = executable == "Simulator" ||
                    index(full_command, "/Simulator.app/Contents/MacOS/Simulator")
                unsafe = command == "make" || executable == "make" ||
                    command == "gmake" || executable == "gmake" ||
                    command == "clang" || executable == "clang" ||
                    command == "clang++" || executable == "clang++" ||
                    command == "ld" || executable == "ld" ||
                    command == "ld64" || executable == "ld64" ||
                    command == "xcodebuild" || executable == "xcodebuild" ||
                    command ~ /^CydiaHomeProbe/ || executable ~ /^CydiaHomeProbe/ ||
                    simulator_app
                if (launchd_helper) {
                    # Exactly one target-bound launchd_sim is allowed only
                    # after the selected runtime has completed booting.
                    if (expected_booted != 1 ||
                        !index(full_command, target_device))
                        unsafe = 1
                    print "H\t" $0
                }
                if (core_helper) print "H\t" $0
                if (unsafe) print "U\t" $0
            }
        }
        END {
            if (records == 0) bad = 1
            exit bad
        }
    ' "$competing_snapshot" >"$process_records"; then
        fail "competing process snapshot is malformed"
    fi
    if ! awk -F '\t' '$1 == "H" { sub(/^[^\t]*\t/, ""); print }' \
            "$process_records" >"$helper_current"; then
        fail "could not classify simulator helper processes"
    fi
    if ! awk -F '\t' '$1 == "U" { sub(/^[^\t]*\t/, ""); print }' \
            "$process_records" >"$unsafe_current"; then
        fail "could not classify competing build processes"
    fi
    if [ -s "$unsafe_current" ]; then
        competing=$(cat "$unsafe_current") ||
            fail "could not read competing process snapshot"
        fail "competing build or Home-probe process is active: $competing"
    fi
    if [ ! -e "$simulator_helper_baseline" ]; then
        if ! cp "$helper_current" "$simulator_helper_baseline"; then
            fail "could not record the idle simulator helper baseline"
        fi
    elif [ "$expected_booted_count" -eq 0 ]; then
        new_helpers=$scratch/new-simulator-helpers.$$
        : >"$new_helpers"
        while IFS= read -r helper_line; do
            [ -n "$helper_line" ] || continue
            if grep -F -x "$helper_line" "$simulator_helper_baseline" >/dev/null 2>&1; then
                continue
            fi
            printf '%s\n' "$helper_line" >>"$new_helpers"
        done <"$helper_current"
        if [ -s "$new_helpers" ]; then
            new_helper_text=$(cat "$new_helpers") ||
                fail "could not read new simulator helpers"
            fail "unexpected simulator helper process is active: $new_helper_text"
        fi
    fi
    if [ "$expected_booted_count" -eq 1 ]; then
        target_launchd_count=$(awk -v target="$simulator" '
            $0 ~ /launchd_sim/ && index($0, target) { count++ }
            END { print count + 0 }
        ' "$helper_current") ||
            fail "could not inspect the target launchd_sim process"
        [ "$target_launchd_count" -eq 1 ] ||
            fail "the booted simulator requires exactly one target-specific launchd_sim"
    fi
    {
        printf '%s\n' "$memory_report"
        printf '%s\n' "$swap_report"
        echo "memory-admission-policy=$memory_admission_policy"
        echo "booted-simulators=$booted_count"
        echo "expected-booted-simulators=$expected_booted_count"
        echo "competing-processes=0"
    } >"$destination"
}

simulator_process_pids() (
    process_snapshot_path=$1
    process_name=$2
    process_device=${3:-}
    process_parent=${4:-}
    process_excluded=${5:-}
    [ -f "$process_snapshot_path" ] || return 1
    case "$process_name" in ''|*[!A-Za-z0-9_.-]*) return 1 ;; esac
    case "$process_parent" in ''|*[!0-9]*) [ -z "$process_parent" ] || return 1 ;; esac
    case "$process_excluded" in
        ''|*[!0-9]*) [ -z "$process_excluded" ] || return 1 ;;
    esac
    awk -v expected_name="$process_name" -v device="$process_device" \
            -v parent="$process_parent" -v excluded="$process_excluded" '
        {
            if (NF < 4 || $1 !~ /^[0-9]+$/ || $2 !~ /^[0-9]+$/ || $3 == "") {
                bad = 1
                next
            }
            records++
            if ($3 == expected_name &&
                    (device == "" || index($0, device)) &&
                    (parent == "" || $2 == parent) &&
                    (excluded == "" || $1 != excluded))
                print $1
        }
        END { if (bad || records == 0) exit 2 }
    ' "$process_snapshot_path"
)

launchd_sim_absent() {
    launchd_snapshot=$scratch/launchd-processes.$$
    if ! ps -axo pid=,ppid=,ucomm=,command= >"$launchd_snapshot" 2>/dev/null; then
        return 1
    fi
    launchd_matches=$(simulator_process_pids "$launchd_snapshot" launchd_sim \
        "$simulator") || return 1
    [ -z "$launchd_matches" ]
}

wait_for_shutdown() {
    attempts=0
    shutdown_list=$scratch/shutdown-list.$$
    shutdown_deadline=$runtime_cleanup_deadline
    if [ -z "$shutdown_deadline" ]; then
        shutdown_started=$(monotonic_seconds) || return 1
        case "$shutdown_started" in ''|*[!0-9]*) return 1 ;; esac
        shutdown_deadline=$((shutdown_started + 120))
    fi
    while [ "$attempts" -lt 30 ] && deadline_available "$shutdown_deadline"; do
        shutdown_timeout=$(deadline_timeout "$shutdown_deadline" 5) || return 1
        if simctl "$shutdown_timeout" list devices >"$shutdown_list" 2>/dev/null &&
                grep -F "($simulator) (Shutdown)" "$shutdown_list" >/dev/null 2>&1 &&
                launchd_sim_absent; then
            return 0
        fi
        attempts=$((attempts + 1))
        sleep 1
    done
    return 1
}

remove_probe() {
    simulator=$1
    terminate_timeout=3
    uninstall_timeout=5
    if [ -n "$runtime_cleanup_deadline" ]; then
        terminate_timeout=$(deadline_timeout "$runtime_cleanup_deadline" 3) || return 1
    fi
    simctl "$terminate_timeout" terminate "$simulator" "$bundle_id" \
        >/dev/null 2>&1 || true
    if [ -n "$runtime_cleanup_deadline" ]; then
        uninstall_timeout=$(deadline_timeout "$runtime_cleanup_deadline" 5) || return 1
    fi
    simctl "$uninstall_timeout" uninstall "$simulator" "$bundle_id" \
        >/dev/null 2>&1 || true
}

container_absent() {
    simulator=$1
    kind=$2
    container_output=$scratch/container-$kind.$$
    container_timeout=3
    if [ -n "$runtime_cleanup_deadline" ]; then
        container_timeout=$(deadline_timeout "$runtime_cleanup_deadline" 3) || return 1
    fi
    set +e
    simctl "$container_timeout" get_app_container "$simulator" "$bundle_id" \
        "$kind" >"$container_output" 2>/dev/null
    status=$?
    set -e
    if [ "$status" -eq 0 ]; then
        path=$(single_line_value "$container_output") || return 1
        [ ! -e "$path" ]
        return $?
    fi
    [ "$status" -eq 2 ] || return 1
    # simctl uses status 2 for both a missing container and several command
    # errors.  Require an independent successful listapps query before treating
    # that status as proof that this bundle is absent.
    set +e
    app_registered "$simulator"
    registration_status=$?
    set -e
    case "$registration_status" in
        0) return 1 ;;
        1) return 0 ;;
        *) return 1 ;;
    esac
}

app_registered() {
    simulator=$1
    listapps=$scratch/listapps.$$
    # LaunchServices may take a few seconds to answer immediately after its
    # process is refreshed.  Keep this command bounded, but give that
    # asynchronous update enough time to settle before classifying a timeout.
    listapps_timeout=10
    if [ -n "$runtime_cleanup_deadline" ]; then
        listapps_timeout=$(deadline_timeout "$runtime_cleanup_deadline" 10) || return 2
    fi
    simctl "$listapps_timeout" listapps "$simulator" >"$listapps" 2>/dev/null || {
        listapps_status=$?
        # Preserve timeout/cleanup failures so wait_for_removal can classify
        # the documented transient statuses and fail closed on other errors.
        return "$listapps_status"
    }
    grep -F "\"$bundle_id\"" "$listapps" >/dev/null 2>&1
}

refresh_simulator_lsd() {
    simulator=$1
    destination=$2
    device_is_booted "$simulator" || return 1
    process_snapshot=$scratch/refresh-processes.$$
    if ! ps -axo pid=,ppid=,ucomm=,command= >"$process_snapshot" 2>/dev/null; then
        return 1
    fi
    launchd_pid=$(simulator_process_pids "$process_snapshot" launchd_sim \
        "$simulator") || return 1
    case "$launchd_pid" in
        ''|*[!0-9]*) return 1 ;;
    esac
    if ! ps -axo pid=,ppid=,ucomm=,command= >"$process_snapshot" 2>/dev/null; then
        return 1
    fi
    lsd_pid=$(simulator_process_pids "$process_snapshot" lsd "" \
        "$launchd_pid") || return 1
    case "$lsd_pid" in
        ''|*[!0-9]*) return 1 ;;
    esac
    kill -TERM "$lsd_pid" 2>/dev/null || return 1
    replacement=
    attempts=0
    while [ "$attempts" -lt 40 ]; do
        if ! ps -axo pid=,ppid=,ucomm=,command= >"$process_snapshot" 2>/dev/null; then
            return 1
        fi
        replacement=$(simulator_process_pids "$process_snapshot" lsd "" \
            "$launchd_pid" "$lsd_pid") || return 1
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

registration_status_retryable() {
    registration_status=$1
    case "$registration_status" in
        2) return 0 ;;
        124)
            # 124 is transient only when run_with_timeout actually expired
            # and cleaned up its child.  A raw command exit of 124, or a
            # timeout whose process cleanup failed (125), is fail-closed.
            [ -n "${command_timeout_marker:-}" ] || return 1
            [ -e "$command_timeout_marker" ] || return 1
            [ -n "${command_cleanup_failure_marker:-}" ] || return 1
            [ ! -e "$command_cleanup_failure_marker" ]
            ;;
        *) return 1 ;;
    esac
}

wait_for_removal() {
    simulator=$1
    destination=$2
    attempts=0
    removal_deadline=$runtime_cleanup_deadline
    if [ -z "$removal_deadline" ]; then
        removal_started=$(monotonic_seconds) || return 1
        case "$removal_started" in ''|*[!0-9]*) return 1 ;; esac
        removal_deadline=$((removal_started + 120))
    fi
    # iOS 12 LaunchServices can publish an uninstall after its containers have
    # disappeared.  Keep polling long enough for that asynchronous update, but
    # retain the aggregate deadline and fail-closed command statuses below.
    while [ "$attempts" -lt 80 ] && deadline_available "$removal_deadline"; do
        if container_absent "$simulator" app && container_absent "$simulator" data; then
            # listapps can briefly fail while iOS 12 LaunchServices settles
            # the uninstall.  Retry only that documented transient status;
            # every other error remains fail-closed.
            registration_attempts=0
            registration_status=2
            while [ "$registration_attempts" -lt 80 ] &&
                    deadline_available "$removal_deadline"; do
                set +e
                app_registered "$simulator"
                registration_status=$?
                set -e
                case "$registration_status" in
                    0) break ;;
                    1) return 0 ;;
                    2|124)
                        registration_status_retryable "$registration_status" ||
                            return 1
                        registration_attempts=$((registration_attempts + 1))
                        sleep 0.25
                        ;;
                    *) return 1 ;;
                esac
            done
            [ "$registration_status" -eq 0 ] || return 1
            refresh_simulator_lsd "$simulator" "$destination" || return 1
            attempts=0
            while [ "$attempts" -lt 80 ] &&
                    deadline_available "$removal_deadline"; do
                set +e
                app_registered "$simulator"
                registration_status=$?
                set -e
                case "$registration_status" in
                    0|2|124)
                        if [ "$registration_status" -ne 0 ]; then
                            registration_status_retryable "$registration_status" ||
                                return 1
                        fi
                        attempts=$((attempts + 1))
                        sleep 0.25
                        ;;
                    1) return 0 ;;
                    *) return 1 ;;
                esac
            done
            return 1
        fi
        attempts=$((attempts + 1))
        sleep 0.25
    done
    return 1
}

cleanup_runtime() {
    destination=$1
    cleanup_status=0
    mkdir -p "$destination"
    if [ -z "$runtime_cleanup_deadline" ]; then
        runtime_cleanup_started=$(monotonic_seconds) || return 1
        case "$runtime_cleanup_started" in
            ''|*[!0-9]*) return 1 ;;
        esac
        # Reserve teardown margin below the four-minute outer safety budget;
        # every simulator command is also clipped to the remaining deadline.
        runtime_cleanup_deadline=$((runtime_cleanup_started + 225))
    fi
    if [ "$installed" -eq 1 ]; then
        deadline_available "$runtime_cleanup_deadline" || return 1
        remove_probe "$simulator" || return 1
        if wait_for_removal "$simulator" "$destination"; then
            installed=0
            echo "probe-containers-absent=true" >>"$destination/cleanup.log"
            echo "probe-registration-absent=true" >>"$destination/cleanup.log"
        else
            echo "[verify-home-simulator][cleanup] probe remains on $simulator" >&2
            cleanup_status=1
        fi
    fi
    if [ "$shutdown_required" -eq 1 ]; then
        shutdown_status=0
        deadline_available "$runtime_cleanup_deadline" || return 1
        shutdown_timeout=$(deadline_timeout "$runtime_cleanup_deadline" 15) || return 1
        simctl "$shutdown_timeout" shutdown "$simulator" \
            >>"$destination/shutdown.log" 2>&1 ||
            shutdown_status=$?
        if [ "$shutdown_status" -eq 0 ] && wait_for_shutdown; then
            shutdown_required=0
            echo "simulator-state=Shutdown" >>"$destination/cleanup.log"
            echo "launchd-sim-absent=true" >>"$destination/cleanup.log"
        else
            echo "[verify-home-simulator][cleanup] simulator shutdown was not proven: $simulator (status=$shutdown_status)" >&2
            cleanup_status=1
        fi
    fi
    if [ "$cleanup_status" -eq 0 ]; then
        runtime_cleanup_deadline=
    fi
    return "$cleanup_status"
}

cleanup() {
    original_status=$?
    trap - EXIT HUP INT TERM
    cleanup_status=0
    cleanup_tracked_processes || cleanup_status=1
    if [ "$mode" = run ] && { [ "$installed" -eq 1 ] || [ "$shutdown_required" -eq 1 ]; }; then
        cleanup_runtime "$artifact_dir" || cleanup_status=1
    fi
    rm -rf -- "$scratch"
    if [ "$mode" = run ] && [ "$case_committed" -eq 0 ] && [ -e "$case_temporary" ]; then
        rm -rf -- "$case_temporary"
    fi
    if [ "$common_committed" -eq 0 ] && [ -e "$common_temporary" ]; then
        rm -rf -- "$common_temporary"
    fi
    if [ -e "$completion_temporary" ]; then
        rm -f -- "$completion_temporary"
    fi
    if [ "$lock_owned" -eq 1 ]; then
        rmdir "$lock_dir" 2>/dev/null || cleanup_status=1
        lock_owned=0
    fi
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
    is_number "$actual" || fail "$message ($key is not numeric: $actual)"
    is_number "$expected" || fail "$message (expected value is not numeric: $expected)"
    awk -v left="$actual" -v right="$expected" -v op="$operator" 'BEGIN {
        if (op == "gt") ok = left > right;
        else if (op == "ge") ok = left >= right;
        else if (op == "lt") ok = left < right;
        else if (op == "le") ok = left <= right;
        else ok = 0;
        exit !ok;
    }' || fail "$message ($key=$actual expected $operator $expected)"
}

assert_nonempty() {
    file=$1
    key=$2
    message=$3
    actual=$(read_state "$file" "$key" || true)
    [ -n "$actual" ] || fail "$message ($key is empty)"
}

wait_for_state() {
    file=$1
    phase=$2
    style=$3
    content_size=$4
    expected_pid=$5
    attempts=0
    while [ "$attempts" -lt 120 ]; do
        if [ -f "$file" ]; then
            ready=$(read_state "$file" ready || true)
            actual_phase=$(read_state "$file" phase || true)
            actual_style=$(read_state "$file" style || true)
            actual_size=$(read_state "$file" contentSize || true)
            actual_pid=$(read_state "$file" processID || true)
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

launch_pid() {
    awk -F ': ' '/: [0-9]+$/ {value=$NF} END {print value}' "$1"
}

capture_phase() {
    state=$1
    destination=$2
    name=$3
    simulator=$4
    captured_state=$destination/$name-state.plist
    temporary_state=$destination/.$name-state.plist.tmp.$$
    capture_attempts=0
    while [ "$capture_attempts" -lt 80 ]; do
        if cp "$state" "$temporary_state" 2>/dev/null &&
                plutil -lint "$temporary_state" >/dev/null 2>&1 &&
                [ "$(read_state "$temporary_state" ready || true)" = true ]; then
            mv "$temporary_state" "$captured_state"
            break
        fi
        rm -f -- "$temporary_state"
        capture_attempts=$((capture_attempts + 1))
        sleep 0.1
    done
    rm -f -- "$temporary_state"
    [ -f "$captured_state" ] ||
        fail "$name Home evidence did not yield a stable ready snapshot"
    plutil -convert json -r -o "$destination/$name-ui-tree.json" "$captured_state"
    simctl 30 io "$simulator" screenshot "$destination/$name.png" >/dev/null ||
        fail "could not capture $name screenshot"
}

verify_base() {
    state=$1
    expected_runtime=$2
    launched_pid=$3
    expected_layout=$4
    assert_state "$state" schema 1 "Home probe schema changed"
    assert_state "$state" fixtureVersion native-home-legacy-hierarchy-v2 \
        "Home fixture version changed"
    assert_state "$state" systemVersion "$expected_runtime" \
        "Home runtime changed"
    assert_state "$state" processID "$launched_pid" \
        "Home state PID differs from launch"
    assert_state "$state" buildEvidence.sourceHEAD "$source_head" \
        "Home source HEAD evidence is stale"
    assert_state "$state" buildEvidence.binarySHA256 "$binary_sha" \
        "Home binary evidence is stale"
    assert_state "$state" buildEvidence.bundleShortVersion "$bundle_short_version" \
        "Home short version evidence changed"
    assert_state "$state" buildEvidence.bundleVersion "$bundle_version" \
        "Home bundle version evidence changed"
    assert_state "$state" controllerClass CydiaHomeProbeController \
        "native Home controller was not installed"
    assert_state "$state" navigationURL cydia://home \
        "Home navigation URL changed"
    assert_state "$state" sectionCount 7 "Home section count changed"
    assert_state "$state" rowCount 14 "Home row count changed"
    assert_state "$state" rowIdentifiers.0 cydia.home.social \
        "Home social pair is not first"
    assert_state "$state" rowIdentifiers.1 cydia.home.discovery \
        "Featured and Themes pair moved"
    assert_state "$state" rowIdentifiers.2 cydia.home.account \
        "Manage Account row moved"
    assert_state "$state" rowIdentifiers.3 cydia.home.help.upgrading \
        "Upgrading help row moved"
    assert_state "$state" rowIdentifiers.4 cydia.home.help.applications \
        "application extensions row moved"
    assert_state "$state" rowIdentifiers.5 cydia.home.help.sources \
        "More Package Sources row moved"
    assert_state "$state" rowIdentifiers.6 cydia.home.guide.faq \
        "FAQ row moved"
    assert_state "$state" rowIdentifiers.7 cydia.home.guide.copying \
        "Copying Files row moved"
    assert_state "$state" rowIdentifiers.8 cydia.home.guide.openssh \
        "OpenSSH row moved"
    assert_state "$state" rowIdentifiers.9 cydia.home.guide.password \
        "Root Password row moved"
    assert_state "$state" rowIdentifiers.10 cydia.home.guide.storage \
        "Storage row moved"
    assert_state "$state" rowIdentifiers.11 cydia.home.developer.resources \
        "developer resources row moved"
    assert_state "$state" rowIdentifiers.12 cydia.home.credits \
        "Credits row moved"
    assert_state "$state" rowIdentifiers.13 cydia.home.privacy \
        "Privacy row moved"
    assert_state "$state" sectionRowCounts.0 1 "social section shape changed"
    assert_state "$state" sectionRowCounts.1 1 "discovery section shape changed"
    assert_state "$state" sectionRowCounts.2 1 "account section shape changed"
    assert_state "$state" sectionRowCounts.3 3 "help section shape changed"
    assert_state "$state" sectionRowCounts.4 5 "guide section shape changed"
    assert_state "$state" sectionRowCounts.5 1 "developer section shape changed"
    assert_state "$state" sectionRowCounts.6 2 "legal section shape changed"
    assert_state "$state" actionCount 16 "Home action count changed"
    assert_state "$state" actionIdentifiers.0 cydia.home.social.facebook \
        "Facebook action moved"
    assert_state "$state" actionIdentifiers.1 cydia.home.social.twitter \
        "Twitter action moved"
    assert_state "$state" actionIdentifiers.2 cydia.home.featured \
        "Featured action moved"
    assert_state "$state" actionIdentifiers.3 cydia.home.themes \
        "Themes action moved"
    assert_state "$state" actionIdentifiers.4 cydia.home.account \
        "Manage Account action moved"
    assert_state "$state" actionIdentifiers.5 cydia.home.help.upgrading \
        "Upgrading help action moved"
    assert_state "$state" actionIdentifiers.6 cydia.home.help.applications \
        "application extensions action moved"
    assert_state "$state" actionIdentifiers.7 cydia.home.help.sources \
        "More Package Sources action moved"
    assert_state "$state" actionIdentifiers.8 cydia.home.guide.faq \
        "FAQ action moved"
    assert_state "$state" actionIdentifiers.9 cydia.home.guide.copying \
        "Copying Files action moved"
    assert_state "$state" actionIdentifiers.10 cydia.home.guide.openssh \
        "OpenSSH action moved"
    assert_state "$state" actionIdentifiers.11 cydia.home.guide.password \
        "Root Password action moved"
    assert_state "$state" actionIdentifiers.12 cydia.home.guide.storage \
        "Storage action moved"
    assert_state "$state" actionIdentifiers.13 cydia.home.developer.resources \
        "developer resources action moved"
    assert_state "$state" actionIdentifiers.14 cydia.home.credits \
        "Credits action moved"
    assert_state "$state" actionIdentifiers.15 cydia.home.privacy \
        "Privacy action moved"
    expected_tag=2
    index=0
    while [ "$index" -le 15 ]; do
        assert_state "$state" "actionTags.$index" "$expected_tag" \
            "Home action tag at index $index changed"
        expected_tag=$((expected_tag + 1))
        index=$((index + 1))
    done
    assert_state "$state" actionDestinations.0 https://www.facebook.com/Cydia \
        "Facebook destination changed"
    assert_state "$state" actionDestinations.1 https://twitter.com/saurik \
        "Twitter destination changed"
    assert_state "$state" actionDestinations.2 https://cydia.saurik.com/featured/ \
        "Featured destination changed"
    assert_state "$state" actionDestinations.3 https://cydia.saurik.com/themes/ \
        "Themes destination changed"
    assert_state "$state" actionDestinations.4 https://cydia.saurik.com/account/ \
        "Manage Account destination changed"
    assert_state "$state" actionDestinations.5 https://cydia.saurik.com/upgrading/ \
        "Upgrading destination changed"
    application_idiom=iphone
    [ "$expected_layout" = ipad ] && application_idiom=ipad
    assert_state "$state" actionDestinations.6 \
        "https://cydia.saurik.com/ui/ios~$application_idiom/1.1/application/" \
        "application extensions destination changed"
    assert_state "$state" actionDestinations.7 https://cydia.saurik.com/sources.html \
        "More Package Sources destination changed"
    assert_state "$state" actionDestinations.8 https://cydia.saurik.com/questions.html \
        "FAQ destination changed"
    assert_state "$state" actionDestinations.9 https://cydia.saurik.com/copying.html \
        "Copying Files destination changed"
    assert_state "$state" actionDestinations.10 https://cydia.saurik.com/openssh.html \
        "OpenSSH destination changed"
    assert_state "$state" actionDestinations.11 https://cydia.saurik.com/password.html \
        "Root Password destination changed"
    assert_state "$state" actionDestinations.12 https://cydia.saurik.com/storage.html \
        "Storage destination changed"
    assert_state "$state" actionDestinations.13 https://cydia.saurik.com/faq/developing.html \
        "developer resources destination changed"
    assert_state "$state" actionDestinations.14 https://cydia.saurik.com/credits.html \
        "Credits destination changed"
    assert_state "$state" actionDestinations.15 https://cydia.saurik.com/policy/privacy/ \
        "Privacy destination changed"
    assert_state "$state" headerPresent true "Home header is absent"
    assert_state "$state" statusHidden true \
        "ready Home still renders a permanent status row"
    assert_number "$state" statusFrameHeight le 0 \
        "ready Home reserves geometry for a hidden status"
    assert_state "$state" headerContentFitted true \
        "Home topper content is outside its header"
    if [ "$(read_state "$state" contentSize)" != accessibility-large ]; then
        assert_number "$state" headerHeight le 100 \
            "ready Home topper is much taller than the legacy header"
    fi
    assert_state "$state" footerPresent true "Home footer is absent"
    footer_summary=$(read_state "$state" footerSummary || true)
    printf '%s\n' "$footer_summary" | grep -F 'iOS ' >/dev/null ||
        fail "Home footer lost its iOS version ($footer_summary)"
    printf '%s\n' "$footer_summary" | grep -F 'Cydia' >/dev/null ||
        fail "Home footer lost its Cydia version ($footer_summary)"
    assert_state "$state" footerHardwareModelMatchesRuntime true \
        "Home footer does not display the runtime hardware model"
    assert_state "$state" footerCydiaVersionMatchesRuntime true \
        "Home footer does not display the installed Cydia version"
    assert_state "$state" footerDeviceIdentifierAvailable true \
        "Home runtime did not provide its legacy visible device identifier"
    assert_state "$state" footerDeviceIdentifierMatchesRuntime true \
        "Home footer device identifier differs from the runtime value"
    assert_state "$state" navigationBarHidden false "Home navigation bar is hidden"
    expected_status_style=0
    [ "$(read_state "$state" style)" = dark ] && expected_status_style=1
    assert_state "$state" preferredStatusBarStyle "$expected_status_style" \
        "Home status-bar content style does not match appearance"
    assert_state "$state" rowLabelsPresent true "Home row labels are missing"
    assert_state "$state" rowsMeetTouchTarget true "Home rows are below 44 points"
    assert_state "$state" splitControlCount 4 \
        "Home split rows lost one of their four controls"
    assert_state "$state" splitControlsMeetTouchTarget true \
        "Home split controls are below 44 points"
    assert_state "$state" splitControlsWired true \
        "Home split controls are not wired to their native actions"
    assert_state "$state" splitDisclosureCount 4 \
        "Home split rows lost one of their four disclosure indicators"
    assert_state "$state" splitDisclosuresDecorative true \
        "Home split disclosure indicators entered the accessibility tree or intercept touches"
    assert_state "$state" splitDisclosuresInsideControls true \
        "Home split disclosure indicator escaped its tappable half"
    assert_state "$state" splitDisclosuresAtTrailingEdge true \
        "Home split disclosure indicator is not at its half's trailing edge"
    assert_state "$state" splitDisclosureTintSynchronized true \
        "Home split disclosure indicators did not follow the active appearance"
    assert_state "$state" splitDisclosuresSystemOwned true \
        "Home split disclosure indicators are not UIKit-owned accessories"
    assert_state "$state" splitContentLeadingAligned true \
        "Home split icons are not aligned to the normal cell leading margin"
    expected_split_layout=horizontal
    [ "$(read_state "$state" contentSize)" = accessibility-large ] &&
        expected_split_layout=vertical
    assert_state "$state" splitLayout "$expected_split_layout" \
        "Home split controls did not adapt to Dynamic Type"
    assert_state "$state" plainRowsHaveNoIcons true \
        "Home plain help/legal rows repeat an unrelated icon"
    assert_state "$state" accountHasHistoricalIcon true \
        "Home Manage Account row lost its historical icon"
    assert_state "$state" legacyAssetsPresent true \
        "Home historical assets are not installed"
    if [ "$expected_layout" = ipad ]; then
        assert_state "$state" iPadRecommendationsVisible true \
            "iPad Home did not render its companion recommendation column"
        assert_state "$state" iPadRecommendationSections 2 \
            "iPad recommendation section count changed"
        assert_state "$state" iPadRecommendationRows 10 \
            "iPad recommendation row count changed"
        assert_state "$state" iPadRecommendationIdentifiers.0 \
            cydia.home.ipad.libactivator \
            "iPad extension ordering changed"
        assert_state "$state" iPadRecommendationIdentifiers.9 \
            cydia.home.ipad.com.rpetrich.videopane \
            "iPad product ordering changed"
        assert_state "$state" columnsSeparated true \
            "iPad Home columns overlap or collapse"
    else
        assert_state "$state" iPadRecommendationsVisible false \
            "phone Home unexpectedly rendered the iPad recommendation column"
    fi
    header_title=$(read_state "$state" headerTitle || true)
    [ -n "$header_title" ] && printf '%s\n' "$header_title" | grep -F "Cydia" >/dev/null ||
        fail "Home welcome title changed (headerTitle=$header_title)"
    assert_state "$state" requestUpdateCount 0 "Home started an update unexpectedly"
    assert_state "$state" cancelUpdateCount 0 "Home cancelled an update unexpectedly"
    assert_state "$state" protocolRegistered true \
        "Home URL protocol canary was not registered"
    assert_state "$state" protocolCanaryCount 1 \
        "Home URL protocol canary was not intercepted exactly once"
    assert_state "$state" appCacheRequestCount 0 \
        "an Application Cache request was observed"
    assert_state "$state" remoteHomeCanaryCount 1 \
        "the exact retired Home request matcher was not exercised"
    assert_state "$state" unexpectedRemoteHomeRequestCount 0 \
        "the native Home fetched the legacy remote Home document"
    assert_state "$state" retiredAssetsAbsent true \
        "retired Application Cache HTML assets remain in the installed bundle"
}

copy_state() {
    state=$1
    destination=$2
    phase_name=$3
    simulator=$4
    capture_phase "$state" "$destination" "$phase_name" "$simulator"
}

run_probe() {
    device_is_booted "$simulator" || fail "$label simulator is not booted"
    destination=$artifact_dir
    mkdir -p "$destination"
    installed=1
    remove_probe "$simulator"
    wait_for_removal "$simulator" "$destination" ||
        fail "$label had a stale Home probe registration before install"
    simctl 30 install "$simulator" "$probe_app" >"$destination/install.log" 2>&1 ||
        fail "could not install on $label"
    app_container_file=$scratch/installed-app-container.$$
    simctl 20 get_app_container "$simulator" "$bundle_id" app \
        >"$app_container_file" || fail "could not locate $label app container"
    app_container=$(single_line_value "$app_container_file") ||
        fail "$label app container path is malformed"
    installed_sha=$(shasum -a 256 "$app_container/Cydia" | awk '{print $1}')
    [ "$installed_sha" = "$binary_sha" ] ||
        fail "$label installed binary hash mismatch"
    {
        echo "source-head=$source_head"
        echo "source-tree=$source_tree"
        echo "binary-sha256=$binary_sha"
        echo "installed-binary-sha256=$installed_sha"
        echo "bundle-id=$bundle_id"
        echo "bundle-short-version=$bundle_short_version"
        echo "bundle-version=$bundle_version"
        echo "developer-dir=$developer_dir"
        echo "xcode-version=$xcode_version"
        echo "xcode-build=$xcode_build"
        echo "xcodebuild-sha256=$xcodebuild_sha"
        echo "xcrun-path=$xcrun_path"
        echo "xcrun-sha256=$xcrun_sha"
        echo "build-xcrun-path=$build_xcrun_path"
        echo "build-xcrun-sha256=$build_xcrun_sha"
        echo "build-xcodebuild-path=$build_xcodebuild_path"
        echo "build-xcodebuild-sha256=$build_xcodebuild_sha"
        echo "simctl-path=$simctl_path"
        echo "simctl-sha256=$simctl_sha"
        echo "simulator-compiler-path=$simulator_compiler_path"
        echo "simulator-compiler-sha256=$simulator_compiler_sha"
        echo "simulator-sdk=$simulator_sdk"
        echo "simulator-sdk-version=$simulator_sdk_version"
        echo "simulator-udid=$simulator"
        echo "runtime-identifier=$actual_runtime_identifier"
        echo "device-type=$actual_device_type"
        echo "device-name=$actual_device_name"
    } >"$destination/provenance.txt"
    touch "$destination/crash-scan-start"
    run_with_timeout 30 env \
        DEVELOPER_DIR="$developer_dir" \
        SIMCTL_CHILD_CYDIA_PROBE_SOURCE_HEAD="$source_head" \
        SIMCTL_CHILD_CYDIA_PROBE_BINARY_SHA256="$binary_sha" \
        SIMCTL_CHILD_CYDIA_PROBE_BUNDLE_SHORT_VERSION="$bundle_short_version" \
        SIMCTL_CHILD_CYDIA_PROBE_BUNDLE_VERSION="$bundle_version" \
        "$xcrun_path" simctl launch --stdout="$destination/stdout.log" \
        --stderr="$destination/stderr.log" "$simulator" "$bundle_id" \
        --cydia-appearance-probe --cydia-home-probe >"$destination/launch.log" 2>&1 ||
        fail "could not launch on $label"
    launched_pid=$(awk -F ': ' '/: [0-9]+$/ {value=$NF} END {print value}' \
        "$destination/launch.log")
    case "$launched_pid" in
        ''|*[!0-9]*) fail "$label launch did not report a PID" ;;
    esac
    data_container_file=$scratch/installed-data-container.$$
    simctl 20 get_app_container "$simulator" "$bundle_id" data \
        >"$data_container_file" || fail "could not locate $label data container"
    data_container=$(single_line_value "$data_container_file") ||
        fail "$label data container path is malformed"
    state=$data_container/tmp/cydia-home-probe.plist
    wait_for_state "$state" full light large "$launched_pid" ||
        fail "$label full Home state did not settle"
    wait_for_value "$state" protocolCanaryCount 1 ||
        fail "$label URL protocol canary did not settle"
    wait_for_value "$state" remoteHomeCanaryCount 1 ||
        fail "$label exact remote Home matcher canary did not settle"
    verify_base "$state" "$expected_runtime" "$launched_pid" "$expected_layout"
    copy_state "$state" "$destination" full-light "$simulator"
    light_luminance=$(read_state "$state" surfaceLuminance)
    light_controller=$(read_state "$state" controllerToken)
    light_model=$(read_state "$state" modelToken)

    touch "$data_container/tmp/cydia-home-probe-dark"
    wait_for_state "$state" full dark large "$launched_pid" ||
        fail "$label dark Home state did not settle"
    verify_base "$state" "$expected_runtime" "$launched_pid" "$expected_layout"
    assert_state "$state" controllerToken "$light_controller" \
        "Home dark transition replaced its controller"
    assert_state "$state" modelToken "$light_model" \
        "Home dark transition replaced its model"
    assert_number "$state" surfaceLuminance lt "$light_luminance" \
        "Home dark transition did not update its surface"
    copy_state "$state" "$destination" full-dark "$simulator"
    dark_separated=$(read_state "$state" surfaceSeparated)
    assert_state "$state" surfaceSeparated true \
        "Home dark grouped and cell surfaces still collapse"
    assert_number "$state" cellLuminance ge 30 \
        "Home dark cell surface is indistinguishable from its root"

    touch "$data_container/tmp/cydia-home-probe-accessibility"
    wait_for_state "$state" full dark accessibility-large "$launched_pid" ||
        fail "$label Accessibility Large Home state did not settle"
    verify_base "$state" "$expected_runtime" "$launched_pid" "$expected_layout"
    assert_state "$state" controllerToken "$light_controller" \
        "Home Dynamic Type transition replaced its controller"
    assert_state "$state" modelToken "$light_model" \
        "Home Dynamic Type transition replaced its model"
    assert_state "$state" rowLabelsPresent true \
        "Home Accessibility Large row labels are missing"
    copy_state "$state" "$destination" full-dark-accessibility "$simulator"

    touch "$data_container/tmp/cydia-home-probe-empty"
    wait_for_state "$state" empty light large "$launched_pid" ||
        fail "$label empty Home state did not settle"
    assert_state "$state" status 0 "empty Home status changed"
    assert_state "$state" databaseReady false "empty Home is marked ready"
    assert_state "$state" statusHidden false "empty Home hides its loading status"
    assert_state "$state" statusVisibleAndFitted true \
        "empty Home loading status is outside the header"
    assert_nonempty "$state" headerStatus "empty Home loading status is blank"
    assert_state "$state" sourceCount 0 "empty Home has sources"
    assert_state "$state" packageCount 0 "empty Home has packages"
    copy_state "$state" "$destination" empty-light "$simulator"

    touch "$data_container/tmp/cydia-home-probe-offline"
    wait_for_state "$state" offline dark large "$launched_pid" ||
        fail "$label offline Home state did not settle"
    assert_state "$state" status 3 "offline Home status changed"
    assert_state "$state" databaseReady true "offline Home lost its cached database"
    assert_state "$state" statusHidden false "offline Home hides its status"
    assert_state "$state" statusVisibleAndFitted true \
        "offline Home status is outside the header"
    assert_nonempty "$state" headerStatus "offline Home status is blank"
    copy_state "$state" "$destination" offline-dark "$simulator"

    touch "$data_container/tmp/cydia-home-probe-updating"
    wait_for_state "$state" updating light large "$launched_pid" ||
        fail "$label updating Home state did not settle"
    assert_state "$state" status 2 "updating Home status changed"
    assert_state "$state" statusHidden false "updating Home hides its status"
    assert_state "$state" statusVisibleAndFitted true \
        "updating Home status is outside the header"
    assert_nonempty "$state" headerStatus "updating Home status is blank"
    copy_state "$state" "$destination" updating-light "$simulator"

    touch "$data_container/tmp/cydia-home-probe-refresh"
    wait_for_state "$state" updating light large "$launched_pid" ||
        fail "$label Refresh changed the model unexpectedly"
    wait_for_value "$state" requestUpdateCount 1 ||
        fail "$label Refresh state did not settle"
    assert_state "$state" requestUpdateCount 1 \
        "Home Refresh did not call the update delegate"
    copy_state "$state" "$destination" refresh "$simulator"
    touch "$data_container/tmp/cydia-home-probe-cancel"
    wait_for_state "$state" updating light large "$launched_pid" ||
        fail "$label Cancel changed the updating fixture unexpectedly"
    wait_for_value "$state" cancelUpdateCount 1 ||
        fail "$label Cancel state did not settle"
    assert_state "$state" cancelUpdateCount 1 \
        "Home Cancel did not call the update delegate"
    assert_state "$state" appCacheRequestCount 0 \
        "$label refresh/cancel path requested Application Cache"
    assert_state "$state" unexpectedRemoteHomeRequestCount 0 \
        "$label refresh/cancel path fetched the remote Home document"
    copy_state "$state" "$destination" cancel "$simulator"

    touch "$data_container/tmp/cydia-home-probe-arm-lifecycle"
    wait_for_value "$state" lifecycleArmed true ||
        fail "$label Home lifecycle observer did not arm"
    wait_for_value "$state" lifecycleNotificationCount 0 ||
        fail "$label Home lifecycle observer did not start empty"
    wait_for_state "$state" updating light large "$launched_pid" ||
        fail "$label Home did not settle before backgrounding"
    cp "$state" "$destination/lifecycle-before-state.plist"
    initial_pid=$(read_state "$state" processID)
    simctl 30 launch "$simulator" "$background_bundle_id" \
        >"$destination/background-settings-launch.log" 2>&1 ||
        fail "$label could not foreground Settings to background Home"
    wait_for_value "$state" lastLifecycleNotification \
        UIApplicationDidEnterBackgroundNotification ||
        fail "$label Home did not receive the real background notification"
    assert_state "$state" applicationState background \
        "$label Home did not reach UIApplicationStateBackground"
    assert_state "$state" lifecycleNotificationCount 2 \
        "$label Home background notification count changed"
    assert_state "$state" lifecycleNotifications.0 \
        UIApplicationWillResignActiveNotification \
        "$label Home missed UIApplicationWillResignActiveNotification"
    assert_state "$state" lifecycleNotifications.1 \
        UIApplicationDidEnterBackgroundNotification \
        "$label Home missed UIApplicationDidEnterBackgroundNotification"
    assert_state "$state" appCacheRequestCount 0 \
        "$label background transition requested Application Cache"
    assert_state "$state" unexpectedRemoteHomeRequestCount 0 \
        "$label background transition fetched the remote Home document"
    cp "$state" "$destination/lifecycle-background-state.plist"
    simctl 30 launch "$simulator" "$bundle_id" \
        >"$destination/foreground-launch.log" 2>&1 ||
        fail "$label could not foreground the Home probe"
    wait_for_value "$state" lifecycleComplete true ||
        fail "$label Home did not complete the real foreground transition"
    assert_state "$state" applicationState active \
        "$label Home did not return to UIApplicationStateActive"
    assert_state "$state" lifecycleNotificationCount 4 \
        "$label Home foreground notification count changed"
    assert_state "$state" lifecycleNotifications.2 \
        UIApplicationWillEnterForegroundNotification \
        "$label Home missed UIApplicationWillEnterForegroundNotification"
    assert_state "$state" lifecycleNotifications.3 \
        UIApplicationDidBecomeActiveNotification \
        "$label Home missed UIApplicationDidBecomeActiveNotification"
    foreground_pid=$(launch_pid "$destination/foreground-launch.log")
    [ -n "$foreground_pid" ] && [ "$foreground_pid" = "$initial_pid" ] ||
        fail "$label plain relaunch did not foreground the same Home process"
    assert_state "$state" appCacheRequestCount 0 \
        "$label foreground transition requested Application Cache"
    assert_state "$state" unexpectedRemoteHomeRequestCount 0 \
        "$label foreground transition fetched the remote Home document"
    cp "$state" "$destination/lifecycle-foreground-state.plist"
    simctl 30 io "$simulator" screenshot \
        "$destination/lifecycle-foreground.png" >/dev/null ||
        fail "$label could not capture Home after foregrounding"

    touch "$data_container/tmp/cydia-home-probe-route-sources"
    wait_for_state "$state" updating light large "$launched_pid" ||
        fail "$label More Package Sources action did not settle"
    wait_for_value "$state" routeCount 1 ||
        fail "$label More Package Sources route did not settle"
    assert_state "$state" routeCount 1 \
        "Home More Package Sources did not use typed dispatch"
    assert_state "$state" fallbackRouteCount 0 "Home route fell through to legacy dispatch"
    assert_state "$state" lastExternalURL https://cydia.saurik.com/sources.html \
        "Home More Package Sources destination changed"
    assert_state "$state" lastRoute \
        cydia://url/https%3A%2F%2Fcydia.saurik.com%2Fsources.html \
        "Home More Package Sources route changed"
    assert_state "$state" lastReferrer cydia://home "Home route referrer changed"
    assert_state "$state" navigationDepth 2 \
        "Home More Package Sources did not push its typed destination"
    copy_state "$state" "$destination" route-sources "$simulator"
    touch "$data_container/tmp/cydia-home-probe-route-pop"
    wait_for_value "$state" navigationDepth 1 ||
        fail "$label native route return did not settle"

    touch "$data_container/tmp/cydia-home-probe-guide"
    wait_for_state "$state" updating light large "$launched_pid" ||
        fail "$label external guide state did not settle"
    wait_for_value "$state" lastExternalURL \
        https://cydia.saurik.com/questions.html ||
        fail "$label external guide action did not settle"
    assert_state "$state" lastExternalURL \
        https://cydia.saurik.com/questions.html \
        "Home guide did not use the external handoff"
    assert_state "$state" routeCount 2 \
        "Home FAQ did not use typed external dispatch"
    assert_state "$state" lastRoute \
        cydia://url/https%3A%2F%2Fcydia.saurik.com%2Fquestions.html \
        "Home FAQ route changed"
    assert_state "$state" navigationDepth 2 \
        "Home FAQ did not push its typed destination"
    copy_state "$state" "$destination" guide "$simulator"
    touch "$data_container/tmp/cydia-home-probe-route-pop"
    wait_for_value "$state" navigationDepth 1 ||
        fail "$label guide route return did not settle"

    touch "$data_container/tmp/cydia-home-probe-featured"
    wait_for_value "$state" routeCount 3 ||
        fail "$label Featured split control did not dispatch"
    assert_state "$state" lastExternalURL \
        https://cydia.saurik.com/featured/ \
        "Home Featured destination changed"
    assert_state "$state" lastRoute \
        cydia://url/https%3A%2F%2Fcydia.saurik.com%2Ffeatured%2F \
        "Home Featured route changed"
    assert_state "$state" navigationDepth 2 \
        "Home Featured split control did not push its typed destination"
    copy_state "$state" "$destination" featured "$simulator"
    touch "$data_container/tmp/cydia-home-probe-route-pop"
    wait_for_value "$state" navigationDepth 1 ||
        fail "$label Featured route return did not settle"

    if [ "$expected_layout" = ipad ]; then
        touch "$data_container/tmp/cydia-home-probe-ipad-package"
        wait_for_value "$state" routeCount 4 ||
            fail "$label iPad package recommendation did not dispatch"
        assert_state "$state" lastRoute cydia://package/libactivator \
            "Home iPad package recommendation route changed"
        assert_state "$state" lastReferrer cydia://home \
            "Home iPad package recommendation referrer changed"
        assert_state "$state" navigationDepth 2 \
            "Home iPad package recommendation did not push its destination"
        copy_state "$state" "$destination" ipad-package "$simulator"
        touch "$data_container/tmp/cydia-home-probe-route-pop"
        wait_for_value "$state" navigationDepth 1 ||
            fail "$label iPad package recommendation return did not settle"
    fi

    touch "$data_container/tmp/cydia-home-probe-about"
    attempts=0
    while [ "$attempts" -lt 80 ]; do
        about=$(read_state "$state" aboutVisible || true)
        [ "$about" = true ] && break
        attempts=$((attempts + 1))
        sleep 0.25
    done
    assert_state "$state" aboutVisible true "Home About alert did not appear"
    about_action=$(read_state "$state" aboutActionTitles.0 || true)
    [ -n "$about_action" ] || fail "Home About alert lost its dismiss action"
    copy_state "$state" "$destination" about "$simulator"

    kill -0 "$launched_pid" 2>/dev/null || fail "$label Home process exited"
    : >"$destination/crash-check.txt"
    for crash_root in "$HOME/Library/Logs/DiagnosticReports" \
        "$HOME/Library/Developer/CoreSimulator/Devices/$simulator/data/Library/Logs/CrashReporter"; do
        [ -d "$crash_root" ] || continue
        crash_files=$scratch/crash-files.$$
        if ! find "$crash_root" -type f -newer "$destination/crash-scan-start" \
                -print >"$crash_files" 2>/dev/null; then
            fail "$label crash-report scan failed"
        fi
        while IFS= read -r report; do
            if grep -Fq "$bundle_id" "$report"; then
                printf '%s\n' "$report"
            fi
        done <"$crash_files" >>"$destination/crash-check.txt"
    done
    [ ! -s "$destination/crash-check.txt" ] || fail "$label produced a crash report"
    {
        echo "# Native Home visual calibration"
        echo
        echo "- Native Home preserves the legacy social, discovery, account, help, guide, developer, and legal hierarchy."
        echo "- UIKit supplies row metrics, fonts, separators, Dynamic Type, and appearance."
        echo "- Six historical Home assets are bundled locally; no Home document or artwork is fetched at runtime."
        echo "- iPad uses a native two-column layout with a typed local recommendation list."
        echo "- Light surface luminance: $light_luminance. Dark surfaces separated: $dark_separated."
        echo "- Dark grouped and cell surfaces are separated by the native cell-background role."
        echo "- Dynamic Type and offline/updating states were captured with the same controller/model tokens."
    } >"$destination/parity-note.md"
}

verify_common_at() {
    verified_common_dir=$1
    [ -d "$verified_common_dir" ] || fail "Home matrix common bundle is absent"
    verify_checksums "$verified_common_dir"
    common_manifest=$verified_common_dir/manifest.txt
    [ -f "$common_manifest" ] || fail "Home matrix common manifest is absent"
    require_manifest_value "$common_manifest" schema 1
    require_manifest_value "$common_manifest" status prepared
    require_manifest_value "$common_manifest" preparation-mode build-only
    require_manifest_value "$common_manifest" source-head "$source_head"
    require_manifest_value "$common_manifest" source-tree "$source_tree"
    require_manifest_value "$common_manifest" developer-dir "$developer_dir"
    require_manifest_value "$common_manifest" xcode-version "$xcode_version"
    require_manifest_value "$common_manifest" xcode-build "$xcode_build"
    require_manifest_value "$common_manifest" xcodebuild-sha256 "$xcodebuild_sha"
    require_manifest_value "$common_manifest" xcrun-path "$xcrun_path"
    require_manifest_value "$common_manifest" xcrun-sha256 "$xcrun_sha"
    require_manifest_value "$common_manifest" build-xcrun-path "$build_xcrun_path"
    require_manifest_value "$common_manifest" build-xcrun-sha256 "$build_xcrun_sha"
    require_manifest_value "$common_manifest" build-xcodebuild-path \
        "$build_xcodebuild_path"
    require_manifest_value "$common_manifest" build-xcodebuild-sha256 \
        "$build_xcodebuild_sha"
    require_manifest_value "$common_manifest" simctl-path "$simctl_path"
    require_manifest_value "$common_manifest" simctl-sha256 "$simctl_sha"
    require_manifest_value "$common_manifest" simulator-compiler-path \
        "$simulator_compiler_path"
    require_manifest_value "$common_manifest" simulator-compiler-sha256 \
        "$simulator_compiler_sha"
    require_manifest_value "$common_manifest" simulator-sdk "$simulator_sdk"
    require_manifest_value "$common_manifest" simulator-sdk-version "$simulator_sdk_version"
    require_manifest_value "$common_manifest" build-jobs 1
    binary_sha=$(manifest_value "$common_manifest" binary-sha256)
    bundle_id=$(manifest_value "$common_manifest" bundle-id)
    bundle_short_version=$(manifest_value "$common_manifest" bundle-short-version)
    bundle_version=$(manifest_value "$common_manifest" bundle-version)
    case "$binary_sha" in
        [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]* ) ;;
        *) fail "common binary SHA-256 is malformed" ;;
    esac
    [ "${#binary_sha}" -eq 64 ] || fail "common binary SHA-256 length changed"
    case "$bundle_id" in com.saurik.Cydia.HomeProbe.h*) ;; *) fail "common bundle ID changed" ;; esac
    probe_app=$verified_common_dir/CydiaHomeProbe.app
    [ -f "$probe_app/Cydia" ] && [ -x "$probe_app/Cydia" ] &&
        [ -f "$probe_app/Info.plist" ] ||
        fail "common Home probe application is incomplete"
    observed_binary_sha=$(shasum -a 256 "$probe_app/Cydia" | awk '{ print $1 }')
    [ "$observed_binary_sha" = "$binary_sha" ] || fail "common binary hash is stale"
    observed_bundle_id=$(plutil -extract CFBundleIdentifier raw -o - "$probe_app/Info.plist")
    [ "$observed_bundle_id" = "$bundle_id" ] || fail "common bundle ID is stale"
    observed_short_version=$(plutil -extract CFBundleShortVersionString raw -o - \
        "$probe_app/Info.plist")
    [ "$observed_short_version" = "$bundle_short_version" ] ||
        fail "common short version is stale"
    observed_bundle_version=$(plutil -extract CFBundleVersion raw -o - \
        "$probe_app/Info.plist")
    [ "$observed_bundle_version" = "$bundle_version" ] ||
        fail "common bundle version is stale"
    preparation_admission=$verified_common_dir/host-admission-prebuild.txt
    [ -f "$preparation_admission" ] ||
        fail "Home matrix preparation admission is absent"
    verify_host_admission "$preparation_admission" preparation prebuild 0
    common_manifest_sha=$(shasum -a 256 "$common_manifest" | awk '{ print $1 }')
    common_checksums_sha=$(shasum -a 256 "$verified_common_dir/SHA256SUMS" |
        awk '{ print $1 }')
}

verify_common() {
    verify_common_at "$common_dir"
}

create_common() {
    [ ! -e "$common_dir" ] || fail "common matrix directory appeared concurrently"
    mkdir "$common_temporary"
    simulator_build_dir=$build_dir/simulator-build
    [ ! -e "$simulator_build_dir" ] ||
        fail "new Home matrix requires an unused simulator build directory"
    if run_bounded_build "$common_build_timeout_seconds" env \
            DEVELOPER_DIR="$developer_dir" MAKEFLAGS= MFLAGS= \
            "$make_program" --no-print-directory \
            -j"$jobs" -C "$source_root" doIA=yes doHomeProbe=yes \
            gxx="$simulator_compiler_path" sdk="$simulator_sdk" \
            BUILD_DIR="$simulator_build_dir" all >"$common_temporary/build.log" 2>&1; then
        :
    else
        build_status=$?
        grep -n -E 'error:|fatal error:|undefined reference|ld:|make: \*\*\*' \
                "$common_temporary/build.log" | head -100 >&2 || true
        if [ "$build_status" -eq 124 ]; then
            fail "simulator Make build timed out after ${common_build_timeout_seconds}s; see $common_temporary/build.log"
        fi
        if [ "$build_status" -eq 125 ]; then
            fail "simulator Make build timed out and descendant cleanup was not proven; inspect host processes before retrying"
        fi
        fail "simulator Make build failed; see $common_temporary/build.log"
    fi
    verify_source_snapshot
    verify_toolchain_snapshot
    probe_app=$common_temporary/CydiaHomeProbe.app
    cp -a "$source_root/MobileCydia.app" "$probe_app"
    cp "$simulator_build_dir/bin/MobileCydia" "$probe_app/Cydia"
    cp "$preparation_admission_file" \
        "$common_temporary/host-admission-prebuild.txt"
    binary_sha=$(shasum -a 256 "$probe_app/Cydia" | awk '{ print $1 }')
    [ "${#binary_sha}" -eq 64 ] || fail "built binary SHA-256 is malformed"
    short_sha=$(printf '%s' "$binary_sha" | cut -c 1-12)
    bundle_id=com.saurik.Cydia.HomeProbe.h$short_sha
    plutil -replace CFBundleIdentifier -string "$bundle_id" "$probe_app/Info.plist"
    plutil -lint "$probe_app/Info.plist" >/dev/null || fail "probe Info.plist is invalid"
    bundle_short_version=$(plutil -extract CFBundleShortVersionString raw -o - \
        "$probe_app/Info.plist")
    bundle_version=$(plutil -extract CFBundleVersion raw -o - "$probe_app/Info.plist")
    {
        echo "schema=1"
        echo "status=prepared"
        echo "preparation-mode=build-only"
        echo "source-head=$source_head"
        echo "source-tree=$source_tree"
        echo "binary-sha256=$binary_sha"
        echo "bundle-id=$bundle_id"
        echo "bundle-short-version=$bundle_short_version"
        echo "bundle-version=$bundle_version"
        echo "developer-dir=$developer_dir"
        echo "xcode-version=$xcode_version"
        echo "xcode-build=$xcode_build"
        echo "xcodebuild-sha256=$xcodebuild_sha"
        echo "xcrun-path=$xcrun_path"
        echo "xcrun-sha256=$xcrun_sha"
        echo "build-xcrun-path=$build_xcrun_path"
        echo "build-xcrun-sha256=$build_xcrun_sha"
        echo "build-xcodebuild-path=$build_xcodebuild_path"
        echo "build-xcodebuild-sha256=$build_xcodebuild_sha"
        echo "simctl-path=$simctl_path"
        echo "simctl-sha256=$simctl_sha"
        echo "simulator-compiler-path=$simulator_compiler_path"
        echo "simulator-compiler-sha256=$simulator_compiler_sha"
        echo "simulator-sdk=$simulator_sdk"
        echo "simulator-sdk-version=$simulator_sdk_version"
        echo "build-jobs=$jobs"
    } >"$common_temporary/manifest.txt"
    write_checksums "$common_temporary"
    verify_common_at "$common_temporary"
    verify_source_snapshot
    verify_toolchain_snapshot
    mv "$common_temporary" "$common_dir"
    common_committed=1
    verify_common
    echo "[verify-home-simulator][ ok ] atomically recorded the prepared shared Home probe"
}

prepare_common() {
    if [ -d "$common_dir" ]; then
        verify_common
        echo "[verify-home-simulator][ ok ] revalidated the exact prepared shared Home probe"
    elif [ -e "$common_dir" ]; then
        fail "Home matrix common preparation is not a directory"
    else
        [ ! -e "$completion_file" ] ||
            fail "cannot prepare a new common for completed Home matrix evidence"
        if [ -e "$cases_dir" ]; then
            [ -d "$cases_dir" ] || fail "Home matrix cases path is not a directory"
            residual_cases=$scratch/residual-cases.$$
            if ! find "$cases_dir" -mindepth 1 -maxdepth 1 -print -quit \
                    >"$residual_cases"; then
                fail "could not inspect residual Home matrix cases"
            fi
            [ ! -s "$residual_cases" ] ||
                fail "cannot prepare a new common beside residual Home matrix cases"
        fi
        create_common
    fi
}

complete_case() {
    cleanup_runtime "$artifact_dir" || fail "$case_name runtime cleanup failed"
    host_admission "$artifact_dir/host-admission-postcleanup.txt"
    load_device_metadata Shutdown
    launchd_sim_absent || fail "$case_name launchd_sim remains after shutdown"
    verify_source_snapshot
    [ ! -s "$artifact_dir/crash-check.txt" ] || fail "$case_name has crash evidence"
    case_manifest=$artifact_dir/case-manifest.txt
    {
        echo "schema=1"
        echo "case=$case_name"
        echo "source-head=$source_head"
        echo "source-tree=$source_tree"
        echo "binary-sha256=$binary_sha"
        echo "bundle-id=$bundle_id"
        echo "common-manifest-sha256=$common_manifest_sha"
        echo "common-checksums-sha256=$common_checksums_sha"
        echo "developer-dir=$developer_dir"
        echo "xcode-version=$xcode_version"
        echo "xcode-build=$xcode_build"
        echo "xcodebuild-sha256=$xcodebuild_sha"
        echo "xcrun-path=$xcrun_path"
        echo "xcrun-sha256=$xcrun_sha"
        echo "build-xcrun-path=$build_xcrun_path"
        echo "build-xcrun-sha256=$build_xcrun_sha"
        echo "build-xcodebuild-path=$build_xcodebuild_path"
        echo "build-xcodebuild-sha256=$build_xcodebuild_sha"
        echo "simctl-path=$simctl_path"
        echo "simctl-sha256=$simctl_sha"
        echo "simulator-compiler-path=$simulator_compiler_path"
        echo "simulator-compiler-sha256=$simulator_compiler_sha"
        echo "simulator-sdk=$simulator_sdk"
        echo "simulator-sdk-version=$simulator_sdk_version"
        echo "simulator-udid=$simulator"
        echo "runtime-version=$expected_runtime"
        echo "runtime-identifier=$actual_runtime_identifier"
        echo "layout=$expected_layout"
        echo "device-family=$expected_device_family"
        echo "device-type=$actual_device_type"
        echo "device-name=$actual_device_name"
        echo "probe-containers-absent=true"
        echo "probe-registration-absent=true"
        echo "simulator-state=Shutdown"
        echo "launchd-sim-absent=true"
        echo "crash-count=0"
    } >"$case_manifest"
    write_checksums "$artifact_dir"
    mv "$artifact_dir" "$case_dir"
    case_committed=1
    echo "[verify-home-simulator][ ok ] $case_name Home evidence: $case_dir"
}

verify_host_admission() {
    admission_file=$1
    admission_case=$2
    admission_phase=$3
    admission_expected_booted=${4:-0}
    case "$admission_expected_booted" in
        0|1) ;;
        *) fail "$admission_case $admission_phase boot-count expectation is invalid" ;;
    esac
    admission_policy_count=$(awk -F= \
        '$1 == "memory-admission-policy" { count++ } END { print count + 0 }' \
        "$admission_file")
    case "$admission_policy_count" in
        0) admission_policy=strict ;;
        1)
            admission_policy=$(awk -F= \
                '$1 == "memory-admission-policy" { print $2 }' "$admission_file")
            case "$admission_policy" in strict|observe) ;; *)
                fail "$admission_case $admission_phase memory policy is invalid"
            esac
            ;;
        *) fail "$admission_case $admission_phase memory policy is ambiguous" ;;
    esac
    admission_free_count=$(awk \
        '/^System-wide memory free percentage: [0-9]+([.][0-9]+)?%$/ { count++ }
         END { print count + 0 }' "$admission_file")
    [ "$admission_free_count" -eq 1 ] ||
        fail "$admission_case $admission_phase memory admission is ambiguous"
    admission_free=$(awk \
        '/^System-wide memory free percentage: [0-9]+([.][0-9]+)?%$/ {
            value = $NF; sub(/%$/, "", value); print value
        }' "$admission_file")
    is_number "$admission_free" &&
        awk -v value="$admission_free" 'BEGIN { exit !(value >= 0 && value <= 100) }' ||
        fail "$admission_case $admission_phase memory admission is invalid"
    if [ "$admission_policy" = strict ]; then
        awk -v value="$admission_free" 'BEGIN { exit !(value >= 40) }' ||
            fail "$admission_case $admission_phase memory admission is invalid"
    fi
    admission_swap_count=$(awk '/^vm[.]swapusage:/ { count++ } END { print count + 0 }' \
        "$admission_file")
    [ "$admission_swap_count" -eq 1 ] ||
        fail "$admission_case $admission_phase swap admission is ambiguous"
    admission_swap_token=$(awk '
        /^vm[.]swapusage:/ {
            for (field = 1; field <= NF; ++field)
                if ($field == "used" && $(field + 1) == "=") {
                    print $(field + 2)
                    exit
                }
        }
    ' "$admission_file")
    case "$admission_swap_token" in *M)
        verified_admission_swap=${admission_swap_token%M} ;; *)
        fail "$admission_case $admission_phase swap admission is malformed" ;; esac
    is_number "$verified_admission_swap" &&
        awk -v value="$verified_admission_swap" 'BEGIN { exit !(value >= 0) }' ||
        fail "$admission_case $admission_phase swap admission is invalid"
    if [ "$admission_policy" = strict ]; then
        awk -v value="$verified_admission_swap" 'BEGIN { exit !(value <= 3072) }' ||
            fail "$admission_case $admission_phase swap admission is invalid"
    fi
    require_manifest_value "$admission_file" booted-simulators "$admission_expected_booted"
    require_manifest_value "$admission_file" expected-booted-simulators \
        "$admission_expected_booted"
    require_manifest_value "$admission_file" competing-processes 0
}

verify_case_semantics() {
    semantic_dir=$1
    semantic_case=$2
    semantic_runtime=$3
    semantic_layout=$4
    if ! /usr/bin/python3 - "$semantic_dir" "$semantic_case" "$semantic_runtime" \
        "$semantic_layout" "$source_head" "$binary_sha" \
            "$bundle_short_version" "$bundle_version" "$bundle_id" <<'PY'
import json
import pathlib
import plistlib
import re
import struct
import sys
import xml.etree.ElementTree as ElementTree
import zlib


class EvidenceError(Exception):
    pass


def evidence_excepthook(exception_type, exception, traceback):
    if exception_type is EvidenceError:
        print(f"semantic evidence error: {exception}", file=sys.stderr)
    else:
        sys.__excepthook__(exception_type, exception, traceback)


sys.excepthook = evidence_excepthook


def reject(message):
    raise EvidenceError(message)


def require_type(value, expected_type, description):
    if type(value) is not expected_type:
        reject(f"{description} has type {type(value).__name__}, expected {expected_type.__name__}")
    return value


def require_value(mapping, key, expected, description):
    if key not in mapping:
        reject(f"{description} is missing {key}")
    value = mapping[key]
    if type(value) is not type(expected) or value != expected:
        reject(f"{description} has {key}={value!r}, expected {expected!r}")


def require_split_disclosures(state, description):
    require_value(state, "splitDisclosureCount", 4, description)
    require_value(state, "splitDisclosuresDecorative", True, description)
    require_value(state, "splitDisclosuresInsideControls", True, description)
    require_value(state, "splitDisclosuresAtTrailingEdge", True, description)
    require_value(state, "splitDisclosureTintSynchronized", True, description)
    require_value(state, "splitDisclosuresSystemOwned", True, description)
    require_value(state, "splitContentLeadingAligned", True, description)


def strict_json_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            reject(f"JSON object repeats key {key!r}")
        result[key] = value
    return result


def reject_json_constant(value):
    reject(f"JSON contains non-finite number {value}")


def same_typed_value(left, right):
    # JSON has one number grammar and Apple's plutil may serialize an integral
    # plist real (for example a 53.0-point row height) as JSON 53. Preserve
    # strict typing for booleans and every nonnumeric value, but compare plist
    # integer/real pairs by their exact numeric value.
    if type(left) in (int, float) and type(right) in (int, float):
        return left == right
    if type(left) is not type(right):
        return False
    if isinstance(left, dict):
        return (left.keys() == right.keys() and
                all(same_typed_value(left[key], right[key]) for key in left))
    if isinstance(left, list):
        return (len(left) == len(right) and
                all(same_typed_value(a, b) for a, b in zip(left, right)))
    return left == right


def load_plist(path):
    try:
        payload = path.read_bytes()
        if not payload.startswith(b"bplist00"):
            document = ElementTree.fromstring(payload)
            for element in document.iter():
                if element.tag.rsplit("}", 1)[-1] != "dict":
                    continue
                children = list(element)
                if len(children) % 2:
                    reject(f"{path.name} contains a malformed XML dictionary")
                keys = set()
                for index in range(0, len(children), 2):
                    key = children[index]
                    if key.tag.rsplit("}", 1)[-1] != "key" or key.text is None:
                        reject(f"{path.name} contains a malformed XML dictionary key")
                    if key.text in keys:
                        reject(f"{path.name} repeats plist key {key.text!r}")
                    keys.add(key.text)
        value = plistlib.loads(payload)
    except EvidenceError:
        raise
    except Exception as error:
        reject(f"{path.name} is not a valid plist: {error}")
    return require_type(value, dict, path.name)


def load_json(path):
    try:
        with path.open("r", encoding="utf-8") as handle:
            value = json.load(handle, object_pairs_hook=strict_json_object,
                              parse_constant=reject_json_constant)
    except EvidenceError:
        raise
    except Exception as error:
        reject(f"{path.name} is not valid JSON: {error}")
    return require_type(value, dict, path.name)


def validate_png(path):
    signature = b"\x89PNG\r\n\x1a\n"
    try:
        handle = path.open("rb")
    except OSError as error:
        reject(f"could not open {path.name}: {error}")
    with handle:
        if handle.read(8) != signature:
            reject(f"{path.name} has an invalid PNG signature")
        chunk_index = 0
        saw_ihdr = False
        saw_idat = False
        ended_idat = False
        saw_plte = False
        dimensions = None
        decompressor = None
        expected_decoded = None
        decoded = 0
        row_stride = None

        def consume_decoded(payload):
            nonlocal decoded
            if decoded + len(payload) > expected_decoded:
                reject(f"{path.name} expands beyond its declared dimensions")
            start = (-decoded) % row_stride
            for index in range(start, len(payload), row_stride):
                if payload[index] > 4:
                    reject(f"{path.name} contains an invalid PNG row filter")
            decoded += len(payload)

        def consume_compressed(payload):
            pending = payload
            while pending:
                try:
                    output = decompressor.decompress(pending, 65536)
                except zlib.error as error:
                    reject(f"{path.name} contains invalid compressed image data: {error}")
                consume_decoded(output)
                pending = decompressor.unconsumed_tail
                if decompressor.unused_data:
                    reject(f"{path.name} contains trailing compressed image data")

        while True:
            header = handle.read(8)
            if len(header) != 8:
                reject(f"{path.name} ended before a complete IEND chunk")
            length, chunk_type = struct.unpack(">I4s", header)
            if length > 0x7fffffff:
                reject(f"{path.name} has an oversized PNG chunk")
            if not all((65 <= byte <= 90) or (97 <= byte <= 122)
                       for byte in chunk_type):
                reject(f"{path.name} has an invalid PNG chunk type")
            if chunk_index == 0 and chunk_type != b"IHDR":
                reject(f"{path.name} does not begin with IHDR")
            if chunk_type == b"IHDR" and saw_ihdr:
                reject(f"{path.name} repeats IHDR")
            if chunk_type == b"IEND" and length != 0:
                reject(f"{path.name} has a non-empty IEND")
            if chunk_type == b"PLTE" and (saw_plte or saw_idat):
                reject(f"{path.name} has an invalid PLTE position")
            if chunk_type not in {b"IHDR", b"PLTE", b"IDAT", b"IEND"} and \
                    65 <= chunk_type[0] <= 90:
                reject(f"{path.name} contains unknown critical chunk "
                       f"{chunk_type.decode('ascii')}")

            checksum = zlib.crc32(chunk_type)
            remaining = length
            retained = bytearray()
            while remaining:
                block = handle.read(min(remaining, 1024 * 1024))
                if not block:
                    reject(f"{path.name} has a truncated {chunk_type.decode('ascii')} chunk")
                checksum = zlib.crc32(block, checksum)
                if chunk_type == b"IHDR":
                    retained.extend(block)
                elif chunk_type == b"IDAT":
                    consume_compressed(block)
                elif chunk_type == b"PLTE":
                    retained.extend(block)
                remaining -= len(block)
            encoded_crc = handle.read(4)
            if len(encoded_crc) != 4:
                reject(f"{path.name} has a truncated PNG CRC")
            observed_crc = struct.unpack(">I", encoded_crc)[0]
            if observed_crc != checksum & 0xffffffff:
                reject(f"{path.name} has a bad {chunk_type.decode('ascii')} CRC")

            if chunk_type == b"IHDR":
                if chunk_index != 0 or length != 13:
                    reject(f"{path.name} has an invalid IHDR")
                width, height, depth, color, compression, filtering, interlace = \
                    struct.unpack(">IIBBBBB", retained)
                valid_depths = {
                    0: {1, 2, 4, 8, 16},
                    2: {8, 16},
                    3: {1, 2, 4, 8},
                    4: {8, 16},
                    6: {8, 16},
                }
                if not (1 <= width <= 16384 and 1 <= height <= 16384 and
                        width * height <= 100000000):
                    reject(f"{path.name} has invalid PNG dimensions {width}x{height}")
                if color not in valid_depths or depth not in valid_depths[color]:
                    reject(f"{path.name} has an invalid PNG color/depth pair")
                if compression != 0 or filtering != 0 or interlace != 0:
                    reject(f"{path.name} has invalid PNG image parameters")
                dimensions = (width, height)
                bits_per_pixel = {0: depth, 2: 3 * depth, 3: depth,
                                  4: 2 * depth, 6: 4 * depth}[color]
                row_stride = 1 + (width * bits_per_pixel + 7) // 8
                expected_decoded = row_stride * height
                decompressor = zlib.decompressobj()
                saw_ihdr = True
            elif chunk_type == b"PLTE":
                if color in (0, 4) or length == 0 or length % 3 or length > 768:
                    reject(f"{path.name} has an invalid PLTE")
                if color == 3 and length // 3 > 1 << depth:
                    reject(f"{path.name} has too many indexed palette entries")
                saw_plte = True
            elif chunk_type == b"IDAT":
                if not saw_ihdr or ended_idat:
                    reject(f"{path.name} has an out-of-order IDAT")
                if color == 3 and not saw_plte:
                    reject(f"{path.name} has indexed image data without PLTE")
                saw_idat = True
            elif saw_idat and chunk_type != b"IEND":
                ended_idat = True

            if chunk_type == b"IEND":
                if not saw_ihdr or not saw_idat:
                    reject(f"{path.name} reached IEND without image data")
                if not decompressor.eof or decoded != expected_decoded:
                    reject(f"{path.name} compressed image data does not match its dimensions")
                if handle.read(1):
                    reject(f"{path.name} has data after IEND")
                return dimensions
            chunk_index += 1


def launch_pid(path, bundle_id):
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except Exception as error:
        reject(f"could not read {path.name}: {error}")
    expression = re.compile(rf"^{re.escape(bundle_id)}: ([1-9][0-9]*)$")
    matches = [int(match.group(1)) for line in lines
               if (match := expression.fullmatch(line))]
    if len(lines) != 1 or len(matches) != 1:
        reject(f"{path.name} must contain exactly one {bundle_id}: PID record")
    return matches[0]


root = pathlib.Path(sys.argv[1])
case_name, runtime, layout = sys.argv[2:5]
source_head, binary_sha, short_version, bundle_version = sys.argv[5:9]
bundle_id = sys.argv[9]

phase_specs = {
    "full-light": ("full", "light", "large"),
    "full-dark": ("full", "dark", "large"),
    "full-dark-accessibility": ("full", "dark", "accessibility-large"),
    "empty-light": ("empty", "light", "large"),
    "offline-dark": ("offline", "dark", "large"),
    "updating-light": ("updating", "light", "large"),
    "refresh": ("updating", "light", "large"),
    "cancel": ("updating", "light", "large"),
    "route-sources": ("updating", "light", "large"),
    "guide": ("updating", "light", "large"),
    "featured": ("updating", "light", "large"),
    "about": ("updating", "light", "large"),
}
if layout == "ipad":
    phase_specs["ipad-package"] = ("updating", "light", "large")
elif layout != "phone":
    reject(f"{case_name} has unknown layout {layout!r}")

lifecycle_specs = {
    "lifecycle-before": ("active", 0, [], "", True, False),
    "lifecycle-background": (
        "background", 2,
        ["UIApplicationWillResignActiveNotification",
         "UIApplicationDidEnterBackgroundNotification"],
        "UIApplicationDidEnterBackgroundNotification", True, False),
    "lifecycle-foreground": (
        "active", 4,
        ["UIApplicationWillResignActiveNotification",
         "UIApplicationDidEnterBackgroundNotification",
         "UIApplicationWillEnterForegroundNotification",
         "UIApplicationDidBecomeActiveNotification"],
        "UIApplicationDidBecomeActiveNotification", False, True),
}

expected_plists = {f"{name}-state.plist" for name in phase_specs}
expected_plists.update(f"{name}-state.plist" for name in lifecycle_specs)
observed_plists = {path.name for path in root.glob("*-state.plist")}
if observed_plists != expected_plists:
    reject(f"{case_name} state plist set differs: "
           f"missing={sorted(expected_plists - observed_plists)!r} "
           f"extra={sorted(observed_plists - expected_plists)!r}")
expected_json = {f"{name}-ui-tree.json" for name in phase_specs}
observed_json = {path.name for path in root.glob("*-ui-tree.json")}
if observed_json != expected_json:
    reject(f"{case_name} UI-tree JSON set differs: "
           f"missing={sorted(expected_json - observed_json)!r} "
           f"extra={sorted(observed_json - expected_json)!r}")
expected_png = {f"{name}.png" for name in phase_specs}
expected_png.add("lifecycle-foreground.png")
observed_png = {path.name for path in root.glob("*.png")}
if observed_png != expected_png:
    reject(f"{case_name} PNG set differs: missing={sorted(expected_png - observed_png)!r} "
           f"extra={sorted(observed_png - expected_png)!r}")

states = {}
common_pid = launch_pid(root / "launch.log", bundle_id)
if launch_pid(root / "foreground-launch.log", bundle_id) != common_pid:
    reject(f"{case_name} foreground PID differs from initial launch")
for name, (phase, style, content_size) in phase_specs.items():
    path = root / f"{name}-state.plist"
    state = load_plist(path)
    states[name] = state
    require_value(state, "schema", 1, path.name)
    require_value(state, "fixtureVersion", "native-home-legacy-hierarchy-v2", path.name)
    require_value(state, "ready", True, path.name)
    require_value(state, "systemVersion", runtime, path.name)
    require_value(state, "phase", phase, path.name)
    require_value(state, "style", style, path.name)
    require_value(state, "contentSize", content_size, path.name)
    require_value(state, "controllerClass", "CydiaHomeProbeController", path.name)
    require_value(state, "navigationURL", "cydia://home", path.name)
    require_split_disclosures(state, path.name)
    evidence = require_type(state.get("buildEvidence"), dict,
                            f"{path.name} buildEvidence")
    require_value(evidence, "sourceHEAD", source_head, f"{path.name} buildEvidence")
    require_value(evidence, "binarySHA256", binary_sha, f"{path.name} buildEvidence")
    require_value(evidence, "bundleShortVersion", short_version,
                  f"{path.name} buildEvidence")
    require_value(evidence, "bundleVersion", bundle_version,
                  f"{path.name} buildEvidence")
    pid = require_type(state.get("processID"), int, f"{path.name} processID")
    if pid <= 0:
        reject(f"{path.name} processID is not positive")
    if pid != common_pid:
        reject(f"{path.name} processID {pid} differs from {common_pid}")
    tree = load_json(root / f"{name}-ui-tree.json")
    if not same_typed_value(state, tree):
        reject(f"{name} UI-tree JSON does not equal its state plist")

for name, (application_state, notification_count, notifications,
           last_notification, lifecycle_armed, lifecycle_complete) in \
        lifecycle_specs.items():
    path = root / f"{name}-state.plist"
    state = load_plist(path)
    require_value(state, "schema", 1, path.name)
    require_value(state, "fixtureVersion", "native-home-legacy-hierarchy-v2", path.name)
    require_value(state, "ready", True, path.name)
    require_value(state, "systemVersion", runtime, path.name)
    require_value(state, "phase", "updating", path.name)
    require_value(state, "style", "light", path.name)
    require_value(state, "contentSize", "large", path.name)
    require_value(state, "processID", common_pid, path.name)
    require_value(state, "controllerClass", "CydiaHomeProbeController", path.name)
    require_value(state, "navigationURL", "cydia://home", path.name)
    require_split_disclosures(state, path.name)
    require_value(state, "lifecycleArmed", lifecycle_armed, path.name)
    require_value(state, "lifecycleComplete", lifecycle_complete, path.name)
    require_value(state, "applicationState", application_state, path.name)
    require_value(state, "lifecycleNotificationCount", notification_count, path.name)
    require_value(state, "lifecycleNotifications", notifications, path.name)
    require_value(state, "lastLifecycleNotification", last_notification, path.name)
    require_value(state, "appCacheRequestCount", 0, path.name)
    require_value(state, "unexpectedRemoteHomeRequestCount", 0, path.name)
    evidence = require_type(state.get("buildEvidence"), dict,
                            f"{path.name} buildEvidence")
    require_value(evidence, "sourceHEAD", source_head, f"{path.name} buildEvidence")
    require_value(evidence, "binarySHA256", binary_sha, f"{path.name} buildEvidence")
    require_value(evidence, "bundleShortVersion", short_version,
                  f"{path.name} buildEvidence")
    require_value(evidence, "bundleVersion", bundle_version,
                  f"{path.name} buildEvidence")

dimensions = None
for png_name in sorted(expected_png):
    current_dimensions = validate_png(root / png_name)
    if dimensions is None:
        dimensions = current_dimensions
    elif current_dimensions != dimensions:
        reject(f"{png_name} dimensions {current_dimensions} differ from {dimensions}")
PY
    then
        fail "$semantic_case semantic Home evidence is invalid"
    fi
}

verify_case() {
    verified_case=$1
    verified_runtime=$2
    verified_runtime_identifier=$3
    verified_layout=$4
    verified_family=$5
    verified_dir=$cases_dir/$verified_case
    [ -d "$verified_dir" ] || fail "Home matrix case is absent: $verified_case"
    verify_checksums "$verified_dir"
    for required in provenance.txt launch.log foreground-launch.log \
            crash-scan-start crash-check.txt cleanup.log \
            shutdown.log host-admission-initial.txt host-admission-preboot.txt \
            host-admission-postboot.txt \
            host-admission-postcleanup.txt \
            lifecycle-before-state.plist lifecycle-background-state.plist \
            lifecycle-foreground-state.plist lifecycle-foreground.png \
            parity-note.md; do
        [ -f "$verified_dir/$required" ] ||
            fail "$verified_case is missing required evidence: $required"
    done
    for phase in full-light full-dark full-dark-accessibility empty-light \
            offline-dark updating-light refresh cancel route-sources guide featured about; do
        for evidence in "$phase.png" "$phase-state.plist" "$phase-ui-tree.json"; do
            [ -f "$verified_dir/$evidence" ] ||
                fail "$verified_case is missing required evidence: $evidence"
        done
    done
    verify_host_admission "$verified_dir/host-admission-initial.txt" \
        "$verified_case" initial
    verified_initial_swap=$verified_admission_swap
    verify_host_admission "$verified_dir/host-admission-preboot.txt" \
        "$verified_case" preboot
    if [ "$admission_policy" = strict ]; then
        awk -v initial="$verified_initial_swap" -v current="$verified_admission_swap" \
            'BEGIN { exit !(current - initial <= 128) }' ||
            fail "$verified_case preboot swap growth exceeded its admission"
    fi
    verify_host_admission "$verified_dir/host-admission-postboot.txt" \
        "$verified_case" postboot 1
    if [ "$admission_policy" = strict ]; then
        awk -v initial="$verified_initial_swap" -v current="$verified_admission_swap" \
            'BEGIN { exit !(current - initial <= 128) }' ||
            fail "$verified_case postboot swap growth exceeded its admission"
    fi
    verify_host_admission "$verified_dir/host-admission-postcleanup.txt" \
        "$verified_case" postcleanup
    if [ "$admission_policy" = strict ]; then
        awk -v initial="$verified_initial_swap" -v current="$verified_admission_swap" \
            'BEGIN { exit !(current - initial <= 128) }' ||
            fail "$verified_case postcleanup swap growth exceeded its admission"
    fi
    [ ! -s "$verified_dir/crash-check.txt" ] ||
        fail "$verified_case crash-check evidence is not empty"
    grep -Fxq 'probe-containers-absent=true' "$verified_dir/cleanup.log" ||
        fail "$verified_case cleanup did not prove container removal"
    grep -Fxq 'probe-registration-absent=true' "$verified_dir/cleanup.log" ||
        fail "$verified_case cleanup did not prove registration removal"
    grep -Fxq 'simulator-state=Shutdown' "$verified_dir/cleanup.log" ||
        fail "$verified_case cleanup did not prove shutdown"
    grep -Fxq 'launchd-sim-absent=true' "$verified_dir/cleanup.log" ||
        fail "$verified_case cleanup did not prove launchd_sim removal"
    if [ "$verified_case" = ios12-ipad ]; then
        for evidence in ipad-package.png ipad-package-state.plist \
                ipad-package-ui-tree.json; do
            [ -f "$verified_dir/$evidence" ] ||
                fail "$verified_case is missing its package-route evidence: $evidence"
        done
    else
        for evidence in ipad-package.png ipad-package-state.plist \
                ipad-package-ui-tree.json; do
            [ ! -e "$verified_dir/$evidence" ] ||
                fail "$verified_case unexpectedly contains iPad-only evidence: $evidence"
        done
    fi
    verified_manifest=$verified_dir/case-manifest.txt
    [ -f "$verified_manifest" ] || fail "$verified_case manifest is absent"
    require_manifest_value "$verified_manifest" schema 1
    require_manifest_value "$verified_manifest" case "$verified_case"
    require_manifest_value "$verified_manifest" source-head "$source_head"
    require_manifest_value "$verified_manifest" source-tree "$source_tree"
    require_manifest_value "$verified_manifest" binary-sha256 "$binary_sha"
    require_manifest_value "$verified_manifest" bundle-id "$bundle_id"
    require_manifest_value "$verified_manifest" common-manifest-sha256 "$common_manifest_sha"
    require_manifest_value "$verified_manifest" common-checksums-sha256 "$common_checksums_sha"
    require_manifest_value "$verified_manifest" developer-dir "$developer_dir"
    require_manifest_value "$verified_manifest" xcode-version "$xcode_version"
    require_manifest_value "$verified_manifest" xcode-build "$xcode_build"
    require_manifest_value "$verified_manifest" xcodebuild-sha256 "$xcodebuild_sha"
    require_manifest_value "$verified_manifest" xcrun-path "$xcrun_path"
    require_manifest_value "$verified_manifest" xcrun-sha256 "$xcrun_sha"
    require_manifest_value "$verified_manifest" build-xcrun-path "$build_xcrun_path"
    require_manifest_value "$verified_manifest" build-xcrun-sha256 "$build_xcrun_sha"
    require_manifest_value "$verified_manifest" build-xcodebuild-path \
        "$build_xcodebuild_path"
    require_manifest_value "$verified_manifest" build-xcodebuild-sha256 \
        "$build_xcodebuild_sha"
    require_manifest_value "$verified_manifest" simctl-path "$simctl_path"
    require_manifest_value "$verified_manifest" simctl-sha256 "$simctl_sha"
    require_manifest_value "$verified_manifest" simulator-compiler-path \
        "$simulator_compiler_path"
    require_manifest_value "$verified_manifest" simulator-compiler-sha256 \
        "$simulator_compiler_sha"
    require_manifest_value "$verified_manifest" simulator-sdk "$simulator_sdk"
    require_manifest_value "$verified_manifest" simulator-sdk-version "$simulator_sdk_version"
    require_manifest_value "$verified_manifest" runtime-version "$verified_runtime"
    require_manifest_value "$verified_manifest" runtime-identifier "$verified_runtime_identifier"
    require_manifest_value "$verified_manifest" layout "$verified_layout"
    require_manifest_value "$verified_manifest" device-family "$verified_family"
    require_manifest_value "$verified_manifest" probe-containers-absent true
    require_manifest_value "$verified_manifest" probe-registration-absent true
    require_manifest_value "$verified_manifest" simulator-state Shutdown
    require_manifest_value "$verified_manifest" launchd-sim-absent true
    require_manifest_value "$verified_manifest" crash-count 0
    verified_udid=$(manifest_value "$verified_manifest" simulator-udid)
    case "$verified_udid" in ????????-????-????-????-????????????) ;; *)
        fail "$verified_case UDID is malformed" ;; esac
    verified_type=$(manifest_value "$verified_manifest" device-type)
    case "$verified_family:$verified_type" in
        iPhone:com.apple.CoreSimulator.SimDeviceType.iPhone-*) ;;
        iPad:com.apple.CoreSimulator.SimDeviceType.iPad-*) ;;
        *) fail "$verified_case device type is inconsistent: $verified_type" ;;
    esac
    verified_name=$(manifest_value "$verified_manifest" device-name)
    provenance=$verified_dir/provenance.txt
    require_manifest_value "$provenance" source-head "$source_head"
    require_manifest_value "$provenance" source-tree "$source_tree"
    require_manifest_value "$provenance" binary-sha256 "$binary_sha"
    require_manifest_value "$provenance" installed-binary-sha256 "$binary_sha"
    require_manifest_value "$provenance" bundle-id "$bundle_id"
    require_manifest_value "$provenance" bundle-short-version "$bundle_short_version"
    require_manifest_value "$provenance" bundle-version "$bundle_version"
    require_manifest_value "$provenance" developer-dir "$developer_dir"
    require_manifest_value "$provenance" xcode-version "$xcode_version"
    require_manifest_value "$provenance" xcode-build "$xcode_build"
    require_manifest_value "$provenance" xcodebuild-sha256 "$xcodebuild_sha"
    require_manifest_value "$provenance" xcrun-path "$xcrun_path"
    require_manifest_value "$provenance" xcrun-sha256 "$xcrun_sha"
    require_manifest_value "$provenance" build-xcrun-path "$build_xcrun_path"
    require_manifest_value "$provenance" build-xcrun-sha256 "$build_xcrun_sha"
    require_manifest_value "$provenance" build-xcodebuild-path \
        "$build_xcodebuild_path"
    require_manifest_value "$provenance" build-xcodebuild-sha256 \
        "$build_xcodebuild_sha"
    require_manifest_value "$provenance" simctl-path "$simctl_path"
    require_manifest_value "$provenance" simctl-sha256 "$simctl_sha"
    require_manifest_value "$provenance" simulator-compiler-path \
        "$simulator_compiler_path"
    require_manifest_value "$provenance" simulator-compiler-sha256 \
        "$simulator_compiler_sha"
    require_manifest_value "$provenance" simulator-sdk "$simulator_sdk"
    require_manifest_value "$provenance" simulator-sdk-version "$simulator_sdk_version"
    require_manifest_value "$provenance" simulator-udid "$verified_udid"
    require_manifest_value "$provenance" runtime-identifier "$verified_runtime_identifier"
    require_manifest_value "$provenance" device-type "$verified_type"
    require_manifest_value "$provenance" device-name "$verified_name"
    verify_case_semantics "$verified_dir" "$verified_case" "$verified_runtime" \
        "$verified_layout"
    verified_case_sha=$(shasum -a 256 "$verified_dir/SHA256SUMS" | awk '{ print $1 }')
}

json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

validate_json() {
    /usr/bin/python3 - "$1" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as handle:
    json.load(handle)
PY
}

finalize_matrix() {
    verify_common
    partial_entries=$scratch/partial-entries
    if ! find "$matrix_root" -mindepth 1 -maxdepth 1 \
            -name '.matrix-complete.json.tmp.*' \
            -print -quit >"$partial_entries"; then
        fail "could not inspect Home matrix partial manifests"
    fi
    if [ -s "$partial_entries" ]; then
        fail "Home matrix contains a stale partial manifest"
    fi
    actual_cases=$scratch/actual-cases
    expected_cases=$scratch/expected-cases
    actual_cases_unsorted=$scratch/actual-cases-unsorted
    if ! find "$cases_dir" -mindepth 1 -maxdepth 1 -exec basename {} \; \
            >"$actual_cases_unsorted"; then
        fail "could not enumerate Home matrix cases"
    fi
    if ! LC_ALL=C sort "$actual_cases_unsorted" >"$actual_cases"; then
        fail "could not sort Home matrix cases"
    fi
    expected_cases_unsorted=$scratch/expected-cases-unsorted
    printf '%s\n' ios12-ipad ios12-phone ios15-phone >"$expected_cases_unsorted"
    if ! LC_ALL=C sort "$expected_cases_unsorted" >"$expected_cases"; then
        fail "could not sort expected Home matrix cases"
    fi
    cmp -s "$actual_cases" "$expected_cases" ||
        fail "Home matrix must contain exactly the three named cases"

    verify_case ios12-phone 12.0 \
        com.apple.CoreSimulator.SimRuntime.iOS-12-0-SyntheticSimulatorFixture phone iPhone
    ios12_phone_udid=$verified_udid
    ios12_phone_sha=$verified_case_sha
    verify_case ios15-phone 15.5 \
        com.apple.CoreSimulator.SimRuntime.iOS-15-5 phone iPhone
    ios15_phone_udid=$verified_udid
    ios15_phone_sha=$verified_case_sha
    verify_case ios12-ipad 12.0 \
        com.apple.CoreSimulator.SimRuntime.iOS-12-0-SyntheticSimulatorFixture ipad iPad
    ios12_ipad_udid=$verified_udid
    ios12_ipad_sha=$verified_case_sha
    [ "$ios12_phone_udid" != "$ios15_phone_udid" ] &&
        [ "$ios12_phone_udid" != "$ios12_ipad_udid" ] &&
        [ "$ios15_phone_udid" != "$ios12_ipad_udid" ] ||
        fail "Home matrix cases do not use three distinct simulators"

    escaped_developer=$(json_escape "$developer_dir")
    {
        echo '{'
        echo '  "schema": 1,'
        echo '  "status": "complete",'
        echo "  \"sourceHEAD\": \"$source_head\","
        echo "  \"sourceTree\": \"$source_tree\","
        echo "  \"binarySHA256\": \"$binary_sha\","
        echo "  \"bundleIdentifier\": \"$bundle_id\","
        echo "  \"developerDir\": \"$escaped_developer\","
        echo "  \"xcodeVersion\": \"$xcode_version\","
        echo "  \"xcodeBuild\": \"$xcode_build\","
        echo "  \"xcodebuildSHA256\": \"$xcodebuild_sha\","
        echo "  \"xcrunPath\": \"$(json_escape "$xcrun_path")\","
        echo "  \"xcrunSHA256\": \"$xcrun_sha\","
        echo "  \"buildXcrunPath\": \"$(json_escape "$build_xcrun_path")\","
        echo "  \"buildXcrunSHA256\": \"$build_xcrun_sha\","
        echo "  \"buildXcodebuildPath\": \"$(json_escape "$build_xcodebuild_path")\","
        echo "  \"buildXcodebuildSHA256\": \"$build_xcodebuild_sha\","
        echo "  \"simctlPath\": \"$(json_escape "$simctl_path")\","
        echo "  \"simctlSHA256\": \"$simctl_sha\","
        echo "  \"simulatorCompilerPath\": \"$(json_escape "$simulator_compiler_path")\","
        echo "  \"simulatorCompilerSHA256\": \"$simulator_compiler_sha\","
        echo "  \"simulatorSDK\": \"$(json_escape "$simulator_sdk")\","
        echo "  \"simulatorSDKVersion\": \"$simulator_sdk_version\","
        echo "  \"commonManifestSHA256\": \"$common_manifest_sha\","
        echo "  \"commonChecksumsSHA256\": \"$common_checksums_sha\","
        echo '  "cases": {'
        echo "    \"ios12-phone\": {\"udid\": \"$ios12_phone_udid\", \"runtime\": \"12.0\", \"layout\": \"phone\", \"evidenceSHA256\": \"$ios12_phone_sha\"},"
        echo "    \"ios15-phone\": {\"udid\": \"$ios15_phone_udid\", \"runtime\": \"15.5\", \"layout\": \"phone\", \"evidenceSHA256\": \"$ios15_phone_sha\"},"
        echo "    \"ios12-ipad\": {\"udid\": \"$ios12_ipad_udid\", \"runtime\": \"12.0\", \"layout\": \"ipad\", \"evidenceSHA256\": \"$ios12_ipad_sha\"}"
        echo '  }'
        echo '}'
    } >"$completion_temporary"
    validate_json "$completion_temporary" || fail "matrix completion JSON is invalid"
    if [ -e "$completion_file" ]; then
        cmp -s "$completion_temporary" "$completion_file" ||
            fail "existing matrix completion does not match current evidence"
        rm -f -- "$completion_temporary"
        echo "[verify-home-simulator][ ok ] existing Home matrix completion revalidated"
    else
        mv "$completion_temporary" "$completion_file"
        echo "[verify-home-simulator][ ok ] atomically completed the Home simulator matrix"
    fi
}

source_head=$(git -C "$source_root" rev-parse HEAD)
source_tree=$(git -C "$source_root" rev-parse 'HEAD^{tree}')
verify_source_snapshot
validate_toolchain
reject_partial_preparation

if [ "$mode" = finalize ]; then
    finalize_matrix
    exit 0
fi

if [ "$mode" = prepare ]; then
    host_admission "$preparation_admission_file"
    prepare_common
    echo "[verify-home-simulator][preparation] $common_dir"
    exit 0
fi

[ -d "$common_dir" ] ||
    fail "Home matrix preparation is absent; run --prepare first"
verify_common
echo "[verify-home-simulator][ ok ] reused the exact prepared shared Home probe"
[ ! -e "$completion_file" ] || fail "Home matrix is already complete"
[ ! -e "$case_dir" ] || fail "Home matrix case already exists: $case_name"
[ ! -e "$cases_dir" ] || [ -d "$cases_dir" ] ||
    fail "Home matrix cases path is not a directory"
mkdir -p "$cases_dir"
mkdir "$case_temporary"
host_admission "$case_temporary/host-admission-initial.txt"
load_device_metadata Shutdown
host_admission "$case_temporary/host-admission-preboot.txt"
load_device_metadata Shutdown
shutdown_required=1
simctl 30 boot "$simulator" >"$case_temporary/boot.log" 2>&1 ||
    fail "could not boot only $case_name"
simctl 120 bootstatus "$simulator" -b >>"$case_temporary/boot.log" 2>&1 ||
    fail "$case_name did not finish booting"
load_device_metadata Booted
host_admission "$case_temporary/host-admission-postboot.txt" 1
run_probe
complete_case

echo "[verify-home-simulator][evidence] $case_dir"
