#!/bin/sh
# Offline contracts for the OOM-safe native Home simulator matrix.

set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
temporary=$(mktemp -d "${TMPDIR:-/tmp}/cydia-home-matrix-tests.XXXXXX")
trap 'rm -rf -- "$temporary"' EXIT HUP INT TERM

fail() {
    echo "[verify-home-matrix-contract][FAIL] $*" >&2
    exit 1
}

pass() {
    echo "[verify-home-matrix-contract][ ok ] $*"
}

tool_log=$temporary/tool.log
host_xcrun=$temporary/host/usr/bin/xcrun
host_xcodebuild=$temporary/host/usr/bin/xcodebuild
xcrun_escape_marker=$temporary/xcrun-escape
mkdir -p "$(dirname "$host_xcrun")"
cat >"$host_xcrun" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>'$tool_log'
case "\$*" in
    '--find simctl')
        if [ -e '$xcrun_escape_marker' ]; then
            echo '/usr/bin/simctl'
        else
            echo "\${DEVELOPER_DIR:?}/usr/bin/simctl"
        fi
        ;;
    'simctl list devices -j') printf '%s\n' '{"devices":{}}' ;;
    '--sdk iphonesimulator -f g++') echo "\${DEVELOPER_DIR:?}/usr/bin/g++" ;;
    *) exit 97 ;;
esac
EOF
cat >"$host_xcodebuild" <<'EOF'
#!/bin/sh
exec "${DEVELOPER_DIR:?}/usr/bin/xcodebuild" "$@"
EOF
chmod +x "$host_xcrun" "$host_xcodebuild"

write_checksums() {
    directory=$1
    checksum_find=$temporary/checksum-find.$$
    checksum_list=$temporary/checksum-list.$$
    checksum_output=$directory/.SHA256SUMS.tmp.$$
    (cd "$directory" && find . -type f ! -name SHA256SUMS -print \
        >"$checksum_find") || fail "fixture file scan failed"
    LC_ALL=C sort "$checksum_find" >"$checksum_list" ||
        fail "fixture file sort failed"
    if ! (
        cd "$directory" || exit 1
        while IFS= read -r file; do
            shasum -a 256 "$file" || exit 1
        done <"$checksum_list"
    ) >"$checksum_output"; then
        fail "fixture checksum generation failed"
    fi
    mv "$checksum_output" "$directory/SHA256SUMS"
}

repo=$temporary/repo
mkdir -p "$repo/scripts" "$repo/MobileCydia.app"
grep -Fq 'assert_number "$state" statusFrameHeight le 0' \
    "$root/scripts/verify-home-simulator.sh" ||
    fail "Home runner compares hidden status geometry as text instead of a number"
grep -Fxq 'xcrun_path=/usr/bin/xcrun' \
    "$root/scripts/verify-home-simulator.sh" ||
    fail "production Home runner does not pin host /usr/bin/xcrun"
grep -Fxq 'build_xcodebuild_path=/usr/bin/xcodebuild' \
    "$root/scripts/verify-home-simulator.sh" ||
    fail "production Home runner does not pin build /usr/bin/xcodebuild"
sed -e "s|^xcrun_path=/usr/bin/xcrun$|xcrun_path=$host_xcrun|" \
    -e "s|^build_xcodebuild_path=/usr/bin/xcodebuild$|build_xcodebuild_path=$host_xcodebuild|" \
    "$root/scripts/verify-home-simulator.sh" \
    >"$repo/scripts/verify-home-simulator.sh"
grep -Fxq "xcrun_path=$host_xcrun" \
    "$repo/scripts/verify-home-simulator.sh" ||
    fail "offline runner did not substitute its synthetic host xcrun"
grep -Fxq "build_xcodebuild_path=$host_xcodebuild" \
    "$repo/scripts/verify-home-simulator.sh" ||
    fail "offline runner did not substitute its synthetic build xcodebuild"
chmod +x "$repo/scripts/verify-home-simulator.sh"
cat >"$repo/MobileCydia.app/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.saurik.Cydia</string>
<key>CFBundleShortVersionString</key><string>1.1.36</string>
<key>CFBundleVersion</key><string>1</string>
</dict></plist>
EOF
printf 'offline payload asset\n' >"$repo/MobileCydia.app/payload.txt"
git -C "$repo" init -q
git -C "$repo" add scripts/verify-home-simulator.sh MobileCydia.app
git -C "$repo" -c user.name='Cydia Tests' -c user.email='tests@example.invalid' \
    -c commit.gpgsign=false \
    commit -qm 'fixture script'
source_head=$(git -C "$repo" rev-parse HEAD)
source_tree=$(git -C "$repo" rev-parse 'HEAD^{tree}')

bounded_functions=$temporary/bounded-functions.sh
awk '
    /^run_with_timeout\(\)/ { copy = 1 }
    /^simctl\(\)/ { copy = 0 }
    copy { print }
' "$repo/scripts/verify-home-simulator.sh" >"$bounded_functions" ||
    fail "could not extract bounded process helpers"
sh -n "$bounded_functions" || fail "bounded process helpers are not valid shell"
bounded_child_pid=$temporary/bounded-child.pid
bounded_guard_fired=$temporary/bounded-guard-fired
(
    scratch=$temporary/bounded-scratch
    mkdir "$scratch"
    active_build_pid=
    build_watchdog_pid=
    build_timeout_marker=
    build_cleanup_failure_marker=
    active_command_pid=
    command_watchdog_pid=
    command_timeout_marker=
    command_cleanup_failure_marker=
    fake_ps_failure=0
    ps() {
        [ "$fake_ps_failure" -eq 0 ] || return 71
        [ "$*" = '-axo pid=,ppid=' ] || return 72
        printf '%s 1\n' "$tree_root_pid"
        if [ -s "$bounded_child_pid" ]; then
            child=$(cat "$bounded_child_pid") || return 73
            printf '%s %s\n' "$child" "$tree_root_pid"
        fi
    }
    fake_hanging_build() {
        sleep 60 &
        child=$!
        printf '%s\n' "$child" >"$bounded_child_pid"
        wait "$child"
    }
    capture_hanging_output() {
        run_with_timeout 60 fake_hanging_build >"$scratch/captured-command-output"
    }
    . "$bounded_functions"
    if run_bounded_build 1 fake_hanging_build; then
        exit 1
    else
        build_status=$?
    fi
    [ "$build_status" -eq 124 ] || exit 1
    [ -s "$bounded_child_pid" ] || exit 1
    child=$(cat "$bounded_child_pid") || exit 1
    attempts=0
    while kill -0 "$child" 2>/dev/null && [ "$attempts" -lt 20 ]; do
        attempts=$((attempts + 1))
        sleep 0.1
    done
    if kill -0 "$child" 2>/dev/null; then
        kill -KILL "$child" 2>/dev/null || true
        exit 1
    fi
    : >"$bounded_child_pid"
    if run_with_timeout 1 fake_hanging_build; then
        exit 1
    else
        command_status=$?
    fi
    [ "$command_status" -eq 124 ] || exit 1
    [ -s "$bounded_child_pid" ] || exit 1
    child=$(cat "$bounded_child_pid") || exit 1
    attempts=0
    while kill -0 "$child" 2>/dev/null && [ "$attempts" -lt 20 ]; do
        attempts=$((attempts + 1))
        sleep 0.1
    done
    if kill -0 "$child" 2>/dev/null; then
        kill -KILL "$child" 2>/dev/null || true
        exit 1
    fi
    : >"$bounded_child_pid"
    fake_ps_failure=1
    if run_bounded_build 1 fake_hanging_build; then
        exit 1
    else
        failed_build_status=$?
    fi
    [ "$failed_build_status" -eq 125 ] || exit 1
    [ -s "$bounded_child_pid" ] || exit 1
    child=$(cat "$bounded_child_pid") || exit 1
    kill -KILL "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
    fake_ps_failure=0
    : >"$bounded_child_pid"
    (
        trap 'cleanup_tracked_processes; exit 143' TERM
        capture_hanging_output
    ) &
    interrupted_runner=$!
    attempts=0
    while [ ! -s "$bounded_child_pid" ] && [ "$attempts" -lt 20 ]; do
        attempts=$((attempts + 1))
        sleep 0.1
    done
    [ -s "$bounded_child_pid" ] || exit 1
    interrupted_child=$(cat "$bounded_child_pid") || exit 1
    kill -TERM "$interrupted_runner" 2>/dev/null || exit 1
    if wait "$interrupted_runner"; then
        exit 1
    else
        interrupted_status=$?
    fi
    [ "$interrupted_status" -eq 143 ] || exit 1
    attempts=0
    while kill -0 "$interrupted_child" 2>/dev/null && [ "$attempts" -lt 20 ]; do
        attempts=$((attempts + 1))
        sleep 0.1
    done
    if kill -0 "$interrupted_child" 2>/dev/null; then
        kill -KILL "$interrupted_child" 2>/dev/null || true
        exit 1
    fi
) &
bounded_contract_pid=$!
(
    sleep 15
    if kill -0 "$bounded_contract_pid" 2>/dev/null; then
        : >"$bounded_guard_fired"
        kill -TERM "$bounded_contract_pid" 2>/dev/null || true
        if [ -s "$bounded_child_pid" ]; then
            child=$(cat "$bounded_child_pid" 2>/dev/null || true)
            case "$child" in *[!0-9]*|'') ;; *) kill -KILL "$child" 2>/dev/null || true ;; esac
        fi
    fi
) &
bounded_guard_pid=$!
if wait "$bounded_contract_pid"; then
    bounded_contract_status=0
else
    bounded_contract_status=$?
fi
kill "$bounded_guard_pid" 2>/dev/null || true
wait "$bounded_guard_pid" 2>/dev/null || true
[ ! -e "$bounded_guard_fired" ] || fail "bounded process contract exceeded fifteen seconds"
[ "$bounded_contract_status" -eq 0 ] || fail "bounded build or ps failure contract failed"
pass "bounded build and command timeouts kill descendants and failed ps stays closed"

capture_functions=$temporary/capture-functions.sh
awk '
    /^capture_phase\(\)/ { copy = 1 }
    /^verify_base\(\)/ { copy = 0 }
    copy { print }
' "$repo/scripts/verify-home-simulator.sh" >"$capture_functions" ||
    fail "could not extract Home capture helper"
