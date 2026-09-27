#!/bin/sh
# Copyright (C) 2026 Torrekie
# SPDX-License-Identifier: GPL-3.0-or-later

# Validate a historical Cydia rollback pair against an immutable manifest.
# This deliberately does not impose current-package branding, epoch, or asset
# policy: rollback archives must match the exact previously installed product.

set -eu
LC_ALL=C
export LC_ALL

fail() {
    echo "[verify-rollback-package][FAIL] $*" >&2
    exit 1
}

if [ "$#" -ne 2 ]; then
    echo "usage: $0 <package-directory> <manifest>" >&2
    exit 2
fi

package_directory=$1
manifest=$2
[ -d "$package_directory" ] || fail "package directory does not exist"
[ -f "$manifest" ] && [ ! -L "$manifest" ] ||
    fail "manifest does not exist or is linked"
command -v dpkg-deb >/dev/null 2>&1 || fail "dpkg-deb is unavailable"
command -v shasum >/dev/null 2>&1 || fail "shasum is unavailable"
command -v tar >/dev/null 2>&1 || fail "tar is unavailable"

temporary=$(mktemp -d "${TMPDIR:-/tmp}/cydia-rollback-verify.XXXXXX") ||
    fail "could not create verification directory"
cleanup() {
    rm -rf -- "$temporary"
}
on_signal() {
    trap - EXIT
    cleanup
    exit 1
}
trap cleanup EXIT
trap on_signal HUP INT TERM

mkdir "$temporary/input" || fail "could not create snapshot directory"
cp "$manifest" "$temporary/input/manifest" || fail "could not snapshot manifest"
manifest=$temporary/input/manifest

allowed_keys='schema layout cydia_file cydia_version cydia_architecture cydia_sha256 cydia_app_sha256 cydia_app_mode cydia_cydo_sha256 cydia_cydo_mode cydia_preinst_sha256 cydia_preinst_mode cydia_postinst_sha256 cydia_postinst_mode cydia_triggers_sha256 cydia_triggers_mode lproj_file lproj_version lproj_architecture lproj_sha256 lproj_payload_sha256'
manifest_keys=$temporary/manifest.keys
awk -F= '
    /^[[:space:]]*($|#)/ { next }
    index($0, "=") == 0 { print "<malformed>"; next }
    $1 == "" { print "<malformed>"; next }
    { print $1 }
' "$manifest" >"$manifest_keys" || fail "could not parse manifest keys"
unknown_keys=$(while IFS= read -r key; do
    found=no
    for allowed in $allowed_keys; do
        [ "$key" = "$allowed" ] && found=yes
    done
    [ "$found" = yes ] || printf '%s\n' "$key"
done <"$manifest_keys")
[ -z "$unknown_keys" ] || fail "manifest has unknown or malformed keys"

manifest_value() {
    key=$1
    count=$(awk -F= -v key="$key" '$1 == key { count++ } END { print count + 0 }' \
        "$manifest")
    [ "$count" -eq 1 ] || fail "manifest has $count '$key' values"
    value=$(awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print }' \
        "$manifest")
    [ -n "$value" ] || fail "manifest value '$key' is empty"
    printf '%s\n' "$value"
}

schema=$(manifest_value schema)
layout=$(manifest_value layout)
[ "$schema" = 1 ] || fail "unsupported manifest schema: $schema"
case "$layout" in
    rootful) expected_architecture=iphoneos-arm; prefix= ;;
    rootless) expected_architecture=iphoneos-arm64; prefix=var/jb ;;
    *) fail "unsupported rollback layout: $layout" ;;
esac

safe_filename() {
    case "$1" in
        ''|.*|*[!A-Za-z0-9_.+~%-]*) return 1 ;;
    esac
}
valid_hash() {
    [ "${#1}" -eq 64 ] || return 1
    case "$1" in
        *[!0-9a-f]*) return 1 ;;
    esac
}
valid_mode() {
    [ "${#1}" -eq 10 ] || return 1
    case "$1" in
        -?????????) ;;
        *) return 1 ;;
    esac
    case "${1#?}" in
        *[!rwxstST-]*) return 1 ;;
    esac
}
file_hash() {
    hash_output=$(shasum -a 256 "$1") || fail "could not hash $1"
    hash_value=${hash_output%% *}
    valid_hash "$hash_value" || fail "hash output for $1 is malformed"
    printf '%s\n' "$hash_value"
}
require_hash() {
    file=$1
    expected=$2
    label=$3
    valid_hash "$expected" || fail "$label manifest hash is malformed"
    actual=$(file_hash "$file")
    [ "$actual" = "$expected" ] ||
        fail "$label hash is $actual (expected $expected)"
}

