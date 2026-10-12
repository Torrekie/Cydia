#!/bin/bash
# Copyright (C) 2026 Torrekie
# SPDX-License-Identifier: GPL-3.0-or-later
set -e
set -o pipefail

fail() { echo "firmware discovery test failed: $*" >&2; exit 1; }
test_root=$(mktemp -d "${TMPDIR:-/tmp}/cydia-firmware-tests.XXXXXX")
trap '/bin/rm -rf "${test_root}"' EXIT
fixture=${test_root}/prefix/usr/libexec/cydia
mock_bin=${test_root}/prefix/usr/bin
mock_state=${test_root}/prefix/var/lib/cydia
query_fixture=${test_root}/providers
discovery_fixture=${test_root}/discovery
controls=${test_root}/controls
trace=${test_root}/trace
preview=${test_root}/preview
invocations=${test_root}/invocations
mkdir -p "${fixture}" "${mock_bin}" "${controls}"
cp Library/firmware.sh "${fixture}/firmware.sh"
cat >"${fixture}/package-paths.sh" <<EOF
CYDIA_PREFIX=${test_root}/prefix
CYDIA_BIN=${mock_bin}
CYDIA_BSD_BIN=${mock_bin}
CYDIA_LIBEXEC=${fixture}
CYDIA_STATE=${mock_state}
CYDIA_DPKG_STATE=${test_root}/prefix/var/lib/dpkg
CYDIA_DPKG=${mock_bin}/dpkg
CYDIA_DPKG_DEB=${mock_bin}/dpkg-deb
CYDIA_DPKG_QUERY=${mock_bin}/dpkg-query
CYDIA_BOOTSTRAP_PATH=${mock_bin}:/bin:/usr/bin:/sbin:/usr/sbin
EOF

cat >"${mock_bin}/dpkg-query" <<'EOF'
#!/bin/bash
printf 'query %s\n' "$*" >>"${INVOCATION_LOG}"
[[ ${FAIL_QUERY:-0} != 1 ]] || exit 74
cat "${QUERY_FIXTURE}"
EOF
cat >"${fixture}/firmware-discovery" <<'EOF'
#!/bin/bash
if [[ ${1-} == --digest ]]; then
    python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'
else
    [[ ${FAIL_DISCOVERY:-0} != 1 ]] || exit 73
    cat "${DISCOVERY_FIXTURE}"
fi
EOF
cat >"${mock_bin}/gssc" <<'EOF'
#!/bin/bash
printf '    "DecimalLegacy" = 1.25;\n    "RetinaDisplay" = 9;\n    "ZeroLegacy" = 0.0;\n'
EOF
cat >"${mock_bin}/dpkg-deb" <<'EOF'
#!/bin/bash
package=$(sed -n 's/^Package: //p' "$3/DEBIAN/control")
printf 'build %s\n' "${package}" >>"${TRACE}"
cp "$3/DEBIAN/control" "${CONTROL_DIR}/${package}.control"
: >"$4"
EOF
cat >"${mock_bin}/dpkg" <<'EOF'
#!/bin/bash
printf 'dpkg %s\n' "$*" >>"${INVOCATION_LOG}"
while [[ ${1-} == --admindir=* || ${1-} == --root=* ]]; do shift; done
case ${1-} in
    --print-architecture) printf '%s\n' "${DPKG_ARCH:-iphoneos-arm64}" ;;
    --compare-versions)
        python3 - "$2" "$4" <<'PY'
import sys
def version(s): return tuple(int(x) for x in s.split('.'))
sys.exit(0 if version(sys.argv[1]) < version(sys.argv[2]) else 1)
PY
        ;;
    --install)
        printf 'install %s\n' "$*" >>"${TRACE}"
        [[ ${FAIL_INSTALL:-0} != 1 ]] || exit 42
        ;;
    *) printf 'unexpected dpkg %s\n' "$*" >>"${TRACE}"; exit 72 ;;
