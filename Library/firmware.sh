#!/bin/bash

set -e

shopt -s extglob
shopt -s nullglob

. "$(dirname "${BASH_SOURCE[0]}")/package-paths.sh"

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
        echo "Maintainer: Jay Freeman (saurik) <saurik@saurik.com>"
        echo "Tag: role::cydia"
        [[ -n ${name} ]] && echo "Name: ${name}"
    } >"${root}/DEBIAN/control"

    "${CYDIA_DPKG_DEB}" -Zxz -b "${root}" "${deb}" >/dev/null
    packages+=("${deb}")
}

# Remove only the synthetic packages managed by this helper.  The package
# manager, rather than a hand-written status parser, decides how removal is
# represented in its current database format.
declare -a obsolete
while IFS= read -r package; do
    if [[ ${package} == firmware || ${package} == gsc.* || ${package} == cy+* ]]; then
        obsolete+=("${package}")
    fi
done < <("${CYDIA_DPKG_QUERY}" -W -f='${Package}\n' 2>/dev/null || true)

if [[ ${#obsolete[@]} -ne 0 ]]; then
    "${CYDIA_LIBEXEC}/cydo" --purge --force-all "${obsolete[@]}" || true
fi

if [[ ${cpu} == arm || ${cpu} == arm64 ]]; then
    pseudo "firmware" "${version}" "almost impressive Apple frameworks" "iOS Firmware"

    while [[ 1 ]]; do
        gssc=$(gssc 2>&1)
        if [[ ${gssc} != *'(null)'* ]]; then
            break
        fi
        sleep 1
    done

    while read -r name value; do case "${name}" in
        (ipad) for name in ipad wildcat; do
            pseudo "gsc.${name}" "${value}" "this device has a very large screen" "iPad"
        done;;

        (*)
            pseudo "gsc.${name}" "${value}" "virtual GraphicsServices dependency"
            ;;
    esac; done < <(echo "${gssc}" | sed -re '
        /^    [^ ]* = [0-9.]*;$/ ! d;
        s/^    ([^ ]*) = ([0-9.]*);$/\1 \2/;
        s/([A-Z])/-\L\1/g;
        s/^"([^ ]*)"/\1/;
        s/^-//;
        / 0$/ d;
    ')
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

"${CYDIA_LIBEXEC}/cydo" --install "${packages[@]}"

if [[ ${cpu} == arm || ${cpu} == arm64 ]]; then
    if [[ -z ${CYDIA_PREFIX} ]]; then
        if [[ ! -h /User && -d /User ]]; then
            cp -afT /User /var/mobile
        fi && rm -rf /User && ln -s "/var/mobile" /User
    fi

    echo 6 >"${CYDIA_STATE}/firmware.ver"
fi
