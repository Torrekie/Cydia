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

The installed `1:1.1.36+177.gb684728` rootless package repeatedly traps during
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
- Multi-Arch identity boundary: implemented with separate route, APT, and dpkg
  names; Objective-C model/operation propagation is pending.
- Rooted/rootless artifacts: pending.
- Updated real-device launch proof: pending.