esac
EOF
cat >"${mock_bin}/chmod" <<'EOF'
#!/bin/bash
[[ ${FAIL_MARKER_CHMOD:-0} != 1 ]] || exit 79
/bin/chmod "$@"
EOF
ln -s /bin/mv "${mock_bin}/mv"
ln -s /bin/rm "${mock_bin}/rm"
chmod +x "${mock_bin}/dpkg" "${mock_bin}/dpkg-query" "${mock_bin}/dpkg-deb" \
    "${fixture}/firmware-discovery" "${mock_bin}/gssc" "${mock_bin}/chmod"
export TRACE=${trace} CONTROL_DIR=${controls} QUERY_FIXTURE=${query_fixture}
export DISCOVERY_FIXTURE=${discovery_fixture} DPKG_ARCH=iphoneos-arm64
export INVOCATION_LOG=${invocations}
export CYDIA_FIRMWARE_ROOT=${test_root}/prefix
export CYDIA_FIRMWARE_ADMINDIR=${test_root}/prefix/var/lib/dpkg

reset_fixture() {
    /bin/rm -rf "${mock_state}" "${controls}"
    mkdir -p "${controls}"
    : >"${query_fixture}"; : >"${trace}"; : >"${invocations}"
    printf 'identity\tfirmware\t17.0\nidentity\tcy+os.iphoneos\t17.0\n' >"${discovery_fixture}"
    printf 'identity\tcy+cpu.arm64\t0\nidentity\tcy+cpu.arm64e\t0\n' >>"${discovery_fixture}"
    printf 'identity\tcy+model.iphone\t15.2\nidentity\tcy+kernel.darwin\t23.0.0\n' >>"${discovery_fixture}"
    printf 'identity\tcy+lib.corefoundation\t1850.00\ngestalt\tipad\t1\n' >>"${discovery_fixture}"
    printf 'gestalt\tRetinaDisplay\t2\n' >>"${discovery_fixture}"
    printf 'gestalt\tDeviceSupportsLiquidDetection_CorrosionMitigation\t1\n' >>"${discovery_fixture}"
}
run_preview() { /bin/bash "${fixture}/firmware.sh" --preview >"${preview}"; }
review_token() { sed -n $'s/^review\t//p' "${preview}"; }
run_apply() {
    local token
    run_preview
    token=$(review_token)
    DPKG_FRONTEND_LOCKED=1 /bin/bash "${fixture}/firmware.sh" --apply \
        --require-frontend-lock --review-token "${token}"
}
assert_no_changes() {
    [[ ! -e ${mock_state} ]] || fail "preview/rejected apply wrote Cydia state"
    [[ -z $(ls -A "${controls}") ]] || fail "preview/rejected apply built a package"
    [[ ! -s ${trace} ]] || fail "preview/rejected apply invoked a package mutation"
}
assert_row() { grep -F -- "$1" "${preview}" >/dev/null || fail "missing preview row: $1"; }
assert_not_built() {
    [[ ! -e ${controls}/$1.control ]] || fail "preserved provider was overwritten: $1"
}

