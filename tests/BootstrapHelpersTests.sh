#!/bin/bash
# Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later
set -e

/bin/bash tests/FirmwareDiscoveryTests.sh
test_root=$(mktemp -d "${TMPDIR:-/tmp}/cydia-bootstrap-helpers.XXXXXX")
trap '/bin/rm -rf "${test_root}"' EXIT
mkdir -p "${test_root}/bin" "${test_root}/AutoInstall" "${test_root}/state"
trace=${test_root}/trace
: >"${trace}"
printf 'package fixture\n' >"${test_root}/AutoInstall/existing.deb"
printf '5\n' >"${test_root}/state/firmware.ver"
for command in dpkg firmware.sh killall sbdidlaunch su uicache rm cp mv ln chmod; do
    cat >"${test_root}/bin/${command}" <<'EOF'
#!/bin/bash
printf '%s\n' "$0 $*" >>"${TRACE}"
exit 71
EOF
    chmod +x "${test_root}/bin/${command}"
done
PATH=${test_root}/bin TRACE=${trace} CYDIA_AUTOINSTALL_DIR=${test_root}/AutoInstall \
    CYDIA_STATE=${test_root}/state /bin/bash Library/startup
[[ ! -s ${trace} ]] || { echo "Compatibility startup invoked a tool" >&2; exit 1; }
[[ $(/bin/cat "${test_root}/AutoInstall/existing.deb") == 'package fixture' ]] || exit 1
[[ $(/bin/cat "${test_root}/state/firmware.ver") == 5 ]] || exit 1
echo "bootstrap helper tests passed"
