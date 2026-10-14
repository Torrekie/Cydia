/* Cydia Refurbished native package-detail state boundary.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "Cydia/PackageDetailViewModel.h"
#import "Cydia/PackageArchitecturePresentation.h"
#include "Cydia/AptCompatibility.hpp"

#include <ctime>

@protocol CydiaPackageDetailAddressSource <NSObject>
- (nullable NSString *)name;
- (nullable NSString *)address;
@end

BOOL CydiaPackageDetailCanPerformAction(CydiaPackageDetailViewModel *selected,
    CydiaPackageDetailViewModel *current, CydiaPackageDetailModifyActionKind kind) {
    if (selected == nil || current == nil || selected.readOnly || current.readOnly) return NO;
    auto equal = [](id left, id right) { return left == right || [left isEqual:right]; };
    if (!equal(selected.identity, current.identity) ||
        !equal(selected.fullVersion, current.fullVersion) ||
        !equal(selected.architecture, current.architecture)) return NO;
    BOOL offered = NO;
    for (CydiaPackageDetailModifyAction *action in current.modifyActions)
        if (action.kind == kind) { offered = YES; break; }
    if (!offered) return NO;
    switch (kind) {
        case CydiaPackageDetailModifyActionKindInstall:
        case CydiaPackageDetailModifyActionKindUpgrade:
        case CydiaPackageDetailModifyActionKindDowngrade:
        case CydiaPackageDetailModifyActionKindReinstall:
            return equal(selected.source.key, current.source.key) &&
                equal(selected.source.repositoryURLString, current.source.repositoryURLString);
        default: return YES;
    }
}

@protocol CydiaPackageDetailSourceSource <NSObject>
- (nullable NSString *)key;
- (nullable NSString *)rooturi;
- (nullable NSString *)name;
- (nullable NSString *)shortDescription;
- (nullable NSString *)host;
- (nullable NSURL *)iconURL;
@end


@protocol CydiaPackageDetailPackageSource <NSObject>
- (void)parse;
- (nullable NSString *)id;
- (nullable NSString *)baseId;
- (nullable NSString *)aptId;
- (nullable NSString *)dpkgId;
- (nullable NSString *)name;
- (nullable NSString *)latest;
- (nullable NSString *)installed;
- (nullable NSString *)md5sum;
- (nullable NSString *)architecture;
- (nullable NSString *)multiArch;
- (nullable NSString *)section;
- (nullable NSString *)simpleSection;
- (nullable NSString *)longSection;
- (nullable NSString *)shortSection;
- (nullable NSString *)shortDescription;
- (nullable NSString *)longDescription;
- (size_t)size;
- (nullable NSString *)mode;
- (nullable NSString *)state;
- (nullable NSString *)selection;
- (nullable NSArray *)warnings;
- (BOOL)uninstalled;
- (BOOL)upgradableAndEssential:(BOOL)essential;
- (BOOL)ignored;
- (BOOL)essential;
- (bool)isCommercial;
- (BOOL)hasTag:(NSString *)tag;
- (nullable id<CydiaPackageDetailAddressSource>)author;
- (nullable id<CydiaPackageDetailAddressSource>)maintainer;
- (nullable NSString *)support;
- (nullable NSString *)homepage;
- (nullable NSString *)depiction;
- (nullable id<CydiaPackageDetailSourceSource>)source;
- (nullable NSArray *)applications;
- (nullable NSArray *)downgrades;
@optional
- (nullable NSString *)fullVersion;
- (BOOL) architectureSupported;
- (BOOL) protectedPackage;
- (BOOL) canReinstall;
- (BOOL) hasSavedConfiguration;
- (BOOL) versionAvailable;
- (BOOL) policyCandidate;
- (BOOL) selectedVersionInstalled;
- (NSInteger) versionPriority;
- (NSInteger) versionComparison;
- (nullable NSArray *)availableVersions;
- (nullable NSString *)getField:(NSString *)name;
- (nullable NSString *)getRecord;
- (nullable NSArray *)tags;
- (nullable NSArray *)purposes;
- (nullable NSArray *)relations;
- (time_t)upgraded;
@end

@protocol CydiaPackageDetailSourceSnapshotSource <NSObject>
@optional
- (nullable NSString *)getField:(NSString *)name;
- (nullable NSDictionary *)record;
- (nullable NSArray *)sections;
- (BOOL)trusted;
- (nullable NSString *)rooturi;
- (nullable NSString *)distribution;
- (nullable NSString *)type;
- (nullable NSString *)baseuri;
- (nullable NSString *)iconuri;
- (nullable NSString *)key;
- (nullable NSString *)host;
- (nullable NSString *)name;
- (nullable NSString *)shortDescription;
- (nullable NSString *)label;
- (nullable NSString *)origin;
- (nullable NSString *)version;
@end

@protocol CydiaPackageDetailRelationSnapshotSource <NSObject>
@optional
- (nullable NSString *)relationship;
- (nullable NSArray *)clauses;
@end

@protocol CydiaPackageDetailClauseSnapshotSource <NSObject>
@optional
- (nullable NSString *)package;
- (nullable id)version;
@end

@protocol CydiaPackageDetailOperationSnapshotSource <NSObject>
@optional
- (nullable NSString *)operator;
- (nullable NSString *)value;
@end

namespace {

NSString *ActionText(NSString *key) {
    return [[NSBundle mainBundle] localizedStringForKey:key value:key table:@"Actions"];
}

NSString *StringOrNil(id value) {
    if (![value isKindOfClass:[NSString class]] || [value length] == 0)
        return nil;
    return [value copy];
}

NSString *URLStringOrNil(id value) {
    if ([value isKindOfClass:[NSURL class]])
        value = [value absoluteString];
    return StringOrNil(value);
}

NSString *RepositoryText(id value, NSUInteger limit, BOOL multiline = NO) {
    if (![value isKindOfClass:NSString.class] || [value length] == 0 || [value length] > limit)
        return nil;
    NSMutableCharacterSet *controls([NSCharacterSet.controlCharacterSet mutableCopy]);
    if (multiline) [controls removeCharactersInString:@"\n\r\t"];
    return [value rangeOfCharacterFromSet:controls].location == NSNotFound ? [value copy] : nil;
}

NSString *RepositoryText(const std::string &value, NSUInteger limit, BOOL multiline = NO) {
    if (value.empty() || value.size() > limit * 4) return nil;
    return RepositoryText([[NSString alloc] initWithBytes:value.data() length:value.size()
        encoding:NSUTF8StringEncoding], limit, multiline);
}

NSString *RepositoryField(const CydiaAPT::PackageRecordData &record, const char *name,
    NSUInteger limit = 4096, BOOL multiline = NO) {
    const auto field(record.fields.find(name));
    return field == record.fields.end() ? nil : RepositoryText(field->second, limit, multiline);
}

NSString *RepositoryURLString(id value) {
    NSString *text(RepositoryText([value isKindOfClass:NSURL.class] ? [value absoluteString] : value, 8192));
    NSURLComponents *parts(text == nil ? nil : [NSURLComponents componentsWithString:text]);
    NSString *decoded(text.stringByRemovingPercentEncoding);
    if (parts == nil || !([parts.scheme.lowercaseString isEqual:@"https"] ||
        [parts.scheme.lowercaseString isEqual:@"http"]) || !parts.host.length ||
        parts.user != nil || parts.password != nil || decoded == nil ||
        [decoded rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound ||
        (parts.port != nil && (parts.port.integerValue < 1 || parts.port.integerValue > 65535))) return nil;
    return text;
}

NSArray<NSString *> *StringArray(id value) {
    if (![value isKindOfClass:[NSArray class]])
        return @[];
    NSMutableArray<NSString *> *strings([NSMutableArray array]);
    for (id item in value) {
        NSString *string(StringOrNil(item));
        if (string != nil)
            [strings addObject:string];
    }
    return [strings copy];
}

id PropertyListValue(id value, NSUInteger depth) {
    if (value == nil || value == [NSNull null])
        return value == [NSNull null] ? [NSNull null] : nil;
    if (depth > 6)
        return nil;
    if ([value isKindOfClass:[NSString class]])
        return [value copy];
    if ([value isKindOfClass:[NSNumber class]])
        return [value copy];
    if ([value isKindOfClass:[NSURL class]])
        return [[value absoluteString] copy];
    if ([value isKindOfClass:[NSArray class]]) {
        NSMutableArray *array([NSMutableArray array]);
        for (id item in (NSArray *)value) {
            id converted(PropertyListValue(item, depth + 1));
            if (converted != nil)
                [array addObject:converted];
        }
        return [array copy];
    }
    if ([value isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *dictionary([NSMutableDictionary dictionary]);
        for (id key in (NSDictionary *)value) {
            if (![key isKindOfClass:[NSString class]] ||
                [key length] == 0 || [key rangeOfString:@"__"].location == 0)
                continue;
            id converted(PropertyListValue([(NSDictionary *)value objectForKey:key],
                                           depth + 1));
            if (converted != nil)
                [dictionary setObject:converted forKey:key];
        }
        return [dictionary copy];
    }
    return nil;
}

NSDictionary *AddressSnapshot(id address) {
    if (address == nil)
        return nil;
    id<CydiaPackageDetailAddressSource> value((id<CydiaPackageDetailAddressSource>)address);
    NSString *name(StringOrNil([value name]));
    NSString *addressText(StringOrNil([value address]));
    if (name == nil && addressText == nil)
        return nil;
    NSMutableDictionary *result([NSMutableDictionary dictionary]);
    if (name != nil)
        [result setObject:name forKey:@"name"];
    if (addressText != nil)
        [result setObject:addressText forKey:@"address"];
    return [result copy];
}

NSDictionary *OperationSnapshot(id operation) {
    if (operation == nil || operation == [NSNull null])
        return operation == [NSNull null] ? (id) [NSNull null] : nil;
    id<CydiaPackageDetailOperationSnapshotSource> value(
        (id<CydiaPackageDetailOperationSnapshotSource>)operation);
    NSString *operatorValue([value respondsToSelector:@selector(operator)] ?
        StringOrNil([value operator]) : nil);
    NSString *version([value respondsToSelector:@selector(value)] ?
        StringOrNil([value value]) : nil);
    if (operatorValue == nil && version == nil)
        return nil;
    NSMutableDictionary *result([NSMutableDictionary dictionary]);
    if (operatorValue != nil)
        [result setObject:operatorValue forKey:@"operator"];
    if (version != nil)
        [result setObject:version forKey:@"value"];
    return [result copy];
}

NSDictionary *ClauseSnapshot(id clause) {
    id<CydiaPackageDetailClauseSnapshotSource> value(
        (id<CydiaPackageDetailClauseSnapshotSource>)clause);
    NSString *package([value respondsToSelector:@selector(package)] ?
        StringOrNil([value package]) : nil);
    if (package == nil)
        return nil;
    NSMutableDictionary *result([NSMutableDictionary dictionaryWithObject:package
                                                                         forKey:@"package"]);
    id version([value respondsToSelector:@selector(version)] ?
        OperationSnapshot([value version]) : nil);
    if (version != nil)
        [result setObject:version forKey:@"version"];
    return [result copy];
}

NSArray *RelationsSnapshot(id relations) {
    if (![relations isKindOfClass:[NSArray class]])
        return @[];
    NSMutableArray *result([NSMutableArray array]);
    for (id relation in (NSArray *)relations) {
        id<CydiaPackageDetailRelationSnapshotSource> value(
            (id<CydiaPackageDetailRelationSnapshotSource>)relation);
        NSString *relationship([value respondsToSelector:@selector(relationship)] ?
            StringOrNil([value relationship]) : nil);
        NSArray *clauses([value respondsToSelector:@selector(clauses)] ?
            [value clauses] : nil);
        if (relationship == nil || ![clauses isKindOfClass:[NSArray class]])
            continue;
        NSMutableArray *clauseValues([NSMutableArray array]);
        for (id clause in clauses) {
            NSDictionary *snapshot(ClauseSnapshot(clause));
            if (snapshot != nil)
                [clauseValues addObject:snapshot];
        }
        [result addObject:@{ @"relationship": relationship,
                             @"clauses": [clauseValues copy] }];
    }
    return [result copy];
}

NSDictionary *SourceSnapshot(id source) {
    if (source == nil)
        return nil;
    id<CydiaPackageDetailSourceSnapshotSource> value(
        (id<CydiaPackageDetailSourceSnapshotSource>)source);
    NSMutableDictionary *result([NSMutableDictionary dictionary]);
    NSArray *names(@[ @"baseuri", @"distribution", @"host", @"key", @"iconuri",
                      @"label", @"name", @"origin", @"rooturi", @"shortDescription",
                      @"type", @"version" ]);
    for (NSString *name in names) {
        id candidate;
        if ([name isEqualToString:@"baseuri"] && [value respondsToSelector:@selector(baseuri)]) candidate = [value baseuri];
        else if ([name isEqualToString:@"distribution"] && [value respondsToSelector:@selector(distribution)]) candidate = [value distribution];
        else if ([name isEqualToString:@"host"] && [value respondsToSelector:@selector(host)]) candidate = [value host];
        else if ([name isEqualToString:@"key"] && [value respondsToSelector:@selector(key)]) candidate = [value key];
        else if ([name isEqualToString:@"iconuri"] && [value respondsToSelector:@selector(iconuri)]) candidate = [value iconuri];
        else if ([name isEqualToString:@"label"] && [value respondsToSelector:@selector(label)]) candidate = [value label];
        else if ([name isEqualToString:@"name"] && [value respondsToSelector:@selector(name)]) candidate = [value name];
        else if ([name isEqualToString:@"origin"] && [value respondsToSelector:@selector(origin)]) candidate = [value origin];
        else if ([name isEqualToString:@"rooturi"] && [value respondsToSelector:@selector(rooturi)]) candidate = [value rooturi];
        else if ([name isEqualToString:@"shortDescription"] && [value respondsToSelector:@selector(shortDescription)]) candidate = [value shortDescription];
        else if ([name isEqualToString:@"type"] && [value respondsToSelector:@selector(type)]) candidate = [value type];
        else if ([name isEqualToString:@"version"] && [value respondsToSelector:@selector(version)]) candidate = [value version];
        else candidate = nil;
        id converted(PropertyListValue(candidate, 0));
        if (converted != nil)
            [result setObject:converted forKey:name];
    }
    NSArray *sections([value respondsToSelector:@selector(sections)] ?
        PropertyListValue([value sections], 0) : nil);
    if (sections != nil)
        [result setObject:sections forKey:@"sections"];
    NSDictionary *record([value respondsToSelector:@selector(record)] ?
        PropertyListValue([value record], 0) : nil);
    if (record != nil)
        [result setObject:record forKey:@"record"];
    if ([value respondsToSelector:@selector(trusted)])
        [result setObject:@([value trusted]) forKey:@"trusted"];
    return [result copy];
}

} // namespace


@interface CydiaPackageDetailSource ()
- (instancetype)initWithSource:(id<CydiaPackageDetailSourceSource>)source;
- (instancetype)initWithRepositoryURLString:(NSString *)URLString name:(NSString *)name;
@end

@implementation CydiaPackageDetailSource

- (instancetype)initWithSource:(id<CydiaPackageDetailSourceSource>)source {
    if ((self = [super init]) != nil) {
        _key = StringOrNil([source key]);
        _repositoryURLString = [source respondsToSelector:@selector(rooturi)] ? StringOrNil([source rooturi]) : nil;
        _name = StringOrNil([source name]) ?: @"";
        _sourceDescription = StringOrNil([source shortDescription]);
        _host = StringOrNil([source host]);
        _iconURLString = URLStringOrNil([source iconURL]);
    }
    return self;
}

- (instancetype)initWithRepositoryURLString:(NSString *)URLString name:(NSString *)name {
    if ((self = [super init]) != nil) {
        _repositoryURLString = [URLString copy];
        _host = [[[NSURL URLWithString:URLString] host] copy];
        _name = RepositoryText(name, 512) ?: _host ?: @"";
    }
    return self;
}

@end


@interface CydiaPackageDetailApplication ()
- (nullable instancetype)initWithLegacyArray:(id)value;
@end

@implementation CydiaPackageDetailApplication

- (nullable instancetype)initWithLegacyArray:(id)value {
    if (![value isKindOfClass:[NSArray class]] || [value count] < 2)
        return nil;
    NSString *identifier(StringOrNil([value objectAtIndex:0]));
    NSString *name(StringOrNil([value objectAtIndex:1]));
    if (identifier == nil || name == nil)
        return nil;
    if ((self = [super init]) != nil) {
        _bundleIdentifier = identifier;
        _displayName = name;
        _iconURLString = [value count] < 3 ? nil : URLStringOrNil([value objectAtIndex:2]);
    }
    return self;
}

@end


@interface CydiaPackageDetailVersionChoice ()
- (nullable instancetype)initWithPackage:(id<CydiaPackageDetailPackageSource>)package
               registeredArchitectures:(NSArray<NSString *> *)registeredArchitectures;
@end

@implementation CydiaPackageDetailVersionChoice

- (nullable instancetype)initWithPackage:(id<CydiaPackageDetailPackageSource>)package
               registeredArchitectures:(NSArray<NSString *> *)registeredArchitectures {
    if (![package respondsToSelector:@selector(id)] ||
        ![package respondsToSelector:@selector(latest)])
        return nil;
    NSString *identity(StringOrNil([package id]));
    NSString *version(StringOrNil([package latest]));
    if (identity == nil || version == nil)
        return nil;
    if ((self = [super init]) != nil) {
        _identity = identity;
        _version = version;
        _fullVersion = [([package respondsToSelector:@selector(fullVersion)] ?
            StringOrNil([package fullVersion]) : version) copy];
        _version = _fullVersion;
        _architecture = [package respondsToSelector:@selector(architecture)] ? StringOrNil([package architecture]) : nil;
        _architectureCaption = [CydiaPackageArchitectureCaption(_architecture, registeredArchitectures) copy];
        _priority = [package respondsToSelector:@selector(versionPriority)] ? [package versionPriority] : 0;
        _candidate = [package respondsToSelector:@selector(policyCandidate)] && [package policyCandidate];
        _installed = [package respondsToSelector:@selector(selectedVersionInstalled)] && [package selectedVersionInstalled];
    }
    return self;
}

@end


@interface CydiaPackageDetailModifyAction ()
- (instancetype)initWithKind:(CydiaPackageDetailModifyActionKind)kind
                         key:(NSString *)key
                    versions:(NSArray<CydiaPackageDetailVersionChoice *> *)versions;
@end

@implementation CydiaPackageDetailModifyAction

- (instancetype)initWithKind:(CydiaPackageDetailModifyActionKind)kind
                         key:(NSString *)key
                    versions:(NSArray<CydiaPackageDetailVersionChoice *> *)versions {
    if ((self = [super init]) != nil) {
        _kind = kind;
        _titleLocalizationKey = [key copy];
        _versions = [versions copy];
    }
    return self;
}

@end


@implementation CydiaPackageDetailViewModel

- (nullable instancetype)initWithRepositoryPackage:(const CydiaAPT::RepositoryPackageAvailabilityData &)availability
                                      identifier:(NSString *)identifier
                                       sourceURL:(NSURL *)sourceURL
                                      sourceName:(NSString *)sourceName
                        registeredArchitectures:(NSArray<NSString *> *)architectures {
    NSString *identity(RepositoryText(identifier, 256));
    NSString *URLString(RepositoryURLString(sourceURL));
    if (identity == nil || URLString == nil) return nil;
    if ((self = [super init]) != nil) {
        _readOnly = YES;
        _identity = identity;
        _baseIdentity = identity;
        _displayName = (availability.known ? RepositoryText(availability.displayName, 512) : nil) ?: identity;
        _source = [[CydiaPackageDetailSource alloc] initWithRepositoryURLString:URLString name:sourceName];
        _contactKind = CydiaPackageDetailContactKindPackageSupport;
        _applications = @[];
        _modifyActions = @[];
        _warnings = @[[[NSBundle mainBundle] localizedStringForKey:@"ACCOUNT_ITEM_NOT_IN_SOURCE"
            value:@"No selected local package from this repository. Refresh sources to check availability." table:@"Accounts"]];

        NSMutableDictionary *fields([NSMutableDictionary dictionary]);
        NSMutableArray<NSString *> *tags([NSMutableArray array]);
        if (availability.known) {
            const auto &record(availability.record);
            _displayName = RepositoryText(availability.displayName, 512) ?:
                RepositoryText(record.displayName, 512) ?: RepositoryField(record, "Name", 512) ?: identity;
            _fullVersion = RepositoryText(availability.version, 256) ?: RepositoryField(record, "Version", 256);
            _latestVersion = _fullVersion;
            _architecture = RepositoryText(availability.architecture, 128) ?: RepositoryField(record, "Architecture", 128);
            _architectureCaption = [CydiaPackageArchitectureCaption(_architecture, architectures) copy];
            _multiArch = RepositoryField(record, "Multi-Arch", 128);
            _rawSection = RepositoryField(record, "Section", 512);
            _localizedSection = [_rawSection copy];
            _shortDescription = RepositoryText(record.shortDescription, 4096);
            _longDescription = RepositoryText(record.longDescription, 65536, YES) ?:
                RepositoryField(record, "Description", 65536, YES);
            _displayDescription = [_longDescription ?: _shortDescription copy];
            _homepageURLString = RepositoryURLString(RepositoryField(record, "Homepage", 8192)) ?:
                RepositoryURLString(RepositoryField(record, "Website", 8192));
            _depictionURLString = RepositoryURLString(RepositoryField(record, "Depiction", 8192));
            _supportURLString = RepositoryURLString(RepositoryField(record, "Support", 8192)) ?:
                RepositoryURLString(RepositoryField(record, "Bugs", 8192));
            for (const std::string &value : record.tags) {
                NSString *tag(RepositoryText(value, 256));
                if (tag != nil && ![tags containsObject:tag]) [tags addObject:tag];
            }
            _commercial = [tags containsObject:@"cydia::commercial"];
            if (architectures.count && !availability.architectures.empty() && !availability.hasCompatibleVersion)
                _warnings = @[ActionText(@"PACKAGE_ARCHITECTURE_UNSUPPORTED")];
            else if (!availability.hasDownloadableVersion)
                _warnings = @[ActionText(@"PACKAGE_VERSION_UNAVAILABLE")];

            /* Preserve only inert, source-scoped display fields. Archive paths,
             * local state and APT/dpkg identities do not enter this facade. */
            NSString *description(RepositoryField(record, "Description", 65536, YES));
            if (description != nil) fields[@"Description"] = description;
        }
        fields[@"Package"] = _identity;
        fields[@"Name"] = _displayName;
        if (_fullVersion != nil) fields[@"Version"] = _fullVersion;
        if (_architecture != nil) fields[@"Architecture"] = _architecture;
        if (_rawSection != nil) fields[@"Section"] = _rawSection;
        if (_multiArch != nil) fields[@"Multi-Arch"] = _multiArch;
        if (_homepageURLString != nil) fields[@"Homepage"] = _homepageURLString;
        if (_depictionURLString != nil) fields[@"Depiction"] = _depictionURLString;
        if (_supportURLString != nil) fields[@"Support"] = _supportURLString;
        NSDictionary *source(@{@"rooturi": URLString, @"name": _source.name,
            @"host": _source.host ?: @""});
        NSDictionary *values(@{
            @"id": _identity, @"baseId": _baseIdentity, @"name": _displayName,
            @"latest": _latestVersion ?: NSNull.null, @"architecture": _architecture ?: NSNull.null,
            @"longDescription": _longDescription ?: NSNull.null,
            @"shortDescription": _shortDescription ?: NSNull.null,
            @"section": _rawSection ?: NSNull.null, @"longSection": _localizedSection ?: NSNull.null,
            @"multiArch": _multiArch ?: NSNull.null, @"homepage": _homepageURLString ?: NSNull.null,
            @"depiction": _depictionURLString ?: NSNull.null, @"support": _supportURLString ?: NSNull.null,
            @"installed": NSNull.null, @"mode": NSNull.null, @"state": NSNull.null,
            @"selection": NSNull.null, @"warnings": _warnings,
        });
        _legacyDepictionSnapshot = @{
            @"package": @{@"values": values, @"fields": [fields copy], @"tags": [tags copy],
                @"source": source, @"applications": @[], @"relations": @[]},
            @"source": source, @"preferredLanguages": [NSLocale preferredLanguages] ?: @[],
            @"localeIdentifier": NSLocale.currentLocale.localeIdentifier ?: @"en_US",
            @"supports": @[@"depiction", @"window.cydia", @"ios12"],
        };
    }
    return self;
}

