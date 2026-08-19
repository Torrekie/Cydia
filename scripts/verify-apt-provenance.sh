#!/bin/sh
# Copyright (C) 2026 Torrekie
# SPDX-License-Identifier: GPL-3.0-or-later
# Verify the embedded APT gitlink, source metadata, and reviewed source groups.

set -u

if [ "$#" -eq 0 ]; then
    echo "usage: $0 {provenance|sources} ..." >&2
    exit 2
fi
mode=$1
shift
failures=0
temporary=

fail() {
    echo "[verify-apt][FAIL] $*" >&2
    failures=$((failures + 1))
}

pass() {
    echo "[verify-apt][ ok ] $*"
}

cleanup() {
    [ -z "$temporary" ] || rm -rf "$temporary"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

read_define() {
    file=$1
    name=$2
    awk -v name="$name" \
        '$1 == "#define" && $2 == name { print $3; exit }' "$file"
}

check_equal() {
    label=$1
    actual=$2
    expected=$3
    if [ "$actual" = "$expected" ]; then
        pass "$label is $expected"
    else
        fail "$label is '$actual' (expected '$expected')"
    fi
}

check_provenance() {
    if [ "$#" -ne 12 ]; then
        fail "provenance expects 12 arguments"
        return
    fi

    source_dir=$1
    expected_commit=$2
    expected_url=$3
    expected_version=$4
    expected_cxx_level=$5
    source_trust=$6
    expected_major=$7
    expected_minor=$8
    expected_release=$9
    shift 9
    license_files=$1
    shift
    contrib_include_dir=$1
    deb_include_dir=$2

    case "$source_trust" in
        legacy-unverified)
            echo "[verify-apt][WARN] embedded APT provenance is legacy-unverified"
            ;;
        *)
            fail "unsupported APT provenance trust state: $source_trust"
            ;;
    esac

    if ! git -C "$source_dir" rev-parse --git-dir >/dev/null 2>&1; then
        fail "$source_dir is not an initialized git worktree"
        return
    fi

    gitlink=$(git ls-files -s -- "$source_dir" |
        awk '$1 == "160000" { print $2; exit }')
    if [ -z "$gitlink" ]; then
        fail "$source_dir is not a tracked gitlink"
    else
        check_equal "recorded gitlink" "$gitlink" "$expected_commit"
    fi

    checkout=$(git -C "$source_dir" rev-parse HEAD 2>/dev/null || true)
    check_equal "checked-out APT commit" "$checkout" "$expected_commit"

    changes=$(git -C "$source_dir" status --porcelain --untracked-files=all 2>/dev/null || true)
    if [ -z "$changes" ]; then
        pass "embedded APT checkout is clean"
    else
        echo "$changes" >&2
        fail "embedded APT checkout has local changes"
    fi

    submodule_name=$(git config -f .gitmodules --get-regexp '^submodule\..*\.path$' |
        awk -v path="$source_dir" '$2 == path {
            name = $1
            sub(/^submodule\./, "", name)
            sub(/\.path$/, "", name)
            print name
            exit
        }')
    if [ -z "$submodule_name" ]; then
        fail "no .gitmodules entry points to $source_dir"
    else
        source_url=$(git config -f .gitmodules --get "submodule.$submodule_name.url" || true)
        check_equal "APT source URL" "$source_url" "$expected_url"
    fi

    cmake_file=$source_dir/CMakeLists.txt
    macros_file=$source_dir/apt-pkg/contrib/macros.h
    if [ ! -f "$cmake_file" ]; then
        fail "missing APT version source: $cmake_file"
    else
        version=$(sed -n \
            's/^[[:space:]]*set(PACKAGE_VERSION[[:space:]]*"\([^"]*\)").*/\1/p' \
            "$cmake_file" | head -n 1)
        check_equal "APT package version" "$version" "$expected_version"
        cxx_level=$(sed -n \
            's/^[[:space:]]*set(CMAKE_CXX_STANDARD[[:space:]]*\([0-9][0-9]*\)).*/\1/p' \
            "$cmake_file" | head -n 1)
        check_equal "APT C++ standard level" "$cxx_level" "$expected_cxx_level"
    fi

    if [ ! -f "$macros_file" ]; then
        fail "missing APT ABI source: $macros_file"
    else
        major=$(read_define "$macros_file" APT_PKG_MAJOR)
        minor=$(read_define "$macros_file" APT_PKG_MINOR)
        release=$(read_define "$macros_file" APT_PKG_RELEASE)
        check_equal "APT ABI major" "$major" "$expected_major"
        check_equal "APT ABI minor" "$minor" "$expected_minor"
        check_equal "APT library release component" "$release" "$expected_release"
    fi

    for license in $license_files; do
        if [ -f "$source_dir/$license" ]; then
            pass "APT license input exists: $license"
        else
            fail "missing APT license input: $source_dir/$license"
        fi
    done

    source_contrib=$(cd "$source_dir/apt-pkg/contrib" 2>/dev/null && pwd -P || true)
    overlay_contrib=$(cd "$contrib_include_dir" 2>/dev/null && pwd -P || true)
    source_deb=$(cd "$source_dir/apt-pkg/deb" 2>/dev/null && pwd -P || true)
    overlay_deb=$(cd "$deb_include_dir" 2>/dev/null && pwd -P || true)
    check_equal "APT contrib include target" "$overlay_contrib" "$source_contrib"
    check_equal "APT deb include target" "$overlay_deb" "$source_deb"
}

