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

depends=$(dpkg-deb -f "$cydia" Depends)
translation_version=$(dpkg-deb -f "$lproj" Version)
printf '%s\n' "$depends" | grep -F "cydia-lproj (>= $translation_version)" >/dev/null || \
    fail "cydia package can be installed without its required native translations"
pre_depends=$(dpkg-deb -f "$cydia" Pre-Depends)
printf '%s\n' "$pre_depends" | tr ',' '\n' | \
    grep -E '^[[:space:]]*bash([[:space:](]|$)' >/dev/null || \
    fail "cydia package does not declare its maintscript Bash predependency"
if printf '%s\n' "$depends" | tr ',' '\n' | \
        grep -E '^[[:space:]]*org[.]thebigboss[.]repo[.]icons([[:space:](]|$)' >/dev/null; then
    fail "cydia package still depends on org.thebigboss.repo.icons"
fi

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
require_path "$cydia_paths" "${prefix:+$prefix/}usr/libexec/cydia/application.identities"
for asset in cydia7.png facebook.png twitter.png featured.png themes.png account.png; do
    require_path "$cydia_paths" \
        "${prefix:+$prefix/}Applications/Cydia.app/Home/$asset"
done
for asset in DOWNGRADE.png INSTALL.png PURGE.png REINSTALL.png REMOVE.png UPGRADE.png; do
    require_path "$cydia_paths" \
        "${prefix:+$prefix/}Applications/Cydia.app/Modes/$asset"
done
require_path "$cydia_paths" "${prefix:+$prefix/}usr/libexec/cydia/cydo"
python3 - "$cydia" "${prefix:+$prefix/}usr/libexec/cydia" <<'PY'
import subprocess, sys, tarfile
expected = {sys.argv[2] + "/cydo": 0o4755,
            sys.argv[2] + "/firmware.sh": 0o755,
            sys.argv[2] + "/firmware-discovery": 0o755}
process = subprocess.Popen(["dpkg-deb", "--fsys-tarfile", sys.argv[1]], stdout=subprocess.PIPE)
with tarfile.open(fileobj=process.stdout, mode="r|") as archive:
    helpers = [member for member in archive if member.name.removeprefix("./") in expected]
if process.wait() != 0 or len(helpers) != len(expected) or len({member.name.removeprefix("./") for member in helpers}) != len(expected):
    raise SystemExit("[verify-package][FAIL] missing or ambiguous helper metadata")
for helper in helpers:
    name = helper.name.removeprefix("./")
    if not helper.isfile() or helper.uid != 0 or helper.gid != 0 or helper.mode != expected[name]:
        if name.endswith("/cydo"):
            raise SystemExit("[verify-package][FAIL] helper must be root-owned setuid without setgid to preserve caller groups")
        raise SystemExit("[verify-package][FAIL] firmware helpers must be root-owned executable files")
PY
require_path "$cydia_paths" "${prefix:+$prefix/}usr/libexec/cydia/firmware-discovery"
if grep -E "^${prefix:+$prefix/}(etc/apt/|Library/LaunchDaemons/)" "$cydia_paths" >/dev/null; then
    fail "package owns shared APT configuration or automatic bootstrap startup jobs"
fi
require_path "$cydia_paths" "${prefix:+$prefix/}usr/share/doc/cydia/NOTICE"
require_path "$cydia_paths" "${prefix:+$prefix/}usr/share/doc/cydia/copyright"
require_path "$cydia_paths" "${prefix:+$prefix/}usr/share/doc/cydia/COPYING"
require_path "$cydia_paths" "${prefix:+$prefix/}usr/share/doc/cydia/ICU-LICENSE"
require_path "$cydia_paths" "${prefix:+$prefix/}usr/share/doc/cydia/SDURLCache-LICENCE"
require_path "$cydia_paths" "${prefix:+$prefix/}usr/share/doc/cydia/APT-COPYING"
require_path "$cydia_paths" "${prefix:+$prefix/}usr/share/doc/cydia/APT-COPYING.GPL"
require_path "$cydia_paths" "${prefix:+$prefix/}usr/share/doc/cydia/XXHASH-LICENSE"
require_path "$cydia_paths" "${prefix:+$prefix/}usr/share/doc/cydia/COMPILER-RT-LICENSE"
require_path "$cydia_paths" "${prefix:+$prefix/}usr/share/doc/cydia/LIBIOSEXEC-LICENSE"
require_path "$cydia_paths" "${prefix:+$prefix/}usr/share/doc/cydia/LIBIOSEXEC-COPYRIGHT"
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

