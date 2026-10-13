# Runtime providers and distribution policy

## Scope and implementation status

Cydia is an optional graphical frontend for the selected distribution's APT
and dpkg environment. Installed, working, supported distribution components
take precedence over Cydia's private recovery components. Installing or
removing Cydia must not replace those components, their configuration, sources,
keyrings, or package database. No distribution is identified from a repository
hostname or assumed to be the default. The package ID remains `cydia`;
legacy package-owned file migrations remain maintscript responsibilities.

Application startup now uses the runtime coordinator. Automatic mode reads
protected provider registrations, validates their components and configuration,
probes the declared adapter, and starts a bound worker session before adopting
its immutable runtime descriptor. A working, compatible registered provider
takes precedence. If none can be selected, the coordinator initializes bundled
APT and explains the fallback. An ordinary installed `apt`, `apt-get` or libapt
package is not a provider registration or a protocol adapter.

The Cydia side includes the remote facade, source-check routing, native progress
and cancellation bridge, Settings controls, immutable confirmation and a
privileged parent executor. A reusable bounded server dispatcher is available
for adapters; it requires independently supplied admission, acquisition,
review and parent-execution hooks and does not itself implement a distribution
adapter. Progress carries source activity separately from display diagnostics,
so source spinners can follow a worker without exposing transport credentials.
There is no completed Remorix adapter or production end-to-end acceptance claim.
APT 2.7.9 remains statically linked into the application, privileged helper and
private recovery worker. The worker is built without UIKit or optional
bootstrap libraries. Automatic selection can use it after the helper captures
a protected payload inventory, inspects its dependencies, and the worker
completes a bound probe/session handshake. dpkg remains external.
The private signature/helper payload is not supplied in this repository, so
the current package cannot establish complete worker readiness on its own.
Automatic startup retains the existing in-process backend as a transitional
fallback. Candidate source loading, cache opening and a fresh protected authority
check finish before adoption; a failed worker selection preserves the working
backend and does not save the attempted preference.

Source loading and cache preparation failures remain operation failures while
the validated worker session is alive. They do not label the provider broken
or select recovery. A failed Settings check preserves the adopted backend,
queue, package handles and confirmation; invalidation occurs only at successful
adoption. Cold-start preparation failure reports that no runtime was adopted.
Automatic recovery retains its reason for fallback, and native confirmation
binds the actual runtime origin so private recovery workers show the existing
localized recovery-policy notice.

Recovery preparation includes a nonexecuting libapt package-manager recorder
and a helper-owned authority capture module. The recorder preserves explicit
operation ordering and exact archive/index identities; it refuses configured
hooks, external planners, pending global effects and unmodeled crossgrades.
The native backend binds those identities to libapt's actual archive selection.
Review does not download archives or alter existing final/partial cache files,
and ambiguous source records cannot silently select the first matching origin.
Its result is input to independent parent review, never execution authority.
Default smart configuration is expanded through libapt's exact configure
callbacks rather than copied into an unbounded dpkg configure-pending command.
Authority capture fingerprints protected configuration, components and methods,
and requires an independent dependency/loadability inspection before it can
report a usable recovery environment. The parent derives an immutable launch
capsule from that authority. Private acquisition tools and parent archive
decoders use their own search path; parent dpkg execution keeps the selected
distribution's path. Cache
reloads retain refresh trust only while the independently fingerprinted
sources, keys and indexes remain unchanged. The worker executes packages only
through reviewed parent RPCs.

Runtime getters resolve the adopted descriptor. Embedded mutation setters
refuse while it is active, and resetting it requires fresh embedded
initialization. Trust and transaction snapshots include the provider identity;
changing providers invalidates cache handles and prepared confirmation. An
absent repository-security preference remains distinct from a saved Warning
choice: absence means distribution policy for an accepted external provider
and the existing Warning default for recovery.

Native confirmation owns the exact package operations and archive identities.
The parent independently proves source/index provenance and verifies downloaded
archive contents before its existing authenticated helper stages and rechecks
them for dpkg. A provider token or a successful worker reply alone cannot
authorize execution or establish completion. Explicit processing of the complete
current pending-trigger set includes independently derived waiter transitions.
Package-state snapshots also fingerprint native trigger-directory membership,
registries and deferred-journal bytes. A bounded read holds the existing native
trigger lock when present; it never creates or rewrites trigger files.
The authenticated app can open one persistent transaction in the existing
`cydo` helper. It independently verifies and retains every reviewed archive
before the first mutation, binds application generation and frontend-lock
inode, and owns child execution and final automatic-package-state commit.
Approved unpack generations may replace declared native executables and
dependencies only when their installed bytes and metadata match the retained
payload. Protected native configuration and actual Mach-O dependency closure
are checked before every native tool launch. Later batches use retained proof;
they do not renew mutable source/index authority after a maintainer script.

Retained native queries and primary/trigger children use one owned, immutable
environment snapshot. It binds the selected distribution search path, converted
locale values and frontend-lock marker into local configuration and approval
identities. An explicit empty environment remains empty; invalid snapshots
refuse launch instead of using ambient process values. The parent rechecks the
snapshot and passes those exact bytes to each child. Legacy one-shot calls keep
their existing environment handling. Native argument binding removes only
validated path options from the option phase and supplies root before the
selected admin directory, so a later root option cannot reset a custom database.
Opaque option values and operands retain their original bytes and order.

This path requires a complete protected native dpkg declaration, described
below. Its absence retains the existing restricted executor before any mutation;
an invalid declaration or failed retained transaction cannot fall through.
The restricted path still invalidates authority on component/configuration
replacement. Protocol v3 optionally negotiates finite trigger effects after
the native declaration and loader checks pass. Native preparation captures a
bounded recipient/awaiter pool before downloading archives. The immutable
confirmation lists exact versions and architectures in a collapsible processing
section, and binds native configuration, platform and component generations.
The helper reconstructs that approval after reacquiring the frontend lock,
refines incoming relationships from verified archive controls, and derives
fresh bounded drain passes between the reviewed primary operations. Every
primary and drain child obtains, settles and releases its own configuration
input/status scope. Internal passes consume neither primary action IDs nor
outer request sequence numbers. Cancellation stops at child boundaries;
an actual child always settles before its scope closes.

The recovery worker keeps exact selected-record Pre-Depends batching hints and
starts a new unpack child before each later archive that declares them. The
finite parent independently checks the corresponding boundary from verified
archive controls and authorized operand order, which can differ from sorted
action IDs. Ordinary homogeneous batches remain available. These boundaries
permit fresh checkpoints; they do not establish native dependency readiness or
authorize inline processing, implicit removal, or deconfiguration.

Support alone does not select this mode. Legacy capture still refuses an
unresolved deferred journal and retains its explicit complete trigger batches.
An approved finite-effects transaction cannot downgrade to the legacy executor.
Trigger-only transactions without primary operations remain unsupported.
Conditional deconfiguration requires a supported protected native policy record,
an immutable paired approval and the bounded per-child route described below.

