/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/LegacyUICompatibility.h"

namespace {

BOOL IsString(id value) {
    return [value isKindOfClass:[NSString class]];
}

BOOL IsNumber(id value) {
    return [value isKindOfClass:[NSNumber class]];
}

BOOL IsMissing(id value) {
    return value == nil || value == [NSNull null] ||
        value == [CydiaLegacyUIUndefinedValue value];
}

BOOL IsBooleanLike(id value) {
    if (IsNumber(value))
        return YES;
    if (!IsString(value))
        return NO;
    NSString *lower([(NSString *) value lowercaseString]);
    return [lower isEqualToString:@"true"] || [lower isEqualToString:@"false"] ||
        [lower isEqualToString:@"yes"] || [lower isEqualToString:@"no"] ||
        [lower isEqualToString:@"1"] || [lower isEqualToString:@"0"];
}

BOOL IsSequence(id value) {
    return [value isKindOfClass:[NSArray class]] ||
        [value isKindOfClass:[NSOrderedSet class]];
}

BOOL IsCredentialFreeAbsoluteURLString(id value) {
    if (!IsString(value) || [(NSString *) value length] == 0)
        return NO;
    NSURLComponents *components([NSURLComponents
        componentsWithString:(NSString *) value]);
    return [[components scheme] length] != 0 &&
        [components percentEncodedUser] == nil &&
        [components percentEncodedPassword] == nil;
}

const NSUInteger kMaximumMetadataKeyLength = 4096;
const NSUInteger kMaximumMetadataComponentLength = 16384;
const NSUInteger kMaximumMetadataContainerCount = 1024;
const NSUInteger kMaximumMetadataDepth = 16;
const NSUInteger kMaximumMetadataNodeCount = 4096;
const NSUInteger kMaximumMetadataPayloadBytes = 1024 * 1024;

BOOL AddMetadataBudget(NSUInteger amount, NSUInteger *used) {
    if (used == NULL || amount > kMaximumMetadataPayloadBytes ||
        *used > kMaximumMetadataPayloadBytes - amount)
        return NO;
    *used += amount;
    return YES;
}

id CopyMetadataNode(id value, NSUInteger depth, NSUInteger *nodes,
                    NSUInteger *bytes, NSMutableSet<NSValue *> *ancestors,
                    BOOL *valid) {
    if (valid == NULL || !*valid || value == nil ||
        value == [NSNull null] ||
        value == [CydiaLegacyUIUndefinedValue value] ||
        depth > kMaximumMetadataDepth || nodes == NULL || bytes == NULL ||
        ancestors == nil || *nodes >= kMaximumMetadataNodeCount) {
        if (valid != NULL)
            *valid = NO;
        return nil;
    }
    ++*nodes;

    @try {
        if ([value isKindOfClass:[NSString class]]) {
            NSUInteger length([(NSString *)value length]);
            if (length > kMaximumMetadataComponentLength ||
                length > NSUIntegerMax / sizeof(unichar) ||
                !AddMetadataBudget(length * sizeof(unichar), bytes)) {
                *valid = NO;
                return nil;
            }
            return [[NSString alloc] initWithString:(NSString *)value];
        }
        if ([value isKindOfClass:[NSNumber class]]) {
            if (!AddMetadataBudget(16, bytes)) {
                *valid = NO;
                return nil;
            }
            return [value copy];
        }
        if ([value isKindOfClass:[NSDate class]]) {
            if (!AddMetadataBudget(16, bytes)) {
                *valid = NO;
                return nil;
            }
            return [[NSDate alloc] initWithTimeIntervalSinceReferenceDate:
                [(NSDate *)value timeIntervalSinceReferenceDate]];
        }
        if ([value isKindOfClass:[NSData class]]) {
            NSUInteger length([(NSData *)value length]);
            if (!AddMetadataBudget(length, bytes)) {
                *valid = NO;
                return nil;
            }
            return [[NSData alloc] initWithData:(NSData *)value];
        }

        BOOL array([value isKindOfClass:[NSArray class]]);
        BOOL dictionary([value isKindOfClass:[NSDictionary class]]);
        if (!array && !dictionary) {
            *valid = NO;
            return nil;
        }

        NSUInteger count(array ? [(NSArray *)value count] :
            [(NSDictionary *)value count]);
        if (count > kMaximumMetadataContainerCount) {
            *valid = NO;
            return nil;
        }
        NSValue *identity([NSValue valueWithPointer:(__bridge const void *)value]);
        if ([ancestors containsObject:identity]) {
            *valid = NO;
            return nil;
        }
        [ancestors addObject:identity];

        id result(nil);
        @try {
            if (array) {
                NSMutableArray *copy([NSMutableArray arrayWithCapacity:count]);
                for (id child in (NSArray *)value) {
                    id copied(CopyMetadataNode(child, depth + 1, nodes, bytes,
                        ancestors, valid));
                    if (!*valid || copied == nil)
                        break;
                    [copy addObject:copied];
                }
                if (*valid)
                    result = [copy copy];
            } else {
                NSArray *keys([(NSDictionary *)value allKeys]);
                if ([keys count] != count) {
                    *valid = NO;
                } else {
                    NSMutableDictionary *copy(
                        [NSMutableDictionary dictionaryWithCapacity:count]);
                    for (id key in keys) {
                        if (![key isKindOfClass:[NSString class]]) {
                            *valid = NO;
                            break;
                        }
                        id copiedKey(CopyMetadataNode(key, depth + 1, nodes,
                            bytes, ancestors, valid));
                        id child([(NSDictionary *)value objectForKey:key]);
                        id copiedValue(CopyMetadataNode(child, depth + 1,
                            nodes, bytes, ancestors, valid));
                        if (!*valid || copiedKey == nil || copiedValue == nil)
                            break;
                        [copy setObject:copiedValue forKey:copiedKey];
                    }
                    if (*valid)
                        result = [copy copy];
                }
            }
        } @finally {
            [ancestors removeObject:identity];
        }
        return result;
    } @catch (NSException *exception) {
        (void)exception;
        *valid = NO;
        return nil;
    }
}

BOOL IsValidArgument(id value, CydiaLegacyUIArgumentKind kind) {
    switch (kind) {
        case CydiaLegacyUIArgumentKindString:
            return IsString(value);
        case CydiaLegacyUIArgumentKindOptionalString:
            return IsMissing(value) || IsString(value);
        case CydiaLegacyUIArgumentKindNumber:
            return IsNumber(value);
        case CydiaLegacyUIArgumentKindOptionalNumber:
            return IsMissing(value) || IsNumber(value);
        case CydiaLegacyUIArgumentKindBooleanLike:
            return IsBooleanLike(value);
        case CydiaLegacyUIArgumentKindOptionalBooleanLike:
            return IsMissing(value) || IsBooleanLike(value);
        case CydiaLegacyUIArgumentKindSequence:
            return IsSequence(value);
        case CydiaLegacyUIArgumentKindOpaque:
            return !IsMissing(value);
        case CydiaLegacyUIArgumentKindOptionalAny:
            return YES;
        case CydiaLegacyUIArgumentKindURLString:
            return IsCredentialFreeAbsoluteURLString(value);
        case CydiaLegacyUIArgumentKindMetadataKey:
            return CydiaLegacyUICompatibilityCopyMetadataKey(value) != nil;
        case CydiaLegacyUIArgumentKindOptionalPropertyList:
            return CydiaLegacyUICompatibilityCopyMetadataValue(
                value, NULL, NULL);
    }
    return NO;
}

id UnavailableValue(CydiaLegacyUIUnavailableConvention convention) {
    switch (convention) {
        case CydiaLegacyUIUnavailableConventionUndefined:
            return [CydiaLegacyUIUndefinedValue value];
        case CydiaLegacyUIUnavailableConventionNull:
            return [NSNull null];
        case CydiaLegacyUIUnavailableConventionFalse:
            return @NO;
    }
    return [CydiaLegacyUIUndefinedValue value];
}

BOOL IsValidResult(id value, CydiaLegacyUIValueKind kind) {
    if (kind == CydiaLegacyUIValueKindVoid)
        return YES;
    if (value == nil || value == [CydiaLegacyUIUndefinedValue value])
        return NO;
    switch (kind) {
        case CydiaLegacyUIValueKindVoid:
        case CydiaLegacyUIValueKindObject:
            return YES;
        case CydiaLegacyUIValueKindString:
            return [value isKindOfClass:[NSString class]];
        case CydiaLegacyUIValueKindNumber:
        case CydiaLegacyUIValueKindBoolean:
            return [value isKindOfClass:[NSNumber class]];
        case CydiaLegacyUIValueKindArray:
            return [value isKindOfClass:[NSArray class]];
    }
    return NO;
}

} // namespace


