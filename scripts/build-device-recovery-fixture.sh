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

for tool in dpkg-deb dpkg-scanpackages gzip; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "$tool is required" >&2
        exit 2
    }
done

fixture=$root/tests/fixtures/ui/device-recovery
for input in baseline.control candidate.control baseline-marker.txt \
        candidate-marker.txt postinst; do
    test -f "$fixture/$input" || {
        echo "missing recovery fixture input: $input" >&2
        exit 2
    }
done

work=$(mktemp -d "${TMPDIR:-/tmp}/cydia-device-recovery.XXXXXX") || exit 2
cleanup() {
    rm -rf -- "$work"
}
trap cleanup EXIT HUP INT TERM

SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$(git -C "$root" show -s --format=%ct HEAD)}
export SOURCE_DATE_EPOCH

package=com.torrekie.cydia-ui-recovery-fixture
baseline=$output/baseline/${package}_1.0_iphoneos-arm64.deb
candidate=$output/repository/${package}_2.0_iphoneos-arm64.deb

build_package() {
    name=$1
    version=$2
    control=$3
    marker=$4
    archive=$5

    staging=$work/$name
    mkdir -p "$staging/DEBIAN" \
        "$staging/var/jb/var/tmp/cydia-ui-recovery-fixture" \
        "$(dirname "$archive")"
    cp "$control" "$staging/DEBIAN/control"
    cp "$marker" \
        "$staging/var/jb/var/tmp/cydia-ui-recovery-fixture/marker.txt"
    chmod 0644 "$staging/DEBIAN/control" \
        "$staging/var/jb/var/tmp/cydia-ui-recovery-fixture/marker.txt"

    if [ "$name" = candidate ]; then
        cp "$fixture/postinst" "$staging/DEBIAN/postinst"
        chmod 0755 "$staging/DEBIAN/postinst"
    fi

    dpkg-deb --root-owner-group -Zxz --build "$staging" "$archive" >/dev/null
    test "$(dpkg-deb -f "$archive" Package)" = "$package"
    test "$(dpkg-deb -f "$archive" Version)" = "$version"
    test "$(dpkg-deb -f "$archive" Architecture)" = iphoneos-arm64
    test "$(dpkg-deb -f "$archive" Essential 2>/dev/null || true)" != yes
    for field in Pre-Depends Depends Conflicts Breaks Replaces; do
        test "$(dpkg-deb -f "$archive" "$field" 2>/dev/null || true)" = ""
    done
    dpkg-deb -c "$archive" | grep -Fq \
        './var/jb/var/tmp/cydia-ui-recovery-fixture/marker.txt'
}

rm -rf -- "$output"
build_package baseline 1.0 "$fixture/baseline.control" \
    "$fixture/baseline-marker.txt" "$baseline"
build_package candidate 2.0 "$fixture/candidate.control" \
    "$fixture/candidate-marker.txt" "$candidate"

baseline_control=$(dpkg-deb --ctrl-tarfile "$baseline" | tar -tf -)
if printf '%s\n' "$baseline_control" |
        grep -Ev '^\./?$|^\./control$' >/dev/null; then
    echo "baseline control archive contains a maintainer script" >&2
    exit 1
fi

candidate_control=$(dpkg-deb --ctrl-tarfile "$candidate" | tar -tf -)
printf '%s\n' "$candidate_control" | grep -Eq '^\./postinst$'
postinst=$work/extracted-postinst
dpkg-deb --ctrl-tarfile "$candidate" | tar -xOf - ./postinst >"$postinst"
cmp -s "$postinst" "$fixture/postinst"
grep -Fqx '#!/var/jb/bin/sh' "$postinst"
grep -Fqx 'exit 23' "$postinst"

(
    cd "$output/repository"
    dpkg-scanpackages . /dev/null >Packages 2>/dev/null
    gzip -n -9 -c Packages >Packages.gz
)
test "$(sed -n 's/^Package: //p' "$output/repository/Packages")" = "$package"
test "$(sed -n 's/^Version: //p' "$output/repository/Packages")" = 2.0
grep -Fq "Filename: ./${package}_2.0_iphoneos-arm64.deb" \
    "$output/repository/Packages"

printf '%s\n%s\n%s\n' "$baseline" "$candidate" \
    "$output/repository/Packages.gz"
