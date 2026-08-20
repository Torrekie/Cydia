#!/bin/bash
# Copyright (C) 2026 Torrekie
# SPDX-License-Identifier: GPL-3.0-or-later

set -e

fail() {
    echo "bootstrap helper test failed: $*" >&2
    exit 1
}

assert_trace_contains() {
    grep -F -- "$1" "${trace}" >/dev/null || fail "trace does not contain: $1"
}

assert_trace_excludes() {
    if grep -F -- "$1" "${trace}" >/dev/null; then
        fail "trace unexpectedly contains: $1"
    fi
}

test_root=$(mktemp -d "${TMPDIR:-/tmp}/cydia-bootstrap-helpers.XXXXXX")
trap '/bin/rm -rf "${test_root}"' EXIT

mock_bin=${test_root}/bin
mock_libexec=${test_root}/libexec
mock_state=${test_root}/state
fixture=${test_root}/fixture
controls=${test_root}/controls
query_fixture=${test_root}/installed-packages
trace=${test_root}/trace
mkdir -p "${mock_bin}" "${mock_libexec}" "${mock_state}" "${fixture}" "${controls}"

cp Library/firmware.sh Library/startup "${fixture}/"
[[ $(sed -n '1p' "${fixture}/firmware.sh") == '#!/bin/bash' ]] || fail "firmware shebang changed"
[[ $(sed -n '1p' "${fixture}/startup") == '#!/bin/bash' ]] || fail "startup shebang changed"

cat >"${fixture}/package-paths.sh" <<EOF
CYDIA_PREFIX=${test_root}/prefix
CYDIA_BIN=${mock_bin}
CYDIA_BSD_BIN=${mock_bin}
CYDIA_SBIN=${mock_bin}
CYDIA_BSD_SBIN=${mock_bin}
CYDIA_LIBEXEC=${mock_libexec}
CYDIA_STATE=${mock_state}
CYDIA_DPKG_STATE=${test_root}/dpkg-state
CYDIA_DPKG=${mock_bin}/dpkg
CYDIA_DPKG_DEB=${mock_bin}/dpkg-deb
CYDIA_DPKG_QUERY=${mock_bin}/dpkg-query
CYDIA_APT_STATE=${test_root}/apt-state
CYDIA_APT_CONFIG=${test_root}/apt-config
CYDIA_BOOTSTRAP_PATH=${mock_bin}:/bin:/usr/bin:/sbin:/usr/sbin
export CYDIA_PREFIX CYDIA_BIN CYDIA_BSD_BIN CYDIA_SBIN CYDIA_BSD_SBIN
export CYDIA_LIBEXEC CYDIA_STATE CYDIA_DPKG_STATE CYDIA_DPKG
export CYDIA_DPKG_DEB CYDIA_DPKG_QUERY CYDIA_APT_STATE CYDIA_APT_CONFIG
export CYDIA_BOOTSTRAP_PATH
EOF

cat >"${mock_bin}/dpkg-deb" <<'EOF'
#!/bin/bash
package=$(/usr/bin/sed -n 's/^Package: //p' "$3/DEBIAN/control")
printf 'build %s\n' "${package}" >>"${TRACE}"
/bin/cp "$3/DEBIAN/control" "${CONTROL_DIR}/${package}.control"
: >"$4"
EOF

cat >"${mock_bin}/dpkg-query" <<'EOF'
#!/bin/bash
[[ ${FAIL_QUERY:-0} == 1 ]] && exit 74
/bin/cat "${QUERY_FIXTURE}"
EOF

cat >"${mock_bin}/dpkg" <<'EOF'
#!/bin/bash
printf 'dpkg %s\n' "$*" >>"${TRACE}"
if [[ $1 == --print-architecture ]]; then
    printf '%s\n' "${DPKG_ARCH}"
    exit 0
fi
if [[ ($1 == --install || $1 == -i) && ${FAIL_INSTALL:-0} == 1 ]]; then
    exit 42
fi
if [[ $1 == --purge && ${FAIL_PURGE:-0} == 1 ]]; then
    exit 43
fi
EOF

cat >"${mock_bin}/sw_vers" <<'EOF'
#!/bin/bash
echo 14.0
EOF

cat >"${mock_bin}/uname" <<'EOF'
#!/bin/bash
echo "firmware helper must not derive package names from uname" >&2
exit 75
EOF

cat >"${mock_bin}/dirname" <<'EOF'
#!/bin/bash
echo "bootstrap helpers must locate companion files without dirname" >&2
exit 78
EOF

