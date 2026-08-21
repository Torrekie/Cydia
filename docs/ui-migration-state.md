# Native UI migration state

Copyright (C) 2026 Torrekie

SPDX-License-Identifier: GPL-3.0-or-later

This is the resumable checkpoint for the P0-P3 WebView-to-UIKit migration.
It is deliberately separate from implementation commits so a context resume
can distinguish planned work from shipped behavior.

## Checkpoint

- Baseline: `eac9b7433431514470443884594957533cb7a57c` (`fix/dpkg-version-upgrades`)
- Planning branch: `ui/native-migration-plan`
- Project rules: Makefile-only, ARC, arm64, iOS 12.0 minimum
- Current phase: `planning`
- Current item: `P0.1 shared contracts and probes`
- Implementation status: not started
- Last state update: 2026-08-22
- Product code changed by this checkpoint: no

## Invariants

- Do not replace an app-owned screen with WebKit. UIKit is mandatory for Home,
  Confirmation, Progress, package metadata, and all Cydia-owned chrome.
- The package depiction is the sole embedded-web exception: native top/details/
  footer layout plus an adaptive, origin-constrained depiction region.
- Preserve all documented `cydia://`, `apptapp://`, and legacy bridge contracts;
  route native callers directly and keep a typed compatibility adapter for
  remaining trusted HTML callers. The full mapping is in
  `docs/ui-migration-compatibility.md`.
- Keep native package actions, database delegates, progress status transitions,
  and rootful/rootless path behavior in their existing service boundaries.
- No Xcode project or additional build system.

## Phase checklist

- [ ] P0.1: shared view models, route/API inventory, screenshot fixture, and
  native confirmation/progress probe scaffolding
- [ ] P0.2: native Confirmation screen and offline transaction evidence
- [ ] P0.3: native Progress screen and cancellation/failure evidence
- [ ] P0.4: critical-flow bridge removal and P0 device/simulator gate
- [ ] P1.1: native package shell with adaptive depiction island
- [ ] P1.2: native Home dashboard
- [ ] P1 gate: package/Home route and appearance evidence
- [ ] P2.1: external routing and typed compatibility API; depiction remains the
  only WK adapter
- [ ] P2.2: native error state and AppCache removal
- [ ] P2 gate: no app-owned route depends on remote HTML
- [ ] P3: private WebKit deletion and final symbol/reference audit

## Acceptance ledger

| Surface | Before/after screenshots | iOS 12 | Current simulator | Rootful | Rootless | URL/API | Status |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Confirmation | pending | pending | pending | pending | pending | pending | not started |
| Progress | pending | pending | pending | pending | pending | pending | not started |
| Package shell | pending | pending | pending | pending | pending | pending | not started |
| Depiction island | pending | pending | pending | pending | pending | pending | not started |
| Home | pending | pending | pending | pending | pending | pending | not started |
| External routing/error | pending | pending | pending | pending | pending | pending | not started |

For every screenshot row, retain a matching accessibility-tree dump at default
and accessibility content sizes. The state cannot become `complete` while a
rollback criterion in the plan remains unresolved.

## Required evidence locations

Use a commit-specific directory outside the repository for binary evidence:

`/tmp/cydia-ui-evidence/<commit>/<surface>/<style>/`

Each surface directory must contain the route, fixture/database identity,
binary/package hash, screenshot pair, runtime log, and a short parity note.
Do not check simulator screenshots, installed packages, or crash reports into
the source tree.

## Resume procedure

1. Read this file and `docs/ui-migration-state.json`.
   Then read `docs/ui-migration-plan.md` and
   `docs/ui-migration-compatibility.md` before changing a route or bridge.
2. Confirm the checkout and baseline commit before editing.
3. Inspect the current phase's source and acceptance row; do not skip an
   unchecked predecessor phase.
4. Make one bounded implementation commit, run its narrow tests, then update
   this file and the JSON state in the same documentation commit or immediately
   after it.
5. Mark a phase complete only after runtime/screenshot evidence exists.
