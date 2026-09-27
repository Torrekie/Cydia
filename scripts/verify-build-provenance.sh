#!/usr/bin/env bash
# Copyright (C) 2026 Torrekie
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

fail() {
    echo "[verify-build-provenance][FAIL] $*" >&2
    exit 1
}

usage() {
    echo "usage: $0 {record|verify} <source-root> <app-binary> <version-header> <provenance-stamp>" >&2
    exit 2
}

[ "$#" -eq 5 ] || usage

mode=$1
source_root=$2
binary=$3
header=$4
stamp=$5

case "$mode" in
    record|verify) ;;
    *) usage ;;
esac

[ -d "$source_root" ] || fail "source root does not exist: $source_root"
source_root=$(cd "$source_root" && pwd -P)

resolve_path() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *) printf '%s/%s\n' "$source_root" "$1" ;;
    esac
}

binary=$(resolve_path "$binary")
header=$(resolve_path "$header")
stamp=$(resolve_path "$stamp")

[ -f "$binary" ] || fail "app binary does not exist: $binary"
[ -f "$header" ] || fail "generated Version.h does not exist: $header"

hash_file() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{ print $1 }'
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{ print $1 }'
    else
        fail "neither shasum nor sha256sum is available"
    fi
}

current_version=$(cd "$source_root" && ./version.sh) ||
    fail "could not derive the current source version"
[ -n "$current_version" ] || fail "current source version is empty"

header_version=$(awk '
    $1 == "#define" && $2 == "CYDIA_VERSION" {
        count++
        if ($0 !~ /^#define CYDIA_VERSION "[^"]*"$/)
            malformed=1
        line=$0
        sub(/^#define CYDIA_VERSION "/, "", line)
        sub(/"$/, "", line)
        value=line
    }
    END {
        if (count != 1 || malformed)
            exit 1
        print value
    }
' "$header") || fail "Version.h does not contain exactly one valid CYDIA_VERSION definition"

[ "$header_version" = "$current_version" ] ||
    fail "Version.h version $header_version does not match current source version $current_version"

command -v strings >/dev/null 2>&1 || fail "strings is unavailable"
if ! LC_ALL=C strings "$binary" | grep -F -x "$current_version" >/dev/null; then
    fail "app binary does not embed current source version $current_version"
fi

source_commit=$(git -C "$source_root" rev-parse HEAD 2>/dev/null) ||
    fail "source root is not a Git checkout"

source_tree_hash() {
    local state_file
    state_file=$(mktemp "${TMPDIR:-/tmp}/cydia-build-source.XXXXXX") ||
        fail "could not allocate a source-state scratch file"
    {
        printf 'commit=%s\n' "$source_commit"
        printf '%s\n' 'diff-begin'
        git -C "$source_root" diff --no-ext-diff --binary HEAD --
        printf '%s\n' 'diff-end'
        printf '%s\n' 'untracked-begin'
        while IFS= read -r -d '' path; do
            printf 'path=%s\n' "$path"
            printf 'sha256=%s\n' "$(hash_file "$source_root/$path")"
        done < <(git -C "$source_root" ls-files --others --exclude-standard -z)
        printf '%s\n' 'untracked-end'
    } >"$state_file"
    local digest
    digest=$(hash_file "$state_file")
    rm -f -- "$state_file"
    printf '%s\n' "$digest"
}

source_tree=$(source_tree_hash)
header_hash=$(hash_file "$header")
binary_hash=$(hash_file "$binary")

stamp_value() {
    local key=$1
    awk -F= -v wanted="$key" '
        $1 == wanted {
            count++
            value=substr($0, length(wanted) + 2)
        }
        END {
            if (count != 1)
                exit 1
            print value
        }
    ' "$stamp"
}

validate_stamp() {
    awk -F= '
        BEGIN {
            allowed["schema"] = 1
            allowed["source-commit"] = 1
            allowed["source-tree-sha256"] = 1
            allowed["version"] = 1
            allowed["version-header-sha256"] = 1
            allowed["binary-sha256"] = 1
        }
        NF < 2 || !($1 in allowed) || ++seen[$1] != 1 {
            exit 1
        }
        END {
            for (key in allowed)
                if (seen[key] != 1)
                    exit 1
        }
    ' "$stamp"
}

compare_value() {
    local label=$1
    local recorded=$2
    local current=$3
    [ "$recorded" = "$current" ] ||
        fail "$label mismatch (recorded $recorded, current $current)"
}

if [ "$mode" = record ]; then
    mkdir -p "$(dirname "$stamp")"
    temporary_stamp="$stamp.tmp.$$"
    trap 'rm -f -- "$temporary_stamp"' EXIT HUP INT TERM
    {
        printf '%s\n' 'schema=1'
        printf 'source-commit=%s\n' "$source_commit"
        printf 'source-tree-sha256=%s\n' "$source_tree"
        printf 'version=%s\n' "$current_version"
        printf 'version-header-sha256=%s\n' "$header_hash"
        printf 'binary-sha256=%s\n' "$binary_hash"
    } >"$temporary_stamp"
    mv -f -- "$temporary_stamp" "$stamp"
    trap - EXIT HUP INT TERM
    echo "[verify-build-provenance][ ok ] recorded $current_version for $binary"
    exit 0
fi

[ -f "$stamp" ] ||
    fail "provenance stamp does not exist: $stamp; relink the app before verifying"
validate_stamp || fail "provenance stamp has an invalid schema or key set: $stamp"

compare_value 'source commit' "$(stamp_value source-commit)" "$source_commit"
compare_value 'source tree' "$(stamp_value source-tree-sha256)" "$source_tree"
compare_value 'version' "$(stamp_value version)" "$current_version"
compare_value 'Version.h hash' "$(stamp_value version-header-sha256)" "$header_hash"
compare_value 'app binary hash' "$(stamp_value binary-sha256)" "$binary_hash"

echo "[verify-build-provenance][ ok ] $binary is bound to source $source_commit ($current_version)"
