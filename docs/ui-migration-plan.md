# Native UI migration plan

Copyright (C) 2026 Torrekie

SPDX-License-Identifier: GPL-3.0-or-later

This plan replaces Cydia's app-owned WebView screens with UIKit while keeping
the existing Makefile build, ARC, arm64 target, and iOS 12 deployment floor.
It is intentionally a staged plan: no screen is removed until its native
replacement, route compatibility, and runtime evidence are complete.

## Baseline contract

Every user-visible migration must preserve the following behavior unless a
change is called out in the acceptance record:

- The same navigation URL, deep-link destination, title, back behavior, and
  primary action remain available.
- The same transaction/package/source data is shown, including empty, loading,
  error, half-installed, and multi-architecture states.
- Localization keys, accessibility labels/traits, Dynamic Type behavior,
  light/dark appearance, pull-to-refresh, scrolling, and state restoration are
  retained where the old screen provided them.
- Native UIKit controls may use contemporary iOS 12+ spacing, semantic colors,
  alerts, sheets, and navigation bars. Legacy pinstripe styling is not a
  required pixel match, but information order and action affordances are.
- A migration is not complete on a compile result alone. It requires an
  installed simulator or device probe and before/after screenshots for the
  affected route.

The project remains Make-only. Do not add an Xcode project, Swift package,
Podfile, or a second build system.

The exact exposed-route and bridge-name contract is tracked in
`docs/ui-migration-compatibility.md`; this plan and that matrix must change
together when a compatibility decision changes.

## Web boundary and compatibility rules

UIKit is the implementation for every Cydia-owned screen. `WKWebView` is
allowed only for the package depiction body, which is intrinsically supplied
as arbitrary repository HTML; it must never be used as a replacement shell for
Home, Confirmation, Progress, package metadata, errors, or other Cydia-owned
chrome. Generic external pages leave Cydia through Safari Services or the
system URL handler instead of gaining a new in-app WebView surface.

The package detail exception is a native shell with one adaptive depiction
region:

```
native package header / icon / name / version / actions
native metadata, warnings, relations, and package information
adaptive depiction web region (optional, repository supplied HTML only)
native files / source / homepage / footer information
```

The depiction region is a constrained `WKWebView`, sized from its content and
contained in the native package scroll view. It must support long depictions,
images, links, and missing/failed content without changing the surrounding
layout. It receives no install, source, configuration, filesystem, or device
mutation API and no device identity headers. A depiction may request an
external link, which is routed through the existing URL policy.

Existing URL schemes and bridge entry points remain functional through a
compatibility router and an explicitly scoped legacy bridge:

The current `forExternal:` boolean is not sufficient as a security boundary.
Before removing the old browser, introduce a route capability enum (for
example `trustedNative`, `externalURL`, and `repositoryDepiction`) and pass it
through every navigation decision. A depiction may open a read-only package
route or an external link, but may not reach source mutation, package settings,
file browsing, app launching, arbitrary `file:` URLs, `javascript:` URLs, or
device APIs. This capability is part of the P0 security contract, not a UI
detail.

| Contract | Required behavior |
| --- | --- |
| `cydia://home`, `sources`, `sections`, `search`, `changes`, `installed` | Open the corresponding native controller. |
| `cydia://package/<id>` | Open the native package shell, preserving the qualified package identity. |
| `cydia://package/<id>/settings` and `/files` | Continue opening the existing native feature controllers. |
| `cydia://sections/<source>/<section>` and `apptapp://package/<id>` | Preserve parsing, percent escaping, and destination semantics. |
| `cydia://url/<encoded-url>` and unhandled external URLs | Preserve the route, but open through Safari Services or the system URL policy; reject `file:`, `javascript:`, unallowlisted custom schemes, and arbitrary device-local paths. Do not recreate a generic in-app WebView. |
| Existing JavaScript names (`getPackageById`, `getInstalledPackages`, `getAllSources`, metadata/session accessors, source refresh/add, `installPackages`, `du`, and navigation controls) | Keep callable for trusted legacy pages through a typed compatibility adapter. Native screens call model/delegate methods directly. Untrusted depictions receive only an allowlisted read-only subset. |

The native compatibility service must preserve every name and
success/failure/null convention from `CydiaObject`'s
`webScriptNameForSelector:` mapping. It is asynchronous where the old bridge
was asynchronous and rejects malformed arguments or disallowed origins.
During transition, the old WebScript adapter may call this service. After P3,
an origin-bound compatibility adapter remains available to explicitly trusted
first-party content, while ordinary repository depictions receive only the
allowlisted read-only subset. API and URL tests are part of every phase;
removing a legacy HTML caller is not permission to remove its public contract.

## P0: transaction safety and the platform boundary

