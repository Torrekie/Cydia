# Multi-Arch and launch compatibility status

Copyright (C) 2026 Torrekie  
SPDX-License-Identifier: GPL-3.0-or-later

This file records the durable state of the architecture-identity and launch
compatibility goal. It is evidence and handoff state, not a replacement for
the Make verification targets.

## Baseline

- Branch base: `b684728` (`fix/bootstrap-runtime-compatibility`).
- Deployment policy remains ARC, arm64, and iOS 12.0 with Make only.
- Rootless verification target: `192.168.1.8`, iOS 15.1.1, Remorix dpkg
  1.23.7, native architecture `iphoneos-arm64`.
- The live dpkg database has no configured foreign architecture, but contains
  `Architecture: all` and hundreds of `Multi-Arch: same` packages.
- The live dpkg architecture database must not be modified by this goal.

## Launch blocker

The installed `1:1.1.36+177.gb684728` rootless package repeatedly trapped during
locale setup before APT initialization. Crash incident
`E98F7BEF-B495-46E8-A318-6C9A10B6FFE8` resolves to RegEx replacement formatting
for `%1$@%2$@`. `RegEx::operator->*` stored captured strings through
`__unsafe_unretained` pointers under ARC, allowing them to die before Foundation
formatted the result. Optional unmatched capture groups also produced a
negative ICU length that was converted to an unsigned size.

The exact rollback package is retained at:

`/private/tmp/cydia-final-rootless-packages.Fon7dA/cydia_1.1.36+177.gb684728_iphoneos-arm64.deb`

Its Cydia executable UUID is `F8C02EBB-A40F-3F54-96B8-FB2201BEF115`, matching
the installed crash report.

Three later first-launch failures were found only after that crash was removed:

- firmware maintenance exited 127 because `dirname` was unavailable before the
  helper had loaded the bootstrap PATH;
- repeated dpkg-record scans and per-character `sed` processes exceeded the
  20-second FrontBoard process-launch watchdog;
- persisted `CYString` values borrowed storage from a temporary APT snapshot,
  producing incident `61D6A43B-F769-493C-B919-A831502A2141` in
  `-[Package installed]` after database loading began.

Companion scripts now use shell path expansion, firmware ownership is indexed
once, capability names are normalized without subprocesses, and every Package
field retained beyond `PackageSnapshot` initialization is copied into its
Package pool. Static verification rejects new non-owning `snapshot` string
assignments.

## Planned checkpoints

1. Fix and test RegEx ARC capture ownership; prove the app reaches APT startup.
2. Remove only the `org.thebigboss.repo.icons` package dependency and verify
   built-in icon fallbacks. BigBoss repository-source policy is separate.
3. Introduce a Cydia-owned architecture-aware package identity.
4. Preserve instance identity through metadata, lists, routes, holds, and
   package operations.
5. Correct `Architecture: all`, dpkg query, relation, diagnostic, and progress
   behavior.
6. Add disposable multiarch fixtures; never add a foreign architecture to the
   live device database.
7. Build and inspect rooted/rootless packages, then perform rollback-safe
   rootless launch and database/UI smoke tests.

## Current state

- RegEx ARC ownership fix: implemented; the host lifetime regression test and
  arm64 device/x86_64 simulator object builds pass.
- BigBoss icons dependency removal: implemented and verified in rooted and
  rootless archives; Cydia's bundled `unknown.png` remains the fallback.
- Multi-Arch identity boundary and Objective-C model propagation: implemented.
  Native/all routes remain unqualified, foreign routes remain distinct, while
  package holds, maintainer-script repair, upgrade timestamps, and installed
  file queries use dpkg's non-ambiguous binary-package name. Installed file
  lists now come from the stable, shell-free `dpkg-query --listfiles` CLI;
  Cydia no longer opens dpkg's `.list` database files for that UI. Repository
  depiction/support lookups and identifier validation continue using the base
  package name.
- APT relation and confirmation data now retain foreign and `:any` route
  qualifiers. Versionless `:any` proxy links resolve to the preferred concrete
  package for navigation, `Architecture: all` Essential candidates are no
  longer hidden, and startup clears stale architecture-vector state around
  config loading so the selected dpkg remains authoritative for configured
  foreign architectures.
- Package-manager progress parsing now locates its numeric percent field rather
  than treating every colon as a delimiter. Qualified `Multi-Arch: same`,
  foreign, and `:any` package names therefore remain attached to status and
  error events, including messages that themselves contain colons.
- `make verify-multiarch-fixture` loads disposable package and progress stanzas
  covering native `iphoneos-arm64`, `Architecture: all`, native/foreign
  coinstallable `Multi-Arch: same`, `foreign`, `allowed`, `:any`, a versionless
  proxy route, and qualified status/error records. The APT runtime fixture also
  proves stale apt.conf vectors are discarded before selected-dpkg native and
  foreign discovery. No device dpkg architecture state is changed.
- Rooted and rootless artifact verification passes for `iphoneos-arm` and
  `iphoneos-arm64`. Both packages retain iOS 12.0, ARC, epoch `1`, bundled icon
  fallbacks, and no `org.thebigboss.repo.icons` dependency.
- Rootless package `1:1.1.36+190.gf5194a6` was hash-checked, installed with its
  matching `cydia-lproj`, and launched on the recorded Remorix device. PID
  `1089` remained unchanged through a 35-second home launch and subsequent
  architecture-aware routes for `bash-builtins:iphoneos-arm64`,
  `ncurses-base` (`Architecture: all`), and the cached foreign record
  `com.mpg13.flashback:iphoneos-arm`. No crash report newer than the expected
  pre-fix incident appeared.
- The cold first launch completed firmware reconciliation in about 10 seconds,
  wrote schema version 6, preserved 277 externally owned virtual packages, and
  recorded only three newly generated Cydia-owned `gsc.*` packages. The live
  dpkg foreign-architecture configuration remained untouched.

## Remaining observations

- Repository refresh on the test device still reports legacy runtime issues
  unrelated to package identity: embedded APT invokes rootful
  `/usr/bin/apt-key`, `lzma` compressor lookup fails, and one configured source
  currently returns HTTP 403. Old indexes allowed route validation, but these
  errors need a separate APT-method/tool-path follow-up before claiming a clean
  online refresh.
- No package install/remove transaction was initiated from the Cydia UI during
  this goal. Resolver, relation, progress, and dpkg-identity behavior are
  covered by disposable fixtures and compile checks; a future harmless device
  transaction should retain its own rollback plan.
