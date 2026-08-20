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
- State: implementation started; no behavioral fix committed yet.
- Device inspected read-only: `root@192.168.1.8`, Remorix dpkg 1.23.7,
  APT 2.9.4, native architecture `iphoneos-arm64`.

## Planned commits

- [ ] Seed APT architecture, dpkg paths/tables, and `DPkg::Path` before init.
- [ ] Add static exec-compat integration without dylib load commands.
- [ ] Resolve privileged BSD tools and harden root helper transactions.
- [ ] Generate correct rooted/rootless package triggers and dependencies.
- [ ] Diagnose planned dependency versions.
- [ ] Load SpringBoardServices explicitly and safely.
- [ ] Complete Make, package, artifact, and device verification.

## Confirmed runtime policy

- Do not set `DPKG_ROOT=/var/jb`; rootless archives already contain `/var/jb`.
- Rootless dpkg data tables are under `/var/jb/usr/share/dpkg`.
- Rootless dpkg state is available at `/var/jb/var/lib/dpkg` (a symlink to the
  configured administrative database).
- Rootless BSD `cp`, `ln`, and `rm` are under `/var/jb/bin`.
- Rootless file triggers use literal `/var/jb/...` paths.
- Installed librecompat does not interpose native `exec*` automatically; static
  consumers must opt into the libiosexec API at build time.

## Remaining risks

- Determine the exact static archive closure and license-compatible build path
  for libiosexec/librecompat before changing cydo linkage.
- Test canonical shebang execution through the statically integrated caller.
- Do not perform package installation or destructive dpkg transactions on the
  device without separate approval.
