#!/bin/sh
# Ordinary HTTP caching remains; HTML5 Application Cache emulation does not.
# Copyright (C) 2026 Torrekie
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cache="$root/CyteKit/URLCache.mm"
header="$root/CyteKit/URLCache.h"
application="$root/CyteKit/Application.mm"

fail() {
    echo "[verify-url-cache][FAIL] $*" >&2
    exit 1
}

test -f "$cache" || fail "URL cache implementation is missing"
test -f "$header" || fail "URL cache declaration is missing"
test -f "$application" || fail "application cache setup is missing"

if grep -Eq 'text/cache-manifest|CachedURLs_|MSClassHook\(NSURLConnection\)|CYHook\(NSURLConnection|NSURLConnection\$init\$' "$cache"; then
    fail "HTML5 Application Cache tracking or NSURLConnection replay hook remains"
fi

grep -Fq '@interface CyteURLCache : SDURLCache' "$header" ||
    fail "ordinary SDURLCache compatibility type was removed"
grep -Fq 'CyteURLCache *cache' "$application" ||
    fail "application no longer creates the ordinary HTTP cache"
grep -Fq '[NSURLCache setSharedURLCache:cache]' "$application" ||
    fail "ordinary HTTP cache is not installed as the shared cache"
grep -Fq 'SDURLCache' "$header" ||
    fail "ordinary SDURLCache implementation is not retained"

echo "[verify-url-cache][ ok ] ordinary HTTP cache retained; HTML5 Application Cache removed"