write_list() {
    values=$1
    destination=$2
    : >"$destination"
    for value in $values; do
        printf '%s\n' "$value"
    done | LC_ALL=C sort >"$destination"
}

is_excluded() {
    candidate=$1
    exclusions=$2
    for exclusion in $exclusions; do
        [ "$candidate" = "$exclusion" ] && return 0
    done
    return 1
}

discover_sources() {
    directory=$1
    exclusions=$2
    destination=$3
    : >"$destination"
    for path in "$directory"/*.cc; do
        [ -f "$path" ] || continue
        name=$(basename "$path")
        is_excluded "$name" "$exclusions" || printf '%s\n' "$name"
    done | LC_ALL=C sort >"$destination"
}

check_source_group() {
    label=$1
    directory=$2
    expected_values=$3
    exclusions=$4
    expected_file=$temporary/$label.expected
    actual_file=$temporary/$label.actual

    write_list "$expected_values" "$expected_file"
    discover_sources "$directory" "$exclusions" "$actual_file"

    duplicates=$(printf '%s\n' $expected_values | LC_ALL=C sort | uniq -d)
    if [ -n "$duplicates" ]; then
        echo "$duplicates" >&2
        fail "$label manifest contains duplicate names"
    elif diff -u "$expected_file" "$actual_file" >/dev/null 2>&1; then
        count=$(wc -l <"$expected_file" | tr -d ' ')
        pass "$label manifest explicitly covers $count source(s)"
    else
        diff -u "$expected_file" "$actual_file" >&2 || true
        fail "$label manifest differs from the embedded APT tree"
    fi
}

check_sources() {
    if [ "$#" -ne 8 ]; then
        fail "sources expects 8 arguments"
        return
    fi

    source_dir=$1
    core_sources=$2
    deb_sources=$3
    contrib_sources=$4
    method_sources=$5
    excluded_contrib_sources=$6
    http_source=$7
    excluded_method_sources=$8

    temporary_root=$(env | sed -n 's/^TMPDIR=//p' | head -n 1)
    [ -n "$temporary_root" ] || temporary_root=/tmp
    temporary=$(mktemp -d "$temporary_root/cydia-apt-verify.XXXXXX") || {
        fail "could not create a temporary verification directory"
        return
    }

    check_source_group core "$source_dir/apt-pkg" "$core_sources" ""
    check_source_group deb "$source_dir/apt-pkg/deb" "$deb_sources" ""
    check_source_group contrib "$source_dir/apt-pkg/contrib" \
        "$contrib_sources" "$excluded_contrib_sources"

    for exclusion in $excluded_contrib_sources; do
        if [ -f "$source_dir/apt-pkg/contrib/$exclusion" ]; then
            pass "reviewed APT exclusion still exists: $exclusion"
        else
            fail "stale APT exclusion: $exclusion"
        fi
    done

    check_source_group methods "$source_dir/methods" \
        "$method_sources $http_source" "$excluded_method_sources"
    for exclusion in $excluded_method_sources; do
        if [ -f "$source_dir/methods/$exclusion" ]; then
            pass "reviewed APT method exclusion still exists: $exclusion"
        else
            fail "stale APT method exclusion: $exclusion"
        fi
    done
}

case "$mode" in
    provenance)
        check_provenance "$@"
        ;;
    sources)
        check_sources "$@"
        ;;
    *)
        echo "usage: $0 {provenance|sources} ..." >&2
        exit 2
        ;;
esac

if [ "$failures" -ne 0 ]; then
    echo "[verify-apt] $failures check(s) failed" >&2
    exit 1
fi
exit 0
