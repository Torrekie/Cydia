#!/bin/sh
# Syntax-check Cydia's APT compatibility surface against a pre-fetched tree.

set -u

fail() {
    echo "[verify-apt-api][FAIL] $*" >&2
    exit 1
}

apt_usage() {
    echo "usage: $0 SOURCE_DIR COMPILER SDK KIND ARCH DEPLOYMENT CXX_STANDARD GENERATED_DIR ICU_INCLUDE_DIR SOURCE..." >&2
    exit 2
}

# Keep the source manifest honest.  This intentionally uses a conservative
# token scan: a newly added translation unit that mentions an APT type must be
# added to the canary list, and a moved consumer must be removed from it.
if [ "${1-}" = inventory ]; then
    [ "$#" -ge 3 ] || {
        echo "usage: $0 inventory 'MANIFEST SOURCES' CANDIDATE_SOURCE..." >&2
        exit 2
    }

    manifest=$2
    shift 2
    pattern='(^|[^[:alnum:]_])(pkg(Cache|DepCache|Acquire|Records|Policy|ProblemResolver|SourceList|PackageManager|CacheFile|ArchiveCleaner)|_error|_config|_system)([^[:alnum:]_]|$)|CydiaAPT::[[:alnum:]_]+|#include[[:space:]]*[<"]apt-pkg/|#include[[:space:]]*[<"]apt\.h'
    count=0

    for listed in $manifest; do
        [ -f "$listed" ] || fail "manifest source does not exist: $listed"
        grep -Eq "$pattern" "$listed" ||
            fail "manifest source no longer exposes an APT dependency: $listed"
        count=$((count + 1))
    done

    for candidate in "$@"; do
        [ -f "$candidate" ] || continue
        if grep -Eq "$pattern" "$candidate"; then
            case " $manifest " in
                *" $candidate "*) ;;
                *) fail "APT consumer is missing from manifest: $candidate" ;;
            esac
        fi
    done

    echo "[verify-apt-api][ ok ] reviewed manifest covers $count APT consumer(s)"
    exit 0
fi

[ "$#" -ge 10 ] || apt_usage

source_dir=$1
compiler=$2
sdk=$3
kind=$4
arch=$5
deployment=$6
cxx_standard=$7
generated_dir=$8
icu_include_dir=$9
shift 9
[ "$#" -gt 0 ] || apt_usage

temporary=
cleanup() {
    [ -z "$temporary" ] || rm -rf "$temporary"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

source_dir=$(cd "$source_dir" 2>/dev/null && pwd -P) ||
    fail "could not resolve APT source directory: $source_dir"
[ -d "$source_dir/apt-pkg" ] || fail "missing APT source directory: $source_dir/apt-pkg"
[ -f "$source_dir/apt-pkg/contrib/macros.h" ] || fail "missing APT ABI header"

for source_file in "$@"; do
    [ -f "$source_file" ] || fail "missing compatibility source: $source_file"
done

commit=$(git -C "$source_dir" rev-parse HEAD 2>/dev/null) ||
    fail "$source_dir is not a git checkout"
changes=$(git -C "$source_dir" status --porcelain --untracked-files=all 2>/dev/null) ||
    fail "could not inspect $source_dir"
[ -z "$changes" ] || fail "APT audit checkout is dirty"

major=$(awk '$1 == "#define" && $2 == "APT_PKG_MAJOR" { print $3; exit }' \
    "$source_dir/apt-pkg/contrib/macros.h")
minor=$(awk '$1 == "#define" && $2 == "APT_PKG_MINOR" { print $3; exit }' \
    "$source_dir/apt-pkg/contrib/macros.h")
[ -n "$major" ] && [ -n "$minor" ] || fail "could not read APT ABI"

# Keep the audit command honest when it is pointed at a newer checkout.  APT
# currently declares its required language level in the top-level CMake file;
# map Clang's spelling for C++23 (c++2b) to the same numeric level.
required_level=$(sed -n \
    's/^[[:space:]]*set(CMAKE_CXX_STANDARD[[:space:]]*\([0-9][0-9]*\)).*/\1/p' \
    "$source_dir/CMakeLists.txt" 2>/dev/null | head -n 1)
case "$cxx_standard" in
    c++11|gnu++11) selected_level=11;;
    c++14|gnu++14) selected_level=14;;
    c++17|gnu++17) selected_level=17;;
    c++20|gnu++20) selected_level=20;;
    c++2b|gnu++2b|c++23|gnu++23) selected_level=23;;
    *) fail "unsupported C++ standard spelling: $cxx_standard"; selected_level=0;;
esac
if [ -n "$required_level" ] && [ "$selected_level" -lt "$required_level" ]; then
    fail "C++ standard $cxx_standard is below APT's required C++$required_level"
fi

temporary_root=${TMPDIR:-/tmp}
temporary=$(mktemp -d "$temporary_root/cydia-apt-api.XXXXXX") ||
    fail "could not create temporary include roots"
mkdir -p "$temporary/contrib" "$temporary/deb" ||
    fail "could not create temporary include roots"
ln -s "$source_dir/apt-pkg/contrib" "$temporary/contrib/apt-pkg" ||
    fail "could not create contrib include root"
ln -s "$source_dir/apt-pkg/deb" "$temporary/deb/apt-pkg" ||
    fail "could not create deb include root"

status=0
for source_file in "$@"; do
    log_name=$(printf '%s' "$source_file" | tr '/ ' '__')
    log_file="$temporary/$log_name.log"
    "$compiler" \
        "-std=$cxx_standard" \
        -fsyntax-only \
        -fobjc-arc \
        -fobjc-call-cxx-cdtors \
        -arch "$arch" \
        "-m$kind-version-min=$deployment" \
        -isysroot "$sdk" \
        -DAPT_PKG_EXPOSE_STRING_VIEW \
        -Dsighandler_t=sig_t \
        -I"$source_dir" \
        -I"$temporary/contrib" \
        -I"$temporary/deb" \
        -Iapt-extra \
        -I. \
        -I"$generated_dir" \
        -isystem sysroot/usr/include \
        -idirafter "$icu_include_dir" \
        -idirafter icu/icuSources/common \
        -idirafter icu/icuSources/i18n \
        -Wno-deprecated-declarations \
        -Wno-unknown-warning-option \
        -include system.h \
        -include apt.h \
        "$source_file" >"$log_file" 2>&1
    if [ "$?" -ne 0 ]; then
        status=1
        echo "[verify-apt-api][FAIL] $source_file" >&2
        grep -m 8 -E 'error:|fatal error:' "$log_file" >&2 || tail -n 40 "$log_file" >&2
    fi
done

[ "$status" -eq 0 ] || exit "$status"
echo "[verify-apt-api][ ok ] $* accept APT ABI $major.$minor at $commit ($cxx_standard)"
