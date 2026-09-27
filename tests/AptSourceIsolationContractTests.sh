#!/bin/sh
# Cydia must consume the bootstrap maintainer's APT source configuration.
# Copyright (C) 2026 Torrekie
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
apt_runtime="$root/Cydia/AptRuntime.cpp"
apt_header="$root/Cydia/AptRuntime.hpp"
sources="$root/Sources.mm"
sources_header="$root/Sources.h"
mobile="$root/MobileCydia.mm"
data="$root/Cydia/Application+Data.mm"
controllers="$root/Cydia/SourceControllers.mm"
package="$root/mk/package.mk"
postinst="$root/postinst.mm"
preinst="$root/preinst"
handoff="$root/Cydia/LegacySourceHandoff.cpp"

fail() {
    echo "[verify-apt-source-isolation][FAIL] $*" >&2
    exit 1
}

assert_marker() {
    marker=$1
    key=$2
    expected=$3
    actual=$(sed -n "s/^${key}=//p" "$marker")
    test "$actual" = "$expected" ||
        fail "marker ${key}=${actual} (expected ${expected})"
}

for file in "$apt_runtime" "$apt_header" "$sources" "$sources_header" \
        "$mobile" "$data" "$controllers" "$package" "$postinst" "$preinst" \
        "$handoff"; do
    test -f "$file" || fail "missing source: ${file#"$root/"}"
done

# APT's own main list and source-parts directory are the only default source
# context.  Relative maintainer values must be resolved through libapt APIs.
grep -Fq 'FindFile("Dir::Etc::sourcelist"' "$apt_runtime" ||
    fail "effective maintainer source list is not resolved with FindFile"
grep -Fq 'FindDir("Dir::Etc::sourceparts"' "$apt_runtime" ||
    fail "effective maintainer sourceparts are not resolved with FindDir"
grep -Fq '_config->Clear("Dir::Etc::sourcelist")' "$apt_runtime" ||
    fail "stale process-global source list key is not cleared"
grep -Fq '_config->Clear("Dir::Etc::sourceparts")' "$apt_runtime" ||
    fail "stale process-global sourceparts key is not cleared"
grep -Fq '_config->Clear("Cydia::APT::ManagedSourceList")' "$apt_runtime" ||
    fail "stale maintainer-managed leaf key is not cleared"
grep -Fq 'Cydia::APT::ManagedSourceList' "$apt_runtime" ||
    fail "maintainer-managed Cydia leaf key is missing"
grep -Fq 'sourceListSetting' "$apt_runtime" ||
    fail "the maintainer source-list setting is not carried through the second APT stage"
grep -Fq 'sourcePartsSetting' "$apt_runtime" ||
    fail "the maintainer sourceparts setting is not carried through the second APT stage"
if grep -Fq 'gSourceListPath.empty() ? "/dev/null"' "$apt_runtime" ||
   grep -Fq 'gSourcePartsDirectory.empty() ? "/dev/null"' "$apt_runtime"; then
    fail "resolved source paths are being written back as synthetic /dev/null values"
fi

if grep -Eq 'APT::Sources::With|InstallManagedSourceLink|CydiaConfiguredManagedSourceListPath|sourceLink' \
        "$apt_runtime" "$sources" "$mobile" "$postinst"; then
    fail "private source link or volatile-index overlay remains"
fi

# The old package-owned global file and hard-coded repository seed must not be
# recreated.  Existing maintainer .list/.sources files are outside this diff.
test ! -e "$root/Sources.list/cydia.list" ||
    fail "legacy global source file is still tracked"
if grep -Fq 'Sources.list/.' "$package"; then
    fail "package recipe still copies a global sourceparts file"
fi
if grep -Eq 'apt\.bingner\.com|apt\.thebigboss\.org|cydia\.zodttd\.com|apt\.modmyi\.com|repo\.chariz\.com|repo\.dynastic\.co|apt\.saurik\.com' \
        "$sources" "$mobile" "$postinst"; then
    fail "Cydia still seeds historical repository URLs"
fi

# Private staging is allowed only as an atomic handoff; it must never become
# an APT configuration value or a symlink in the maintainer's source directory.
grep -Fq 'mkstemp' "$sources" || fail "source updates are not atomically staged"
grep -Fq 'BootstrapBSDCommand::Copy' "$sources" ||
    fail "source staging is not copied through the privileged boundary"
grep -Fq 'BootstrapBSDCommand::Move' "$sources" ||
    fail "source staging is not atomically moved into the declared file"
grep -Fq 'lstat' "$sources" || fail "source target symlink/non-file checks are missing"
grep -Fq 'BEGIN CYDIA MANAGED SOURCES' "$sources" ||
    fail "managed source edits do not preserve unowned file content"
grep -Fq 'CydiaAPT::ManagedSourceListPath' "$mobile" ||
    fail "MobileCydia does not consume the validated maintainer path"