sh -n "$capture_functions" || fail "Home capture helper is not valid shell"
(
    capture_root=$temporary/capture-ready
    mkdir "$capture_root"
    capture_live=$capture_root/live.plist
    capture_destination=$capture_root/evidence
    mkdir "$capture_destination"
    write_capture_state() {
        capture_ready=$1
        capture_output=$capture_root/live.tmp
        if [ "$capture_ready" = true ]; then
            ready_element='<true/>'
        else
            ready_element='<false/>'
        fi
        cat >"$capture_output" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>ready</key>$ready_element</dict></plist>
EOF
        mv "$capture_output" "$capture_live"
    }
    read_state() {
        plutil -extract "$2" raw -o - "$1" 2>/dev/null
    }
    fail() {
        echo "$*" >&2
        exit 1
    }
    simctl() {
        [ "$1" = 30 ] && [ "$2" = io ] && [ "$4" = screenshot ] || exit 91
        : >"$5"
    }
    . "$capture_functions"
    write_capture_state false
    (sleep 0.3; write_capture_state true) &
    capture_writer=$!
    capture_phase "$capture_live" "$capture_destination" settled fixture-simulator
    wait "$capture_writer"
    [ "$(plutil -extract ready raw -o - \
        "$capture_destination/settled-state.plist")" = true ] || exit 1
    [ -s "$capture_destination/settled-ui-tree.json" ] || exit 1
    [ -f "$capture_destination/settled.png" ] || exit 1
) || fail "Home capture helper did not wait for a stable ready snapshot"
pass "phase capture snapshots a parseable settled state before JSON and PNG"

process_parser=$temporary/simulator-process-parser.sh
awk '
    /^simulator_process_pids\(\)/ { copy = 1 }
    /^launchd_sim_absent\(\)/ { copy = 0 }
    copy { print }
' "$repo/scripts/verify-home-simulator.sh" >"$process_parser" ||
    fail "could not extract the simulator process parser"
sh -n "$process_parser" || fail "simulator process parser is not valid shell"
process_snapshot=$temporary/simulator-processes.txt
cat >"$process_snapshot" <<'EOF'
701 44 launchd_sim /Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 12.0.simruntime/Contents/Resources/RuntimeRoot/bin/launchd_sim -d AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA
702 701 lsd /usr/libexec/lsd
703 701 lsd /usr/libexec/lsd
704 44 launchd_sim /Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 15.5.simruntime/Contents/Resources/RuntimeRoot/bin/launchd_sim -d BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB
EOF
(
    . "$process_parser"
    [ "$(simulator_process_pids "$process_snapshot" launchd_sim \
        AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA)" = 701 ] || exit 1
    [ "$(simulator_process_pids "$process_snapshot" lsd "" 701 702)" = 703 ] ||
        exit 1
    [ -z "$(simulator_process_pids "$process_snapshot" launchd_sim \
        CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC)" ] || exit 1
) || fail "full-path simulator process matching is not exact"
printf 'malformed process snapshot\n' >"$process_snapshot"
(
    . "$process_parser"
    if simulator_process_pids "$process_snapshot" launchd_sim \
            AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA >/dev/null; then
        exit 1
    fi
) || fail "malformed simulator process snapshot was accepted"
pass "simulator process matching handles full paths and fails closed"
grep -Fq 'ps -axo pid=,ucomm=,command=' \
    "$repo/scripts/verify-home-simulator.sh" ||
    fail "host admission does not use the untruncated executable name"
pass "host admission uses untruncated process names"

host_process_program=$temporary/host-process-classifier.awk
/usr/bin/python3 - "$repo/scripts/verify-home-simulator.sh" \
        "$host_process_program" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
start = next((index + 1 for index, line in enumerate(source)
              if line.strip() == "-v target_device=\"$simulator\" '"), None)
end = next((index for index, line in enumerate(source)
            if start is not None and index >= start and
            line.strip() == "' \"$competing_snapshot\" >\"$process_records\"; then"),
           None)
if start is None or end is None or start >= end:
    raise SystemExit("could not isolate host process classifier")
pathlib.Path(sys.argv[2]).write_text("\n".join(source[start:end]) + "\n",
                                    encoding="utf-8")
PY
host_process_fixture=$temporary/host-process-classifier.txt
cat >"$host_process_fixture" <<'EOF'
101 Simulator /fixture/Xcode.app/Contents/Developer/Applications/Simulator.app/Contents/MacOS/Simulator
102 com.apple.CoreSi /Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/XPCServices/com.apple.CoreSimulator.CoreSimulatorService.xpc/Contents/MacOS/com.apple.CoreSimulator.CoreSimulatorService
103 sh /bin/sh fixture-parent
EOF
host_process_output=$temporary/host-process-classifier.out
/usr/bin/awk -v ancestors=' 103' -v expected_booted=0 \
    -v target_device=AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA \
    -f "$host_process_program" "$host_process_fixture" \
    >"$host_process_output" || fail "Apple awk rejected the host process classifier"
grep -Fq "U	101 Simulator " "$host_process_output" ||
    fail "host process classifier did not reject Simulator.app"
grep -Fq "H	102 com.apple.CoreSi " "$host_process_output" ||
    fail "host process classifier did not inventory CoreSimulatorService"
if grep -Fq '103 sh ' "$host_process_output"; then
    fail "host process classifier did not exclude its own ancestry"
fi
pass "Apple awk parses and executes the host process classifier"

metadata_functions=$temporary/simulator-metadata-functions.sh
awk '
    /^load_device_metadata\(\)/ { copy = 1 }
    /^booted_simulator_count\(\)/ { copy = 0 }
    copy { print }
' "$repo/scripts/verify-home-simulator.sh" >"$metadata_functions" ||
    fail "could not extract simulator metadata parser"
sh -n "$metadata_functions" || fail "simulator metadata parser is not valid shell"
metadata_fixture=$temporary/simulator-metadata.json
cat >"$metadata_fixture" <<'EOF'
{
  "devices": {
    "com.apple.CoreSimulator.SimRuntime.iOS-12-0-SyntheticSimulatorFixture": [
      {
        "udid": "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
        "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-8",
        "state": "Shutdown",
        "isAvailable": true,
        "name": "iPhone 8 Home Fixture"
      }
    ]
  }
}
EOF
(
    scratch=$temporary/metadata-scratch
    mkdir "$scratch"
    simulator=AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA
    case_name=ios12-phone
    expected_runtime_identifier=com.apple.CoreSimulator.SimRuntime.iOS-12-0-SyntheticSimulatorFixture
    expected_device_family=iPhone
    simctl() {
        shift
        [ "$*" = 'list devices -j' ] || return 91
        cat "$metadata_fixture"
    }
    . "$metadata_functions"
    load_device_metadata Shutdown
    [ "$actual_runtime_identifier" = "$expected_runtime_identifier" ] || exit 1
    [ "$actual_device_type" = com.apple.CoreSimulator.SimDeviceType.iPhone-8 ] ||
        exit 1
    [ "$actual_device_state" = Shutdown ] || exit 1
    [ "$actual_device_available" = true ] || exit 1
    [ "$actual_device_name" = 'iPhone 8 Home Fixture' ] || exit 1
) || fail "simulator metadata Python heredoc did not execute"
pass "simulator metadata parser executes its Python heredoc"

container_functions=$temporary/container-functions.sh
awk '
    /^container_absent\(\)/ { copy = 1 }
    /^refresh_simulator_lsd\(\)/ { copy = 0 }
    copy { print }
' "$repo/scripts/verify-home-simulator.sh" >"$container_functions" ||
    fail "could not extract container cleanup helpers"
sh -n "$container_functions" || fail "container cleanup helpers are not valid shell"
(
    scratch=$temporary/container-scratch
    mkdir "$scratch"
    bundle_id=com.saurik.Cydia.HomeProbe.offline
    runtime_cleanup_deadline=
    command_timeout_marker=$scratch/command-timeout
    command_cleanup_failure_marker=$scratch/command-cleanup-failed
    fake_container_mode=listapps-error
    simctl() {
        shift
        case "$1:$fake_container_mode" in
            get_app_container:*) return 2 ;;
            listapps:listapps-error) return 2 ;;
            listapps:absent) printf '{}\n'; return 0 ;;
            listapps:registered)
                printf '"%s" = {};\n' "$bundle_id"
                return 0
                ;;
            listapps:timeout) return 124 ;;
            listapps:cleanup-timeout) return 125 ;;
            *) return 3 ;;
        esac
    }
    . "$container_functions"
    if container_absent OFFLINE app; then exit 1; fi
    if app_registered OFFLINE; then exit 1; else status=$?; fi
    [ "$status" -eq 2 ] || exit 1
    fake_container_mode=absent
    container_absent OFFLINE app || exit 1
    fake_container_mode=registered
    if container_absent OFFLINE app; then exit 1; fi
    fake_container_mode=unknown
    if app_registered OFFLINE; then exit 1; else status=$?; fi
    [ "$status" -eq 3 ] || exit 1
    fake_container_mode=timeout
    if app_registered OFFLINE; then exit 1; else status=$?; fi
    [ "$status" -eq 124 ] || exit 1
    fake_container_mode=cleanup-timeout
    if app_registered OFFLINE; then exit 1; else status=$?; fi
    [ "$status" -eq 125 ] || exit 1
) || fail "get_app_container failure was accepted without listapps proof"
pass "container and registration absence require independent successful queries"

grep -Fq 'runtime_cleanup_deadline=$((runtime_cleanup_started + 225))' \
    "$repo/scripts/verify-home-simulator.sh" ||
    fail "runtime cleanup lost its sub-four-minute admission deadline"
grep -Fq 'terminate_timeout=$(deadline_timeout "$runtime_cleanup_deadline" 3)' \
    "$repo/scripts/verify-home-simulator.sh" ||
    fail "probe termination is not clipped to the cleanup deadline"
grep -Fq 'shutdown_timeout=$(deadline_timeout "$runtime_cleanup_deadline" 15)' \
    "$repo/scripts/verify-home-simulator.sh" ||
    fail "simulator shutdown is not clipped to the cleanup deadline"
grep -Fq 'while [ "$attempts" -lt 80 ] && deadline_available "$removal_deadline"; do' \
    "$repo/scripts/verify-home-simulator.sh" ||
    fail "container removal polling cap is not 80 attempts with a deadline"
grep -Fq 'listapps_timeout=10' "$repo/scripts/verify-home-simulator.sh" ||
    fail "LaunchServices listapps timeout is not 10 seconds"
grep -Fq 'listapps_timeout=$(deadline_timeout "$runtime_cleanup_deadline" 10)' \
    "$repo/scripts/verify-home-simulator.sh" ||
    fail "LaunchServices listapps timeout is not clipped to the cleanup deadline"
/usr/bin/python3 - "$repo/scripts/verify-home-simulator.sh" <<'PY' ||
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
start = source.index("wait_for_removal()")
end = source.index("\ncleanup_runtime()", start)
function = source[start:end]
if function.count('-lt 80 ]') != 3:
    raise SystemExit(1)
if function.count('deadline_available "$removal_deadline"') != 3:
    raise SystemExit(1)
