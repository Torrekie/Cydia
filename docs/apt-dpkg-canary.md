# APT/dpkg compatibility canary

Cydia has two deliberately different package-runtime boundaries:

- `apt64` is the shipped, statically embedded APT implementation. The
  gitlink is a reviewed starting point, currently the custom
  `e4718f05d049c1a09fb9662cc3db2d4c5122defe` tree (version 1.8.2, ABI 5.0.2,
  C++11, legacy-unverified provenance).
- `dpkg` is never linked into the application. The device supplies the
  executable; native Cydia code invokes it through the shell-free `cydo`/
  `DpkgRunner` boundary, and bootstrap scripts use the same selected helper
  paths. Cydia does not depend on dpkg's private C library ABI.

`make verify-apt-api` compiles the reviewed Cydia compatibility surface against
a separately fetched, clean checkout. It does not fetch, replace, or relink
the embedded tree. The current canary evidence covers the pinned ABI 5/C++11
tree and a clean upstream-main ABI 7/C++23 checkout. The canary is an early
warning lane: a passing syntax check is necessary evidence for an APT update,
not a claim that an unreviewed tree is shippable.

## Backend boundary

`Cydia/AptBackend.hpp` is the public, Cydia-owned façade. Its implementation
storage and all libapt-pkg headers live in `AptBackendInternal.hpp` and the
backend translation units. `Database` consumes only Cydia-owned records,
source snapshots, transaction results, cache summaries, fetch failures, and
error values. Acquire status callbacks use the opaque
`DatabaseStatus` façade; their raw `pkgAcquireStatus` subclasses are private
to `DatabaseStatus.mm`.

Version-sensitive calls are declared in `AptCompatibilityInternal.hpp` and
implemented in `AptCompatibility.cpp`. Public model/controller headers do not
include `apt-pkg` and do not expose cache iterators, map pointers, records, or
acquire items. A database reload creates one backend-owned epoch; opaque
`PackageHandle` and `SourceHandle` values are valid only for that epoch.

The remaining raw APT code is intentionally limited to these internal files:

| Boundary | Responsibility |
| --- | --- |
| `AptBackend*.{cpp,hpp}` | cache, records, resolver, source list, acquire, locks, and package-manager lifetimes |
| `AptCompatibility*.{cpp,hpp}` | version-gated API calls and stable DTO construction |
| `AptRuntime.cpp` | process-wide APT configuration and initialization |
| `DatabaseStatus*.{mm,hpp}` | acquire callback adapters and progress translation |

The source manifest in `mk/apt.mk` lists every Cydia translation unit that
depends on this boundary. The verifier rejects a new or moved APT consumer
until it is explicitly reviewed.

## Update order

An APT update is split into small, independently testable commits:

1. update the gitlink and provenance values;
2. refresh the explicit APT source manifest;
3. add or refresh only the guarded Darwin/iPhoneOS compatibility code;
4. adapt `AptCompatibility`/`AptBackend` while keeping DTOs stable; and
5. run the pinned tree, newest reviewed stable tree, upstream-main canary,
   device/simulator links, and rooted/rootless package fixtures.

The release lane must use an exact reviewed commit. The canary lane may use a
pre-fetched upstream checkout, but Make never fetches a floating branch. A
future signed lane must verify an annotated tag, its signer fingerprint, and
the peeled commit before changing `APT_SOURCE_TRUST`; ancestry to a signed
ancestor does not authenticate a fork delta.

## dpkg and filesystem policy

`PackageDatabasePaths` selects rootful or rootless state as one immutable
layout before the first database access. `DpkgRunner` owns argv construction,
status-fd inheritance, stdin/stdout redirection, and exit-status reporting.
No Cydia controller assembles `/var/lib`, `/var/jb`, `/etc/apt`, or a shell
command line. CLI behavior is intentionally delegated to the installed dpkg;
future dpkg changes therefore require adapter/fixture updates rather than a
new embedded dpkg ABI.

Use `CYDIA_PACKAGE_LAYOUT=rootful` or `rootless` when both databases are
present. `make verify-package-paths` exercises both deterministic layouts and
rejects package-info/helper path traversal. Package fixtures must be built in
both modes:

```sh
make --no-print-directory -B -j6 PACKAGE_LAYOUT=rootful package
make --no-print-directory -B -j6 PACKAGE_LAYOUT=rootless package
```

## Acceptance gates

For a pinned embedded tree:

```sh
make verify-apt
make verify-apt-compile
make verify
make build/bin/MobileCydia
make --no-print-directory -B -j6 doIA=yes \
  BUILD_DIR=/tmp/cydia-simulator-build \
  /tmp/cydia-simulator-build/bin/MobileCydia
```

For a pre-fetched upstream canary:

```sh
make verify-apt-api \
  APT_AUDIT_SOURCE_DIR=/path/to/clean/apt \
  APT_AUDIT_CXX_STANDARD=c++2b
```

The canary must not be mistaken for a runtime test of the embedded archive;
the release gates above remain mandatory before moving the gitlink.
