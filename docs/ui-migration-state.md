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
- Current item: `P0.2 native Confirmation runtime and parity evidence`
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

The compatibility gate now inventories 92 remaining property/schema rows.
The retired `cydiaConfirm` and `cydiaProgress` globals and the Confirmation
object graph are absent; WebScript attributes, the remaining `cydia` global,
dynamic dictionary methods, and the legacy `CyteObject` wildcard key policy
remain explicit debt. This is inventory-only; caller authorization remains a
later typed-adapter gate.

The transaction data boundaries are now native and independently testable.
`CydiaConfirmationViewModel` owns an immutable, Foundation-only snapshot of
the five change groups, dependency reasons and clauses, exact byte counts,
multiarch routing identities, and essential-removal policy without WebScript
sentinels. `CydiaProgressViewModel` consumes the existing ordered
`ProgressDelegate` callbacks and publishes immutable UIKit-ready state while
preserving the cancellation tri-state, raw/clamped percentage values, event
order, terminal carriage-return behavior, and finish-action mapping. Both
transaction routes now use their native controllers.

The progress model also accepts late monotonic finish-action publications from
Database's status-fd reader on the main thread. This keeps the visible finish
title aligned with a late reload/reboot escalation while the close handler
continues to re-read the live value before executing the existing side effect.

Popup and pushed-window decisions now carry opaque caller metadata through the
legacy WebView boundary. The initiating committed frame origin is preferred
over a provisional destination, redirects and popups cannot promote caller
authority, and unknown web origins are explicitly untrusted. Enforcement is
still shadow-only: the private WebKit navigation-type gesture heuristic must
be validated on-device before P0.4 can switch routing decisions.

`ConfirmationController` is now a native grouped `UITableView` backed by the
typed transaction snapshot. It preserves the legacy Confirm/Cannot Comply
titles, Continue Queuing placement, statistics-before-modifications order,
operation ordering, blocking issue details, essential-removal alerts, and the
four distinct delegate outcomes. Its production path no longer creates a
WebView or waits for the first-party confirmation HTML. A simulator-only
initializer reaches the same production table/action implementation from a
deterministic snapshot. Installed visual, accessibility, restoration, alert,
and transaction evidence is still required before P0.2 can complete.

`ProgressController` is now a native title/status area, progress bar, and
self-sizing event table driven by the typed progress model. It preserves raw
status display, qualified package identities, cancellation state, external
status ordering, and late monotonic `Finish_` escalation before the existing
return/terminate/reload/reboot delegate effects. Warning, Error, and unknown
future event types remain explicit to sighted and VoiceOver users. The remote
page, `cydiaProgress` JavaScript bridge, and its hidden NetDragon install
telemetry are gone; that undisclosed network side effect was neither visible UI
nor transaction state and is intentionally not reproduced.

An installed iOS 12 simulator harness exercises the exact production Progress
controller with deterministic state. It passed live light-to-dark switching,
default and Accessibility Large typography, ordered/CR-normalized events,
multiarch identity, semantic warning/error colors, cancellation/finish chrome,
and completion accessibility. Four retained captures and state plists are at
`/tmp/cydia-ui-evidence/61ad729/progress/`. This is after-state evidence; legacy
before captures plus rooted/rootless transactions, cancellation/failure,
backgrounding, and interrupted-launch recovery remain required.

Passing evidence at this checkpoint:

- `make --no-print-directory -j6 verify`
- `make --no-print-directory -j6 verify-native-ui`
- `make --no-print-directory -j6 verify-static`
- `make --no-print-directory -B -j6 verify-confirmation-view-model`
- `make --no-print-directory -B -j6 verify-progress-view-model`
- `make --no-print-directory -j6 verify-progress-controller`
- `make --no-print-directory SIMULATOR_UDID=12B87D7E-664A-4BE2-85A3-E5FEADB3A0B7 verify-progress-simulator`
- targeted iPhoneOS compilation of `Database`, `ProgressViewModel`,
  `ProgressController`, and `MobileCydia`
- targeted iPhoneOS compilation of `UIRouteContext`,
  `Application+Navigation`, `MobileCydia`, `ConfirmationViewModel`,
  `ConfirmationController`, `ProgressViewModel`, `ProgressController`,
  `ProgressEventCell`, `ProgressControllerProbe`, and `ProgressData`
- x86_64 iOS 12 simulator compilation of `ConfirmationController` and its
  deterministic initializer fixture
- `git diff --check`

Still required before P0.1 can complete: the installed Confirmation transaction
probe and its retained evidence. Progress probe scaffolding and installed iOS 12
after-state evidence are complete. P0.2 additionally requires Confirmation
runtime parity, alert, restoration, and device transaction evidence; P0.3 still
requires legacy before captures and real transaction/cancellation/failure/
recovery evidence. Route-policy enforcement remains a separately revertible
P0.4 move.

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
  - [x] popup/new-window caller metadata in shadow mode
  - [x] native Confirmation simulator injection seam
  - [x] native Progress screenshot/probe scaffolding
  - [ ] native Confirmation screenshot/probe scaffolding
- [ ] P0.2: native Confirmation screen and offline transaction evidence
  - [x] native controller and deterministic action/table contracts
  - [ ] installed screenshots, accessibility, alerts, restoration, and device
    transaction evidence
- [ ] P0.3: native Progress screen and cancellation/failure evidence
  - [x] native controller, event cells, and deterministic contracts
  - [x] late `Finish_` escalation reaches native finish chrome
  - [x] installed iOS 12 after-state appearance/accessibility probe
  - [ ] legacy before-state, device transaction, cancellation/failure,
    background, and interrupted-launch evidence
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
| Confirmation | pending | compile passed | pending | pending | pending | contract passed | implementation complete; runtime pending |
| Progress | four native after captures; legacy before pending | installed deterministic probe passed | pending | pending | pending | model/controller contracts passed | implementation complete; real transaction/recovery evidence pending |
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