### P0.1 Shared contracts and probes

Add small UIKit view-model interfaces around the existing transaction and
progress data. Add the route-capability parameter and a Make-driven static
allowlist gate before behavior changes. Keep the old controllers behind a
temporary route flag while the replacement is verified. Add probes for:

- confirmation groups, dependency reasons, download/resume sizes, essential
  removal, empty transactions, and localization;
- progress percent/status/event ordering, cancellation, failure, completion,
  SpringBoard/reboot outcomes, and background/foreground restoration;
- all URL routes and trusted bridge calls listed above.

This commit changes no production route and establishes the screenshot naming
and evidence directory convention under `/tmp/cydia-ui-evidence/<commit>/`.

### P0.2 Native confirmation

Replace the WebView body of `ConfirmationController` with a native table or
collection layout. Reuse the existing `Database::transactionData` conversion,
delegate callbacks, essential-package alert, and confirm/cancel actions. The
native screen must work with the network disabled and must never wait for a
remote HTML page before enabling a valid confirmation action.

Parity evidence: normal install, upgrade, downgrade, reinstall, removal,
dependency issue, essential-removal warning, empty transaction, light/dark,
iOS 12 fallback, and a restored modal state after backgrounding. Preserve the
legacy distinction between Cancel (clear the queued transaction) and Continue
Queuing (dismiss while retaining the queue); conflating them is a rollback
condition.

### P0.3 Native progress

Replace the remote progress page and `cydiaProgress` JavaScript updates with a
native title/status area, `UIProgressView`, event log, cancel control, and
finish/reload/reboot action. Reuse `CydiaProgressData`, `CydiaProgressEvent`,
and the existing database delegate. Keep the external status transitions and
termination behavior byte-for-byte at the delegate boundary.

Parity evidence: download, configure, install, cancellation, resolver error,
partial failure, completion, restart/reload/reboot result, long event text,
background/foreground, and a cold launch after an interrupted transaction.

### P0.4 Remove privileged bridge use from critical flows

Confirmation and Progress must no longer instantiate `CydiaObject` or depend
on `didClearWindowObject`. Keep the compatibility adapter available for other
legacy callers until P2, with origin checks and explicit request/response
schemas.

P0 exit gate: both transaction screens are native, offline-capable, route/API
compatible, and verified on iOS 12 simulator plus a rooted/rootless device
when a transaction-capable device is available.

P0 implementation commits remain independently revertible: shared route/probe
contracts, native Confirmation, native Progress, and critical bridge removal
are separate meaningful commits. Do not combine them with P1 screen work.

## P1: daily-use screens and depiction island

### P1.1 Native package detail shell

Create a native package detail controller using the existing `Package` model,
package action logic, package cells, files controller, settings controller,
and multi-architecture identity. Preserve the existing top information,
expanded content, and footer information order. Actions must continue to use
the existing delegate/confirmation flow rather than duplicating package
operations.

Add the depiction island only after the native shell works without it. The
native package controller owns one vertical scroll experience; the depiction
WebView has its own scrolling disabled and expands to the stabilized document
height so the user sees the former top-information, full depiction, and footer
sequence without a nested scroll view. Normal depiction content is never
truncated. A pathological or non-settling document fails into a native error
row with an explicit external-open action rather than hanging layout:

- load only the package's depiction URL after origin validation;
- constrain navigation, media, and redirects to the existing security policy;
- measure content height with a bounded message/KVO protocol and cap pathological
  heights;
- show a native placeholder/error row when the depiction is absent or fails;
- keep files, source, homepage, support, and footer controls native;
- never pass the legacy mutation bridge into repository depiction content.

Parity evidence: installed/uninstalled/upgradable/held packages, `all`, native
and foreign qualified identities, missing metadata, commercial/no-depiction,
short and very long depictions, iframe/image/link content, failed depiction,
rotation, Dynamic Type, light/dark, and package/settings/files deep links.

### P1.2 Native Home

Replace `HomeController`'s remote page with a native dashboard using local
database/source/status state. Preserve the About action, refresh/reachability
behavior, tab position, and `cydia://home` route. External guides and ordinary
web links go through the browser boundary, not through a privileged Cydia
bridge.

Parity evidence: first launch with empty/cache-loaded database, refresh online
and offline, source failure, reachability transition, About, external link,
light/dark, iOS 12 fallback, and state restoration.

P1 exit gate: package and Home routes are native; only the package depiction
region can create an embedded web view.

## P2: residual web content and failure states

### P2.1 External routing and compatibility bridge

Keep the P1 package depiction adapter as the sole public `WKWebView` surface.
Use `SFSafariViewController` or the system URL handler for external browsing;
do not create a generic in-app WebView controller. Replace the remaining
private frame/DOM/WebCore routing with native URL policy and the typed
compatibility service.