cat >"${mock_bin}/sysctl" <<'EOF'
#!/bin/bash
case "$2" in
    hw.machine) echo iPhone15,2 ;;
    kern.ostype) echo Darwin ;;
    kern.osrelease) echo 23.0.0 ;;
    *) exit 2 ;;
esac
EOF

cat >"${mock_bin}/gssc" <<'EOF'
#!/bin/bash
cat <<'OUTPUT'
    "ipad" = 1;
    "RetinaDisplay" = 2;
OUTPUT
EOF

cat >"${mock_libexec}/cfversion" <<'EOF'
#!/bin/bash
echo 1850.0
EOF

cat >"${mock_bin}/cp" <<'EOF'
#!/bin/bash
printf 'cp %s\n' "$*" >>"${TRACE}"
[[ ${FAIL_COPY:-0} == 1 ]] && exit 76
/bin/cp "$@"
EOF

cat >"${mock_bin}/rm" <<'EOF'
#!/bin/bash
printf 'rm %s\n' "$*" >>"${TRACE}"
/bin/rm "$@"
EOF

cat >"${mock_bin}/ln" <<'EOF'
#!/bin/bash
printf 'ln %s\n' "$*" >>"${TRACE}"
[[ ${FAIL_LINK:-0} == 1 ]] && exit 77
/bin/ln "$@"
EOF

cat >"${mock_bin}/mv" <<'EOF'
#!/bin/bash
printf 'mv %s\n' "$*" >>"${TRACE}"
/bin/mv "$@"
EOF

chmod +x "${fixture}/firmware.sh" "${fixture}/startup" \
    "${mock_bin}/dpkg-deb" "${mock_bin}/dpkg-query" "${mock_bin}/dpkg" \
    "${mock_bin}/sw_vers" "${mock_bin}/uname" "${mock_bin}/dirname" \
    "${mock_bin}/sysctl" \
    "${mock_bin}/gssc" "${mock_bin}/cp" "${mock_bin}/rm" \
    "${mock_bin}/ln" "${mock_bin}/mv" "${mock_libexec}/cfversion"

run_firmware() {
    TRACE=${trace} CONTROL_DIR=${controls} QUERY_FIXTURE=${query_fixture} \
        DPKG_ARCH=${DPKG_ARCH:-iphoneos-arm64} /bin/bash "${fixture}/firmware.sh"
}

reset_firmware_fixture() {
    /bin/rm -rf "${mock_state}" "${controls}"
    mkdir -p "${mock_state}" "${controls}"
    : >"${query_fixture}"
    : >"${trace}"
}

# Externally owned firmware/gsc/cy+ packages are name collisions, not Cydia
# state. Only a marked, desired package may be updated, and only a marked stale
# name from Cydia's manifest may be purged.
reset_firmware_fixture
cat >"${query_fixture}" <<'EOF'
firmware|install ok installed|procursus
gsc.ipad|install ok installed|procursus
gsc.wildcat|install ok installed|procursus
gsc.retina-display|install ok installed|procursus
cy+os.iphoneos|install ok installed|procursus
cy+cpu.arm64|install ok installed|procursus
cy+cpu.arm64e|install ok installed|procursus
cy+model.iphone|install ok installed|cydia-refurbished.torrekie.dev/v1
cy+old|install ok installed|cydia-refurbished.torrekie.dev/v1
cy+stale-external|install ok installed|procursus
EOF
cat >"${mock_state}/firmware-packages.list" <<'EOF'
cy+model.iphone
cy+old
cy+cpu.arm64e
cy+stale-external
EOF
run_firmware

assert_trace_contains 'build cy+model.iphone'
assert_trace_contains 'build cy+kernel.darwin'
assert_trace_contains 'build cy+lib.corefoundation'
assert_trace_excludes 'build firmware'
assert_trace_excludes 'build gsc.ipad'
assert_trace_excludes 'build cy+cpu.arm64'
assert_trace_excludes 'build cy+os.iphoneos'
assert_trace_contains 'dpkg --purge cy+old'
assert_trace_excludes 'cy+cpu.arm64e.deb'
assert_trace_excludes 'dpkg --purge cy+cpu.arm64e'
assert_trace_excludes 'dpkg --purge cy+stale-external'
assert_trace_excludes '--force-all'

expected_manifest=${test_root}/expected-manifest
printf '%s\n' cy+model.iphone cy+kernel.darwin cy+lib.corefoundation >"${expected_manifest}"
cmp -s "${expected_manifest}" "${mock_state}/firmware-packages.list" || \
    fail "managed firmware manifest did not retain only Cydia-owned desired packages"
