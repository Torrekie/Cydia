#!/bin/sh
# Copyright (C) 2026 Torrekie
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu
LC_ALL=C
export LC_ALL

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
verifier=$root/scripts/verify-rollback-package-pair.sh
temporary=$(mktemp -d "${TMPDIR:-/tmp}/cydia-rollback-tests.XXXXXX")
cleanup() { rm -rf -- "$temporary"; }
on_signal() { trap - EXIT; cleanup; exit 1; }
trap cleanup EXIT
trap on_signal HUP INT TERM

fail() {
    echo "[verify-rollback-package-tests][FAIL] $*" >&2
    exit 1
}
hash() {
    hash_output=$(shasum -a 256 "$1") || fail "could not hash $1"
    hash_value=${hash_output%% *}
    printf '%s\n' "$hash_value"
}
build_package() {
    root_directory=$1
    output=$2
    dpkg-deb --build --root-owner-group "$root_directory" "$output" >/dev/null
}
manifest_value() {
    fixture_manifest=$1
    fixture_key=$2
    awk -F= -v key="$fixture_key" '$1 == key { sub(/^[^=]*=/, ""); print }' \
        "$fixture_manifest"
}
replace_manifest_value() {
    fixture_manifest=$1
    fixture_key=$2
    fixture_value=$3
    replacement=$fixture_manifest.new
    awk -F= -v key="$fixture_key" -v value="$fixture_value" '
        $1 == key { print key "=" value; next }
        { print }
    ' "$fixture_manifest" >"$replacement"
    mv "$replacement" "$fixture_manifest"
}