The Make/shell static allowlist gate introduced in P0 is tightened after the
depiction adapter lands. WebKit references are permitted only in the depiction
adapter and its fixture. The gate rejects new production references to
`UIWebView`, private
`WebFrame`/`WebPreferences`/`WAKView`/WebCore classes, `WebScriptObject`,
private WebThread locks, and `applicationCache`. Unrelated private services in
`iPhonePrivate.h` are audited separately instead of being removed by a broad
text match.

The adapter must preserve `cydia://url` routing, HTTP/HTTPS policy, mail/App
Store handling, and back navigation by returning those actions to the native
router. It must not expose package installation, source mutation,
configuration writes, or filesystem queries to arbitrary origins. Trusted
legacy pages may use the compatibility service while P0/P1 routes are retired,
and explicitly trusted first-party content can continue to use its documented
contract afterward. No new app-owned product screen may depend on that path.

The depiction request layer sends no `X-Cydia-Id`, `X-Cydia-Cf`, `X-Machine`,
installed-package inventory, or other device-identifying data unless a
separately documented first-party origin contract explicitly requires it.

### P2.2 Native error state and AppCache removal

Replace the bundled HTML error page with a reusable native retry/details view.
Once Home, Confirmation, Progress, and the package shell no longer depend on
the remote asset bundle, remove `AppCacheController`, foreground app-cache
reloads, WebFrame DOM helpers, and the old app-cache assets. Keep ordinary HTTP
cache behavior separate from HTML5 Application Cache.

P2 exit gate: no app-owned route requires a remote page or Application Cache;
depictions remain functional in the native shell; external URLs still open by
their documented policy; URL/API tests still pass.

## P3: delete legacy implementation

After a full link/reference audit, delete `CyteWebViewTableViewCell`, the
private `CyteWebView`/WebFrame/WebPreferences/WAK/WebCore stack, WebThread
helpers, private DOM appearance code, legacy `CydiaObject` injection paths, and
WebKit install-name rewriting that exists only for private symbols. Keep the
small WK adapter and the simulator depiction fixture if they still have
callers.

P3 exit gate:

- production objects contain no `UIWebView`, private WebKit class, WebCore
  thread-lock, or runtime private-WebKit hook symbols;
- the only production WebKit object is the package depiction adapter, and no
  depiction fixture can obtain the old privileged bridge or device headers;
- `make verify`, device/simulator links, rooted/rootless package inspection,
  and all route/API tests pass;
- screenshot probes show the accepted native parity matrix for every migrated
  route; any intentional visual difference is recorded with its reason.

## Evidence protocol

Each UI commit must include a state update and the narrowest relevant evidence:

1. Build with the existing Make graph for device and simulator, then install the
   exact binary or package under test.
2. Capture before/after screenshots at the same viewport, route, data fixture,
   interface style, and content size. Compare stable regions structurally
   (title, action, section order, row count, footer) and use pixel diffs only
   after masking status/navigation bars and documented modern-style changes.
3. Exercise the route through its public URL and, where applicable, the legacy
   API/bridge call. Record PID stability, crash logs, and state restoration.
4. For depictions, run a local fixture containing short/long text, images,
   iframe content, links, script attempts, and a failed load; verify adaptive
   height, footer reachability, origin restrictions, and absence of privileged
   messages.
5. For device evidence, retain the exact package hashes and a rollback pair;
   simulator evidence does not substitute for rootless transaction evidence.

Accessibility evidence accompanies screenshots: record an accessibility-tree
dump, verify logical focus order and button traits, and test default plus an
accessibility content-size category. Warnings and event severity must not be
communicated by color alone, and touch targets remain at least 44 points.

Automatic rollback criteria include a launch crash/watchdog, changed package
or transaction identity, missing/duplicated/out-of-order progress events,
incorrect essential-removal or finish actions, a depiction privilege escape,
an unbounded depiction height/hang, a route regression, inaccessible primary
actions, or a new network dependency in Confirmation/Progress. Intentional
iOS 12+ differences may include safe-area/grouped-table spacing, semantic color
values, modern alert/sheet presentation, and font wrapping; record them in the
parity note rather than silently ignoring them.

No phase may be marked complete from a source diff alone.

## Planned commit sequence

Each item is a separate meaningful commit unless a compile dependency makes a
smaller commit impossible:

1. `docs: define native UI migration contract` — this plan, compatibility
   matrix, and resumable state only.
2. `ui: add route capabilities and migration probes` — native caller-context
   router, route/API fixtures, static WebKit allowlist, screenshot harness; no
   production route switch.
3. `ui: add native transaction confirmation` — native view model/table and
   feature-flagged controller, preserving the delegate contract.
