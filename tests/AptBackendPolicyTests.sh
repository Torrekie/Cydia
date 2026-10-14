#!/bin/sh
# Build the C++ driver against the same native vendored APT used by the
# repository-security fixture, then run it with isolated package indexes.
set -e
PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
: "${APT_INTEGRATION_TESTS_BUILD_DIR:?native APT build directory is required}"
ACTION_DRIVER="$APT_INTEGRATION_TESTS_BUILD_DIR/cydia-package-actions"
python3 "$PROJECT_DIR/tests/BuildAptBackendPolicyTest.py"
ASAN_OPTIONS=detect_leaks=0 "$APT_INTEGRATION_TESTS_BUILD_DIR/cydia-native-launch-environment"
ASAN_OPTIONS=detect_leaks=0 "$APT_INTEGRATION_TESTS_BUILD_DIR/cydia-native-effect-policy"
"$APT_INTEGRATION_TESTS_BUILD_DIR/cydia-source-preflight" "$APT_INTEGRATION_TESTS_BUILD_DIR/methods"
ASAN_OPTIONS=detect_leaks=0 "$APT_INTEGRATION_TESTS_BUILD_DIR/cydia-package-archive-reader"
ASAN_OPTIONS=detect_leaks=0 "$APT_INTEGRATION_TESTS_BUILD_DIR/cydia-package-archive-decoder"
ASAN_OPTIONS=detect_leaks=0 "$APT_INTEGRATION_TESTS_BUILD_DIR/cydia-provider-binary-relationships"
ASAN_OPTIONS=detect_leaks=0 "$APT_INTEGRATION_TESTS_BUILD_DIR/cydia-provider-native-version-comparison"
"$APT_INTEGRATION_TESTS_BUILD_DIR/cydia-mmap-backing"
fakeroot "$APT_INTEGRATION_TESTS_BUILD_DIR/cydia-runtime-state"
# Run ordinary admission/codec cases and then the protected-registration and
# framed-probe cases under the existing fakeroot boundary.
"$APT_INTEGRATION_TESTS_BUILD_DIR/cydia-provider-selection"
fakeroot "$APT_INTEGRATION_TESTS_BUILD_DIR/cydia-provider-selection"
# gzip is already part of the native APT fixture environment. Its compressed
# index case must run, never silently skip an unavailable decoder.
command -v gzip >/dev/null
ASAN_OPTIONS=detect_leaks=0 "$APT_INTEGRATION_TESTS_BUILD_DIR/cydia-provider-archive-evidence"
"$APT_INTEGRATION_TESTS_BUILD_DIR/cydia-worker-progress"
ASAN_OPTIONS=detect_leaks=0 "$APT_INTEGRATION_TESTS_BUILD_DIR/cydia-recovery-plan"
ASAN_OPTIONS=detect_leaks=0 "$APT_INTEGRATION_TESTS_BUILD_DIR/cydia-recovery-backend"
"$APT_INTEGRATION_TESTS_BUILD_DIR/cydia-recovery-authority"
fakeroot "$APT_INTEGRATION_TESTS_BUILD_DIR/cydia-recovery-authority"
fakeroot "$APT_INTEGRATION_TESTS_BUILD_DIR/cydia-recovery-trust"
ASAN_OPTIONS=detect_leaks=0 "$APT_INTEGRATION_TESTS_BUILD_DIR/cydia-provider-trigger-evidence"
fakeroot "$APT_INTEGRATION_TESTS_BUILD_DIR/cydia-provider-trigger-capture"
fakeroot "$APT_INTEGRATION_TESTS_BUILD_DIR/cydia-provider-transaction-files"
fakeroot "$APT_INTEGRATION_TESTS_BUILD_DIR/cydia-provider-transaction-owner"
# The runner can have system dpkg shell loggers. Expose only this fixture's
# known config in a private mount namespace; leave host mounts and files intact.
# Restore the ordinary caller before fakeroot and retain the C++ config guard.
(
    conditional_uid=$(id -u)
    conditional_gid=$(id -g)
    if [ "$conditional_uid" -eq 0 ]; then
        echo "[conditional-native] requires an ordinary fakeroot caller" >&2
        exit 1
    fi
    for conditional_tool in sudo unshare mount setpriv fakeroot; do
        command -v "$conditional_tool" >/dev/null
    done
    conditional_config=$(mktemp -d "${TMPDIR:-/tmp}/cydia-native-dpkg-config.XXXXXXXX")
    trap 'rm -rf -- "$conditional_config"' 0
    trap 'exit 1' 1 2 15
    mkdir "$conditional_config/dpkg.cfg.d"
    printf '# Disposable Cydia native fixture configuration\nno-debsig\n' >"$conditional_config/dpkg.cfg"
    sudo -n unshare --mount --propagation private -- /bin/sh -eu -c '
        mount --bind "$1" /etc/dpkg
        mount -o remount,bind,ro /etc/dpkg
        exec setpriv --reuid "$2" --regid "$3" --clear-groups \
            --inh-caps=-all --ambient-caps=-all --bounding-set=-all \
            --no-new-privs fakeroot "$4"
    ' sh "$conditional_config" "$conditional_uid" "$conditional_gid" \
        "$APT_INTEGRATION_TESTS_BUILD_DIR/cydia-provider-conditional-owner"
)
ASAN_OPTIONS=detect_leaks=0 "$APT_INTEGRATION_TESTS_BUILD_DIR/cydia-provider-native-generation"
fakeroot "$APT_INTEGRATION_TESTS_BUILD_DIR/cydia-provider-unpack-admission"
fakeroot "$APT_INTEGRATION_TESTS_BUILD_DIR/cydia-provider-transaction-service"
fakeroot "$APT_INTEGRATION_TESTS_BUILD_DIR/cydia-provider-native-dpkg-authority"
"$APT_INTEGRATION_TESTS_BUILD_DIR/cydia-provider-broker-transaction"
ASAN_OPTIONS=detect_leaks=0 "$APT_INTEGRATION_TESTS_BUILD_DIR/cydia-provider-trigger-effects"
ASAN_OPTIONS=detect_leaks=0 "$APT_INTEGRATION_TESTS_BUILD_DIR/cydia-provider-primary-readiness"
ASAN_OPTIONS=detect_leaks=0 "$APT_INTEGRATION_TESTS_BUILD_DIR/cydia-provider-conditional-lifecycle"
fakeroot "$APT_INTEGRATION_TESTS_BUILD_DIR/cydia-provider-trigger-metadata"
fakeroot "$APT_INTEGRATION_TESTS_BUILD_DIR/cydia-provider-installed-scripts"
fakeroot "$APT_INTEGRATION_TESTS_BUILD_DIR/cydia-provider-installed-ownership"
ASAN_OPTIONS=detect_leaks=0 "$APT_INTEGRATION_TESTS_BUILD_DIR/cydia-provider-unpack-ownership"
ASAN_OPTIONS=detect_leaks=0 "$APT_INTEGRATION_TESTS_BUILD_DIR/cydia-provider-predepends-evidence"
ASAN_OPTIONS=detect_leaks=0 "$APT_INTEGRATION_TESTS_BUILD_DIR/cydia-provider-deconfiguration-approval"
ASAN_OPTIONS=detect_leaks=0 "$APT_INTEGRATION_TESTS_BUILD_DIR/cydia-provider-effect-review-bundle"
ASAN_OPTIONS=detect_leaks=0 "$APT_INTEGRATION_TESTS_BUILD_DIR/cydia-provider-transaction-begin"
ASAN_OPTIONS=detect_leaks=0 "$APT_INTEGRATION_TESTS_BUILD_DIR/cydia-provider-conditional-deconfiguration"
ASAN_OPTIONS=detect_leaks=0 "$APT_INTEGRATION_TESTS_BUILD_DIR/cydia-provider-restoration-debt"
fakeroot "$APT_INTEGRATION_TESTS_BUILD_DIR/cydia-provider-restoration-capture"
ASAN_OPTIONS=detect_leaks=0 "$APT_INTEGRATION_TESTS_BUILD_DIR/cydia-provider-deconfiguration-allowances"
fakeroot "$APT_INTEGRATION_TESTS_BUILD_DIR/cydia-provider-trigger-review-capture"
"$APT_INTEGRATION_TESTS_BUILD_DIR/cydia-recovery-dependencies"
ASAN_OPTIONS=detect_leaks=0 "$APT_INTEGRATION_TESTS_BUILD_DIR/cydia-recovery-worker"
TESTDIR="$PROJECT_DIR/apt64/test/integration"
TESTDIRECTORY="$TESTDIR"
. "$TESTDIR/framework"
setupenvironment
configarchitecture 'amd64' 'i386' 'armhf'
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
insertpackage 'unstable' 'foreign-only' 'i386' '1'
insertpackage 'unstable' 'mixed-layout' 'all' '1'
insertpackage 'unstable' 'mixed-layout' 'amd64' '2'
# APT must retain separate native/all version records even when Version agrees.
insertpackage 'unstable' 'same-version-layout' 'all' '1' 'Name: Same-version portable'
insertpackage 'unstable' 'same-version-layout' 'amd64' '1' 'Name: Same-version native'
insertinstalledpackage 'epoch-target' 'amd64' '1:1.0-1'
insertpackage 'unstable' 'epoch-target' 'amd64' '1:1.0-1'
insertpackage 'unstable' 'epoch-target' 'amd64' '1:9.0-1'
insertpackage 'unstable' 'epoch-target' 'amd64' '2:1.0-1'
insertpackage 'unstable' 'portable' 'all' '1'
insertpackage 'unstable' 'native-only' 'amd64' '1'
insertinstalledpackage 'transition' 'all' '1' 'Name: Portable transition'
insertpackage 'unstable' 'transition' 'all' '1' 'Name: Portable transition'
insertpackage 'unstable' 'transition' 'amd64' '2' 'Name: Native transition'
insertinstalledpackage 'portable-config' 'all' '1' 'Name: Old portable configuration' 'optional' 'deinstall ok config-files'
insertpackage 'unstable' 'portable-config' 'amd64' '2' 'Name: New native configuration\nIcon: https://fixture.invalid/portable-config.png\nDepiction: https://fixture.invalid/portable-config\nHomepage: https://fixture.invalid/\nSponsor: Fixture Sponsor <https://sponsor.invalid/>'
insertpackage 'unstable' 'coinstall' 'amd64' '1' 'Multi-Arch: same'
insertpackage 'unstable' 'coinstall' 'i386' '1' 'Multi-Arch: same'
insertinstalledpackage 'lockstep' 'amd64,i386' '1' 'Multi-Arch: same'
insertpackage 'unstable' 'lockstep' 'amd64,i386' '1' 'Multi-Arch: same'
insertpackage 'unstable' 'lockstep' 'amd64,i386' '2' 'Multi-Arch: same'
insertpackage 'unstable' 'allowed-runtime' 'i386' '1' 'Multi-Arch: allowed'
insertpackage 'unstable' 'foreign-runtime' 'i386' '1' 'Multi-Arch: foreign'
insertpackage 'unstable' 'qualified-consumer' 'amd64' '1' 'Depends: allowed-runtime:any, coinstall:i386, foreign-runtime, portable'
insertpackage 'unstable' 'unqualified-runtime-consumer' 'amd64' '1' 'Depends: native-only:any'
# Package version and provided ABI version are deliberately different. An
# unversioned or too-old Provides must not satisfy the versioned dependency.
insertpackage 'unstable' 'versioned-runtime' 'i386' '7' 'Multi-Arch: allowed\nProvides: fixture-api (= 2)'
insertpackage 'unstable' 'unversioned-runtime' 'i386' '99' 'Multi-Arch: allowed\nProvides: fixture-api'
insertpackage 'unstable' 'old-provided-runtime' 'i386' '99' 'Multi-Arch: allowed\nProvides: fixture-api (= 1)'
insertpackage 'unstable' 'versioned-consumer' 'amd64' '1' 'Depends: fixture-api:any (>= 2)'
insertpackage 'unstable' 'alternative-consumer' 'amd64' '1' 'Depends: missing-fixture-api:any (>= 2) | fixture-api:any (>= 2)'
insertpackage 'unstable' 'unsatisfied-versioned-consumer' 'amd64' '1' 'Depends: fixture-api:any (>= 3)'
insertpackage 'unstable' 'unsupported' 'armhf' '1'
insertpackage 'unstable' 'unsupported-consumer' 'amd64' '1' 'Depends: unsupported:armhf'
insertinstalledpackage 'unsupported-installed' 'armhf' '1'
insertpackage 'unstable' 'unsupported-installed' 'armhf' '1'
insertpackage 'unstable' 'unsupported-installed' 'armhf' '2'
insertinstalledpackage 'negative-installed' 'amd64' '1'
insertinstalledpackage 'negative-foreign' 'armhf' '1'
insertpackage 'unstable' 'negative-installed' 'amd64' '1'
insertpackage 'unstable' 'negative-foreign' 'armhf' '1'
insertpackage 'unstable' 'negative-only' 'amd64' '1'
insertpackage 'unstable' 'negative-consumer' 'amd64' '1' 'Depends: negative-only'
# Real archives exercise the complete transaction gate, including a dependency
# whose Architecture: all label does not make a rootless payload rooted-safe.
mkdir -p archive-build/archive-parent/DEBIAN archive-build/archive-parent/usr/share/archive-parent
mkdir -p archive-build/archive-layout-dependency/DEBIAN archive-build/archive-layout-dependency/var/jb/usr/share/archive-layout-dependency
mkdir -p archive-build/archive-authorized/DEBIAN archive-build/archive-authorized/usr/share/archive-authorized
mkdir -p aptarchive/pool/archive-policy
cat >archive-build/archive-parent/DEBIAN/control <<'EOF'
Package: archive-parent
Version: 1
Architecture: all
Maintainer: Fixture <fixture@example.invalid>
Depends: archive-layout-dependency
Tag: cydia::commercial
Description: Archive preflight parent
EOF
cat >archive-build/archive-parent/DEBIAN/postinst <<'EOF'
#!/bin/sh
exit 0
EOF
chmod 755 archive-build/archive-parent/DEBIAN/postinst
cat >archive-build/archive-layout-dependency/DEBIAN/control <<'EOF'
Package: archive-layout-dependency
Version: 1
Architecture: all
Maintainer: Fixture <fixture@example.invalid>
Description: Deliberately incompatible archive layout
Tag: cydia::commercial
EOF
cat >archive-build/archive-authorized/DEBIAN/control <<'EOF'
Package: archive-authorized
Version: 1
Architecture: all
Maintainer: Fixture <fixture@example.invalid>
Description: Authorized archive acquisition without dependencies or scripts
Tag: cydia::commercial
EOF
printf 'parent fixture\n' >archive-build/archive-parent/usr/share/archive-parent/payload
printf 'rootless fixture\n' >archive-build/archive-layout-dependency/var/jb/usr/share/archive-layout-dependency/payload
printf 'authorized fixture\n' >archive-build/archive-authorized/usr/share/archive-authorized/payload
for package in archive-parent archive-layout-dependency; do
    testsuccess dpkg-deb --root-owner-group -Zgzip --build "archive-build/$package" "aptarchive/pool/archive-policy/${package}_1_all.deb"
