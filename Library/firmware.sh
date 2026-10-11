#!/bin/bash
# Modified work Copyright (C) 2026 Torrekie
# SPDX-License-Identifier: GPL-3.0-or-later

set -e
set -o pipefail
shopt -s extglob
shopt -s nullglob

case ${BASH_SOURCE[0]} in
    */*) cydia_firmware_dir=${BASH_SOURCE[0]%/*} ;;
    *) cydia_firmware_dir=. ;;
esac
. "${cydia_firmware_dir}/package-paths.sh"
readonly firmware_source_directory=${cydia_firmware_dir}
unset cydia_firmware_dir
export PATH=${CYDIA_BOOTSTRAP_PATH}
export LC_ALL=C

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
        case ${character} in
            A) character=a ;; B) character=b ;; C) character=c ;;
            D) character=d ;; E) character=e ;; F) character=f ;;
            G) character=g ;; H) character=h ;; I) character=i ;;
            J) character=j ;; K) character=k ;; L) character=l ;;
            M) character=m ;; N) character=n ;; O) character=o ;;
            P) character=p ;; Q) character=q ;; R) character=r ;;
            S) character=s ;; T) character=t ;; U) character=u ;;
            V) character=v ;; W) character=w ;; X) character=x ;;
            Y) character=y ;; Z) character=z ;;
            _) result+=-; continue ;;
            *) result+=${character}; continue ;;
        esac
        [[ -n ${result} ]] && result+=-
        result+=${character}
    done
    printf '%s\n' "${result}"
}

function tsv_field() {
    local value=$1
    value=${value//%/%25}
    value=${value//$'\t'/%09}
    value=${value//$'\r'/%0D}
    value=${value//$'\n'/%0A}
    printf '%s' "${value}"
}

function validate_firmware_environment() {
    local mode=$1 require_frontend_lock=$2 physical_source physical_libexec
    if [[ ${CYDIA_LIBEXEC} != "${CYDIA_PREFIX}/usr/libexec/cydia" ||
          ${CYDIA_DPKG} != "${CYDIA_PREFIX}/usr/bin/dpkg" ||
          ${CYDIA_DPKG_DEB} != "${CYDIA_PREFIX}/usr/bin/dpkg-deb" ||
          ${CYDIA_DPKG_QUERY} != "${CYDIA_PREFIX}/usr/bin/dpkg-query" ||
          ${CYDIA_STATE} != "${CYDIA_PREFIX}/var/lib/cydia" ]]; then
        echo "Firmware helper paths disagree with the installed package environment" >&2
        return 1
    fi
    physical_source=$(cd -P "${firmware_source_directory}" && pwd -P)
    physical_libexec=$(cd -P "${CYDIA_LIBEXEC}" && pwd -P)
    if [[ ${physical_source} != "${physical_libexec}" ||
          ! -f ${CYDIA_LIBEXEC}/firmware-discovery ||
          ! -x ${CYDIA_LIBEXEC}/firmware-discovery ||
          -L ${CYDIA_LIBEXEC}/firmware-discovery ]]; then
        echo "Firmware discovery must be the installed package's libexec binary" >&2
        return 1
    fi
    if [[ ${mode} == apply && ${require_frontend_lock} == 1 &&
          (-z ${CYDIA_FIRMWARE_ROOT:-} || -z ${CYDIA_FIRMWARE_ADMINDIR:-}) ]]; then
        echo "Firmware generation requires the privileged runtime descriptor" >&2
        return 1
    fi
    if [[ ${firmware_root} != /* || ${firmware_admin} != /* ||
          ${firmware_root} == *$'\n'* || ${firmware_admin} == *$'\n'* ||
          ${firmware_root} == *$'\r'* || ${firmware_admin} == *$'\r'* ]]; then
        echo "Invalid firmware root or administrative directory" >&2
        return 1
    fi
    local tool
    for tool in "${firmware_dpkg}" "${firmware_query}" "${firmware_deb}"; do
        if [[ ${tool} != /* || ! -f ${tool} || ! -x ${tool} ]]; then
            echo "Invalid firmware package-management executable" >&2
            return 1
        fi
    done
}

# A status is not an ownership claim. Keep every database record, including
# held, removed-with-conffiles, unpacked and foreign-architecture providers.
# The index avoids rescanning the snapshot for each discovered capability.
function index_package_records() {
    local package architecture status version provides owner provide alias aliases
    record_name_index=$'\n'
    record_packages=() record_architectures=() record_statuses=()
    record_versions=() record_owners=() record_aliases=()
    while IFS='|' read -r package architecture status version provides owner; do
        [[ -n ${package} ]] || continue
        if ! valid_package_name "${package}" || [[ -z ${status} ]]; then
            echo "Invalid firmware provider snapshot" >&2
            return 1
        fi
        record_packages+=("${package}")
        record_architectures+=("${architecture}")
        record_statuses+=("${status}")
        record_versions+=("${version}")
        record_owners+=("${owner}")
        record_name_index+=${package}$'\n'
        aliases=$'\n'${package}$'\n'
        local -a provided_names
        IFS=, read -r -a provided_names <<<"${provides}"
        for provide in "${provided_names[@]}"; do
            provide=${provide##+([[:space:]])}
            alias=${provide%%[[:space:](]*}
            valid_package_name "${alias}" || continue
            aliases+=${alias}$'\n'
            record_name_index+=${alias}$'\n'
        done
        record_aliases+=("${aliases}")
    done <"${installed_snapshot}"
}

function inspect_package() {
    local expected=$1 index
    provider_indices=()
    [[ ${record_name_index} == *$'\n'"${expected}"$'\n'* ]] || return 0
    for ((index = 0; index < ${#record_packages[@]}; ++index)); do
        [[ ${record_aliases[index]} == *$'\n'"${expected}"$'\n'* ]] && provider_indices+=("${index}")
    done
    return 0
}

function add_candidate() {
    local package=$1 version=$2 description name=
    valid_package_name "${package}" || {
        echo "Invalid discovered firmware package name: ${package}" >&2
        return 1
    }
    [[ ${version} =~ ^[0-9]+([.][0-9]+)*$ ]] || {
        echo "Invalid discovered firmware package version: ${package}" >&2
        return 1
    }
    [[ ${desired_name_index} != *$'\n'"${package}"$'\n'* ]] || return 0
    case ${package} in
        firmware) description='almost impressive Apple frameworks'; name='iOS Firmware' ;;
        gsc.ipad|gsc.wildcat) description='this device has a very large screen'; name=iPad ;;
        gsc.*) description='virtual GraphicsServices dependency' ;;
        cy+os.*) description='virtual operating system dependency' ;;
        cy+cpu.*) description='virtual CPU dependency' ;;
        cy+model.*) description='virtual model dependency' ;;
        cy+kernel.*) description='virtual kernel dependency' ;;
        cy+lib.corefoundation) description='virtual corefoundation dependency' ;;
        *) echo "Unsupported firmware capability family: ${package}" >&2; return 1 ;;
    esac
    desired_names+=("${package}")
    desired_versions+=("${version}")
    desired_descriptions+=("${description}")
    desired_display_names+=("${name}")
    desired_name_index+=${package}$'\n'
}

function collect_candidates() {
    local kind name value gssc line cpu
    "${CYDIA_LIBEXEC}/firmware-discovery" >"${firmware_tmp}/discovery"
    while IFS=$'\t' read -r kind name value; do
        case ${kind} in
            identity) add_candidate "${name}" "${value}" ;;
            gestalt)
                name=$(hyphenate "${name}")
                add_candidate "gsc.${name}" "${value}"
                [[ ${name} != ipad ]] || add_candidate gsc.wildcat "${value}"
                ;;
            *) echo "Invalid firmware discovery output" >&2; return 1 ;;
        esac
    done <"${firmware_tmp}/discovery"

    # Hardware identity does not replace the legacy dpkg-native CPU alias:
    # rootful arm package environments on arm64 hardware still need cy+cpu.arm.
    case ${arch} in
        iphoneos-arm) cpu=arm ;;
        iphoneos-arm64) cpu=arm64 ;;
        *) echo "Unsupported dpkg architecture: ${arch}" >&2; return 1 ;;
    esac
    add_candidate "cy+cpu.${cpu}" 0

    gssc_state=unavailable
    if command -v gssc >/dev/null 2>&1; then
        gssc=$(gssc)
        if [[ ${gssc} == *'(null)'* ]]; then
            echo "GraphicsServices discovery is unavailable; retry the preview later" >&2
            return 1
        fi
        gssc_state=available
        local pattern='^[[:space:]]+([^[:space:]]+)[[:space:]]*=[[:space:]]*([0-9]+([.][0-9]+)*);$'
        while IFS= read -r line; do
            [[ ${line} =~ ${pattern} ]] || continue
            name=${BASH_REMATCH[1]}
            value=${BASH_REMATCH[2]}
            name=${name#\"}; name=${name%\"}
            [[ ${value//[0.]/} != "" ]] || continue
            name=$(hyphenate "${name}")
            add_candidate "gsc.${name}" "${value}"
            [[ ${name} != ipad ]] || add_candidate gsc.wildcat "${value}"
        done <<<"${gssc}"
    fi
    [[ ${#desired_names[@]} -ne 0 ]] || return 1
}

function classify_candidate() {
    local package=$1 proposed=$2 index
    candidate_action=preserve
    candidate_reason=current
    inspect_package "${package}"
    if [[ ${#provider_indices[@]} == 0 ]]; then
        candidate_action=create; candidate_reason=missing
        return 0
    fi
    for index in "${provider_indices[@]}"; do
        if [[ ${record_packages[index]} != "${package}" ]]; then
            candidate_reason=virtual-provider; return 0
        fi
    done
    for index in "${provider_indices[@]}"; do
        if [[ ${record_owners[index]} != "${firmware_owner}" ]]; then
            candidate_reason=external-provider; return 0
        fi
    done
    for index in "${provider_indices[@]}"; do
        if [[ ${record_architectures[index]} != "${arch}" ]]; then
            candidate_reason=foreign-architecture; return 0
        fi
    done
    if [[ ${#provider_indices[@]} != 1 ]]; then
        candidate_reason=multiple-providers; return 0
    fi
    index=${provider_indices[0]}
    if [[ ${record_statuses[index]} != 'install ok installed' ]]; then
        candidate_reason=package-state; return 0
    fi
    if [[ -z ${record_versions[index]} ]]; then
        candidate_reason=unknown-version; return 0
    fi
    if [[ ${record_versions[index]} == "${proposed}" ]]; then
        return 0
    fi
    if "${firmware_dpkg}" --compare-versions "${record_versions[index]}" lt "${proposed}"; then
        candidate_action=update; candidate_reason=owned-update
    else
        if [[ $? == 1 ]]; then candidate_reason=newer-provider
        else candidate_reason=unknown-version; fi
    fi
}

function emit_candidate() {
    local package=$1 proposed=$2 action=$3 reason=$4 index=${5-} value
    local provider_arch= provider_status= provider_version= provider_owner= provider_package=
    if [[ -n ${index} ]]; then
        provider_arch=${record_architectures[index]}
        provider_status=${record_statuses[index]}
        provider_version=${record_versions[index]}
        provider_owner=${record_owners[index]}
        provider_package=${record_packages[index]}
    fi
    printf 'candidate'
    for value in "${package}" "${proposed}" "${action}" "${reason}" \
        "${provider_arch}" "${provider_status}" "${provider_version}" "${provider_owner}" "${provider_package}"; do
        printf '\t'
        tsv_field "${value}"
    done
    printf '\n'
}

function build_preview() {
    local package index provider desired_index
    printf 'cydia-firmware-preview\t1\n'
    printf 'environment\t'; tsv_field "${arch}"
    printf '\t'; tsv_field "${CYDIA_PREFIX}"
    printf '\t'; tsv_field "${firmware_admin}"
    printf '\t'; tsv_field "${firmware_root}"; printf '\n'
    printf 'tool\tdpkg\t'; tsv_field "${firmware_dpkg}"; printf '\n'
    printf 'tool\tdpkg-query\t'; tsv_field "${firmware_query}"; printf '\n'
    printf 'tool\tdpkg-deb\t'; tsv_field "${firmware_deb}"; printf '\n'
    printf 'collector\tmobilegestalt\tcomplete\ncollector\tgssc\t%s\n' "${gssc_state}"
    # Sorting names and provider records makes the review token independent of
    # enumeration order. Every provider row is part of the reviewed preimage.
    for package in $(printf '%s\n' "${desired_names[@]}" | sort); do
        for ((desired_index = 0; desired_index < ${#desired_names[@]}; ++desired_index)); do
            [[ ${desired_names[desired_index]} == "${package}" ]] && break
        done
        classify_candidate "${package}" "${desired_versions[desired_index]}"
        plan_indices+=("${desired_index}")
        plan_actions+=("${candidate_action}")
        if [[ ${#provider_indices[@]} == 0 ]]; then
            emit_candidate "${package}" "${desired_versions[desired_index]}" \
                "${candidate_action}" "${candidate_reason}"
        else
            for provider in "${provider_indices[@]}"; do
                emit_candidate "${package}" "${desired_versions[desired_index]}" \
                    "${candidate_action}" "${candidate_reason}" "${provider}"
            done
        fi
    done
    # Retain historical aliases and providers that this collector no longer
    # discovers. A changed device/capability list never authorizes removal.
    for ((index = 0; index < ${#record_packages[@]}; ++index)); do
        package=${record_packages[index]}
        case ${package} in firmware|gsc.*|cy+*) ;; *) continue ;; esac
        [[ ${desired_name_index} != *$'\n'"${package}"$'\n'* ]] || continue
        emit_candidate "${package}" "${record_versions[index]}" preserve retained-provider "${index}"
    done
}

# Generate reviewed empty packages and let dpkg maintain its own database.
function pseudo() {
    local package=$1 version=$2 description=$3 name=$4
    local root=${firmware_tmp}/${package} deb=${firmware_tmp}/${package}.deb
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
        if [[ -n ${name} ]]; then echo "Name: ${name}"; fi
    } >"${root}/DEBIAN/control"
    "${firmware_deb}" -Zxz -b "${root}" "${deb}" >/dev/null
    packages+=("${deb}")
}

function write_managed_manifest() {
    local package
    firmware_manifest_tmp=$(mktemp "${CYDIA_STATE}/.${firmware_manifest_name}.XXXXXX")
    for package in "${next_managed_names[@]}"; do
        printf '%s\n' "${package}"
    done | sort -u >"${firmware_manifest_tmp}"
    "${CYDIA_BSD_BIN}/mv" -f "${firmware_manifest_tmp}" "${CYDIA_STATE}/${firmware_manifest_name}"
    firmware_manifest_tmp=
}

function cleanup_firmware_temporary_files() {
    [[ -z ${firmware_manifest_tmp} ]] || "${CYDIA_BSD_BIN}/rm" -f "${firmware_manifest_tmp}"
    [[ -z ${firmware_tmp} ]] || "${CYDIA_BSD_BIN}/rm" -rf "${firmware_tmp}"
}

function firmware_main() {
    local mode=preview require_frontend_lock=0 reviewed_token= review_token arch installed_snapshot package index desired_index
    local firmware_root=${CYDIA_FIRMWARE_ROOT:-${CYDIA_PREFIX:-/}}
    local firmware_admin=${CYDIA_FIRMWARE_ADMINDIR:-${CYDIA_DPKG_STATE}}
    local firmware_dpkg=${CYDIA_FIRMWARE_DPKG:-${CYDIA_DPKG}}
    local firmware_query=${CYDIA_FIRMWARE_DPKG_QUERY:-${CYDIA_DPKG_QUERY}}
    local firmware_deb=${CYDIA_FIRMWARE_DPKG_DEB:-${CYDIA_DPKG_DEB}}
    while [[ $# -ne 0 ]]; do
        case $1 in
            --preview) mode=preview ;;
            --apply) mode=apply ;;
            --require-frontend-lock) require_frontend_lock=1 ;;
            --review-token)
                [[ $# -ge 2 ]] || return 64
                reviewed_token=$2; shift ;;
            *) echo "Usage: firmware.sh --preview | --apply --require-frontend-lock --review-token SHA256" >&2; return 64 ;;
        esac
        shift
    done
    if [[ ${mode} == apply && ! ${reviewed_token} =~ ^[a-f0-9]{64}$ ]]; then
        echo "Explicit firmware generation requires the reviewed preview token" >&2
        return 64
    fi
    if [[ ${mode} == apply &&
          (${require_frontend_lock} != 1 || ${DPKG_FRONTEND_LOCKED:-} != 1) ]]; then
        echo "Firmware generation must be launched by the frontend-lock-owning privileged helper" >&2
        return 64
    fi
    validate_firmware_environment "${mode}" "${require_frontend_lock}"
    arch=$("${firmware_dpkg}" --root="${firmware_root}" --admindir="${firmware_admin}" --print-architecture)
    umask 077
    firmware_tmp=$(mktemp -d "${TMPDIR:-/tmp}/cydia-firmware.XXXXXX")
    trap cleanup_firmware_temporary_files EXIT
    installed_snapshot=${firmware_tmp}/providers
    "${firmware_query}" --admindir="${firmware_admin}" -W \
        -f='${Package}|${Architecture}|${Status}|${Version}|${Provides}|${X-Cydia-Firmware-Owner}\n' | \
        sort >"${installed_snapshot}"
    local -a record_packages record_architectures record_statuses record_versions record_owners record_aliases provider_indices
    local -a desired_names desired_versions desired_descriptions desired_display_names
    local -a plan_indices plan_actions packages next_managed_names
    local record_name_index desired_name_index=$'\n' candidate_action candidate_reason gssc_state
    index_package_records
    collect_candidates
    build_preview >"${firmware_tmp}/preview"
    review_token=$("${CYDIA_LIBEXEC}/firmware-discovery" --digest <"${firmware_tmp}/preview")
    [[ ${review_token} =~ ^[a-f0-9]{64}$ ]] || return 1
    if [[ ${mode} == preview ]]; then
        cat "${firmware_tmp}/preview"
        printf 'review\t%s\n' "${review_token}"
        return 0
    fi
    if [[ ${reviewed_token} != "${review_token}" ]]; then
        echo "Firmware providers or discovery changed; review a fresh preview" >&2
        return 75
    fi
    if [[ -L ${CYDIA_STATE} || (-e ${CYDIA_STATE} && ! -d ${CYDIA_STATE}) ]]; then
        echo "Cydia state must be a directory, not a symlink or another file type" >&2
        return 1
    fi
    # DPKG_FRONTEND_LOCKED is the helper handshake, not proof of a lock.
    # cydo verifies/acquires the real environment's lock and retains it in its
    # parent while this child checks the fresh snapshot and invokes dpkg.
    for ((index = 0; index < ${#plan_indices[@]}; ++index)); do
        case ${plan_actions[index]} in create|update) ;; *) continue ;; esac
        desired_index=${plan_indices[index]}
        pseudo "${desired_names[desired_index]}" "${desired_versions[desired_index]}" \
            "${desired_descriptions[desired_index]}" "${desired_display_names[desired_index]}"
        next_managed_names+=("${desired_names[desired_index]}")
    done
    if [[ ${#packages[@]} -ne 0 ]]; then
        "${firmware_dpkg}" --root="${firmware_root}" --admindir="${firmware_admin}" --install "${packages[@]}"
        for ((index = 0; index < ${#record_packages[@]}; ++index)); do
            [[ ${record_owners[index]} != "${firmware_owner}" ]] || \
                next_managed_names+=("${record_packages[index]}")
        done
        mkdir -p "${CYDIA_STATE}"
        write_managed_manifest
    fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    firmware_main "$@"
fi