[[ $(cat "${mock_state}/firmware.ver") == 6 ]] || fail "firmware version was not committed"

# With an empty database, dpkg's native architecture drives current virtual
# names. uname is a hard-failing mock, so reaching this point also proves it
# was not consulted.
reset_firmware_fixture
run_firmware
[[ -e ${controls}/cy+cpu.arm64.control ]] || fail "iphoneos-arm64 CPU package was not generated"
[[ -e ${controls}/cy+os.iphoneos.control ]] || fail "iphoneos operating-system package was not generated"
[[ ! -e ${controls}/cy+cpu.arm.control ]] || fail "legacy uname-derived CPU package was generated"
[[ ! -e ${controls}/cy+os.ios.control ]] || fail "legacy os.ios package was generated"
grep -q '^Architecture: iphoneos-arm64$' "${controls}/cy+cpu.arm64.control" || \
    fail "generated package architecture did not come from dpkg"
grep -q '^X-Cydia-Firmware-Owner: cydia-refurbished.torrekie.dev/v1$' \
    "${controls}/cy+cpu.arm64.control" || fail "generated package lacks ownership marker"

reset_firmware_fixture
DPKG_ARCH=iphoneos-arm run_firmware
[[ -e ${controls}/cy+cpu.arm.control ]] || fail "iphoneos-arm CPU package was not generated"
[[ ! -e ${controls}/cy+cpu.arm64.control ]] || fail "rooted layout generated the rootless CPU package"
grep -q '^Architecture: iphoneos-arm$' "${controls}/cy+cpu.arm.control" || \
    fail "rooted generated package architecture did not come from dpkg"

# A failed install must leave the previous durable state untouched. Retrying
# without the injected failure must regenerate packages and commit state.
reset_firmware_fixture
printf '%s\n' cy+old >"${mock_state}/firmware-packages.list"
if TRACE=${trace} CONTROL_DIR=${controls} QUERY_FIXTURE=${query_fixture} \
    DPKG_ARCH=iphoneos-arm64 FAIL_INSTALL=1 /bin/bash "${fixture}/firmware.sh"; then
    fail "firmware helper ignored generated-package install failure"
fi
[[ $(cat "${mock_state}/firmware-packages.list") == cy+old ]] || \
    fail "failed install replaced the managed manifest"
[[ ! -e ${mock_state}/firmware.ver ]] || fail "failed install wrote firmware.ver"
assert_trace_excludes 'dpkg --purge'
: >"${trace}"
run_firmware
[[ -e ${mock_state}/firmware.ver ]] || fail "successful retry did not write firmware.ver"

# A purge failure also keeps the prior manifest and completion marker intact
# for retry; no broad force option may be used to bypass bootstrap dependencies.
reset_firmware_fixture
cat >"${query_fixture}" <<'EOF'
firmware|install ok installed|procursus
gsc.ipad|install ok installed|procursus
gsc.wildcat|install ok installed|procursus
gsc.retina-display|install ok installed|procursus
cy+os.iphoneos|install ok installed|procursus
cy+cpu.arm64|install ok installed|procursus
cy+model.iphone|install ok installed|procursus
cy+kernel.darwin|install ok installed|procursus
cy+lib.corefoundation|install ok installed|procursus
cy+old|install ok installed|cydia-refurbished.torrekie.dev/v1
EOF
printf '%s\n' cy+old >"${mock_state}/firmware-packages.list"
if TRACE=${trace} CONTROL_DIR=${controls} QUERY_FIXTURE=${query_fixture} \
    DPKG_ARCH=iphoneos-arm64 FAIL_PURGE=1 /bin/bash "${fixture}/firmware.sh"; then
    fail "firmware helper ignored managed-package purge failure"
fi
[[ $(cat "${mock_state}/firmware-packages.list") == cy+old ]] || \
    fail "failed purge replaced the managed manifest"
[[ ! -e ${mock_state}/firmware.ver ]] || fail "failed purge wrote firmware.ver"
assert_trace_contains 'dpkg --purge cy+old'
assert_trace_excludes '--force-all'
: >"${trace}"
run_firmware
[[ ! -s ${mock_state}/firmware-packages.list ]] || \
    fail "successful purge retry retained a stale managed name"

# An unreadable dpkg database must be a hard stop before any package changes.
reset_firmware_fixture
printf '%s\n' cy+old >"${mock_state}/firmware-packages.list"
if TRACE=${trace} CONTROL_DIR=${controls} QUERY_FIXTURE=${query_fixture} \
    DPKG_ARCH=iphoneos-arm64 FAIL_QUERY=1 /bin/bash "${fixture}/firmware.sh"; then
    fail "firmware helper treated a failed package query as an empty database"
