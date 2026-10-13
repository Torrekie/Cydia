# APT providers and dpkg compatibility

Cydia's target scope is an optional frontend for the selected distribution's
package-management environment. A working, supported bootstrap APT takes
precedence over the bundled recovery implementation; its policies must remain
authoritative unless the administrator explicitly overrides them. The
[runtime provider design](runtime-providers.md) records the required migration,
policy precedence, recovery boundaries, Remorix packaging/localization,
commercial-repository integration, and staged acceptance criteria.

Automatic startup selects a validated registered external APT worker before
the private recovery worker. An ordinary installed APT package without a
supported adapter is not a registered provider. The transitional in-process
backend remains when the private recovery payload is unavailable. Bundled
APT must remain reproducible from a reviewed source revision, and dpkg
integration must tolerate supported runtime implementations without linking
against dpkg's private C library. Cydia-owned ICU services prefer a validated
bootstrap ICU, then Apple's `libicucore`; UIKit collation remains Apple-owned.
The private fallback loader requires separately supplied ICU/data binaries.
Embedded APT packages its matching upstream catalogs and uses a protected
bootstrap libintl when available, with optional private libintl fallback.
dpkg remains external; neither provider selection nor recovery replaces it.

## Adding and editing sources

Sources keeps its URL alert, with **Add Source**, **Advanced…**, and **Cancel**.
An ordinary flat source is checked and saved without a separate generic review
screen. An unsigned source under the current Cydia-default Warning policy
requires an explicit warning acknowledgment. Advanced opens a native form; cancelling it
returns to the original URL draft. Repository editing remains in Settings.

| Operation | Behavior |
| --- | --- |
| Structured draft | Inline URL, suite (flat default `./`) and components (flat default empty), APT architecture filters and an editable save filename; source-code indexes remain deferred |
| Imported definition | Original `.list` or Deb822 bytes remain intact until explicitly converted to fields; unsupported options, comments and multiple values remain editable as raw text |
| Find Repository Options | Follows bounded, same-origin published directory links and reads Release metadata; retains nested suite paths and offers only advertised components |
| Architecture selection | Inherits effective APT settings by default; filtering indexes does not register a dpkg architecture or change the eligibility of `Architecture: all` |
| Source check | Routes through the selected backend/session; recovery isolates temporary source/list configuration without update hooks or shared-cache changes; cancellation removes its temporary files |
| Save destination | A collision-safe new file in APT's effective source directory; Advanced can choose an eligible existing file of the same format |
| Signing key | Finds candidates in permitted key files, installed keyring packages, publisher links, signature-guided keyserver results, or suitable packages already available from configured sources |
| Trust approval | Shows provenance and full fingerprints, checks an actual repository signature, then requires **Trust Key and Save**; the key is scoped using `Signed-By` |
| Installed keyring | References a verified package-owned key file so package updates can rotate keys; downloaded package candidates are inspected without installation or maintscript execution |
| Save disabled | Stores a source without enabling acquisition or granting new key trust |

Published metadata and keyserver responses are discovery hints, not publisher
identity proofs. Discovery never guesses a distribution suite from the OS
version, registers an architecture, adds a distribution source, installs a
package, or grants trust. Hidden directory listings and unavailable key data
retain manual entry/import as the fallback. Local key generation cannot replace
a missing publisher public key.

An unsaved repository-security preference inherits an accepted external
provider's distribution policy. Recovery retains Cydia's Warning default;
saved Allow/Warning/Error choices remain explicit overrides. Invalid signatures,
hash mismatches and known authenticated-to-unsigned transitions cannot silently
be treated as ordinary unsigned sources. A selected candidate key must
authenticate the checked source even under Allow or Warning. Package archive
layout validation remains a separate installation gate.

Source changes use fresh file and protection-policy snapshots plus a protected
runtime snapshot checked at commit. A changed APT configuration, source file,
keyring, tool, or protected distribution selection requires another review.
Neither the editor nor external `cydia://`/legacy bridge drafts bypass native
approval. No source registry is reconstructed from Cydia preferences, and no
default distribution repository is assumed.

The source-draft, published-directory discovery, source-commit, key-import and
process-runner checks have focused host targets. The native APT policy CI also
runs real acquisition/isolation fixtures for source preflight and real GnuPG
signature verification. New source-editor text uses the existing 21-locale
baseline.

## Reproducible baseline

The current baseline is recorded in [`mk/apt.mk`](../mk/apt.mk):

