#!/bin/bash
# Copyright (C) 2026 Torrekie
# SPDX-License-Identifier: GPL-3.0-or-later

set -e

fail() {
    echo "bootstrap helper test failed: $*" >&2
    exit 1
}

test_root=$(mktemp -d "${TMPDIR:-/tmp}/cydia-bootstrap-helpers.XXXXXX")
trap '/bin/rm -rf "${test_root}"' EXIT

mock_bin=${test_root}/bin
mock_libexec=${test_root}/libexec
mock_state=${test_root}/state
fixture=${test_root}/fixture
trace=${test_root}/trace
mkdir -p "${mock_bin}" "${mock_libexec}" "${mock_state}" "${fixture}"

cp Library/firmware.sh Library/startup "${fixture}/"

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
printf 'build %s\n' "$*" >>"${TRACE}"
for output in "$@"; do :; done
: >"${output}"
EOF

cat >"${mock_bin}/dpkg-query" <<'EOF'
#!/bin/bash
printf '%s\n' firmware gsc.stale cy+old cy+os.macosx
EOF

cat >"${mock_bin}/dpkg" <<'EOF'
#!/bin/bash
printf 'dpkg %s\n' "$*" >>"${TRACE}"
if [[ ($1 == --install || $1 == -i) && ${FAIL_INSTALL:-0} == 1 ]]; then
    exit 42
fi
EOF

cat >"${mock_bin}/sw_vers" <<'EOF'
#!/bin/bash
echo 14.0
EOF

cat >"${mock_bin}/uname" <<'EOF'
#!/bin/bash
[[ $1 == -p ]] && echo x86_64
EOF

cat >"${mock_bin}/sysctl" <<'EOF'
#!/bin/bash
case "$2" in
    hw.model) echo MacBookPro1,1 ;;
    kern.ostype) echo Darwin ;;
    *) exit 2 ;;
esac
EOF

cat >"${mock_libexec}/cfversion" <<'EOF'
#!/bin/bash
echo 1850.0
EOF

chmod +x "${fixture}/firmware.sh" "${fixture}/startup" \
    "${mock_bin}/dpkg-deb" "${mock_bin}/dpkg-query" "${mock_bin}/dpkg" \
    "${mock_bin}/sw_vers" "${mock_bin}/uname" "${mock_bin}/sysctl" \
    "${mock_libexec}/cfversion"

: >"${trace}"
TRACE=${trace} /bin/bash "${fixture}/firmware.sh"

last_build=$(grep -n '^build ' "${trace}" | tail -1 | cut -d: -f1)
install_line=$(grep -n '^dpkg --install ' "${trace}" | cut -d: -f1)
purge_line=$(grep -n '^dpkg --purge ' "${trace}" | cut -d: -f1)
[[ -n ${last_build} && -n ${install_line} && ${last_build} -lt ${install_line} ]] || \
    fail "replacement packages were not built before installation"
[[ -n ${purge_line} && ${install_line} -lt ${purge_line} ]] || \
    fail "stale packages were purged before replacements were installed"
grep '^dpkg --purge ' "${trace}" | grep -q 'gsc.stale' || fail "stale gsc package not purged"
grep '^dpkg --purge ' "${trace}" | grep -q 'cy+old' || fail "stale cy package not purged"
if grep '^dpkg --purge ' "${trace}" | grep -q 'cy+os.macosx'; then
    fail "newly replaced package was purged"
fi

: >"${trace}"
if TRACE=${trace} FAIL_INSTALL=1 /bin/bash "${fixture}/firmware.sh"; then
    fail "firmware helper ignored replacement install failure"
fi
if grep -q '^dpkg --purge ' "${trace}"; then
    fail "firmware helper purged metadata after replacement failure"
fi

cat >"${mock_libexec}/firmware.sh" <<'EOF'
#!/bin/bash
exit 0
EOF
cat >"${mock_bin}/rm" <<'EOF'
#!/bin/bash
printf 'rm %s\n' "$*" >>"${TRACE}"
/bin/rm "$@"
EOF
for command in killall sbdidlaunch su; do
    cat >"${mock_bin}/${command}" <<'EOF'
#!/bin/bash
exit 0
EOF
done
chmod +x "${mock_libexec}/firmware.sh" "${mock_bin}/rm" \
    "${mock_bin}/killall" "${mock_bin}/sbdidlaunch" "${mock_bin}/su"

autoinstall=${test_root}/AutoInstall
mkdir -p "${autoinstall}"
: >"${autoinstall}/failure.deb"
: >"${trace}"
TRACE=${trace} FAIL_INSTALL=1 CYDIA_AUTOINSTALL_DIR=${autoinstall} \
    /bin/bash "${fixture}/startup"
[[ -f ${autoinstall}/failure.deb ]] || fail "failed AutoInstall package was deleted"

/bin/rm -f "${autoinstall}/failure.deb"
: >"${autoinstall}/success.deb"
: >"${trace}"
TRACE=${trace} CYDIA_AUTOINSTALL_DIR=${autoinstall} /bin/bash "${fixture}/startup"
[[ ! -e ${autoinstall}/success.deb ]] || fail "successful AutoInstall package was retained"

echo "bootstrap helper tests passed"
