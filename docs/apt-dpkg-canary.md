# APT/dpkg compatibility canary

The embedded runtime and the update canary intentionally have different
responsibilities:

- `apt64` at the pinned gitlink is the shipped, statically embedded APT
  implementation. It is currently an old, custom, legacy-unverified fork.
- `make verify-apt-api` compiles the Cydia-owned compatibility adapter against
  a separately fetched, clean APT checkout. It does not fetch or replace the
  embedded tree.
- `dpkg` remains an external device executable. Cydia launches it through the
  shell-free `cydo` runner and selects rooted/rootless paths before database
  access.

The source-compatibility canary currently passes the pinned ABI 5/C++11 tree
and a clean upstream-main ABI 7/C++23 checkout. The compatibility boundary
absorbs archive cleanup, upgrade minimization, resolver execution,
package-manager progress, package-record fields/tags, and content
fingerprinting. All current app-owned C++/Objective-C++ translation units
syntax-check against that upstream-main checkout.

That result is deliberately narrower than an APT update: the canary does not
replace, link, or run the embedded tree. The UI/model layer still exposes raw
APT iterators and cache lifetimes, so those objects must move behind
`AptBackend` before the gitlink can advance safely.

`Cydia/AptBackend` is now the owner of one database epoch's mutable cache,
record, resolver, acquire, lock, package-manager, and source-list handles.
`Database` remains the Objective-C façade for this transition. Its raw handle
accessors now live in the explicitly private `DatabaseApt.h` category instead
of the public database API; replacing that category with DTO queries is the
next migration seam. `Database.h` itself no longer imports `apt-pkg`; the
acquire status adapters that still require those headers live in the private
`DatabaseStatus.h` boundary.

| Area | Legacy dependency | Backend migration seam |
| --- | --- | --- |
| package records | backend snapshots fields/tags/descriptions into `PackageRecordData`; lookup still receives a short-lived opaque iterator handle | replace the handle with a backend-owned package/version key |
| package cache | backend snapshots package state and owns clear/install/remove mutations; calls still pass short-lived iterator addresses | replace iterator addresses with backend-owned package/version keys |
| archive cleanup | old `pkgArchiveCleaner::Erase` virtual signature | `AptArchiveCleaner` adapter with version-gated implementation |
| package manager setup | direct `pkgSystem::CreatePM` and `pkgCacheFile` assumptions | `AptBackend` owns initialization and transaction handles |
| policy/upgrade | policy comparisons and cache mutation still occur outside the adapter | backend methods returning Cydia result enums |
| source/update flow | raw acquire/source-list objects in UI callbacks | backend progress events and source DTOs |

## Migration order

1. Keep the current adapter and provenance gates green for the pinned tree and
   the canary tree.
2. Introduce `AptBackend` as the only owner of APT headers and lifetime. Move
   package records, cache queries, source lists, and transaction operations
   behind Cydia-owned DTOs; no controller or public model header should include
   `apt-pkg`.
3. Add narrowly version-gated implementations for cache/record access,
   archive cleanup, policy, and package-manager creation. Each implementation
   is compiled in a separate translation unit and tested against both lanes.
4. Keep filesystem policy in `PackageDatabasePaths` and process construction in
   `DpkgRunner`. APT configuration receives resolved paths; UI code never
   assembles `/var/lib`, `/etc/apt`, or dpkg command strings.
5. Run the device and simulator Make graph plus package-manager fixtures for a
   pinned release, the newest reviewed stable release, and upstream-main. A
   canary failure blocks an APT update but never silently changes the shipped
   gitlink.

The target is rolling compatibility with reviewed APT/dpkg releases, not a
promise that one frozen ABI can accept arbitrary future headers. Every APT ABI
or documented API change must be absorbed in the backend seam and accompanied
by a new canary result.