if '2) return 1' in function:
    raise SystemExit(1)
if '2|124)\n                        registration_status_retryable' not in function:
    raise SystemExit(1)
if '0|2|124)' not in function:
    raise SystemExit(1)
if function.count('registration_status_retryable "$registration_status"') != 2:
    raise SystemExit(1)
if 'return "$listapps_status"' not in source:
    raise SystemExit(1)
if 'registration_status_retryable()' not in source:
    raise SystemExit(1)
if '[ -e "$command_timeout_marker" ]' not in source:
    raise SystemExit(1)
if '[ ! -e "$command_cleanup_failure_marker" ]' not in source:
    raise SystemExit(1)
PY
    fail "registration removal polling is not bounded/fail-closed at 80 attempts"
pass "runtime cleanup has aggregate and per-command bounds"

removal_functions=$temporary/removal-functions.sh
awk '
    /^registration_status_retryable\(\)/ { copy = 1 }
    /^cleanup_runtime\(\)/ { copy = 0 }
    copy { print }
' "$repo/scripts/verify-home-simulator.sh" >"$removal_functions" ||
    fail "could not extract registration-removal helper"
sh -n "$removal_functions" ||
    fail "registration-removal helper is not valid shell"
(
    scratch=$temporary/removal-scratch
    mkdir "$scratch"
    runtime_cleanup_deadline=9999999999
    bundle_id=fixture.bundle
    simulator=fixture-simulator
    command_timeout_marker=$scratch/command-timeout
    command_cleanup_failure_marker=$scratch/command-cleanup-failed
    . "$removal_functions"
    : >"$command_timeout_marker"
    registration_status_retryable 2 || exit 1
    registration_status_retryable 124 || exit 1
    if registration_status_retryable 125; then exit 1; fi
    if registration_status_retryable 7; then exit 1; fi
    rm -f -- "$command_timeout_marker"
    if registration_status_retryable 124; then exit 1; fi
    : >"$command_timeout_marker"
    : >"$command_cleanup_failure_marker"
    if registration_status_retryable 124; then exit 1; fi
    rm -f -- "$command_cleanup_failure_marker"
    registration_calls=0
    refresh_calls=0
    deadline_available() { return 0; }
    container_absent() { return 0; }
    refresh_simulator_lsd() {
        refresh_calls=$((refresh_calls + 1))
        return 0
    }
    app_registered() {
        registration_calls=$((registration_calls + 1))
        case "$registration_calls" in
            1) return 2 ;;
            2) return 0 ;;
            3) return 124 ;;
            4) return 2 ;;
            5) return 1 ;;
            *) return 1 ;;
        esac
    }
    sleep() { :; }
    wait_for_removal "$simulator" "$scratch" || exit 1
    [ "$registration_calls" -eq 5 ] || exit 1
    [ "$refresh_calls" -eq 1 ] || exit 1
    registration_calls=0
    refresh_calls=0
    app_registered() { return 124; }
    if wait_for_removal "$simulator" "$scratch"; then exit 1; fi
    [ "$refresh_calls" -eq 0 ] || exit 1
    app_registered() { return 125; }
    if wait_for_removal "$simulator" "$scratch"; then exit 1; fi
    [ "$refresh_calls" -eq 0 ] || exit 1
) || fail "transient listapps statuses were not retried/fail-closed correctly"
pass "transient listapps statuses retry only when proven and fail closed otherwise"

if grep -E '\$\(simctl |booted_count=\$\(booted_simulator_count' \
        "$repo/scripts/verify-home-simulator.sh" >/dev/null; then
    fail "tracked simulator command is isolated inside command substitution"
fi
pass "tracked simulator commands remain visible to signal cleanup"

developer=$temporary/Xcode.app/Contents/Developer
mkdir -p "$developer/usr/bin"
developer=$(CDPATH= cd -- "$developer" && pwd -P)
sdk=$developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator15.5.sdk
mkdir -p "$sdk"
cat >"$developer/usr/bin/xcodebuild" <<EOF
#!/bin/sh
case "\$*" in
    '-version')
        echo 'Xcode 13.4.1'
        echo 'Build version 13F100'
        ;;
    '-sdk iphonesimulator -version Path') echo '$sdk' ;;
    '-sdk iphonesimulator -version SDKVersion') echo '15.5' ;;
    *) exit 2 ;;
esac
EOF
cat >"$developer/usr/bin/simctl" <<'EOF'
#!/bin/sh
exit 98
EOF
cat >"$developer/usr/bin/g++" <<'EOF'
#!/bin/sh
exit 96
EOF
chmod +x "$developer/usr/bin/xcodebuild" "$developer/usr/bin/simctl" \
    "$developer/usr/bin/g++"
[ ! -e "$developer/usr/bin/xcrun" ] ||
    fail "offline fake Xcode unexpectedly contains xcrun"
xcodebuild_sha=$(shasum -a 256 "$developer/usr/bin/xcodebuild" | awk '{ print $1 }')
xcrun_sha=$(shasum -a 256 "$host_xcrun" | awk '{ print $1 }')
build_xcodebuild_sha=$(shasum -a 256 "$host_xcodebuild" | awk '{ print $1 }')
simctl_sha=$(shasum -a 256 "$developer/usr/bin/simctl" | awk '{ print $1 }')
simulator_compiler_sha=$(shasum -a 256 "$developer/usr/bin/g++" | awk '{ print $1 }')

fake_host_bin=$temporary/fake-host-bin
mkdir "$fake_host_bin"
cat >"$fake_host_bin/memory_pressure" <<'EOF'
#!/bin/sh
[ "$*" = '-Q' ] || exit 2
echo "System-wide memory free percentage: ${CYDIA_HOME_TEST_FREE_PERCENT:-80}%"
EOF
cat >"$fake_host_bin/sysctl" <<'EOF'
#!/bin/sh
[ "$*" = 'vm.swapusage' ] || exit 2
echo "vm.swapusage: total = 5120.00M used = ${CYDIA_HOME_TEST_SWAP_MB:-64.00}M free = 1024.00M (encrypted)"
EOF
cat >"$fake_host_bin/ps" <<'EOF'
#!/bin/sh
case "$*" in
    '-axo pid=,ucomm=,command=')
        echo '900 sh /bin/sh offline-idle-process'
        ;;
    '-axo pid=,ppid=') exec /bin/ps -axo pid=,ppid= ;;
    '-o ppid= -p '*) echo '1' ;;
    *) exit 2 ;;
esac
EOF
chmod +x "$fake_host_bin/memory_pressure" "$fake_host_bin/sysctl" \
    "$fake_host_bin/ps"

