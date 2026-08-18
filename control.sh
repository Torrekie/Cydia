#!/bin/bash
src=$1
dir=$2
arch=${3:-iphoneos-arm}
prefix=${4:-}
dir=${dir:=_}
sed \
    -e "s@^\(Version:\).*@\1 $(./version.sh)@" \
    -e "s@^\(Architecture:\).*@\1 ${arch}@" \
    -e "s@file:///Applications/@file://${prefix}/Applications/@" \
    "${src}"
echo "Installed-Size: $(du -s "${dir}" | cut -f 1)"