@implementation CydiaLegacyUIUndefinedValue

+ (instancetype) value {
    static CydiaLegacyUIUndefinedValue *value;
    @synchronized (self) {
        if (value == nil)
            value = (CydiaLegacyUIUndefinedValue *) [super new];
    }
    return value;
}

- (NSString *) description {
    return @"undefined";
}

@end

NSString *CydiaLegacyUICompatibilityCopyMetadataKey(id key) {
    if (![key isKindOfClass:[NSString class]])
        return nil;
    NSString *string((NSString *)key);
    if ([string length] == 0 || [string length] > kMaximumMetadataKeyLength ||
        [string rangeOfCharacterFromSet:[NSCharacterSet controlCharacterSet]].location != NSNotFound)
        return nil;
    @try {
        return [[NSString alloc] initWithString:string];
    } @catch (NSException *exception) {
        (void)exception;
        return nil;
    }
}

BOOL CydiaLegacyUICompatibilityCopyMetadataValue(id value,
                                                  id *copy,
                                                  BOOL *removesValue) {
    if (copy != NULL)
        *copy = nil;
    if (removesValue != NULL)
        *removesValue = NO;

    if (value == nil || value == [NSNull null] ||
        value == [CydiaLegacyUIUndefinedValue value]) {
        if (removesValue != NULL)
            *removesValue = YES;
        return YES;
    }

    NSUInteger nodes(0);
    NSUInteger bytes(0);
    BOOL valid(YES);
    NSMutableSet<NSValue *> *ancestors([NSMutableSet set]);
    id normalized(CopyMetadataNode(value, 0, &nodes, &bytes, ancestors,
        &valid));
    if (!valid || normalized == nil)
        return NO;

    @try {
        NSError *serializationError(nil);
        NSData *plistData([NSPropertyListSerialization
            dataWithPropertyList:normalized
            format:NSPropertyListBinaryFormat_v1_0 options:0
            error:&serializationError]);
        if (plistData == nil || [plistData length] > kMaximumMetadataPayloadBytes)
            return NO;
        NSPropertyListFormat format(NSPropertyListBinaryFormat_v1_0);
        NSError *parseError(nil);
        id immutable([NSPropertyListSerialization
            propertyListWithData:plistData options:NSPropertyListImmutable
            format:&format error:&parseError]);
        if (immutable == nil || ![NSPropertyListSerialization
                propertyList:immutable isValidForFormat:NSPropertyListBinaryFormat_v1_0])
            return NO;
        if (copy != NULL)
            *copy = immutable;
        return YES;
    } @catch (NSException *exception) {
        (void)exception;
        return NO;
    }
}

