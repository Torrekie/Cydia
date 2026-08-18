# Embedded APT and dpkg compatibility

Cydia intentionally embeds APT and executes dpkg as an external program. The
application must be rebuildable from one reviewed APT source revision, while
the dpkg integration must tolerate newer runtime implementations without
linking against dpkg's private C library.

## Reproducible baseline

The current baseline is recorded in mk/apt.mk:

| Input | Recorded value |
| --- | --- |
| Source directory | apt64 gitlink |
| Commit | e4718f05d049c1a09fb9662cc3db2d4c5122defe |
| Source URL | git://git.bingner.com/apt.git |
| Embedded version | 1.8.2 |
| Required C++ level | 11 |
| libapt-pkg version triplet | 5.0.2 |
| ABI/SOVERSION | 5.0 / 5 |
| Provenance trust | legacy-unverified |

This records the inherited starting point; it is not a claim that the old fork
is the desired long-term version or that its unauthenticated `git://` origin
proves source authenticity. No signed upstream tag or signer fingerprint was
recorded for this inherited commit, so the manifest deliberately labels it
`legacy-unverified`. A separate untracked source archive or working directory
is not an acceptable replacement for the gitlink. An update must identify an
authoritative upstream commit and review the iOS/Darwin delta explicitly.

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

`CydiaRuntime::PackageDatabasePaths` now selects a complete package-database layout
before the first database access. Rootful paths remain under `/var/lib`; a
rootless bootstrap uses `/var/jb/var/lib` and its matching `cydo`/`dpkg`
helpers. APT configuration and source-list paths follow `/etc/apt` or
`/var/jb/etc/apt` from the same selection. Set
`CYDIA_PACKAGE_LAYOUT=rootful` or `rootless` in a launcher when a device
intentionally keeps both databases; automatic detection only selects rootless
when its database and helper are present. `make verify-package-paths` exercises
both deterministic layouts and rejects package/helper path traversal.

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
5. run the complete device, simulator, and package-manager fixtures.

Changing the APT ABI requires rebuilding every Cydia reverse dependency. A
source import and an application behavior change must not be hidden in the same
commit.

## Compatibility boundary

The migration keeps APT embedded but removes APT types from UI and model-facing
headers. Cydia-owned package, source, transaction, progress, and error values
cross the backend boundary today. `AptBackend.hpp` is a façade over the private
`AptBackendInternal.hpp` storage; acquire status uses the opaque
`DatabaseStatus` façade. Raw cache iterators and acquisition objects remain
private to the APT adapter and cannot outlive its cache generation.

dpkg remains external. `DpkgRunner` resolves its executable, constructs an
argument vector without shell interpolation, preserves status-fd descriptors,
and reports launch/exit/signal results rather than linking libdpkg.a or
matching localized error text. Future dpkg capability probes belong in this
runner boundary; controllers must not grow version-specific CLI logic.

All APT, dpkg, cache, state, lock, helper, and package-database paths are
provided by one environment policy. Rooted and rootless layouts are selected
explicitly; paths are not converted by blindly prefixing /var/jb. Native Cydia
operations and bootstrap helpers now use that policy; remaining path literals
are limited to the policy implementation and documented legacy user-data
locations.

## Acceptance

Every compatibility change retains:

- the existing Makefile as the only project build system;
- ARC for all Objective-C and Objective-C++ sources;
- arm64 and an iOS 12.0 minimum deployment target;
- the existing simulator build;
- the app-owned source-size gate; and
- small commits and pull requests with one semantic migration each.

The baseline verification sequence is:

~~~sh
make verify-apt
make verify-apt-compile
make verify
make build/bin/MobileCydia
make --no-print-directory -B -j6 doIA=yes \
  BUILD_DIR=/tmp/cydia-simulator-build \
  /tmp/cydia-simulator-build/bin/MobileCydia
~~~