make_log=$temporary/fake-make.log
fake_make=$temporary/fake-make
cat >"$fake_make" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>'$make_log'
[ "\${MAKEFLAGS-}" = '' ] || exit 81
[ "\${MFLAGS-}" = '' ] || exit 82
output=
for argument in "\$@"; do
    case "\$argument" in BUILD_DIR=*) output=\${argument#BUILD_DIR=} ;; esac
done
[ -n "\$output" ] || exit 83
mkdir -p "\$output/bin" || exit 84
printf '%s\n' 'offline prepared Home binary' >"\$output/bin/MobileCydia"
chmod +x "\$output/bin/MobileCydia"
EOF
chmod +x "$fake_make"
offline_path=$fake_host_bin:$(dirname "$host_xcrun"):/usr/bin:/bin

missing_preparation=$temporary/missing-preparation
if PATH="$offline_path" "$repo/scripts/verify-home-simulator.sh" \
        --case ios12-phone \
        --simulator AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA \
        --build-dir "$missing_preparation" --developer-dir "$developer" \
        >"$temporary/missing-preparation.out" \
        2>"$temporary/missing-preparation.err"; then
    fail "Home case accepted a missing explicit preparation"
fi
[ ! -e "$missing_preparation" ] ||
    fail "Home case created directories before finding its preparation"
grep -Fq 'Home matrix preparation is absent' \
    "$temporary/missing-preparation.err" ||
    fail "missing preparation did not fail at the explicit preparation boundary"
pass "Home case refuses missing preparation without creating matrix state"

if PATH="$offline_path" "$repo/scripts/verify-home-simulator.sh" \
        --case ios12-phone \
        --simulator AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA \
        --make "$fake_make" --build-dir "$temporary/rejected-case-make" \
        --developer-dir "$developer" >"$temporary/case-make.out" \
        2>"$temporary/case-make.err"; then
    fail "Home case accepted build authority"
fi
grep -Fq 'usage:' "$temporary/case-make.err" ||
    fail "case build authority was not rejected by the CLI"
pass "only explicit preparation accepts a Make program"

if PATH="$offline_path" "$repo/scripts/verify-home-simulator.sh" --prepare \
        --make "$fake_make" --build-dir "$temporary/rejected-jobs" \
        --developer-dir "$developer" --jobs 2 >"$temporary/jobs.out" \
        2>"$temporary/jobs.err"; then
    fail "unsafe parallel Home preparation was accepted"
fi
grep -Fq 'jobs must be exactly 1' "$temporary/jobs.err" ||
    fail "unsafe parallelism did not fail at the jobs boundary"
pass "Home preparation parallelism is capped at one"

shadow_marker=$temporary/shadow-xcrun-ran
shadow_bin=$temporary/shadow-bin
mkdir "$shadow_bin"
cat >"$shadow_bin/xcrun" <<EOF
#!/bin/sh
: >'$shadow_marker'
exit 91
EOF
chmod +x "$shadow_bin/xcrun"
if PATH="$shadow_bin:$offline_path" "$repo/scripts/verify-home-simulator.sh" --prepare \
        --make "$fake_make" --build-dir "$temporary/shadowed-lookup" \
        --developer-dir "$developer" --jobs 1 \
        >"$temporary/shadowed-lookup.out" \
        2>"$temporary/shadowed-lookup.err"; then
    fail "Home preparation accepted a shadowing xcrun build lookup"
fi
grep -Fq 'preparation xcrun lookup escaped' "$temporary/shadowed-lookup.err" ||
    fail "shadowing xcrun did not fail at build lookup validation"
[ ! -e "$shadow_marker" ] || fail "shadowing xcrun was executed"
[ ! -e "$make_log" ] || fail "shadowing xcrun reached Make"
pass "preparation rejects a shadowing tool lookup before Make"

partial_preparation=$temporary/partial-preparation
mkdir -p "$partial_preparation/home-simulator-matrix/.common.tmp.crashed"
if PATH="$offline_path" "$repo/scripts/verify-home-simulator.sh" \
        --case ios12-phone \
        --simulator AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA \
        --build-dir "$partial_preparation" --developer-dir "$developer" \
        >"$temporary/partial-preparation.out" \
        2>"$temporary/partial-preparation.err"; then
    fail "Home case accepted a partial preparation"
fi
grep -Fq 'stale partial preparation' "$temporary/partial-preparation.err" ||
    fail "partial preparation did not fail closed"
[ ! -e "$partial_preparation/home-simulator-matrix/cases" ] ||
    fail "Home case created case state before rejecting partial preparation"
pass "Home case rejects partial preparation before creating case state"

residual_preparation=$temporary/residual-preparation
mkdir -p "$residual_preparation/home-simulator-matrix/cases/ios12-phone"
if PATH="$offline_path" "$repo/scripts/verify-home-simulator.sh" --prepare \
        --make "$fake_make" --build-dir "$residual_preparation" \
        --developer-dir "$developer" --jobs 1 \
        >"$temporary/residual-preparation.out" \
        2>"$temporary/residual-preparation.err"; then
    fail "new Home preparation accepted residual case evidence"
fi
grep -Fq 'residual Home matrix cases' "$temporary/residual-preparation.err" ||
    fail "residual case evidence did not fail closed"
[ ! -e "$make_log" ] || fail "residual case evidence reached Make"
[ ! -e "$residual_preparation/home-simulator-matrix/common" ] ||
    fail "residual case evidence produced a visible common"
pass "new preparation refuses residual case evidence without invoking Make"

interrupt_child_pid=$temporary/interrupt-child.pid
interrupt_make=$temporary/interrupt-make
cat >"$interrupt_make" <<EOF
#!/bin/sh
output=
for argument in "\$@"; do
    case "\$argument" in BUILD_DIR=*) output=\${argument#BUILD_DIR=} ;; esac
done
[ -n "\$output" ] || exit 83
mkdir -p "\$output/bin" || exit 84
sleep 60 &
child=\$!
printf '%s\n' "\$child" >'$interrupt_child_pid'
wait "\$child"
EOF
chmod +x "$interrupt_make"
interrupt_build=$temporary/interrupt-build
interrupt_guard_fired=$temporary/interrupt-guard-fired
: >"$tool_log"
PATH="$offline_path" "$repo/scripts/verify-home-simulator.sh" --prepare \
    --make "$interrupt_make" --build-dir "$interrupt_build" \
    --developer-dir "$developer" --jobs 1 \
    >"$temporary/interrupt.out" 2>"$temporary/interrupt.err" &
interrupt_verifier=$!
(
    sleep 15
    if kill -0 "$interrupt_verifier" 2>/dev/null; then
        : >"$interrupt_guard_fired"
        kill -TERM "$interrupt_verifier" 2>/dev/null || true
        sleep 2
        kill -KILL "$interrupt_verifier" 2>/dev/null || true
    fi
) &
interrupt_guard=$!
attempts=0
while { [ ! -s "$interrupt_child_pid" ] ||
        [ ! -d "$interrupt_build/home-simulator-matrix/.common.tmp.$interrupt_verifier" ]; } &&
        [ "$attempts" -lt 100 ]; do
    attempts=$((attempts + 1))
    sleep 0.1
done
[ -s "$interrupt_child_pid" ] || fail "interrupted Make did not start its child"
[ -d "$interrupt_build/home-simulator-matrix/.common.tmp.$interrupt_verifier" ] ||
    fail "interrupted preparation did not expose only its temporary common"
interrupt_child=$(cat "$interrupt_child_pid") ||
    fail "could not read interrupted Make child PID"
kill -TERM "$interrupt_verifier" 2>/dev/null ||
    fail "could not interrupt Home preparation"
if wait "$interrupt_verifier"; then
    interrupt_status=0
else
    interrupt_status=$?
fi
kill "$interrupt_guard" 2>/dev/null || true
wait "$interrupt_guard" 2>/dev/null || true
[ ! -e "$interrupt_guard_fired" ] ||
    fail "interrupted Home preparation exceeded its cleanup guard"
[ "$interrupt_status" -eq 143 ] ||
    fail "interrupted Home preparation exited $interrupt_status instead of 143"
attempts=0
while kill -0 "$interrupt_child" 2>/dev/null && [ "$attempts" -lt 50 ]; do
    attempts=$((attempts + 1))
    sleep 0.1
done
if kill -0 "$interrupt_child" 2>/dev/null; then
    kill -KILL "$interrupt_child" 2>/dev/null || true
    fail "interrupted Home preparation leaked its Make child"
fi
[ ! -e "$interrupt_build/home-simulator-matrix/.lock" ] ||
    fail "interrupted Home preparation leaked its lock"
[ ! -e "$interrupt_build/home-simulator-matrix/common" ] ||
    fail "interrupted Home preparation published an unverified common"
[ ! -e "$interrupt_build/home-simulator-matrix/cases" ] ||
    fail "interrupted Home preparation created runtime case state"
interrupt_partials=$temporary/interrupt-partials
find "$interrupt_build/home-simulator-matrix" -mindepth 1 -maxdepth 1 \
    -name '.common.tmp.*' -print >"$interrupt_partials"
[ ! -s "$interrupt_partials" ] ||
    fail "interrupted Home preparation leaked a partial common"
if awk '$1 == "simctl" && $0 != "simctl list devices -j" { bad = 1 }
        END { exit bad }' "$tool_log"; then
    :
else
    fail "interrupted preparation issued a non-list simulator operation"
fi
pass "interrupted preparation kills Make descendants and publishes no partial state"

mutation_simctl_good=$temporary/mutation-simctl.good
cp "$developer/usr/bin/simctl" "$mutation_simctl_good"
mutation_make=$temporary/mutation-make
cat >"$mutation_make" <<EOF
#!/bin/sh
output=
for argument in "\$@"; do
    case "\$argument" in BUILD_DIR=*) output=\${argument#BUILD_DIR=} ;; esac
done
[ -n "\$output" ] || exit 83
mkdir -p "\$output/bin" || exit 84
printf '%s\n' 'offline mutating Home binary' >"\$output/bin/MobileCydia"
chmod +x "\$output/bin/MobileCydia"
printf '%s\n' '# mutated during Make' >>'$developer/usr/bin/simctl'
EOF
chmod +x "$mutation_make"
mutation_build=$temporary/mutation-build
: >"$tool_log"
if PATH="$offline_path" "$repo/scripts/verify-home-simulator.sh" --prepare \
        --make "$mutation_make" --build-dir "$mutation_build" \
        --developer-dir "$developer" --jobs 1 \
        >"$temporary/mutation.out" 2>"$temporary/mutation.err"; then
    fail "Home preparation published after tool mutation during Make"
fi
grep -Fq 'simctl changed during Home preparation' "$temporary/mutation.err" ||
    fail "tool mutation did not fail at the post-build snapshot comparison"
[ ! -e "$mutation_build/home-simulator-matrix/common" ] ||
    fail "tool mutation published a prepared common"
[ ! -e "$mutation_build/home-simulator-matrix/.lock" ] ||
    fail "tool mutation leaked its preparation lock"
mutation_partials=$temporary/mutation-partials
find "$mutation_build/home-simulator-matrix" -mindepth 1 -maxdepth 1 \
    -name '.common.tmp.*' -print >"$mutation_partials"
[ ! -s "$mutation_partials" ] || fail "tool mutation leaked a partial common"
mv "$mutation_simctl_good" "$developer/usr/bin/simctl"
pass "post-build snapshot blocks tool mutation before atomic publication"

prepare_build=$temporary/prepare-build
: >"$tool_log"
PATH="$offline_path" "$repo/scripts/verify-home-simulator.sh" --prepare \
    --make "$fake_make" --build-dir "$prepare_build" \
    --developer-dir "$developer" --jobs 1 >"$temporary/prepare.out"
prepared_common=$prepare_build/home-simulator-matrix/common
[ -f "$prepared_common/manifest.txt" ] &&
    [ -f "$prepared_common/SHA256SUMS" ] &&
    [ -f "$prepared_common/host-admission-prebuild.txt" ] ||
    fail "explicit preparation did not atomically record its receipt"
(cd "$prepared_common" && shasum -a 256 -c SHA256SUMS >/dev/null) ||
    fail "explicit preparation receipt checksums do not verify"
grep -Fxq 'status=prepared' "$prepared_common/manifest.txt" ||
    fail "preparation manifest has no prepared status"
grep -Fxq 'preparation-mode=build-only' "$prepared_common/manifest.txt" ||
    fail "preparation manifest has no build-only mode"
grep -Fxq 'build-jobs=1' "$prepared_common/manifest.txt" ||
    fail "preparation manifest did not pin one build job"
[ "$(wc -l <"$make_log" | tr -d ' ')" -eq 1 ] ||
    fail "explicit preparation did not invoke fake Make exactly once"
grep -Fq -- '-j1' "$make_log" || fail "explicit preparation did not pass -j1"
grep -Fq "gxx=$developer/usr/bin/g++" "$make_log" ||
    fail "explicit preparation did not pin the resolved simulator compiler"
grep -Fq "sdk=$sdk" "$make_log" ||
    fail "explicit preparation did not pin the resolved simulator SDK"
grep -Fxq 'simctl list devices -j' "$tool_log" ||
    fail "preparation did not prove zero booted simulators with a read-only list"
if awk '$1 == "simctl" && $0 != "simctl list devices -j" { bad = 1 }
        END { exit bad }' "$tool_log"; then
    :
else
    fail "preparation issued a non-list simulator operation"
fi
if grep -E 'simctl (boot|bootstatus|install|launch|terminate|uninstall|shutdown)' \
        "$tool_log" >/dev/null; then
    fail "preparation issued a mutating simulator operation"
fi
[ ! -e "$prepare_build/home-simulator-matrix/cases" ] ||
    fail "build-only preparation created runtime case state"
pass "explicit preparation builds once at -j1 with only read-only simctl listing"

PATH="$offline_path" "$repo/scripts/verify-home-simulator.sh" --prepare \
    --make /usr/bin/false --build-dir "$prepare_build" \
    --developer-dir "$developer" --jobs 1 >"$temporary/reprepare.out"
[ "$(wc -l <"$make_log" | tr -d ' ')" -eq 1 ] ||
    fail "idempotent preparation rebuilt an existing common"
grep -Fq 'revalidated the exact prepared shared Home probe' \
    "$temporary/reprepare.out" ||
    fail "idempotent preparation did not report exact receipt reuse"
pass "existing exact preparation revalidates without rebuilding"

low_memory_build=$temporary/low-memory-build
if CYDIA_HOME_TEST_FREE_PERCENT=12 CYDIA_HOME_TEST_SWAP_MB=4096.00 \
        PATH="$offline_path" "$repo/scripts/verify-home-simulator.sh" --prepare \
        --make "$fake_make" --build-dir "$low_memory_build" \
        --developer-dir "$developer" --jobs 1 \
        >"$temporary/low-memory-strict.out" \
        2>"$temporary/low-memory-strict.err"; then
    fail "strict Home preparation accepted low-memory fixture"
fi
[ ! -e "$low_memory_build/home-simulator-matrix/common" ] ||
    fail "strict low-memory failure published a prepared common"
CYDIA_HOME_MEMORY_POLICY=observe CYDIA_HOME_TEST_FREE_PERCENT=12 \
    CYDIA_HOME_TEST_SWAP_MB=4096.00 PATH="$offline_path" \
    "$repo/scripts/verify-home-simulator.sh" --prepare \
    --make "$fake_make" --build-dir "$low_memory_build" \
    --developer-dir "$developer" --jobs 1 \
    >"$temporary/low-memory-observe.out"
low_memory_admission=$low_memory_build/home-simulator-matrix/common/host-admission-prebuild.txt
grep -Fxq 'System-wide memory free percentage: 12%' "$low_memory_admission" ||
    fail "observational memory policy did not preserve free-memory evidence"
grep -Fq 'used = 4096.00M' "$low_memory_admission" ||
    fail "observational memory policy did not preserve swap evidence"
grep -Fxq 'memory-admission-policy=observe' "$low_memory_admission" ||
    fail "observational memory policy was not recorded"
pass "explicit observational policy records memory without blocking serial work"

cp "$prepared_common/CydiaHomeProbe.app/payload.txt" \
    "$temporary/prepared-payload.good"
printf 'tampered\n' >>"$prepared_common/CydiaHomeProbe.app/payload.txt"
if PATH="$offline_path" "$repo/scripts/verify-home-simulator.sh" \
        --case ios12-phone \
        --simulator AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA \
        --build-dir "$prepare_build" --developer-dir "$developer" \
        >"$temporary/prepared-tamper.out" \
        2>"$temporary/prepared-tamper.err"; then
    fail "Home case accepted a tampered prepared common"
fi
grep -Fq 'checksum verification failed' "$temporary/prepared-tamper.err" ||
    fail "prepared common tampering did not fail at checksum verification"
[ ! -e "$prepare_build/home-simulator-matrix/cases" ] ||
    fail "tampered preparation created runtime case state"
cp "$temporary/prepared-payload.good" \
    "$prepared_common/CydiaHomeProbe.app/payload.txt"
pass "Home case rejects complete-payload tampering before case creation"

chmod -x "$prepared_common/CydiaHomeProbe.app/Cydia"
if PATH="$offline_path" "$repo/scripts/verify-home-simulator.sh" \
        --case ios12-phone \
        --simulator AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA \
        --build-dir "$prepare_build" --developer-dir "$developer" \
        >"$temporary/prepared-mode.out" 2>"$temporary/prepared-mode.err"; then
    fail "Home case accepted a non-executable prepared binary"
fi
grep -Fq 'common Home probe application is incomplete' \
    "$temporary/prepared-mode.err" ||
    fail "prepared binary mode tamper did not fail at common verification"
chmod +x "$prepared_common/CydiaHomeProbe.app/Cydia"
pass "Home case rejects a non-executable prepared binary"

make_count_before_case=$(wc -l <"$make_log" | tr -d ' ')
if PATH="$offline_path" "$repo/scripts/verify-home-simulator.sh" \
        --case ios12-phone \
        --simulator AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA \
        --build-dir "$prepare_build" --developer-dir "$developer" \
        >"$temporary/no-case-build.out" 2>"$temporary/no-case-build.err"; then
    fail "offline Home case unexpectedly found a registered simulator"
fi
[ "$(wc -l <"$make_log" | tr -d ' ')" -eq "$make_count_before_case" ] ||
    fail "Home case invoked Make"
grep -Fq 'is not uniquely registered' "$temporary/no-case-build.err" ||
    fail "valid prepared common did not reach synthetic simulator validation"
pass "Home case revalidates preparation and never invokes Make"

prepared_source_head=$source_head
git -C "$repo" -c user.name='Cydia Tests' -c user.email='tests@example.invalid' \
    -c commit.gpgsign=false commit --allow-empty -qm 'fixture HEAD drift'
source_head=$(git -C "$repo" rev-parse HEAD)
source_tree=$(git -C "$repo" rev-parse 'HEAD^{tree}')
[ "$source_head" != "$prepared_source_head" ] || fail "fixture HEAD did not drift"
if PATH="$offline_path" "$repo/scripts/verify-home-simulator.sh" \
        --case ios12-phone \
        --simulator AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA \
        --build-dir "$prepare_build" --developer-dir "$developer" \
        >"$temporary/stale-preparation.out" \
        2>"$temporary/stale-preparation.err"; then
    fail "Home case accepted preparation from the wrong HEAD"
fi
grep -Fq 'source-head=' "$temporary/stale-preparation.err" ||
    fail "wrong-HEAD preparation did not fail at source provenance"
pass "Home case rejects an otherwise intact preparation from another HEAD"

: >"$tool_log"
build_dir=$temporary/build
matrix=$build_dir/home-simulator-matrix
common=$matrix/common
cases=$matrix/cases
mkdir -p "$common/CydiaHomeProbe.app" "$cases"
printf 'offline-home-binary\n' >"$common/CydiaHomeProbe.app/Cydia"
chmod +x "$common/CydiaHomeProbe.app/Cydia"
binary_sha=$(shasum -a 256 "$common/CydiaHomeProbe.app/Cydia" | awk '{ print $1 }')
bundle_id=com.saurik.Cydia.HomeProbe.h$(printf '%s' "$binary_sha" | cut -c 1-12)
cat >"$common/CydiaHomeProbe.app/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$bundle_id</string>
<key>CFBundleShortVersionString</key><string>1.1.36</string>
<key>CFBundleVersion</key><string>1</string>
</dict></plist>
EOF
cat >"$common/manifest.txt" <<EOF
schema=1
status=prepared
preparation-mode=build-only
source-head=$source_head
source-tree=$source_tree
binary-sha256=$binary_sha
bundle-id=$bundle_id
bundle-short-version=1.1.36
bundle-version=1
developer-dir=$developer
xcode-version=13.4.1
xcode-build=13F100
xcodebuild-sha256=$xcodebuild_sha
xcrun-path=$host_xcrun
xcrun-sha256=$xcrun_sha
build-xcrun-path=$host_xcrun
build-xcrun-sha256=$xcrun_sha
build-xcodebuild-path=$host_xcodebuild
build-xcodebuild-sha256=$build_xcodebuild_sha
simctl-path=$developer/usr/bin/simctl
simctl-sha256=$simctl_sha
simulator-compiler-path=$developer/usr/bin/g++
simulator-compiler-sha256=$simulator_compiler_sha
simulator-sdk=$sdk
simulator-sdk-version=15.5
build-jobs=1
EOF
cat >"$common/host-admission-prebuild.txt" <<'EOF'
System-wide memory free percentage: 80%
vm.swapusage: total = 512.00M used = 64.00M free = 448.00M (encrypted)
booted-simulators=0
expected-booted-simulators=0
competing-processes=0
EOF
write_checksums "$common"
common_sha=$(shasum -a 256 "$common/manifest.txt" | awk '{ print $1 }')
common_checksums_sha=$(shasum -a 256 "$common/SHA256SUMS" | awk '{ print $1 }')

valid_png=$temporary/valid.png
/usr/bin/python3 - "$valid_png" <<'PY'
import pathlib
import struct
import sys
import zlib


def chunk(kind, payload):
    checksum = zlib.crc32(kind + payload) & 0xffffffff
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", checksum)


png = bytearray(b"\x89PNG\r\n\x1a\n")
png.extend(chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 6, 0, 0, 0)))
png.extend(chunk(b"IDAT", zlib.compress(b"\x00\x00\x00\x00\xff")))
png.extend(chunk(b"IEND", b""))
pathlib.Path(sys.argv[1]).write_bytes(png)
PY

