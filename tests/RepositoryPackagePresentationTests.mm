#import "Cydia/RepositoryPackagePresentation.h"
#import "Cydia/RepositoryLibraryItem.h"
#import "Cydia/PackageArchitecturePresentation.h"
#include "Cydia/AptCompatibility.hpp"
#include <cstdio>
#include <cstdlib>

static void Require(bool condition, const char *message) {
    if (!condition) { std::fprintf(stderr, "[repository-package][FAIL] %s\n", message); std::exit(1); }
}
static CydiaRepositoryPackagePresentation *Present(NSDictionary *info, BOOL signedIn = YES,
    BOOL supported = YES, BOOL downloadAvailable = YES, NSURL *URL = nil) {
    return [[CydiaRepositoryPackagePresentation alloc] initWithInfo:info signedIn:signedIn
        supported:supported downloadAvailable:downloadAvailable purchaseURL:URL];
}
static CydiaRepositoryPackagePresentation *NativePresent(NSDictionary *info, BOOL downloadSupported = YES,
    BOOL purchaseAvailable = YES) {
    return [[CydiaRepositoryPackagePresentation alloc] initWithInfo:info signedIn:YES
        supported:YES downloadAvailable:YES downloadSupported:downloadSupported
        purchaseAvailable:purchaseAvailable purchaseURL:nil];
}
static CydiaRepositoryLibraryItem *LibraryItem(const CydiaAPT::RepositoryPackageAvailabilityData &availability,
    BOOL selectedFromSource = YES, NSString *architecture = @"iphoneos-arm64",
    NSArray<NSString *> *registered = @[@"iphoneos-arm64"], BOOL versionAvailable = YES,
    BOOL architectureSupported = YES, NSString *name = @"Selected Product", NSString *route = @"com.example.product",
    NSString *version = @"2.0") {
    return [[CydiaRepositoryLibraryItem alloc] initWithIdentifier:@"com.example.product" availability:availability
        selectedName:name selectedRouteIdentity:route selectedVersion:version selectedArchitecture:architecture
        selectedFromSource:selectedFromSource versionAvailable:versionAvailable
        architectureSupported:architectureSupported registeredArchitectures:registered];
}
static void CheckLibraryItems() {
    CydiaAPT::RepositoryPackageAvailabilityData source;
    source.known = true;
    source.displayName = "Source Product";
    source.architectures = {"iphoneos-arm64"};
    source.hasCompatibleVersion = true;
    source.hasDownloadableVersion = true;
    auto native = LibraryItem(source);
    Require(native.state == CydiaRepositoryLibraryItemStateAvailable &&
        [native.statusLocalizationKey isEqual:@"ACCOUNT_OWNED"] &&
        [native.displayName isEqual:@"Source Product"] && [native.routeIdentity isEqual:@"com.example.product"] &&
        [native.version isEqual:@"2.0"] && native.architectureCaption == nil,
        "source-scoped native library item lost ordinary selectable presentation");

    auto elsewhere = LibraryItem(source, NO, @"iphoneos-arm64", @[@"iphoneos-arm64", @"iphoneos-arm"], YES, YES,
        @"Other Repository Product", @"com.example.product:iphoneos-arm64", @"99.0");
    Require(elsewhere.state == CydiaRepositoryLibraryItemStateNotSelected &&
        [elsewhere.statusLocalizationKey isEqual:@"ACCOUNT_ITEM_NOT_IN_SOURCE"] &&
        [elsewhere.displayName isEqual:@"Source Product"] && elsewhere.routeIdentity == nil &&
        elsewhere.version == nil && elsewhere.architectureCaption == nil,
        "another source's selected package supplied a library name, architecture, version, or route");
    source.displayName.clear();
    Require([LibraryItem(source).displayName isEqual:@"Selected Product"] &&
        [LibraryItem(source, NO).displayName isEqual:@"com.example.product"],
        "selected name fallback escaped the exact repository boundary");

    CydiaAPT::RepositoryPackageAvailabilityData unsupported(source);
    unsupported.displayName = "Unsupported Source Product";
    unsupported.architectures = {"iphoneos-arm"};
    unsupported.hasCompatibleVersion = false;
    unsupported.hasDownloadableVersion = false;
    auto unsupportedItem = LibraryItem(unsupported, NO);
    Require(unsupportedItem.state == CydiaRepositoryLibraryItemStateUnsupportedArchitecture &&
        [unsupportedItem.statusLocalizationKey isEqual:@"ACCOUNT_ITEM_ARCHITECTURE_UNSUPPORTED"] &&
        [unsupportedItem.displayName isEqual:@"Unsupported Source Product"] && unsupportedItem.routeIdentity == nil &&
        [unsupportedItem.architectureCaption isEqual:CydiaPackageArchitectureCaption(@"iphoneos-arm", @[@"iphoneos-arm64"])],
        "unsupported-only source was hidden or borrowed the globally selected native architecture");

    CydiaAPT::RepositoryPackageAvailabilityData independent(source);
    independent.architectures = {"all"};
    auto all = LibraryItem(independent, YES, @"all");
    Require(all.state == CydiaRepositoryLibraryItemStateAvailable && all.architectureCaption == nil &&
        [all.routeIdentity isEqual:@"com.example.product"],
        "Architecture: all became incompatible, qualified, or noisy on a single-architecture system");

    CydiaAPT::RepositoryPackageAvailabilityData foreign(source);
    foreign.architectures = {"iphoneos-arm"};
    NSArray<NSString *> *multiarch = @[@"iphoneos-arm64", @"iphoneos-arm"];
    auto additional = LibraryItem(foreign, YES, @"iphoneos-arm", multiarch, YES, YES,
        @"Selected Product", @"com.example.product:iphoneos-arm");
    Require(additional.state == CydiaRepositoryLibraryItemStateAvailable &&
        [additional.routeIdentity isEqual:@"com.example.product:iphoneos-arm"] &&
        [additional.architectureCaption isEqual:CydiaPackageArchitectureCaption(@"iphoneos-arm", multiarch)],
        "supported foreign item lost its existing architecture caption or qualified identity");

    CydiaAPT::RepositoryPackageAvailabilityData unknown;
    auto missing = LibraryItem(unknown, NO, @"iphoneos-arm", multiarch, YES, NO);
    Require(missing.state == CydiaRepositoryLibraryItemStateUnknown &&
        [missing.statusLocalizationKey isEqual:@"ACCOUNT_ITEM_NOT_IN_SOURCE"] &&
        [missing.displayName isEqual:@"com.example.product"] && missing.architectureCaption == nil &&
        missing.routeIdentity == nil && missing.version == nil,
        "unknown repository metadata invented architecture incompatibility or a selected-source route");
    CydiaAPT::RepositoryPackageAvailabilityData noVersion(source);
    auto external = LibraryItem(unknown);
    Require(external.state == CydiaRepositoryLibraryItemStateAvailable && external.routeIdentity.length != 0,
        "an existing provider lost same-source current package navigation without optional metadata support");
    Require(LibraryItem(unsupported, NO, @"iphoneos-arm64", @[]).state == CydiaRepositoryLibraryItemStateUnknown,
        "unknown dpkg architecture registration invented an incompatibility claim");
    noVersion.hasDownloadableVersion = false;
    auto unavailable = LibraryItem(noVersion);
    Require(unavailable.state == CydiaRepositoryLibraryItemStateNoDownloadableVersion &&
        [unavailable.statusLocalizationKey isEqual:@"ACCOUNT_ITEM_NO_VERSION"] && unavailable.routeIdentity == nil,
        "source without a downloadable compatible version retained an actionable route");
    Require(LibraryItem(source, YES, @"iphoneos-arm64", @[@"iphoneos-arm64"], NO).routeIdentity == nil &&
        LibraryItem(source, YES, @"iphoneos-arm64", @[@"iphoneos-arm64"], YES, NO).routeIdentity == nil,
        "unavailable or unsupported current selection became a library route");

    NSMutableString *identifier = [NSMutableString stringWithString:@"com.example.product"];
    NSMutableString *name = [NSMutableString stringWithString:@"Copied Product"];
    NSMutableString *route = [NSMutableString stringWithString:@"com.example.product:iphoneos-arm"];
    NSMutableString *version = [NSMutableString stringWithString:@"3.0"];
    NSMutableString *architecture = [NSMutableString stringWithString:@"iphoneos-arm"];
    NSMutableArray *registered = [NSMutableArray arrayWithArray:multiarch];
    CydiaAPT::RepositoryPackageAvailabilityData copied(source);
    auto snapshot = [[CydiaRepositoryLibraryItem alloc] initWithIdentifier:identifier availability:copied
        selectedName:name selectedRouteIdentity:route selectedVersion:version selectedArchitecture:architecture
        selectedFromSource:YES versionAvailable:YES architectureSupported:YES registeredArchitectures:registered];
    NSString *caption = snapshot.architectureCaption;
    copied.displayName = "Copied Source Product";
    auto sourceSnapshot = LibraryItem(copied, NO);
    [identifier appendString:@".changed"]; [name appendString:@" Changed"]; [route appendString:@".changed"];
    [version appendString:@".changed"]; [architecture appendString:@".changed"]; [registered removeAllObjects];
    copied.displayName = "Changed"; copied.architectures.clear(); copied.hasDownloadableVersion = false;
    Require([snapshot.identifier isEqual:@"com.example.product"] && [snapshot.displayName isEqual:@"Copied Product"] &&
        [snapshot.routeIdentity isEqual:@"com.example.product:iphoneos-arm"] && [snapshot.version isEqual:@"3.0"] &&
        [snapshot.architectureCaption isEqual:caption] && snapshot.state == CydiaRepositoryLibraryItemStateAvailable &&
        [sourceSnapshot.displayName isEqual:@"Copied Source Product"],
        "library snapshot retained mutable caller or availability state");

    source.displayName = "Unsafe\nName";
    Require([LibraryItem(source, YES, @"iphoneos-arm64", @[@"iphoneos-arm64"], YES, YES, @"Safe Product").displayName
        isEqual:@"Safe Product"], "control-bearing source display name bypassed sanitization");
    source.displayName.assign(513, 'x');
    auto sanitized = LibraryItem(source, YES, @"iphoneos-arm64", @[@"iphoneos-arm64"], YES, YES,
        @"Unsafe\nSelected", @"com.example.product\nother", @"2.0\nother");
    Require([sanitized.displayName isEqual:@"com.example.product"] && sanitized.routeIdentity == nil && sanitized.version == nil,
        "excessive or control-bearing library values survived the copied presentation boundary");
}
int main() {
    @autoreleasepool {
        CheckLibraryItems();
        NSURL *source = [NSURL URLWithString:@"https://repo.chariz.com/"];
        Require([CydiaRepositorySourceDisplayURL([NSURL URLWithString:@"https://user:password@repo.example/suite/rootless/?token=secret#private"])
            isEqual:@"https://repo.example/suite/rootless/"], "source display lost repository scope or exposed credentials");
        Require([CydiaRepositorySourceDisplayURL([NSURL URLWithString:@"http://repo.example/rooted/"])
            isEqual:@"http://repo.example/rooted/"], "legacy source scope hidden by HTTPS display policy");
        Require(CydiaRepositorySourceDisplayURL([NSURL URLWithString:@"https://repo.example/%0asource"]) == nil,
            "source display accepted a newline-bearing path");
        NSURL *buy = [NSURL URLWithString:@"https://chariz.com/buy/example-product"];
        Require([CydiaRepositoryPurchaseWebsite(source, buy) isEqual:buy], "explicit vendor product page refused");
        for (NSString *URL in @[@"https://chariz.com/", @"https://chariz.com/buy", @"https://chariz.com/buy/..",
            @"https://other.example/buy/example-product", @"https://chariz.com/buy/example?token=secret",
            @"https://chariz.com/buy/example/other"])
            Require(CydiaRepositoryPurchaseWebsite(source, [NSURL URLWithString:URL]) == nil,
                "non-product page presented as checkout");
        Require(CydiaRepositoryPurchaseWebsite([NSURL URLWithString:@"https://other.example/"], buy) == nil,
            "another source claimed a vendor purchase page");
        NSDictionary *owned = @{@"available": @YES, @"purchased": @YES};
        NSDictionary *unpurchased = @{@"available": @YES, @"purchased": @NO};
        Require(Present(owned).state == CydiaRepositoryPackageStateDownload, "owned exact package cannot download");
        Require(Present(owned, YES, YES, NO).state == CydiaRepositoryPackageStateOwned,
            "owned package invented an unavailable install callback");
        Require(Present(owned, NO).state == CydiaRepositoryPackageStateSignIn,
            "anonymous ownership authorized download");
        Require(Present(owned, YES, NO).state == CydiaRepositoryPackageStateUnavailable,
            "unsupported client authorized paid acquisition");
        Require(Present(@{@"available": @NO}).state == CydiaRepositoryPackageStateUnavailable,
            "vendor unavailable ignored");
        Require(Present(nil).state == CydiaRepositoryPackageStateUnknown, "missing response accepted");
        Require(Present(@{}).state == CydiaRepositoryPackageStateUnknown, "missing availability accepted");
        for (id wrong in @[@"true", @1, NSNull.null, @[], @{}])
            Require(Present(@{@"available": wrong, @"purchased": @YES}).state == CydiaRepositoryPackageStateUnknown,
                "nonboolean availability accepted");
        for (id wrong in @[@"true", @1, NSNull.null, @[], @{}])
            Require(Present(@{@"available": @YES, @"purchased": wrong}).state == CydiaRepositoryPackageStateUnknown,
                "nonboolean ownership accepted");
        Require(Present(@{@"available": @YES}, NO).state == CydiaRepositoryPackageStateSignIn,
            "anonymous package info required ownership field");
        Require(Present(unpurchased).state == CydiaRepositoryPackageStateNotPurchased,
            "missing public purchase link became invented buy URL");
        NSURL *safe = [NSURL URLWithString:@"https://vendor.invalid/store/package"];
        auto purchase = Present(unpurchased, YES, YES, YES, safe);
        Require(purchase.state == CydiaRepositoryPackageStateBuy && [purchase.purchaseURL isEqual:safe],
            "valid explicit public purchase website refused");
        Require(Present(owned, YES, YES, YES, safe).purchaseURL == nil,
            "owned package retained redundant purchase action");
        Require(Present(unpurchased, NO, YES, YES, safe).purchaseURL == nil,
            "signed out info retained actionable purchase URL");
        for (NSString *unsafe in @[@"http://vendor.invalid/store", @"file:///tmp/store", @"cydia://package/example",
            @"https://user:pass@vendor.invalid/store", @"https://vendor.invalid/store#secret",
            @"https://vendor.invalid/store?token=secret", @"https://vendor.invalid:0/store",
            @"https://vendor.invalid:65536/store", @"https://vendor.invalid/%0astore"])
            Require(Present(unpurchased, YES, YES, YES, [NSURL URLWithString:unsafe]).state == CydiaRepositoryPackageStateNotPurchased,
                "unsafe website became buy action");
        Require(Present(@{@"available": @YES, @"purchased": @YES, @"error": @"vendor error"}).state == CydiaRepositoryPackageStateUnknown,
            "vendor error authorized download");
        Require(Present(@{@"available": @YES, @"purchased": @YES, @"success": @NO}).state == CydiaRepositoryPackageStateUnknown,
            "unsuccessful response authorized download");
        Require(Present(@{@"available": @YES, @"purchased": @NO, @"recovery_url": safe.absoluteString,
            @"purchase_url": safe.absoluteString}).state == CydiaRepositoryPackageStateNotPurchased,
            "protocol-unsupported field became buy action");
        NSDictionary *offer = @{@"available": @YES, @"purchased": @NO, @"price": @"$2.99"};
        auto native = NativePresent(offer);
        Require(native.state == CydiaRepositoryPackageStateBuy && [native.price isEqual:@"$2.99"] && !native.purchased,
            "native provider offer has no bound displayed price");
        Require(NativePresent(offer, NO).state == CydiaRepositoryPackageStateNotPurchased,
            "purchase encouraged despite a known unsupported download client");
        Require(NativePresent(offer, YES, NO).state == CydiaRepositoryPackageStateNotPurchased,
            "purchase offered without provider checkout capability");
        Require(NativePresent(unpurchased).state == CydiaRepositoryPackageStateNotPurchased,
            "purchase offered without a confirmable price");
        Require(NativePresent(owned, NO).state == CydiaRepositoryPackageStateOwned,
            "reading ownership erased by a download policy restriction");
        Require(NativePresent(@{@"available": @NO, @"purchased": @YES}).state == CydiaRepositoryPackageStateOwnedUnavailable,
            "owned but unavailable product disappeared from ownership presentation");
        Require(NativePresent(@{@"available": @NO, @"purchased": @YES}).purchased,
            "ownership of an unavailable product was lost");
        NSDictionary *publicFree = @{@"available": @YES, @"free": @YES};
        auto freeSignedOut = Present(publicFree, NO, YES, YES);
        Require(freeSignedOut.state == CydiaRepositoryPackageStateDownload && freeSignedOut.isFree && !freeSignedOut.purchased,
            "public free package required an account or became synthetic ownership");
        Require(NativePresent(publicFree, NO).state == CydiaRepositoryPackageStateDownload,
            "public free install incorrectly required repository-grant engine support");
        Require(Present(publicFree, NO, YES, NO).state == CydiaRepositoryPackageStateFree,
            "nonactionable free product represented as owned or purchasable");
        Require(NativePresent(@{@"available": @YES, @"price": @0}, NO).isFree,
            "explicit numeric zero price not recognized as public free evidence");
        auto freeOwned = NativePresent(@{@"available": @YES, @"free": @YES, @"purchased": @YES}, NO);
        Require(freeOwned.isFree && freeOwned.purchased,
            "independent vendor ownership field erased by public free presentation");
        auto unavailableFree = NativePresent(@{@"available": @NO, @"free": @YES, @"purchased": @YES});
        Require(unavailableFree.state == CydiaRepositoryPackageStateOwnedUnavailable && unavailableFree.isFree,
            "unavailable free metadata could settle old charge status or enable installation");
        for (NSDictionary *notFree in @[
            @{@"available": @YES, @"purchased": @NO, @"free": @NO},
            @{@"available": @YES, @"purchased": @NO, @"free": @0},
            @{@"available": @YES, @"purchased": @NO, @"price": @NO},
            @{@"available": @YES, @"purchased": @NO, @"price": @"Free"},
            @{@"available": @YES, @"purchased": @NO, @"price": @"$0.00"}])
            Require(!NativePresent(notFree).isFree, "untrusted display text or false boolean became free-install authority");
        for (id price in @[@1, @YES, NSNull.null, @[], @{}, @"", @"$2\ncheckout"]) {
            Require(NativePresent(@{@"available": @YES, @"purchased": @NO, @"price": price}).state == CydiaRepositoryPackageStateNotPurchased,
                "invalid native price was offered for financial confirmation");
        }
        Require([CydiaRepositoryPurchasedPackageIdentifiers(@{@"items": @[@"com.example.one", @"com.example.one", @"two-package"]})
            isEqual:@[@"com.example.one", @"two-package"]], "owned library did not deduplicate provider item IDs");
        Require(CydiaRepositoryPurchasedPackageIdentifiers(@{@"items": @[]}).count == 0,
            "valid empty provider library treated as failure");
        for (id items in @[@"pkg", NSNull.null, @{}, @[@"pkg", @1], @[@"https://vendor.invalid/pkg"],
            @[@"pkg:arm64"], @[@"Pkg"], @[@"-pkg"], @[@"p"]])
            Require(CydiaRepositoryPurchasedPackageIdentifiers(@{@"items": items}) == nil,
                "malformed provider library became an actionable local package identity");
    }
    std::puts("[repository-package] presentation decisions passed"); return 0;
}
