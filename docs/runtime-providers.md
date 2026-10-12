# Runtime providers and distribution policy

## Scope and implementation status

Cydia is an optional graphical frontend for the selected distribution's APT
and dpkg environment. Installed, working, supported distribution components
take precedence over Cydia's private recovery components. Installing or
removing Cydia must not replace those components, their configuration, sources,
keyrings, or package database. No distribution is identified from a repository
hostname or assumed to be the default. The package ID remains `cydia`;
legacy package-owned file migrations remain maintscript responsibilities.

This document specifies the target architecture. Provider selection is not
implemented yet. Currently APT 2.7.9 is statically linked into the application
and privileged helper, dpkg is external, and Cydia directly links Apple's
system `libicucore`. The ICU compatibility headers contain declarations, not
an embedded ICU implementation. Bundled APT also disables gettext through
`apt-extra/apti18n.h`.

| Area | Current implementation | Required behavior |
| --- | --- | --- |
| APT | The facade always constructs the embedded backend | Prefer a validated distribution provider; keep the bundled provider available for recovery |
| Repository policy | Cydia's default Warning mode overwrites APT security options | Inherit distribution enforcement by default; preserve explicit administrator overrides |
| Other APT settings | Startup forces expiration checking off and supplies acquisition defaults | Preserve effective distribution configuration; distinguish absent defaults from explicit overrides |
| Source checks | Preflight runs bundled APT | Check with the same selected provider and policy used for refresh and transactions |
| dpkg | Selected external tools and protected runtime paths | Retain external dpkg and its policies; extend validation to the selected APT provider |
| ICU | Direct calls into Apple system ICU | Prefer compatible bootstrap ICU for Cydia-owned services, then Apple ICU, then a private bundled fallback |
| Messages | Locale conversion exists; bundled APT stubs gettext | Use each provider's own gettext and catalogs; bundle localization support with the recovery backend |
| Failure handling | No APT provider transition | Diagnose provider failure separately from repository, configuration, dependency, and lock errors |

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

Default enforcement is **Use distribution settings**. Preserve the provider's
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
from a saved choice: migrate absence to inheritance and retain explicitly
saved choices. Apply an override through supported provider controls, show its
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

## Delivery order and compatibility gates

1. Distinguish stored choices from defaults and stop unconditional overrides
   of effective configuration. Add provider identity/capability models without
   silently changing engines. Full inheritance of compiled distribution
   behavior requires the external adapters in step 3.
2. Put the existing bundled backend behind the worker protocol. Preserve
   transaction previews, multiarch, locks, state updates, source checks and
   existing bootstrap protections before adding a second implementation.
3. Add external-provider adapters with representative strict and permissive
   distribution behavior. Prefer external only when the required operation is
   supported, and expose unsupported-provider cases honestly. Missing
   capabilities in a healthy provider require an explicit compatibility or
   recovery choice, not silent substitution of the bundled provider.
4. Implement recovery transitions, dependency isolation and bundled gettext.
   Verify failure handling before, during and after an interrupted transaction.
5. Add the ICU adapter and private fallback independently; verify regex,
   transliteration, locale conversion and section/sort consistency.
6. Complete Settings explanations and all existing UI locales, package checks,
   and narrowly scoped rooted/rootless runtime acceptance where necessary.

Potential behavior changes include distribution-specific dependency solutions
and security decisions, restored expiry checking when the distribution enables
it, localized upstream errors, different Unicode sorting, larger private
recovery payloads, and queue invalidation after provider changes. Do not erase
saved user overrides or silently replace distribution policy during migration.

Acceptance must include healthy external preference; missing, unloadable and
unsupported providers as distinct cases; provider updates between review and
execution; exact-plan/multiarch/hold/pin behavior; one real lock owner; hook and
automatic-state parity; source preflight parity; no fallback on ordinary repo
or resolver errors; unchanged bootstrap files on install/removal; working
recovery without external APT/ICU dependencies; and upstream message catalogs
without localized prose controlling execution.

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