namespace {

/* Keep localization input bounded and resource-local.  The historical API
 * accepts arbitrary NSString values, but a native compatibility caller must
 * not turn the table argument into a path or feed control characters into a
 * bundle lookup.  The fallback value may be empty (an intentional blank
 * fallback); the key itself must identify a non-empty entry. */
const NSUInteger kMaximumLocalizationComponentLength = 4096;

BOOL IsValidLocalizationComponent(id value, BOOL required, BOOL table) {
    if (IsMissing(value))
        return !required;
    if (!IsString(value))
        return NO;
    NSString *string((NSString *) value);
    if ((required && [string length] == 0) ||
        [string length] > kMaximumLocalizationComponentLength ||
        [string rangeOfCharacterFromSet:[NSCharacterSet controlCharacterSet]].location != NSNotFound)
        return NO;
    if (table && ([string rangeOfString:@"/"].location != NSNotFound ||
                  [string rangeOfString:@"\\"].location != NSNotFound))
        return NO;
    return YES;
}

} // namespace


NSString *CydiaLegacyUICompatibilityLocalizedStringInBundle(NSBundle *bundle,
                                                             id key,
                                                             id value,
                                                             id table) {
    if (![bundle isKindOfClass:[NSBundle class]] ||
        !IsValidLocalizationComponent(key, YES, NO) ||
        !IsValidLocalizationComponent(value, NO, NO) ||
        !IsValidLocalizationComponent(table, NO, YES))
        return nil;

    NSString *fallback(IsMissing(value) ? nil : [(NSString *) value copy]);
    NSString *tableName(IsMissing(table) ? nil : [(NSString *) table copy]);
    @try {
        id localized([bundle localizedStringForKey:(NSString *) key
                                               value:fallback
                                               table:tableName]);
        return [localized isKindOfClass:[NSString class]] ? localized : nil;
    } @catch (NSException *exception) {
        (void)exception;
        return nil;
    }
}

NSString *CydiaLegacyUICompatibilityLocalizedString(id key, id value, id table) {
    return CydiaLegacyUICompatibilityLocalizedStringInBundle(
        [NSBundle mainBundle], key, value, table);
}

namespace {

/* The old bridge accepted a complete printf format and a variadic argument
 * vector.  Keep the compatibility slice deliberately smaller: only object
 * substitutions and escaped percent signs are needed by the first-party
 * pages, and a hand-written parser avoids invoking a format-string engine on
 * untrusted input.  Bounds are expressed in NSString UTF-16 units. */
const NSUInteger kMaximumFormatLength = 4096;
const NSUInteger kMaximumFormatArgumentCount = 64;
const NSUInteger kMaximumFormatValueLength = 4096;
const NSUInteger kMaximumFormattedResultLength = 16384;

BOOL IsSupportedFormatValue(id value) {
    return value == nil || value == [NSNull null] ||
        value == [CydiaLegacyUIUndefinedValue value] || IsString(value) ||
        IsNumber(value);
}

NSString *FormatValueDescription(id value) {
    if (value == nil)
        return @"(null)";
    if (value == [NSNull null])
        return @"<null>";
    if (value == [CydiaLegacyUIUndefinedValue value])
        return @"undefined";
    if (!IsString(value) && !IsNumber(value))
        return nil;

    id description(nil);
    @try {
        description = [value description];
    } @catch (NSException *exception) {
        (void)exception;
        return nil;
    }
    if (![description isKindOfClass:[NSString class]])
        return nil;
    NSString *string((NSString *)description);
    return [string length] <= kMaximumFormatValueLength ? [string copy] : nil;
}

NSArray *FormatValues(id arguments) {
    if ([arguments isKindOfClass:[NSArray class]]) {
        @try {
            if ([(NSArray *)arguments count] > kMaximumFormatArgumentCount)
                return nil;
            return [[NSArray alloc] initWithArray:(NSArray *)arguments
                                        copyItems:NO];
        } @catch (NSException *exception) {
            (void)exception;
            return nil;
        }
    }
    if ([arguments isKindOfClass:[NSOrderedSet class]]) {
        @try {
            if ([(NSOrderedSet *)arguments count] > kMaximumFormatArgumentCount)
                return nil;
            NSArray *array([(NSOrderedSet *)arguments array]);
            return [[NSArray alloc] initWithArray:array copyItems:NO];
        } @catch (NSException *exception) {
            (void)exception;
            return nil;
        }
    }
    return nil;
}

} // namespace


