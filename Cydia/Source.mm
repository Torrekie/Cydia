#include "Cydia/Source.h"
#include "Cydia/Database.h"

#include "Cydia/Profile.hpp"
#include "iPhonePrivate.h"

static const NSStringCompareOptions LaxCompareOptions_ = NSNumericSearch | NSDiacriticInsensitiveSearch | NSWidthInsensitiveSearch | NSCaseInsensitiveSearch;

@implementation Source

+ (NSString *) webScriptNameForSelector:(SEL)selector {
    if (false);
    else if (selector == @selector(addSection:))
        return @"addSection";
    else if (selector == @selector(getField:))
        return @"getField";
    else if (selector == @selector(removeSection:))
        return @"removeSection";
    else if (selector == @selector(remove))
        return @"remove";
    else
        return nil;
}

+ (BOOL) isSelectorExcludedFromWebScript:(SEL)selector {
    return [self webScriptNameForSelector:selector] == nil;
}

+ (NSArray *) _attributeKeys {
    return [NSArray arrayWithObjects:
        @"baseuri",
        @"distribution",
        @"host",
        @"key",
        @"iconuri",
        @"label",
        @"name",
        @"origin",
        @"rooturi",
        @"sections",
        @"shortDescription",
        @"trusted",
        @"type",
        @"version",
    nil];
}

- (NSArray *) attributeKeys {
    return [[self class] _attributeKeys];
}

+ (BOOL) isKeyExcludedFromWebScript:(const char *)name {
    return ![[self _attributeKeys] containsObject:[NSString stringWithUTF8String:name]] && [super isKeyExcludedFromWebScript:name];
}

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
    return record_ == nil ? (id) [NSNull null] : [record_ objectForKey:@"Sections"] ?: [NSArray array];
}

- (void) _addSection:(NSString *)section {
    if (record_ == nil)
        return;
    else if (NSMutableArray *sections = [record_ objectForKey:@"Sections"]) {
        if (![sections containsObject:section])
            [sections addObject:section];
    } else
        [record_ setObject:[NSMutableArray arrayWithObject:section] forKey:@"Sections"];
}

- (bool) addSection:(NSString *)section {
    if (record_ == nil)
        return false;

    [self performSelectorOnMainThread:@selector(_addSection:) withObject:section waitUntilDone:NO];
    return true;
}

- (void) _removeSection:(NSString *)section {
    if (record_ == nil)
        return;

    if (NSMutableArray *sections = [record_ objectForKey:@"Sections"])
        if ([sections containsObject:section])
            [sections removeObject:section];
}

- (bool) removeSection:(NSString *)section {
    if (record_ == nil)
        return false;

    [self performSelectorOnMainThread:@selector(_removeSection:) withObject:section waitUntilDone:NO];
    return true;
}

- (void) _remove {
    [Sources_ removeObjectForKey:[self key]];
}

- (bool) remove {
    bool value(record_ != nil);
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