The Cydia library retains native installed `Config-Version` and raw disk status
separately from the read-only query view, and can capture protected `prerm` and
`postinst` generations for an independently selected package subset. Incoming
control inspection preserves exact script presence, bytes and tar metadata.
Bounded binary relationship parsing distinguishes dpkg's unpack and configure
checks, including actual architectures and versioned virtual providers. Native
version-comparison adapter uses a frozen parent-owned dpkg callback and exact
exit codes. Protected deconfiguration review capture connects it to the selected
native dpkg, checking the complete configuration, loader, environment and package
state around queries and cached comparisons. Localized
diagnostics never determine execution policy. The initial-generation
allowance builder binds prospective Breaks/sibling causes to exact reviewed
restoration endpoints. Batch index-control capture binds each exact reviewed
record to retained source/index provenance before download. Protected ownership
capture retains native file lists and diversions, including configuration-only
owners, without inferring filesystem types or permission to replace files.
The native Pre-Depends evaluator keeps current and last configured versions,
virtual providers, incoming self dependencies and same-child deconfiguration
queues distinct. These library facts are not an execution route: automatic
deconfiguration requires immutable native approval, locked reconstruction,
complete per-batch effect admission and restoration-aware settlement. The
transaction owner contains those conditional gates, including exact primary
dependency checks and restoration-aware trigger scheduling. A protected startup
marker selects review capture only for the current native executor and supported
Unpack profile; it cannot authorize execution. An empty allowance pool retains
ordinary finite-trigger execution and batching.

Control capture also retains the original record and native dependency-field
order. Index records, archive controls and installed status each keep their own
order; equal canonical fields do not imply equal native processing order.
Private archive copies must reproduce the exact captured control record. Trigger
checkpoints bind installed record bytes and order as well as canonical fields.

Opt-in archive inspection retains a bounded, ordered inventory of native dpkg
member names, link targets and header/dispatch types. It preserves `/.` rather
than substituting a normalized root path, and publishes only after complete
archive, trailer and descriptor/path checks. The pure ownership evaluator uses
these names with protected installed lists to find a sufficient saving-name
witness for each potentially disappearing package. Configuration-only owners
still count as sharers. Intermediate archive failures and newly introduced
package generations require independently bound native list-continuity evidence;
a payload inventory alone cannot supply it. Missing evidence requests a fresh
child boundary; it never starts or retries dpkg. This evaluator is not yet an
execution route. Replicated deconfiguration causes and their canonical identity
framing have separate output bounds, with incremental hashing and atomic refusal.

A standalone `CYDIA-DECONFIGURATION-APPROVAL-1` codec transports the exact
review, checkpoint/native identities, old-generation phases and history,
control/script identities, ordered causes and existing restoration endpoints.
It carries no protected file or script contents and recomputes no native proof.
Frames are limited to 8 MiB, with bounded action/archive/allowance counts and a
shared cause limit; malformed references, noncanonical framing and partial
results are refused. This codec does not change transaction protocol versions,
advertise capability or enable execution. Begin integration must independently
recapture and rebuild the parent proof before comparing canonical approvals.

Protected review capture derives prospective recipients from exact retained
index controls and captures their native installed scripts under the actual
frontend lock. It rechecks source/index, native component/configuration and
package/trigger evidence before returning an immutable review, without downloading
archives. A shared capture deadline reaches native queries, trigger locks and
compressed-index readers. External decoder output remains provisional until
the stream and successful child exit are verified; cancellation also settles
the owned decoder process group. Complete-state queries use a literal wildcard
to retain native Install/Hold selections on packages which are not installed.
Only genuinely metadata-empty, unselected dependency references are excluded
from package-effect/progress comparisons; protected raw state remains bound.
An authenticated read-only cydo route returns trigger and deconfiguration
approvals from that same protected checkpoint. Its canonical bundle binds the
exact review and acquisition methods, with one combined 8 MiB limit. The client
retains immutable approval values and refuses mismatched or cancelled replies.
A soft stop reserves child-cleanup time before the helper's hard deadline.
Begin v3 carries the complete paired approval and binds its canonical bytes to
the review digest; legacy v2 framing and digests remain readable when no
deconfiguration approval is supplied. The authenticated service checks the
independently resolved methods before binding the session. The retained owner
reconstructs one protected checkpoint and compares both approvals before archive
staging. A nonempty matched pair selects conditional owner settlement; an empty
paired Begin is refused because the broker uses ordinary trigger approval in
that case. Every actual launch still requires complete fresh native admission,
and the capture route advertises no provider execution capability.

The optional native confirmation retains that exact shared bundle, displays
old installed generations, causes and existing Configure/Remove/Purge endpoints,
and binds every displayed approval byte to its presentation identity. Its two
guidance labels cover all 21 locales. The internal capture selector is installed
only after independently protected native routing support; no user setting or
provider boolean can activate it. A paired Begin cannot fall back to legacy execution.

An opaque pre-unpack capture checks the actual retained private archive operands,
fresh native state, selected effective policy, ordered Conflicts/Breaks/Pre-Depends
processing and protected ownership. It rechecks sources, indexes, archive copies,
scripts, configuration and locks before publishing or reusing its result.
`FactsVerified` covers those captured facts, not inline-trigger or whole-child
execution safety. Multiple archives without independently proven native list
continuity request a fresh boundary; the capture never splits or retries dpkg.

A bounded restoration ledger records only observed, approved old-generation
deconfiguration after a successful child. It transfers debt only through the
exact reviewed successor Unpack and independently proven installed controls and
scripts. An actual Configure can discharge debt only after the native package
and its trigger obligations settle; exact Remove/Purge endpoints preserve any
separately reviewed later Purge. Unused allowances create no debt or operation.
Failed, cancelled or uncertain children retire the ledger without completing
actions or clearing debt. Opaque protected restoration checkpoints retain exact
native phases separately from generation content identities. Successor capture
compares freshly installed controls and selected scripts against rehashed
retained archive bytes and exact script metadata; it does not infer native
child success. Versioned NotInstalled selections remain present metadata,
while genuinely forgotten records remain absent. Conditional owner settlement
checks complete before/after observations against its private ledger history,
retains real HalfConfigured and Unpacked phases, and publishes debt and trigger
changes only after both checks pass. Drain/Defer/Refuse decisions, trigger
quiescence and the existing final state compare-and-swap are connected to the
owner. Connected disposable native-child fixtures exercise that call chain;
their explicitly labelled policy/loader doubles do not establish real
distribution or Darwin declaration acceptance.

The conditional route admits one retained archive per Unpack child and one
explicit Configure/Remove/Purge target. It does not split or retry an already
authorized native batch. Unmodeled multiarchive list continuity, dependency
cycle breaking, implicit removal, native payload filters and unsupported effective native settings
request a new review before that child. All capture callbacks share bounded
cancellation, while actual started children are always awaited and reaped.
The owner seals the complete retained archive store after its final native
policy and restoration callbacks, immediately before launch.

