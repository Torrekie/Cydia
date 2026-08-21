# Native UI migration state

Copyright (C) 2026 Torrekie

SPDX-License-Identifier: GPL-3.0-or-later

This is the resumable checkpoint for the P0-P3 WebView-to-UIKit migration.
It is deliberately separate from implementation commits so a context resume
can distinguish planned work from shipped behavior.

## Checkpoint

- Baseline: `3cf4a492f55a35013a6d5ddd30233bb1162e977c` (`origin/main`)
- Implementation branch: `ui/native-migration`
- Project rules: Makefile-only, ARC, arm64, iOS 12.0 minimum
- Current phase: `P0`
- Current item: `P0.1 native probe scaffolding and popup caller metadata`
- Implementation status: in progress
- Last state update: 2026-08-22
- Product code changed by this checkpoint: yes

## Latest meaningful move

The route-capability foundation is implemented in shadow mode.
`CydiaUIRouteContext` now
distinguishes trusted native, OS external, trusted legacy-page, and repository
depiction callers; authority cannot be upgraded by a redirect. The production
entry points construct this context, but the temporary private-WebView stack
still uses the legacy controller factory until saved-stack, popup, and runtime
parity evidence permits enforcement. Qualified package identities, opaque
source keys, and the documented `cydia://`/`apptapp://` routes have a
fixture-driven host runtime test.

A Make-driven gate now freezes the current private-WebKit debt per source file,
rejects public WebKit outside the future `PackageDepictionView`, and inventories
the existing script method names and route policy. This is a decreasing debt
baseline, not approval of the legacy implementation.

The compatibility gate also inventories 115 declared property/schema rows:
WebScript attributes, the three injected window globals, dynamic dictionary
methods, the Confirmation object graph, its default `queue` call, and the
legacy `CyteObject` wildcard key policy. This is inventory-only; caller
authorization remains a later typed-adapter gate.

The transaction data boundaries are now native and independently testable.
`CydiaConfirmationViewModel` owns an immutable, Foundation-only snapshot of
the five change groups, dependency reasons and clauses, exact byte counts,
multiarch routing identities, and essential-removal policy without WebScript
sentinels. `CydiaProgressViewModel` consumes the existing ordered
`ProgressDelegate` callbacks and publishes immutable UIKit-ready state while
preserving the temporary `cydiaProgress` adapter, cancellation tri-state,
raw/clamped percentage values, event order, and finish-action mapping. Neither
screen route has changed at this checkpoint.

The native Progress screen will intentionally omit the remote page's hidden
NetDragon install telemetry. That legacy network side effect is not transaction
state or visible UI, and must not be reproduced in the UIKit controller. It is
still present while the legacy progress route remains active.

Passing evidence at this checkpoint:

- `make --no-print-directory -j6 verify`
- `make --no-print-directory -j6 verify-native-ui`
- `make --no-print-directory -j6 verify-static`
- `make --no-print-directory -B -j6 verify-confirmation-view-model`
- `make --no-print-directory -B -j6 verify-progress-view-model`
- targeted iPhoneOS compilation of `UIRouteContext`,
  `Application+Navigation`, `MobileCydia`, `ConfirmationViewModel`,
  `ProgressViewModel`, `ProgressController`, and `ProgressData`
- `git diff --check`

Still required before P0.1 can complete: native screenshot/probe scaffolding,
popup caller metadata, and installed runtime evidence. Route-policy enforcement
remains a separately revertible P0.4 move.

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
  - [x] caller-capability shadow policy and route runtime fixture
  - [x] private-WebKit decreasing-debt gate and method-name inventory
  - [x] legacy property/global/schema inventory
  - [x] typed Confirmation and Progress view models
  - [ ] native screenshot/probe scaffolding
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
