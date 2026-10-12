# Runtime providers and distribution policy

## Scope and implementation status

Cydia is an optional graphical frontend for the selected distribution's APT
and dpkg environment. Installed, working, supported distribution components
take precedence over Cydia's private recovery components. Installing or
removing Cydia must not replace those components, their configuration, sources,
keyrings, or package database. No distribution is identified from a repository
hostname or assumed to be the default. The package ID remains `cydia`;
legacy package-owned file migrations remain maintscript responsibilities.

This document distinguishes the target architecture from the available
implementation. APT 2.7.9 remains statically linked into the application and
privileged helper, and dpkg is external. The versioned provider codecs,
protected executable probe and session client are preparation for adapters;
they do not activate an external backend. Activation requires an adapter
accepted against the complete transaction and source-check contract below.
An ordinary installed APT executable is not such an adapter.

Cydia-owned locale conversion and regular expressions prefer validated
bootstrap ICU, with Apple ICU as the next choice. UIKit collation remains
entirely Apple-owned. Optional private ICU and libintl loading interfaces do
not supply those binaries or their dependency closures. Embedded APT uses a
real libintl bridge and source-matched upstream catalogs; it falls back to
upstream English messages if no usable libintl is available.

| Area | Current implementation | Required behavior |
| --- | --- | --- |
| APT | The facade always constructs the embedded backend | Prefer a validated distribution provider; keep the bundled provider available for recovery |
| Repository policy | Existing Warning default is retained; explicit Use selected APT settings restores independent loaded settings | Inherit validated distribution-provider enforcement by default; preserve explicit administrator overrides |
| Other APT settings | Expiration policy and explicit language/parallel settings are preserved | Preserve the selected provider's configuration and compiled behavior |
| Source checks | Preflight runs bundled APT | Check with the same selected provider and policy used for refresh and transactions |
| dpkg | Selected external tools and protected runtime paths | Retain external dpkg and its policies; extend validation to the selected APT provider |
| ICU | Validated bootstrap/Apple service tables; isolated private fallback loader; Apple-owned UIKit collation | Supply reproducible private fallback binaries and matching data |
| Messages | Converted locale environment, upstream catalog packaging and optional libintl bridge | Supply the private libintl closure for localization when external libraries are broken |
| Failure handling | No APT provider transition | Diagnose provider failure separately from repository, configuration, dependency, and lock errors |
| Remorix packages | Future distribution integration is not yet defined | Publish localized APT/dpkg and a tested provider interface without making Remorix a requirement for Cydia |
| Commercial sources | Native accounts and exact archive authorization with ordinary hash/layout checks; no purchase API | Complete vendor-authorized account/download acceptance separately from public-source access |

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
provider, then the selected bootstrap's provider. Discovery must use the
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
Implement tested adapters for supported external libapt ABI families and a
separate bundled recovery worker. Do not load arbitrary libapt C++ ABIs into
the UIKit process or require distribution maintainers to install Cydia's APT
patches. A CLI adapter may cover supported capabilities, but it must prove the
same preview and transaction guarantees before it is used for mutations.

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

## Distribution policy and explicit overrides

The selected-provider target default is **Use distribution settings**. Until
external activation, the shipped default remains Warning. The explicit
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

Before adding grants, separate transport URLs from display URLs. Current
progress/error paths expose raw URIs, and the preflight sanitizer only strips
URL user information. Redact credentials and sensitive query/path tokens from
UI, logs, diagnostics and crash context. Send grants through authenticated,
bounded IPC or protected descriptors, never command arguments, source files,
shared APT configuration or world-readable caches. Do not forward account
tokens or device headers to redirect destinations. A signed CDN URL is its
own scoped grant; retain TLS, repository trust and payload-integrity checks.

### Patch responsibilities and CLI behavior

| Layer | Planned work |
| --- | --- |
| Cydia | Native accounts, supported browser callbacks, entitlement-aware actions, typed authentication errors and safe progress presentation |
| Provider protocol | Carry a scoped authorized download or a securely staged, verified archive while preserving the provider's reviewed solve, archive identity and transaction guarantees |
| Bundled APT | Reuse supported acquisition interfaces first. Add a narrow, generic authorization hook only if an adapter cannot safely supply the reviewed archive; no vendor-specific bypass or identity spoofing |
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

## Required implementation changes

