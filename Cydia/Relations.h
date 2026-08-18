#ifndef Cydia_Relations_H
#define Cydia_Relations_H

#include "Cydia/AptCompatibility.hpp"
#include "CyteKit/UCPlatform.h"
#include "Menes/ObjectHandle.h"

#include <Foundation/Foundation.h>

@interface CydiaOperation : NSObject {
    _H<NSString> operator_;
    _H<NSString> value_;
}

- (id) initWithOperator:(const char *)_operator value:(const char *)value;
- (NSString *) operator;
- (NSString *) value;

@end

@interface CydiaClause : NSObject {
    _H<NSString> package_;
    _H<CydiaOperation> version_;
}

- (id) initWithData:(const CydiaAPT::RelationClauseData &)data;
- (NSString *) package;
- (CydiaOperation *) version;

@end

@interface CydiaRelation : NSObject {
    _H<NSString> relationship_;
    _H<NSMutableArray> clauses_;
}

- (id) initWithData:(const CydiaAPT::RelationData &)data;
- (NSString *) relationship;
- (NSArray *) clauses;
- (void) addClause:(CydiaClause *)clause;

@end

#endif//Cydia_Relations_H
