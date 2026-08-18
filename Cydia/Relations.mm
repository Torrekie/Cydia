#include "Cydia/Relations.h"

#include "iPhonePrivate.h"

@implementation CydiaOperation

- (id) initWithOperator:(const char *)_operator value:(const char *)value {
    if ((self = [super init]) != nil) {
        operator_ = [NSString stringWithUTF8String:_operator];
        value_ = [NSString stringWithUTF8String:value];
    } return self;
}

+ (NSArray *) _attributeKeys {
    return [NSArray arrayWithObjects:
        @"operator",
        @"value",
    nil];
}

- (NSArray *) attributeKeys {
    return [[self class] _attributeKeys];
}

+ (BOOL) isKeyExcludedFromWebScript:(const char *)name {
    return ![[self _attributeKeys] containsObject:[NSString stringWithUTF8String:name]] && [super isKeyExcludedFromWebScript:name];
}

- (NSString *) operator {
    return operator_;
}

- (NSString *) value {
    return value_;
}

@end

@implementation CydiaClause

- (id) initWithData:(const CydiaAPT::RelationClauseData &)data {
    if ((self = [super init]) != nil) {
        package_ = [NSString stringWithUTF8String:data.package.c_str()];

        if (!data.version.empty())
            version_ = [[CydiaOperation alloc] initWithOperator:data.comparison.c_str() value:data.version.c_str()];
        else
            version_ = (id) [NSNull null];
    } return self;
}

+ (NSArray *) _attributeKeys {
    return [NSArray arrayWithObjects:
        @"package",
        @"version",
    nil];
}

- (NSArray *) attributeKeys {
    return [[self class] _attributeKeys];
}

+ (BOOL) isKeyExcludedFromWebScript:(const char *)name {
    return ![[self _attributeKeys] containsObject:[NSString stringWithUTF8String:name]] && [super isKeyExcludedFromWebScript:name];
}

- (NSString *) package {
    return package_;
}

- (CydiaOperation *) version {
    return version_;
}

@end

@implementation CydiaRelation

- (id) initWithData:(const CydiaAPT::RelationData &)data {
    if ((self = [super init]) != nil) {
        relationship_ = [NSString stringWithUTF8String:data.relationship.c_str()];
        clauses_ = [NSMutableArray arrayWithCapacity:8];

        for (std::vector<CydiaAPT::RelationClauseData>::const_iterator clause(data.clauses.begin());
             clause != data.clauses.end(); ++clause)
            [clauses_ addObject:[[CydiaClause alloc] initWithData:*clause]];
    } return self;
}

+ (NSArray *) _attributeKeys {
    return [NSArray arrayWithObjects:
        @"clauses",
        @"relationship",
    nil];
}

- (NSArray *) attributeKeys {
    return [[self class] _attributeKeys];
}

+ (BOOL) isKeyExcludedFromWebScript:(const char *)name {
    return ![[self _attributeKeys] containsObject:[NSString stringWithUTF8String:name]] && [super isKeyExcludedFromWebScript:name];
}

- (NSString *) relationship {
    return relationship_;
}

- (NSArray *) clauses {
    return clauses_;
}

- (void) addClause:(CydiaClause *)clause {
    [clauses_ addObject:clause];
}

@end