cydia_file=$(manifest_value cydia_file)
lproj_file=$(manifest_value lproj_file)
safe_filename "$cydia_file" || fail "unsafe Cydia archive filename"
safe_filename "$lproj_file" || fail "unsafe translation archive filename"
[ "$cydia_file" != "$lproj_file" ] || fail "rollback archives share one filename"
cydia_source=$package_directory/$cydia_file
lproj_source=$package_directory/$lproj_file
[ -f "$cydia_source" ] && [ ! -L "$cydia_source" ] ||
    fail "Cydia archive is missing or linked"
[ -f "$lproj_source" ] && [ ! -L "$lproj_source" ] ||
    fail "translation archive is missing or linked"
cydia=$temporary/input/cydia.deb
lproj=$temporary/input/lproj.deb
cp "$cydia_source" "$cydia" || fail "could not snapshot Cydia archive"
cp "$lproj_source" "$lproj" || fail "could not snapshot translation archive"

cydia_sha=$(manifest_value cydia_sha256)
lproj_sha=$(manifest_value lproj_sha256)
require_hash "$cydia" "$cydia_sha" "Cydia archive"
require_hash "$lproj" "$lproj_sha" "translation archive"

check_control() {
    archive=$1
    expected_package=$2
    version_key=$3
    architecture_key=$4
    package=$(dpkg-deb -f "$archive" Package)
    version=$(dpkg-deb -f "$archive" Version)
    architecture=$(dpkg-deb -f "$archive" Architecture)
    expected_version=$(manifest_value "$version_key")
    manifest_architecture=$(manifest_value "$architecture_key")
    [ "$package" = "$expected_package" ] ||
        fail "$archive has package '$package'"
    [ "$manifest_architecture" = "$expected_architecture" ] ||
        fail "$architecture_key does not match layout"
    [ "$architecture" = "$manifest_architecture" ] ||
        fail "$archive has architecture '$architecture'"
    [ "$version" = "$expected_version" ] ||
        fail "$archive has version '$version'"
}

cydia_tar=$temporary/cydia-data.tar
lproj_tar=$temporary/lproj-data.tar
control_tar=$temporary/cydia-control.tar
lproj_control_tar=$temporary/lproj-control.tar
dpkg-deb --fsys-tarfile "$cydia" >"$cydia_tar" ||
    fail "could not read Cydia payload archive"
dpkg-deb --fsys-tarfile "$lproj" >"$lproj_tar" ||
    fail "could not read translation payload archive"
dpkg-deb --ctrl-tarfile "$cydia" >"$control_tar" ||
    fail "could not read Cydia control archive"
dpkg-deb --ctrl-tarfile "$lproj" >"$lproj_control_tar" ||
    fail "could not read translation control archive"

canonical_member_list() {
    archive=$1
    output=$2
    archive_label=$3
    raw=$output.raw
    tar -tf "$archive" >"$raw" || fail "could not list $archive_label"
    [ -s "$raw" ] || fail "$archive_label is empty"
    : >"$output"
    while IFS= read -r member; do
        case "$member" in
            .|./) normalized= ;;
            ./*) normalized=${member#./} ;;
            *) fail "$archive_label has noncanonical member: $member" ;;
        esac
        case "$normalized" in
            *//*) fail "$archive_label has unsafe member: $member" ;;
        esac
        case "$normalized" in
            */) normalized=${normalized%/} ;;
        esac
        case "$normalized" in
            '' ) ;;
            .|..|/*|./*|../*|*/./*|*/../*|*/.|*/.. )
                fail "$archive_label has unsafe member: $member"
                ;;
        esac
        printf '%s\n' "$normalized" >>"$output"
    done <"$raw"
    LC_ALL=C sort "$output" >"$output.sorted" ||
        fail "could not sort $archive_label members"
    duplicates=$(uniq -d "$output.sorted") ||
        fail "could not check $archive_label duplicates"
    [ -z "$duplicates" ] || fail "$archive_label has duplicate canonical members"
}

