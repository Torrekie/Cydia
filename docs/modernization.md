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

`CyteKit/` and `Menes/` remain reusable framework/support layers. `apt64/` and
`SDURLCache/` remain vendored inputs; they are compiled by the existing Make
graph but are not forced into the app-owned module-size policy.

The embedded APT gitlink, ABI, licenses, and reviewed source groups are recorded
in `mk/apt.mk`. The update and backend-boundary policy is documented in
`docs/apt-dpkg-compatibility.md`.

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

The app-owned source-size limit is 1200 lines (`VERIFY_MAX_SOURCE_LINES` can be
overridden for an audit). The largest maintained source is now below that
limit; the remaining larger inputs are either focused application/bootstrap
files or vendored code. Device and simulator application links are also tested
with the normal Make recipes.

The expected acceptance sequence for future changes is:

```sh
make verify
make build/bin/MobileCydia
make --no-print-directory -B -j6 doIA=yes \
  BUILD_DIR=/tmp/cydia-simulator-build \
  /tmp/cydia-simulator-build/bin/MobileCydia
```
