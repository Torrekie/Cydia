#!/bin/sh
# Copyright (C) 2026 Torrekie
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

fail() {
    echo "[verify-exec-compat][FAIL] $*" >&2
    exit 1
}

pass() {
    echo "[verify-exec-compat][ ok ] $*"
}

require_line() {
    expected=$1
    file=$2
    grep -F -x "$expected" "$file" >/dev/null ||
        fail "$file is missing: $expected"
}

mode=${1-}
[ "$#" -gt 0 ] && shift

case "$mode" in
    provenance)
        [ "$#" -eq 13 ] || fail "provenance expects 13 arguments"
        source_dir=$1
        expected_commit=$2
        expected_url=$3
        expected_sources=$4
        expected_license=$5
        expected_copyright=$6
        provenance_stamp=$7
        config_stamp=$8
        layout=$9
        package_prefix=${10}
        expected_redirect=${11}
        expected_default_path=${12}
        expected_standard_path=${13}

        [ -f "$source_dir/$expected_license" ] ||
            fail "missing libiosexec license: $source_dir/$expected_license"
        [ -f "$source_dir/$expected_copyright" ] ||
            fail "missing libiosexec copyright classification: $source_dir/$expected_copyright"
        actual_commit=$(git -C "$source_dir" rev-parse HEAD 2>/dev/null || true)
        [ "$actual_commit" = "$expected_commit" ] ||
            fail "libiosexec is $actual_commit; expected $expected_commit"
        gitlink=$(git ls-files --stage "$source_dir" | awk 'NR == 1 { print $1 " " $2 }')
        [ "$gitlink" = "160000 $expected_commit" ] ||
            fail "libiosexec gitlink is $gitlink"
        [ -z "$(git -C "$source_dir" status --porcelain --untracked-files=all)" ] ||
            fail "libiosexec source tree is dirty"
        configured_url=$(git config -f .gitmodules --get submodule.libiosexec.url || true)
        [ "$configured_url" = "$expected_url" ] ||
            fail "libiosexec submodule URL is $configured_url"
        [ "$expected_sources" = "execv.c get_new_argv.c utils.c" ] ||
            fail "unexpected static source manifest: $expected_sources"

        require_line "source-dir=$source_dir" "$provenance_stamp"
        require_line "source-url=$expected_url" "$provenance_stamp"
        require_line "commit=$expected_commit" "$provenance_stamp"
        require_line "source-files=$expected_sources" "$provenance_stamp"
        require_line "license=$expected_license" "$provenance_stamp"
        require_line "copyright=$expected_copyright" "$provenance_stamp"
        grep -E '^tree-state=[0-9]+:[0-9]+$' "$provenance_stamp" >/dev/null ||
            fail "$provenance_stamp has no source-tree checksum"

        require_line "layout=$layout" "$config_stamp"
        require_line "package-prefix=$package_prefix" "$config_stamp"
        require_line "shebang-redirect=$expected_redirect" "$config_stamp"
        require_line "default-path=$expected_default_path" "$config_stamp"
        require_line "standard-path=$expected_standard_path" "$config_stamp"
        require_line "deployment-target=12.0" "$config_stamp"
        grep -F -x 'architecture=arm64' "$config_stamp" >/dev/null ||
            fail "$config_stamp does not target arm64"
        grep -E '^compiler=.+$' "$config_stamp" >/dev/null ||
            fail "$config_stamp does not record the compiler"
        grep -E '^config-state=[0-9]+:[0-9]+$' "$config_stamp" >/dev/null ||
            fail "$config_stamp has no Make configuration checksum"
        pass "$layout source, gitlink, provenance, and iOS 12 configuration"
        ;;
    archive)
        [ "$#" -eq 2 ] || fail "archive expects <ar> <archive>"
        archive_tool=$1
        archive=$2
        [ -f "$archive" ] || fail "missing archive: $archive"
        members=$("$archive_tool" t "$archive" | grep -v '^__[.]SYMDEF' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')
        [ "$members" = "execv.o get_new_argv.o utils.o" ] ||
            fail "$archive contains unexpected objects: $members"
        pass "$archive contains only the reviewed exec shim objects"
        ;;
    binary)
        [ "$#" -eq 3 ] || fail "binary expects <nm> <otool> <cydo>"
        nm_tool=$1
        otool_tool=$2
        binary=$3
        [ -f "$binary" ] || fail "missing cydo binary: $binary"

        symbols=$("$nm_tool" "$binary")
        printf '%s\n' "$symbols" | grep -E '[[:space:]][Tt][[:space:]]+_ie_execv$' >/dev/null ||
            fail "cydo does not define ie_execv"
        printf '%s\n' "$symbols" | grep -E '[[:space:]][Tt][[:space:]]+_ie_execve$' >/dev/null ||
            fail "cydo does not define ie_execve"
        undefined_ie=$(printf '%s\n' "$symbols" | awk 'NF >= 2 && $(NF - 1) == "U" && $NF ~ /^_ie_/ { print $NF }')
        [ -z "$undefined_ie" ] ||
            fail "cydo has undefined libiosexec symbols: $undefined_ie"

        loads=$("$otool_tool" -L "$binary")
        if printf '%s\n' "$loads" | grep -E 'lib(iosexec|recompat)' >/dev/null; then
            fail "cydo dynamically loads libiosexec or librecompat"
        fi
        commands=$("$otool_tool" -l "$binary")
        if printf '%s\n' "$commands" | grep -F 'LC_RPATH' >/dev/null; then
            fail "cydo unexpectedly contains an LC_RPATH command"
        fi
        if ! printf '%s\n' "$commands" | awk '
            $1 == "cmd" && ($2 == "LC_BUILD_VERSION" || $2 == "LC_VERSION_MIN_IPHONEOS") { in_version = 1; next }
            in_version && (($1 == "minos" || $1 == "version") && $2 == "12.0") { found = 1 }
            in_version && $1 == "cmd" { in_version = 0 }
            END { exit found ? 0 : 1 }
        '; then
            fail "cydo does not declare iOS 12.0 as its minimum version"
        fi
        pass "cydo embeds exec shims with no compatibility dylib or rpath"
        ;;
    *)
        echo "usage: $0 {provenance|archive|binary} ..." >&2
        exit 2
        ;;
esac