create_pair() {
    pair_name=$1
    pair_layout=$2
    pair_architecture=$3
    pair_prefix=$4
    pair_base=$temporary/$pair_name
    pair_cydia_root=$pair_base/cydia-root
    pair_lproj_root=$pair_base/lproj-root
    pair_packages=$pair_base/packages
    pair_app_path=${pair_prefix:+$pair_prefix/}Applications/Cydia.app/Cydia
    pair_cydo_path=${pair_prefix:+$pair_prefix/}usr/libexec/cydia/cydo
    pair_localizable_path=${pair_prefix:+$pair_prefix/}Applications/Cydia.app/en.lproj/Localizable.strings

    mkdir -p "$pair_cydia_root/DEBIAN" \
        "$pair_cydia_root/$(dirname "$pair_app_path")" \
        "$pair_cydia_root/$(dirname "$pair_cydo_path")" \
        "$pair_lproj_root/DEBIAN" \
        "$pair_lproj_root/$(dirname "$pair_localizable_path")" \
        "$pair_packages"
    printf '%s\n' 'Package: cydia' 'Version: 1.2.3' \
        "Architecture: $pair_architecture" \
        'Maintainer: Test <test@example.invalid>' \
        'Description: rollback fixture' >"$pair_cydia_root/DEBIAN/control"
    printf '%s\n' '#!/bin/sh' 'exit 0' >"$pair_cydia_root/DEBIAN/preinst"
    printf '%s\n' '#!/bin/sh' 'exit 0' >"$pair_cydia_root/DEBIAN/postinst"
    printf '%s\n' 'interest-noawait /Applications' \
        >"$pair_cydia_root/DEBIAN/triggers"
    chmod 755 "$pair_cydia_root/DEBIAN/preinst" \
        "$pair_cydia_root/DEBIAN/postinst"
    printf '%s\n' fixture-app >"$pair_cydia_root/$pair_app_path"
    printf '%s\n' fixture-cydo >"$pair_cydia_root/$pair_cydo_path"
    chmod 755 "$pair_cydia_root/$pair_app_path" \
        "$pair_cydia_root/$pair_cydo_path"
    if [ "$pair_layout" = rootful ]; then
        ln -s Cydia "$pair_cydia_root/Applications/Cydia.app/fixture-tool"
        ln -s /usr/share/fixture/icon.png \
            "$pair_cydia_root/Applications/Cydia.app/fixture-icon.png"
    fi
    printf '%s\n' 'Package: cydia-lproj' 'Version: 1.2.0' \
        "Architecture: $pair_architecture" \
        'Maintainer: Test <test@example.invalid>' \
        'Description: translation fixture' >"$pair_lproj_root/DEBIAN/control"
    printf '%s\n' fixture-translation \
        >"$pair_lproj_root/$pair_localizable_path"

    pair_cydia_file=cydia_1.2.3_${pair_architecture}.deb
    pair_lproj_file=cydia-lproj_1.2.0_${pair_architecture}.deb
    build_package "$pair_cydia_root" "$pair_packages/$pair_cydia_file"
    build_package "$pair_lproj_root" "$pair_packages/$pair_lproj_file"

    pair_lproj_list=$pair_base/lproj-list
    printf '%s  %s\n' "$(hash "$pair_lproj_root/$pair_localizable_path")" \
        "$pair_localizable_path" >"$pair_lproj_list"
    pair_manifest=$pair_base/manifest
    {
        echo schema=1
        echo layout=$pair_layout
        echo cydia_file=$pair_cydia_file
        echo cydia_version=1.2.3
        echo cydia_architecture=$pair_architecture
        echo cydia_sha256=$(hash "$pair_packages/$pair_cydia_file")
        echo cydia_app_sha256=$(hash "$pair_cydia_root/$pair_app_path")
        echo cydia_app_mode=-rwxr-xr-x
        echo cydia_cydo_sha256=$(hash "$pair_cydia_root/$pair_cydo_path")
        echo cydia_cydo_mode=-rwxr-xr-x
        echo cydia_preinst_sha256=$(hash "$pair_cydia_root/DEBIAN/preinst")
        echo cydia_preinst_mode=-rwxr-xr-x
        echo cydia_postinst_sha256=$(hash "$pair_cydia_root/DEBIAN/postinst")
        echo cydia_postinst_mode=-rwxr-xr-x
        echo cydia_triggers_sha256=$(hash "$pair_cydia_root/DEBIAN/triggers")
        echo cydia_triggers_mode=-rw-r--r--
        echo lproj_file=$pair_lproj_file
        echo lproj_version=1.2.0
        echo lproj_architecture=$pair_architecture
        echo lproj_sha256=$(hash "$pair_packages/$pair_lproj_file")
        echo lproj_payload_sha256=$(hash "$pair_lproj_list")
    } >"$pair_manifest"
}

expect_failure() {
    failure_label=$1
    failure_base=$2
    if "$verifier" "$failure_base/packages" "$failure_base/manifest" \
            >"$failure_base/verifier.out" 2>&1; then
        fail "$failure_label passed"
    fi
}

clone_pair() {
    source_name=$1
    destination_name=$2
    cp -R "$temporary/$source_name" "$temporary/$destination_name"
}

refresh_archive_hash() {
    fixture_base=$1
    archive_key=$2
    archive_file_key=$3
    archive_file=$(manifest_value "$fixture_base/manifest" "$archive_file_key")
    replace_manifest_value "$fixture_base/manifest" "$archive_key" \
        "$(hash "$fixture_base/packages/$archive_file")"
}