NSString *CydiaLegacyUICompatibilityFormatString(NSString *format, id arguments) {
    if (![format isKindOfClass:[NSString class]] ||
        [format length] > kMaximumFormatLength)
        return nil;

    NSArray *values(FormatValues(arguments));
    if (values == nil || [values count] > kMaximumFormatArgumentCount)
        return nil;

    NSString *source(nil);
    @try {
        /* Copy mutable format/sequence inputs before walking them so a caller
         * cannot change the operation midway through validation. */
        source = [(NSString *)format copy];
    } @catch (NSException *exception) {
        (void)exception;
        return nil;
    }

    NSMutableString *result([NSMutableString stringWithCapacity:[source length]]);
    NSUInteger argumentIndex(0);
    NSUInteger index(0);
    NSUInteger length([source length]);
    @try {
        while (index < length) {
            NSUInteger literalStart(index);
            while (index < length && [source characterAtIndex:index] != '%')
                ++index;
            if (index > literalStart)
                [result appendString:[source substringWithRange:
                    NSMakeRange(literalStart, index - literalStart)]];

            if (index == length)
                break;

            /* A percent must be followed by exactly one allowlisted token;
             * flags, width/precision, positional arguments, and all numeric
             * conversions are intentionally rejected. */
            if (++index >= length)
                return nil;
            unichar token([source characterAtIndex:index++]);
            if (token == '%') {
                [result appendString:@"%"];
            } else if (token == '@') {
                if (argumentIndex >= [values count])
                    return nil;
                id value([values objectAtIndex:argumentIndex++]);
                if (!IsSupportedFormatValue(value))
                    return nil;
                NSString *description(FormatValueDescription(value));
                if (description == nil)
                    return nil;
                [result appendString:description];
            } else {
                return nil;
            }

            if ([result length] > kMaximumFormattedResultLength)
                return nil;
        }
    } @catch (NSException *exception) {
        (void)exception;
        return nil;
    }

    return argumentIndex == [values count] ? [result copy] : nil;
}


@interface CydiaLegacyUICompatibilitySignature ()
- (instancetype) initWithMember:(CydiaLegacyBridgeMember *)member
                   argumentKinds:(NSArray<NSNumber *> *)argumentKinds
                      resultKind:(CydiaLegacyUIValueKind)resultKind
           unavailableConvention:(CydiaLegacyUIUnavailableConvention)unavailableConvention
                    dispatchMode:(CydiaLegacyUIDispatchMode)dispatchMode;
@end

@implementation CydiaLegacyUICompatibilitySignature

- (instancetype) initWithMember:(CydiaLegacyBridgeMember *)member
                   argumentKinds:(NSArray<NSNumber *> *)argumentKinds
                      resultKind:(CydiaLegacyUIValueKind)resultKind
           unavailableConvention:(CydiaLegacyUIUnavailableConvention)unavailableConvention
                    dispatchMode:(CydiaLegacyUIDispatchMode)dispatchMode {
    if ((self = [super init]) != nil) {
        _member = member;
        _argumentKinds = [argumentKinds copy];
        _resultKind = resultKind;
        _unavailableConvention = unavailableConvention;
        _dispatchMode = dispatchMode;
    }
    return self;
}

@end


@implementation CydiaLegacyUICompatibilityInvocation

- (instancetype) initWithScope:(NSString *)scope
                    memberKind:(CydiaLegacyBridgeMemberKind)memberKind
                    memberName:(NSString *)memberName
                       context:(CydiaUIRouteContext *)context
                 callingOrigin:(NSURL *)callingOrigin
               packageIdentity:(NSString *)packageIdentity
                  targetOrigin:(NSURL *)targetOrigin
                     arguments:(NSArray *)arguments {
    if ((self = [super init]) != nil) {
        _scope = [scope copy];
        _memberKind = memberKind;
        _memberName = [memberName copy];
        _context = context;
        _callingOrigin = [callingOrigin copy];
        _packageIdentity = [packageIdentity copy];
        _targetOrigin = [targetOrigin copy];
        _arguments = [arguments copy];
    }
    return self;
}

