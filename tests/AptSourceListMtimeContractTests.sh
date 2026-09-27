#!/bin/sh
# pkgSourceList cache invalidation must observe every configured source part.
# Copyright (C) 2026 Torrekie
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source_list="$root/apt64/apt-pkg/sourcelist.cc"
source_test="$root/apt64/test/libapt/sourcelist_test.cc"

fail() {
    echo "[verify-apt-sourcelist-mtime][FAIL] $*" >&2
    exit 1
}

test -f "$source_list" || fail "missing apt-pkg/sourcelist.cc"
test -f "$source_test" || fail "missing sourcelist regression test"

# Keep the existing GetListOfFilesInDir contract: both source formats are
# collected in one sorted pass, then their mtimes are compared with the main
# list.  This also rejects a regression to the historical .list-only call.
mtime_body=$(sed -n '/time_t pkgSourceList::GetLastModifiedTime()/,/^}[[:space:]]*\/\*}}}\*\//p' "$source_list")
printf '%s\n' "$mtime_body" | grep -Fq 'std::vector<std::string> const ext = {"list", "sources"};' ||
    fail "GetLastModifiedTime does not include .list and .sources parts"
printf '%s\n' "$mtime_body" | grep -Fq 'GetListOfFilesInDir(Parts, ext, true)' ||
    fail "source parts are not collected with stable sorting"
printf '%s\n' "$mtime_body" | grep -Fq 'modtimes.push_back(GetModificationTime(Main));' ||
    fail "main source-list mtime is no longer included"
printf '%s\n' "$mtime_body" | grep -Fq 'std::transform(List.begin(), List.end()' ||
    fail "source-part mtimes are no longer compared"

# The apt-native regression fixture must use a real Deb822 source part and
# force its mtime newer than the main list, proving the bug is observable.
grep -Fq 'GetLastModifiedTimeIncludesDeb822Parts' "$source_test" ||
    fail "missing Deb822 mtime regression test"
grep -Fq 'default.sources' "$source_test" ||
    fail "regression fixture does not create a .sources part"
grep -Fq 'utime(deb822.c_str(), &deb822Times)' "$source_test" ||
    fail "regression fixture does not control the .sources mtime"
grep -Fq 'EXPECT_EQ(deb822Time, sources.GetLastModifiedTime())' "$source_test" ||
    fail "regression fixture does not assert the Deb822 mtime"

echo "[verify-apt-sourcelist-mtime][ ok ] .list and Deb822 .sources mtimes use sorted sourceparts"
