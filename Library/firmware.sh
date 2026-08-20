#!/bin/bash

set -e

shopt -s extglob
shopt -s nullglob

. "$(dirname "${BASH_SOURCE[0]}")/package-paths.sh"
export PATH=${CYDIA_BOOTSTRAP_PATH}

version=$(sw_vers -productVersion)
cpu=$(uname -p)

if [[ ${cpu} == arm || ${cpu} == arm64 ]]; then
    model=hw.machine
    os=ios
else
    model=hw.model
    os=macosx
fi

model=$(sysctl -n "${model}")

if [[ ${CYDIA_PREFIX} == /var/jb ]]; then
    arch=iphoneos-arm64
else
    arch=iphoneos-arm
fi

if [[ ${cpu} != arm && ${cpu} != arm64 ]]; then
    arch=cydia
fi

function lower() {
    sed -e 'y/ABCDEFGHIJKLMNOPQRSTUVWXYZ/abcdefghijklmnopqrstuvwxyz/'
}

tmp=$(mktemp -d "${TMPDIR:-/tmp}/cydia-firmware.XXXXXX")
trap 'rm -rf "${tmp}"' EXIT

declare -a packages
declare -a replacement_names

# Generate an empty package and let dpkg own its status/database bookkeeping.
# This deliberately avoids writing status or info files directly: those files
# are an implementation detail that changes across dpkg releases.
function pseudo() {
    local package=$1 version=$2 description=$3 name=$4
    local root=${tmp}/${package}
    local deb=${tmp}/${package}.deb

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
        [[ -n ${name} ]] && echo "Name: ${name}"
    } >"${root}/DEBIAN/control"

    "${CYDIA_DPKG_DEB}" -Zxz -b "${root}" "${deb}" >/dev/null
    packages+=("${deb}")
    replacement_names+=("${package}")
}

function is_replacement() {
    local expected
    for expected in "${replacement_names[@]}"; do
        [[ ${expected} == "$1" ]] && return 0
    done
    return 1
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

if [[ ${cpu} == arm || ${cpu} == arm64 ]]; then
    pseudo "firmware" "${version}" "almost impressive Apple frameworks" "iOS Firmware"

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
        (ipad) for name in ipad wildcat; do
            pseudo "gsc.${name}" "${value}" "this device has a very large screen" "iPad"
        done;;

        (*)
            pseudo "gsc.${name}" "${value}" "virtual GraphicsServices dependency"
            ;;
        esac
    done <<<"${gssc}"
fi

pseudo "cy+os.${os}" "${version}" "virtual operating system dependency"
pseudo "cy+cpu.${cpu}" "0" "virtual CPU dependency"

name=${model%%*([0-9]),*([0-9])}
version=${model#${name}}
name=$(lower <<<${name})
version=${version/,/.}
pseudo "cy+model.${name}" "${version}" "virtual model dependency"

pseudo "cy+kernel.$(lower <<<$(sysctl -n kern.ostype))" \
    "$(sysctl -n kern.osrelease)" "virtual kernel dependency"
pseudo "cy+lib.corefoundation" "$(${CYDIA_LIBEXEC}/cfversion)" \
    "virtual corefoundation dependency"

"${CYDIA_DPKG}" --install "${packages[@]}"

# Installing a replacement upgrades an existing synthetic package in place.
# Only purge stale names after every replacement package has been built and
# installed successfully, so a generator or disk failure cannot leave the
# package database without its Essential firmware metadata.
declare -a obsolete
while IFS= read -r package; do
    if [[ ${package} == firmware || ${package} == gsc.* || ${package} == cy+* ]]; then
        is_replacement "${package}" || obsolete+=("${package}")
    fi
done < <("${CYDIA_DPKG_QUERY}" -W -f='${Package}\n' 2>/dev/null || true)

if [[ ${#obsolete[@]} -ne 0 ]]; then
    "${CYDIA_DPKG}" --purge --force-all "${obsolete[@]}"
fi

if [[ ${cpu} == arm || ${cpu} == arm64 ]]; then
    if [[ -z ${CYDIA_PREFIX} ]]; then
        if [[ ! -h /User && -d /User ]]; then
            "${CYDIA_BSD_BIN}/cp" -a /User/. /var/mobile/
        fi && "${CYDIA_BSD_BIN}/rm" -rf /User && \
            "${CYDIA_BSD_BIN}/ln" -s "/var/mobile" /User
    fi

    echo 6 >"${CYDIA_STATE}/firmware.ver"
fi
