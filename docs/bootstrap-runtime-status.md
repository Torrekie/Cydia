# Bootstrap Runtime Compatibility Status

This file is the durable implementation checkpoint for the rooted/rootless
bootstrap review follow-up. Update it after every meaningful commit so work can
resume safely after context compaction.

## Goal

- Initialize embedded APT from the selected rooted or rootless package layout.
- Preserve canonical script shebangs; use libiosexec/librecompat only through a
  verified static integration, with no runtime dylib dependency.
- Prefer bootstrap BSD tools. GNU coreutils/findutils remain explicitly `g*`.
- Preserve cydo's direct-parent authorization boundary.
- Keep the Make-only, ARC, iOS 12, rooted, and rootless acceptance gates.

## Current checkpoint

- Branch: `fix/bootstrap-runtime-compatibility`
- Base: `77caf89` (`identity/cydia-refurbished`)
- State: implementation and host/artifact verification are complete. A later
  rollback-protected multiarch validation installed a rootless Cydia candidate
  and exercised the authorized Cydia-to-cydo helper path; see
  `docs/multiarch-launch-status.md`.
- Device inspected read-only: `root@192.168.1.8`, Remorix dpkg 1.23.7,
  APT 2.9.4, native architecture `iphoneos-arm64`.

## Planned commits

- [x] Seed APT architecture, dpkg paths/tables, and `DPkg::Path` before init.
- [x] Add static exec-compat integration without dylib load commands.
- [x] Make root firmware and AutoInstall helper transactions failure-safe.
- [x] Resolve privileged BSD tools used directly by the application.
- [x] Generate correct rooted/rootless package triggers and dependencies.
- [x] Diagnose planned dependency versions.
- [x] Load SpringBoardServices explicitly and safely.
- [x] Complete Make, package, artifact, simulator, and read-only device
  verification.

## Confirmed runtime policy

- Do not set `DPKG_ROOT=/var/jb`; rootless archives already contain `/var/jb`.
- Rootless dpkg data tables are under `/var/jb/usr/share/dpkg`.
- Rootless dpkg state is available at `/var/jb/var/lib/dpkg` (a symlink to the
  configured administrative database).
- Rootless BSD `cp`, `ln`, and `rm` are under `/var/jb/bin`.
- Rootless file triggers use literal `/var/jb/...` paths.
- APT and maintainer-script search paths put bootstrap BSD `/bin` before
  `/usr/bin`; GNU coreutils/findutils remain explicitly `g*` commands.
- Canonical helper shebangs remain unchanged. `cydo` opts into the statically
  embedded libiosexec API, which performs the Remorix `/var/jb` interpreter
  redirect without a compatibility dylib or added rpath.
- The static archive is pinned to libiosexec commit
  `9953dfb10a92415301dbb9cf2f79e4a01591c708` and contains only `execv.c`,
  `get_new_argv.c`, and `utils.c`. Librecompat is not linked.
- Firmware pseudo-package cleanup is ownership-scoped. Cydia records generated
  package names and an ownership marker, and never purges unrelated Procursus
  or Remorix `firmware`, `gsc.*`, or `cy+*` packages.

## Verification completed

- `make --no-print-directory -j6 verify`
- `make --no-print-directory -j6 PACKAGE_LAYOUT=rootless verify`
- Rootful and rootless `build/bin/MobileCydia` links.
- An x86_64 iOS Simulator `MobileCydia` link with deployment target 12.0.
- `make --no-print-directory verify-bootstrap-helpers`
- `/bin/bash -n Library/package-paths.sh Library/startup Library/firmware.sh`
- Rooted `iphoneos-arm` and rootless `iphoneos-arm64` package builds, followed
  by `scripts/verify-package-artifacts.sh` for each layout.
- Both extracted package copies of `cydo` pass
  `scripts/verify-exec-compat.sh binary`: embedded `_ie_execv` and
  `_ie_execve`, no unresolved `_ie_*`, no libiosexec/librecompat load command,
  no `LC_RPATH`, and minimum iOS 12.0.
- Package controls carry epoch `1`, `Cydia Refurbished`, Torrekie as
  Maintainer, and Jay Freeman as Author; `cydia-lproj` retains
  `Cydia Translations`.
- Read-only device inspection confirmed Remorix's dpkg/APT architecture and
  paths, Essential Bash/librecompat packages, BSD tool locations, and the
  installed dpkg's own statically embedded libiosexec symbols.
- A subsequent rootless cold launch proved the canonical `#!/bin/bash` firmware
  helper executes through cydo's static libiosexec integration, completes its
  ownership-scoped reconciliation, and preserves bootstrap-owned virtual
  packages.

## Remaining risks

- The embedded APT source remains the inherited, reproducible but
  `legacy-unverified` fork. Its separate compatibility/update policy and canary
  lane remain required before changing the pin.
- Repository refresh still exposes separate rootless APT tool-path failures
  (`apt-key` and `lzma`); those are recorded for a follow-up and are not covered
  by the successful helper execution proof.
