#!/usr/bin/env bash

set -e

header=

if [[ ${1:-} == --header ]]; then
    if [[ $# -lt 2 ]]; then
        echo "usage: $0 [--header path] [git-describe-options...]" >&2
        exit 2
    fi

    header=$2
    shift 2
fi

if [[ $# -eq 0 ]]; then
    flags=(--dirty="+")
else
    flags=("$@")
fi

version=$(git describe --tags --match="v*" "${flags[@]}" | sed -e 's@-\([^-]*\)-\([^-]*\)$@+\1.\2@;s@^v@@;s@%@~@g')

if grep '#define ForRelease 0' MobileCydia.mm &>/dev/null; then
    version=${version}~srk
fi

if [[ -n ${header} ]]; then
    define="#define CYDIA_VERSION \"${version}\""
    before=$(cat "${header}" 2>/dev/null || true)

    if [[ ${before} != ${define} ]]; then
        mkdir -p "$(dirname "${header}")"
        printf '%s\n' "${define}" >"${header}"
    fi
fi

echo "${version}"