cydia_paths=$temporary/cydia.paths
lproj_paths=$temporary/lproj.paths
control_paths=$temporary/control.paths
lproj_control_paths=$temporary/lproj-control.paths
canonical_member_list "$cydia_tar" "$cydia_paths" "Cydia payload"
canonical_member_list "$lproj_tar" "$lproj_paths" "translation payload"
canonical_member_list "$control_tar" "$control_paths" "Cydia control archive"
canonical_member_list "$lproj_control_tar" "$lproj_control_paths" \
    "translation control archive"

member_type() {
    archive=$1
    member=$2
    listing=$temporary/member-listing
    tar -tvf "$archive" --no-recursion "./$member" >"$listing" ||
        fail "could not inspect archive member: $member"
    listing_lines=$(awk 'END { print NR + 0 }' "$listing") ||
        fail "could not count archive member listings: $member"
    [ "$listing_lines" -eq 1 ] ||
        fail "archive member is ambiguous: $member"
    type=$(cut -c1 "$listing")
    [ -n "$type" ] || fail "archive member has no type: $member"
    printf '%s\n' "$type"
}
member_mode() {
    archive=$1
    member=$2
    listing=$temporary/member-mode-listing
    tar -tvf "$archive" --no-recursion "./$member" >"$listing" ||
        fail "could not inspect archive member mode: $member"
    listing_lines=$(awk 'END { print NR + 0 }' "$listing") ||
        fail "could not count archive member mode listings: $member"
    [ "$listing_lines" -eq 1 ] ||
        fail "archive member mode is ambiguous: $member"
    mode=$(cut -c1-10 "$listing")
    valid_mode "$mode" || fail "archive member mode is malformed: $member"
    printf '%s\n' "$mode"
}
require_member_mode() {
    archive=$1
    member=$2
    mode_key=$3
    expected_mode=$(manifest_value "$mode_key")
    valid_mode "$expected_mode" || fail "$mode_key is malformed"
    actual_mode=$(member_mode "$archive" "$member")
    [ "$actual_mode" = "$expected_mode" ] ||
        fail "$member mode is $actual_mode (expected $expected_mode)"
}