Internal transaction-channel version three can bind a protected conffile policy
to each actual child before spawn. The parent retains the parser's exact option
span, binds root and admin paths, finalizes status fd3, matches the complete
native settings and hashes the exact arguments and frozen environment. The
frontend applies that decision to its pending child scope and acknowledges the
same nonce, review, sequence, child ordinal and descriptor before the helper
rechecks authority and launches. For the supported semantic profile, effective
`confold`, `confnew` and `confdef` suppress answers: native dpkg can emit the
notification before choosing automatically. Missing or unsupported policy never
becomes a guessed interactive decision; a notification then closes input
without an answer. The broker negotiates this mode for retained transactions. Legacy one-shot
and transitional in-process paths retain their argument-only behavior.
This handshake binds a child policy, not proof that a particular native question
is still waiting on stdin. A stronger per-question status interface would be a
separate distribution dpkg change.

After settlement, Cydia retires the worker, cache handles, grants and review;
the next normal reload performs fresh discovery. A helper-confirmed final
commit remains a known outcome if the worker subsequently fails. Unknown
helper settlement remains indeterminate and cannot become an automatic retry.

Cydia-owned locale conversion and regular expressions prefer validated
bootstrap ICU, with Apple ICU as the next choice. UIKit collation remains
entirely Apple-owned. Optional private ICU and libintl loading interfaces do
not supply those binaries or their dependency closures. Embedded APT uses a
real libintl bridge and source-matched upstream catalogs; it falls back to
upstream English messages if no usable libintl is available.

| Area | Current implementation | Required behavior |
| --- | --- | --- |
| APT | Automatic startup prefers a validated registered external worker, then an independently verified private worker; transitional in-process fallback remains while its private payload is unavailable | Supply accepted distribution adapters and the private dependency payload, then retire the transitional fallback |
| Repository policy | Unsaved preference inherits an accepted external provider; recovery retains Warning; saved choices are preserved | Verify each adapter reproduces its distribution's compiled frontend and library policy |
| Other APT settings | Expiration policy and explicit language/parallel settings are preserved | Preserve the selected provider's configuration and compiled behavior |
| Source checks | Preflight, resource requests and discovery use the selected database backend and session | Establish source-check parity for each distribution adapter |
| dpkg | Selected external tools, parent-owned locks, reviewed batches, retained staging and negotiated finite trigger effects | Complete independent deconfiguration evidence and adapter acceptance |
| ICU | Validated bootstrap/Apple service tables; isolated private fallback loader; Apple-owned UIKit collation | Supply reproducible private fallback binaries and matching data |
| Messages | Converted locale environment, upstream catalog packaging and optional libintl bridge | Supply the private libintl closure for localization when external libraries are broken |
| Failure handling | Selection and fallback occur at coordinator boundaries; no operation-level retry under another provider | Verify interruption and recovery behavior with real adapters and their dependencies |
| Settings | Automatic/Cydia Recovery, cached provider identity/version/status, asynchronous Check Again and distinct fallback explanations | Retain truthful state; never probe while rendering cells or claim an unselected provider is active |
| Remorix packages | The registration/protocol contract and Cydia client exist; no Remorix adapter or new APT/dpkg package is supplied | Publish localized APT/dpkg and a tested adapter without making Remorix a requirement for Cydia |
| Commercial sources | Native accounts and exact archive authorization with ordinary hash/layout checks; no purchase API | Complete vendor-authorized account/download acceptance separately from public-source access |

The provider protocol also supports bounded paid-archive grants during an
approved fetch. Cydia derives each request from its retained source/index proof,
rechecks that proof around native account authorization, and sends only the
resulting HTTPS download URL to the worker. Credentials remain in Cydia. This
does not authorize purchases or prove vendor compatibility. The recovery worker
installs its scoped authorization bridge only during an approved fetch.

## Remorix distribution contract

Remorix will maintain its own APT and dpkg packages. Treat those as normal
external distribution components, not privileged exceptions to provider
selection. Publish their supported interfaces and an optional versioned
provider adapter alongside them. Cydia must also support other distributions
through tested adapters, without replacing their APT/dpkg with Remorix builds.

For APT, dpkg and other packages with localization support, enable native
gettext/NLS and ship available upstream catalogs by default. Keep catalogs
matched to the binary's domains and release. Do not strip translations merely
to reduce package size, or assume every upstream project already translates
all 21 Cydia UI languages. A language package split is acceptable only if the
normal package dependencies install the intended catalogs automatically.
Use package-policy-derived locale directories and real libintl dependencies;
test ordinary CLI execution as well as Cydia's converted locale environment.
Remove English diagnostic matching before enabling translated recovery paths.

Distribution behavior should be expressed in ordinary APT configuration where
possible and documented independently of Cydia. Keep insecure repositories,
weak metadata, authentication downgrades and payload integrity separate.
The Remorix release policy must be explicit; neither the bundled backend's
defaults nor another distribution's patches become Remorix policy implicitly.

Darwin packaging follows these requirements:

- `iphoneos-arm` uses rooted package policy; `iphoneos-arm64` uses rootless
  package policy. Derive installation paths from templates/variables. Confirm
  the selected runtime and `/var/jb` mapping rather than treating both layouts
  as interchangeable or applying a prefix to every local-state path.
- Bootstrap tools and libraries take priority within their selected runtime.
  Resolve configuration, catalogs, libexec tools and state paths from package
  policy. `Architecture: all` retains dpkg meaning; layout validation remains
  independent, including for proprietary packages.
- Track public library ABI through symbols metadata where applicable, with
  architecture-specific expectations. Resolve actual Mach-O install names,
  reexports and dependent libraries; add rootless library rpaths only when
  the artifact requires them, and re-sign modified Mach-O files.
- Keep local package metadata and changelog consistent with Remorix. Preserve
  package ID `cydia`, existing compatibility options and maintscript ownership
  of legacy file migrations. Do not make installing Cydia install a new
  distribution or overwrite another manager's configuration.
- Keep Darwin portability, locale support, distribution policy and optional
  authorization integration in separate, minimal patches. Use platform guards
  and DEP3 metadata; preserve non-Apple behavior. Reuse existing quilt stacks
  and generate hunks from diffs when implementation begins.

The recovery APT, libintl/catalogs and ICU/data remain private application
resources with reproducible versions and licenses. They must not resolve
through broken optional bootstrap libraries or advertise themselves as the
system's installed APT, dpkg or ICU packages. The external dpkg requirement
and the platform-framework recovery limit below still apply.

## Selecting one coherent APT provider

Automatic selection first considers a protected, explicitly configured external
provider, then the selected bootstrap's provider. Discovery uses the
selected runtime and its effective configuration, not the first `apt` found in
an arbitrary inherited PATH. The provider includes its APT library or tools,
acquisition methods, dependent libraries, configuration interpretation, and
policy implementation. Do not combine a bundled resolver with an external
transaction runner and assume their decisions are equivalent.

