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
- Current item: `P0 device transaction, restoration, and route-authority evidence`
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
deterministic snapshot.

The calibrated Confirmation probe at commit `8f22e2d` uses the same normal and
blocking-issue fixtures as a retained rendering of the live legacy template and
its pinned Cytyle CSS. Installed iOS 12 and iOS 15.5 runs preserve the legacy
Queue, Statistics, Modifications, operation, and issue-detail hierarchy and
exact visible fixture values. They also pass light/dark changes, Accessibility
Large reflow, essential-removal alerts, all four delegate outcomes, qualified
multiarch identity, clipping checks, and a no-WebView assertion. The accepted
visual differences are native safe-area/navigation metrics, semantic colors,
dark appearance, and Dynamic Type reflow. Evidence and hashes are retained at
`/tmp/cydia-ui-evidence/8f22e2d/confirmation/`. This does not substitute for
rooted/rootless transaction, background, or restoration evidence.

`ProgressController` is now a compact native event stream with bottom status,
progress, and completion controls driven by the typed progress model. It
preserves raw status display, qualified package identities, cancellation state,
external status ordering, and late monotonic `Finish_` escalation before the
existing return/terminate/reload/reboot delegate effects. Warning, Error, and
unknown future event types remain explicit to sighted and VoiceOver users. The
remote page, `cydiaProgress` JavaScript bridge, and its hidden NetDragon install
telemetry are gone; that undisclosed network side effect was neither visible UI
nor transaction state and is intentionally not reproduced.

The calibrated Progress checkpoint at commit `2d465bf` uses the same ordered
fixture as a retained rendering of the live legacy progress template. Its
navigation title/actions, compact separator-free stream, bottom running status
and narrow progress indicator, and large bottom completion action preserve the
legacy hierarchy. Installed iOS 12 and iOS 15.5 probes pass light/dark changes,
default and Accessibility Large typography, five actual visible cells,
CR-normalized events, multiarch identity, semantic warning/error colors,
non-color event markers, completion accessibility, and a no-WebView assertion.
The accepted visual differences are semantic light appearance, Dynamic Type,
system navigation metrics, and an explicit raw label for unknown future event
kinds. The legacy inputs, native screenshots/state, exact version headers,
logs, and hashes are retained at
`/tmp/cydia-ui-evidence/2d465bf/progress/`. Rooted/rootless transactions,
cancellation/failure, backgrounding, and interrupted-launch recovery remain
required.

Exact rootful and rootless package candidates have also been built from
`b304ca7558e1238d9e7a98a923ca51a4a8f19a9a` without changing source or device
state. The rootful pair is retained under
`/private/tmp/cydia-rootful-b304ca7-build/packages/`: the Cydia archive is
`1:1.1.36+217.gb304ca7`, `iphoneos-arm`, SHA-256
`bea48e52408939ddeb13e59d28d19f5bab592e238e89c193fe11ea8967f18aad`, and
the matching translations archive is SHA-256
`bc0a72359286e2434c2a3aa96e04aee94d63d3ccb1fbe4b93e2c800451159cd7`.
The rootless pair is retained under
`/private/tmp/cydia-rootless-b304ca7.uqMG9Q/build/packages/`: the Cydia archive
is `1:1.1.36+217.gb304ca7`, `iphoneos-arm64`, SHA-256
`9613e0ccf007cd44094e27ef7641ce1298c623ba87b2a163807db3f8b8753e6f`, and
the matching translations archive is SHA-256
`ffd385e70435fdd6cc966fd8a1545321bfe03305c6192c1d60ea3193e0cffb0a`.
Both package verifiers pass. These archives are rollback-prepared inputs for
device testing; package construction is not rooted or rootless runtime proof.
The designated rootless device at `192.168.1.8` was unreachable, so no install
or dpkg state mutation was attempted.

Passing evidence at this checkpoint:

