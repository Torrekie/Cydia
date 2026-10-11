#!/bin/sh
# APT documents are administrator state, independent of Cydia payload ownership.
# Copyright (C) 2026 Torrekie
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
fail() {
    printf '[verify-apt-source-isolation][FAIL] %s\n' "$*" >&2
    exit 1
}

for file in Cydia/AptRuntime.cpp Cydia/SourceDocument.cpp Cydia/SourceDocumentStore.cpp \
        Library/shared-config-lifecycle.sh preinst prerm postrm postinst.mm mk/package.mk; do
    test -f "$root/$file" || fail "missing source: $file"
done

# libapt remains authoritative for the actual main document and parts directory.
grep -Fq 'FindFile("Dir::Etc::sourcelist"' "$root/Cydia/AptRuntime.cpp" ||
    fail "effective source list is not resolved through libapt"
grep -Fq 'FindDir("Dir::Etc::sourceparts"' "$root/Cydia/AptRuntime.cpp" ||
    fail "effective sourceparts are not resolved through libapt"

# Fresh installations do not seed shared trust, preferences, or repositories.
test ! -e "$root/Sources.list/cydia.list" || fail "legacy repository payload remains"
if grep -Eq 'cp .*Sources[.]list|cp .*cydia[.]preferences|cp .*Trusted[.]gpg' "$root/mk/package.mk"; then
    fail "package recipe still supplies shared APT configuration"
fi
if grep -Eq 'apt[.]bingner[.]com|apt[.]thebigboss[.]org|cydia[.]zodttd[.]com|apt[.]modmyi[.]com|repo[.]chariz[.]com|repo[.]dynastic[.]co|apt[.]saurik[.]com' \
        "$root/Sources.mm" "$root/MobileCydia.mm" "$root/postinst.mm"; then
    fail "Cydia still seeds historical repository URLs"
fi

# Old package ownership is retired solely through maintscripts. Both removal
# entry points embed their helper so a later purge does not require deleted
# payload or private control files.
for script in preinst prerm postrm; do
    grep -Fq "cydia_shared_config_lifecycle $script" "$root/$script" ||
        fail "$script does not execute the shared-file lifecycle"
done
grep -Fq 'FinishSharedConfigHandoff(argv[0], paths)' "$root/postinst.mm" ||
    fail "native postinst does not finalize the control-file handoff"
grep -Fq 'cydia.cydia-shared-config-lifecycle' "$root/Cydia/SharedConfigHandoff.hpp" ||
    fail "native postinst does not locate its installed private control helper"
grep -Fq 'CydiaRuntime::RestoreLegacySourceHandoff(paths)' "$root/postinst.mm" ||
    fail "marker-authorized restore for previously distributed handoffs is absent"
grep -Fq 'CYDIA_POSTINST_ROOTLESS' "$root/postinst.mm" ||
    fail "postinst does not select its package build layout"
if grep -Fq 'PackageDatabasePaths::Current()' "$root/postinst.mm"; then
    fail "postinst infers private payload layout from the running environment"
fi
if grep -Eq 'retire_legacy_source|cydia[.]disabled' \
        "$root/preinst" "$root/postinst.mm" "$root/Library/shared-config-lifecycle.sh"; then
    fail "the old source-disable lifecycle remains active"
fi
if grep -Eq 'eval |rm -rf|--package cydia' "$root/Library/shared-config-lifecycle.sh"; then
    fail "shared-file handoff contains broad deletion or a Cydia-exempt diversion"
fi

# Exercise the actual dpkg lifecycle rather than asserting implementation text.
python3 "$root/tests/SharedConfigLifecycleTests.py"
printf '[verify-apt-source-isolation] PASS\n'
