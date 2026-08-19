# Cydia modernization

The project deliberately remains Makefile-based. No Xcode project or additional
build system is required: `make all`, `make package`, and the existing helper
targets continue to be the build interface.

## Structure

App-owned code is organized by domain under `Cydia/`:

- database/status and progress services (`Database*`, `Progress*`)
- package models and views (`Package*`, `PackageViews`)
- browsing and feature controllers (`PackageControllers`, `SectionControllers`,
  `ChangeControllers`, `PackageFeatureControllers`, `SourceControllers`)
- navigation and web integration (`TabBarController`, `URLProtocol`,
  `CydiaWebViewController`, `URLHelpers`)
- application lifecycle categories (`Application+Data`, `+Navigation`,
  `+Operations`, `+Lifecycle`) with a small bootstrap in `MobileCydia.mm`
- runtime/private-service adapters (`PrivateServices`, `LockdownServices`)

`CyteKit/` and `Menes/` remain reusable framework/support layers. `apt64/`
remains a pinned submodule, while the Cydia-maintained ARC/iOS 12
`SDURLCache/` runtime sources are vendored directly because their historical
gitlink is not published by the external mirror. Both are compiled by the
existing Make graph but are not forced into the app-owned module-size policy.

The embedded APT gitlink, ABI, licenses, and reviewed source groups are recorded
in `mk/apt.mk`. The update and backend-boundary policy is documented in
`docs/apt-dpkg-compatibility.md`; current canary blockers and migration order
are tracked in `docs/apt-dpkg-canary.md`.

## Compatibility contract

- Minimum deployment target: iOS 12.0.
- Device architecture: arm64. The existing simulator path remains x86_64.
- Supported Objective-C and Objective-C++ sources compile with ARC; no source
  uses explicit retain/release/autorelease ownership or an MRC conditional.
- Former `_transient` fields now state their intent explicitly: delegates and
  database back-references are `__weak`, application owners are strong, and
  active requests/cache values retain their objects.
- Private SpringBoard/Lockdown entry points are resolved at runtime, allowing
  current public SDKs to link while preserving jailbreak-runtime behavior.
- ICU headers use `ICU_SDK` when available (defaulting to
  `~/iPhoneOS14.5.sdk`) and fall back to the host macOS SDK.

## Verification

`make verify-apt` checks the recorded embedded APT input and explicit source
manifest before an upstream update can enter the build. The inherited baseline
is explicitly `legacy-unverified`; exact-input checks are not presented as
source-authenticity proof. `make verify-apt-compile` rebuilds the embedded APT
archive, HTTP method, and Cydia-owned compatibility adapter through that
reviewed manifest. `make verify-apt-api` can syntax-check the adapter against a
separately fetched clean APT stable or main checkout without network access in
Make.
`make verify-config` checks the effective device configuration and the ARC/iOS
12 flags emitted by the Objective-C, Objective-C++ and helper recipes.
`make verify-compile` builds every supported Objective-C object plus the
`postinst` and `cfversion` helpers without linking. `make verify-static` adds
the ownership and source-size gates, and `make verify` runs the complete
compile/static suite.

`make verify-package-paths` is the rooted/rootless fixture gate. It checks the
same Cydia-owned path policy used by `DpkgRunner`, `cydo`, and the package
staging rules; it does not assume that a rootless installation is a prefixed
copy of a rootful filesystem.

The app-owned source-size limit is 1200 lines (`VERIFY_MAX_SOURCE_LINES` can be
overridden for an audit). The largest maintained source is now below that
limit; the remaining larger inputs are either focused application/bootstrap
files or vendored code. Device and simulator application links are also tested
with the normal Make recipes.

Appearance colors are role-based through `UIColor+Cydia`. iOS 13 and newer use
UIKit semantic/dynamic colors; iOS 12 resolves calibrated concrete fallbacks
against the owning view's trait collection. Custom-drawn cells invalidate and
redraw when the color appearance changes, and web views receive the same live
appearance event. No dynamic color is cached as a process-wide `CGColor`.

The opt-in simulator gate builds Cydia through Make, installs a uniquely
identified probe app, and switches a running iOS 13+ simulator from light to
dark without relaunching it. Supplying an iOS 12 simulator also checks fallback
resolution and unavailable-selector safety. The probe hosts Cydia's custom
cells in a real table, a native loading view, and a Cyte web controller with a
hard-coded page-body fallback; the gate checks their resolved luminance and the
page's JavaScript appearance event before accepting a live transition. Cyte
injects a resolved host fallback for legacy pages that do not provide their own
appearance CSS, while pages marked as appearance-managed retain their own
listener-driven styling. It restores the modern simulator's original appearance
and removes the probe app on exit:

When a runtime does not implement `simctl ui appearance`, the gate uses a
simulator-only parent trait override triggered through the probe data container.
This keeps the process alive and exercises the same callbacks, including both
branches of the explicit iOS 12 fallback.

```sh
make verify-appearance-simulator \
  SIMULATOR_UDID=<modern-simulator-udid> \
  IOS12_SIMULATOR_UDID=<ios-12-simulator-udid> \
  BUILD_DIR=/tmp/cydia-appearance-verification
```

The expected acceptance sequence for future changes is:

```sh
make verify
make build/bin/MobileCydia
make --no-print-directory -B -j6 doIA=yes \
  BUILD_DIR=/tmp/cydia-simulator-build \
  /tmp/cydia-simulator-build/bin/MobileCydia
make --no-print-directory -B -j6 PACKAGE_LAYOUT=rootful package
make --no-print-directory -B -j6 PACKAGE_LAYOUT=rootless package
```

## Linux package CI

`.github/workflows/linux-packages.yml` builds both package layouts on
Ubuntu 22.04 using the same Make targets as local builds. The public iPhoneOS
14.5 SDK snapshot and Linux-hosted iOS toolchain are pinned by URL and SHA-256;
the job refuses a changed download instead of silently taking a newer toolchain.
The embedded `apt64` gitlink is initialized over HTTPS; `SDURLCache` is already
vendored at the reviewed Cydia revision. ICU headers come from the pinned
iPhoneOS SDK, so the legacy ICU submodule is not required by this build.

Each matrix leg checks the generated Debian epoch (`1:`), identity fields
(`Name: Cydia Refurbished`, `Maintainer: Torrekie <me@torrekie.dev>`, and the
preserved upstream `Author`), architecture, package prefix, launchd executable
path, translations, and maintainer files. Rootless archives
must keep every data path below `/var/jb`; rooted archives must contain no
`/var/jb` path. The resulting `.deb` files and `SHA256SUMS` are retained as CI
candidate artifacts only. The workflow does not publish a release or submit a
package to a repository.
Because the public fork has no release-tag refs, CI sets an explicit raw
candidate version (`1.1.36+git.<merge-sha>`). The package control generator
adds Debian epoch `1:` to that value (for example,
`1:1.1.36+git.<merge-sha>`), while keeping the filename and embedded app
version free of the colon. This is intentionally distinct from a release
version and can be replaced when a signed release process is introduced.