| Input | Recorded value |
| --- | --- |
| Source directory | apt64 gitlink |
| Commit | 0c7c5febb3308fc194b79fe1d2a054c80a321a77 |
| Upstream base | ed053de346d92c1a4218a7b80a20158f3535fe2a |
| Source URL | https://salsa.debian.org/apt-team/apt.git |
| Embedded version | 2.7.9 |
| Required C++ level | 17 |
| libapt-pkg version triplet | 6.0.0 |
| ABI/SOVERSION | 6.0 / 6 |
| Provenance trust | legacy-unverified |

The upstream base is the APT 2.7.9 release commit. Ten local commits are
tracked as mail patches in
[`apt-extra/apt-2.7.9-cydia.patch`](../apt-extra/apt-2.7.9-cydia.patch). They add
Deb822 source-file mtime coverage, typed repository authentication and cached
metadata validation, a protected lock-file opener, deferred shared automatic
package state, and current frontend proof for cached repository trust. The
series also tests changed metadata and clears stale cached signatures after an
allowed unsigned refresh. An absent frontend policy retains upstream behavior.
Dynamic cache teardown also matches the backing allocation: heap fallback
storage uses `free`, while anonymous mappings use `munmap`. This preserves
Darwin allocator bookkeeping when a growable cache uses `calloc`/`realloc`.
The native APT fixture covers heap, mapped, and grown heap cache disposal.

[`scripts/checkout-apt-source.sh`](../scripts/checkout-apt-source.sh) fetches the
exact public base and replays the recorded identities and dates to regenerate
the exact committed gitlink. It checks the resulting commit, clean checkout
and Git object integrity. If Salsa's transport is unavailable, it fetches the
same base from Debian's HTTPS GitHub mirror. It never substitutes a floating
branch or the inherited APT 1.8.2 fork.

For a fresh clone without initialized submodules, run:

~~~sh
scripts/checkout-apt-source.sh
git submodule update --init libiosexec xxhash
~~~

An existing clean checkout at the recorded APT commit is retained. The helper
refuses to replace a different existing checkout or local changes. CI also
initializes the pinned xxHash 0.8.2 submodule used by APT's header-only XXH3.

No signed upstream tag or signer fingerprint has been verified for this
baseline, so the manifest deliberately retains `legacy-unverified`. Matching
the pinned commit does not upgrade that trust claim. A separate untracked
source archive or working directory is not an acceptable replacement for the
gitlink. Updates must review the upstream revision and iOS/Darwin delta.

make verify-apt checks that:

- the gitlink and checked-out commit match;
- the submodule URL, embedded version, and ABI match the manifest;
- the checkout is clean and its license inputs are present;
- every compiled APT source is explicitly listed; and
- new, removed, or accidentally included source files require manifest review.

These checks prove that the local build matches the recorded legacy input;
they do not retroactively authenticate that input.

The application still uses the existing Makefile graph. The upstream CMake
files are metadata inputs only and are not a Cydia build entry point.
APT compatibility include roots are generated inside `BUILD_DIR` from
`APT_SOURCE_DIR`; legacy repository symlinks cannot silently supply headers to
an audit of another tree.

## Update policy

The first release-candidate update from this legacy baseline must record an
authoritative HTTPS source, signed tag, signer fingerprint, and a verification
step that validates the tag before `APT_SOURCE_TRUST` can change. Release
builds then pin that exact reviewed tag and commit. They never fetch a floating
branch during make. Compatibility work uses two lanes:

1. a reviewed, compatible signed stable APT release, which is release-blocking; and
2. upstream main as an early-warning canary, which is never shipped unpinned.

The runtime currently embeds APT: the reviewed `apt64` sources are compiled
into `libapt64.a` and force-loaded into `MobileCydia`. `dpkg` is intentionally
not embedded; package transactions still go through the configured `cydo`
runner and a device `dpkg` executable. That runner and its filesystem policy
are centralized so an APT update does not require changing UI code or assuming
one bootstrap layout.

`CydiaRuntime::PackageDatabasePaths` supplies installation defaults for rooted
and rootless packages. A running installed app or helper selects its layout by
matching its canonical executable path to the package's installed paths.
Neither `CYDIA_PACKAGE_LAYOUT` nor the presence of another package database can
override that match. For an executable outside those installed locations, the
general path policy retains an explicit environment override and then a
bootstrap-presence fallback for fixtures and legacy callers. The privileged
`cydo` entry point separately requires its own canonical installed helper path;
it does not authorize a layout from the caller's environment.

