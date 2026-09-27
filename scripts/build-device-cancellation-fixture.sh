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

for tool in cmp dd dpkg-deb dpkg-scanpackages gzip shasum tar; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "$tool is required" >&2
        exit 2
    }
done

fixture=$root/tests/fixtures/ui/device-cancellation
control=$fixture/control
test -f "$control" || {
    echo "device cancellation fixture control is missing" >&2
    exit 2
}

work=$(mktemp -d "${TMPDIR:-/tmp}/cydia-device-cancellation.XXXXXX") || exit 2
cleanup() {
    rm -rf -- "$work"
}
trap cleanup EXIT HUP INT TERM

SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$(git -C "$root" show -s --format=%ct HEAD)}
export SOURCE_DATE_EPOCH

package=com.torrekie.cydia-ui-cancellation-fixture
archive_name=${package}_1.0_iphoneos-arm64.deb

build_repository() {
    name=$1
    repository=$work/$name/repository
    staging=$work/$name/staging

    mkdir -p "$repository" "$staging/DEBIAN" \
        "$staging/var/jb/var/tmp/cydia-ui-cancellation-fixture"
    cp "$control" "$staging/DEBIAN/control"
    dd if=/dev/zero \
        of="$staging/var/jb/var/tmp/cydia-ui-cancellation-fixture/payload.bin" \
        bs=1048576 count=8 2>/dev/null
    chmod 0644 "$staging/DEBIAN/control" \
        "$staging/var/jb/var/tmp/cydia-ui-cancellation-fixture/payload.bin"

    dpkg-deb --root-owner-group -Znone --build "$staging" \
        "$repository/$archive_name" >/dev/null
    (
        cd "$repository"
        dpkg-scanpackages . /dev/null >Packages 2>/dev/null
        gzip -n -9 -c Packages >Packages.gz
        shasum -a 256 "$archive_name" Packages Packages.gz >SHA256SUMS
    )
}

build_repository first
build_repository second
cmp -s "$work/first/repository/$archive_name" \
    "$work/second/repository/$archive_name"
cmp -s "$work/first/repository/Packages" "$work/second/repository/Packages"
cmp -s "$work/first/repository/Packages.gz" \
    "$work/second/repository/Packages.gz"

archive=$work/first/repository/$archive_name
test "$(dpkg-deb -f "$archive" Package)" = "$package"
test "$(dpkg-deb -f "$archive" Version)" = 1.0
test "$(dpkg-deb -f "$archive" Architecture)" = iphoneos-arm64
test "$(dpkg-deb -f "$archive" Essential 2>/dev/null || true)" != yes
for field in Pre-Depends Depends Conflicts Breaks Replaces; do
    test "$(dpkg-deb -f "$archive" "$field" 2>/dev/null || true)" = ""
done

archive_size=$(wc -c <"$archive" | tr -d '[:space:]')
test "$archive_size" -ge 8388608
test "$archive_size" -lt 8500000
dpkg-deb -c "$archive" | grep -Fq \
    './var/jb/var/tmp/cydia-ui-cancellation-fixture/payload.bin'
dpkg-deb -x "$archive" "$work/extracted"
payload=$work/extracted/var/jb/var/tmp/cydia-ui-cancellation-fixture/payload.bin
test "$(wc -c <"$payload" | tr -d '[:space:]')" -eq 8388608
tr -d '\000' <"$payload" >"$work/nonzero-payload"
test ! -s "$work/nonzero-payload"
control_members=$(dpkg-deb --ctrl-tarfile "$archive" | tar -tf -)
if printf '%s\n' "$control_members" |
        grep -Ev '^\./?$|^\./control$' >/dev/null; then
    echo "cancellation fixture control archive contains unexpected members" >&2
    exit 1
fi

packages=$work/first/repository/Packages
test "$(sed -n 's/^Package: //p' "$packages")" = "$package"
test "$(sed -n 's/^Version: //p' "$packages")" = 1.0
grep -Fq "Filename: ./$archive_name" "$packages"
grep -Fq "Size: $archive_size" "$packages"

rm -rf -- "$output"
mkdir -p "$output"
cp -R "$work/first/repository" "$output/repository"

printf '%s\n%s\n%s\n' "$output/repository/$archive_name" \
    "$output/repository/Packages.gz" "$output/repository/SHA256SUMS"
