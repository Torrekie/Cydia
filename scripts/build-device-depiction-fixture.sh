#!/bin/sh
# Copyright (C) 2026 Torrekie
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

if [ "$#" -ne 2 ]; then
    echo "usage: $0 OUTPUT_DIR DEPICTION_ORIGIN" >&2
    exit 2
fi

output=$1
origin=$2
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P) || exit 2
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
case "$origin" in
    http://*|https://*) ;;
    *) echo "DEPICTION_ORIGIN must be an absolute HTTP(S) URL" >&2; exit 2 ;;
esac
case "$origin" in
    *[[:space:]]*) echo "DEPICTION_ORIGIN contains whitespace" >&2; exit 2 ;;
esac

command -v dpkg-deb >/dev/null 2>&1 || {
    echo "dpkg-deb is required" >&2
    exit 2
}

fixture=$root/tests/fixtures/ui/device-depiction
template=$fixture/control.in
marker=$fixture/marker.txt
test -f "$template" && test -f "$marker" || {
    echo "device depiction fixture inputs are incomplete" >&2
    exit 2
}

layout=${PACKAGE_LAYOUT:-rootless}
case "$layout" in
    rootless) architecture=iphoneos-arm64 ;;
    rootful) architecture=iphoneos-arm ;;
    *) echo "unsupported PACKAGE_LAYOUT: $layout" >&2; exit 2 ;;
esac

staging_root=$(mktemp -d "${TMPDIR:-/tmp}/cydia-device-depiction.XXXXXX") || exit 2
cleanup() { rm -rf -- "$staging_root"; }
trap cleanup EXIT HUP INT TERM

SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$(git -C "$root" show -s --format=%ct HEAD)}
export SOURCE_DATE_EPOCH

rm -rf -- "$output"
mkdir -p "$output"

build_case() {
    case_name=$1
    case_path=$2
    package=com.torrekie.cydia-ui-depiction-${case_name}-fixture
    staging=$staging_root/$case_name
    archive=$output/${package}_1.0_${architecture}.deb

    mkdir -p "$staging/DEBIAN" \
        "$staging/var/jb/var/tmp/cydia-ui-depiction-fixture/$case_name"
    sed -e "s#@PACKAGE@#$package#g" \
        -e "s#@NAME@#Cydia UI Depiction ${case_name} fixture#g" \
        -e "s#@PACKAGE_ARCH@#$architecture#g" \
        -e "s#@CASE@#$case_name#g" \
        -e "s#@DEPICTION_URL@#${origin}/${case_path}#g" \
        "$template" >"$staging/DEBIAN/control"
    cp "$marker" \
        "$staging/var/jb/var/tmp/cydia-ui-depiction-fixture/$case_name/marker.txt"
    chmod 0644 "$staging/DEBIAN/control" \
        "$staging/var/jb/var/tmp/cydia-ui-depiction-fixture/$case_name/marker.txt"

    dpkg-deb --root-owner-group -Zxz --build "$staging" "$archive" >/dev/null
    test "$(dpkg-deb -f "$archive" Package)" = "$package"
    test "$(dpkg-deb -f "$archive" Version)" = 1.0
    test "$(dpkg-deb -f "$archive" Architecture)" = "$architecture"
    test "$(dpkg-deb -f "$archive" Depiction)" = "${origin}/${case_path}"
    test "$(dpkg-deb -f "$archive" Essential 2>/dev/null || true)" != yes
    for field in Pre-Depends Depends Conflicts Breaks Replaces; do
        test "$(dpkg-deb -f "$archive" "$field" 2>/dev/null || true)" = ""
    done
    dpkg-deb -c "$archive" | grep -Fq \
        "./var/jb/var/tmp/cydia-ui-depiction-fixture/$case_name/marker.txt"
}

build_case short short
build_case long long
build_case hostile hostile
build_case failed failed

count=$(find "$output" -type f -name '*.deb' | wc -l | tr -d '[:space:]')
test "$count" -eq 4

find "$output" -type f -name '*.deb' -print | LC_ALL=C sort
