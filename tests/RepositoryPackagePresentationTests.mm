#import "Cydia/RepositoryPackagePresentation.h"
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
int main() {
    @autoreleasepool {
        NSURL *source = [NSURL URLWithString:@"https://repo.chariz.com/"];
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