mutate_deb_tar() {
    mut_deb=$1
    mut_member=$2
    mut_kind=$3
    mut_work=$(mktemp -d "$temporary/mutation.XXXXXX")
    mut_compressed=$mut_work/$mut_member
    mut_tar=$mut_work/archive.tar
    mut_input=$mut_work/input
    mkdir -p "$mut_input"
    printf '%s\n' malicious >"$mut_input/escape"
    ln -s escape "$mut_input/link"
    ar p "$mut_deb" "$mut_member" >"$mut_compressed" ||
        fail "could not read $mut_member"
    xz -dc "$mut_compressed" >"$mut_tar" ||
        fail "could not decompress $mut_member"
    case "$mut_kind" in
        traversal)
            tar -rf "$mut_tar" -C "$mut_input" \
                -s ',^./escape$,./../escape,' ./escape
            ;;
        repeated-prefix)
            tar -rf "$mut_tar" -C "$mut_input" \
                -s ',^./escape$,././Applications/escape,' ./escape
            ;;
        absolute)
            tar -P -rf "$mut_tar" -C "$mut_input" \
                -s ',^./escape$,/absolute/escape,' ./escape
            ;;
        duplicate)
            tar -rf "$mut_tar" -C "$mut_input" \
                -s ',^./escape$,./Applications/Cydia.app/Cydia,' ./escape
            ;;
        dot-alias)
            tar -rf "$mut_tar" -C "$mut_input" \
                -s ',^./escape$,./.,' ./escape
            ;;
        dotdot-alias)
            tar -rf "$mut_tar" -C "$mut_input" \
                -s ',^./escape$,./..,' ./escape
            ;;
        double-slash)
            tar -rf "$mut_tar" -C "$mut_input" \
                -s ',^./escape$,./Applications//escape,' ./escape
            ;;
        file-descendant)
            tar -rf "$mut_tar" -C "$mut_input" \
                -s ',^./escape$,./Applications/Cydia.app/blocker,' ./escape
            tar -rf "$mut_tar" -C "$mut_input" \
                -s ',^./escape$,./Applications/Cydia.app/blocker/child,' ./escape
            ;;
        link-descendant)
            tar -rf "$mut_tar" -C "$mut_input" \
                -s ',^./link$,./Applications/Cydia.app/linked,' ./link
            tar -rf "$mut_tar" -C "$mut_input" \
                -s ',^./escape$,./Applications/Cydia.app/linked/child,' ./escape
            ;;
        *) fail "unknown archive mutation: $mut_kind" ;;
    esac
    xz -c "$mut_tar" >"$mut_compressed" ||
        fail "could not recompress $mut_member"
    (
        cd "$mut_work"
        ar r "$mut_deb" "$mut_member" >/dev/null
    ) || fail "could not replace $mut_member"
}

for command in ar dpkg-deb shasum tar xz; do
    command -v "$command" >/dev/null 2>&1 || fail "$command is unavailable"
done

create_pair rootful rootful iphoneos-arm ''
"$verifier" "$temporary/rootful/packages" "$temporary/rootful/manifest" \
    >/dev/null || fail "valid rootful pair failed"

create_pair rootless rootless iphoneos-arm64 var/jb
"$verifier" "$temporary/rootless/packages" "$temporary/rootless/manifest" \
    >/dev/null || fail "valid rootless pair failed"

clone_pair rootful wrong-app-hash
replace_manifest_value "$temporary/wrong-app-hash/manifest" \
    cydia_app_sha256 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
expect_failure "wrong installed binary hash" "$temporary/wrong-app-hash"

clone_pair rootful wrong-layout
replace_manifest_value "$temporary/wrong-layout/manifest" layout rootless
expect_failure "wrong package layout" "$temporary/wrong-layout"

clone_pair rootful duplicate-key
printf '%s\n' schema=1 >>"$temporary/duplicate-key/manifest"
expect_failure "duplicate manifest key" "$temporary/duplicate-key"

clone_pair rootful unknown-key
printf '%s\n' unsupported_key=value >>"$temporary/unknown-key/manifest"
expect_failure "unknown manifest key" "$temporary/unknown-key"

clone_pair rootful malformed-line
printf '%s\n' malformed-line >>"$temporary/malformed-line/manifest"
expect_failure "malformed manifest line" "$temporary/malformed-line"

clone_pair rootful empty-key
printf '%s\n' '=value' >>"$temporary/empty-key/manifest"
expect_failure "empty manifest key" "$temporary/empty-key"

clone_pair rootless rootless-escape
mkdir -p "$temporary/rootless-escape/cydia-root/usr/share"
printf '%s\n' escape >"$temporary/rootless-escape/cydia-root/usr/share/escape"
rootless_cydia_file=$(manifest_value "$temporary/rootless-escape/manifest" cydia_file)
build_package "$temporary/rootless-escape/cydia-root" \
    "$temporary/rootless-escape/packages/$rootless_cydia_file"