Validate executable and library identities, target architecture, loadability,
supported interfaces, required methods, and consistency with the selected dpkg
database. Probes must be bounded and nonmutating. An installed package record,
a version string, or a successful `apt-config` call alone is insufficient.
An unrecognized but otherwise healthy APT version is **unsupported**, not
**broken**; expose that distinction and the available recovery option.

Use a versioned Cydia-owned protocol across a worker-process boundary. The
existing package/source/transaction value types are a starting point; raw APT
C++ objects and cache handles must remain inside their owning provider.
The Cydia client and parent broker use this boundary for external providers.
Tested adapters for supported external libapt ABI families and acceptance of the
complete private recovery payload remain deliverables. Do not load arbitrary libapt C++ ABIs into
the UIKit process or require distribution maintainers to install Cydia's APT
patches. A CLI adapter may cover supported capabilities, but it must prove the
same preview and transaction guarantees before it is used for mutations.

The current wire schema is version 3. Version 2 adapters must be rebuilt;
the client does not reinterpret their handshake. Optional `FiniteTriggerEffects`
support is bit 18, separate from the immutable `Hello.finiteTriggerEffects`
selection and matching `Info.finiteTriggerEffects` acceptance. Probes leave the
accepted mode false. Cydia selects it only after native authority readiness;
advertising support alone preserves legacy behavior. In this mode a review
contains primary package actions, while the authenticated parent owns the
approved finite recipient pool and repeatable trigger passes. A mixed review
containing legacy `Triggers` or automatic `Deconfigure` actions is refused.

Debian recommends `apt-get` and `apt-cache` rather than the interactive `apt`
interface for automation. This does not make localized terminal output a
transaction protocol. Machine results must use documented structured channels
or an adapter protocol. A simulated operation is not an authorized, locked
transaction: configuration, state, provider identity, and the exact plan must
be revalidated before committing.

One provider must own source preflight, cache interpretation, candidate and
dependency selection, queue review, downloads, and transaction execution for a
given operation. Include provider identity, capabilities, policy and relevant
configuration in review snapshots. A provider change invalidates package
handles, caches, prepared archives and queued review, requiring reconstruction
and normal user review before execution.
Do not reuse provider-native binary caches or trust proofs across incompatible
providers. Rebuild derived data while preserving shared sources, dpkg state,
holds and automatic-package markings.

### Native dpkg transaction declaration

Retained execution reads `native-dpkg.conf` first in Cydia's protected state
directory, then in the distribution's `cydia` data directory beside dpkg data.
A present invalid higher-priority declaration is an error. Cydia neither
generates this file from guessed defaults nor changes native dpkg configuration.
A distributor must bind its compiled configuration and command graph to each
supported executable generation and verify that declaration against its build.

`CYDIA-NATIVE-DPKG-1` uses the existing canonical length-prefixed field format.
It contains exactly these ten fields, in order:

| Field | Value |
| --- | --- |
| Format | `CYDIA-NATIVE-DPKG-1` |
| Executable generations | Nested pairs of absolute executable path and lowercase SHA256; multiple admitted hashes may share a path |
| Configuration files | Nested required absolute paths |
| Configuration directories | Nested required absolute paths, captured recursively |
| Optional configuration files | Nested paths whose absence is also bound |
| Optional configuration directories | Nested paths whose absence and later membership are bound |
| Native commands | Nested paths of configured commands, each present in the executable and component declarations |
| Initial components | Complete protected regular-file inventory for native executables and nonplatform dependencies |
| Successor components | Nested pairs of `package:architecture` and a nested list of exact payload paths; matched only to approved archives |
| Graph contract | `complete-native-graph` |

Configuration, commands and optional inputs include defaults and transitive
includes. Every declared executable must be in the retained inventory. A new
binary hash is admitted only with an unchanged configuration graph and exact
approved archive payload. Changed native configuration requires a new review;
the same declaration cannot authorize arbitrary newly installed binaries.
Commands and libraries must pass the installed loader inspector. Platform
edges bind the active dyld cache, OS build and target; unavailable platform ABI
evidence refuses this optional path. No provider message can supply these
filesystem or loader proofs.

The version-one declaration establishes a protected read/loader graph, not
resolved dpkg effect policy. Graph-backed Unpack admission separately refuses
the exact native configuration option `auto-deconfigure`, including conservative
whitespace/long-option spellings; comments and values of other options do not
become that option. This closes the known configuration-before-argv case without
changing bootstrap files. Compiled defaults, environment force settings, ordered
hooks/filters and complete native policy still need independently supported,
input-bound evidence before automatic deconfiguration can be enabled. Absence of
a command-line switch cannot establish that policy, and the existing restricted
legacy path does not acquire complete native-policy parity from this check.
The retained environment binding fixes native launch inputs; it does not attest
to compiled defaults or interpret them as complete effect policy. Supported
native option arities and short clusters are used for database-path binding;
unknown option arities and abbreviated privileged options are refused.

`CYDIA-NATIVE-DPKG-2` retains fields 1–9 and the graph marker of version one,
adds a canonical bounded effect-record container at field 10, and ends with
`complete-native-effect-policy` at field 11. The protected reader accepts both
versions. Invalid outer/container framing remains a declaration error; an
invalid inner assertion retains a separate typed failure while its valid
protected graph remains usable. Missing, stale, ambiguous, unknown-profile or
unmodeled assertions cannot enable deconfiguration.

The record container is `CYDIA-NATIVE-EFFECT-POLICIES-1` plus a nested list in
canonical encoded-byte order. Each `CYDIA-NATIVE-EFFECT-POLICY-1` record binds a
semantic profile, executor path/SHA256, input identity, invocation role, exact
ordered option prefix, resolved setting assertions and the
`asserted-native-effect-settings` marker. The initial supported profile is
`dpkg-1.23.7-effects-1`; support is never inferred from version output. Settings
retain native Automatic/Enabled/Disabled trigger states, pending scope,
execution/selection/signature flags, abort/debug/output settings, the complete
enabled force subset, ignored dependencies and ordered hooks/loggers/filters.
Unexpressed settings remain explicit unsupported values.

Cydia builds distributor lookup inputs from revalidated native graph and actual
component/loader evidence, selected paths and its frozen launch environment.
File contents, explicit absence and directory membership are bound, along with
executor/component bytes, platform identity, invocation role and the parent's
finalized option prefix. Declaration/self-output bytes and local inode/time/group
metadata are excluded from that lookup. Textual or inode aliases reintroducing
the declaration through native inputs/components refuse lookup. The complete
protected local authority remains separate and requires fresh review after a
local generation change even if contents still match the distributor record.