if grep -Eq 'SOURCES_LIST|ln -s[f]?' "$sources" "$mobile"; then
    fail "private cache is still exposed as an APT source link"
fi

# Without an explicit, physically usable managed leaf, all source mutations
# are fail-closed and the editing controls stay hidden.
grep -Fq 'CydiaCanEditManagedSources' "$data" ||
    fail "data delegate does not enforce managed-source readiness"
grep -Fq 'CydiaCanEditManagedSources' "$controllers" ||
    fail "Sources UI does not enforce managed-source readiness"

# Upgrades preserve the old package-owned path by renaming it before unpack.
# A standard-layout sole source gets an explicit, one-transaction handoff;
# postinst restores only that marker and never invents a source configuration.
grep -Fq '.disabled' "$preinst" ||
    fail "legacy source migration has no recoverable disabled name"
grep -Fq 'legacy_source_listed' "$preinst" ||
    fail "legacy migration is not gated by dpkg ownership evidence"
grep -Fq 'mv "$source" "$backup"' "$preinst" ||
    fail "legacy source migration does not preserve file contents"
grep -Fq 'mode=sole' "$preinst" ||
    fail "sole-source migration marker is missing"
grep -Fq 'mode=disabled' "$preinst" ||
    fail "non-sole migration receipt is missing"
grep -Fq 'effective_apt_paths_are_standard' "$preinst" ||
    fail "effective APT path gating is missing"
grep -Fq 'apt-config' "$preinst" ||
    fail "apt-config compatibility probe is missing"
grep -Fq 'Dir::Etc::main' "$preinst" ||
    fail "APT main-config alias is not checked"
grep -Fq 'Dir::Etc::parts' "$preinst" ||
    fail "APT parts-config alias is not checked"
grep -Fq 'normalize_install_root' "$preinst" ||
    fail "non-canonical DPKG_ROOT values are not rejected"
grep -Fq 'ln "$marker_tmp" "$marker"' "$preinst" ||
    fail "legacy marker publication is not no-replace atomic"
grep -Fq 'var/lib/cydia/cydia.legacy-source-marker' "$preinst" ||
    fail "legacy marker is not persisted in Cydia state"
grep -Fq 'apt_config_reports_prefix' "$preinst" ||
    fail "alternate-root apt-config provenance is not checked"
grep -Fq 'RestoreLegacySourceHandoff' "$postinst" ||
    fail "postinst sole-source handoff is missing"
grep -Fq 'RenameLegacySourceNoReplace' "$handoff" ||
    fail "postinst handoff is not no-replace"
grep -Fq 'renamex_np' "$handoff" ||
    fail "postinst Darwin handoff is not an atomic rename"
grep -Fq 'link(source, target)' "$handoff" ||
    fail "postinst fallback handoff lacks no-replace publication"
grep -Fq 'sourceType' "$handoff" ||
    fail "postinst does not validate the preserved source object type"
grep -Fq 'values["version"] == "1"' "$handoff" ||
    fail "postinst does not retain the version-1 marker compatibility path"
grep -Fq 'var/lib/cydia/cydia.legacy-source-marker' "$handoff" ||
    fail "postinst does not scan the durable Cydia state marker"
grep -Fq '/var/lib/dpkg/info' "$handoff" ||
    fail "postinst dropped the historical dpkg-info marker compatibility path"
grep -Fq 'No unmarked .disabled file is ever considered' "$handoff" ||
    fail "legacy restore is not marker-gated"
if grep -Eq 'CydiaSourcesListPath|writeToFile:.*cydia|unlink\(cydia' "$postinst"; then
    fail "postinst still mutates the active sourceparts path"
fi

# Exercise the migration boundary with a trailing DPKG_ROOT slash.  This is a
# throwaway fixture: the real preinst must prove ownership before moving the
# legacy path, and normalizing the root must not make that proof disappear.
tmp_parent=${TMPDIR:-/tmp}
if [ "$tmp_parent" != "/" ]; then
    tmp_parent=${tmp_parent%/}
fi
fixture=$(mktemp -d "$tmp_parent/cydia-source-migration.XXXXXX") ||
    fail "could not create migration fixture"
trap 'rm -rf "$fixture"' EXIT HUP INT TERM
mkdir -p "$fixture/root/etc/apt/sources.list.d" "$fixture/root/var/lib/dpkg/info" \
    "$fixture/root/var/lib/cydia"
printf '%s\n' 'deb https://maintainer.example/ stable main' \
    >"$fixture/root/etc/apt/sources.list.d/cydia.list"
printf '%s\n' 'etc/apt/sources.list.d/cydia.list' \
    >"$fixture/root/var/lib/dpkg/info/cydia.list"
DPKG_ROOT="$fixture/root/" DPKG_ADMINDIR=/var/lib/dpkg CYDIA= \
    "$root/preinst" configure || fail "owned legacy source migration failed"
