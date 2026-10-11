#!/bin/sh
# Copyright (C) 2026 Torrekie
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source_dir=${1:-"$root/apt64"}
test "$#" -le 1 || {
    echo "usage: $0 [empty-apt-directory]" >&2
    exit 2
}

fail() {
    echo "[checkout-apt][FAIL] $*" >&2
    exit 1
}

base=$(awk '$1 == "APT_SOURCE_BASE_COMMIT" { print $3; exit }' "$root/mk/apt.mk")
expected=$(awk '$1 == "APT_SOURCE_COMMIT" { print $3; exit }' "$root/mk/apt.mk")
gitlink=$(git -C "$root" ls-tree HEAD apt64 | awk '$1 == "160000" { print $3 }')
test -n "$base" && test -n "$expected" && test "$expected" = "$gitlink" ||
    fail "APT manifest and committed gitlink do not agree"
url=$(git config -f "$root/.gitmodules" --get submodule.apt64.url)

# Do not replace an existing developer checkout or its local changes.
if test -e "$source_dir/.git"; then
    test "$(git -C "$source_dir" rev-parse HEAD)" = "$expected" ||
        fail "refusing to replace an existing APT checkout"
    test -z "$(git -C "$source_dir" status --porcelain --untracked-files=all)" ||
        fail "existing APT checkout has local changes"
    echo "[checkout-apt][ ok ] recorded APT commit already checked out"
    exit 0
fi

mkdir -p "$source_dir"
git -c init.defaultBranch=main init "$source_dir"
git -C "$source_dir" remote add origin "$url"
fetch_base() {
    timeout 90 git -C "$source_dir" \
        -c transfer.fsckObjects=true -c fetch.fsckObjects=true \
        fetch --depth=1 "$1" "$base"
}
if ! fetch_base "$url"; then
    echo "[checkout-apt] upstream transport unavailable; using Debian's HTTPS mirror"
    fetch_base https://github.com/Debian/apt.git
fi
test "$(git -C "$source_dir" rev-parse FETCH_HEAD)" = "$base" ||
    fail "fetched APT revision differs from the recorded upstream base"
git -C "$source_dir" checkout --detach "$base"

# Both reviewed local commits have identical author/committer identities and
# dates. Replaying their recorded mail patches regenerates the exact gitlink,
# without requiring a private fork or fetching a floating upstream branch.
git -C "$source_dir" -c user.name=Torrekie \
    -c user.email=31795847+Torrekie@users.noreply.github.com \
    -c commit.gpgsign=false -c am.threeWay=false \
    am --committer-date-is-author-date "$root/apt-extra/apt-2.7.9-cydia.patch"
test "$(git -C "$source_dir" rev-parse HEAD)" = "$expected" ||
    fail "replayed APT compatibility commits differ from the recorded gitlink"
test -z "$(git -C "$source_dir" status --porcelain --untracked-files=all)" ||
    fail "replayed APT checkout is not clean"
git -C "$source_dir" fsck --strict
echo "[checkout-apt][ ok ] exact APT gitlink regenerated: $expected"
