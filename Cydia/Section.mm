#include "Cydia/Section.h"

#include "Cydia/Package.h"

static const NSStringCompareOptions LaxCompareOptions_ =
    NSNumericSearch | NSDiacriticInsensitiveSearch |
    NSWidthInsensitiveSearch | NSCaseInsensitiveSearch;

@implementation Section

- (NSComparisonResult) compareByLocalized:(Section *)section {
    NSString *lhs(localized_);
    NSString *rhs([section localized]);
    return [lhs compare:rhs options:LaxCompareOptions_];
}

- (instancetype) initWithName:(NSString *)name localized:(NSString *)localized {
    if ((self = [self initWithName:name localize:NO]) != nil && localized != nil)
        localized_ = localized;
    return self;
}

- (instancetype) initWithName:(NSString *)name localize:(BOOL)localize {
    return [self initWithName:name row:0 localize:localize];
}

- (instancetype) initWithName:(NSString *)name row:(size_t)row localize:(BOOL)localize {
    if ((self = [super init]) != nil) {
        name_ = name;
        row_ = row;
        if (localize)
            localized_ = LocalizeSection(name_);
    }
    return self;
}

- (NSString *) name {
    return name_;
}

- (void) setName:(NSString *)name {
    name_ = name;
}

- (size_t) row {
    return row_;
}

- (size_t) count {
    return count_;
}

- (void) addToRow {
    ++row_;
}

- (void) addToCount {
    ++count_;
}

- (void) setCount:(size_t)count {
    count_ = count;
}

- (NSString *) localized {
    return localized_;
}

@end