test ! -e "$fixture/root/etc/apt/sources.list.d/cydia.list" ||
    fail "legacy source path was not retired"
test -f "$fixture/root/etc/apt/sources.list.d/cydia.list.cydia.disabled" ||
    fail "legacy source backup was not preserved"
assert_marker "$fixture/root/var/lib/cydia/cydia.legacy-source-marker" mode sole
assert_marker "$fixture/root/var/lib/cydia/cydia.legacy-source-marker" sole 1
assert_marker "$fixture/root/var/lib/cydia/cydia.legacy-source-marker" source_type regular
test ! -e "$fixture/root/var/lib/dpkg/info/cydia.legacy-source-marker" ||
    fail "sole marker was still written below dpkg/info"
# Simulate dpkg replacing its package-info directory after preinst.  The
# durable receipt must remain available for postinst's restore pass.
rm -f "$fixture/root/var/lib/dpkg/info/cydia.list"
test -f "$fixture/root/var/lib/cydia/cydia.legacy-source-marker" ||
    fail "durable marker did not survive dpkg-info cleanup"
printf '%s\n' 'deb https://maintainer.example/ stable main' >"$fixture/expected-sole.list"
cmp -s "$fixture/root/etc/apt/sources.list.d/cydia.list.cydia.disabled" \
    "$fixture/expected-sole.list" ||
    fail "sole-source backup bytes changed"

# Empty and comment-only sourceparts are ignored by APT.  They must not make a
# real Cydia source look multi-source, otherwise upgrading Cydia would leave
# the rooted installation with no active cydia.list after the package handoff.
empty_sibling_tree="$fixture/empty-siblings"
mkdir -p "$empty_sibling_tree/etc/apt/sources.list.d" \
    "$empty_sibling_tree/var/lib/dpkg/info" "$empty_sibling_tree/var/lib/cydia"
printf '%s\n' 'deb https://empty-sibling.example/ stable main' \
    >"$empty_sibling_tree/etc/apt/sources.list.d/cydia.list"
: >"$empty_sibling_tree/etc/apt/sources.list.d/sileo.sources"
printf '%s\n' '# retained for a future source configuration' \
    >"$empty_sibling_tree/etc/apt/sources.list.d/comment-only.list"
printf '%s\n' 'etc/apt/sources.list.d/cydia.list' \
    >"$empty_sibling_tree/var/lib/dpkg/info/cydia.list"
DPKG_ROOT="$empty_sibling_tree" DPKG_ADMINDIR=/var/lib/dpkg CYDIA= \
    "$root/preinst" configure || fail "empty-sibling sole-source migration failed"
test ! -e "$empty_sibling_tree/etc/apt/sources.list.d/cydia.list" ||
    fail "empty-sibling legacy source path was not retired"
test -f "$empty_sibling_tree/etc/apt/sources.list.d/cydia.list.cydia.disabled" ||
    fail "empty-sibling legacy backup was not preserved"
assert_marker "$empty_sibling_tree/var/lib/cydia/cydia.legacy-source-marker" mode sole
assert_marker "$empty_sibling_tree/var/lib/cydia/cydia.legacy-source-marker" sole 1

# APT's apt-config shell output is not evaluated as shell code.  Exercise the
# common wrapper spelling with a trailing semicolon and verify that standard
# paths still receive a sole marker.
apt_config_bin="$fixture/apt-config-bin"
mkdir -p "$apt_config_bin"
cat >"$apt_config_bin/apt-config" <<'EOF'
#!/bin/bash
if [[ $1 != shell ]]; then exit 2; fi
case "$3" in
    Dir::Etc::sourcelist) printf "%s='sources.list';\n" "$2" ;;
    Dir::Etc::sourceparts) printf "%s='sources.list.d';\n" "$2" ;;
    Dir::Etc) printf "%s='etc/apt';\n" "$2" ;;
    RootDir) printf "%s='/';\n" "$2" ;;
    Dir) if [[ ${FAKE_APT_CUSTOM:-0} == 1 ]]; then printf "%s='/alternate';\n" "$2"; else printf "%s='/';\n" "$2"; fi ;;
    *) exit 1 ;;
esac
EOF
chmod 755 "$apt_config_bin/apt-config"
fake_tree="$fixture/fake-apt-config"
mkdir -p "$fake_tree/etc/apt/sources.list.d" "$fake_tree/var/lib/dpkg/info" \
    "$fake_tree/var/lib/cydia"
printf '%s\n' 'deb https://fake.example/ stable main' \
    >"$fake_tree/etc/apt/sources.list.d/cydia.list"
printf '%s\n' 'etc/apt/sources.list.d/cydia.list' \
    >"$fake_tree/var/lib/dpkg/info/cydia.list"
