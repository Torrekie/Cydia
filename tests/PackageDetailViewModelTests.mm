/* Cydia Refurbished native package-detail model tests.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import <Foundation/Foundation.h>

#import "Cydia/PackageDetailViewModel.h"

#include <cstdlib>
#include <ctime>
#include <iostream>

void Require(bool condition, const char *message) {
    if (!condition) {
        std::cerr << "[verify-package-detail-view-model][FAIL] " << message << std::endl;
        std::exit(1);
    }
}

void RequireString(NSString *actual, NSString *expected, const char *message) {
    Require(actual == expected || [actual isEqualToString:expected], message);
}

@interface FakePackageAddress : NSObject
@property(nonatomic, strong) NSMutableString *nameValue;
@property(nonatomic, strong) NSMutableString *addressValue;
@end

@implementation FakePackageAddress
- (NSString *)name { return _nameValue; }
- (NSString *)address { return _addressValue; }
@end


@interface FakePackageSource : NSObject
@property(nonatomic, strong) NSMutableString *keyValue;
@property(nonatomic, strong) NSMutableString *nameValue;
@property(nonatomic, strong) NSMutableString *descriptionValue;
@property(nonatomic, strong) NSMutableString *hostValue;
@property(nonatomic, strong) NSURL *iconValue;
@end

@implementation FakePackageSource
- (NSString *)key { return _keyValue; }
- (NSString *)name { return _nameValue; }
- (NSString *)shortDescription { return _descriptionValue; }
- (NSString *)host { return _hostValue; }
- (NSURL *)iconURL { return _iconValue; }
@end


@interface FakeOperation : NSObject
@property(nonatomic, copy) NSString *operatorValue;
@property(nonatomic, copy) NSString *valueValue;
@end

@implementation FakeOperation
- (NSString *)operator { return _operatorValue; }
- (NSString *)value { return _valueValue; }
@end


@interface FakeClause : NSObject
@property(nonatomic, copy) NSString *packageValue;
@property(nonatomic, strong) id versionValue;
@end

@implementation FakeClause
- (NSString *)package { return _packageValue; }
- (id)version { return _versionValue; }
@end


@interface FakeRelation : NSObject
@property(nonatomic, copy) NSString *relationshipValue;
@property(nonatomic, strong) NSArray *clausesValue;
@end

@implementation FakeRelation
- (NSString *)relationship { return _relationshipValue; }
- (NSArray *)clauses { return _clausesValue; }
@end


@interface FakePackage : NSObject
@property(nonatomic) NSUInteger parseCount;
@property(nonatomic, strong) id identityValue;
@property(nonatomic, strong) id baseIdentityValue;
@property(nonatomic, strong) id aptIdentityValue;
@property(nonatomic, strong) id dpkgIdentityValue;
@property(nonatomic, strong) id nameValue;
@property(nonatomic, strong) id latestValue;
@property(nonatomic, strong) id installedValue;
@property(nonatomic, strong) id md5sumValue;
@property(nonatomic, strong) id architectureValue;
@property(nonatomic, strong) id multiArchValue;
@property(nonatomic, strong) id rawSectionValue;
@property(nonatomic, strong) id simpleSectionValue;
@property(nonatomic, strong) id sectionValue;
@property(nonatomic, strong) id shortSectionValue;
@property(nonatomic, strong) id shortDescriptionValue;
@property(nonatomic, strong) id longDescriptionValue;
@property(nonatomic) size_t sizeValue;
@property(nonatomic, strong) id modeValue;
@property(nonatomic, strong) id stateValue;
@property(nonatomic, strong) id selectionValue;
@property(nonatomic, strong) id warningsValue;
@property(nonatomic) BOOL uninstalledValue;
@property(nonatomic) BOOL upgradableValue;
@property(nonatomic) BOOL ignoredValue;
@property(nonatomic) BOOL essentialValue;
@property(nonatomic) bool commercialValue;
@property(nonatomic) BOOL consoleValue;
@property(nonatomic, strong) id authorValue;
@property(nonatomic, strong) id maintainerValue;
@property(nonatomic, strong) id supportValue;
@property(nonatomic, strong) id homepageValue;
@property(nonatomic, strong) id depictionValue;
@property(nonatomic, strong) id sourceValue;
@property(nonatomic, strong) id applicationsValue;
@property(nonatomic, strong) id purposesValue;
@property(nonatomic, strong) id tagsValue;
@property(nonatomic, strong) id relationsValue;
@property(nonatomic) time_t upgradedValue;
@property(nonatomic, strong) id downgradesValue;
@end

@implementation FakePackage
- (void)parse { ++_parseCount; }
- (NSString *)id { return _identityValue; }
- (NSString *)baseId { return _baseIdentityValue; }
- (NSString *)aptId { return _aptIdentityValue; }
- (NSString *)dpkgId { return _dpkgIdentityValue; }
- (NSString *)name { return _nameValue; }
- (NSString *)latest { return _latestValue; }
- (NSString *)installed { return _installedValue; }
- (NSString *)md5sum { return _md5sumValue; }
- (NSString *)architecture { return _architectureValue; }
- (NSString *)multiArch { return _multiArchValue; }
- (NSString *)section { return _rawSectionValue; }
- (NSString *)simpleSection { return _simpleSectionValue; }
- (NSString *)longSection { return _sectionValue; }
- (NSString *)shortSection { return _shortSectionValue; }
- (NSString *)shortDescription { return _shortDescriptionValue; }
- (NSString *)longDescription { return _longDescriptionValue; }
- (size_t)size { return _sizeValue; }
- (NSString *)mode { return _modeValue; }
- (NSString *)state { return _stateValue; }
- (NSString *)selection { return _selectionValue; }
- (NSArray *)warnings { return _warningsValue; }
- (BOOL)uninstalled { return _uninstalledValue; }
- (BOOL)upgradableAndEssential:(BOOL)essential { (void)essential; return _upgradableValue; }
- (BOOL)ignored { return _ignoredValue; }
- (BOOL)essential { return _essentialValue; }
- (bool)isCommercial { return _commercialValue; }
- (BOOL)hasTag:(NSString *)tag {
    return _consoleValue && [tag isEqualToString:@"purpose::console"];
}
- (id)author { return _authorValue; }
- (id)maintainer { return _maintainerValue; }
- (NSString *)support { return _supportValue; }
- (NSString *)homepage { return _homepageValue; }
- (NSString *)depiction { return _depictionValue; }
- (id)source { return _sourceValue; }
- (NSArray *)applications { return _applicationsValue; }
- (NSArray *)purposes { return _purposesValue; }
- (NSArray *)tags { return _tagsValue; }
- (NSArray *)relations { return _relationsValue; }
- (time_t)upgraded { return _upgradedValue; }
- (NSArray *)downgrades { return _downgradesValue; }
@end


FakePackage *BasePackage(NSString *identity) {
    FakePackage *package([[FakePackage alloc] init]);
    package.identityValue = [identity mutableCopy];
    package.baseIdentityValue = [@"runtime" mutableCopy];
    package.aptIdentityValue = [@"runtime:iphoneos-arm64" mutableCopy];
    package.dpkgIdentityValue = [@"runtime:iphoneos-arm64" mutableCopy];
    package.nameValue = [@"Runtime Package" mutableCopy];
    package.latestValue = [@"2:1.1" mutableCopy];
    package.architectureValue = [@"iphoneos-arm64" mutableCopy];
    package.md5sumValue = [@"0123456789abcdef0123456789abcdef" mutableCopy];
    package.multiArchValue = [@"same" mutableCopy];
    package.rawSectionValue = [@"System" mutableCopy];
    package.simpleSectionValue = [@"System" mutableCopy];
    package.sectionValue = [@"System" mutableCopy];
    package.shortSectionValue = [@"System" mutableCopy];
    package.shortDescriptionValue = [@"Short package description" mutableCopy];
    package.sizeValue = 8192;
    package.stateValue = [@"Installed" mutableCopy];
    package.selectionValue = [@"install" mutableCopy];
    package.upgradedValue = 1700000000;
    package.warningsValue = [NSMutableArray array];
    package.applicationsValue = [NSMutableArray array];
    package.purposesValue = [NSMutableArray arrayWithObject:@"utility"];
    package.tagsValue = [NSMutableArray arrayWithObject:@"purpose::utility"];
    package.relationsValue = [NSMutableArray array];
    package.downgradesValue = [NSMutableArray array];
    return package;
}

NSArray<NSNumber *> *ActionKinds(CydiaPackageDetailViewModel *model) {
    NSMutableArray<NSNumber *> *kinds([NSMutableArray array]);
    for (CydiaPackageDetailModifyAction *action in [model modifyActions])
        [kinds addObject:@([action kind])];
    return [kinds copy];
}


void TestCompleteQualifiedSnapshotAndOwnership() {
    FakePackage *package(BasePackage(@"runtime:iphoneos-arm64"));
    package.installedValue = [@"2:1.0" mutableCopy];
    package.longDescriptionValue = [@"Long package description\nSecond line" mutableCopy];
    package.modeValue = [@"INSTALL" mutableCopy];
    package.upgradableValue = YES;
    package.ignoredValue = YES;
    package.essentialValue = YES;
    package.commercialValue = true;
    package.consoleValue = YES;
    package.supportValue = [@"https://support.example/runtime" mutableCopy];
    package.homepageValue = [@"https://example.test/runtime" mutableCopy];
    package.depictionValue = [@"https://repo.example/depiction/runtime" mutableCopy];

    FakePackageAddress *author([[FakePackageAddress alloc] init]);
    author.nameValue = [@"Runtime Author" mutableCopy];
    author.addressValue = [@"author@example.test" mutableCopy];
    package.authorValue = author;
    FakePackageAddress *maintainer([[FakePackageAddress alloc] init]);
    maintainer.nameValue = [@"Ignored Maintainer" mutableCopy];
    package.maintainerValue = maintainer;

    FakePackageSource *source([[FakePackageSource alloc] init]);
    source.keyValue = [@"https://repo.example/ ./" mutableCopy];
    source.nameValue = [@"Example Repository" mutableCopy];
    source.descriptionValue = [@"Repository description" mutableCopy];
    source.hostValue = [@"repo.example" mutableCopy];
    source.iconValue = [NSURL URLWithString:@"https://repo.example/CydiaIcon.png"];
    package.sourceValue = source;

    NSMutableString *warning([@"Package warning" mutableCopy]);
    package.warningsValue = [NSMutableArray arrayWithObjects:warning, @42, @"", nil];
    NSMutableArray *application([NSMutableArray arrayWithObjects:
        [@"com.example.runtime" mutableCopy], [@"Runtime App" mutableCopy],
        [NSURL URLWithString:@"file:///Applications/Runtime.app/icon.png"], nil]);
    package.applicationsValue = [NSMutableArray arrayWithObjects:
        application, @[@"missing-name"], @[@7, @"Bad"], nil];

    FakeOperation *operation([[FakeOperation alloc] init]);
    operation.operatorValue = @">=";
    operation.valueValue = @"1.0";
    FakeClause *clause([[FakeClause alloc] init]);
    clause.packageValue = @"com.dependency";
    clause.versionValue = operation;
    FakeRelation *relation([[FakeRelation alloc] init]);
    relation.relationshipValue = @"Depends";
    relation.clausesValue = @[ clause ];
    package.relationsValue = @[ relation ];

    FakePackage *downgrade(BasePackage(@"runtime:iphoneos-arm64"));
    downgrade.latestValue = [@"2:0.9" mutableCopy];
    package.downgradesValue = [NSMutableArray arrayWithObjects:downgrade, @"invalid", nil];

    CydiaPackageDetailViewModel *model([[CydiaPackageDetailViewModel alloc]
        initWithPackage:(Package *)(id)package]);
    Require(model != nil, "qualified package did not produce a model");
    Require(package.parseCount == 1, "package metadata was not parsed exactly once");
    RequireString(model.identity, @"runtime:iphoneos-arm64", "qualified route identity changed");
    RequireString(model.baseIdentity, @"runtime", "base identity changed");
    RequireString(model.aptIdentity, @"runtime:iphoneos-arm64", "APT identity changed");
    RequireString(model.dpkgIdentity, @"runtime:iphoneos-arm64", "dpkg identity changed");
    RequireString(model.displayName, @"Runtime Package", "display name changed");
    RequireString(model.latestVersion, @"2:1.1", "latest version changed");
    RequireString(model.installedVersion, @"2:1.0", "installed version changed");
    RequireString(model.architecture, @"iphoneos-arm64", "architecture changed");
    RequireString(model.multiArch, @"same", "Multi-Arch mode changed");
    RequireString(model.rawSection, @"System", "raw section changed");
    RequireString(model.localizedSection, @"System", "localized section changed");
    RequireString(model.displayDescription, @"Long package description\nSecond line",
                  "long description did not win over short description");
    NSDictionary *legacyPackage(model.legacyDepictionSnapshot[@"package"]);
    NSDictionary *legacyValues(legacyPackage[@"values"]);
    RequireString(legacyValues[@"longDescription"],
                  @"Long package description\nSecond line", "legacy long description changed");
    RequireString(legacyValues[@"longSection"], @"System", "legacy long section changed");
    RequireString(legacyValues[@"shortSection"], @"System", "legacy short section changed");
    RequireString(legacyValues[@"simpleSection"], @"System", "legacy simple section changed");
    RequireString(legacyValues[@"icon"],
                  @"cydia://package-icon/runtime:iphoneos-arm64", "legacy icon reference changed");
    RequireString(legacyValues[@"depiction"],
                  @"https://repo.example/depiction/runtime", "legacy depiction changed");
    RequireString(legacyValues[@"md5sum"],
                  @"0123456789abcdef0123456789abcdef", "legacy md5sum changed");
    RequireString(legacyValues[@"state"], @"Installed", "legacy state changed");
    RequireString(legacyValues[@"selection"], @"install", "legacy selection changed");
    Require([legacyValues[@"upgraded"] unsignedLongLongValue] == 1700000000ULL,
            "legacy upgraded timestamp changed");
    Require([legacyPackage[@"purposes"] isEqual:@[@"utility"]],
            "legacy purposes changed");
    Require([legacyPackage[@"tags"] isEqual:@[@"purpose::utility"]],
            "legacy tags changed");
    Require([legacyPackage[@"applications"] isKindOfClass:[NSArray class]],
            "legacy applications were not projected");
    RequireString(legacyPackage[@"applications"][0][2],
                  @"file:///Applications/Runtime.app/icon.png",
                  "legacy application icon URL changed");
    RequireString(legacyPackage[@"relations"][0][@"relationship"],
                  @"Depends", "legacy relation kind changed");
    RequireString(legacyPackage[@"relations"][0][@"clauses"][0][@"package"],
                  @"com.dependency", "legacy relation package changed");
    RequireString(legacyPackage[@"relations"][0][@"clauses"][0][@"version"][@"operator"],
                  @">=", "legacy relation operator changed");
    RequireString(legacyPackage[@"author"][@"name"], @"Runtime Author",
                  "legacy author snapshot changed");
    RequireString(legacyPackage[@"maintainer"][@"name"], @"Ignored Maintainer",
                  "legacy maintainer snapshot changed");
    Require(model.installedSizeBytes == 8192, "installed size changed");
    Require(model.isInstalled && model.isUpgradable && model.isHeld && model.isEssential,
            "installed package state changed");
    Require(model.isCommercial && model.isConsolePackage, "package tags changed");
    RequireString(model.modeLocalizationKey, @"INSTALL", "queue mode changed");
    Require(model.contactKind == CydiaPackageDetailContactKindAuthor,
            "author did not take contact precedence");
    RequireString(model.contactName, @"Runtime Author", "contact name changed");
    RequireString(model.contactAddress, @"author@example.test", "contact address changed");
    RequireString(model.source.name, @"Example Repository", "source name changed");
    RequireString(model.source.sourceDescription, @"Repository description",
                  "source description changed");
    RequireString(model.source.iconURLString, @"https://repo.example/CydiaIcon.png",
                  "source icon URL changed");
    NSDictionary *legacySource(model.legacyDepictionSnapshot[@"source"]);
    Require([legacySource[@"key"] isEqualToString:@"https://repo.example/ ./"],
            "legacy source key was not projected");
    Require([legacySource[@"name"] isEqualToString:@"Example Repository"],
            "legacy source name was not projected");
    Require([legacySource[@"host"] isEqualToString:@"repo.example"],
            "legacy source host was not projected");
    Require([model.warnings count] == 1, "invalid warning values were not filtered");
    Require([model.applications count] == 1, "invalid application values were not filtered");
    RequireString(model.applications[0].bundleIdentifier, @"com.example.runtime",
                  "application identifier changed");
    RequireString(model.applications[0].iconURLString,
                  @"file:///Applications/Runtime.app/icon.png", "application icon changed");

    NSArray *expectedKinds(@[
        @(CydiaPackageDetailModifyActionKindClear),
        @(CydiaPackageDetailModifyActionKindUpgrade),
        @(CydiaPackageDetailModifyActionKindRemove),
        @(CydiaPackageDetailModifyActionKindDowngrade),
    ]);
    Require([ActionKinds(model) isEqualToArray:expectedKinds],
            "legacy modify action ordering changed");
    RequireString(model.primaryModifyTitleLocalizationKey, @"MODIFY",
                  "multiple actions did not use Modify");
    CydiaPackageDetailModifyAction *downgradeAction(model.modifyActions.lastObject);
    Require([downgradeAction.versions count] == 1, "downgrade choices changed");
    RequireString(downgradeAction.versions[0].identity, @"runtime:iphoneos-arm64",
                  "downgrade qualified identity changed");
    RequireString(downgradeAction.versions[0].version, @"2:0.9",
                  "downgrade version changed");

    [(NSMutableString *)package.identityValue appendString:@"-mutated"];
    [(NSMutableString *)package.nameValue appendString:@" Mutated"];
    [warning appendString:@" Mutated"];
    [author.nameValue appendString:@" Mutated"];
    [source.nameValue appendString:@" Mutated"];
    [application[0] appendString:@".mutated"];
    [(NSMutableString *)downgrade.latestValue appendString:@"-mutated"];
    RequireString(model.identity, @"runtime:iphoneos-arm64", "model retained package identity");
    RequireString(model.displayName, @"Runtime Package", "model retained package name");
    RequireString(model.warnings[0], @"Package warning", "model retained warning storage");
    RequireString(model.contactName, @"Runtime Author", "model retained contact storage");
    RequireString(model.source.name, @"Example Repository", "model retained source storage");
    RequireString(model.applications[0].bundleIdentifier, @"com.example.runtime",
                  "model retained application storage");
    RequireString(downgradeAction.versions[0].version, @"2:0.9",
                  "model retained downgrade storage");
}


void TestInstallReinstallRemoveAndLocalActions() {
    FakePackageSource *source([[FakePackageSource alloc] init]);
    source.nameValue = [@"Repository" mutableCopy];

    FakePackage *uninstalled(BasePackage(@"runtime"));
    uninstalled.uninstalledValue = YES;
    uninstalled.sourceValue = source;
    CydiaPackageDetailViewModel *install([[CydiaPackageDetailViewModel alloc]
        initWithPackage:(Package *)(id)uninstalled]);
    Require([ActionKinds(install) isEqualToArray:@[@(CydiaPackageDetailModifyActionKindInstall)]],
            "uninstalled source package action changed");
    RequireString(install.primaryModifyTitleLocalizationKey, @"INSTALL",
                  "single Install title changed");
    RequireString(install.displayDescription, @"Short package description",
                  "short-description fallback changed");

    FakePackage *installed(BasePackage(@"runtime"));
    installed.installedValue = @"1.0";
    installed.sourceValue = source;
    CydiaPackageDetailViewModel *reinstall([[CydiaPackageDetailViewModel alloc]
        initWithPackage:(Package *)(id)installed]);
    Require([ActionKinds(reinstall) isEqualToArray:@[
        @(CydiaPackageDetailModifyActionKindReinstall),
        @(CydiaPackageDetailModifyActionKindRemove)]],
        "installed source package actions changed");
    RequireString(reinstall.primaryModifyTitleLocalizationKey, @"MODIFY",
                  "Reinstall/Remove did not use Modify");

    FakePackage *local(BasePackage(@"runtime"));
    local.installedValue = @"1.0";
    CydiaPackageDetailViewModel *remove([[CydiaPackageDetailViewModel alloc]
        initWithPackage:(Package *)(id)local]);
    Require([ActionKinds(remove) isEqualToArray:@[@(CydiaPackageDetailModifyActionKindRemove)]],
            "installed local package exposed repository actions");
    RequireString(remove.primaryModifyTitleLocalizationKey, @"REMOVE",
                  "single local Remove title changed");
}


void TestNullabilityFallbackAndContactPriority() {
    FakePackage *invalid([[FakePackage alloc] init]);
    Require([[CydiaPackageDetailViewModel alloc]
        initWithPackage:(Package *)(id)invalid] == nil, "identity-less package produced a model");

    FakePackage *package(BasePackage(@"runtime"));
    package.nameValue = @"";
    package.architectureValue = [NSNull null];
    package.multiArchValue = @"";
    package.rawSectionValue = [NSNull null];
    package.sectionValue = [NSNull null];
    package.shortDescriptionValue = @"";
    package.longDescriptionValue = [NSNull null];
    package.md5sumValue = nil;
    package.stateValue = nil;
    package.selectionValue = nil;
    package.upgradedValue = 0;
    package.warningsValue = [NSNull null];
    package.applicationsValue = [NSNull null];
    package.purposesValue = nil;
    package.tagsValue = nil;
    package.downgradesValue = [NSNull null];
    FakePackageAddress *maintainer([[FakePackageAddress alloc] init]);
    maintainer.nameValue = [@"Runtime Maintainer" mutableCopy];
    maintainer.addressValue = [@"maintainer@example.test" mutableCopy];
    package.maintainerValue = maintainer;

    CydiaPackageDetailViewModel *model([[CydiaPackageDetailViewModel alloc]
        initWithPackage:(Package *)(id)package]);
    RequireString(model.displayName, @"runtime", "empty display name did not fall back to identity");
    Require(model.architecture == nil && model.multiArch == nil &&
            model.rawSection == nil && model.localizedSection == nil,
            "web sentinels leaked into nullable metadata");
    Require(model.displayDescription == nil, "empty descriptions did not normalize to nil");
    Require([model.warnings count] == 0 && [model.applications count] == 0,
            "web sentinels leaked into arrays");
    NSDictionary *legacyValues(model.legacyDepictionSnapshot[@"package"][@"values"]);
    Require(legacyValues[@"md5sum"] == [NSNull null] &&
            legacyValues[@"state"] == [NSNull null] &&
            legacyValues[@"selection"] == [NSNull null],
            "missing scalar readers did not remain null-safe");
    Require([legacyValues[@"upgraded"] unsignedLongLongValue] == 0,
            "missing upgraded timestamp did not remain zero");
    Require(model.legacyDepictionSnapshot[@"package"][@"purposes"] == nil &&
            model.legacyDepictionSnapshot[@"package"][@"tags"] == nil,
            "missing array readers were invented");
    Require(model.contactKind == CydiaPackageDetailContactKindMaintainer,
            "maintainer contact fallback changed");
    RequireString(model.contactName, @"Runtime Maintainer", "maintainer name changed");

    package.maintainerValue = nil;
    CydiaPackageDetailViewModel *support([[CydiaPackageDetailViewModel alloc]
        initWithPackage:(Package *)(id)package]);
    Require(support.contactKind == CydiaPackageDetailContactKindPackageSupport,
            "package-support fallback changed");
    Require(support.contactName == nil && support.contactAddress == nil,
            "package-support fallback invented a contact");
    Require(support.legacyDepictionSnapshot[@"source"] == [NSNull null],
            "package without a source did not project null source");
}

int main() {
    @autoreleasepool {
        TestCompleteQualifiedSnapshotAndOwnership();
        TestInstallReinstallRemoveAndLocalActions();
        TestNullabilityFallbackAndContactPriority();
    }
    std::cout << "[verify-package-detail-view-model][ ok ] immutable package snapshot"
              << std::endl;
    return 0;
}
