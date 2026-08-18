#include "Cydia/Package.h"
#include "Cydia/Section.h"

#include <algorithm>

static const NSStringCompareOptions MatchCompareOptions_ = NSLiteralSearch | NSCaseInsensitiveSearch;

@interface Package (Search)
@end

@implementation Package (Search)

- (uint32_t) rank {
    return rank_;
}

- (BOOL) matches:(NSArray *)query {
    if (query == nil || [query count] == 0)
        return NO;

    rank_ = 0;

    NSString *string;
    NSRange range;
    NSUInteger length;

    string = [self name];
    length = [string length];

    if (length != 0)
    for (NSString *term in query) {
        range = [string rangeOfString:term options:MatchCompareOptions_];
        if (range.location != NSNotFound)
            rank_ -= 6 * 1000000 / length;
    }

    if (rank_ == 0) {
        string = [self id];
        length = [string length];

        if (length != 0)
        for (NSString *term in query) {
            range = [string rangeOfString:term options:MatchCompareOptions_];
            if (range.location != NSNotFound)
                rank_ -= 6 * 1000000 / length;
        }
    }

    string = [self shortDescription];
    length = [string length];
    NSUInteger stop(std::min<NSUInteger>(length, 200));

    if (length != 0)
    for (NSString *term in query) {
        range = [string rangeOfString:term options:MatchCompareOptions_ range:NSMakeRange(0, stop)];
        if (range.location != NSNotFound)
            rank_ -= 2 * 100000;
    }

    return rank_ != 0;
}

- (NSArray *) tags {
    return tags_;
}

- (BOOL) hasTag:(NSString *)tag {
    return tags_ == nil ? NO : [tags_ containsObject:tag];
}

- (NSString *) primaryPurpose {
    for (NSString *tag in (NSArray *) tags_)
        if ([tag hasPrefix:@"purpose::"])
            return [tag substringFromIndex:9];
    return nil;
}

- (NSArray *) purposes {
    NSMutableArray *purposes([NSMutableArray arrayWithCapacity:2]);
    for (NSString *tag in (NSArray *) tags_)
        if ([tag hasPrefix:@"purpose::"])
            [purposes addObject:[tag substringFromIndex:9]];
    return [purposes count] == 0 ? nil : purposes;
}

- (bool) isCommercial {
    return [self hasTag:@"cydia::commercial"];
}

- (void) setIndex:(size_t)index {
    if (metadata_ != NULL && metadata_->index_ != index + 1)
        metadata_->index_ = index + 1;
}

- (CYString &) cyname {
    return !transform_.empty() ? transform_ : !name_.empty() ? name_ : id_;
}

- (uint32_t) compareBySection:(NSArray *)sections {
    NSString *section([self section]);
    for (size_t i(0), e([sections count]); i != e; ++i) {
        if ([section isEqualToString:[[sections objectAtIndex:i] name]])
            return i;
    }

    return _not(uint32_t);
}

@end