The pure codec is limited to 1 MiB, 64 records and 64 KiB per record/value, with
separate item/count bounds. Required environment names bind presence separately
from empty values; additional `DPKG_*` and `LC_*` names are included. A separate
per-child identity includes all frozen environment entries, exact arguments and
fixed stdin/status roles. Parent-owned SHA256 is used; no producer, native parser
or new executable is supplied. A matched record is an input-bound distributor
assertion, not execution readiness. Production deconfiguration still needs
parent-finalized argument/I/O binding, immutable approval, independent Begin
reconstruction, complete effect admission and restoration-aware settlement.

Declaration and graph sizes, component/dependency counts, archive reads and
nonmutating admission are bounded. All archive copies are retained in private
root-owned files before mutation. Execution has no timeout that kills a live
dpkg child. App generation, caller identity, lock ownership, copied archives,
installed components and native configuration are rechecked through settlement.

### Protected registration and Settings

`AptProviderSelection` looks for `apt-provider.conf` first in Cydia's protected
state directory, then in the distribution's `cydia` data directory beside its
dpkg data directory. Both paths are derived from the selected package layout.
A present but invalid higher-priority registration does not fall through to a
different external provider. It is reported as a failure of that candidate;
Automatic mode can use recovery with a visible explanation.

Registration format `CYDIA-APT-PROVIDER-1` is a bounded, length-prefixed field
document, not a source file or shell script. Its root-owned declaration names
the adapter, effective dpkg/source/state/keyring/method paths, executable search
path, protected dpkg options, and complete library/frontend/configuration/policy
inputs. Optional configuration files and directories are declared explicitly.
`AptProviderSelection.hpp` defines the required fields. Cydia's authenticated
helper reads and verifies this authority independently of the worker's claims,
including protected paths, component identities and dpkg architectures.

The probe and session handshake must agree with that snapshot, supported
protocol capabilities and the current package-state identity. The coordinator
publishes a descriptor only after validation. Later privileged requests reread
the registration and compare its authority, so replacing a component or changing
configuration cannot silently authorize an old review. This mechanism cannot
prove that a distributor declared every dependency or faithfully implemented
its policy; those remain adapter packaging and acceptance requirements.

Advanced Settings exposes **Automatic** and **Cydia Recovery**. Its status is a
cached snapshot of the selected runtime, with the accepted provider identifier
and adapter version when available. APT version is not inferred from the
adapter version or an installed package record. **Check Again** performs an
asynchronous coordinator check. Missing, unsupported and broken external
candidates have distinct explanations even when recovery is the active runtime.
Settings changes rebuild the cache and invalidate queued confirmation; a notice
explains this when package changes are pending. Preferences are saved only
after a successful selection. No arbitrary executable-path picker is added.

### Immutable review and parent execution

`Database.prepare` captures an external transaction and source/index evidence
off the main thread while holding the frontend lock. The lock is released while
the user reads the confirmation sheet. `CydiaTransactionReview` copies the
transaction values, exact execution-action IDs, and per-archive warning IDs.
The native sheet displays every operation and its version; normal single-arch
devices retain unqualified native/`all` package names, while multiarch reviews
distinguish native, foreign and architecture-independent packages. Progress
uses that same owned snapshot instead of asking the worker for a fresh review.

Archive inspection limits are presented for the exact queued archives. This
acknowledgment is independent of repository-signature settings. It permits only
a complete, identity-verified inspection with unverified script/shared-path
semantics; it does not permit an incomplete inspection, an identity/hash
mismatch or a known layout conflict. The later fetch cannot add hidden warning
approvals or substitute a different manifest.

`AptProviderArchiveEvidence` independently reads the configured source files and
retains the selected Packages indexes before confirmation. Each archive names
its source document and definition ordinal, exact index URI/path, SHA256 of
the stored index bytes, and decoded record offset/length. Cydia verifies the
source association and exact Package, Version, Architecture, Filename, Size and
hash fields. Ordinary flat and suite/component sources are supported, including
implicit `binary-all` targets unless explicitly removed. Source/index changes
invalidate the proof. Compressed indexes use bounded readers and protected
decoder paths, without invoking the bundled resolver or adopting its policy.
Custom `Acquire::IndexTargets` paths and alternate list naming are not supported
by this proof and must not be treated as verified.

Before the first mutation, the parent checks every approved downloaded archive's
source/index evidence, size, hashes, control identity and layout. This includes
archives scheduled after an earlier removal or pending configuration. Unpack
batches still recheck their exact archives. The privileged
broker then copies approved archives into a root-owned private staging directory,
checks them again, and substitutes only those protected copies into validated
dpkg operands. The parent owns the frontend lock, authorizes exact reviewed
batches, and verifies structured dpkg state before and after execution. Shared
automatic-package state is committed only for approved deltas after verified
completion. Cancellation cannot turn a started dpkg operation into a safe retry;
the actual child must settle and uncertain effects require a new review.

Brokered dpkg children have separate configuration-question input/status
channels. Keep Old/Accept New replies bind to one child and one question;
settlement or subsequent status invalidates the alert. Paths containing spaces
are supported. Exact forced-old/new options suppress unnecessary questions;
unknown native configuration and `--force-confdef` alone do not establish an
automatic choice. An unreadable question closes that child's input and reports
failure rather than guessing a response. The transitional in-process APT path
has transaction-level isolation because it exposes no individual child boundary.
Upstream's notification precedes its native automatic decision, so per-question
input readiness within a single child remains a separate native interface
requirement; lifecycle tokens do not prove that dpkg is waiting for input.

## Distribution policy and explicit overrides

With an accepted external provider, the unsaved default is **Use distribution
settings**. Recovery retains the existing Warning default. The explicit
**Use selected APT settings** choice restores the active embedded engine's
loaded settings; it does not claim to reproduce another binary's compiled
distribution policies. Existing saved choices remain unchanged. Preserve the provider's
compiled behavior as well as its configuration: `apt-config dump` cannot
describe or reproduce arbitrary distribution patches. This includes source
authentication, expiry checks, keyrings, pins, holds, architecture policy,
hooks, dpkg options, automatic-package state, and acquisition methods.
Configuration precedence follows the selected APT implementation, including
binary-specific configuration where relevant. A libapt adapter must also
account for distribution changes made in the `apt-get` frontend itself;
loading the same library alone does not reproduce those frontend defaults or
patches. Specify and test the provider's frontend/configuration identity.
Returning to inheritance or changing providers must create a clean effective
configuration, without retaining Cydia overrides from a previous session.

Cydia may show a nonblocking warning for a repository that the distribution
accepts without authentication. This warning is presentation, not a hidden
change to enforcement. Existing Allow/Warning/Error choices remain available
as explicit Cydia overrides. Settings must distinguish an absent preference
from a saved choice: migrate absence to inheritance only with supported
provider activation, and retain explicitly saved choices. Apply an override through supported provider controls, show its
scope, and report unsupported controls instead of silently changing providers.
Do not write these overrides into shared distribution configuration files.

Unsigned metadata, invalid signatures, a previously signed source becoming
unsigned, weak hashes, and an archive hash mismatch are different outcomes.
Do not infer one distribution's treatment of all these cases from its handling
of unsigned repositories. Preserve those distinctions in provider results.
Cydia's archive identity/layout validation, explicit key-import approval and
protection against changed transaction inputs remain frontend responsibilities;
they must be visible and must not masquerade as the distribution's policy.