refresh_archive_hash "$temporary/rootless-escape" cydia_sha256 cydia_file
expect_failure "rootless payload escape" "$temporary/rootless-escape"

clone_pair rootful linked-app
mv "$temporary/linked-app/cydia-root/Applications/Cydia.app/Cydia" \
    "$temporary/linked-app/cydia-root/Applications/Cydia.app/Cydia.real"
ln -s Cydia.real "$temporary/linked-app/cydia-root/Applications/Cydia.app/Cydia"
linked_cydia_file=$(manifest_value "$temporary/linked-app/manifest" cydia_file)
build_package "$temporary/linked-app/cydia-root" \
    "$temporary/linked-app/packages/$linked_cydia_file"
refresh_archive_hash "$temporary/linked-app" cydia_sha256 cydia_file
expect_failure "linked Cydia binary" "$temporary/linked-app"

clone_pair rootful linked-localization
mv "$temporary/linked-localization/lproj-root/Applications/Cydia.app/en.lproj/Localizable.strings" \
    "$temporary/linked-localization/lproj-root/Applications/Cydia.app/en.lproj/Localizable.real"
ln -s Localizable.real \
    "$temporary/linked-localization/lproj-root/Applications/Cydia.app/en.lproj/Localizable.strings"
linked_lproj_file=$(manifest_value "$temporary/linked-localization/manifest" lproj_file)
build_package "$temporary/linked-localization/lproj-root" \
    "$temporary/linked-localization/packages/$linked_lproj_file"
refresh_archive_hash "$temporary/linked-localization" lproj_sha256 lproj_file
expect_failure "linked localization" "$temporary/linked-localization"

clone_pair rootful nonexecutable-app
chmod 644 "$temporary/nonexecutable-app/cydia-root/Applications/Cydia.app/Cydia"
nonexec_cydia_file=$(manifest_value "$temporary/nonexecutable-app/manifest" cydia_file)
build_package "$temporary/nonexecutable-app/cydia-root" \
    "$temporary/nonexecutable-app/packages/$nonexec_cydia_file"
refresh_archive_hash "$temporary/nonexecutable-app" cydia_sha256 cydia_file
expect_failure "non-executable Cydia binary" "$temporary/nonexecutable-app"

clone_pair rootful special-member
mkfifo "$temporary/special-member/cydia-root/Applications/Cydia.app/unsupported.pipe"
special_cydia_file=$(manifest_value "$temporary/special-member/manifest" cydia_file)
build_package "$temporary/special-member/cydia-root" \
    "$temporary/special-member/packages/$special_cydia_file"
refresh_archive_hash "$temporary/special-member" cydia_sha256 cydia_file
expect_failure "special payload member" "$temporary/special-member"

for mutation in traversal repeated-prefix absolute duplicate dot-alias \
        dotdot-alias double-slash file-descendant link-descendant; do
    clone_pair rootful "unsafe-$mutation"
    mutation_base=$temporary/unsafe-$mutation
    mutation_cydia_file=$(manifest_value "$mutation_base/manifest" cydia_file)
    mutate_deb_tar "$mutation_base/packages/$mutation_cydia_file" \
        data.tar.xz "$mutation"
    refresh_archive_hash "$mutation_base" cydia_sha256 cydia_file
    expect_failure "unsafe $mutation member" "$mutation_base"
done

clone_pair rootful unsafe-control
unsafe_control_base=$temporary/unsafe-control
unsafe_control_file=$(manifest_value "$unsafe_control_base/manifest" cydia_file)
mutate_deb_tar "$unsafe_control_base/packages/$unsafe_control_file" \
    control.tar.xz traversal
refresh_archive_hash "$unsafe_control_base" cydia_sha256 cydia_file
expect_failure "unsafe control member" "$unsafe_control_base"

echo "[verify-rollback-package-tests][ ok ] exact historical pair contract"