These defaults locate Cydia's app, helper and private state; they do not freeze
the bootstrap's effective APT environment. APT initialization preserves
`APT_CONFIG`, `apt.conf`, `RootDir`, source-list and source-parts settings,
configured lists and shared `extended_states`, and trusted-keyring locations.
Paths are resolved through APT rather than mechanically prefixed with
`/var/jb`. A contradictory `RootDir` with paths already rooted beneath it is
rejected instead of applying the root twice.

The configured dpkg executable, status-derived administration directory, root
and `DPkg::Options` remain part of the runtime descriptor. Native and foreign
architectures are queried from the selected dpkg; an explicit
`APT::Architectures` list retains the bootstrap's acquisition policy. A
contradictory dpkg administration directory or an unsupported dpkg chroot
disables mutations with an actionable error. Advanced Settings can override
the supported external tools (`dpkg`, `dpkg-query`, `dpkg-deb`, `uicache`,
`apt-key`, `gpgv` and `gpg`) through a protected Cydia-owned configuration file.
Override targets must pass executable and ownership checks.

The dpkg registration list and APT acquisition list have separate roles.
Cache reloads requery dpkg's native and foreign architectures without changing
either registration or source architecture options. A failed query disables
package changes; the previous verified acquisition state remains available
for browsing. Changes to dpkg's architecture file invalidate a reviewed queue.
Downloading an architecture's indexes does not authorize installing it.

An unqualified package link selects only native or `all` versions. A concrete
qualifier selects that actual version architecture, even when APT stores
native and `all` versions in the same bucket. The user-facing `:any` selector
requires an unambiguous eligible variant or an explicit choice; dependency
`:any`, `Multi-Arch`, versioned `Provides` and alternatives are evaluated by
APT in their original dependency context. Version actions match the full
Debian version, including its epoch, and architecture. Multiarch views show
native, additional and architecture-independent captions; ordinary singlearch
views retain their historical appearance. Unsupported installed packages
remain inspectable and removable subject to existing package protections.

Package layout is checked independently of architecture and repository
membership. The installed Cydia layout supplies the default payload prefix.
Distributions using a different prefix can declare
`Cydia::Package-Install-Prefix` as an absolute path in their protected APT
configuration. If the configured dpkg installation root already contains that
prefix, archive paths are checked relative to that root. Custom executable or
administration-directory locations do not imply a different payload layout.

Every downloaded or cached archive is associated with its exact planned APT
version. Before dpkg starts, Cydia verifies its Package, Version and Architecture
fields and inspects bounded archive paths and links. Demonstrated layout
mismatches, invalid archives, incomplete inspection and inconsistent identities
stop the transaction, including when the affected archive is a dependency.
Valid prefixed `all` packages, structural directories and shared user files
are supported. Maintainer scripts and uncertain shared destinations remain
explicitly unverified and produce a warning after complete inspection; this
check does not establish script safety. No package conversion, architecture
rewriting or custom publisher field is required.

Some package distributions place a protected dpkg database below root-owned
directories that are writable by an administrator group. During installation,
the root maintscript initializes Cydia's private database-access policy from
`DPKG_ADMINDIR`, or the verified installed control-file location on older dpkg.
Normal first use needs no manual Settings approval. The setup accepts existing
root-owned, non-world-writable ancestor groups and binds their exact namespace
and permissions, without changing bootstrap permissions or group membership.
It creates policies only when absent, preserving existing approvals, explicit
revocation and administrator configuration. An unsafe database produces an
installer diagnostic and remains unavailable for privileged operations.
Advanced Settings → Distribution Database Access provides status, review and
revocation when subsequent configuration changes need troubleshooting.

The root-protected `admin-access.conf` records the installer-selected path,
canonical database and ancestor identities, owners, groups and permission
modes. An independently protected APT alias may resolve to the identical
database without adding writable ancestry. Both the installer route and the
current runtime namespace are rechecked for every operation. Darwin extended
ACLs are also bound to the review; ACL entries granting access to additional
principals cannot be enrolled. Replacing a directory or alias, selecting a
different database, or changing permissions requires a new review. Ordinary
lock/journal changes do not invalidate enrollment. Approval applies only to
the selected administration namespace, shared locks and package-state reads;
tools, hooks, APT configuration, keyrings, source writers and the private policy
retain strict ancestry checks. World-writable or non-root-owned ancestors and
a group-writable final administration directory cannot be enrolled. Revocation
remains available independently of database resolution and restores strict
access. Installation-time enrollment inherits the distribution installer’s trust in
these administrator groups; explicit review is also available. It is not protection
against a malicious member of an approved group or a replacement racing a
root operation. Existing bootstrap configurations are preserved.