For example, the published Elucubratus APT `1.8.2+ios` fork defaults
`AllowInsecureRepositories` to true while leaving `AllowWeakRepositories` and
`AllowDowngradeToInsecureRepositories` false. It also changes warning behavior.
Cydia's current single mode setting all three allowances together is not an
equivalent policy. This is evidence for provider inheritance, not a rule to
identify distributions by name or copy one fork's defaults to every system.

## Recovery without changing the bootstrap

Missing or unloadable components may select a private recovery provider before
an operation begins. Normal network failures, rejected signatures, bad source
configuration, unsatisfied dependencies and locks held by another manager are
not evidence that APT is broken and must not trigger provider switching.

Recovery must retain the selected package database and any policy that can be
established reliably. Compiled distribution behavior cannot be reconstructed
from config files alone. If equivalent mutation policy cannot be established,
keep browsing/diagnostics available and require an explicitly reviewed recovery
policy before package changes; do not silently impose either stricter or more
permissive bundled defaults. Never retry a started transaction under another
provider. Reconcile actual dpkg state and prepare a new review first.

The bundled provider needs a verified usable dependency closure for the
recovery operations it offers, including applicable methods, decompression,
signature verification and message catalogs. Merely bundling libapt does not
guarantee recovery when one of those dependencies is missing. Keep all bundled
components private; do not install them over distribution executables or
libraries. A missing or unusable dpkg still prevents ordinary package
installation; this design does not introduce a replacement dpkg or claim to
repair a corrupt package database by switching APT.

## ICU and message localization

ICU provider selection is independent of APT's dependency graph. Apply the
bootstrap -> Apple system -> bundled fallback order only to Cydia-owned ICU
operations; do not inject a replacement ICU into Foundation, UIKit, or external
APT tools. Platform frameworks retain their own dependencies.

Use a narrow C API adapter with provider-owned handles. Validate the complete
required API and matching common, internationalization and data components;
ICU symbol renaming and release-specific data make a filename check inadequate.
Keep regex objects and transliterators with their creating provider until
closed. Select before creating Cydia's locale/regex/transliteration state;
do not hot-switch an active provider's function table. A private fallback
needs pinned source, matching data, licensing,
reproducible builds and isolated symbols. It is new packaging work, not a
change to the existing header fallbacks.

Package sorting currently combines UIKit section metadata, CoreFoundation
comparison and direct ICU transliteration. Do not switch only transliteration
and leave incompatible section thresholds behind. Retain an explicitly
Apple-owned UIKit collation service or migrate sorting, section assignment and
transliteration together. Rebuild derived sort/search state when providers or
Unicode data change. A private ICU cannot recover broken OS frameworks that
the application itself requires to launch.

ICU is not gettext. Keep the Apple-to-POSIX locale conversion and machine-safe
locale categories, and pass them to the selected worker/tools. External APT
uses its own gettext implementation and installed catalogs when capable.
This is not guaranteed by an external installation: the published Elucubratus
APT 1.8 build recipe explicitly uses `USE_NLS=0`.
Enable gettext and supply matching catalogs for the bundled recovery backend;
do not create Cydia copies of upstream diagnostic translations. Remove any
English-message matching used for recovery decisions before localizing that
backend, using structured errors or independent dpkg-state checks instead.

## Commercial repository compatibility

Public metadata, free archives, account authentication, purchase entitlement
and paid archives are separate capabilities. A successful metadata request
does not prove paid-download compatibility or a complete authenticated APT
refresh. Vendor support policy is also distinct from HTTP admission.

| Repository | Public evidence | Compatibility limit |
| --- | --- | --- |
| Havoc | Anonymous bounded requests retrieved `Release`, `Release.gpg` and `Packages.xz`; `payment_endpoint` advertises an HTTPS provider | Havoc explicitly does not support Cydia for paid packages. Public metadata availability does not overturn this policy or establish acceptance of Cydia's account callbacks and download requests |
| Chariz | Anonymous bounded requests retrieved `Release` and `Packages`; an HTTPS payment provider is advertised. Its FAQ documents Cydia's Buy or Log In flow | The documented legacy flow does not establish that this refurbished native Cydia implements it, or that a new integration works end to end |

These checks used ordinary truthful clients without account credentials or
device identifiers. They did not verify metadata signatures, run a device APT
refresh, purchase products or retrieve package archives. They show public-index
access for the tested clients, not universal admission for every client or
network. Havoc's absent `InRelease` can use its detached
`Release.gpg`; that response alone is not a client block. Its documented 418
error can also indicate an account/login problem.

Cydia's native `payment_endpoint` account service is shared by Home's Manage
Account entry, Settings and commercial package details. It uses explicit
device-link consent, scoped Keychain tokens and package/version/architecture
authorization. Temporary HTTPS archive URLs are acquired privately and checked
against the selected index hashes, size, identity and layout before dpkg.
This implementation does not establish vendor acceptance. Havoc account
linking and paid authorization remain unsupported; anonymous discovery and
ordinary public acquisition stay available. Purchases use the vendor website,
not an automatic purchase API. The read-only depiction bridge remains unchanged.

### Native accounts and download authorization

Implement a native account broker using supported payment-provider discovery,
browser authentication, account information and ownership APIs. Verify API
versions and the accepted client callback with each vendor. Existing protocols
and implementations include Sileo-specific callbacks; do not globally register
another manager's URL scheme or impersonate its client identity. Havoc's
seller-side DRM API is not a substitute for a package-manager API, and seller
credentials never belong in Cydia.

Discovery may come from a source accepted without authenticated metadata.
Require HTTPS, show the source and payment-provider origins during account
linking, and scope stored credentials to the approved provider origin. A
changed advertised endpoint must suspend credential reuse until the new
binding is confirmed; never automatically send an existing token or device
identifier to the replacement endpoint. Tie authentication callbacks to the
active browser session and exact provider, validate returned fields, and
reject unsolicited or replayed callbacks. Use protocol-supported state,
nonce or PKCE mechanisms where available; do not accept an unbound callback
when the protocol cannot establish a safe session association.

Home's existing Manage Account entry and Settings account links should reach
the same controller. Package pages should distinguish Sign In, Buy, Download,
Unavailable and authentication failures. Purchases always require an explicit
user action. Keep ordinary Sources browsing familiar and source configuration
in Settings. Support logout and account removal without deleting repositories.

Keep long-lived account tokens and purchase secrets in Keychain. Honor any
protocol-required user authentication and disclose required device binding;
do not send permanent device identifiers with every public metadata request.
Bind an authorization grant to the source, account, package, version and
selected package architecture, including foreign architectures. Obtain a
short-lived HTTPS grant near download time. Reauthorization after expiry must
not change the reviewed package identity, expected hash or layout checks.

