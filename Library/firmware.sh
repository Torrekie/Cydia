#!/bin/bash
# Modified work Copyright (C) 2026 Torrekie
# SPDX-License-Identifier: GPL-3.0-or-later

set -e

shopt -s extglob
shopt -s nullglob

case ${BASH_SOURCE[0]} in
    */*) cydia_firmware_dir=${BASH_SOURCE[0]%/*} ;;
    *) cydia_firmware_dir=. ;;
esac
. "${cydia_firmware_dir}/package-paths.sh"
unset cydia_firmware_dir
export PATH=${CYDIA_BOOTSTRAP_PATH}

readonly firmware_owner='cydia-refurbished.torrekie.dev/v1'
readonly firmware_manifest_name='firmware-packages.list'
firmware_tmp=
firmware_manifest_tmp=

function lower() {
    sed -e 'y/ABCDEFGHIJKLMNOPQRSTUVWXYZ/abcdefghijklmnopqrstuvwxyz/'
}

function contains_name() {
    local expected=$1 candidate
    shift
    for candidate in "$@"; do
        [[ ${candidate} == "${expected}" ]] && return 0
    done
    return 1
}

function valid_package_name() {
    [[ $1 =~ ^[a-z0-9][a-z0-9+.-]*$ ]]
}

function hyphenate() {
    local value=$1 result= character index
    for ((index = 0; index < ${#value}; ++index)); do
        character=${value:index:1}
        if [[ ${character} == [[:upper:]] ]]; then
            [[ -n ${result} ]] && result+=-
            result+=$(lower <<<"${character}")
        else
            result+=${character}
        fi
    done
    printf '%s\n' "${result}"
}

# Read the installed package database once. A failed query is fatal: treating
# an unreadable database as an empty one could overwrite bootstrap-owned
# virtual packages.
function inspect_package() {
    local expected=$1 package status owner
    package_installed=0
    package_owned=0

    while IFS='|' read -r package status owner; do
        if [[ ${package} == "${expected}" && ${status} == 'install ok installed' ]]; then
            package_installed=1
            [[ ${owner} == "${firmware_owner}" ]] && package_owned=1
            return 0
        fi
    done <"${installed_snapshot}"
}

# Generate an empty package and let dpkg own its status/database bookkeeping.
# The ownership marker is retained by dpkg and prevents a stale manifest from
# granting ownership over a package supplied by the bootstrap.
function pseudo() {
    local package=$1 version=$2 description=$3 name=$4
    local root=${firmware_tmp}/${package}
    local deb=${firmware_tmp}/${package}.deb

    mkdir -p "${root}/DEBIAN"
    {
        echo "Package: ${package}"
        echo "Essential: yes"
        echo "Priority: required"
        echo "Section: System"
        echo "Installed-Size: 0"
        echo "Architecture: ${arch}"
        echo "Version: ${version}"
        echo "Description: ${description}"
        echo "Maintainer: Torrekie <me@torrekie.dev>"
        echo "Tag: role::cydia"
        echo "X-Cydia-Firmware-Owner: ${firmware_owner}"
        [[ -n ${name} ]] && echo "Name: ${name}"
    } >"${root}/DEBIAN/control"

    "${CYDIA_DPKG_DEB}" -Zxz -b "${root}" "${deb}" >/dev/null
    packages+=("${deb}")
}

# A missing virtual package is safe to create. An installed package is safe to
# update only when it carries Cydia's ownership marker. Exact-name collisions
# from Procursus or another bootstrap are deliberately preserved.
function ensure_pseudo() {
    local package=$1 version=$2 description=$3 name=$4
    contains_name "${package}" "${desired_names[@]}" || desired_names+=("${package}")

    inspect_package "${package}"
    if [[ ${package_installed} == 1 && ${package_owned} != 1 ]]; then
        echo "Preserving externally owned virtual package ${package}" >&2
        return 0
    fi

    pseudo "${package}" "${version}" "${description}" "${name}"
    contains_name "${package}" "${next_managed_names[@]}" || next_managed_names+=("${package}")
}

function write_managed_manifest() {
    local package
    firmware_manifest_tmp=$(mktemp "${CYDIA_STATE}/.${firmware_manifest_name}.XXXXXX")
    for package in "${next_managed_names[@]}"; do
        printf '%s\n' "${package}" >>"${firmware_manifest_tmp}"
    done
    "${CYDIA_BSD_BIN}/mv" -f "${firmware_manifest_tmp}" "${managed_manifest}"
    firmware_manifest_tmp=
}

function write_firmware_version() {
    local version_tmp
    version_tmp=$(mktemp "${CYDIA_STATE}/.firmware.ver.XXXXXX")
    if ! printf '6\n' >"${version_tmp}" ||
       ! "${CYDIA_BSD_BIN}/mv" -f "${version_tmp}" "${CYDIA_STATE}/firmware.ver"; then
        "${CYDIA_BSD_BIN}/rm" -f "${version_tmp}"
        return 1
    fi
}

function migrate_user_directory() {
    local user_path=$1 mobile_path=$2

    [[ -h ${user_path} ]] && return 0
    if [[ -d ${user_path} ]]; then
        if ! "${CYDIA_BSD_BIN}/cp" -a "${user_path}/." "${mobile_path}/"; then
            return 1
        fi
    fi
    if ! "${CYDIA_BSD_BIN}/rm" -rf "${user_path}"; then
        return 1
    fi
    "${CYDIA_BSD_BIN}/ln" -s "${mobile_path}" "${user_path}"
}

# Kept separate so the failure ordering can be exercised without touching the
# host's real /User path. Production always supplies /User and /var/mobile.
function finalize_firmware_state() {
    local user_path=$1 mobile_path=$2
    if [[ -z ${CYDIA_PREFIX} ]]; then
        migrate_user_directory "${user_path}" "${mobile_path}" || return 1
    fi
    write_firmware_version
}

function cleanup_firmware_temporary_files() {
    if [[ -n ${firmware_manifest_tmp} ]]; then
        "${CYDIA_BSD_BIN}/rm" -f "${firmware_manifest_tmp}"
    fi
    if [[ -n ${firmware_tmp} ]]; then
        "${CYDIA_BSD_BIN}/rm" -rf "${firmware_tmp}"
    fi
}

function firmware_main() {
    local version model gssc line name value package arch cpu
    local managed_manifest installed_snapshot package_installed package_owned

    version=$(sw_vers -productVersion)
    arch=$("${CYDIA_DPKG}" --print-architecture)
    case "${arch}" in
        iphoneos-arm)
            cpu=arm
            ;;
        iphoneos-arm64)
            cpu=arm64
            ;;
        *)
            echo "Unsupported dpkg architecture for Cydia firmware packages: ${arch}" >&2
            return 1
            ;;
    esac
    model=$(sysctl -n hw.machine)

    mkdir -p "${CYDIA_STATE}"
    managed_manifest=${CYDIA_STATE}/${firmware_manifest_name}
    firmware_tmp=$(mktemp -d "${TMPDIR:-/tmp}/cydia-firmware.XXXXXX")
    installed_snapshot=${firmware_tmp}/installed-packages
    trap cleanup_firmware_temporary_files EXIT

    declare -a packages
    declare -a desired_names
    declare -a managed_names
    declare -a next_managed_names
    declare -a obsolete_names

    if [[ -e ${managed_manifest} ]]; then
        while IFS= read -r package || [[ -n ${package} ]]; do
            if valid_package_name "${package}" && ! contains_name "${package}" "${managed_names[@]}"; then
                managed_names+=("${package}")
            fi
        done <"${managed_manifest}"
    fi

    "${CYDIA_DPKG_QUERY}" -W \
        -f='${Package}|${Status}|${X-Cydia-Firmware-Owner}\n' >"${installed_snapshot}"

    ensure_pseudo "firmware" "${version}" "almost impressive Apple frameworks" "iOS Firmware"

    while [[ 1 ]]; do
        gssc=$(gssc 2>&1)
        if [[ ${gssc} != *'(null)'* ]]; then
            break
        fi
        sleep 1
    done

    gssc_pattern='^[[:space:]]+([^[:space:]]+)[[:space:]]*=[[:space:]]*([0-9.]+);$'
    while IFS= read -r line; do
        [[ ${line} =~ ${gssc_pattern} ]] || continue
        name=${BASH_REMATCH[1]}
        value=${BASH_REMATCH[2]}
        name=${name#\"}
        name=${name%\"}
        [[ ${value} == 0 ]] && continue
        name=$(hyphenate "${name}")

        case "${name}" in
            ipad)
                for name in ipad wildcat; do
                    ensure_pseudo "gsc.${name}" "${value}" \
                        "this device has a very large screen" "iPad"
                done
                ;;
            *)
                ensure_pseudo "gsc.${name}" "${value}" \
                    "virtual GraphicsServices dependency" ""
                ;;
        esac
    done <<<"${gssc}"

    ensure_pseudo "cy+os.iphoneos" "${version}" "virtual operating system dependency" ""
    ensure_pseudo "cy+cpu.${cpu}" "0" "virtual CPU dependency" ""

    name=${model%%*([0-9]),*([0-9])}
    value=${model#${name}}
    name=$(lower <<<"${name}")
    value=${value/,/.}
    ensure_pseudo "cy+model.${name}" "${value}" "virtual model dependency" ""

    name=$(lower <<<"$(sysctl -n kern.ostype)")
    value=$(sysctl -n kern.osrelease)
    ensure_pseudo "cy+kernel.${name}" "${value}" "virtual kernel dependency" ""
    ensure_pseudo "cy+lib.corefoundation" "$("${CYDIA_LIBEXEC}/cfversion")" \
        "virtual corefoundation dependency" ""

    if [[ ${#packages[@]} -ne 0 ]]; then
        "${CYDIA_DPKG}" --install "${packages[@]}"
    fi

    # Only names from the durable manifest can become stale, and even those
    # must still carry our marker before they may be removed. This prevents a
    # later bootstrap takeover of the same name from being purged.
    for package in "${managed_names[@]}"; do
        contains_name "${package}" "${desired_names[@]}" && continue
        inspect_package "${package}"
        if [[ ${package_installed} == 1 && ${package_owned} == 1 ]]; then
            obsolete_names+=("${package}")
        fi
    done

    if [[ ${#obsolete_names[@]} -ne 0 ]]; then
        "${CYDIA_DPKG}" --purge "${obsolete_names[@]}"
    fi

    # The manifest moves into place only after both package-manager operations
    # succeed. Marker-based adoption makes a partially completed dpkg run safe
    # to retry if dpkg itself changed some packages before returning failure.
    write_managed_manifest
    finalize_firmware_state /User /var/mobile
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    firmware_main "$@"
fi