write_state_plist() {
    state_path=$1
    state_runtime=$2
    state_phase=$3
    state_style=$4
    state_content_size=$5
    state_pid=$6
    state_application=$7
    state_notification_count=$8
    state_lifecycle_complete=$9
    state_lifecycle_armed=${10}
    shift 10
    {
        cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>schema</key><integer>1</integer>
<key>fixtureVersion</key><string>native-home-legacy-hierarchy-v2</string>
<key>buildEvidence</key><dict>
<key>sourceHEAD</key><string>$source_head</string>
<key>binarySHA256</key><string>$binary_sha</string>
<key>bundleShortVersion</key><string>1.1.36</string>
<key>bundleVersion</key><string>1</string>
</dict>
<key>ready</key><true/>
<key>phase</key><string>$state_phase</string>
<key>style</key><string>$state_style</string>
<key>contentSize</key><string>$state_content_size</string>
<key>processID</key><integer>$state_pid</integer>
<key>systemVersion</key><string>$state_runtime</string>
<key>controllerClass</key><string>CydiaHomeProbeController</string>
<key>navigationURL</key><string>cydia://home</string>
EOF
        if [ "$state_lifecycle_armed" = true ]; then
            printf '%s\n' '<key>lifecycleArmed</key><true/>'
        else
            printf '%s\n' '<key>lifecycleArmed</key><false/>'
        fi
        if [ "$state_lifecycle_complete" = true ]; then
            printf '%s\n' '<key>lifecycleComplete</key><true/>'
        else
            printf '%s\n' '<key>lifecycleComplete</key><false/>'
        fi
        cat <<EOF
<key>applicationState</key><string>$state_application</string>
<key>lifecycleNotificationCount</key><integer>$state_notification_count</integer>
<key>lifecycleNotifications</key><array>
EOF
        last_notification=
        for notification in "$@"; do
            printf '<string>%s</string>\n' "$notification"
            last_notification=$notification
        done
        printf '%s\n' '</array>'
        printf '<key>lastLifecycleNotification</key><string>%s</string>\n' \
            "$last_notification"
        printf '%s\n' \
            '<key>splitDisclosureCount</key><integer>4</integer>' \
            '<key>splitDisclosuresDecorative</key><true/>' \
            '<key>splitDisclosuresInsideControls</key><true/>' \
            '<key>splitDisclosuresAtTrailingEdge</key><true/>' \
            '<key>splitDisclosureTintSynchronized</key><true/>' \
            '<key>splitDisclosuresSystemOwned</key><true/>' \
            '<key>splitContentLeadingAligned</key><true/>' \
            '<key>appCacheRequestCount</key><integer>0</integer>' \
            '<key>unexpectedRemoteHomeRequestCount</key><integer>0</integer>' \
            '</dict></plist>'
    } >"$state_path"
}