The native account/acquisition implementation separates transport URLs from
display URLs and redacts credential-bearing URLs in progress and diagnostic
paths. Preserve this separation in every adapter. Redact credentials and sensitive query/path tokens from
UI, logs, diagnostics and crash context. Send grants through authenticated,
bounded IPC or protected descriptors, never command arguments, source files,
shared APT configuration or world-readable caches. Do not forward account
tokens or device headers to redirect destinations. A signed CDN URL is its
own scoped grant; retain TLS, repository trust and payload-integrity checks.

### Patch responsibilities and CLI behavior

| Layer | Responsibility and status |
| --- | --- |
| Cydia | Native accounts, browser-session callbacks, entitlement-aware actions and redacted progress are implemented; vendor acceptance remains separate |
| External provider integration | An adapter must carry a scoped authorized download or a securely staged, verified archive while preserving its reviewed solve and archive identity; native account support alone does not complete this integration |
| Bundled APT | Cydia uses existing acquisition interfaces to stage granted archives and verify expected hashes and size; no vendor-specific bypass or identity spoofing is supplied |
| Remorix APT | If a generic hook is necessary, share the same tested protocol as recovery APT and keep it an optional, separately maintained patch/integration |
| Other distributions | Use supported adapters or verified archive staging. Do not patch installed APT in place or require replacing it with Remorix |
| Optional Remorix CLI helper | Let an explicitly linked account authorize downloads through a protected service. Do not assume root CLI processes can read the mobile user's Keychain. Without credentials, report an actionable authentication requirement |

APT's `auth.conf` handles conventional repository/proxy credentials; it is not
a payment-provider client. An ordinary CLI may refresh accessible public
indexes and fetch available free archives without Cydia account integration;
it does not automatically gain paid-download entitlement from installing our
APT build. The optional helper must never start purchases or unsolicited login
flows during `apt update` or unattended transactions.

Map HTTP/account outcomes to typed provider errors. Missing entitlement,
expired grants, unsupported clients, repository rejection and network errors
must not trigger engine fallback, relaxed signature enforcement or disabled
hash verification. No current evidence justifies a blanket Havoc/Chariz
transport bypass patch. Paid Havoc support stays explicitly unsupported or
unverified until the vendor accepts the Cydia integration and an authorized
owned-package retrieval succeeds. This gate does not block the general
APT/ICU provider migration or public-source support.

## Implementation map and remaining work

| Part | Work |
| --- | --- |
| `AptRuntime.*`, `RuntimeProviderCoordinator.*`, `AptProviderSelection.*`, `MobileCydia.mm` | Startup selection, protected registration and immutable descriptor adoption are implemented; distribution adapters and deployment acceptance remain |
| `AptBackendFacade.cpp`, `AptBackend*`, `SourcePreflight*`, `AptProviderServer*`, `AptRecoveryWorker*` | Remote value facade, source routing, bounded server and separate native recovery worker are implemented; no distribution adapter or complete private payload is supplied |
| `apt-extra/apt-2.7.9-cydia.patch`, `AptCompatibility.cpp` | Keep recovery-specific patches private; replace Cydia-only authentication/state hooks in stock-provider adapters |
| `PrivilegedRuntime.*`, `PrivilegedClient.*`, `AptProviderBroker*`, `cydo.cpp` | Authenticated authority snapshots, retained parent execution, protected archive staging, declared component succession and per-child settlement are implemented; independent deconfiguration coverage remains |
| `RuntimeSnapshotInputs.*`, `Database*`, `TransactionReview.*`, `AptProviderArchiveEvidence.*` | Provider-bound immutable review and independent source/index/archive proof are implemented; custom index-target/list layouts remain unsupported |
| `SettingsStore.*`, `RuntimeProviderSettingsController.*`, Settings controllers, locale tables | Explicit-choice preservation, Automatic/recovery selection and truthful asynchronous status UI are implemented in all existing locales |
| `CyteKit/RegEx.hpp`, `Collation.hpp`, `Package.mm`, `Package+Metadata.mm`, `MessageLocaleConversion.mm` | ICU adapter and handle ownership, coherent collation and locale behavior |
| `mk/apt.mk`, `mk/toolchain.mk`, `mk/rules.mk`, `mk/recovery.mk`, `mk/package.mk`, `cydia.control` | Separate recovery worker and private methods are packaged; complete signature/compression/ICU/libintl payloads remain separate inputs; package ID and distribution ownership are preserved |
| `PackageArchivePolicy.*`, `PackageArchiveReader.*` | Bounded exact payload-file bytes and numeric metadata can be captured without extraction; this is a foundation for independently verified component succession, not execution authority |
| `AptProviderTransactionOwner.*`, `AptProviderTransactionLease.*`, `AptProviderComponentSuccession.*`, `AptProviderNativeDpkgAuthority.*` | Persistent helper ownership, retained archive copies, native declaration/loader evidence, approved component generations and exact settlement; declaration delivery and real distribution acceptance remain |
| `AptProviderTrigger*`, `RuntimeSnapshotInputs.*`, transaction channel/service | Protected registry/control capture, immutable native approval, bounded finite drain ledger and separate child scopes; legacy mode remains restricted |
| `DpkgConffile.*`, `AptProviderConffilePolicy*`, `Database+Configuration.mm`, `PrivilegedClient.*` | Retained transactions use exact final launch binding, protected force-state suppression and stale-alert invalidation; legacy argument-only behavior and stronger native per-question readiness remain separate limitations |
| `AptProviderDeconfigurationApproval.*`, `AptProviderRestorationDebt.*` | Bounded immutable approval codec and observed restoration bookkeeping; protected capture, locked reconstruction and owner integration remain prerequisites to activation |
| `apt-extra/apti18n.h`, locale packaging | Real gettext/catalog support for recovery without replacing provider-owned translations |
| Account controllers/service, `PackageDetailViewModel.mm`, source snapshots | Payment-provider discovery, supported sign-in, ownership states and exact-package download authorization |
| `DatabaseStatus.mm`, `ProgressEvent.mm`, acquisition protocol | Redacted display URLs, typed account/transport failures and protected short-lived grants |
| Remorix APT/dpkg packaging and optional adapter/helper packages | Native catalogs, declared runtime/ABI policy and reusable optional authorization integration |

## Remaining delivery and compatibility gates

