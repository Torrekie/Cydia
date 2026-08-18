#include "CyteKit/Diversion.h"

#include "CyteKit/RegEx.hpp"
#include "Menes/ObjectHandle.h"

#define ForSaurik 0

static _H<NSMutableSet> Diversions_;

@implementation Diversion {
    RegEx pattern_;
    _H<NSString> key_;
    _H<NSString> format_;
}

- (id) initWithFrom:(NSString *)from to:(NSString *)to {
    if ((self = [super init]) != nil) {
        pattern_ = [from UTF8String];
        key_ = from;
        format_ = to;
    } return self;
}

- (NSString *) divert:(NSString *)url {
    return !pattern_(url) ? nil : pattern_->*format_;
}

+ (void) initializeStore {
    if (Diversions_ == nil)
        Diversions_ = [NSMutableSet setWithCapacity:0];
}

+ (void) addDiversion:(Diversion *)diversion {
    [Diversions_ addObject:diversion];
}

+ (NSURL *) divertURL:(NSURL *)url {
  divert:
    NSString *href([url absoluteString]);

    for (Diversion *diversion in (id) Diversions_)
        if (NSString *diverted = [diversion divert:href]) {
#if !ForRelease
            NSLog(@"div: %@", diverted);
#endif
            url = [NSURL URLWithString:diverted];
            goto divert;
        }

    return url;
}

- (NSString *) key {
    return key_;
}

- (NSUInteger) hash {
    return [key_ hash];
}

- (BOOL) isEqual:(Diversion *)object {
    return self == object || [self class] == [object class] && [key_ isEqual:[object key]];
}

@end