python3 - "$data_directory/${prefix:+$prefix/}usr/libexec/cydia/application.identities" \
    "$data_directory/${prefix:+$prefix/}Applications/Cydia.app/Cydia" \
    "$(dirname "$0")/write-application-identity.py" <<'PY'
import hashlib, importlib.util, pathlib, re, sys
data = pathlib.Path(sys.argv[1]).read_bytes()
header = b'CYDIA-APPLICATION-IDENTITY-1\n'
if len(data) > 4096 or not data.startswith(header) or not re.fullmatch(rb'(?:[0-9a-f]{40}\n)+', data[len(header):]):
    sys.exit('[verify-package][FAIL] invalid application code identity')
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('application_identity', sys.argv[3])
identity = importlib.util.module_from_spec(spec)
spec.loader.exec_module(identity)
hashes = {hashlib.sha256(value).hexdigest()[:40] for value in identity.executable_directories(pathlib.Path(sys.argv[2]).read_bytes())}
expected = header + ''.join(value + '\n' for value in sorted(hashes)).encode('ascii')
if data != expected:
    sys.exit('[verify-package][FAIL] application identity does not match final executable')
PY

bigboss_source_icon=$data_directory/${prefix:+$prefix/}Applications/Cydia.app/Sources/apt.bigboss.us.com.png
planetiphones_section_icon=$data_directory/${prefix:+$prefix/}Applications/Cydia.app/Sections/Planet-iPhones\ Mods.png
[ ! -e "$bigboss_source_icon" ] && [ ! -L "$bigboss_source_icon" ] ||
    fail "package still installs the external BigBoss source icon"
[ ! -e "$planetiphones_section_icon" ] && [ ! -L "$planetiphones_section_icon" ] ||
    fail "package still installs the external Planet-iPhones section icon"
[ -f "$data_directory/${prefix:+$prefix/}Applications/Cydia.app/unknown.png" ] ||
    fail "package does not contain the source/section icon fallback"

for script in preinst postinst prerm postrm cydia-shared-config-lifecycle triggers; do
    [ -f "$control_directory/$script" ] || fail "missing maintainer file: $script"
done

expected_trigger_prefix=/${prefix:+$prefix/}
grep -Fx "interest-noawait ${expected_trigger_prefix}Applications" \
    "$control_directory/triggers" >/dev/null || \
    fail "package has the wrong Applications trigger for $layout"
grep -Fx "interest-noawait ${expected_trigger_prefix}Library/Themes" \
    "$control_directory/triggers" >/dev/null || \
    fail "package has the wrong themes trigger for $layout"

expected_shebang="#!/${prefix:+$prefix/}bin/bash"
for script in preinst prerm postrm cydia-shared-config-lifecycle; do
    [ "$(sed -n '1p' "$control_directory/$script")" = "$expected_shebang" ] ||
        fail "$script does not use the installed bootstrap shell"
    grep -F 'cydia_shared_config_lifecycle()' "$control_directory/$script" >/dev/null ||
        fail "$script lacks its self-contained configuration handoff"
done
for helper in firmware.sh package-paths.sh startup; do
    helper_path=$data_directory/${prefix:+$prefix/}usr/libexec/cydia/$helper
    [ "$(sed -n '1p' "$helper_path")" = "$expected_shebang" ] ||
        fail "$helper does not use the installed bootstrap shell"
done

icon=$(dpkg-deb -f "$cydia" Icon)
expected_icon="file:///${prefix:+$prefix/}Applications/Cydia.app/Icon-60.png"
[ "$icon" = "$expected_icon" ] || fail "Icon is $icon, expected $expected_icon"

echo "[verify-package][ ok ] $layout cydia and translation archives"
echo "[verify-package][ ok ] architecture $architecture, prefix /${prefix}"
echo "[verify-package][ ok ] dependencies, bootstrap shebangs, triggers, and isolated maintscripts"