Data-only dpkg status/journal records, APT automatic-package state and accepted
preference files may retain another frontend's owner or group. Cydia reads
single-link regular files through protected root-owned parent directories,
refuses symlink leaves, set-id or world-writable files, and binds snapshot
evidence to both the descriptor and pathname. State changes invalidate review.
Automatic/manual flag writes preserve the existing owner, group, ordinary
permissions, ACLs and attributes, under the shared frontend lock and a stale
state check. An uncooperative writer can still race between the final check and
replacement. This data policy does not authorize APT hooks, executable paths,
trust keyrings or Cydia's private configuration; those retain strict checks.

Protected root-owned source-file aliases may delegate repository data to an
external frontend's publicly readable cache, including a user-owned cache.
The reader verifies access under the original caller's UID/GID and exact
supplementary group list, including
directory traversal and ACLs, and binds the alias, canonical target and bytes
to the review snapshot. These files are read-only in Cydia: their definitions
remain visible and usable for bootstrap protection, while other regular
source files remain editable. Cydia does not replace the link or edit through
it. Unsafe or malformed delegated inputs still block mutation review.

`make verify-package-paths`, `verify-apt-runtime` and
`verify-apt-source-isolation` cover installation defaults and runtime
configuration independently.

`make verify-apt-api` syntax-checks Cydia's private adapter against the pinned
tree. A pre-fetched clean stable or main checkout can be tested without changing
the gitlink and without allowing Make to access the network:

~~~sh
make verify-apt-api \
  APT_AUDIT_SOURCE_DIR=/path/to/apt \
  APT_AUDIT_CXX_STANDARD=c++2b
~~~

The C++ standard is an APT-source property; app-owned Objective-C++ remains on
its existing standard until raw APT headers have been removed from that file.

An APT source update is split into reviewable commits:

1. update the gitlink and provenance values;
2. refresh the explicit source manifest;
3. refresh the minimal guarded Darwin/iPhoneOS patch set;
4. adapt only the private APT backend; and
5. run the affected package-manager fixtures and compile checks, then any
   targeted simulator or physical-device checks needed to prove behavior that
   those checks cannot establish.

Changing the APT ABI requires rebuilding every Cydia reverse dependency. A
source import and an application behavior change must not be hidden in the same
commit.

## Compatibility boundary

The implemented boundary keeps APT embedded but removes APT types from UI and
model-facing headers. It is the starting point for the planned provider
migration, not an external-provider implementation. Cydia-owned package,
source, transaction, progress, and error values cross the backend boundary
today. `AptBackend.hpp` is a façade over the private
`AptBackendInternal.hpp` storage; acquire status uses the opaque
`DatabaseStatus` façade. Raw cache iterators and acquisition objects remain
private to the APT adapter and cannot outlive its cache generation.

dpkg remains external. `DpkgRunner` resolves its executable, constructs an
argument vector without shell interpolation, preserves status-fd descriptors,
and reports launch/exit/signal results rather than linking libdpkg.a or
matching localized error text. Future dpkg capability probes belong in this
runner boundary; controllers must not grow version-specific CLI logic.

Cydia marks a package as upgradable only when the repository candidate is
strictly newer than the installed version under Debian's dpkg ordering. The
comparison uses the selected APT versioning system (`debVS` for Debian
packages), so epochs, Debian revisions, and tilde pre-releases agree with
`dpkg --compare-versions`. Equal or older candidates are not upgrade badges;
an explicit downgrade remains a separate transaction decision.

The privileged helper independently reloads the protected APT configuration,
validates its configuration and executable graph, and compares the resolved
environment with the app's request. Caller-provided paths do not grant access
to a different database. Typed requests carry runtime evidence that is
rechecked before protected operations. Ordinary dpkg argument vectors are
validated against that environment, including configured hooks, before the
helper runs the selected external dpkg with a sanitized environment.

The mobile app owns APT's `fcntl` locks. When APT needs the protected dpkg
`lock` or `lock-frontend` file, `cydo` opens the validated file and transfers
its descriptor over a Unix socket with `SCM_RIGHTS`; the app then acquires the
lock itself. A short-lived helper is not used as a substitute lock owner.
Protected shared-state requests require the calling app to own the selected
frontend lock. Other helper-managed mutations acquire that frontend lock and
reject a competing package manager rather than deleting its lock file.