# Index all states and architectures in one pass; later lookups must not
# reopen a status snapshot whose providers may have changed.
reset_fixture
cat >"${query_fixture}" <<'EOF'
firmware|all|hold ok installed|17.0||zebra-firmware
firmware|iphoneos-arm64|install ok unpacked|17.0||cydia-refurbished.torrekie.dev/v1
EOF
/bin/bash -c '
    . "$1"
    installed_snapshot=$2
    index_package_records
    /bin/rm -f "${installed_snapshot}"
    inspect_package firmware
    [[ ${#provider_indices[@]} == 2 ]]
    [[ ${record_statuses[0]} == "hold ok installed" ]]
    [[ ${record_architectures[1]} == iphoneos-arm64 ]]
    inspect_package missing-provider
    [[ ${#provider_indices[@]} == 0 ]]
' _ "${fixture}/firmware.sh" "${query_fixture}" || fail "single-pass provider index lost records"

# Review is pure and deterministic; identities include both hardware CPU
# subtype and native-architecture aliases, and retain legacy decimal gsc data.
reset_fixture
run_preview
assert_no_changes
cp "${preview}" "${test_root}/first-preview"
run_preview
cmp -s "${preview}" "${test_root}/first-preview" || fail "preview is nondeterministic"
assert_row $'candidate\tgsc.retina-display\t2\tcreate\tmissing\t\t\t\t'
assert_row $'candidate\tgsc.decimal-legacy\t1.25\tcreate\tmissing'
assert_row $'candidate\tgsc.wildcat\t1\tcreate\tmissing'
if grep -F 'zero-legacy' "${preview}" >/dev/null; then fail "zero capability was emitted"; fi
if /bin/bash "${fixture}/firmware.sh" --apply >/dev/null 2>&1; then
    fail "explicit generation accepted no reviewed token"
fi
assert_no_changes
token=$(review_token)
if /bin/bash "${fixture}/firmware.sh" --apply --require-frontend-lock --review-token "${token}" >/dev/null 2>&1; then
    fail "explicit generation accepted no frontend-lock helper handshake"
fi
if DPKG_FRONTEND_LOCKED=1 /bin/bash "${fixture}/firmware.sh" --apply --review-token "${token}" >/dev/null 2>&1; then
    fail "environment token alone authorized generation"
fi
assert_no_changes
if (unset CYDIA_FIRMWARE_ROOT CYDIA_FIRMWARE_ADMINDIR
    DPKG_FRONTEND_LOCKED=1 /bin/bash "${fixture}/firmware.sh" --apply \
        --require-frontend-lock --review-token "${token}" >/dev/null 2>&1); then
    fail "generation accepted no runtime descriptor"
fi
assert_no_changes
run_apply
grep -q '^Version: 1.25$' "${controls}/gsc.decimal-legacy.control" || fail "decimal gsc version changed"
grep -q '^Version: 2$' "${controls}/gsc.retina-display.control" || fail "native gsc value lost to legacy duplicate"
grep -q '^X-Cydia-Firmware-Owner: cydia-refurbished.torrekie.dev/v1$' \
    "${controls}/firmware.control" || fail "generated package has no ownership marker"
[[ -e ${controls}/cy+cpu.arm64e.control ]] || fail "hardware CPU subtype missing"
[[ ! -e ${mock_state}/firmware.ver ]] || fail "explicit apply wrote legacy autorun marker"
if grep -E 'purge|unexpected dpkg' "${trace}" >/dev/null; then fail "unreviewed dpkg operation"; fi

reset_fixture
DPKG_ARCH=iphoneos-arm run_apply
[[ -e ${controls}/cy+cpu.arm.control ]] || fail "rootful native CPU alias missing"
[[ -e ${controls}/cy+cpu.arm64.control ]] || fail "rootful hardware CPU identity missing"
grep -q '^Architecture: iphoneos-arm$' "${controls}/cy+cpu.arm64.control" || fail "wrong package architecture"

# Effective APT root/admin paths are independent of the installed libexec.
reset_fixture
CYDIA_FIRMWARE_ROOT=${test_root}/different-root \
CYDIA_FIRMWARE_ADMINDIR=${test_root}/different-admin run_apply
grep -F -- "--root=${test_root}/different-root --admindir=${test_root}/different-admin --install" \
    "${invocations}" >/dev/null || fail "apply ignored effective runtime root/admin"
grep -F -- "query --admindir=${test_root}/different-admin" "${invocations}" >/dev/null || \
    fail "preview used a different administrative database"

# Every external dpkg state remains a provider; its status never grants Cydia
# ownership. Also preserve Cydia-owned held/partial/foreign records.
reset_fixture
cat >"${query_fixture}" <<'EOF'
firmware|all|deinstall ok config-files|17.0||zebra-firmware
gsc.ipad|all|hold ok installed|1||zebra-firmware
gsc.wildcat|all|install ok unpacked|1||zebra-firmware
gsc.retina-display|all|install ok half-configured|2||zebra-firmware
cy+os.iphoneos|all|install reinstreq half-installed|17.0||zebra-firmware
cy+cpu.arm64|iphoneos-arm64|hold ok installed|0||cydia-refurbished.torrekie.dev/v1
cy+cpu.arm64e|iphoneos-arm|install ok installed|0||cydia-refurbished.torrekie.dev/v1
cy+model.iphone|iphoneos-arm64|install ok unpacked|15.2||cydia-refurbished.torrekie.dev/v1
cy+model.iphone|iphoneos-arm|install ok installed|15.2||zebra-firmware
cy+kernel.darwin|iphoneos-arm64|install ok installed|99.0||cydia-refurbished.torrekie.dev/v1
cy+old|iphoneos-arm64|install ok installed|0||cydia-refurbished.torrekie.dev/v1
EOF
cp "${query_fixture}" "${test_root}/providers-before"
run_apply
for package in firmware gsc.ipad gsc.wildcat gsc.retina-display cy+os.iphoneos \
    cy+cpu.arm64 cy+cpu.arm64e cy+model.iphone cy+kernel.darwin cy+old; do
    assert_not_built "${package}"
done
cmp -s "${query_fixture}" "${test_root}/providers-before" || fail "provider database was rewritten"
assert_row $'candidate\tcy+cpu.arm64\t0\tpreserve\tpackage-state'
assert_row $'candidate\tcy+cpu.arm64e\t0\tpreserve\tforeign-architecture'
assert_row $'candidate\tcy+kernel.darwin\t23.0.0\tpreserve\tnewer-provider'
assert_row $'candidate\tcy+old\t0\tpreserve\tretained-provider'
grep -qx 'cy+old' "${mock_state}/firmware-packages.list" || fail "historical owned alias lost from receipt"

# A differently named package's Provides field is also a provider, including
# versioned aliases, noninstalled states and multiple aliases on one record.
reset_fixture
cat >"${query_fixture}" <<'EOF'
bootstrap-capabilities|all|hold ok unpacked|1|firmware (= 17.0), gsc.ipad, gsc.wildcat (= 1)|zebra-firmware
other-capabilities|iphoneos-arm|unknown ok not-installed||cy+cpu.arm64, cy+cpu.arm64e|
EOF
run_apply
for package in firmware gsc.ipad gsc.wildcat cy+cpu.arm64 cy+cpu.arm64e; do
    assert_not_built "${package}"
done
assert_row $'candidate\tfirmware\t17.0\tpreserve\tvirtual-provider\tall\thold ok unpacked\t1\tzebra-firmware\tbootstrap-capabilities'

# Previously installed names may use the legacy underscore spelling. They
# remain providers and preview rows, without becoming generated package names.
reset_fixture
cat >"${query_fixture}" <<'EOF'
gsc.legacy_capability|all|install ok installed|1||
legacy_provider|all|hold ok installed|1|firmware, gsc.retina-display|external
EOF
cp "${query_fixture}" "${test_root}/legacy-providers-before"
run_preview
assert_no_changes
assert_row $'candidate\tgsc.legacy_capability\t1\tpreserve\tretained-provider\tall\tinstall ok installed\t1\t\tgsc.legacy_capability'
assert_row $'candidate\tfirmware\t17.0\tpreserve\tvirtual-provider\tall\thold ok installed\t1\texternal\tlegacy_provider'
run_apply
assert_not_built gsc.legacy_capability
assert_not_built legacy_provider
assert_not_built firmware
assert_not_built gsc.retina-display
cmp -s "${query_fixture}" "${test_root}/legacy-providers-before" || fail "legacy provider database was rewritten"
reset_fixture
printf 'identity\tgsc.invalid_name\t1\n' >>"${discovery_fixture}"
if run_preview >/dev/null 2>&1; then fail "generation accepted a legacy-only package name"; fi
assert_no_changes

# Cydia may update only its single, unheld, healthy native record.
reset_fixture
printf 'firmware|iphoneos-arm64|install ok installed|16.0||cydia-refurbished.torrekie.dev/v1\n' >"${query_fixture}"
run_apply
[[ -e ${controls}/firmware.control ]] || fail "owned native update was not built"
assert_row $'candidate\tfirmware\t17.0\tupdate\towned-update'

# A provider appearing, changing state, architecture or ownership between
# review and apply invalidates approval before any generation takes place.
for record in \
    'firmware|all|unknown ok not-installed|||zebra-firmware' \
    'firmware|iphoneos-arm64|hold ok installed|16.0||cydia-refurbished.torrekie.dev/v1' \
    'firmware|iphoneos-arm|install ok installed|16.0||cydia-refurbished.torrekie.dev/v1'; do
    reset_fixture
    run_preview
    token=$(review_token)
    printf '%s\n' "${record}" >"${query_fixture}"
    if DPKG_FRONTEND_LOCKED=1 /bin/bash "${fixture}/firmware.sh" --apply \
        --require-frontend-lock --review-token "${token}" >/dev/null 2>&1; then
        fail "apply accepted a stale reviewed provider snapshot"
    fi
    assert_no_changes
    run_preview
    assert_row $'candidate\tfirmware\t17.0\tpreserve'
done

reset_fixture
if FAIL_QUERY=1 run_preview; then fail "failed query was treated as empty database"; fi
assert_no_changes
if FAIL_DISCOVERY=1 run_preview; then fail "failed discovery was treated as complete"; fi
assert_no_changes

reset_fixture
mkdir -p "${mock_state}"
printf 'prior-owned\n' >"${mock_state}/firmware-packages.list"
run_preview
token=$(review_token)
if FAIL_INSTALL=1 DPKG_FRONTEND_LOCKED=1 /bin/bash "${fixture}/firmware.sh" --apply \
    --require-frontend-lock --review-token "${token}"; then
    fail "failed dpkg install was ignored"
fi
[[ $(cat "${mock_state}/firmware-packages.list") == prior-owned ]] || fail "failed install published a receipt"
[[ ! -e ${mock_state}/firmware.ver ]] || fail "failed install published completion"

# Invalid private state must be rejected before any bootstrap package writes.
reset_fixture
mkdir -p "${test_root}/other-state"
ln -s "${test_root}/other-state" "${mock_state}"
run_preview
token=$(review_token)
if DPKG_FRONTEND_LOCKED=1 /bin/bash "${fixture}/firmware.sh" --apply \
    --require-frontend-lock --review-token "${token}" >/dev/null 2>&1; then
    fail "generation accepted a symlinked private state directory"
fi
[[ ! -s ${trace} && -z $(ls -A "${controls}") ]] || fail "invalid state was detected after package writes"

# Discovery cannot be redirected to another directory or a symlinked binary.
reset_fixture
mv "${fixture}/firmware-discovery" "${test_root}/discovery-implementation"
ln -s "${test_root}/discovery-implementation" "${fixture}/firmware-discovery"
if run_preview; then fail "preview accepted a symlinked discovery binary"; fi
assert_no_changes
/bin/rm "${fixture}/firmware-discovery"
mv "${test_root}/discovery-implementation" "${fixture}/firmware-discovery"
cp "${fixture}/firmware.sh" "${fixture}/package-paths.sh" "${test_root}/"
if /bin/bash "${test_root}/firmware.sh" --preview >/dev/null 2>&1; then
    fail "relocated script selected another installation's libexec"
fi
assert_no_changes

# No-argument compatibility calls are review-only and preserve old markers.
reset_fixture
mkdir -p "${mock_state}"
printf '5\n' >"${mock_state}/firmware.ver"
/bin/bash "${fixture}/firmware.sh" >"${preview}"
[[ $(cat "${mock_state}/firmware.ver") == 5 ]] || fail "preview replaced an old marker"
[[ ! -s ${trace} && -z $(ls -A "${controls}") ]] || fail "no-argument preview mutated packages"
run_apply
[[ $(cat "${mock_state}/firmware.ver") == 5 ]] || fail "explicit apply replaced an old autorun marker"
if grep -E 'migrate_user_directory|/User|setupUserSymbolicLink|--purge|--force-all' \
    Library/firmware.sh >/dev/null; then fail "firmware generation retains unrelated migration/removal"; fi

python3 tests/FirmwareDiscoveryCoverageTests.py
echo "firmware discovery tests passed"
