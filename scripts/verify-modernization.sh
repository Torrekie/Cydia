#!/bin/sh
# Static and command-graph checks for the Makefile-based Cydia build.
#
# This intentionally uses only POSIX shell utilities already present on the
# host.  The source list is supplied by mk/verify.mk so that the verifier and
# the build cannot silently drift apart.

set -u

mode=${1-}
shift || true
failures=0

fail() {
    echo "[verify][FAIL] $*" >&2
    failures=$((failures + 1))
}

pass() {
    echo "[verify][ ok ] $*"
}

contains() {
    # POSIX shell pattern matching is sufficient for the short command lines
    # emitted by make -n.  The caller supplies the haystack and needle.
    case "$1" in
        *"$2"*) return 0 ;;
        *) return 1 ;;
    esac
}

check_no_forbidden_arc_flag() {
    file=$1
    if grep -n -E -- '-fno-objc-arc([[:space:]]|$)' "$file" >/dev/null 2>&1; then
        grep -n -E -- '-fno-objc-arc([[:space:]]|$)' "$file" >&2 || true
        fail "$file contains -fno-objc-arc"
    fi
}

check_command_arc() {
    make_program=$1
    target=$2
    source_name=$3
    label=$4
    expected_arch=$5
    expected_deployment=$6
    output=$(mktemp "${TMPDIR:-/tmp}/cydia-verify.XXXXXX") || {
        fail "could not create a temporary file for $label"
        return
    }

    if ! "$make_program" --no-print-directory -Bn "$target" >"$output" 2>&1; then
        sed -n '1,80p' "$output" >&2
        fail "$label dry-run could not be generated"
        rm -f "$output"
        return
    fi

    # Select the recipe line which both mentions the source and emits an
    # output.  This avoids mistaking the informational [cycc] echo for the
    # compiler invocation.
    command=$(awk -v source="$source_name" \
        'index($0, source) && $0 ~ /(^|[[:space:]])-o[[:space:]]/ { print; exit }' \
        "$output")
    if [ -z "$command" ]; then
        fail "$label dry-run has no command for $source_name"
    else
        if contains "$command" "-fno-objc-arc"; then
            fail "$label command contains -fno-objc-arc"
        elif ! contains "$command" "-fobjc-arc"; then
            fail "$label command is missing -fobjc-arc"
        elif contains "$command" "-target $expected_arch-apple-ios$expected_deployment"; then
            pass "$label command uses ARC, $expected_arch, and iOS $expected_deployment"
        elif ! contains "$command" "-arch $expected_arch"; then
            fail "$label command is missing an $expected_arch target flag"
        elif ! contains "$command" "-miphoneos-version-min=$expected_deployment"; then
            fail "$label command is missing iOS $expected_deployment deployment flag"
        else
            pass "$label command uses ARC, $expected_arch, and iOS $expected_deployment"
        fi
    fi
    rm -f "$output"
}

check_config() {
    deployment=$1
    device_arch=$2
    arc_flag=$3
    make_program=$4
    object_dir=$5
    postinst_binary=$6
    cfversion_binary=$7
    makefiles=$8

    if [ "$deployment" = "12.0" ]; then
        pass "deployment target is exactly iOS 12.0"
    else
        fail "deployment target is '$deployment' (expected 12.0)"
    fi

    if [ "$device_arch" = "arm64" ]; then
        pass "device architecture is arm64"
    else
        fail "device architecture is '$device_arch' (expected arm64)"
    fi

    if [ "$arc_flag" = "-fobjc-arc" ]; then
        pass "Make ARC flag is -fobjc-arc"
    else
        fail "Make ARC flag is '$arc_flag' (expected -fobjc-arc)"
    fi

    for makefile in $makefiles; do
        if [ -f "$makefile" ]; then
            check_no_forbidden_arc_flag "$makefile"
        fi
    done

    # Exercise both pattern rules and the two direct Objective-C++ helper
    # commands.  SDURLCache is intentionally included: although it remains a
    # vendored source for the line-size check, it is a supported build input
    # and must still compile as ARC.
    check_command_arc "$make_program" "$object_dir/SDURLCache/SDURLCache.o" \
        "SDURLCache/SDURLCache.m" "Objective-C pattern rule" "$device_arch" "$deployment"
    check_command_arc "$make_program" "$object_dir/Version.o" \
        "Version.mm" "Objective-C++ pattern rule" "$device_arch" "$deployment"
    check_command_arc "$make_program" "$postinst_binary" \
        "postinst.mm" "postinst helper" "$device_arch" "$deployment"
    check_command_arc "$make_program" "$cfversion_binary" \
        "cfversion.mm" "cfversion helper" "$device_arch" "$deployment"
}