4. `ui: route confirmations through UIKit` — switch the production route only
   after simulator evidence; retain the old path for device rollback.
5. `ui: add native transaction progress` — native progress/event UI behind the
   same rollback mechanism.
6. `ui: route transaction progress through UIKit` — switch after simulator and
   harmless device evidence; remove transaction-page bridge use.
7. `ui: add native package detail shell` — header/metadata/footer/actions with
   no depiction dependency.
8. `ui: embed adaptive package depictions` — sole WK adapter, local hostile and
   long-content fixtures, no privileged headers/bridge.
9. `ui: route package details through native shell` — deep links, settings,
   files, multiarch identity, and device screenshots.
10. `ui: replace remote Home dashboard` — native Home and reachability/restore
    probes.
11. `ui: externalize generic web routes` — Safari/system routing and persistent
    typed legacy compatibility service; no generic WK controller.
12. `ui: replace HTML failures and remove AppCache` — native error state,
    hidden preload/lifecycle removal.
13. `web: retire private UIWebView stack` — delete legacy files/hooks, remove
    private link rewrites, tighten symbol/static gates, and update state to P3
    complete only after full evidence.

The P3 deletion commit may be split into dead-cell/AppCache, bridge support,
and private WebKit removals if its review grows too large. No commit mixes an
unrelated APT/dpkg/package-format change into the UI series.

## Proposed source and test layout

Keep modules focused and below the existing first-party source-size gate:

| Responsibility | Planned files |
| --- | --- |
| Caller-aware routing | `Cydia/UIRouteContext.h`, `Cydia/UIRouteContext.mm` |
| Legacy name/command compatibility | `Cydia/LegacyUICompatibility.h`, `Cydia/LegacyUICompatibility.mm` |
| Native confirmation data/UI | `Cydia/ConfirmationViewModel.h`, `.mm`, existing `ConfirmationController.h`, `.mm` |
| Native progress UI | existing `ProgressData`/`ProgressEvent`, `Cydia/ProgressEventCell.h`, `.mm`, existing `ProgressController.h`, `.mm` |
| Native package shell | `Cydia/PackageDetailViewModel.h`, `.mm`, `Cydia/PackageDetailController.h`, `.mm` |
| Sole web exception | `Cydia/PackageDepictionView.h`, `.mm` |
| Native Home | existing `HomeController.h`, `.mm`, plus focused native cell files only if needed |
| Native load failure | `Cydia/ErrorViewController.h`, `.mm` |
| Make-driven fixtures | `tests/UIRouteCompatibilityTests.mm`, `tests/ConfirmationViewModelTests.mm`, `tests/ProgressViewModelTests.mm`, `tests/PackageDetailViewModelTests.mm` |
| Runtime probes | `scripts/verify-native-ui-simulator.sh`, depiction fixtures under `tests/fixtures/depictions/` |

Names may be refined when implementation begins, but responsibilities must not
be collapsed into a new monolithic controller or compatibility file. New
Objective-C/Objective-C++ sources stay under the existing Make wildcard and
must not be included as implementation text from another source.

## P3 deletion inventory

Delete these only after reference, route, fixture, and clean-link gates prove
they have no remaining caller:

- `CyteKit/WebView.h`, `CyteKit/WebView.mm`;
- `CyteKit/WebViewController.h`, `CyteKit/WebViewController.mm`,
  `CyteKit/WebViewControllerPrivate.h`, and the Appearance, Navigation,
  WebDelegate, and Hooks implementation categories;
- `CyteKit/WebFrame+Cydia.h`, `CyteKit/WebFrame+Cydia.mm`,
  `CyteKit/WebThreadLocked.hpp`, and the private WebCore compatibility header;
- `CyteKit/WebViewTableViewCell.h`, `CyteKit/WebViewTableViewCell.mm`;
- `CyteKit/dispatchEvent.h`, `CyteKit/dispatchEvent.mm`,
  `CyteKit/webScriptObjectInContext.h`, `.mm`, and web-only enumeration helpers;
- `Cydia/CydiaWebViewController.h`, `.mm`, including `CydiaObject` and
  `AppCacheController`, after the typed service has replaced its contract;
- bundled `MobileCydia.app/error.html` and cache-manifest assets after native
  error/Home/package/transaction routes no longer reference them.

Before deletion, split web-private declarations from `iPhonePrivate.h` rather
than deleting unrelated SpringBoard/runtime declarations. Decouple user-agent
setup and `NSURL (CydiaSecure)` from the old controller if native sources or the
depiction adapter still require them. Remove the WebKit deprecation suppression
and private install-name rewriting only after the final clean link; retain the
public WebKit framework solely for `PackageDepictionView`.