- (nullable instancetype)initWithPackage:(Package *)package {
    return [self initWithPackage:package registeredArchitectures:@[]];
}

- (nullable instancetype)initWithPackage:(Package *)package
               registeredArchitectures:(NSArray<NSString *> *)registeredArchitectures {
    return [self initWithPackage:package registeredArchitectures:registeredArchitectures
        versionArchitecture:nil];
}

- (nullable instancetype)initWithPackage:(Package *)package
               registeredArchitectures:(NSArray<NSString *> *)registeredArchitectures
                    versionArchitecture:(nullable NSString *)versionArchitecture {
    return [self initWithPackage:package registeredArchitectures:registeredArchitectures
        versionArchitecture:versionArchitecture repositoryConstraint:nil];
}

- (nullable instancetype)initWithPackage:(Package *)package
               registeredArchitectures:(NSArray<NSString *> *)registeredArchitectures
                    versionArchitecture:(nullable NSString *)versionArchitecture
                   repositoryConstraint:(nullable NSURL *)repositoryConstraint {
    if (package == nil)
        return nil;
    id<CydiaPackageDetailPackageSource> sourcePackage((id)package);
    [sourcePackage parse];
    if (repositoryConstraint && ![[[sourcePackage source] rooturi] isEqual:repositoryConstraint.absoluteString]) return nil;

    NSString *identity(StringOrNil([sourcePackage id]));
    NSString *baseIdentity(StringOrNil([sourcePackage baseId]));
    NSString *aptIdentity(StringOrNil([sourcePackage aptId]));
    NSString *dpkgIdentity(StringOrNil([sourcePackage dpkgId]));
    if (identity == nil)
        return nil;

    if ((self = [super init]) != nil) {
        _readOnly = NO;
        _identity = [identity copy];
        _baseIdentity = [baseIdentity copy];
        _aptIdentity = [aptIdentity copy];
        _dpkgIdentity = [dpkgIdentity copy];
        _displayName = [(StringOrNil([sourcePackage name]) ?: identity) copy];
        _latestVersion = StringOrNil([sourcePackage latest]);
        _fullVersion = [([sourcePackage respondsToSelector:@selector(fullVersion)] ?
            StringOrNil([sourcePackage fullVersion]) : _latestVersion) copy];
        _installedVersion = StringOrNil([sourcePackage installed]);
        NSString *md5sum([sourcePackage respondsToSelector:@selector(md5sum)] ?
            StringOrNil([sourcePackage md5sum]) : nil);
        NSString *state([sourcePackage respondsToSelector:@selector(state)] ?
            StringOrNil([sourcePackage state]) : nil);
        NSString *selection([sourcePackage respondsToSelector:@selector(selection)] ?
            StringOrNil([sourcePackage selection]) : nil);
        time_t upgraded([sourcePackage respondsToSelector:@selector(upgraded)] ?
            [sourcePackage upgraded] : 0);
        _architecture = StringOrNil([sourcePackage architecture]);
        _architectureCaption = [CydiaPackageArchitectureCaption(_architecture, registeredArchitectures) copy];
        _multiArch = StringOrNil([sourcePackage multiArch]);
        _rawSection = StringOrNil([sourcePackage section]);
        NSString *simpleSection(StringOrNil([sourcePackage simpleSection]));
        _localizedSection = StringOrNil([sourcePackage longSection]);
        NSString *shortSection(StringOrNil([sourcePackage shortSection]));
        _shortDescription = StringOrNil([sourcePackage shortDescription]);
        _longDescription = StringOrNil([sourcePackage longDescription]);
        _displayDescription = [_longDescription ?: _shortDescription copy];
        _installedSizeBytes = static_cast<uint64_t>([sourcePackage size]);

        _modeLocalizationKey = StringOrNil([sourcePackage mode]);
        _warnings = StringArray([sourcePackage warnings]);
        _installed = ![sourcePackage uninstalled];
        _upgradable = [sourcePackage upgradableAndEssential:NO];
        _held = [sourcePackage ignored];
        _essential = [sourcePackage essential];
        _protectedPackage = [sourcePackage respondsToSelector:@selector(protectedPackage)] && [sourcePackage protectedPackage];
        const BOOL canReinstall([sourcePackage respondsToSelector:@selector(canReinstall)] ?
            [sourcePackage canReinstall] : [sourcePackage source] != nil);
        NSMutableArray *actionWarnings([_warnings mutableCopy]);
        if (_held) [actionWarnings addObject:ActionText(@"PACKAGE_HELD_NOTICE")];
        if (_essential) [actionWarnings addObject:ActionText(@"PACKAGE_ESSENTIAL_NOTICE")];
        else if (_protectedPackage) [actionWarnings addObject:ActionText(@"PACKAGE_PROTECTED_NOTICE")];
        if (_installed && !canReinstall) [actionWarnings addObject:ActionText(@"PACKAGE_REINSTALL_UNAVAILABLE")];
        _warnings = [actionWarnings copy];
        _commercial = [sourcePackage isCommercial];
        _consolePackage = [sourcePackage hasTag:@"purpose::console"];

        id<CydiaPackageDetailAddressSource> authorSource([sourcePackage author]);
        id<CydiaPackageDetailAddressSource> maintainerSource([sourcePackage maintainer]);
        _authorName = StringOrNil([authorSource name]);
        _authorAddress = StringOrNil([authorSource address]);
        _maintainerName = StringOrNil([maintainerSource name]);
        _maintainerAddress = StringOrNil([maintainerSource address]);

        id<CydiaPackageDetailAddressSource> contact(authorSource);
        _contactKind = CydiaPackageDetailContactKindAuthor;
        if (contact == nil) {
            contact = maintainerSource;
            _contactKind = contact == nil ? CydiaPackageDetailContactKindPackageSupport :
                                           CydiaPackageDetailContactKindMaintainer;
        }
        _contactName = StringOrNil([contact name]);
        _contactAddress = StringOrNil([contact address]);
        _supportURLString = URLStringOrNil([sourcePackage support]);
        _homepageURLString = URLStringOrNil([sourcePackage homepage]);
        _depictionURLString = URLStringOrNil([sourcePackage depiction]);

        NSMutableDictionary *legacyPackage([NSMutableDictionary dictionary]);
        NSDictionary *packageValues(@{
            @"architecture": _architecture ?: [NSNull null],
            @"aptId": _aptIdentity ?: [NSNull null],
            @"baseId": _baseIdentity ?: [NSNull null],
            @"depiction": _depictionURLString ?: [NSNull null],
            @"dpkgId": _dpkgIdentity ?: [NSNull null],
            @"essential": @(_essential),
            @"homepage": _homepageURLString ?: [NSNull null],
            @"icon": [NSString stringWithFormat:@"cydia://package-icon/%@", _identity],
            @"id": _identity,
            @"installed": _installedVersion ?: [NSNull null],
            @"latest": _latestVersion ?: [NSNull null],
            @"longDescription": _longDescription ?: [NSNull null],
            @"longSection": _localizedSection ?: [NSNull null],
            @"mode": _modeLocalizationKey ?: [NSNull null],
            @"multiArch": _multiArch ?: [NSNull null],
            @"name": _displayName,
            @"section": _rawSection ?: [NSNull null],
            @"md5sum": md5sum ?: [NSNull null],
            @"selection": selection ?: [NSNull null],
            @"simpleSection": simpleSection ?: [NSNull null],
            @"shortDescription": _shortDescription ?: [NSNull null],
            @"shortSection": shortSection ?: [NSNull null],
            @"size": @(_installedSizeBytes),
            @"state": state ?: [NSNull null],
            @"support": _supportURLString ?: [NSNull null],
            @"upgraded": @((long long) upgraded),
            @"warnings": _warnings ?: @[],
        });
        [legacyPackage setObject:packageValues forKey:@"values"];
        NSDictionary *author(AddressSnapshot([sourcePackage author]));
        if (author != nil)
            [legacyPackage setObject:author forKey:@"author"];
        NSDictionary *maintainer(AddressSnapshot([sourcePackage maintainer]));
        if (maintainer != nil)
            [legacyPackage setObject:maintainer forKey:@"maintainer"];
        NSArray *tags([sourcePackage respondsToSelector:@selector(tags)] ?
            PropertyListValue([sourcePackage tags], 0) : nil);
        if (tags != nil)
            [legacyPackage setObject:tags forKey:@"tags"];
        NSArray *purposes([sourcePackage respondsToSelector:@selector(purposes)] ?
            PropertyListValue([sourcePackage purposes], 0) : nil);
        if (purposes != nil)
            [legacyPackage setObject:purposes forKey:@"purposes"];
        NSArray *legacyApplicationsValue(PropertyListValue([sourcePackage applications], 0));
        if (legacyApplicationsValue != nil)
            [legacyPackage setObject:legacyApplicationsValue forKey:@"applications"];
        NSArray *relations([sourcePackage respondsToSelector:@selector(relations)] ?
            RelationsSnapshot([sourcePackage relations]) : @[]);
        if (relations != nil)
            [legacyPackage setObject:relations forKey:@"relations"];
        NSString *record([sourcePackage respondsToSelector:@selector(getRecord)] ?
            [sourcePackage getRecord] : nil);
        if ([record isKindOfClass:[NSString class]])
            [legacyPackage setObject:record forKey:@"record"];
        NSMutableDictionary *fields([NSMutableDictionary dictionary]);
        NSArray *fieldNames(@[ @"Package", @"Name", @"Version", @"Architecture",
                              @"Description", @"Section", @"Maintainer", @"Depends",
                              @"Pre-Depends", @"Recommends", @"Suggests", @"Conflicts",
                              @"Replaces", @"Provides", @"Installed-Size", @"Filename",
                              @"Size", @"MD5sum", @"SHA256", @"Tag", @"Homepage",
                              @"Depiction", @"Support", @"Author" ]);
        for (NSString *fieldName in fieldNames) {
            id field([sourcePackage respondsToSelector:@selector(getField:)] ?
                PropertyListValue([sourcePackage getField:fieldName], 0) : nil);
            if (field != nil && field != [NSNull null])
                [fields setObject:field forKey:fieldName];
        }
        [legacyPackage setObject:[fields copy] forKey:@"fields"];

        id<CydiaPackageDetailSourceSource> packageSource([sourcePackage source]);
        if (packageSource != nil)
            _source = [[CydiaPackageDetailSource alloc] initWithSource:packageSource];

        NSDictionary *legacySource(SourceSnapshot(packageSource));
        if (legacySource == nil)
            legacySource = @{};
        if ([legacySource count] != 0)
            [legacyPackage setObject:[legacySource copy] forKey:@"source"];

        NSMutableArray<CydiaPackageDetailApplication *> *applications(
            [NSMutableArray array]);
        id legacyApplications([sourcePackage applications]);
        if ([legacyApplications isKindOfClass:[NSArray class]]) {
            for (id value in legacyApplications) {
                CydiaPackageDetailApplication *application(
                    [[CydiaPackageDetailApplication alloc] initWithLegacyArray:value]);
                if (application != nil)
                    [applications addObject:application];
            }
        }
        _applications = [applications copy];

        NSMutableArray<CydiaPackageDetailVersionChoice *> *versions(
            [NSMutableArray array]);
        id legacyDowngrades([sourcePackage respondsToSelector:@selector(availableVersions)] ?
            [sourcePackage availableVersions] : [sourcePackage downgrades]);
        if ([legacyDowngrades isKindOfClass:[NSArray class]]) {
            for (id value in legacyDowngrades) {
                id<CydiaPackageDetailPackageSource> versionPackage(value);
                if (repositoryConstraint && ![[[versionPackage source] rooturi] isEqual:repositoryConstraint.absoluteString]) continue;
                if ([versionPackage respondsToSelector:@selector(architectureSupported)] &&
                    ![versionPackage architectureSupported]) continue;
                CydiaPackageDetailVersionChoice *choice(
                    [[CydiaPackageDetailVersionChoice alloc]
                        initWithPackage:(id<CydiaPackageDetailPackageSource>)value
                        registeredArchitectures:registeredArchitectures]);
                if (choice != nil && (versionArchitecture == nil ||
                    [[choice architecture] isEqualToString:versionArchitecture]))
                    [versions addObject:choice];
            }
        }

        NSMutableArray<CydiaPackageDetailModifyAction *> *actions(
            [NSMutableArray array]);
        if (_modeLocalizationKey != nil)
            [actions addObject:[[CydiaPackageDetailModifyAction alloc]
                initWithKind:CydiaPackageDetailModifyActionKindClear key:@"CLEAR" versions:@[]]];
        const BOOL available([sourcePackage respondsToSelector:@selector(versionAvailable)] ?
            [sourcePackage versionAvailable] : _source != nil);
        const NSInteger comparison([sourcePackage respondsToSelector:@selector(versionComparison)] ?
            [sourcePackage versionComparison] : (_upgradable ? 1 : 0));
        const BOOL supported(![sourcePackage respondsToSelector:@selector(architectureSupported)] ||
            [sourcePackage architectureSupported]);
        if (!_held && available && supported) {
            if (_upgradable)
                [actions addObject:[[CydiaPackageDetailModifyAction alloc]
                    initWithKind:CydiaPackageDetailModifyActionKindUpgrade key:@"UPGRADE" versions:@[]]];
            else if (!_installed)
                [actions addObject:[[CydiaPackageDetailModifyAction alloc]
                    initWithKind:CydiaPackageDetailModifyActionKindInstall key:@"INSTALL" versions:@[]]];
            else if (comparison < 0)
                [actions addObject:[[CydiaPackageDetailModifyAction alloc]
                    initWithKind:CydiaPackageDetailModifyActionKindDowngrade key:@"DOWNGRADE" versions:@[]]];
        }
        if (!_held && _installed && canReinstall)
                [actions addObject:[[CydiaPackageDetailModifyAction alloc]
                    initWithKind:CydiaPackageDetailModifyActionKindReinstall key:@"REINSTALL" versions:@[]]];
        if (!_held && _installed && !_essential && !_protectedPackage) {
            [actions addObject:[[CydiaPackageDetailModifyAction alloc]
                initWithKind:CydiaPackageDetailModifyActionKindRemove key:@"REMOVE" versions:@[]]];
        }
        if (!_held && !_essential && !_protectedPackage && (_installed ||
            ([sourcePackage respondsToSelector:@selector(hasSavedConfiguration)] && [sourcePackage hasSavedConfiguration])))
            [actions addObject:[[CydiaPackageDetailModifyAction alloc]
                initWithKind:CydiaPackageDetailModifyActionKindPurge key:@"PACKAGE_PURGE_ACTION" versions:@[]]];
        if (!_held && [versions count] != 0)
            [actions addObject:[[CydiaPackageDetailModifyAction alloc]
                initWithKind:CydiaPackageDetailModifyActionKindVersions key:@"PACKAGE_VERSIONS"
                     versions:versions]];
        if (_commercial && _source.repositoryURLString.length)
            [actions addObject:[[CydiaPackageDetailModifyAction alloc]
                initWithKind:CydiaPackageDetailModifyActionKindAccount key:@"ACCOUNTS" versions:@[]]];
        _modifyActions = [actions copy];
        if ([actions count] == 1)
            _primaryModifyTitleLocalizationKey = [[[actions objectAtIndex:0]
                titleLocalizationKey] copy];
        else if ([actions count] > 1)
            _primaryModifyTitleLocalizationKey = @"MODIFY";

        NSMutableDictionary *legacySnapshot([NSMutableDictionary dictionary]);
        [legacySnapshot setObject:[legacyPackage copy] forKey:@"package"];
        id legacySourceValue([legacySource count] == 0 ? (id) [NSNull null] :
                             (id) [legacySource copy]);
        [legacySnapshot setObject:legacySourceValue forKey:@"source"];
        [legacySnapshot setObject:[NSLocale preferredLanguages] ?: @[]
                            forKey:@"preferredLanguages"];
        [legacySnapshot setObject:[[NSLocale currentLocale] localeIdentifier] ?: @"en_US"
                            forKey:@"localeIdentifier"];
        [legacySnapshot setObject:@[ @"depiction", @"window.cydia", @"ios12" ]
                            forKey:@"supports"];
        _legacyDepictionSnapshot = [legacySnapshot copy];
    }
    return self;
}

@end