fi
assert_trace_excludes 'dpkg --install'
assert_trace_excludes 'dpkg --purge'
[[ $(cat "${mock_state}/firmware-packages.list") == cy+old ]] || \
    fail "failed package query replaced the managed manifest"

# Exercise the rootful /User migration with safe fixture paths. Copy or link
# failures must leave firmware.ver absent so a later run retries the migration.
copy_state=${test_root}/copy-state
copy_user=${test_root}/User
copy_mobile=${test_root}/mobile
mkdir -p "${copy_state}" "${copy_user}" "${copy_mobile}"
printf 'preserve me\n' >"${copy_user}/data"
if TRACE=${trace} FAIL_COPY=1 /bin/bash -c '
    . "$1"
    CYDIA_PREFIX=
    CYDIA_STATE=$2
    finalize_firmware_state "$3" "$4"
' _ "${fixture}/firmware.sh" "${copy_state}" "${copy_user}" "${copy_mobile}"; then
    fail "rootful user migration ignored copy failure"
fi
[[ ! -e ${copy_state}/firmware.ver ]] || fail "copy failure wrote firmware.ver"
TRACE=${trace} /bin/bash -c '
    . "$1"
    CYDIA_PREFIX=
    CYDIA_STATE=$2
    finalize_firmware_state "$3" "$4"
' _ "${fixture}/firmware.sh" "${copy_state}" "${copy_user}" "${copy_mobile}"
[[ -h ${copy_user} ]] || fail "successful copy retry did not create the /User link"
[[ -e ${copy_mobile}/data ]] || fail "successful copy retry lost /User contents"
[[ $(cat "${copy_state}/firmware.ver") == 6 ]] || fail "successful copy retry did not write firmware.ver"

link_state=${test_root}/link-state
link_user=${test_root}/LinkUser
mkdir -p "${link_state}"
if TRACE=${trace} FAIL_LINK=1 /bin/bash -c '
    . "$1"
    CYDIA_PREFIX=
    CYDIA_STATE=$2
    finalize_firmware_state "$3" "$4"
' _ "${fixture}/firmware.sh" "${link_state}" "${link_user}" "${copy_mobile}"; then
    fail "rootful user migration ignored link failure"
fi
[[ ! -e ${link_state}/firmware.ver ]] || fail "link failure wrote firmware.ver"

# Startup must stop before AutoInstall when firmware maintenance fails, and it
# must retain AutoInstall packages after either failure path.
cat >"${mock_libexec}/firmware.sh" <<'EOF'
#!/bin/bash
exit 71
EOF
for command in killall sbdidlaunch su; do
    cat >"${mock_bin}/${command}" <<'EOF'
#!/bin/bash
exit 0
EOF
done
chmod +x "${mock_libexec}/firmware.sh" "${mock_bin}/killall" \
    "${mock_bin}/sbdidlaunch" "${mock_bin}/su"

autoinstall=${test_root}/AutoInstall
mkdir -p "${autoinstall}"
: >"${autoinstall}/firmware-failure.deb"
: >"${trace}"
if TRACE=${trace} QUERY_FIXTURE=${query_fixture} DPKG_ARCH=iphoneos-arm64 \
    CYDIA_AUTOINSTALL_DIR=${autoinstall} /bin/bash "${fixture}/startup"; then
    fail "startup ignored firmware maintenance failure"
fi
[[ -f ${autoinstall}/firmware-failure.deb ]] || \
    fail "startup deleted AutoInstall package after firmware failure"
assert_trace_excludes 'dpkg -i'

cat >"${mock_libexec}/firmware.sh" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "${mock_libexec}/firmware.sh"
/bin/rm -f "${autoinstall}/firmware-failure.deb"
: >"${autoinstall}/install-failure.deb"
: >"${trace}"
TRACE=${trace} FAIL_INSTALL=1 CYDIA_AUTOINSTALL_DIR=${autoinstall} \
    /bin/bash "${fixture}/startup"
[[ -f ${autoinstall}/install-failure.deb ]] || fail "failed AutoInstall package was deleted"

/bin/rm -f "${autoinstall}/install-failure.deb"
: >"${autoinstall}/success.deb"
: >"${trace}"
TRACE=${trace} CYDIA_AUTOINSTALL_DIR=${autoinstall} /bin/bash "${fixture}/startup"
[[ ! -e ${autoinstall}/success.deb ]] || fail "successful AutoInstall package was retained"

echo "bootstrap helper tests passed"
