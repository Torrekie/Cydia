#include "Cydia/Source.h"
#include "Cydia/Database.h"

#include "Cydia/Profile.hpp"
#include "iPhonePrivate.h"
#include "Sources.h"

static const NSStringCompareOptions LaxCompareOptions_ = NSNumericSearch | NSDiacriticInsensitiveSearch | NSWidthInsensitiveSearch | NSCaseInsensitiveSearch;

@implementation Source

- (void) setSnapshot:(const CydiaAPT::SourceSnapshot &)snapshot inPool:(CYPool *)pool {
    trusted_ = snapshot.trusted;

    uri_.set(pool, snapshot.uri);
    distribution_.set(pool, snapshot.distribution);
    type_.set(pool, snapshot.type);
    base_.set(pool, snapshot.base);
    defaultIcon_.set(pool, snapshot.defaultIcon);
    depiction_.set(pool, snapshot.depiction);
    description_.set(pool, snapshot.description);
    label_.set(pool, snapshot.label);
    origin_.set(pool, snapshot.origin);
    support_.set(pool, snapshot.support);
    version_.set(pool, snapshot.version);
    files_ = snapshot.files;

    record_ = [Sources_ objectForKey:[self key]];

    NSURL *url([NSURL URLWithString:uri_]);

    host_ = [url host];
    if (host_ != nil)
        host_ = [host_ lowercaseString];

    if (host_ != nil)
        authority_ = host_;
    else
        authority_ = [url path];
}

- (Source *) initWithHandle:(CydiaAPT::SourceHandle)handle forDatabase:(Database *)database inPool:(CYPool *)pool {
    if ((self = [super init]) != nil) {
        era_ = [database era];
        database_ = database;
        handle_ = handle;

        _profile(Source$initWithHandle$setSnapshot)
        [self setSnapshot:[database sourceSnapshot:handle] inPool:pool];
        _end
    } return self;
}

- (NSString *) getField:(NSString *)name {
@synchronized (database_) {
    if ([database_ era] != era_ || !handle_.valid())
        return nil;
    return [database_ sourceField:handle_ name:name];
} }

- (NSComparisonResult) compareByName:(Source *)source {
    NSString *lhs = [self name];
    NSString *rhs = [source name];

    if ([lhs length] != 0 && [rhs length] != 0) {
        unichar lhc = [lhs characterAtIndex:0];
        unichar rhc = [rhs characterAtIndex:0];
        NSCharacterSet *letters([NSCharacterSet letterCharacterSet]);
        bool lha([letters characterIsMember:lhc]);
        bool rha([letters characterIsMember:rhc]);

        if (lha && !rha)
            return NSOrderedAscending;
        else if (!lha && rha)
            return NSOrderedDescending;
    }

    return [lhs compare:rhs options:LaxCompareOptions_];
}

- (NSString *) depictionForPackage:(NSString *)package {
    return depiction_.empty() ? nil : [static_cast<id>(depiction_) stringByReplacingOccurrencesOfString:@"*" withString:package];
}

- (NSString *) supportForPackage:(NSString *)package {
    return support_.empty() ? nil : [static_cast<id>(support_) stringByReplacingOccurrencesOfString:@"*" withString:package];
}

- (NSArray *) sections {
    NSArray<CydiaSourceDefinition *> *definitions(CydiaSourceDefinitionsForKey([self key]));
    // libapt can merge several entries into one release. Expose components
    // only when this legacy Source identity maps to one actual definition.
    return definitions.count == 1 ? definitions.firstObject.components : (id)[NSNull null];
}

- (bool) _addSection:(NSString *)section {
    if (!CydiaUpdateSourceSection([self key], section, true))
        return false;
    return true;
}

- (bool) addSection:(NSString *)section {
    if ([database_ era] != era_ || !CydiaManagedSourceKeyIsOwned([self key]))
        return false;

    [self performSelectorOnMainThread:@selector(_addSection:) withObject:section waitUntilDone:NO];
    return true;
}

- (bool) _removeSection:(NSString *)section {
    if (!CydiaUpdateSourceSection([self key], section, false))
        return false;
    return true;
}

- (bool) removeSection:(NSString *)section {
    if ([database_ era] != era_ || !CydiaManagedSourceKeyIsOwned([self key]))
        return false;

    [self performSelectorOnMainThread:@selector(_removeSection:) withObject:section waitUntilDone:NO];
    return true;
}

- (void) _remove {
    CydiaRemoveSource([self key]);
}

- (bool) remove {
    bool value([database_ era] == era_ && CydiaManagedSourceKeyIsOwned([self key]));
    if (!value)
        return false;
    [self performSelectorOnMainThread:@selector(_remove) withObject:nil waitUntilDone:NO];
    return value;
}

- (NSDictionary *) record {
    return record_;
}

- (BOOL) trusted {
    return trusted_;
}

- (NSString *) rooturi {
    return uri_;
}

- (NSString *) distribution {
    return distribution_;
}

- (NSString *) type {
    return type_;
}

- (NSString *) baseuri {
    return base_.empty() ? nil : (id) base_;
}

- (NSString *) iconuri {
    if (NSString *base = [self baseuri])
        return [base stringByAppendingString:@"CydiaIcon.png"];

    return nil;
}

- (NSURL *) iconURL {
    if (NSString *uri = [self iconuri])
        return [NSURL URLWithString:uri];
    return nil;
}

- (NSString *) key {
    return [NSString stringWithFormat:@"%@:%@:%@", (NSString *) type_, (NSString *) uri_, (NSString *) distribution_];
}

- (NSString *) host {
    return host_;
}

- (NSString *) name {
    return origin_.empty() ? (id) authority_ : origin_;
}

- (NSString *) shortDescription {
    return description_;
}

- (NSString *) label {
    return label_.empty() ? (id) authority_ : label_;
}

- (NSString *) origin {
    return origin_;
}

- (NSString *) version {
    return version_;
}

- (NSString *) defaultIcon {
    return defaultIcon_;
}

- (void) setDelegate:(NSObject<SourceDelegate> *)delegate {
    delegate_ = delegate;
}

- (bool) fetch {
@synchronized (self) {
    return !fetches_.empty();
} }

- (void) setFetch:(bool)fetch forURI:(const char *)uri {
    bool fetching;
@synchronized (self) {
    if (!fetch) {
        if (fetches_.erase(uri) == 0)
            return;
    } else if (files_.find(uri) == files_.end())
        return;
    else if (!fetches_.insert(uri).second)
        return;

    fetching = !fetches_.empty();
}

    [delegate_ performSelectorOnMainThread:@selector(setFetch:) withObject:[NSNumber numberWithBool:fetching] waitUntilDone:NO];
}

- (void) resetFetch {
@synchronized (self) {
    fetches_.clear();
}
    [delegate_ performSelectorOnMainThread:@selector(setFetch:) withObject:[NSNumber numberWithBool:NO] waitUntilDone:NO];
}

@end
/* }}} */