PATH="$apt_config_bin:$PATH" DPKG_ROOT="$fake_tree" DPKG_ADMINDIR=/var/lib/dpkg CYDIA= \
    "$root/preinst" configure || fail "apt-config semicolon fixture failed"
assert_marker "$fake_tree/var/lib/cydia/cydia.legacy-source-marker" mode sole

# Keep a deterministic fallback-parser PATH for hosts that happen to ship
# apt-config.  The maintainer script only needs these external utilities;
# command -v apt-config must otherwise report no binary.
fallback_bin="$fixture/fallback-bin"
mkdir -p "$fallback_bin"
for utility in sed grep mv ln rm; do
    utility_path=$(command -v "$utility") || fail "missing fallback utility: $utility"
    ln -s "$utility_path" "$fallback_bin/$utility"
done

# Even with apt-config available, a custom effective parent Dir is outside
# Cydia's standard physical layout and must receive an inert receipt.
fake_custom_tree="$fixture/fake-apt-custom"
mkdir -p "$fake_custom_tree/etc/apt/sources.list.d" "$fake_custom_tree/var/lib/dpkg/info" \
    "$fake_custom_tree/var/lib/cydia"
printf '%s\n' 'deb https://fake-custom.example/ stable main' \
    >"$fake_custom_tree/etc/apt/sources.list.d/cydia.list"
printf '%s\n' 'etc/apt/sources.list.d/cydia.list' \
    >"$fake_custom_tree/var/lib/dpkg/info/cydia.list"
PATH="$apt_config_bin:$PATH" FAKE_APT_CUSTOM=1 DPKG_ROOT="$fake_custom_tree" \
    DPKG_ADMINDIR=/var/lib/dpkg CYDIA= "$root/preinst" configure ||
    fail "apt-config custom-parent fixture failed"
assert_marker "$fake_custom_tree/var/lib/cydia/cydia.legacy-source-marker" mode disabled
assert_marker "$fake_custom_tree/var/lib/cydia/cydia.legacy-source-marker" sole 0

# A host apt-config may report the host's standard defaults while DPKG_ROOT
# points at an alternate tree whose apt.conf redirects sourceparts.  The
# rooted fallback must inspect that tree instead of trusting host output.
host_config_tree="$fixture/fake-host-rooted-custom"
mkdir -p "$host_config_tree/etc/apt/sources.list.d" "$host_config_tree/var/lib/dpkg/info" \
    "$host_config_tree/var/lib/cydia"
printf '%s\n' 'Dir::Etc::sourceparts "vendor.sources.d";' \
    >"$host_config_tree/etc/apt/apt.conf"
printf '%s\n' 'deb https://host-rooted.example/ stable main' \
    >"$host_config_tree/etc/apt/sources.list.d/cydia.list"
printf '%s\n' 'etc/apt/sources.list.d/cydia.list' \
    >"$host_config_tree/var/lib/dpkg/info/cydia.list"
PATH="$apt_config_bin:$PATH" DPKG_ROOT="$host_config_tree" \
    DPKG_ADMINDIR=/var/lib/dpkg CYDIA= "$root/preinst" configure ||
    fail "host-apt-config rooted fallback failed"
assert_marker "$host_config_tree/var/lib/cydia/cydia.legacy-source-marker" mode disabled
assert_marker "$host_config_tree/var/lib/cydia/cydia.legacy-source-marker" sole 0

# Multiple active sourceparts are fail-closed: the old package file remains a
# disabled receipt and the unrelated maintainer file is byte-for-byte intact.
multi_tree="$fixture/multi"
mkdir -p "$multi_tree/etc/apt/sources.list.d" "$multi_tree/var/lib/dpkg/info" \
    "$multi_tree/var/lib/cydia"
printf '%s\n' 'deb https://legacy.example/ stable main' \
    >"$multi_tree/etc/apt/sources.list.d/cydia.list"
printf '%s\n' 'deb https://maintainer.example/ stable main' \
    >"$multi_tree/etc/apt/sources.list.d/other.list"
multi_hash=$(cksum "$multi_tree/etc/apt/sources.list.d/other.list")
printf '%s\n' 'etc/apt/sources.list.d/cydia.list' \
    >"$multi_tree/var/lib/dpkg/info/cydia.list"
DPKG_ROOT="$multi_tree" DPKG_ADMINDIR=/var/lib/dpkg CYDIA= \
    "$root/preinst" configure || fail "multi-source migration failed"
assert_marker "$multi_tree/var/lib/cydia/cydia.legacy-source-marker" mode disabled
assert_marker "$multi_tree/var/lib/cydia/cydia.legacy-source-marker" sole 0
test -f "$multi_tree/etc/apt/sources.list.d/cydia.list.cydia.disabled" ||
    fail "multi-source legacy backup is missing"
test "$(cksum "$multi_tree/etc/apt/sources.list.d/other.list")" = "$multi_hash" ||
    fail "unrelated maintainer source changed"

