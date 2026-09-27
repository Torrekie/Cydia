#!/bin/sh
# Copyright (C) 2026 Torrekie
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: $0 OUTPUT_DIR" >&2
    exit 2
fi

output=$1
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P) || exit 2
layout=${PACKAGE_LAYOUT:-rootless}
case "$layout" in
    rootless)
        architecture=iphoneos-arm64
        marker_relative=var/jb/var/tmp/cydia-ui-transaction-fixture/marker.txt
        ;;
    rootful)
        architecture=iphoneos-arm
        marker_relative=var/tmp/cydia-ui-transaction-fixture/marker.txt
        ;;
    *)
        echo "unsupported PACKAGE_LAYOUT: $layout" >&2
        exit 2
        ;;
esac
case "$output" in
    /*) ;;
    *) output=$root/$output ;;
esac
case "$output" in
    /|/private|/private/tmp|/tmp)
        echo "unsafe OUTPUT_DIR: $output" >&2
        exit 2
        ;;
esac

command -v dpkg-deb >/dev/null 2>&1 || {
    echo "dpkg-deb is required" >&2
    exit 2
}

fixture=$root/tests/fixtures/ui/device-transaction
control=$fixture/control
marker=$fixture/marker.txt
test -f "$control" && test -f "$marker" || {
    echo "device transaction fixture inputs are incomplete" >&2
    exit 2
}

staging=$(mktemp -d "${TMPDIR:-/tmp}/cydia-device-transaction.XXXXXX") || exit 2
cleanup() {
    rm -rf -- "$staging"
}
trap cleanup EXIT HUP INT TERM

SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$(git -C "$root" show -s --format=%ct HEAD)}
export SOURCE_DATE_EPOCH

mkdir -p "$output" "$staging/DEBIAN" \
    "$(dirname "$staging/$marker_relative")"
chmod 0755 "$staging"
sed "s/@PACKAGE_ARCH@/$architecture/g" "$control" \
    >"$staging/DEBIAN/control"
cp "$marker" "$staging/$marker_relative"
chmod 0644 "$staging/DEBIAN/control" \
    "$staging/$marker_relative"

package=$(sed -n 's/^Package: //p' "$control")
test "$package" = "com.torrekie.cydia-ui-transaction-fixture" || {
    echo "fixture package identity changed" >&2
    exit 1
}

archive=$output/${package}_1.0_${architecture}.deb
dpkg-deb --root-owner-group --build "$staging" "$archive" >/dev/null

test "$(dpkg-deb -f "$archive" Package)" = "$package"
test "$(dpkg-deb -f "$archive" Version)" = "1.0"
test "$(dpkg-deb -f "$archive" Architecture)" = "$architecture"
test "$(dpkg-deb -f "$archive" Essential 2>/dev/null || true)" != "yes"
test "$(dpkg-deb -f "$archive" Pre-Depends 2>/dev/null || true)" = ""
test "$(dpkg-deb -f "$archive" Depends 2>/dev/null || true)" = ""
test "$(dpkg-deb -f "$archive" Conflicts 2>/dev/null || true)" = ""
test "$(dpkg-deb -f "$archive" Breaks 2>/dev/null || true)" = ""
test "$(dpkg-deb -f "$archive" Replaces 2>/dev/null || true)" = ""

members=$(dpkg-deb -c "$archive")
printf '%s\n' "$members" | grep -Fq "./$marker_relative"
control_members=$(dpkg-deb --ctrl-tarfile "$archive" | tar -tf -)
if printf '%s\n' "$control_members" |
        grep -Ev '^\./?$|^\./control$' >/dev/null; then
    echo "fixture control archive contains more than its control file" >&2
    exit 1
fi

printf '%s\n' "$archive"
