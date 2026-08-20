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

if [[ -n ${CYDIA_VERSION:-} ]]; then
    version=${CYDIA_VERSION}
else
    version=$(git describe --tags --match="v*" "${flags[@]}" 2>/dev/null | \
        sed -e 's@-\([^-]*\)-\([^-]*\)$@+\1.\2@;s@^v@@;s@%@~@g' || true)
    if [[ -z ${version} ]]; then
        version="0.0+git.$(git rev-parse --short=12 HEAD)"
    fi
fi

if grep '#define ForRelease 0' MobileCydia.mm &>/dev/null; then
    version=${version}~srk
fi

# Keep the upstream/app version separate from Debian's epoch.  The package
# control generator adds epoch 1, while Mach-O/CFBundle versions and package
# filenames must remain colon-free.
if [[ ${version} == *:* ]]; then
    echo "version.sh: CYDIA_VERSION must not contain a Debian epoch; the package generator adds epoch 1" >&2
    exit 2
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