# A configured non-standard sourceparts path is also fail-closed, even when
# the physical legacy directory happens to be otherwise empty.
custom_tree="$fixture/custom"
mkdir -p "$custom_tree/etc/apt/sources.list.d" "$custom_tree/var/lib/dpkg/info" \
    "$custom_tree/var/lib/cydia"
printf '%s\n' 'Dir::Etc::sourceparts "vendor.sources.d";' \
    >"$custom_tree/etc/apt/apt.conf"
printf '%s\n' 'deb https://legacy.example/ stable main' \
    >"$custom_tree/etc/apt/sources.list.d/cydia.list"
printf '%s\n' 'etc/apt/sources.list.d/cydia.list' \
    >"$custom_tree/var/lib/dpkg/info/cydia.list"
DPKG_ROOT="$custom_tree" DPKG_ADMINDIR=/var/lib/dpkg CYDIA= \
    "$root/preinst" configure || fail "custom-layout migration failed"
assert_marker "$custom_tree/var/lib/cydia/cydia.legacy-source-marker" mode disabled
assert_marker "$custom_tree/var/lib/cydia/cydia.legacy-source-marker" sole 0

# The manual parser must reject a parent Dir assignment that redirects all
# relative APT paths, even when the legacy physical source happens to exist.
parent_tree="$fixture/custom-parent"
mkdir -p "$parent_tree/etc/apt/sources.list.d" "$parent_tree/var/lib/dpkg/info" \
    "$parent_tree/var/lib/cydia"
printf '%s\n' 'Dir "/alternate";' >"$parent_tree/etc/apt/apt.conf"
printf '%s\n' 'deb https://parent.example/ stable main' \
    >"$parent_tree/etc/apt/sources.list.d/cydia.list"
printf '%s\n' 'etc/apt/sources.list.d/cydia.list' \
    >"$parent_tree/var/lib/dpkg/info/cydia.list"
PATH="$fallback_bin" DPKG_ROOT="$parent_tree" DPKG_ADMINDIR=/var/lib/dpkg CYDIA= \
    "$root/preinst" configure || fail "custom-parent fallback migration failed"
assert_marker "$parent_tree/var/lib/cydia/cydia.legacy-source-marker" mode disabled
assert_marker "$parent_tree/var/lib/cydia/cydia.legacy-source-marker" sole 0

# Dir::Etc::main and Dir::Etc::parts aliases select the configuration files
# APT loads.  A nonstandard alias must fail closed instead of being mistaken
# for the documented apt.conf/apt.conf.d defaults.
alias_tree="$fixture/custom-config-aliases"
mkdir -p "$alias_tree/etc/apt/sources.list.d" "$alias_tree/var/lib/dpkg/info" \
    "$alias_tree/var/lib/cydia"
printf '%s\n' 'Dir::Etc::main "vendor.conf";' \
    'Dir::Etc::parts "vendor.conf.d";' >"$alias_tree/etc/apt/apt.conf"
printf '%s\n' 'deb https://alias.example/ stable main' \
    >"$alias_tree/etc/apt/sources.list.d/cydia.list"
printf '%s\n' 'etc/apt/sources.list.d/cydia.list' \
    >"$alias_tree/var/lib/dpkg/info/cydia.list"
PATH="$fallback_bin" DPKG_ROOT="$alias_tree" DPKG_ADMINDIR=/var/lib/dpkg CYDIA= \
    "$root/preinst" configure || fail "custom-config-alias migration failed"
assert_marker "$alias_tree/var/lib/cydia/cydia.legacy-source-marker" mode disabled
assert_marker "$alias_tree/var/lib/cydia/cydia.legacy-source-marker" sole 0

# APT applies fragments before apt.conf.  If two fragments assign a relevant
# key, precedence is intentionally treated as ambiguous and the source is
# only retired with an inert receipt.
precedence_tree="$fixture/custom-precedence"
mkdir -p "$precedence_tree/etc/apt/apt.conf.d" \
    "$precedence_tree/etc/apt/sources.list.d" "$precedence_tree/var/lib/dpkg/info" \
    "$precedence_tree/var/lib/cydia"
printf '%s\n' 'Dir::Etc::sourceparts "sources.list.d";' \
    >"$precedence_tree/etc/apt/apt.conf.d/00-standard"
printf '%s\n' 'Dir::Etc::sourceparts "vendor.sources.d";' \
    >"$precedence_tree/etc/apt/apt.conf.d/99-custom"
printf '%s\n' 'deb https://precedence.example/ stable main' \
    >"$precedence_tree/etc/apt/sources.list.d/cydia.list"
printf '%s\n' 'etc/apt/sources.list.d/cydia.list' \
    >"$precedence_tree/var/lib/dpkg/info/cydia.list"