@end


@interface CydiaLegacyUICompatibilityDecision ()
- (instancetype) initWithSignature:(CydiaLegacyUICompatibilitySignature *)signature
                     authorization:(CydiaLegacyBridgeAuthorization *)authorization
                      denialReason:(CydiaLegacyUICompatibilityDenialReason)denialReason;
@end


@implementation CydiaLegacyUICompatibilityDecision

- (instancetype) initWithSignature:(CydiaLegacyUICompatibilitySignature *)signature
                     authorization:(CydiaLegacyBridgeAuthorization *)authorization
                      denialReason:(CydiaLegacyUICompatibilityDenialReason)denialReason {
    if ((self = [super init]) != nil) {
        _signature = signature;
        _authorization = authorization;
        _denialReason = denialReason;
        _unavailableValue = UnavailableValue(signature == nil ?
            CydiaLegacyUIUnavailableConventionUndefined :
            [signature unavailableConvention]);
    }
    return self;
}

- (BOOL) isAllowed {
    return _denialReason == CydiaLegacyUICompatibilityDenialReasonNone &&
        [_authorization isAllowed];
}

@end


#define CYDIA_LEGACY_UI_RESULT_void CydiaLegacyUIValueKindVoid
#define CYDIA_LEGACY_UI_RESULT_object CydiaLegacyUIValueKindObject
#define CYDIA_LEGACY_UI_RESULT_string CydiaLegacyUIValueKindString
#define CYDIA_LEGACY_UI_RESULT_number CydiaLegacyUIValueKindNumber
#define CYDIA_LEGACY_UI_RESULT_boolean CydiaLegacyUIValueKindBoolean
#define CYDIA_LEGACY_UI_RESULT_array CydiaLegacyUIValueKindArray
#define CYDIA_LEGACY_UI_UNAVAILABLE_undefined CydiaLegacyUIUnavailableConventionUndefined
#define CYDIA_LEGACY_UI_UNAVAILABLE_null_value CydiaLegacyUIUnavailableConventionNull
#define CYDIA_LEGACY_UI_UNAVAILABLE_false_value CydiaLegacyUIUnavailableConventionFalse
#define CYDIA_LEGACY_UI_DISPATCH_synchronous CydiaLegacyUIDispatchModeSynchronous
#define CYDIA_LEGACY_UI_DISPATCH_main_async CydiaLegacyUIDispatchModeMainThreadAsync
#define CYDIA_LEGACY_UI_DISPATCH_native_confirmation CydiaLegacyUIDispatchModeNativeConfirmation
#define CYDIA_LEGACY_UI_ARGUMENT_string CydiaLegacyUIArgumentKindString
#define CYDIA_LEGACY_UI_ARGUMENT_optional_string CydiaLegacyUIArgumentKindOptionalString
#define CYDIA_LEGACY_UI_ARGUMENT_number CydiaLegacyUIArgumentKindNumber
#define CYDIA_LEGACY_UI_ARGUMENT_optional_number CydiaLegacyUIArgumentKindOptionalNumber
#define CYDIA_LEGACY_UI_ARGUMENT_boolean_like CydiaLegacyUIArgumentKindBooleanLike
#define CYDIA_LEGACY_UI_ARGUMENT_optional_boolean_like CydiaLegacyUIArgumentKindOptionalBooleanLike
#define CYDIA_LEGACY_UI_ARGUMENT_sequence CydiaLegacyUIArgumentKindSequence
#define CYDIA_LEGACY_UI_ARGUMENT_opaque CydiaLegacyUIArgumentKindOpaque
#define CYDIA_LEGACY_UI_ARGUMENT_optional_any CydiaLegacyUIArgumentKindOptionalAny
#define CYDIA_LEGACY_UI_ARGUMENT_url_string CydiaLegacyUIArgumentKindURLString
#define CYDIA_LEGACY_UI_ARGUMENT_metadata_key CydiaLegacyUIArgumentKindMetadataKey
#define CYDIA_LEGACY_UI_ARGUMENT_optional_property_list CydiaLegacyUIArgumentKindOptionalPropertyList

