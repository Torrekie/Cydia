#!/bin/sh
# Syntax-check Cydia's private adapter against a pre-fetched APT source tree.

set -u

if [ "$#" -ne 8 ]; then
    echo "usage: $0 SOURCE_DIR COMPILER SDK KIND ARCH DEPLOYMENT CXX_STANDARD SOURCE" >&2
    exit 2
fi

source_dir=$1
compiler=$2
sdk=$3
kind=$4
arch=$5
deployment=$6
cxx_standard=$7
adapter_source=$8
temporary=

cleanup() {
    [ -z "$temporary" ] || rm -rf "$temporary"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

fail() {
    echo "[verify-apt-api][FAIL] $*" >&2
    exit 1
}

source_dir=$(cd "$source_dir" 2>/dev/null && pwd -P) ||
    fail "could not resolve APT source directory: $source_dir"
[ -d "$source_dir/apt-pkg" ] || fail "missing APT source directory: $source_dir/apt-pkg"
[ -f "$source_dir/apt-pkg/contrib/macros.h" ] || fail "missing APT ABI header"
[ -f "$adapter_source" ] || fail "missing adapter source: $adapter_source"

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

"$compiler" \
    "-std=$cxx_standard" \
    -fsyntax-only \
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
    -include apt.h \
    "$adapter_source" || fail "adapter does not compile against APT ABI $major.$minor"

echo "[verify-apt-api][ ok ] adapter accepts APT ABI $major.$minor at $commit ($cxx_standard)"
