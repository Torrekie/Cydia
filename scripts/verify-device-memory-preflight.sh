#!/bin/sh
# Copyright (C) 2026 Torrekie
# SPDX-License-Identifier: GPL-3.0-or-later

# Read-only admission gate for Cydia device acceptance.  The live mode performs
# one bounded SSH collection; --report validates a previously captured report
# without contacting a device.  Missing, conflicting, or malformed required
# fields always fail closed.

set -eu
LC_ALL=C
export LC_ALL

minimum_free_percent=30
maximum_swap_used_mb=256
maximum_collection_timeout_seconds=15
collection_timeout_seconds=$maximum_collection_timeout_seconds

fail() {
    echo "[verify-device-preflight][FAIL] $*" >&2
    exit 1
}

usage() {
    cat >&2 <<'EOF'
usage: verify-device-memory-preflight.sh --layout <rootful|rootless> --report <file>
       verify-device-memory-preflight.sh --layout <rootful|rootless> --host <user@host> [--output <file>] [--timeout-seconds <1-15>]
EOF
    exit 2
}

layout=
report=
target=
output=
timeout_was_set=no

while [ "$#" -gt 0 ]; do
    case "$1" in
        --layout)
            [ "$#" -ge 2 ] || usage
            layout=$2
            shift 2
            ;;
        --report)
            [ "$#" -ge 2 ] || usage
            report=$2
            shift 2
            ;;
        --host)
            [ "$#" -ge 2 ] || usage
            target=$2
            shift 2
            ;;
        --output)
            [ "$#" -ge 2 ] || usage
            output=$2
            shift 2
            ;;
        --timeout-seconds)
            [ "$#" -ge 2 ] || usage
            collection_timeout_seconds=$2
            timeout_was_set=yes
            shift 2
            ;;
        *) usage ;;
    esac
done

case "$layout" in
    rootful) expected_architecture=iphoneos-arm; expected_prefix=rootful ;;
    rootless) expected_architecture=iphoneos-arm64; expected_prefix=rootless ;;
    *) usage ;;
esac

if [ -n "$report" ] && [ -n "$target" ]; then
    usage
fi
if [ -z "$report" ] && [ -z "$target" ]; then
    usage
fi
if [ -n "$report" ] && [ -n "$output" ]; then
    usage
fi
case "$collection_timeout_seconds" in
    ''|*[!0-9]*) usage ;;
esac
[ "$collection_timeout_seconds" -ge 1 ] &&
    [ "$collection_timeout_seconds" -le "$maximum_collection_timeout_seconds" ] ||
    usage
if [ -n "$report" ] && [ "$timeout_was_set" = yes ]; then
    usage
fi

temporary=
output_temporary=
timeout_marker=
completion_marker=
ssh_pid=
watchdog_pid=
cleanup() {
    if [ -n "$watchdog_pid" ]; then
        kill "$watchdog_pid" 2>/dev/null || true
        wait "$watchdog_pid" 2>/dev/null || true
    fi
    if [ -n "$ssh_pid" ]; then
        kill "$ssh_pid" 2>/dev/null || true
        kill -9 "$ssh_pid" 2>/dev/null || true
        wait "$ssh_pid" 2>/dev/null || true
    fi
    if [ -n "$temporary" ] && [ -f "$temporary" ]; then
        rm -f "$temporary"
    fi
    if [ -n "$output_temporary" ] && [ -f "$output_temporary" ]; then
        rm -f "$output_temporary"
    fi
    if [ -n "$timeout_marker" ] && [ -f "$timeout_marker" ]; then
        rm -f "$timeout_marker"
    fi
    if [ -n "$completion_marker" ] && [ -f "$completion_marker" ]; then
        rm -f "$completion_marker"
    fi
}
on_signal() {
    trap - EXIT
    cleanup
    exit 1
}
trap cleanup EXIT
trap on_signal HUP INT TERM

if [ -n "$target" ]; then
    case "$target" in
        -*|*[!A-Za-z0-9_.:@-]*) fail "unsafe SSH target: $target" ;;
    esac

    temporary=$(mktemp "${TMPDIR:-/tmp}/cydia-device-preflight.XXXXXX") ||
        fail "could not allocate a report file"
    timeout_marker=$temporary.timeout
    completion_marker=$temporary.complete
    captured_at_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ') ||
        fail "could not record capture time"
    {
        echo __CYDIA_CAPTURE__
        echo "target=$target"
        echo "captured_at_utc=$captured_at_utc"
    } >"$temporary"

    # The remote shell does not load profiles.  Its explicit PATH covers both
    # package layouts, and the host watchdog bounds the entire collection even
    # when a connected shell or command stops making progress.
    ssh -T -o BatchMode=yes -o ConnectTimeout=8 \
            -o ConnectionAttempts=1 -o ServerAliveInterval=3 \
            -o ServerAliveCountMax=1 "$target" \
            'if [ -x /var/jb/bin/bash ]; then exec /var/jb/bin/bash --noprofile --norc -s; elif [ -x /bin/bash ]; then exec /bin/bash --noprofile --norc -s; else exit 127; fi' \
            >>"$temporary" <<'REMOTE' &