write_json_from_plist() {
    state_path=$1
    json_path=$2
    /usr/bin/python3 - "$state_path" "$json_path" <<'PY'
import json
import pathlib
import plistlib
import sys

with pathlib.Path(sys.argv[1]).open("rb") as handle:
    state = plistlib.load(handle)
pathlib.Path(sys.argv[2]).write_text(
    json.dumps(state, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
    encoding="utf-8")
PY
}

write_phase_evidence() {
    phase_directory=$1
    phase_name=$2
    phase_runtime=$3
    phase_value=$4
    phase_style=$5
    phase_content_size=$6
    phase_pid=$7
    phase_plist=$phase_directory/$phase_name-state.plist
    write_state_plist "$phase_plist" "$phase_runtime" "$phase_value" \
        "$phase_style" "$phase_content_size" "$phase_pid" active 0 false false
    write_json_from_plist "$phase_plist" \
        "$phase_directory/$phase_name-ui-tree.json"
    cp "$valid_png" "$phase_directory/$phase_name.png"
}

make_case() {
    name=$1
    udid=$2
    runtime=$3
    runtime_identifier=$4
    layout=$5
    family=$6
    device_type=$7
    directory=$cases/$name
    mkdir "$directory"
    : >"$directory/crash-check.txt"
    for required in crash-scan-start shutdown.log parity-note.md; do
        printf 'offline %s for %s\n' "$required" "$name" >"$directory/$required"
    done
    case "$name" in
        ios12-phone) fixture_pid=4101 ;;
        ios15-phone) fixture_pid=4102 ;;
        ios12-ipad) fixture_pid=4103 ;;
        *) fail "unknown fixture case: $name" ;;
    esac
    printf '%s: %s\n' "$bundle_id" "$fixture_pid" >"$directory/launch.log"
    printf '%s: %s\n' "$bundle_id" "$fixture_pid" \
        >"$directory/foreground-launch.log"
    for phase in initial preboot postcleanup; do
        cat >"$directory/host-admission-$phase.txt" <<EOF
System-wide memory free percentage: 80%
vm.swapusage: total = 512.00M used = 64.00M free = 448.00M (encrypted)
booted-simulators=0
expected-booted-simulators=0
competing-processes=0
EOF
    done
    cat >"$directory/host-admission-postboot.txt" <<EOF
System-wide memory free percentage: 80%
vm.swapusage: total = 512.00M used = 64.00M free = 448.00M (encrypted)
booted-simulators=1
expected-booted-simulators=1
competing-processes=0
EOF
    write_phase_evidence "$directory" full-light "$runtime" full light large \
        "$fixture_pid"
    write_phase_evidence "$directory" full-dark "$runtime" full dark large \
        "$fixture_pid"
    write_phase_evidence "$directory" full-dark-accessibility "$runtime" full \
        dark accessibility-large "$fixture_pid"
    write_phase_evidence "$directory" empty-light "$runtime" empty light large \
        "$fixture_pid"
    write_phase_evidence "$directory" offline-dark "$runtime" offline dark large \
        "$fixture_pid"
    for phase in updating-light refresh cancel route-sources guide featured about; do
        write_phase_evidence "$directory" "$phase" "$runtime" updating light \
            large "$fixture_pid"
    done
    if [ "$name" = ios12-ipad ]; then
        write_phase_evidence "$directory" ipad-package "$runtime" updating light \
            large "$fixture_pid"
    fi
    write_state_plist "$directory/lifecycle-before-state.plist" "$runtime" \
        updating light large "$fixture_pid" active 0 false true
    write_state_plist "$directory/lifecycle-background-state.plist" "$runtime" \
        updating light large "$fixture_pid" background 2 false true \
        UIApplicationWillResignActiveNotification \
        UIApplicationDidEnterBackgroundNotification
    write_state_plist "$directory/lifecycle-foreground-state.plist" "$runtime" \
        updating light large "$fixture_pid" active 4 true false \
        UIApplicationWillResignActiveNotification \
        UIApplicationDidEnterBackgroundNotification \
        UIApplicationWillEnterForegroundNotification \
        UIApplicationDidBecomeActiveNotification
    cp "$valid_png" "$directory/lifecycle-foreground.png"
    cat >"$directory/cleanup.log" <<EOF
probe-containers-absent=true
probe-registration-absent=true
simulator-state=Shutdown
launchd-sim-absent=true
EOF
    printf 'offline evidence for %s\n' "$name" >"$directory/evidence.txt"
    cat >"$directory/provenance.txt" <<EOF
source-head=$source_head
source-tree=$source_tree
binary-sha256=$binary_sha
installed-binary-sha256=$binary_sha
bundle-id=$bundle_id
bundle-short-version=1.1.36
bundle-version=1
developer-dir=$developer
xcode-version=13.4.1
xcode-build=13F100
xcodebuild-sha256=$xcodebuild_sha
xcrun-path=$host_xcrun
xcrun-sha256=$xcrun_sha
build-xcrun-path=$host_xcrun
build-xcrun-sha256=$xcrun_sha
build-xcodebuild-path=$host_xcodebuild
build-xcodebuild-sha256=$build_xcodebuild_sha
simctl-path=$developer/usr/bin/simctl
simctl-sha256=$simctl_sha
simulator-compiler-path=$developer/usr/bin/g++
simulator-compiler-sha256=$simulator_compiler_sha
simulator-sdk=$sdk
simulator-sdk-version=15.5
simulator-udid=$udid
runtime-identifier=$runtime_identifier
device-type=$device_type
device-name=Offline $name
EOF
    cat >"$directory/case-manifest.txt" <<EOF
schema=1
case=$name
source-head=$source_head
source-tree=$source_tree
binary-sha256=$binary_sha
bundle-id=$bundle_id
common-manifest-sha256=$common_sha
common-checksums-sha256=$common_checksums_sha
developer-dir=$developer
xcode-version=13.4.1
xcode-build=13F100
xcodebuild-sha256=$xcodebuild_sha
xcrun-path=$host_xcrun
xcrun-sha256=$xcrun_sha
build-xcrun-path=$host_xcrun
build-xcrun-sha256=$xcrun_sha
build-xcodebuild-path=$host_xcodebuild
build-xcodebuild-sha256=$build_xcodebuild_sha
simctl-path=$developer/usr/bin/simctl
simctl-sha256=$simctl_sha
simulator-compiler-path=$developer/usr/bin/g++
simulator-compiler-sha256=$simulator_compiler_sha
simulator-sdk=$sdk
simulator-sdk-version=15.5
simulator-udid=$udid
runtime-version=$runtime
runtime-identifier=$runtime_identifier
layout=$layout
device-family=$family
device-type=$device_type
device-name=Offline $name
probe-containers-absent=true
probe-registration-absent=true
simulator-state=Shutdown
launchd-sim-absent=true
crash-count=0
EOF
    write_checksums "$directory"
}

make_case ios12-phone AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA 12.0 \
    com.apple.CoreSimulator.SimRuntime.iOS-12-0-SyntheticSimulatorFixture phone \
    iPhone com.apple.CoreSimulator.SimDeviceType.iPhone-XS
make_case ios15-phone BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB 15.5 \
    com.apple.CoreSimulator.SimRuntime.iOS-15-5 phone \
    iPhone com.apple.CoreSimulator.SimDeviceType.iPhone-11
make_case ios12-ipad CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC 12.0 \
    com.apple.CoreSimulator.SimRuntime.iOS-12-0-SyntheticSimulatorFixture ipad \
    iPad com.apple.CoreSimulator.SimDeviceType.iPad-Pro--9-7-inch-

/usr/bin/python3 - "$repo/scripts/verify-home-simulator.sh" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
dispatch_marker = 'source_head=$(git -C "$source_root" rev-parse HEAD)'
dispatch_offset = source.rfind(dispatch_marker)
if dispatch_offset < 0:
    raise SystemExit("Home mode dispatch is absent")
dispatch = source[dispatch_offset:]
prepare_markers = [
    'if [ "$mode" = prepare ]; then',
    'host_admission "$preparation_admission_file"',
    'prepare_common',
    'exit 0',
]
offset = 0
for marker in prepare_markers:
    position = dispatch.find(marker, offset)
    if position < 0:
        raise SystemExit("Home build-only preparation order is incomplete")
    offset = position + len(marker)
case_flow = dispatch[offset:]
if "create_common" in case_flow or "prepare_common" in case_flow or \
        "make_program" in case_flow:
    raise SystemExit("Home runtime case retains an implicit build path")
case_markers = [
    '[ -d "$common_dir" ] ||',
    'verify_common',
    'mkdir -p "$cases_dir"',
    'mkdir "$case_temporary"',
    'host_admission "$case_temporary/host-admission-initial.txt"',
    'load_device_metadata Shutdown',
    'host_admission "$case_temporary/host-admission-preboot.txt"',
    'load_device_metadata Shutdown',
    'simctl 30 boot "$simulator"',
]
offset = 0
for marker in case_markers:
    position = case_flow.find(marker, offset)
    if position < 0:
        raise SystemExit("Home prepared-common/preboot order is incomplete")
    offset = position + len(marker)

create_start = source.index("create_common() {")
create_end = source.index("\nprepare_common() {", create_start)
create = source[create_start:create_end]
temporary_verify = create.find('verify_common_at "$common_temporary"')
atomic_rename = create.find('mv "$common_temporary" "$common_dir"')
if temporary_verify < 0 or atomic_rename < 0 or temporary_verify > atomic_rename:
    raise SystemExit("Home preparation becomes visible before full verification")
PY
pass "prepare is the only build path and cases verify common before creating state"
pass "prepared common is fully verified before its atomic rename"

prepare_make_recipe=$temporary/prepare-make-recipe
case_make_recipe=$temporary/case-make-recipe
awk '
    /^verify-home-simulator-prepare:/ { copy = 1 }
    /^verify-home-simulator:/ { copy = 0 }
    copy { print }
' "$root/mk/verify.mk" >"$prepare_make_recipe"
awk '
    /^verify-home-simulator:/ { copy = 1 }
    /^verify-home-simulator-matrix:/ { copy = 0 }
    copy { print }
' "$root/mk/verify.mk" >"$case_make_recipe"
grep -Fq -- '--prepare --make "$(MAKE)"' "$prepare_make_recipe" ||
    fail "Make preparation target does not own the explicit build"
if grep -Fq -- '--make' "$case_make_recipe"; then
    fail "Make runtime case retains build authority"
fi
pass "Make exposes one explicit prepare target and no case build authority"

absent_build=$temporary/absent-build
if "$repo/scripts/verify-home-simulator.sh" --finalize --build-dir "$absent_build" \
        --developer-dir "$developer" >"$temporary/absent.out" 2>"$temporary/absent.err"; then
    fail "matrix finalizer accepted absent evidence"
