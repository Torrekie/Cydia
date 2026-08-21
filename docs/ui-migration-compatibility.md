# Native UI compatibility matrix

Copyright (C) 2026 Torrekie

SPDX-License-Identifier: GPL-3.0-or-later

This file is the compatibility contract for replacing Cydia-owned WebView UI
with UIKit. It records public routes, legacy script names, caller authority,
and the test required before an old implementation can be removed.

## Caller capabilities

Replace the ambiguous `forExternal:` Boolean with an explicit caller context:

- `trustedNative`: Cydia's controllers, restored navigation stack, and local
  user actions;
- `externalURL`: an OS-delivered deep link or external application;
- `trustedLegacyPage`: a specifically allowlisted first-party compatibility
  page during migration;
- `repositoryDepiction`: arbitrary repository-supplied depiction HTML.

The context is immutable for one navigation decision and cannot be upgraded by
a redirect, subframe, popup, JavaScript call, or `addBridgedHost`. Compatibility
means retaining intended behavior for an authorized caller; it does not grant
an internal command to a depiction or external application.

## URL routes

| Route | Native target | Allowed caller | Compatibility test |
| --- | --- | --- | --- |
| `cydia://home` | native Home controller | trusted native; OS launch preserves existing start-URL policy | cold/warm route opens Home and round-trips its navigation URL |
| `cydia://sources` | existing Sources controller | trusted native | restored stack opens same controller |
| `cydia://sources/add` | Sources controller plus add-source prompt | trusted native; external only as an explicit user-confirmed prompt | cancel mutates nothing; confirm validates and adds once |
| `cydia://sources/<key>` | existing source Sections controller | trusted native; external read-only after key validation | valid key opens; unknown key fails safely |
| `cydia://sections`, `sections/<section>`, `sections/<source>/<section>` | existing Sections/Section controllers | trusted native/restored stack | wildcard, escaped source, and escaped section restore correctly |
| `cydia://search` and `search/<query>` | existing Search controller | trusted native/restored stack | query escaping and controller state round-trip |
| `cydia://changes` | existing Changes controller | trusted native/restored stack | route opens Changes with no database mutation |
| `cydia://installed` | existing Installed controller | trusted native/restored stack | route opens Installed with original mode |
| `cydia://package/<identity>` | native package detail shell | trusted native, external URL, depiction read-only link | cold/warm route preserves qualified multi-arch identity; unknown identity is safe |
| `apptapp://package/<identity>` | alias of native package detail | same parser behavior as today | alias and `cydia://package` resolve the same package |
| `cydia://package/<identity>/settings` | existing Package Settings controller | trusted native/restored stack | external and depiction callers are rejected |
| `cydia://package/<identity>/files` | existing File Table | trusted native/restored stack | qualified package identity and files remain correct |
| `cydia://launch/<bundle-id>` | existing native application-launch command | trusted native only | external, legacy-page, and depiction attempts are rejected |
| `cydia://url/<encoded-url>` | Safari Services/system URL policy | trusted native or external URL after validation | HTTPS/mail/App Store work; `file:`, `javascript:`, paths, and unsafe custom schemes fail |

The app currently registers only the `cydia` scheme. `apptapp` remains a
parser-level compatibility alias unless a separately reviewed change registers
it in the bundle.

## Depiction resource URLs

The old URL protocol serves `cydia://application-icon`, `package-icon`,
`uikit-image`, and `section-icon`. Preserve only resources required by
repository depictions through a typed, allowlisted resolver. Identifiers are
data, never filesystem paths. Unknown commands, traversal, encoded separators,
and oversized images fail closed. Once native package/Home/error UI stops using
these resources, tests determine which compatibility commands still have a
real depiction caller.

## Legacy bridge names

All names in `CydiaObject` and inherited `CyteObject` remain represented in the
compatibility service. The implementation is separated from WebKit so native
controllers and a temporary trusted-page adapter use the same policy.

### Read-only package/rendering APIs

These keep their existing names and null/error conventions for an authorized
first-party compatibility page. A depiction receives only fields for the
package currently displayed and no global installed-package inventory.