set -eu
LC_ALL=C
LANG=C
PATH=/var/jb/usr/bin:/var/jb/usr/sbin:/var/jb/bin:/var/jb/sbin:/usr/bin:/usr/sbin:/bin:/sbin
export LC_ALL LANG PATH

memory_pressure_command=$(command -v memory_pressure || true)
sysctl_command=$(command -v sysctl || true)
ps_command=$(command -v ps || true)
dpkg_command=$(command -v dpkg || true)
id_command=$(command -v id || true)

[ -n "$memory_pressure_command" ]
[ -n "$sysctl_command" ]
[ -n "$ps_command" ]
[ -n "$dpkg_command" ]
[ -n "$id_command" ]

echo __CYDIA_MEMORY__
"$memory_pressure_command" -Q
echo __CYDIA_SWAP__
"$sysctl_command" vm.swapusage
echo __CYDIA_ARCH__
"$dpkg_command" --print-architecture
echo __CYDIA_UID__
"$id_command" -u
echo __CYDIA_PREFIX__
if [ -d /var/jb ]; then
    echo rootless
else
    echo rootful
fi
echo __CYDIA_PROCESSES__
"$ps_command" -axo pid=,comm=
echo __CYDIA_END__
REMOTE

    ssh_pid=$!
    (
        watchdog_sleep_pid=
        watchdog_grace_pid=
        stop_watchdog() {
            if [ -n "$watchdog_sleep_pid" ]; then
                kill "$watchdog_sleep_pid" 2>/dev/null || true
                wait "$watchdog_sleep_pid" 2>/dev/null || true
            fi
            if [ -n "$watchdog_grace_pid" ]; then
                kill "$watchdog_grace_pid" 2>/dev/null || true
                wait "$watchdog_grace_pid" 2>/dev/null || true
            fi
            exit 0
        }
        trap stop_watchdog HUP INT TERM
        sleep "$collection_timeout_seconds" &
        watchdog_sleep_pid=$!
        wait "$watchdog_sleep_pid" 2>/dev/null || exit 0
        watchdog_sleep_pid=
        if [ ! -f "$completion_marker" ] && kill -0 "$ssh_pid" 2>/dev/null; then
            : >"$timeout_marker"
            kill "$ssh_pid" 2>/dev/null || true
            sleep 1 &
            watchdog_grace_pid=$!
            wait "$watchdog_grace_pid" 2>/dev/null || exit 0
            watchdog_grace_pid=
            kill -9 "$ssh_pid" 2>/dev/null || true
        fi
    ) &
    watchdog_pid=$!

    ssh_status=0
    wait "$ssh_pid" || ssh_status=$?
    ssh_pid=
    : >"$completion_marker"
    kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
    watchdog_pid=

    if [ -f "$timeout_marker" ]; then
        fail "read-only SSH collection exceeded ${collection_timeout_seconds}s"
    fi
    if [ "$ssh_status" -ne 0 ]; then
        fail "read-only SSH collection failed"
    fi

    report=$temporary
    if [ -n "$output" ]; then
        output_directory=$(dirname -- "$output")
        [ -d "$output_directory" ] ||
            fail "output directory does not exist: $output_directory"
        umask 077
        output_temporary=$(mktemp "$output_directory/.cydia-device-preflight.XXXXXX") ||
            fail "could not allocate an output file"
        cp "$temporary" "$output_temporary"
        mv "$output_temporary" "$output"
        output_temporary=
        report=$output
    fi
fi

[ -f "$report" ] || fail "report does not exist: $report"