done
(cd aptarchive && aptftparchive packages pool/archive-policy) >>aptarchive/dists/unstable/main/binary-amd64/Packages
testsuccess dpkg-deb --root-owner-group -Zgzip --build archive-build/archive-authorized \
    aptarchive/pool/archive-policy/archive-authorized_1_all.deb
# APT resolves Filename relative to the source, including strings resembling
# absolute URLs. Give this package its own real network source and index;
# the private HTTPS method below serves authorized payloads without a network.
(cd aptarchive && aptftparchive packages pool/archive-policy/archive-authorized_1_all.deb) >authorized-Packages
export CYDIA_APT_PREFLIGHT_DPKG_MARKER="$TMPWORKINGDIRECTORY/dpkg-was-invoked"
export CYDIA_APT_PREFLIGHT_DPKG_SENTINEL="$TMPWORKINGDIRECTORY/rootdir/usr/bin/cydia-dpkg-sentinel"
cat >"$CYDIA_APT_PREFLIGHT_DPKG_SENTINEL" <<'EOF'
#!/bin/sh
: >"$CYDIA_APT_PREFLIGHT_DPKG_MARKER"
exit 97
EOF
chmod 755 "$CYDIA_APT_PREFLIGHT_DPKG_SENTINEL"
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

Package: negative-installed negative-foreign negative-only
Pin: version *
Pin-Priority: -1
EOF
setupaptarchive
printf 'deb [trusted=yes] https://authorized.invalid/ ./\n' >rootdir/etc/apt/sources.list.d/authorized.list
cp authorized-Packages rootdir/var/lib/apt/lists/authorized.invalid_._Packages
# The backend opens the archive lock before constructing acquire items. The
# application initializes this cache directory; the isolated fixture must too.
mkdir -p rootdir/var/cache/apt/archives/partial
# The HTTPS method fixture serves the real indexed bytes through APT's acquire
# protocol without network access. Remove the normal source payload: success
# must come from private staging and GetArchives recognizing the verified cache.
mkdir -m 700 authorized-fixture
export CYDIA_APT_AUTHORIZED_PAYLOAD="$TMPWORKINGDIRECTORY/authorized-fixture/payload.deb"
export CYDIA_APT_AUTHORIZED_MARKER="$TMPWORKINGDIRECTORY/authorized-fixture/acquisitions"
export CYDIA_APT_AUTHORIZED_CACHE="$TMPWORKINGDIRECTORY/rootdir/var/cache/apt/archives"
export CYDIA_APT_AUTHORIZED_METHOD="$TMPWORKINGDIRECTORY/authorized-fixture/https"
mv aptarchive/pool/archive-policy/archive-authorized_1_all.deb "$CYDIA_APT_AUTHORIZED_PAYLOAD"
cp "$PROJECT_DIR/tests/fixtures/authorized-https-method.py" "$CYDIA_APT_AUTHORIZED_METHOD"
chmod 700 "$CYDIA_APT_AUTHORIZED_METHOD"
# APT retains process-wide configuration allocations. Check invalid accesses in
# the frontend fixture without treating those library globals as fixture leaks.
ASAN_OPTIONS=detect_leaks=0 testsuccess runapt "$ACTION_DRIVER"
# APT's already-cached fast path must receive the same inspection. Remove the
# source archives so this second invocation can only use the cached payloads.
cp aptarchive/pool/archive-policy/*.deb rootdir/var/cache/apt/archives/
mv aptarchive/pool/archive-policy aptarchive/pool/archive-policy-saved
ASAN_OPTIONS=detect_leaks=0 testsuccess runapt "$ACTION_DRIVER" --cached-preflight
test ! -e "$CYDIA_APT_PREFLIGHT_DPKG_MARKER"