check_payload_members() {
    archive=$1
    paths=$2
    archive_label=$3
    allow_links=$4
    non_directory_paths=$temporary/$archive_label.non-directories
    : >"$non_directory_paths"
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        type=$(member_type "$archive" "$path")
        case "$type" in
            d) ;;
            -)
                printf '%s\n' "$path" >>"$non_directory_paths"
                ;;
            l)
                [ "$allow_links" = yes ] ||
                    fail "$archive_label contains a link: $path"
                printf '%s\n' "$path" >>"$non_directory_paths"
                ;;
            *) fail "$archive_label contains unsupported member type '$type': $path" ;;
        esac
        if [ "$layout" = rootless ]; then
            case "$path" in
                var|var/|var/jb|var/jb/|var/jb/*) ;;
                *) fail "rootless $archive_label escapes /var/jb: $path" ;;
            esac
        else
            case "$path" in
                var/jb|var/jb/|var/jb/*) fail "rootful $archive_label contains /var/jb" ;;
            esac
        fi
    done <"$paths"
    while IFS= read -r non_directory_path; do
        while IFS= read -r candidate; do
            case "$candidate" in
                "$non_directory_path"/*)
                    fail "$archive_label has descendants below a non-directory member: $non_directory_path"
                    ;;
            esac
        done <"$paths"
    done <"$non_directory_paths"
}

check_payload_members "$cydia_tar" "$cydia_paths" cydia yes
check_payload_members "$lproj_tar" "$lproj_paths" lproj no

check_control_members() {
    archive=$1
    paths=$2
    archive_label=$3
    non_directory_paths=$temporary/control-non-directories
    : >"$non_directory_paths"
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        type=$(member_type "$archive" "$path")
        case "$type" in
            d) ;;
            -) printf '%s\n' "$path" >>"$non_directory_paths" ;;
            *) fail "$archive_label contains unsupported member: $path" ;;
        esac
    done <"$paths"
    while IFS= read -r non_directory_path; do
        while IFS= read -r candidate; do
            case "$candidate" in
                "$non_directory_path"/*)
                    fail "$archive_label has descendants below a non-directory member: $non_directory_path"
                    ;;
            esac
        done <"$paths"
    done <"$non_directory_paths"
}

check_control_members "$control_tar" "$control_paths" "Cydia control archive"
check_control_members "$lproj_control_tar" "$lproj_control_paths" \
    "translation control archive"

check_control "$cydia" cydia cydia_version cydia_architecture
check_control "$lproj" cydia-lproj lproj_version lproj_architecture

app_path=${prefix:+$prefix/}Applications/Cydia.app/Cydia
cydo_path=${prefix:+$prefix/}usr/libexec/cydia/cydo
grep -Fx "$app_path" "$cydia_paths" >/dev/null || fail "Cydia binary is absent"
grep -Fx "$cydo_path" "$cydia_paths" >/dev/null || fail "cydo is absent"
[ "$(member_type "$cydia_tar" "$app_path")" = - ] ||
    fail "Cydia binary is not a regular archive member"
[ "$(member_type "$cydia_tar" "$cydo_path")" = - ] ||
    fail "cydo is not a regular archive member"
require_member_mode "$cydia_tar" "$app_path" cydia_app_mode
require_member_mode "$cydia_tar" "$cydo_path" cydia_cydo_mode

hash_archive_member() {
    archive=$1
    member=$2
    output=$3
    tar -xOf "$archive" "./$member" >"$output" ||
        fail "could not read archive member: $member"
    file_hash "$output"
}

app_hash=$(hash_archive_member "$cydia_tar" "$app_path" "$temporary/app")
[ "$app_hash" = "$(manifest_value cydia_app_sha256)" ] ||
    fail "installed Cydia binary hash is $app_hash"
cydo_hash=$(hash_archive_member "$cydia_tar" "$cydo_path" "$temporary/cydo")
[ "$cydo_hash" = "$(manifest_value cydia_cydo_sha256)" ] ||
    fail "installed cydo hash is $cydo_hash"

for control_file in preinst postinst triggers; do
    grep -Fx "$control_file" "$control_paths" >/dev/null ||
        fail "rollback Cydia is missing $control_file"
    [ "$(member_type "$control_tar" "$control_file")" = - ] ||
        fail "$control_file is not a regular control member"
    require_member_mode "$control_tar" "$control_file" \
        "cydia_${control_file}_mode"
    actual=$(hash_archive_member "$control_tar" "$control_file" \
        "$temporary/control-$control_file")
    expected=$(manifest_value "cydia_${control_file}_sha256")
    [ "$actual" = "$expected" ] || fail "$control_file hash is $actual"
done

lproj_regular_paths=$temporary/lproj-regular.paths
: >"$lproj_regular_paths"
while IFS= read -r path; do
    [ -n "$path" ] || continue
    [ "$(member_type "$lproj_tar" "$path")" = - ] || continue
    printf '%s\n' "$path" >>"$lproj_regular_paths"
done <"$lproj_paths"
grep -E "^${prefix:+$prefix/}Applications/Cydia[.]app/[^/]+[.]lproj/Localizable[.]strings$" \
    "$lproj_regular_paths" >/dev/null ||
    fail "translation payload has no regular Localizable.strings"

lproj_hash_list=$temporary/lproj-payload.sha256
: >"$lproj_hash_list"
LC_ALL=C sort "$lproj_regular_paths" >"$temporary/lproj-regular.sorted"
index=0
while IFS= read -r path; do
    index=$((index + 1))
    hash=$(hash_archive_member "$lproj_tar" "$path" "$temporary/lproj-$index")
    printf '%s  %s\n' "$hash" "$path" >>"$lproj_hash_list"
done <"$temporary/lproj-regular.sorted"
[ -s "$lproj_hash_list" ] || fail "translation payload is empty"
require_hash "$lproj_hash_list" "$(manifest_value lproj_payload_sha256)" \
    "translation payload manifest"

echo "[verify-rollback-package][ ok ] exact $layout Cydia rollback pair"
echo "[verify-rollback-package][ ok ] versions, archives, app/cydo, maintainer files, and translations"