unknown_markers=$(awk '
    /^__CYDIA_/ &&
        $0 != "__CYDIA_CAPTURE__" &&
        $0 != "__CYDIA_MEMORY__" &&
        $0 != "__CYDIA_SWAP__" &&
        $0 != "__CYDIA_ARCH__" &&
        $0 != "__CYDIA_UID__" &&
        $0 != "__CYDIA_PREFIX__" &&
        $0 != "__CYDIA_PROCESSES__" &&
        $0 != "__CYDIA_END__" { print }
' "$report")
[ -z "$unknown_markers" ] || fail "report contains an unknown section marker"

capture_marker_count=$(grep -Fxc __CYDIA_CAPTURE__ "$report" || true)
case "$capture_marker_count" in
    0)
        first_nonempty=$(awk 'NF { print; exit }' "$report")
        [ "$first_nonempty" = __CYDIA_MEMORY__ ] ||
            fail "offline report has unrecognized leading data"
        ;;
    1)
        first_nonempty=$(awk 'NF { print; exit }' "$report")
        [ "$first_nonempty" = __CYDIA_CAPTURE__ ] ||
            fail "capture metadata is not the first report section"
        capture_values=$(awk '
            $0 == "__CYDIA_CAPTURE__" { active = 1; next }
            active && /^__CYDIA_/ { exit }
            active && NF { print }
        ' "$report")
        capture_lines=$(printf '%s\n' "$capture_values" | awk 'NF { count++ } END { print count + 0 }')
        [ "$capture_lines" -eq 2 ] || fail "capture metadata is malformed"
        captured_target=$(printf '%s\n' "$capture_values" | awk -F= '$1 == "target" { sub(/^target=/, ""); print }')
        captured_time=$(printf '%s\n' "$capture_values" | awk -F= '$1 == "captured_at_utc" { sub(/^captured_at_utc=/, ""); print }')
        case "$captured_target" in
            ''|-*|*[!A-Za-z0-9_.:@-]*) fail "capture target is malformed" ;;
        esac
        printf '%s\n' "$captured_time" | awk '
            /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$/ { valid = 1 }
            END { exit !valid }
        ' || fail "capture time is malformed"
        if [ -n "$target" ]; then
            [ "$captured_target" = "$target" ] || fail "capture target changed during collection"
            [ "$captured_time" = "$captured_at_utc" ] || fail "capture time changed during collection"
        fi
        ;;
    *) fail "report has $capture_marker_count capture markers" ;;
esac

require_marker() {
    marker=$1
    count=$(grep -Fxc "$marker" "$report" || true)
    [ "$count" -eq 1 ] || fail "report has $count '$marker' marker(s)"
}

previous_line=0
for marker in __CYDIA_MEMORY__ __CYDIA_SWAP__ __CYDIA_ARCH__ __CYDIA_UID__ \
        __CYDIA_PREFIX__ __CYDIA_PROCESSES__ __CYDIA_END__; do
    require_marker "$marker"
    marker_line=$(grep -Fnx "$marker" "$report" | cut -d: -f1)
    [ "$marker_line" -gt "$previous_line" ] ||
        fail "report sections are out of order at $marker"
    previous_line=$marker_line
done
awk '
    $0 == "__CYDIA_END__" { ended = 1; next }
    ended && NF { exit 1 }
' "$report" || fail "report has data after its end marker"

free_token=$(awk '
    $0 == "__CYDIA_MEMORY__" { active = 1; next }
    active && /^__CYDIA_/ { exit }
    active && /^System-wide memory free percentage:/ {
        print $NF
        exit
    }
' "$report")
free_percent_count=$(awk '
    $0 == "__CYDIA_MEMORY__" { active = 1; next }
    active && /^__CYDIA_/ { active = 0 }
    active && /^System-wide memory free percentage:/ { count++ }
    END { print count + 0 }
' "$report")
[ "$free_percent_count" -eq 1 ] ||
    fail "memory section has $free_percent_count authoritative values"
printf '%s\n' "$free_token" | awk \
    '/^[0-9]+([.][0-9]+)?%$/ { valid = 1 } END { exit !valid }' ||
    fail "memory free percentage is missing or malformed"
free_percent=${free_token%?}

is_number() {
    awk -v value="$1" 'BEGIN {
        exit !(value ~ /^[0-9]+([.][0-9]+)?$/)
    }'
}

awk -v actual="$free_percent" 'BEGIN { exit !(actual >= 0 && actual <= 100) }' ||
    fail "memory free percentage is outside 0-100: ${free_percent}%"

swap_token=$(awk '
    $0 == "__CYDIA_SWAP__" { active = 1; next }
    active && /^__CYDIA_/ { exit }
    active && /^vm[.]swapusage:/ {
        for (field = 1; field <= NF; ++field) {
            if ($field == "used" && $(field + 1) == "=") {
                print $(field + 2)
                exit
            }
        }
    }
' "$report")
swap_value_count=$(awk '
    $0 == "__CYDIA_SWAP__" { active = 1; next }
    active && /^__CYDIA_/ { active = 0 }
    active && /^vm[.]swapusage:/ { count++ }
    END { print count + 0 }
' "$report")
[ "$swap_value_count" -eq 1 ] ||
    fail "swap section has $swap_value_count authoritative values"
swap_section_lines=$(awk '
    $0 == "__CYDIA_SWAP__" { active = 1; next }
    active && /^__CYDIA_/ { active = 0 }
    active && NF { count++ }
    END { print count + 0 }
' "$report")
[ "$swap_section_lines" -eq 1 ] ||
    fail "swap section contains unexpected data"

case "$swap_token" in
    *[Kk]) swap_value=${swap_token%?}; swap_factor=0.0009765625 ;;
    *[Mm]) swap_value=${swap_token%?}; swap_factor=1 ;;
    *[Gg]) swap_value=${swap_token%?}; swap_factor=1024 ;;
    *) fail "swap usage is missing or has an unsupported unit" ;;
