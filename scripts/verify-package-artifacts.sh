#!/bin/sh
# Copyright (C) 2026 Torrekie
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

fail() {
    echo "[verify-package][FAIL] $*" >&2
    exit 1
}

if [ "$#" -ne 2 ]; then
    echo "usage: $0 <rootful|rootless> <package-directory>" >&2
    exit 2
fi

layout=$1
package_directory=$2

case "$layout" in
    rootful)
        architecture=iphoneos-arm
        prefix=
        ;;
    rootless)
        architecture=iphoneos-arm64
        prefix=var/jb
        ;;
    *)
        fail "unsupported layout: $layout"
        ;;
esac

[ -d "$package_directory" ] || fail "package directory does not exist: $package_directory"

cydia=
cydia_count=0
for candidate in "$package_directory"/cydia_*.deb; do
    [ -f "$candidate" ] || continue
    cydia=$candidate
    cydia_count=$((cydia_count + 1))
done
[ "$cydia_count" -eq 1 ] || fail "expected one cydia package, found $cydia_count"

lproj=
lproj_count=0
for candidate in "$package_directory"/cydia-lproj_*.deb; do
    [ -f "$candidate" ] || continue
    lproj=$candidate
    lproj_count=$((lproj_count + 1))
done
[ "$lproj_count" -eq 1 ] || fail "expected one cydia-lproj package, found $lproj_count"

temporary=$(mktemp -d "${TMPDIR:-/tmp}/cydia-package-verify.XXXXXX")
cleanup() {
    rm -rf "$temporary"
}
on_signal() {
    cleanup
    exit 1
}
trap cleanup EXIT
trap on_signal HUP INT TERM

check_control() {
    archive=$1
    expected_package=$2
    expected_name=$3

    actual_package=$(dpkg-deb -f "$archive" Package)
    actual_architecture=$(dpkg-deb -f "$archive" Architecture)
    version=$(dpkg-deb -f "$archive" Version)
    maintainer=$(dpkg-deb -f "$archive" Maintainer)
    author=$(dpkg-deb -f "$archive" Author)
    name=$(dpkg-deb -f "$archive" Name)

    [ "$actual_package" = "$expected_package" ] ||
        fail "$archive has package name $actual_package"
    [ "$actual_architecture" = "$architecture" ] ||
        fail "$archive has architecture $actual_architecture"
    case "$version" in
        1:*) ;;
        *) fail "$archive has version $version; expected Debian epoch 1" ;;
    esac
    [ "$maintainer" = "Torrekie <me@torrekie.dev>" ] ||
        fail "$archive has maintainer $maintainer"
    [ "$author" = "Jay Freeman (saurik) <saurik@saurik.com>" ] ||
        fail "$archive has author $author"
    [ "$name" = "$expected_name" ] ||
        fail "$archive has display name $name"
}

check_control "$cydia" cydia "Cydia Refurbished"
check_control "$lproj" cydia-lproj "Cydia Translations"

cydia_paths=$temporary/cydia.paths
lproj_paths=$temporary/lproj.paths
dpkg-deb --fsys-tarfile "$cydia" | tar -tf - | sed 's@^\./@@' >"$cydia_paths"
dpkg-deb --fsys-tarfile "$lproj" | tar -tf - | sed 's@^\./@@' >"$lproj_paths"

require_path() {
    paths=$1
    required=$2
    grep -Fx "$required" "$paths" >/dev/null || fail "missing package path: $required"
}

require_path "$cydia_paths" "${prefix:+$prefix/}Applications/Cydia.app/Cydia"
require_path "$cydia_paths" "${prefix:+$prefix/}usr/libexec/cydia/cydo"
require_path "$cydia_paths" "${prefix:+$prefix/}Library/LaunchDaemons/com.saurik.Cydia.Startup.plist"
require_path "$cydia_paths" "${prefix:+$prefix/}usr/share/doc/cydia/NOTICE"
require_path "$cydia_paths" "${prefix:+$prefix/}usr/share/doc/cydia/copyright"
require_path "$cydia_paths" "${prefix:+$prefix/}usr/share/doc/cydia/COPYING"
require_path "$cydia_paths" "${prefix:+$prefix/}usr/share/doc/cydia/ICU-LICENSE"
require_path "$cydia_paths" "${prefix:+$prefix/}usr/share/doc/cydia/SDURLCache-LICENCE"
require_path "$cydia_paths" "${prefix:+$prefix/}usr/share/doc/cydia/APT-COPYING"
require_path "$cydia_paths" "${prefix:+$prefix/}usr/share/doc/cydia/APT-COPYING.GPL"
grep -E "^${prefix:+$prefix/}Applications/Cydia[.]app/[^/]+[.]lproj/Localizable[.]strings$" \
    "$lproj_paths" >/dev/null || fail "translation package has no Localizable.strings"

if [ "$layout" = rootless ]; then
    while IFS= read -r path; do
        case "$path" in
            ""|var|var/|var/jb|var/jb/|var/jb/*) ;;
            *) fail "rootless archive escapes /var/jb: $path" ;;
        esac
    done <"$cydia_paths"
    while IFS= read -r path; do
        case "$path" in
            ""|var|var/|var/jb|var/jb/|var/jb/*) ;;
            *) fail "rootless translation archive escapes /var/jb: $path" ;;
        esac
    done <"$lproj_paths"
else
    if grep -E '^var/jb(/|$)' "$cydia_paths" "$lproj_paths" >/dev/null; then
        fail "rootful archive unexpectedly contains /var/jb"
    fi
fi

control_directory=$temporary/control
data_directory=$temporary/data
mkdir -p "$control_directory" "$data_directory"
dpkg-deb -e "$cydia" "$control_directory"
dpkg-deb -x "$cydia" "$data_directory"

for script in preinst postinst triggers; do
    [ -f "$control_directory/$script" ] || fail "missing maintainer file: $script"
done

launchd=$data_directory/${prefix:+$prefix/}Library/LaunchDaemons/com.saurik.Cydia.Startup.plist
expected_launch_path=/${prefix:+$prefix/}usr/libexec/cydia/startup
grep -F "$expected_launch_path" "$launchd" >/dev/null ||
    fail "launch daemon does not use $expected_launch_path"

icon=$(dpkg-deb -f "$cydia" Icon)
expected_icon="file:///${prefix:+$prefix/}Applications/Cydia.app/Icon-60.png"
[ "$icon" = "$expected_icon" ] || fail "Icon is $icon, expected $expected_icon"

echo "[verify-package][ ok ] $layout cydia and translation archives"
echo "[verify-package][ ok ] architecture $architecture, prefix /${prefix}"
echo "[verify-package][ ok ] maintainer files and launchd path"