check_ownership() {
    # These are actual MRC constructs, rather than the words "retain" or
    # "release" in comments, API names, or Core Foundation calls.  A source
    # may use custom methods named retainNetworkActivityIndicator, but may not
    # send retain/release/autorelease to an Objective-C object.
    if [ "$#" -eq 0 ]; then
        fail "no supported Objective-C sources were supplied"
        return
    fi

    for file in "$@"; do
        [ -f "$file" ] || {
            fail "supported source is missing: $file"
            continue
        }
        hits=$(grep -n -E \
            '\[[^]]+[[:space:]](retain|release|autorelease)\][[:space:]]*;|\[super[[:space:]]+dealloc\][[:space:]]*;|NSAutoreleasePool|@property[^[:cntrl:]]*\([^)]*[[:space:],]retain([[:space:],)])|#if[[:space:]]*!?[[:space:]]*__has_feature\([[:space:]]*objc_arc[[:space:]]*\)' \
            "$file" 2>/dev/null || true)
        if [ -n "$hits" ]; then
            echo "$hits" >&2
            fail "$file contains explicit MRC or an ARC/MRC conditional"
        fi
    done
    [ "$failures" -eq 0 ] && pass "supported Objective-C sources contain no explicit MRC constructs"
}

check_size() {
    max_lines=$1
    shift
    case "$max_lines" in
        ''|*[!0-9]*) fail "maximum source line threshold is not an integer: $max_lines"; return ;;
    esac
    [ "$#" -gt 0 ] || { fail "no supported sources were supplied for line-size check"; return; }

    oversized=0
    for file in "$@"; do
        [ -f "$file" ] || { fail "supported source is missing: $file"; continue; }
        lines=$(wc -l < "$file")
        # Command substitution removes the surrounding whitespace emitted by
        # wc, leaving a portable decimal value for the arithmetic comparison.
        if [ "$lines" -gt "$max_lines" ]; then
            echo "[verify][FAIL] $file has $lines lines (maximum $max_lines)" >&2
            oversized=$((oversized + 1))
        fi
    done
    if [ "$oversized" -eq 0 ] && [ "$failures" -eq 0 ]; then
        pass "supported app-owned sources are at most $max_lines lines"
    elif [ "$oversized" -gt 0 ]; then
        failures=$((failures + oversized))
    fi
}

case "$mode" in
    config)
        # The final argument is a space-separated list of Make fragments.  All
        # paths in this repository are space-free, so this remains POSIX-safe.
        [ "$#" -eq 8 ] || { fail "config expects 8 arguments"; exit 2; }
        check_config "$@"
        ;;
    ownership)
        check_ownership "$@"
        ;;
    size)
        [ "$#" -ge 1 ] || { fail "size expects a threshold"; exit 2; }
        check_size "$@"
        ;;
    *)
        echo "usage: $0 {config|ownership|size} ..." >&2
        exit 2
        ;;
esac

if [ "$failures" -ne 0 ]; then
    echo "[verify] $failures check(s) failed" >&2
    exit 1
fi
exit 0