PATH="$fallback_bin" DPKG_ROOT="$precedence_tree" DPKG_ADMINDIR=/var/lib/dpkg CYDIA= \
    "$root/preinst" configure || fail "ambiguous-config migration failed"
assert_marker "$precedence_tree/var/lib/cydia/cydia.legacy-source-marker" mode disabled
assert_marker "$precedence_tree/var/lib/cydia/cydia.legacy-source-marker" sole 0

# Non-canonical DPKG_ROOT spellings are rejected before ownership/path
# resolution.  This keeps preinst and postinst's absolute-path policy in
# lockstep and leaves the maintainer source untouched.
noncanonical_tree="$fixture/noncanonical-root"
mkdir -p "$noncanonical_tree/etc/apt/sources.list.d" \
    "$noncanonical_tree/var/lib/dpkg/info" "$noncanonical_tree/var/lib/cydia"
printf '%s\n' 'deb https://noncanonical.example/ stable main' \
    >"$noncanonical_tree/etc/apt/sources.list.d/cydia.list"
printf '%s\n' 'etc/apt/sources.list.d/cydia.list' \
    >"$noncanonical_tree/var/lib/dpkg/info/cydia.list"
noncanonical_before=$(cksum "$noncanonical_tree/etc/apt/sources.list.d/cydia.list")
DPKG_ROOT="$noncanonical_tree/." DPKG_ADMINDIR=/var/lib/dpkg CYDIA= \
    "$root/preinst" configure || fail "noncanonical-root fixture unexpectedly failed"
test "$(cksum "$noncanonical_tree/etc/apt/sources.list.d/cydia.list")" = \
    "$noncanonical_before" || fail "noncanonical DPKG_ROOT changed source"
test ! -e "$noncanonical_tree/etc/apt/sources.list.d/cydia.list.cydia.disabled" ||
    fail "noncanonical DPKG_ROOT created a backup"

# An unowned path is never touched, regardless of how attractive the default
# spelling looks.
unowned_tree="$fixture/unowned"
mkdir -p "$unowned_tree/etc/apt/sources.list.d" "$unowned_tree/var/lib/dpkg/info" \
    "$unowned_tree/var/lib/cydia"
printf '%s\n' 'deb https://unowned.example/ stable main' \
    >"$unowned_tree/etc/apt/sources.list.d/cydia.list"
printf '%s\n' 'etc/apt/sources.list.d/other.list' \
    >"$unowned_tree/var/lib/dpkg/info/cydia.list"
unowned_before=$(cksum "$unowned_tree/etc/apt/sources.list.d/cydia.list")
DPKG_ROOT="$unowned_tree" DPKG_ADMINDIR=/var/lib/dpkg CYDIA= \
    "$root/preinst" configure || fail "unowned fixture unexpectedly failed"
test "$(cksum "$unowned_tree/etc/apt/sources.list.d/cydia.list")" = "$unowned_before" ||
    fail "unowned source path changed"
test ! -e "$unowned_tree/etc/apt/sources.list.d/cydia.list.cydia.disabled" ||
    fail "unowned source path was retired"

# Symlink sources are moved as links, not dereferenced copies.  The target is
# intentionally outside sourceparts to make accidental content replacement
# visible in the fixture.
symlink_tree="$fixture/symlink"
mkdir -p "$symlink_tree/etc/apt/sources.list.d" "$symlink_tree/var/lib/dpkg/info" \
    "$symlink_tree/var/lib/cydia" "$symlink_tree/vendor"
printf '%s\n' 'deb https://link.example/ stable main' >"$symlink_tree/vendor/cydia.list"
ln -s ../../../vendor/cydia.list "$symlink_tree/etc/apt/sources.list.d/cydia.list"
printf '%s\n' 'etc/apt/sources.list.d/cydia.list' \
    >"$symlink_tree/var/lib/dpkg/info/cydia.list"
DPKG_ROOT="$symlink_tree" DPKG_ADMINDIR=/var/lib/dpkg CYDIA= \
    "$root/preinst" configure || fail "symlink migration failed"
assert_marker "$symlink_tree/var/lib/cydia/cydia.legacy-source-marker" source_type symlink
test "$(readlink "$symlink_tree/etc/apt/sources.list.d/cydia.list.cydia.disabled")" = \
    '../../../vendor/cydia.list' || fail "symlink target was not preserved exactly"
test "$(cksum "$symlink_tree/vendor/cydia.list" | awk '{print $1, $2}')" = \
    "$(printf '%s\n' 'deb https://link.example/ stable main' | cksum | awk '{print $1, $2}')" ||
    fail "symlink target bytes changed"

# Marker creation failure must roll back a sole-source rename before dpkg can
# remove the old package path.  A directory at the marker name is a portable
# way to force that failure even when the test runs as root.
rollback_tree="$fixture/rollback"
mkdir -p "$rollback_tree/etc/apt/sources.list.d" "$rollback_tree/var/lib/dpkg/info" \
    "$rollback_tree/var/lib/cydia/cydia.legacy-source-marker"