namespace {

NSArray<NSNumber *> *Arguments(NSString *first, NSString *second,
                               NSString *third, NSString *fourth) {
    NSMutableArray<NSNumber *> *arguments([NSMutableArray arrayWithCapacity:4]);
    for (NSString *token in @[first, second, third, fourth]) {
        if ([token isEqualToString:@"none"])
            break;
#define CYDIA_LEGACY_UI_ARGUMENT_CASE(value) \
        if ([token isEqualToString:@#value]) { \
            [arguments addObject:@(CYDIA_LEGACY_UI_ARGUMENT_##value)]; \
            continue; \
        }
        CYDIA_LEGACY_UI_ARGUMENT_CASE(string)
        CYDIA_LEGACY_UI_ARGUMENT_CASE(optional_string)
        CYDIA_LEGACY_UI_ARGUMENT_CASE(number)
        CYDIA_LEGACY_UI_ARGUMENT_CASE(optional_number)
        CYDIA_LEGACY_UI_ARGUMENT_CASE(boolean_like)
        CYDIA_LEGACY_UI_ARGUMENT_CASE(optional_boolean_like)
        CYDIA_LEGACY_UI_ARGUMENT_CASE(sequence)
        CYDIA_LEGACY_UI_ARGUMENT_CASE(opaque)
        CYDIA_LEGACY_UI_ARGUMENT_CASE(optional_any)
        CYDIA_LEGACY_UI_ARGUMENT_CASE(url_string)
        CYDIA_LEGACY_UI_ARGUMENT_CASE(metadata_key)
        CYDIA_LEGACY_UI_ARGUMENT_CASE(optional_property_list)
#undef CYDIA_LEGACY_UI_ARGUMENT_CASE
        return nil;
    }
    return arguments;
}

CydiaLegacyUIValueKind ValueKindForNonMethod(CydiaLegacyBridgeMember *member) {
    NSString *scope([member scope]);
    NSString *name([member name]);
    if ([member kind] == CydiaLegacyBridgeMemberKindKeyPolicy)
        return CydiaLegacyUIValueKindBoolean;
    if ([member kind] == CydiaLegacyBridgeMemberKindGlobal ||
        [member kind] == CydiaLegacyBridgeMemberKindDynamicMethod)
        return [name isEqualToString:@"keys"] ?
            CydiaLegacyUIValueKindArray : CydiaLegacyUIValueKindObject;

    NSSet *arrayMembers([NSSet setWithArray:@[
        @"CydiaObject.cells", @"Package.applications", @"Package.purposes",
        @"Package.relations", @"Package.tags", @"Package.warnings",
        @"Source.sections", @"CydiaRelation.clauses",
        @"CydiaProgressData.events",
    ]]);
    NSSet *numberMembers([NSSet setWithArray:@[
        @"CyteObject.bittage", @"Package.size", @"CydiaProgressData.current",
        @"CydiaProgressData.finish", @"CydiaProgressData.percent",
        @"CydiaProgressData.speed", @"CydiaProgressData.total",
    ]]);
    NSSet *booleanMembers([NSSet setWithArray:@[
        @"Package.essential", @"Package.upgraded", @"Source.trusted",
        @"CydiaProgressData.running",
    ]]);
    NSString *key([NSString stringWithFormat:@"%@.%@", scope, name]);
    if ([arrayMembers containsObject:key])
        return CydiaLegacyUIValueKindArray;
    if ([numberMembers containsObject:key])
        return CydiaLegacyUIValueKindNumber;
    if ([booleanMembers containsObject:key])
        return CydiaLegacyUIValueKindBoolean;
    return CydiaLegacyUIValueKindObject;
}

CydiaLegacyUIUnavailableConvention UnavailableConventionForNonMethod(
    CydiaLegacyBridgeMember *member) {
    if ([member kind] == CydiaLegacyBridgeMemberKindKeyPolicy)
        return CydiaLegacyUIUnavailableConventionFalse;
    NSString *key([NSString stringWithFormat:@"%@.%@",
        [member scope], [member name]]);
    NSSet *legacyNullMembers([NSSet setWithArray:@[
        @"CyteObject.bbsnum", @"CyteObject.ecid", @"CydiaObject.role",
        @"CydiaClause.version",
    ]]);
    return [legacyNullMembers containsObject:key] ?
        CydiaLegacyUIUnavailableConventionNull :
        CydiaLegacyUIUnavailableConventionUndefined;
}

NSArray<NSNumber *> *ArgumentsForNonMethod(CydiaLegacyBridgeMember *member) {
    if ([member kind] != CydiaLegacyBridgeMemberKindDynamicMethod)
        return @[];
    return [[member name] isEqualToString:@"get"] ?
        @[@(CydiaLegacyUIArgumentKindOptionalAny)] : @[];
}

CydiaLegacyUICompatibilitySignature *SignatureForNonMethod(
    CydiaLegacyBridgeMember *member) {
    return [[CydiaLegacyUICompatibilitySignature alloc]
        initWithMember:member
        argumentKinds:ArgumentsForNonMethod(member)
        resultKind:ValueKindForNonMethod(member)
        unavailableConvention:UnavailableConventionForNonMethod(member)
        dispatchMode:CydiaLegacyUIDispatchModeSynchronous];
}

} // namespace


NSArray<CydiaLegacyUICompatibilitySignature *> *CydiaLegacyUICompatibilitySignatures(void) {
    static NSArray<CydiaLegacyUICompatibilitySignature *> *signatures;
    @synchronized ([CydiaLegacyUICompatibilitySignature class]) {
        if (signatures == nil) {
#define CYDIA_LEGACY_UI_SIGNATURE(scope, name, result, unavailable, dispatch, first, second, third, fourth) \
            [[CydiaLegacyUICompatibilitySignature alloc] \
                initWithMember:CydiaLegacyBridgeMemberForName(@#scope, \
                    CydiaLegacyBridgeMemberKindMethod, @#name) \
                argumentKinds:Arguments(@#first, @#second, @#third, @#fourth) \
                resultKind:CYDIA_LEGACY_UI_RESULT_##result \
                unavailableConvention:CYDIA_LEGACY_UI_UNAVAILABLE_##unavailable \
                dispatchMode:CYDIA_LEGACY_UI_DISPATCH_##dispatch],
            NSMutableArray<CydiaLegacyUICompatibilitySignature *> *built(
                [NSMutableArray arrayWithArray:@[
#include "Cydia/LegacyUICompatibilitySignatures.def"
            ]]);
#undef CYDIA_LEGACY_UI_SIGNATURE
            for (CydiaLegacyBridgeMember *member in CydiaLegacyBridgeMembers())
                if ([member kind] != CydiaLegacyBridgeMemberKindMethod)
                    [built addObject:SignatureForNonMethod(member)];
            signatures = [built copy];
        }
    }
    return signatures;
}

CydiaLegacyUICompatibilitySignature *CydiaLegacyUICompatibilitySignatureForMember(
    NSString *scope, CydiaLegacyBridgeMemberKind kind, NSString *name) {
    for (CydiaLegacyUICompatibilitySignature *signature in
            CydiaLegacyUICompatibilitySignatures()) {
        CydiaLegacyBridgeMember *member([signature member]);
        if ([member kind] == kind && [[member scope] isEqualToString:scope] &&
            [[member name] isEqualToString:name])
            return signature;
    }
    return nil;
}

CydiaLegacyUICompatibilityDecision *CydiaLegacyUIEvaluateCompatibilityInvocation(
    CydiaLegacyUICompatibilityInvocation *invocation) {
    if (![invocation isKindOfClass:[CydiaLegacyUICompatibilityInvocation class]])
        return [[CydiaLegacyUICompatibilityDecision alloc]
            initWithSignature:nil authorization:CydiaLegacyBridgeAuthorize(nil)
            denialReason:CydiaLegacyUICompatibilityDenialReasonPolicy];

    CydiaLegacyUICompatibilitySignature *signature(
        CydiaLegacyUICompatibilitySignatureForMember([invocation scope],
            [invocation memberKind], [invocation memberName]));
    CydiaLegacyBridgeRequest *request([[CydiaLegacyBridgeRequest alloc]
        initWithScope:[invocation scope]
        memberKind:[invocation memberKind]
        memberName:[invocation memberName]
        context:[invocation context]
        callingOrigin:[invocation callingOrigin]
        packageIdentity:[invocation packageIdentity]
        targetOrigin:[invocation targetOrigin]
        inProcessCapability:[[invocation context] inProcessCapability]]);
    CydiaLegacyBridgeAuthorization *authorization(CydiaLegacyBridgeAuthorize(request));
    if (signature == nil || ![authorization isAllowed])
        return [[CydiaLegacyUICompatibilityDecision alloc]
            initWithSignature:signature authorization:authorization
            denialReason:CydiaLegacyUICompatibilityDenialReasonPolicy];

    NSArray *arguments([invocation arguments]);
    NSArray<NSNumber *> *kinds([signature argumentKinds]);
    if (![arguments isKindOfClass:[NSArray class]] || [arguments count] != [kinds count])
        return [[CydiaLegacyUICompatibilityDecision alloc]
            initWithSignature:signature authorization:authorization
            denialReason:CydiaLegacyUICompatibilityDenialReasonMalformedArguments];
    for (NSUInteger index(0); index != [kinds count]; ++index)
        if (!IsValidArgument([arguments objectAtIndex:index],
                (CydiaLegacyUIArgumentKind) [[kinds objectAtIndex:index]
                    unsignedIntegerValue]))
            return [[CydiaLegacyUICompatibilityDecision alloc]
                initWithSignature:signature authorization:authorization
                denialReason:CydiaLegacyUICompatibilityDenialReasonMalformedArguments];

    return [[CydiaLegacyUICompatibilityDecision alloc]
        initWithSignature:signature authorization:authorization
        denialReason:CydiaLegacyUICompatibilityDenialReasonNone];
}


@implementation CydiaLegacyUICompatibilityService

- (instancetype) initWithContext:(CydiaUIRouteContext *)context
                   callingOrigin:(NSURL *)callingOrigin
                 packageIdentity:(NSString *)packageIdentity {
    return [self initWithContext:context callingOrigin:callingOrigin
        packageIdentity:packageIdentity executor:nil];
}

- (instancetype) initWithContext:(CydiaUIRouteContext *)context
                   callingOrigin:(NSURL *)callingOrigin
                 packageIdentity:(NSString *)packageIdentity
                        executor:(id<CydiaLegacyUICompatibilityExecuting>)executor {
    if ((self = [super init]) != nil) {
        _context = context;
        _callingOrigin = [callingOrigin copy];
        _packageIdentity = [packageIdentity copy];
        _executor = executor;
    }
    return self;
}

- (BOOL) isExecutable {
    return _executor != nil;
}

- (CydiaLegacyUICompatibilityDecision *) decisionForScope:(NSString *)scope
                                                memberKind:(CydiaLegacyBridgeMemberKind)memberKind
                                                memberName:(NSString *)memberName
                                                 arguments:(NSArray *)arguments
                                              targetOrigin:(NSURL *)targetOrigin {
    CydiaLegacyUICompatibilityInvocation *invocation(
        [[CydiaLegacyUICompatibilityInvocation alloc]
            initWithScope:scope memberKind:memberKind memberName:memberName
            context:_context callingOrigin:_callingOrigin
            packageIdentity:_packageIdentity targetOrigin:targetOrigin
            arguments:arguments]);
    return CydiaLegacyUIEvaluateCompatibilityInvocation(invocation);
}

- (id) invokeScope:(NSString *)scope
         memberKind:(CydiaLegacyBridgeMemberKind)memberKind
         memberName:(NSString *)memberName
          arguments:(NSArray *)arguments
       targetOrigin:(NSURL *)targetOrigin {
    CydiaLegacyUICompatibilityInvocation *invocation(
        [[CydiaLegacyUICompatibilityInvocation alloc]
            initWithScope:scope memberKind:memberKind memberName:memberName
            context:_context callingOrigin:_callingOrigin
            packageIdentity:_packageIdentity targetOrigin:targetOrigin
            arguments:arguments]);
    CydiaLegacyUICompatibilityDecision *decision(
        CydiaLegacyUIEvaluateCompatibilityInvocation(invocation));
    /* Capture the weak executor before dispatch. This keeps an explicitly
     * retained backend alive for the duration of a call while preserving the
     * intentional policy-only behavior once its owner releases it. */
    id<CydiaLegacyUICompatibilityExecuting> executor(_executor);
    if (![decision isAllowed] || executor == nil)
        return [decision unavailableValue];

    CydiaLegacyUICompatibilitySignature *signature([decision signature]);
    switch ([signature dispatchMode]) {
        case CydiaLegacyUIDispatchModeSynchronous: {
            id value([executor legacyUICompatibilityService:self
                executeSynchronousInvocation:invocation]);
            return IsValidResult(value, [signature resultKind]) ?
                value : [decision unavailableValue];
        }
        case CydiaLegacyUIDispatchModeMainThreadAsync:
            [executor legacyUICompatibilityService:self
                enqueueMainThreadInvocation:invocation];
            return [decision unavailableValue];
        case CydiaLegacyUIDispatchModeNativeConfirmation: {
            BOOL accepted([executor legacyUICompatibilityService:self
                requestNativeConfirmationForInvocation:invocation]);
            return [signature resultKind] == CydiaLegacyUIValueKindBoolean ?
                @(accepted) : [decision unavailableValue];
        }
    }
    return [decision unavailableValue];
}

@end


#undef CYDIA_LEGACY_UI_ARGUMENT_url_string
#undef CYDIA_LEGACY_UI_ARGUMENT_optional_property_list
#undef CYDIA_LEGACY_UI_ARGUMENT_metadata_key
#undef CYDIA_LEGACY_UI_ARGUMENT_optional_any
#undef CYDIA_LEGACY_UI_ARGUMENT_opaque
#undef CYDIA_LEGACY_UI_ARGUMENT_sequence
#undef CYDIA_LEGACY_UI_ARGUMENT_optional_boolean_like
#undef CYDIA_LEGACY_UI_ARGUMENT_boolean_like
#undef CYDIA_LEGACY_UI_ARGUMENT_optional_number
#undef CYDIA_LEGACY_UI_ARGUMENT_number
#undef CYDIA_LEGACY_UI_ARGUMENT_optional_string
#undef CYDIA_LEGACY_UI_ARGUMENT_string
#undef CYDIA_LEGACY_UI_DISPATCH_native_confirmation
#undef CYDIA_LEGACY_UI_DISPATCH_main_async
#undef CYDIA_LEGACY_UI_DISPATCH_synchronous
#undef CYDIA_LEGACY_UI_UNAVAILABLE_false_value
#undef CYDIA_LEGACY_UI_UNAVAILABLE_null_value
#undef CYDIA_LEGACY_UI_UNAVAILABLE_undefined
#undef CYDIA_LEGACY_UI_RESULT_array
#undef CYDIA_LEGACY_UI_RESULT_boolean
#undef CYDIA_LEGACY_UI_RESULT_number
#undef CYDIA_LEGACY_UI_RESULT_string
#undef CYDIA_LEGACY_UI_RESULT_object
#undef CYDIA_LEGACY_UI_RESULT_void