fi
[ ! -e "$absent_build" ] || fail "read-only finalizer created an absent matrix root"
pass "matrix finalizer leaves absent evidence untouched"

failed_find_bin=$temporary/failed-find-bin
mkdir "$failed_find_bin"
cat >"$failed_find_bin/find" <<'EOF'
#!/bin/sh
exit 73
EOF
chmod +x "$failed_find_bin/find"
if PATH="$failed_find_bin:/usr/bin:/bin" \
        "$repo/scripts/verify-home-simulator.sh" --finalize \
        --build-dir "$build_dir" --developer-dir "$developer" \
        >"$temporary/find.out" 2>"$temporary/find.err"; then
    fail "matrix finalizer accepted a failed find scan"
fi
grep -Fq 'could not inspect Home matrix partial preparations' \
    "$temporary/find.err" ||
    fail "failed find did not fail closed at the evidence scan"
pass "matrix finalizer fails closed when find fails"

cp "$developer/usr/bin/xcodebuild" "$temporary/xcodebuild.good"
sed 's/Xcode 13[.]4[.]1/Xcode 13.4.0/' "$temporary/xcodebuild.good" \
    >"$developer/usr/bin/xcodebuild"
chmod +x "$developer/usr/bin/xcodebuild"
if "$repo/scripts/verify-home-simulator.sh" --finalize --build-dir "$build_dir" \
        --developer-dir "$developer" >"$temporary/xcode.out" 2>"$temporary/xcode.err"; then
    fail "matrix finalizer accepted the wrong Xcode"
fi
grep -Fq 'requires Xcode 13.4.1/13F100' "$temporary/xcode.err" ||
    fail "wrong Xcode did not fail at the toolchain provenance boundary"
mv "$temporary/xcodebuild.good" "$developer/usr/bin/xcodebuild"
pass "matrix finalizer requires the exact explicit Xcode"

: >"$xcrun_escape_marker"
if "$repo/scripts/verify-home-simulator.sh" --finalize --build-dir "$build_dir" \
        --developer-dir "$developer" >"$temporary/simctl-escape.out" \
        2>"$temporary/simctl-escape.err"; then
    fail "matrix finalizer accepted simctl outside the explicit Xcode"
fi
grep -Fq 'simctl escaped the explicit developer directory: /usr/bin/simctl' \
        "$temporary/simctl-escape.err" ||
    fail "escaped simctl did not fail at the exact tool provenance boundary"
rm "$xcrun_escape_marker"
pass "host xcrun cannot resolve simctl outside the explicit Xcode"

cp "$developer/usr/bin/simctl" "$temporary/simctl.good"
printf '%s\n' '# same-path content drift' >>"$developer/usr/bin/simctl"
if "$repo/scripts/verify-home-simulator.sh" --finalize --build-dir "$build_dir" \
        --developer-dir "$developer" >"$temporary/simctl-drift.out" \
        2>"$temporary/simctl-drift.err"; then
    fail "matrix finalizer accepted same-path simctl content drift"
fi
grep -Fq 'simctl-sha256=' "$temporary/simctl-drift.err" ||
    fail "same-path simctl drift did not fail at the executable hash boundary"
mv "$temporary/simctl.good" "$developer/usr/bin/simctl"
pass "matrix finalizer pins simctl content as well as its path"

mv "$cases/ios12-ipad" "$temporary/ios12-ipad"
if "$repo/scripts/verify-home-simulator.sh" --finalize --build-dir "$build_dir" \
        --developer-dir "$developer" >"$temporary/missing.out" 2>"$temporary/missing.err"; then
    fail "matrix finalizer accepted a missing case"
fi
mv "$temporary/ios12-ipad" "$cases/ios12-ipad"
pass "matrix finalizer rejects partial evidence"

: >"$cases/unexpected-entry"
if "$repo/scripts/verify-home-simulator.sh" --finalize --build-dir "$build_dir" \
        --developer-dir "$developer" >"$temporary/extra.out" 2>"$temporary/extra.err"; then
    fail "matrix finalizer accepted an extra case-root entry"
fi
rm "$cases/unexpected-entry"
pass "matrix finalizer requires exactly the three named case entries"

printf 'drifted common payload\n' >"$common/drift.txt"
write_checksums "$common"
if "$repo/scripts/verify-home-simulator.sh" --finalize --build-dir "$build_dir" \
        --developer-dir "$developer" >"$temporary/common-drift.out" \
        2>"$temporary/common-drift.err"; then
    fail "matrix finalizer accepted a changed common payload"
fi
rm "$common/drift.txt"
write_checksums "$common"
[ "$(shasum -a 256 "$common/SHA256SUMS" | awk '{ print $1 }')" = \
        "$common_checksums_sha" ] || fail "common fixture did not restore exactly"
pass "matrix cases pin the exact common payload"

sed 's/^source-tree=.*/source-tree=stale/' "$cases/ios15-phone/case-manifest.txt" \
    >"$temporary/stale-manifest"
mv "$temporary/stale-manifest" "$cases/ios15-phone/case-manifest.txt"
write_checksums "$cases/ios15-phone"
if "$repo/scripts/verify-home-simulator.sh" --finalize --build-dir "$build_dir" \
        --developer-dir "$developer" >"$temporary/stale.out" 2>"$temporary/stale.err"; then
    fail "matrix finalizer accepted stale provenance"
fi
sed "s/^source-tree=.*/source-tree=$source_tree/" \
    "$cases/ios15-phone/case-manifest.txt" >"$temporary/fresh-manifest"
mv "$temporary/fresh-manifest" "$cases/ios15-phone/case-manifest.txt"
write_checksums "$cases/ios15-phone"
pass "matrix finalizer rejects stale source provenance"

sed 's/^developer-dir=.*/developer-dir=stale/' "$cases/ios15-phone/provenance.txt" \
    >"$temporary/stale-provenance"
mv "$temporary/stale-provenance" "$cases/ios15-phone/provenance.txt"
write_checksums "$cases/ios15-phone"
if "$repo/scripts/verify-home-simulator.sh" --finalize --build-dir "$build_dir" \
        --developer-dir "$developer" >"$temporary/provenance.out" \
        2>"$temporary/provenance.err"; then
    fail "matrix finalizer accepted stale launch provenance"
fi
sed "s|^developer-dir=.*|developer-dir=$developer|" \
    "$cases/ios15-phone/provenance.txt" >"$temporary/fresh-provenance"
mv "$temporary/fresh-provenance" "$cases/ios15-phone/provenance.txt"
write_checksums "$cases/ios15-phone"
pass "matrix finalizer validates the captured launch provenance"

sed 's/free percentage: 80%/free percentage: 39%/' \
    "$cases/ios12-phone/host-admission-postcleanup.txt" \
    >"$temporary/low-memory-admission"
mv "$temporary/low-memory-admission" \
    "$cases/ios12-phone/host-admission-postcleanup.txt"
write_checksums "$cases/ios12-phone"
if "$repo/scripts/verify-home-simulator.sh" --finalize --build-dir "$build_dir" \
        --developer-dir "$developer" >"$temporary/admission.out" \
        2>"$temporary/admission.err"; then
    fail "matrix finalizer accepted a failed cleanup memory gate"
fi
sed 's/free percentage: 39%/free percentage: 80%/' \
    "$cases/ios12-phone/host-admission-postcleanup.txt" \
    >"$temporary/healthy-memory-admission"
mv "$temporary/healthy-memory-admission" \
    "$cases/ios12-phone/host-admission-postcleanup.txt"
write_checksums "$cases/ios12-phone"
pass "matrix finalizer validates cleanup memory and process gates"

{
    sed 's/free percentage: 80%/free percentage: 12%/' \
        "$cases/ios12-phone/host-admission-postcleanup.txt"
    echo 'memory-admission-policy=observe'
} >"$temporary/observed-memory-admission"
mv "$temporary/observed-memory-admission" \
    "$cases/ios12-phone/host-admission-postcleanup.txt"
write_checksums "$cases/ios12-phone"
if ! "$repo/scripts/verify-home-simulator.sh" --finalize \
        --build-dir "$build_dir" --developer-dir "$developer" \
        >"$temporary/observed-memory-finalize.out" \
        2>"$temporary/observed-memory-finalize.err"; then
    fail "matrix finalizer rejected explicitly observational memory evidence"
fi
rm "$matrix/matrix-complete.json"
sed '/^memory-admission-policy=observe$/d; s/free percentage: 12%/free percentage: 80%/' \
    "$cases/ios12-phone/host-admission-postcleanup.txt" \
    >"$temporary/restored-memory-admission"
mv "$temporary/restored-memory-admission" \
    "$cases/ios12-phone/host-admission-postcleanup.txt"
write_checksums "$cases/ios12-phone"
pass "matrix finalizer honors self-described observational memory evidence"

mutate_plist_key() {
    plist_path=$1
    key_path=$2
    json_value=$3
    /usr/bin/python3 - "$plist_path" "$key_path" "$json_value" <<'PY'
import json
import pathlib
import plistlib
import sys

path = pathlib.Path(sys.argv[1])
with path.open("rb") as handle:
    state = plistlib.load(handle)
destination = state
parts = sys.argv[2].split(".")
for part in parts[:-1]:
    destination = destination[part]
destination[parts[-1]] = json.loads(sys.argv[3])
with path.open("wb") as handle:
    plistlib.dump(state, handle, fmt=plistlib.FMT_XML, sort_keys=False)
PY
}

expect_semantic_rejection() {
    rejection_name=$1
    rejection_pattern=$2
    if "$repo/scripts/verify-home-simulator.sh" --finalize \
            --build-dir "$build_dir" --developer-dir "$developer" \
            >"$temporary/$rejection_name.out" \
            2>"$temporary/$rejection_name.err"; then
        fail "matrix finalizer accepted $rejection_name semantic evidence"
    fi
    grep -Fq "$rejection_pattern" "$temporary/$rejection_name.err" ||
        fail "$rejection_name did not fail at the expected semantic boundary"
}

cp "$cases/ios12-phone/full-light-state.plist" "$temporary/full-light-state.good"
printf '%s\n' 'not a plist' >"$cases/ios12-phone/full-light-state.plist"
write_checksums "$cases/ios12-phone"
if "$repo/scripts/verify-home-simulator.sh" --finalize --build-dir "$build_dir" \
        --developer-dir "$developer" >"$temporary/plist.out" \
        2>"$temporary/plist.err"; then
    fail "matrix finalizer accepted a malformed state plist"
fi
grep -Fq 'full-light-state.plist is not a valid plist' "$temporary/plist.err" ||
    fail "malformed state plist did not fail at the semantic boundary"
mv "$temporary/full-light-state.good" \
    "$cases/ios12-phone/full-light-state.plist"