| Gate | Available Cydia support | Remaining work or acceptance |
| --- | --- | --- |
| Contracts and policy | Versioned worker/account models, protected registration, explicit-choice handling and provider-bound snapshots | Demonstrate that real adapters declare their complete environment and reproduce distribution policy |
| Remorix packages | A client/registration contract that does not require replacing another distribution | Supply localized APT/dpkg and an optional adapter; verify catalogs, ABI/path metadata and dependency closure |
| Recovery isolation | Separate unprivileged worker, bound read-only capsule, isolated configuration and native acquisition/review | Supply and accept the private payload, complete transaction parity, then retire the transitional in-process fallback; configured hooks remain refused |
| External transactions | Startup admission, native review, retained authenticated helper ownership, archive copies, declared component succession and optional finite trigger effects | Real adapter/device acceptance and independent deconfiguration proof |
| Recovery dependencies and ICU | Bootstrap/Apple ICU selection, private loader interfaces and upstream gettext bridge/catalogs | Supply private ICU/libintl binaries and full dependency/data closure; prove usable recovery when optional bootstrap components fail |
| Commercial sources | Native accounts, scoped authorization, private archive acquisition and redacted diagnostics | Vendor-accepted callbacks and authorized paid retrieval; any optional Remorix CLI authorization helper remains separate work |
| UI and release acceptance | Runtime Settings and immutable confirmation in all existing Cydia locales | Verify runtime transitions, failure handling and safe drop-in upgrade/removal with supported provider packages |

The Cydia production glue does not by itself establish compatibility with an
ordinary installed APT or a future Remorix adapter. Full inheritance of compiled
distribution behavior requires the accepted adapter, not configuration cleanup
alone. Automatic can select recovery before an operation and explain why;
repository failures and unsupported controls must not silently change the
provider during an operation. Havoc paid support remains a separate external
compatibility gate.

Current limits are explicit:

- The bundled recovery worker requires a complete protected payload inventory;
  missing dependencies retain the transitional in-process fallback at startup.
- Private ICU/libintl binaries and their complete recovery dependency closure
  are not packaged by the loader interfaces.
- Independent archive provenance supports ordinary flat and suite/component
  indexes; custom `Acquire::IndexTargets` and alternate list naming are unsupported.
- Legacy explicit trigger batches must enumerate the complete fresh pending set
  and retain `--no-triggers`; automatic deconfiguration requires the separate
  protected paired route. This is a bounded adapter contract, not full implicit trigger parity.
  The broker rejects effects it cannot independently establish; the protocol's
  action enum and visible review rows are not a claim of complete dpkg coverage.
- Without an independently rebuilt paired approval, the parent refuses an out-of-sync coinstalled
  `Multi-Arch: same` sibling that dpkg would implicitly deconfigure, even without
  `--auto-deconfigure`. Updating both architectures in one batch does not hide
  that intermediate effect. Single instances, unrelated foreign packages and
  dpkg-equivalent synchronized versions remain supported. Full sibling upgrades
  require independently approved causes and exact restoration endpoints through
  the bounded conditional route; unmodeled native batching remains unsupported.
- Active native components can succeed only through retained helper authority
  and explicitly declared binary generations with the same immutable native
  configuration graph. Missing native declarations retain restricted execution;
  invalid declarations, config changes, undeclared dependencies or unsupported
  loader behavior refuse. Mach-O inspection verifies protected bytes, target,
  rpath resolution and dylib-version compatibility; it does not prove every
  symbol, dynamic load or device trust-cache decision. Native dpkg configuration
  declarations and accepted package generations remain distribution packaging
  work; APT options do not establish dpkg's compiled search policy.
- No real Remorix adapter, full external-provider end-to-end acceptance or
  vendor-authorized commercial-download acceptance has been completed by these
  interfaces. Remorix APT/dpkg patches, adapter packages and optional CLI helpers
  are separate distribution work, not bundled substitutes supplied by Cydia.

Potential behavior changes include distribution-specific dependency solutions
and security decisions, restored expiry checking when the distribution enables
it, localized upstream errors, different Unicode sorting, larger private
recovery payloads, queue invalidation after provider changes, and explicit
sign-in/unavailable states instead of generic failures for paid packages.
Do not erase saved user overrides or silently replace distribution policy
during migration.

Acceptance must include healthy external preference; missing, unloadable and
unsupported providers as distinct cases; provider updates between review and
execution; exact-plan/multiarch/hold/pin behavior; one real lock owner; hook and
automatic-state parity; source preflight parity; no fallback on ordinary repo
or resolver errors; unchanged bootstrap files on install/removal; working
recovery without external APT/ICU dependencies; and upstream message catalogs
without localized prose controlling execution.

Commercial-source acceptance must separately verify signature-checked public
refresh, free archive retrieval and an already-owned paid archive using an
authorized account. Cover login/purchase cancellation, unsupported callbacks
or clients, endpoint changes, unsolicited/replayed callbacks, expired/revoked
grants, exact foreign-architecture selection, redirects, redaction and
hash/layout failure handling with both external and recovery providers.
Use fixtures for ordinary failure cases; do not make a
purchase or transmit a device identity solely for an automated test. A vendor
capability is not complete until its own authorized end-to-end gate passes.

Validate Remorix package metadata, catalogs and Mach-O dependencies, then verify
the relevant artifacts on their supported runtime layouts. New Cydia-owned UI
strings cover the existing 21 locales. APT/dpkg diagnostics remain upstream
translations, with untranslated upstream
messages allowed to fall back normally.

## Upstream references

- [APT automation guidance](https://manpages.debian.org/trixie/apt/apt.8.en.html)
- [APT configuration and hook protocols](https://manpages.debian.org/trixie/apt/apt.conf.5.en.html)
- [APT simulation limitations](https://manpages.debian.org/testing/apt/apt-get.8.en.html)
- [APT repository authentication](https://manpages.debian.org/trixie/apt/apt-secure.8.en.html)
- [Elucubratus APT 1.8.2+ios defaults](https://git.bingner.com/apt.git/tree/apt-pkg/init.cc?h=1.8.2%2bios)
- [Elucubratus APT 1.8 build options](https://git.bingner.com/elucubratus.git/plain/data/_apt1.8/make.sh)
- [ICU design and compatibility](https://unicode-org.github.io/icu/userguide/icu/design)
- [ICU library isolation](https://unicode-org.github.io/icu/userguide/icu4c/packaging.html)
- [ICU data packaging](https://unicode-org.github.io/icu/userguide/icu_data/)
- [Havoc supported package managers](https://docs.havoc.app/docs/help/package_managers/)
- [Havoc purchased-package downloads](https://docs.havoc.app/docs/help/how_to_download/)
- [Havoc 418 troubleshooting](https://docs.havoc.app/docs/help/common_errors/418_error/)
- [Havoc seller DRM API](https://docs.havoc.app/docs/seller/drm/)
- [Chariz purchase and package-manager FAQ](https://docs.chariz.com/help/faq)
- [Payment-provider protocol](https://developer.getsileo.app/payment-providers)
- [Zebra payment-provider extensions](https://github.com/zbrateam/Zebra/blob/v1/docs/Payment-Providers-Extensions.md)
- [Zebra payment-provider implementation](https://github.com/zbrateam/Zebra/blob/v1/Zebra/Tabs/Sources/Helpers/ZBPaymentVendor.m)
- [APT scoped repository/proxy credentials](https://manpages.debian.org/trixie/apt/apt_auth.conf.5.en.html)
- [APT HTTP transport](https://manpages.debian.org/trixie/apt/apt-transport-http.1.en.html)
