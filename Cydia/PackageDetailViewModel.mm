/* Cydia Refurbished native package-detail state boundary.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "Cydia/PackageDetailViewModel.h"

@protocol CydiaPackageDetailAddressSource <NSObject>
- (nullable NSString *)name;
- (nullable NSString *)address;
@end

@protocol CydiaPackageDetailSourceSource <NSObject>
- (nullable NSString *)key;
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
- (nullable NSString *)architecture;
- (nullable NSString *)multiArch;
- (nullable NSString *)section;
- (nullable NSString *)longSection;
- (nullable NSString *)shortDescription;
- (nullable NSString *)longDescription;
- (size_t)size;
- (nullable NSString *)mode;
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
@end

namespace {

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

} // namespace


@interface CydiaPackageDetailSource ()
- (instancetype)initWithSource:(id<CydiaPackageDetailSourceSource>)source;
@end

@implementation CydiaPackageDetailSource

- (instancetype)initWithSource:(id<CydiaPackageDetailSourceSource>)source {
    if ((self = [super init]) != nil) {
        _key = StringOrNil([source key]);
        _name = StringOrNil([source name]) ?: @"";
        _sourceDescription = StringOrNil([source shortDescription]);
        _host = StringOrNil([source host]);
        _iconURLString = URLStringOrNil([source iconURL]);
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
- (nullable instancetype)initWithPackage:(id<CydiaPackageDetailPackageSource>)package;
@end

@implementation CydiaPackageDetailVersionChoice

- (nullable instancetype)initWithPackage:(id<CydiaPackageDetailPackageSource>)package {
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

- (nullable instancetype)initWithPackage:(Package *)package {
    if (package == nil)
        return nil;
    id<CydiaPackageDetailPackageSource> sourcePackage((id)package);
    [sourcePackage parse];

    NSString *identity(StringOrNil([sourcePackage id]));
    NSString *baseIdentity(StringOrNil([sourcePackage baseId]));
    NSString *aptIdentity(StringOrNil([sourcePackage aptId]));
    NSString *dpkgIdentity(StringOrNil([sourcePackage dpkgId]));
    if (identity == nil)
        return nil;

    if ((self = [super init]) != nil) {
        _identity = [identity copy];
        _baseIdentity = [baseIdentity copy];
        _aptIdentity = [aptIdentity copy];
        _dpkgIdentity = [dpkgIdentity copy];
        _displayName = [(StringOrNil([sourcePackage name]) ?: identity) copy];
        _latestVersion = StringOrNil([sourcePackage latest]);
        _installedVersion = StringOrNil([sourcePackage installed]);
        _architecture = StringOrNil([sourcePackage architecture]);
        _multiArch = StringOrNil([sourcePackage multiArch]);
        _rawSection = StringOrNil([sourcePackage section]);
        _localizedSection = StringOrNil([sourcePackage longSection]);
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
        _commercial = [sourcePackage isCommercial];
        _consolePackage = [sourcePackage hasTag:@"purpose::console"];

        id<CydiaPackageDetailAddressSource> contact([sourcePackage author]);
        _contactKind = CydiaPackageDetailContactKindAuthor;
        if (contact == nil) {
            contact = [sourcePackage maintainer];
            _contactKind = contact == nil ? CydiaPackageDetailContactKindPackageSupport :
                                           CydiaPackageDetailContactKindMaintainer;
        }
        _contactName = StringOrNil([contact name]);
        _contactAddress = StringOrNil([contact address]);
        _supportURLString = URLStringOrNil([sourcePackage support]);
        _homepageURLString = URLStringOrNil([sourcePackage homepage]);
        _depictionURLString = URLStringOrNil([sourcePackage depiction]);

        id<CydiaPackageDetailSourceSource> packageSource([sourcePackage source]);
        if (packageSource != nil)
            _source = [[CydiaPackageDetailSource alloc] initWithSource:packageSource];

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
        id legacyDowngrades([sourcePackage downgrades]);
        if ([legacyDowngrades isKindOfClass:[NSArray class]]) {
            for (id value in legacyDowngrades) {
                CydiaPackageDetailVersionChoice *choice(
                    [[CydiaPackageDetailVersionChoice alloc]
                        initWithPackage:(id<CydiaPackageDetailPackageSource>)value]);
                if (choice != nil)
                    [versions addObject:choice];
            }
        }

        NSMutableArray<CydiaPackageDetailModifyAction *> *actions(
            [NSMutableArray array]);
        if (_modeLocalizationKey != nil)
            [actions addObject:[[CydiaPackageDetailModifyAction alloc]
                initWithKind:CydiaPackageDetailModifyActionKindClear key:@"CLEAR" versions:@[]]];
        if (_source != nil) {
            if (_upgradable)
                [actions addObject:[[CydiaPackageDetailModifyAction alloc]
                    initWithKind:CydiaPackageDetailModifyActionKindUpgrade key:@"UPGRADE" versions:@[]]];
            else if (!_installed)
                [actions addObject:[[CydiaPackageDetailModifyAction alloc]
                    initWithKind:CydiaPackageDetailModifyActionKindInstall key:@"INSTALL" versions:@[]]];
            else
                [actions addObject:[[CydiaPackageDetailModifyAction alloc]
                    initWithKind:CydiaPackageDetailModifyActionKindReinstall key:@"REINSTALL" versions:@[]]];
        }
        if (_installed)
            [actions addObject:[[CydiaPackageDetailModifyAction alloc]
                initWithKind:CydiaPackageDetailModifyActionKindRemove key:@"REMOVE" versions:@[]]];
        if ([versions count] != 0)
            [actions addObject:[[CydiaPackageDetailModifyAction alloc]
                initWithKind:CydiaPackageDetailModifyActionKindDowngrade key:@"DOWNGRADE"
                     versions:versions]];
        _modifyActions = [actions copy];
        if ([actions count] == 1)
            _primaryModifyTitleLocalizationKey = [[[actions objectAtIndex:0]
                titleLocalizationKey] copy];
        else if ([actions count] > 1)
            _primaryModifyTitleLocalizationKey = @"MODIFY";
    }
    return self;
}

@end