| Part | Work |
| --- | --- |
| `AptRuntime.*`, `MobileCydia.mm` | Provider discovery, capability reporting, inherited configuration, removal of unconditional policy overrides |
| `AptBackendFacade.cpp`, `AptBackend*`, `SourcePreflight*` | Worker protocol, provider adapters, one-provider operation lifecycle, structured progress and errors |
| `apt-extra/apt-2.7.9-cydia.patch`, `AptCompatibility.cpp` | Keep recovery-specific patches private; replace Cydia-only authentication/state hooks in stock-provider adapters |
| `PrivilegedConfig.cpp`, `PrivilegedRuntime.*`, `PrivilegedClient.*`, `cydo.cpp` | Authenticate worker requests, validate provider/dependency identity and configuration, update lock ownership and privilege boundaries |
| `RuntimeSnapshotInputs.*`, `Database.mm` | Bind previews to provider and policy identity, invalidate stale queues, preserve shared state and structured recovery |
| `SettingsStore.*`, Settings controllers, locale tables | Inheritance versus explicit overrides, Automatic/recovery selection, provider/version/status and an actionable fallback explanation |
| `CyteKit/RegEx.hpp`, `Collation.hpp`, `Package.mm`, `Package+Metadata.mm`, `MessageLocaleConversion.mm` | ICU adapter and handle ownership, coherent collation and locale behavior |
| `mk/apt.mk`, `mk/toolchain.mk`, `mk/rules.mk`, `mk/package.mk`, `cydia.control` | Separate workers/adapters and private recovery dependencies; preserve package ID and avoid hard dependencies that defeat recovery |
| `apt-extra/apti18n.h`, locale packaging | Real gettext/catalog support for recovery without replacing provider-owned translations |
| Account controllers/service, `PackageDetailViewModel.mm`, source snapshots | Payment-provider discovery, supported sign-in, ownership states and exact-package download authorization |
| `DatabaseStatus.mm`, `ProgressEvent.mm`, acquisition protocol | Redacted display URLs, typed account/transport failures and protected short-lived grants |
| Remorix APT/dpkg packaging and optional adapter/helper packages | Native catalogs, declared runtime/ABI policy and reusable optional authorization integration |

## Delivery order and compatibility gates

| Phase | Deliverable | Exit condition |
| --- | --- | --- |
| 1. Contracts and policy | Versioned worker/account capability models, explicit-choice migration, clean inherited configuration and removal of English diagnostic control flow | Saved choices survive; absence means inheritance; errors are structured; no silent engine changes |
| 2. Remorix packages | Localized APT/dpkg, published distribution policy, Darwin ABI/path metadata and an optional versioned adapter | CLI catalogs work; dependencies and rooted/rootless artifacts match policy; installing Cydia does not replace another distribution with Remorix |
| 3. Isolate current APT | Put bundled APT behind the worker boundary and update helper/lock ownership | Existing review, multiarch, source preflight, hooks, state updates and bootstrap protections remain correct |
| 4. Prefer external APT | Remorix and other tested distribution adapters, coherent operation ownership and provider-change invalidation | Healthy supported external providers win; strict and permissive distribution behavior is preserved; unsupported is distinct from broken |
| 5. Recovery and ICU | Private recovery dependency closure and gettext; independent ICU adapter and fallback | Failure handling works before/during/after interrupted operations; no mid-transaction switching; sorting, sections and transliteration remain coherent |
| 6. Commercial sources | URL redaction first, native accounts, accepted callbacks, entitlement and generic acquisition integration; optional Remorix CLI helper | Public refresh, free retrieval and owned paid retrieval have separate gates; secrets remain scoped; unsupported vendors are identified honestly |
| 7. UI and release acceptance | Settings, all existing Cydia UI locales, package install/upgrade/remove checks and focused runtime verification | Clear provider/account states, unchanged ordinary Sources UX, package ID `cydia` and safe drop-in upgrade/removal |

Phases 2 and 3 can proceed independently after the contract is fixed; the ICU
work can also proceed after its interface is defined. Full inheritance of
compiled distribution behavior arrives with phase 4, not the configuration
cleanup alone. Missing capabilities in a healthy provider require an explicit
compatibility or recovery choice, not silent bundled-provider substitution.
Havoc paid support remains a separate external compatibility gate.

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

Validate Remorix packaging statically first, then use the smallest relevant
build and inspect the resulting metadata, catalogs and Mach-O dependencies.
Retain the existing build machines. Use real devices only for gaps that depend
on device behavior: general/rooted checks on an iPad, rootless or iPhone-specific
checks on an iPhone. New Cydia-owned UI strings cover the existing 21 locales;
APT/dpkg diagnostics remain upstream translations, with untranslated upstream
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