- `getPackageById`, `getAllSources`, `getInstalledPackages`,
  `substitutePackageNames`;
- `getMetadataKeys`, `getMetadataValue`, `getSessionValue`;
- `getLocaleIdentifier`, `getPreferredLanguages`, `localize`, `format`,
  `supports`, and allowlisted `isReachable`;
- package, source, relation, and MIME-address read-only properties required to
  render a depiction.

Tests cover the original JavaScript name, argument conversion, asynchronous
completion, `nil`/undefined/null behavior, localized data, unsupported package
identity, and multi-architecture identity. Repository depictions cannot query
the complete installed package/source/application inventory.

### Mutating package/source/configuration APIs

Keep the names `addSource`, `addTrivialSource`, `refreshSources`, `saveConfig`,
`installPackages`, package `install`/`remove`/`clear`, and source mutation. Their
implementation becomes a typed native command sent through `CydiaDelegate` and
the existing Confirmation/Progress flow.

- A trusted first-party compatibility page may request a command.
- The command never mutates immediately; Cydia presents the native validation,
  confirmation, or progress UI.
- A repository depiction cannot request it.
- Cancel has no side effect; acceptance dispatches the command exactly once.

Tests assert the command name remains callable, validation and user consent
occur, cancel is a no-op, and accepted work targets the correct qualified
package/source through the existing serialized operation path.

### Session, chrome, and navigation APIs

Keep `setSessionValue`, `addInternalRedirect`, `close`, `popViewController`,
`setAllowsNavigationAction`, `setBadgeValue`, `setButtonImage`,
`setButtonTitle`, `setHidesBackButton`, `setHidesNavigationBar`,
`setNavigationBarStyle`, `setNavigationBarTintColor`, scrolling/viewport
methods, `registerFrame`, and `unload` in the trusted first-party compatibility
adapter. Native screens implement the equivalent behavior directly and do not
depend on this adapter.

The depiction island receives none of these. External-link requests return to
the native router. Clipboard setters require a user gesture/confirmation. The
compatibility tests verify each legacy name while also proving a depiction
cannot alter Cydia chrome, register frames, redirect internal routes, or write
the clipboard silently.

### Sensitive device/filesystem APIs

Keep the legacy names and behavior (`du`, `statfs`, IORegistry/kernel queries,
application inventory/info, device/cell/operator identifiers, metadata writes,
host trust expansion, and `setToken`) for explicitly trusted first-party
compatibility content and the equivalent native diagnostic capability. Calls
from repository depictions, external URLs, and untrusted subframes receive the
same defined denied/unavailable result rather than an accidental selector
crash. Trust expansion is scoped to the authorized compatibility session and
cannot grant capabilities to an ordinary depiction.

No depiction request receives `X-Cydia-Id`, `X-Cydia-Cf`, `X-Machine`, a UDID,
serial/ECID/baseband data, filesystem results, installed-app inventory, or a
way to add a bridged/insecure host. Tests cover main-frame, subframe, popup,
redirect, and external-URL attempts.

## Transaction page contracts

`cydiaConfirm` and `cydiaProgress` are not public depiction APIs. Their data
and actions move into native view models while retaining their internal
semantics:

- Confirmation preserves installs/reinstalls/upgrades/downgrades/removes,
  dependency clauses, sizes, Confirm, Cancel-and-clear, Continue-Queuing, and
  essential-removal handling.
- Progress preserves title/status/percent/current/total/speed, ordered events,
  cancellation, Finish outcomes, external status transitions, and delegate
  side effects.

During the route-flag comparison period, the compatibility adapter can still
populate the old pages. It is deleted only after native runtime evidence is
accepted.

## Final contract gate

The final Make-driven compatibility target must:

1. enumerate every route and legacy bridge name from the source mapping;
2. fail if a name disappears without an explicit compatibility implementation;
3. exercise allowed and denied caller contexts;
4. prove depictions receive no mutation/device/header capability;
5. round-trip canonical navigation URLs and qualified package identities;
6. run before the P3 private-WebKit deletion is accepted.
