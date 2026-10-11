#!/bin/sh
# Build the C++ driver against the same native vendored APT used by the
# repository-security fixture, then run it with isolated package indexes.
set -e
PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
: "${APT_INTEGRATION_TESTS_BUILD_DIR:?native APT build directory is required}"
ACTION_DRIVER="$APT_INTEGRATION_TESTS_BUILD_DIR/cydia-package-actions"
python3 "$PROJECT_DIR/tests/BuildAptBackendPolicyTest.py"
TESTDIR="$PROJECT_DIR/apt64/test/integration"
TESTDIRECTORY="$TESTDIR"
. "$TESTDIR/framework"
setupenvironment
configarchitecture 'amd64' 'i386'
configcompression '.'
insertinstalledpackage 'target' 'amd64' '2'
insertinstalledpackage 'held-target' 'amd64' '2' '' 'optional' 'hold ok installed'
insertinstalledpackage 'essential-target' 'amd64' '2' 'Essential: yes'
insertinstalledpackage 'protected-target' 'amd64' '2' 'Protected: yes'
insertinstalledpackage 'missing-reinstall' 'amd64' '4'
insertinstalledpackage 'residual-config' 'amd64' '1' '' 'optional' 'deinstall ok config-files'
insertpackage 'unstable' 'target' 'amd64' '1'
insertpackage 'unstable' 'target' 'amd64' '2'
insertpackage 'unstable' 'target' 'amd64' '3'
insertpackage 'unstable' 'held-target' 'amd64' '2'
insertpackage 'unstable' 'held-target' 'amd64' '3'
insertpackage 'unstable' 'essential-target' 'amd64' '2' 'Essential: yes'
insertpackage 'unstable' 'protected-target' 'amd64' '2' 'Protected: yes'
insertpackage 'unstable' 'missing-reinstall' 'amd64' '3'
insertpackage 'unstable' 'virtual-consumer' 'amd64' '1' 'Depends: unprovided-virtual'
mkdir -p rootdir/var/lib/apt
cat >rootdir/var/lib/apt/extended_states <<'EOF'
Package: target
Architecture: amd64
Auto-Installed: 1

EOF
cat >rootdir/etc/apt/preferences <<'EOF'
Package: target
Pin: version 1
Pin-Priority: 1001
EOF
setupaptarchive
testsuccess runapt "$ACTION_DRIVER"
if [ "$EXIT_CODE" -ne 0 ] && command -v gdb >/dev/null 2>&1; then
    runapt command gdb --batch -ex run -ex 'bt 12' --args "$ACTION_DRIVER" || true
fi
