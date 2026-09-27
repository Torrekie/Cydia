#!/bin/sh
# Copyright (C) 2026 Torrekie
# SPDX-License-Identifier: GPL-3.0-or-later

# This is host-only policy accounting.  It deliberately does not claim that
# an allowed member has been exercised by an installed caller.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
operations="$root/Cydia/LegacyBridgeOperations.def"
properties="$root/Cydia/LegacyBridgeProperties.def"
api_fixture="$root/tests/fixtures/ui/legacy-api.tsv"
property_fixture="$root/tests/fixtures/ui/legacy-properties.tsv"
tmp_root=${TMPDIR:-/tmp}
work=$(mktemp -d "$tmp_root/cydia-legacy-inventory.XXXXXX")
cleanup() {
    rm -rf -- "$work"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

fail() {
    echo "[verify-legacy-ui-inventory][FAIL] $*" >&2
    exit 1
}

test -f "$operations" || fail "missing operation definitions"
test -f "$properties" || fail "missing property definitions"
test -f "$api_fixture" || fail "missing API fixture"
test -f "$property_fixture" || fail "missing property fixture"

awk '
    function trim(value) {
        sub(/^[[:space:]]+/, "", value)
        sub(/[[:space:]]+$/, "", value)
        return value
    }
    /^CYDIA_LEGACY_BRIDGE_OPERATION\(/ {
        line=$0
        sub(/^CYDIA_LEGACY_BRIDGE_OPERATION\(/, "", line)
        sub(/\)[[:space:]]*$/, "", line)
        n=split(line, f, /,[[:space:]]*/)
        if (n != 5) bad=1
        for (i=1; i<=n; ++i) f[i]=trim(f[i])
        gsub(/_/, "-", f[3]); gsub(/_/, "-", f[4]); gsub(/_/, "-", f[5])
        print f[1] "\tmethod\t" f[2] "\t" f[3] "\t" f[4] "\t" f[5]
    }
    END { exit bad }
' "$operations" | LC_ALL=C sort -u > "$work/operations.tsv" ||
    fail "malformed operation definitions"

awk '
    function trim(value) {
        sub(/^[[:space:]]+/, "", value)
        sub(/[[:space:]]+$/, "", value)
        return value
    }
    /^CYDIA_LEGACY_BRIDGE_PROPERTY\(/ {
        line=$0
        sub(/^CYDIA_LEGACY_BRIDGE_PROPERTY\(/, "", line)
        sub(/\)[[:space:]]*$/, "", line)
        n=split(line, f, /,[[:space:]]*/)
        if (n != 7) bad=1
        for (i=1; i<=n; ++i) {
            f[i]=trim(f[i])
            if (i != 1 && i != 3) gsub(/_/, "-", f[i])
        }
        print f[1] "\t" f[2] "\t" f[3] "\t" f[4] "\t" \
            f[5] "\t" f[6] "\t" f[7]
    }
    END { exit bad }
' "$properties" | LC_ALL=C sort -u > "$work/properties.tsv" ||
    fail "malformed property definitions"

awk -F '\t' '!/^#/ && NF == 6 { print }' "$api_fixture" |
    LC_ALL=C sort -u > "$work/fixture-operations.tsv"
if ! diff -u "$work/fixture-operations.tsv" "$work/operations.tsv" \
        > "$work/operations.diff"; then
    sed -n '1,120p' "$work/operations.diff" >&2
    fail "operation definitions diverge from the public fixture"
fi

awk -F '\t' '!/^#/ && NF == 4 { print $1 "\t" $2 "\t" $3 "\t" $4 }' \
    "$property_fixture" | LC_ALL=C sort -u > "$work/fixture-property-identities.tsv"
cut -f 1-4 "$work/properties.tsv" |
    LC_ALL=C sort -u > "$work/property-identities.tsv"
if ! diff -u "$work/fixture-property-identities.tsv" \
        "$work/property-identities.tsv" > "$work/properties.diff"; then
    sed -n '1,120p' "$work/properties.diff" >&2
    fail "property definitions diverge from the public fixture"
fi

# Derive the trusted in-process partition from the same deny families used by
# the policy.  Session reads are the sole exception inside the session family;
# clipboard gesture rows are intentionally denied for this partition.
awk -F '\t' '
    function allowed_operation(family, trusted, name) {
        if (trusted != "allow") return 0
        if (family == "sensitive" || family == "chrome" ||
            family == "clipboard" || family == "retired") return 0
        if (family == "session" && name != "getSessionValue") return 0
        return 1
    }
    {
        total++
        if (allowed_operation($4, $5, $3)) allow++
        else deny++
    }
    END {
        printf "%d\t%d\t%d\n", total, allow, deny
    }
' "$work/operations.tsv" > "$work/operation-count.tsv"

awk -F '\t' '
    function allowed_property(family, trusted) {
        if (trusted != "allow") return 0
        if (family == "sensitive" || family == "chrome" || family == "retired") return 0
        return 1
    }
    {
        total++
        if (allowed_property($5, $6)) allow++
        else deny++
    }
    END {
        printf "%d\t%d\t%d\n", total, allow, deny
    }
' "$work/properties.tsv" > "$work/property-count.tsv"

read operation_total operation_allow operation_deny < "$work/operation-count.tsv"
read property_total property_allow property_deny < "$work/property-count.tsv"
total=$((operation_total + property_total))
allowed=$((operation_allow + property_allow))
denied=$((operation_deny + property_deny))
test "$total" -eq 152 || fail "expected 152 inventory rows, got $total"
test "$allowed" -eq 87 || fail "expected 87 trusted allowed rows, got $allowed"
test "$denied" -eq 65 || fail "expected 65 intentional denials, got $denied"
test $((allowed + denied)) -eq "$total" || fail "partition does not sum to total"

metadata_count=$(awk -F '\t' '
    $1 == "CydiaObject" && $2 == "method" &&
    ($3 == "getMetadataKeys" || $3 == "getMetadataValue") &&
    $4 == "global-read" && $5 == "allow" { count++ }
    END { print count + 0 }
' "$work/operations.tsv")
test "$metadata_count" -eq 2 ||
    fail "metadata reads are not both represented as allowed global-read rows"

echo "[verify-legacy-ui-inventory][ ok ] $total inventory rows ($allowed allow, $denied deny); host policy accounting only"