esac
is_number "$swap_value" || fail "swap usage is malformed: $swap_token"
swap_used_mb=$(awk -v value="$swap_value" -v factor="$swap_factor" \
    'BEGIN { printf "%.2f", value * factor }')

section_value() {
    begin=$1
    awk -v begin="$begin" '
        $0 == begin { active = 1; next }
        active && /^__CYDIA_/ { exit }
        active && NF { print; exit }
    ' "$report"
}

architecture=$(section_value __CYDIA_ARCH__)
remote_uid=$(section_value __CYDIA_UID__)
prefix=$(section_value __CYDIA_PREFIX__)
section_line_count() {
    begin=$1
    awk -v begin="$begin" '
        $0 == begin { active = 1; next }
        active && /^__CYDIA_/ { active = 0 }
        active && NF { count++ }
        END { print count + 0 }
    ' "$report"
}
[ "$(section_line_count __CYDIA_ARCH__)" -eq 1 ] ||
    fail "architecture section does not contain exactly one value"
[ "$(section_line_count __CYDIA_UID__)" -eq 1 ] ||
    fail "UID section does not contain exactly one value"
[ "$(section_line_count __CYDIA_PREFIX__)" -eq 1 ] ||
    fail "layout section does not contain exactly one value"
[ "$architecture" = "$expected_architecture" ] ||
    fail "device architecture is '$architecture' (expected $expected_architecture)"
[ "$remote_uid" = 0 ] ||
    fail "remote process snapshot was collected as UID '$remote_uid' (root required)"
[ "$prefix" = "$expected_prefix" ] ||
    fail "device layout is '$prefix' (expected $expected_prefix)"

busy_processes=$(awk '
    $0 == "__CYDIA_PROCESSES__" { active = 1; next }
    active && /^__CYDIA_/ { active = 0 }
    active && NF >= 2 {
        name = $2
        sub(/^.*\//, "", name)
        if (name ~ /^(apt|dpkg|cydo)/)
            print $0
    }
' "$report")
[ -z "$busy_processes" ] || {
    printf '%s\n' "$busy_processes" >&2
    fail "a package-manager process is active"
}

awk '
    $0 == "__CYDIA_PROCESSES__" { active = 1; next }
    active && /^__CYDIA_/ { active = 0 }
    active && NF {
        lines++
        if (NF < 2 || $1 !~ /^[0-9]+$/)
            malformed = 1
    }
    END { exit !(lines > 0 && !malformed) }
' "$report" || fail "process inventory is empty or malformed"

awk -v actual="$free_percent" -v minimum="$minimum_free_percent" \
    'BEGIN { exit !(actual >= minimum) }' ||
    fail "free memory is ${free_percent}% (minimum ${minimum_free_percent}%)"
awk -v value="$swap_value" -v factor="$swap_factor" \
        -v maximum="$maximum_swap_used_mb" \
    'BEGIN { exit !((value * factor) <= maximum) }' ||
    fail "swap use is $swap_token (${swap_used_mb} MB; maximum ${maximum_swap_used_mb} MB)"

if [ -n "$target" ]; then
    echo "[verify-device-preflight][ ok ] live root-UID $layout capture for $target at $captured_at_utc: ${free_percent}% free, ${swap_used_mb} MB swap used; no apt/dpkg/cydo process observed"
else
    echo "[verify-device-preflight][ ok ] offline root-UID $layout report validated: ${free_percent}% free, ${swap_used_mb} MB swap used; no apt/dpkg/cydo process observed (not current device evidence)"
fi
