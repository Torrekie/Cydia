#!/bin/bash
src=$1
dir=$2
arch=${3:-iphoneos-arm}
prefix=${4:-}
dir=${dir:=_}

epoch=${CYDIA_PACKAGE_EPOCH:-1}
case ${epoch} in
    ''|*[!0-9]*)
        echo "control.sh: CYDIA_PACKAGE_EPOCH must be a non-negative integer" >&2
        exit 2
        ;;
esac

version=$(./version.sh)
case ${version} in
    *:*) package_version=${version} ;;
    *) package_version=${epoch}:${version} ;;
esac

sed \
    -e "s@^\(Version:\).*@\1 ${package_version}@" \
    -e "s@^\(Architecture:\).*@\1 ${arch}@" \
    -e "s@file:///Applications/@file://${prefix}/Applications/@" \
    "${src}"
echo "Installed-Size: $(du -s "${dir}" | cut -f 1)"