printf '%s\n' 'deb https://rollback.example/ stable main' \
    >"$rollback_tree/etc/apt/sources.list.d/cydia.list"
printf '%s\n' 'etc/apt/sources.list.d/cydia.list' \
    >"$rollback_tree/var/lib/dpkg/info/cydia.list"
if DPKG_ROOT="$rollback_tree" DPKG_ADMINDIR=/var/lib/dpkg CYDIA= \
        "$root/preinst" configure; then
    fail "marker failure did not stop the transaction"
fi
test -f "$rollback_tree/etc/apt/sources.list.d/cydia.list" ||
    fail "sole-source marker failure stranded the source"
test ! -e "$rollback_tree/etc/apt/sources.list.d/cydia.list.cydia.disabled" ||
    fail "rollback left a disabled sole-source backup"

# An existing marker is never overwritten.  The source rename is rolled back
# and the pre-existing marker bytes remain unchanged.
stale_tree="$fixture/stale-marker"
mkdir -p "$stale_tree/etc/apt/sources.list.d" "$stale_tree/var/lib/dpkg/info" \
    "$stale_tree/var/lib/cydia"
printf '%s\n' 'deb https://stale.example/ stable main' \
    >"$stale_tree/etc/apt/sources.list.d/cydia.list"
printf '%s\n' 'etc/apt/sources.list.d/cydia.list' \
    >"$stale_tree/var/lib/dpkg/info/cydia.list"
printf '%s\n' 'version=1' >"$stale_tree/var/lib/cydia/cydia.legacy-source-marker"
stale_hash=$(cksum "$stale_tree/var/lib/cydia/cydia.legacy-source-marker")
if DPKG_ROOT="$stale_tree" DPKG_ADMINDIR=/var/lib/dpkg CYDIA= \
        "$root/preinst" configure; then
    fail "stale marker collision did not stop the transaction"
fi
test "$(cksum "$stale_tree/var/lib/cydia/cydia.legacy-source-marker")" = "$stale_hash" ||
    fail "stale marker was overwritten"
test -f "$stale_tree/etc/apt/sources.list.d/cydia.list" ||
    fail "stale marker collision stranded the source"

# A pre-fix package may leave a complete version-1 marker.  Preinst must not
# overwrite that receipt; postinst is the only consumer of the marker.
legacy_v1_tree="$fixture/legacy-v1-marker"
mkdir -p "$legacy_v1_tree/etc/apt/sources.list.d" "$legacy_v1_tree/var/lib/dpkg/info" \
    "$legacy_v1_tree/var/lib/cydia"
printf '%s\n' 'deb https://legacy-v1.example/ stable main' \
    >"$legacy_v1_tree/etc/apt/sources.list.d/cydia.list"
printf '%s\n' 'etc/apt/sources.list.d/cydia.list' \
    >"$legacy_v1_tree/var/lib/dpkg/info/cydia.list"
mv "$legacy_v1_tree/etc/apt/sources.list.d/cydia.list" \
    "$legacy_v1_tree/etc/apt/sources.list.d/cydia.list.cydia.disabled"
printf '%s\n' 'deb https://legacy-v1.example/ stable main' \
    >"$legacy_v1_tree/etc/apt/sources.list.d/cydia.list"
printf '%s\n' \
    'version=1' \
    "source=$legacy_v1_tree/etc/apt/sources.list.d/cydia.list" \
    "backup=$legacy_v1_tree/etc/apt/sources.list.d/cydia.list.cydia.disabled" \
    >"$legacy_v1_tree/var/lib/cydia/cydia.legacy-source-marker"
legacy_v1_hash=$(cksum "$legacy_v1_tree/var/lib/cydia/cydia.legacy-source-marker")
if DPKG_ROOT="$legacy_v1_tree" DPKG_ADMINDIR=/var/lib/dpkg CYDIA= \
        "$root/preinst" configure; then
    fail "version-1 marker collision did not stop the transaction"
fi
test "$(cksum "$legacy_v1_tree/var/lib/cydia/cydia.legacy-source-marker")" = \
    "$legacy_v1_hash" || fail "version-1 marker was overwritten"
test -f "$legacy_v1_tree/etc/apt/sources.list.d/cydia.list" ||
    fail "version-1 marker collision stranded the source"

# The historical receipt must be accepted when the source is absent and only
# its disabled sibling remains.  The portable executable-level test below
# invokes the same production handoff routine used by postinst.
legacy_v1_restore_tree="$fixture/legacy-v1-restore"
mkdir -p "$legacy_v1_restore_tree/etc/apt/sources.list.d" \
    "$legacy_v1_restore_tree/var/lib/dpkg/info" "$legacy_v1_restore_tree/var/lib/cydia"