APT's automatic-state write is deferred until a package transaction completes.
The helper merges only the requested package/architecture flag changes into
the configured shared `extended_states`, preserving unrelated records and
fields. It checks the original state bytes and dpkg status again, then replaces
the state file atomically against its captured identity. A stale or concurrent
change fails without overwriting another frontend's work. Marking a package
automatic requires it to be fully installed; clearing an existing automatic
flag is also supported for removals.

## Acceptance

Every compatibility change retains:

- the existing Makefile as the only project build system;
- ARC for all Objective-C and Objective-C++ sources;
- arm64 and an iOS 12.0 minimum deployment target;
- the existing simulator build;
- the app-owned source-size gate; and
- reviewable commits with a coherent compatibility change.

The baseline verification sequence is:

~~~sh
make verify-apt
make verify-apt-compile
make verify-dpkg-runner
make verify-apt-runtime verify-apt-source-isolation
make verify-privileged-runtime verify-privileged-client
make verify-extended-state verify-runtime-snapshot verify-runtime-access
make verify
make build/bin/MobileCydia
make --no-print-directory -B -j6 doIA=yes \
  BUILD_DIR=/tmp/cydia-simulator-build \
  /tmp/cydia-simulator-build/bin/MobileCydia
~~~

Use the fixtures and targets relevant to the change. Simulator compile
coverage does not establish jailbroken process authentication or protected
filesystem access. Physical-device checks are needed only where that runtime
behavior cannot be established by the host fixtures; select the rooted or
rootless installation and form factor required by the change. Record actual
observations separately from source-level conclusions, without treating a
full device matrix as a prerequisite for every compatibility edit.

## Embedded APT helper execution and TLS

Verifier defaults follow the selected native dpkg executable directory;
protected APT configuration and Advanced Settings overrides take precedence.
The embedded APT processes use the existing static script-execution fallback
and the loaded `DPkg::Path`, so rootless interpreters and command dependencies
remain discoverable. No compatibility dylib or shell wrapper is installed.
External compression tools are discovered through the same native search path
before APT selects its codecs and arguments. Explicit compressor paths and
options in APT configuration retain precedence.

The iOS HTTPS backend uses SecureTransport’s automatic system trust. Custom
`CaInfo`, client-certificate and CRL files are currently unsupported and fail
explicitly, instead of appearing to load while being ignored. Signature policy
remains independent of TLS: Allow/Warning can accept unsigned repositories
while normal HTTPS certificate validation remains enabled.

The SecureTransport adapter retains partially transferred application bytes,
reports incomplete socket operations as retryable, and waits for the required
read or write direction. Buffered decrypted bytes remain available without
waiting for another socket event. TLS errors include the native status code.

Capability previews preserve existing provider identities from older
generators, including legacy names containing underscores. These identities
are read-only: new or updated generated packages still require standard
lowercase package names. Previewing capabilities never renames or removes
another generator's providers.
Capability previews recognize legacy `gsc.*` underscore spellings as existing
providers through read-only lookup aliases, preventing duplicate generation.
APT continues to resolve dependencies from the unchanged dpkg names and
`Provides` fields. If multiple providers already exist, all remain preserved.

The maintscript also initializes an absent source-protection policy with an
empty selection. No official distribution source is inferred. Existing
selections and invalid policies remain untouched; editing through delegated
source-file links retains its separate read-only boundary.

On rootful upgrades, the maintscript recognizes Cydia's historical
`cydia.list` link to the mobile account's private Cydia source cache. When the
alias, cache and administrator metadata can be verified, it replaces only that
link with an administrator-owned regular file containing the exact existing
bytes. The original cache remains intact. This makes those existing definitions
manageable through ordinary APT source operations without reintroducing a
private repository registry or a default repository list. Foreign package
ownership, diversions, other managers' aliases and unsafe objects prevent this
optional migration; Cydia reports the refusal and preserves the existing alias.
Rootless aliases retain their existing read-only policy.

The old source handoff could disable `cydia.list` during an upgrade when another
source document existed. Current maintscripts preserve shared source files.
Historical disabled backups are not automatically reactivated: they may contain
repositories deliberately removed by the administrator. The narrowly verified
sole-source recovery remains separate from the cache-alias migration.

The Sources page retains source-list read failures and provides localized
diagnostic and repository-settings links after the initial error is dismissed.
A valid empty source configuration continues to display normally. Missing
downloaded indexes affect package availability, but configured source documents
are still represented independently of those indexes.