- `make --no-print-directory -j6 verify`
- `make --no-print-directory -j6 verify-native-ui`
- `make --no-print-directory -j6 verify-static`
- `make --no-print-directory -B -j6 verify-confirmation-view-model`
- `make --no-print-directory -B -j6 verify-progress-view-model`
- `make --no-print-directory -j6 verify-progress-controller verify-progress-view-model verify-native-ui verify-static`
- `make --no-print-directory -j6 verify-compile MobileCydia`
- `make --no-print-directory -j6 PACKAGE_LAYOUT=rootful BUILD_DIR=/private/tmp/cydia-rootful-b304ca7-build verify`
- `make --no-print-directory -j6 PACKAGE_LAYOUT=rootful BUILD_DIR=/private/tmp/cydia-rootful-b304ca7-build MobileCydia`
- `make --no-print-directory -j6 PACKAGE_LAYOUT=rootful BUILD_DIR=/private/tmp/cydia-rootful-b304ca7-build package`
- `scripts/verify-package-artifacts.sh rootful /private/tmp/cydia-rootful-b304ca7-build/packages`
- `make --no-print-directory -j6 PACKAGE_LAYOUT=rootless BUILD_DIR=/private/tmp/cydia-rootless-b304ca7.uqMG9Q/build package`
- `scripts/verify-package-artifacts.sh rootless /private/tmp/cydia-rootless-b304ca7.uqMG9Q/build/packages`
- `make --no-print-directory -j6 SIMULATOR_UDID=12B87D7E-664A-4BE2-85A3-E5FEADB3A0B7 BUILD_DIR=/private/tmp/cydia-progress-2d465bf-ios12 verify-progress-simulator`
- `make --no-print-directory -j6 SIMULATOR_UDID=EE995643-9E3B-4541-8698-FE42A5917DDF BUILD_DIR=/private/tmp/cydia-progress-2d465bf-ios15 verify-progress-simulator`
- `make --no-print-directory -j6 SIMULATOR_UDID=12B87D7E-664A-4BE2-85A3-E5FEADB3A0B7 BUILD_DIR=/private/tmp/cydia-confirmation-8f22e2d-ios12 verify-confirmation-simulator`
- `make --no-print-directory -j6 SIMULATOR_UDID=EE995643-9E3B-4541-8698-FE42A5917DDF BUILD_DIR=/private/tmp/cydia-confirmation-8f22e2d-current verify-confirmation-simulator`
- targeted iPhoneOS compilation of `Database`, `ProgressViewModel`,
  `ProgressController`, and `MobileCydia`
- targeted iPhoneOS compilation of `UIRouteContext`,
  `Application+Navigation`, `MobileCydia`, `ConfirmationViewModel`,
  `ConfirmationController`, `ProgressViewModel`, `ProgressController`,
  `ProgressEventCell`, `ProgressControllerProbe`, and `ProgressData`
- x86_64 iOS 12 simulator compilation of `ConfirmationController` and its
  deterministic initializer fixture
- `git diff --check`

P0.1 probe scaffolding and deterministic screenshot fixtures are complete.
P0.2 still requires Confirmation background/restoration and rooted/rootless
device transaction evidence; P0.3 still requires real
transaction/cancellation/failure/recovery evidence. Route-policy enforcement
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

- [x] P0.1: shared view models, route/API inventory, screenshot fixture, and
  native confirmation/progress probe scaffolding
  - [x] caller-capability shadow policy and route runtime fixture
  - [x] private-WebKit decreasing-debt gate and method-name inventory
  - [x] legacy property/global/schema inventory
  - [x] typed Confirmation and Progress view models
  - [x] popup/new-window caller metadata in shadow mode
  - [x] native Confirmation simulator injection seam
  - [x] native Progress screenshot/probe scaffolding
  - [x] native Confirmation screenshot/probe scaffolding
- [ ] P0.2: native Confirmation screen and offline transaction evidence
  - [x] native controller and deterministic action/table contracts
  - [x] matched legacy/native screenshots plus installed simulator
    accessibility and alert evidence
  - [ ] background/restoration and rooted/rootless device transaction evidence
- [ ] P0.3: native Progress screen and cancellation/failure evidence
  - [x] native controller, event cells, and deterministic contracts
  - [x] late `Finish_` escalation reaches native finish chrome
  - [x] matched legacy/native screenshots plus installed iOS 12 and iOS 15.5
    appearance/accessibility probes
  - [ ] device transaction, cancellation/failure, background, and
    interrupted-launch evidence
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
| Confirmation | matched legacy/native normal and issue captures plus dark, Dynamic Type, and alerts | installed probe passed | iOS 15.5 installed probe passed | pending | pending | route/action contracts passed | simulator parity passed; device transaction/restoration pending |
| Progress | matched legacy/native running and completion captures plus dark and Dynamic Type | installed deterministic probe passed | iOS 15.5 installed probe passed | pending | pending | model/controller contracts passed | simulator parity passed; real transaction/recovery evidence pending |
| Package shell | pending | pending | pending | pending | pending | pending | not started |
| Depiction island | pending | pending | pending | pending | pending | pending | not started |
| Home | pending | pending | pending | pending | pending | pending | not started |
| External routing/error | pending | pending | pending | pending | pending | pending | not started |

For every screenshot row, retain a matching accessibility-tree dump at default
and accessibility content sizes. The state cannot become `complete` while a
rollback criterion in the plan remains unresolved.

## Required evidence locations

Use a commit-specific directory outside the repository for binary evidence:

`/tmp/cydia-ui-evidence/<commit>/<surface>/<runtime>/`

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