printf '%s\n' 'deb https://legacy-v1-restore.example/ stable main' \
    >"$legacy_v1_restore_tree/etc/apt/sources.list.d/cydia.list.cydia.disabled"
printf '%s\n' \
    'version=1' \
    "source=$legacy_v1_restore_tree/etc/apt/sources.list.d/cydia.list" \
    "backup=$legacy_v1_restore_tree/etc/apt/sources.list.d/cydia.list.cydia.disabled" \
    >"$legacy_v1_restore_tree/var/lib/dpkg/info/cydia.legacy-source-marker"
test ! -e "$legacy_v1_restore_tree/etc/apt/sources.list.d/cydia.list" ||
    fail "version-1 restore fixture unexpectedly has a source target"
test -f "$legacy_v1_restore_tree/etc/apt/sources.list.d/cydia.list.cydia.disabled" ||
    fail "version-1 restore fixture lacks its backup"
assert_marker "$legacy_v1_restore_tree/var/lib/dpkg/info/cydia.legacy-source-marker" version 1
assert_marker "$legacy_v1_restore_tree/var/lib/dpkg/info/cydia.legacy-source-marker" \
    source "$legacy_v1_restore_tree/etc/apt/sources.list.d/cydia.list"
grep -Fq 'marker->legacy = true' "$handoff" ||
    fail "version-1 marker is not classified for restoration"
grep -Fq 'if (marker.legacy)' "$handoff" ||
    fail "version-1 marker has no restore-time object validation"

# An orphaned disabled backup has no provenance and must remain inert.  Even
# with a package ownership list present, preinst must not synthesize a marker
# or resurrect a source that may have been deliberately retired earlier.
orphan_tree="$fixture/orphan-backup"
mkdir -p "$orphan_tree/etc/apt/sources.list.d" "$orphan_tree/var/lib/dpkg/info" \
    "$orphan_tree/var/lib/cydia"
printf '%s\n' 'deb https://orphan.example/ stable main' \
    >"$orphan_tree/etc/apt/sources.list.d/cydia.list.cydia.disabled"
printf '%s\n' 'etc/apt/sources.list.d/cydia.list' \
    >"$orphan_tree/var/lib/dpkg/info/cydia.list"
DPKG_ROOT="$orphan_tree" DPKG_ADMINDIR=/var/lib/dpkg CYDIA= \
    "$root/preinst" configure || fail "orphan backup preinst handling failed"
test -f "$orphan_tree/etc/apt/sources.list.d/cydia.list.cydia.disabled" ||
    fail "orphan backup was removed without a marker"
test ! -e "$orphan_tree/etc/apt/sources.list.d/cydia.list" ||
    fail "orphan backup synthesized an active source"
test ! -e "$orphan_tree/var/lib/cydia/cydia.legacy-source-marker" ||
    fail "orphan backup synthesized a handoff marker"

# Procursus' rootless dpkg commonly keeps its administrative database under
# Library/dpkg rather than var/lib/dpkg.  Exercise both dpkg's in-root
# spelling and the fully-qualified spelling used by maintainer scripts.
for layout in rooted-admin absolute-admin; do
    case "$layout" in
        rooted-admin)
            tree="$fixture/root-library"
            admin=/Library/dpkg
            root_value="$tree/"
            ;;
        absolute-admin)
            tree="$fixture/absolute-library"
            admin="$tree/Library/dpkg"
            root_value=
            ;;
    esac
    mkdir -p "$tree/etc/apt/sources.list.d" "$tree/Library/dpkg/info" \
        "$tree/var/lib/cydia"
    printf '%s\n' 'deb https://library-admin.example/ stable main' \
        >"$tree/etc/apt/sources.list.d/cydia.list"
    printf '%s\n' 'etc/apt/sources.list.d/cydia.list' \
        >"$tree/Library/dpkg/info/cydia.list"
    if [[ "$layout" == rooted-admin ]]; then
        DPKG_ROOT="$root_value" DPKG_ADMINDIR="$admin" CYDIA= \
            "$root/preinst" configure || fail "Library/dpkg rooted migration failed"
    else
        DPKG_ROOT= DPKG_ADMINDIR="$admin" CYDIA= \
            "$root/preinst" configure || fail "Library/dpkg absolute migration failed"
    fi
    test ! -e "$tree/etc/apt/sources.list.d/cydia.list" ||
        fail "Library/dpkg legacy source path was not retired ($layout)"
    test -f "$tree/etc/apt/sources.list.d/cydia.list.cydia.disabled" ||
        fail "Library/dpkg legacy backup was not preserved ($layout)"
    assert_marker "$tree/var/lib/cydia/cydia.legacy-source-marker" mode sole
done

echo "[verify-apt-source-isolation][ ok ] maintainer APT paths preserved; Cydia source ownership is explicit and additive"