write_checksums "$cases/ios12-phone"
pass "matrix finalizer parses every state and lifecycle plist"

cp "$cases/ios12-phone/full-light-state.plist" "$temporary/phase-state.good"
mutate_plist_key "$cases/ios12-phone/full-light-state.plist" phase '"offline"'
write_checksums "$cases/ios12-phone"
expect_semantic_rejection wrong-phase "full-light-state.plist has phase='offline'"
mv "$temporary/phase-state.good" "$cases/ios12-phone/full-light-state.plist"
write_checksums "$cases/ios12-phone"

cp "$cases/ios12-phone/full-light-state.plist" "$temporary/pid-state.good"
mutate_plist_key "$cases/ios12-phone/full-light-state.plist" processID '9999'
write_checksums "$cases/ios12-phone"
expect_semantic_rejection wrong-pid 'full-light-state.plist processID 9999 differs'
mv "$temporary/pid-state.good" "$cases/ios12-phone/full-light-state.plist"
write_checksums "$cases/ios12-phone"

cp "$cases/ios12-phone/full-light-state.plist" "$temporary/provenance-state.good"
mutate_plist_key "$cases/ios12-phone/full-light-state.plist" \
    buildEvidence.sourceHEAD '"stale"'
write_checksums "$cases/ios12-phone"
expect_semantic_rejection wrong-state-provenance \
    "full-light-state.plist buildEvidence has sourceHEAD='stale'"
mv "$temporary/provenance-state.good" \
    "$cases/ios12-phone/full-light-state.plist"
write_checksums "$cases/ios12-phone"

cp "$cases/ios12-phone/lifecycle-foreground-state.plist" \
    "$temporary/lifecycle-state.good"
mutate_plist_key "$cases/ios12-phone/lifecycle-foreground-state.plist" \
    lifecycleNotifications \
    '["UIApplicationDidBecomeActiveNotification","UIApplicationWillEnterForegroundNotification","UIApplicationDidEnterBackgroundNotification","UIApplicationWillResignActiveNotification"]'
write_checksums "$cases/ios12-phone"
expect_semantic_rejection wrong-lifecycle \
    'lifecycle-foreground-state.plist has lifecycleNotifications='
mv "$temporary/lifecycle-state.good" \
    "$cases/ios12-phone/lifecycle-foreground-state.plist"
write_checksums "$cases/ios12-phone"
pass "matrix finalizer pins phase PID provenance and lifecycle semantics"

cp "$cases/ios12-phone/launch.log" "$temporary/launch.good"
printf '%s: %s\n' wrong.bundle 4101 >>"$cases/ios12-phone/launch.log"
write_checksums "$cases/ios12-phone"
expect_semantic_rejection ambiguous-launch \
    'launch.log must contain exactly one'
mv "$temporary/launch.good" "$cases/ios12-phone/launch.log"
write_checksums "$cases/ios12-phone"
pass "matrix finalizer requires one exact bundle launch record"

cp "$cases/ios12-phone/full-light-state.plist" "$temporary/duplicate-plist.good"
/usr/bin/python3 - "$cases/ios12-phone/full-light-state.plist" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
payload = path.read_bytes()
closing = payload.rfind(b"</dict>")
if closing < 0:
    raise SystemExit("fixture plist closing marker changed")
duplicate = b"<key>schema</key><integer>1</integer>\n"
path.write_bytes(payload[:closing] + duplicate + payload[closing:])
PY
write_checksums "$cases/ios12-phone"
expect_semantic_rejection duplicate-plist "repeats plist key 'schema'"
mv "$temporary/duplicate-plist.good" \
    "$cases/ios12-phone/full-light-state.plist"
write_checksums "$cases/ios12-phone"
pass "matrix finalizer rejects duplicate plist keys"

cp "$cases/ios12-phone/full-light-ui-tree.json" \
    "$temporary/full-light-ui-tree.good"
cp "$cases/ios12-phone/full-dark-ui-tree.json" \
    "$cases/ios12-phone/full-light-ui-tree.json"
write_checksums "$cases/ios12-phone"
if "$repo/scripts/verify-home-simulator.sh" --finalize --build-dir "$build_dir" \
        --developer-dir "$developer" >"$temporary/json.out" \
        2>"$temporary/json.err"; then
    fail "matrix finalizer accepted mismatched UI-tree JSON"
fi
grep -Fq 'full-light UI-tree JSON does not equal its state plist' \
        "$temporary/json.err" ||
    fail "mismatched UI-tree JSON did not fail at the semantic boundary"
mv "$temporary/full-light-ui-tree.good" \
    "$cases/ios12-phone/full-light-ui-tree.json"
write_checksums "$cases/ios12-phone"
pass "matrix finalizer requires paired plist and JSON equality"

cp "$cases/ios12-phone/full-light-state.plist" \
    "$temporary/integral-real-state.good"
cp "$cases/ios12-phone/full-light-ui-tree.json" \
    "$temporary/integral-real-tree.good"
/usr/bin/python3 - "$cases/ios12-phone/full-light-state.plist" \
        "$cases/ios12-phone/full-light-ui-tree.json" <<'PY'
import json
import pathlib
import plistlib
import sys

plist_path = pathlib.Path(sys.argv[1])
json_path = pathlib.Path(sys.argv[2])
state = plistlib.loads(plist_path.read_bytes())
tree = json.loads(json_path.read_text(encoding="utf-8"))
state["integralRealRoundTrip"] = 53.0
tree["integralRealRoundTrip"] = 53
plist_path.write_bytes(plistlib.dumps(state, fmt=plistlib.FMT_XML))
json_path.write_text(json.dumps(tree, ensure_ascii=False, indent=2,
                                sort_keys=True) + "\n", encoding="utf-8")
PY
write_checksums "$cases/ios12-phone"
if ! "$repo/scripts/verify-home-simulator.sh" --finalize \
        --build-dir "$build_dir" --developer-dir "$developer" \
        >"$temporary/integral-real.out" \
        2>"$temporary/integral-real.err"; then
    fail "matrix finalizer rejected an integral plist real represented as JSON integer"
fi
rm "$matrix/matrix-complete.json"
mv "$temporary/integral-real-state.good" \
    "$cases/ios12-phone/full-light-state.plist"
mv "$temporary/integral-real-tree.good" \
    "$cases/ios12-phone/full-light-ui-tree.json"
write_checksums "$cases/ios12-phone"
pass "matrix finalizer accepts JSON's lossless integral-real representation"

cp "$cases/ios12-phone/full-light-ui-tree.json" \
    "$temporary/duplicate-ui-tree.good"
printf '%s\n' '{"schema":1,"schema":1}' \
    >"$cases/ios12-phone/full-light-ui-tree.json"
write_checksums "$cases/ios12-phone"
expect_semantic_rejection duplicate-json "JSON object repeats key 'schema'"
mv "$temporary/duplicate-ui-tree.good" \
    "$cases/ios12-phone/full-light-ui-tree.json"
write_checksums "$cases/ios12-phone"
pass "matrix finalizer rejects duplicate JSON keys"

cp "$cases/ios12-phone/full-light.png" "$temporary/full-light.good.png"
/usr/bin/python3 - "$cases/ios12-phone/full-light.png" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
payload = bytearray(path.read_bytes())
payload[-1] ^= 1
path.write_bytes(payload)
PY
write_checksums "$cases/ios12-phone"
if "$repo/scripts/verify-home-simulator.sh" --finalize --build-dir "$build_dir" \
        --developer-dir "$developer" >"$temporary/png.out" \
        2>"$temporary/png.err"; then
    fail "matrix finalizer accepted an invalid PNG"
fi
grep -Fq 'has a bad IEND CRC' "$temporary/png.err" ||
    fail "invalid PNG did not fail at the semantic boundary"
mv "$temporary/full-light.good.png" "$cases/ios12-phone/full-light.png"
write_checksums "$cases/ios12-phone"
pass "matrix finalizer validates PNG chunks and CRCs"

cp "$cases/ios12-phone/full-light.png" "$temporary/full-light-valid-idat.png"
/usr/bin/python3 - "$cases/ios12-phone/full-light.png" <<'PY'
import pathlib
import struct
import sys
import zlib


def chunk(kind, payload):
    checksum = zlib.crc32(kind + payload) & 0xffffffff
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", checksum)


png = bytearray(b"\x89PNG\r\n\x1a\n")
png.extend(chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 6, 0, 0, 0)))
png.extend(chunk(b"IDAT", zlib.compress(b"\x05\x00\x00\x00\xff")))
png.extend(chunk(b"IEND", b""))
pathlib.Path(sys.argv[1]).write_bytes(png)
PY
write_checksums "$cases/ios12-phone"
expect_semantic_rejection invalid-idat \
    'full-light.png contains an invalid PNG row filter'
mv "$temporary/full-light-valid-idat.png" "$cases/ios12-phone/full-light.png"
write_checksums "$cases/ios12-phone"
pass "matrix finalizer inflates and validates PNG scanlines"

"$repo/scripts/verify-home-simulator.sh" --finalize --build-dir "$build_dir" \
    --developer-dir "$developer" >"$temporary/finalize.out"
[ -f "$matrix/matrix-complete.json" ] || fail "matrix completion was not written"
/usr/bin/python3 -c 'import json,sys; json.load(open(sys.argv[1]))' \
    "$matrix/matrix-complete.json" ||
    fail "matrix completion is not valid JSON"
grep -Fq '"status": "complete"' "$matrix/matrix-complete.json" ||
    fail "matrix completion status is absent"
grep -Fq "\"xcrunPath\": \"$host_xcrun\"" \
        "$matrix/matrix-complete.json" ||
    fail "matrix completion did not record the external host xcrun"
"$repo/scripts/verify-home-simulator.sh" --finalize --build-dir "$build_dir" \
    --developer-dir "$developer" >"$temporary/refinalize.out"
grep -Fq 'existing Home matrix completion revalidated' "$temporary/refinalize.out" ||
    fail "matrix finalization is not idempotent"
pass "exact three-case evidence completes atomically and revalidates"
pass "fake Xcode without xcrun finalizes through the recorded host xcrun"

printf 'tampered\n' >>"$cases/ios12-phone/evidence.txt"
if "$repo/scripts/verify-home-simulator.sh" --finalize --build-dir "$build_dir" \
        --developer-dir "$developer" >"$temporary/tampered.out" \
        2>"$temporary/tampered.err"; then
    fail "completed matrix accepted tampered evidence"
fi
pass "completed matrix revalidation detects evidence tampering"

if grep -E '^simctl ' "$tool_log" >/dev/null 2>&1; then
    fail "offline finalizer invoked simctl"
fi
pass "offline finalizer never invokes a simulator operation"
