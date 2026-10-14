/* Cydia Refurbished native package-detail model tests.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import <Foundation/Foundation.h>

#import "Cydia/PackageDetailViewModel.h"
#import "Cydia/PackageArchitecturePresentation.h"
#include "Cydia/AptCompatibility.hpp"

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
@property(nonatomic, copy) NSString *rootValue;
@end

@implementation FakePackageSource
- (NSString *)key { return _keyValue; }
- (NSString *)name { return _nameValue; }
- (NSString *)shortDescription { return _descriptionValue; }
- (NSString *)host { return _hostValue; }
- (NSURL *)iconURL { return _iconValue; }
- (NSString *)rooturi { return _rootValue; }
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
@property(nonatomic, copy) NSString *fullVersionValue;
@property(nonatomic, strong) NSNumber *architectureSupportedValue;
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
@property(nonatomic) BOOL protectedValue;
@property(nonatomic, strong) NSNumber *canReinstallOverride;
@property(nonatomic) NSInteger comparisonValue;
@property(nonatomic) NSInteger priorityValue;
@property(nonatomic) BOOL candidateValue;
@property(nonatomic) BOOL selectedInstalledValue;
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
@property(nonatomic, strong) NSDictionary *fieldsValue;
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
- (NSString *)fullVersion { return _fullVersionValue ?: _latestValue; }
- (BOOL)architectureSupported { return _architectureSupportedValue == nil || [_architectureSupportedValue boolValue]; }
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
- (BOOL)protectedPackage { return _protectedValue; }
- (BOOL)canReinstall { return _canReinstallOverride != nil ? [_canReinstallOverride boolValue] : _sourceValue != nil; }
- (BOOL)versionAvailable { return _sourceValue != nil; }
- (NSInteger)versionComparison { return _comparisonValue; }
- (NSInteger)versionPriority { return _priorityValue; }
- (BOOL)policyCandidate { return _candidateValue; }
- (BOOL)selectedVersionInstalled { return _selectedInstalledValue; }
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
- (NSString *)getField:(NSString *)name { return _fieldsValue[name]; }
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
    Require(!model.readOnly, "ordinary Package snapshot became readonly");
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
    Require([model.warnings count] == 3, "held and essential notices were not added to filtered warnings");
    Require([model.applications count] == 1, "invalid application values were not filtered");
    RequireString(model.applications[0].bundleIdentifier, @"com.example.runtime",
                  "application identifier changed");
    RequireString(model.applications[0].iconURLString,
                  @"file:///Applications/Runtime.app/icon.png", "application icon changed");

    NSArray *expectedKinds(@[
        @(CydiaPackageDetailModifyActionKindClear),
    ]);
    Require([ActionKinds(model) isEqualToArray:expectedKinds],
            "held package exposed a mutation action");
    RequireString(model.primaryModifyTitleLocalizationKey, @"CLEAR",
                  "held package cannot clear its queued selection");

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
        @(CydiaPackageDetailModifyActionKindRemove),
        @(CydiaPackageDetailModifyActionKindPurge)]],
        "installed source package actions changed");
    RequireString(reinstall.primaryModifyTitleLocalizationKey, @"MODIFY",
                  "Reinstall/Remove did not use Modify");

    FakePackage *local(BasePackage(@"runtime"));
    local.installedValue = @"1.0";
    CydiaPackageDetailViewModel *remove([[CydiaPackageDetailViewModel alloc]
        initWithPackage:(Package *)(id)local]);
    Require([ActionKinds(remove) isEqualToArray:@[@(CydiaPackageDetailModifyActionKindRemove),
        @(CydiaPackageDetailModifyActionKindPurge)]],
            "installed local package exposed repository actions");
    RequireString(remove.primaryModifyTitleLocalizationKey, @"MODIFY",
                  "local Remove and Purge were not separate actions");
}

void TestExactVersionActionsAndSafeguards() {
    FakePackageSource *source([[FakePackageSource alloc] init]);
    source.nameValue = [@"Repository" mutableCopy];
    FakePackage *package(BasePackage(@"runtime"));
    package.sourceValue = source;
    package.installedValue = @"2:1.0";
    package.latestValue = @"2:0.9";
    package.comparisonValue = -1;
    package.canReinstallOverride = @NO;
    FakePackage *choice(BasePackage(@"runtime"));
    choice.latestValue = [@"2:0.9" mutableCopy];
    choice.priorityValue = 1001;
    choice.candidateValue = YES;
    package.downgradesValue = @[choice];
    CydiaPackageDetailViewModel *model([[CydiaPackageDetailViewModel alloc] initWithPackage:(Package *)(id)package]);
    Require([ActionKinds(model) isEqualToArray:@[@(CydiaPackageDetailModifyActionKindDowngrade),
        @(CydiaPackageDetailModifyActionKindRemove), @(CydiaPackageDetailModifyActionKindPurge),
        @(CydiaPackageDetailModifyActionKindVersions)]], "policy downgrade was mislabeled or exposed wrong-version Reinstall");
    CydiaPackageDetailVersionChoice *version(model.modifyActions.lastObject.versions[0]);
    Require(version.priority == 1001 && version.candidate && !version.installed,
        "version pin/candidate/installed status was lost");
    RequireString(version.architecture, @"iphoneos-arm64", "version architecture was lost");
    [choice.latestValue appendString:@"-changed"];
    RequireString(version.version, @"2:0.9", "version choice retained mutable package state");
    package.protectedValue = YES;
    model = [[CydiaPackageDetailViewModel alloc] initWithPackage:(Package *)(id)package];
    Require([ActionKinds(model) isEqualToArray:@[@(CydiaPackageDetailModifyActionKindDowngrade),
        @(CydiaPackageDetailModifyActionKindVersions)]], "Protected package exposed Remove or Purge");
    package.protectedValue = NO;
    package.essentialValue = YES;
    model = [[CydiaPackageDetailViewModel alloc] initWithPackage:(Package *)(id)package];
    Require([ActionKinds(model) isEqualToArray:@[@(CydiaPackageDetailModifyActionKindDowngrade),
        @(CydiaPackageDetailModifyActionKindVersions)]], "Essential package exposed Remove or Purge");
}

void TestArchitecturePresentation() {
    NSArray *native(@[@"iphoneos-arm64"]);
    NSArray *multiarch(@[@"iphoneos-arm64", @"iphoneos-arm"]);
    Require(CydiaPackageArchitectureCaption(@"iphoneos-arm64", native) == nil &&
        CydiaPackageArchitectureCaption(@"all", native) == nil,
        "single-architecture native/all packages acquired new labels");
    RequireString(CydiaPackageArchitectureCaption(@"iphoneos-arm64", multiarch),
        @"Native · iphoneos-arm64", "native architecture role was lost");
    RequireString(CydiaPackageArchitectureCaption(@"iphoneos-arm", multiarch),
        @"Additional · iphoneos-arm", "foreign architecture role was lost");
    RequireString(CydiaPackageArchitectureCaption(@"all", multiarch),
        @"Architecture-independent · all", "all was treated as a foreign architecture");
    RequireString(CydiaPackageArchitectureCaption(@"iphoneos-arm", native),
        @"Unsupported · iphoneos-arm", "single-architecture unsupported exception disappeared");
    Require(CydiaPackageArchitectureCaption(@"any", multiarch) == nil &&
        CydiaPackageArchitectureCaption(@"iphoneos-arm", @[]) == nil,
        "dependency proxy or unknown runtime state invented an architecture role");
    Require([CydiaPackageRegisteredArchitectureNames({"iphoneos-arm64", "all", "iphoneos-arm64", "any", "iphoneos-arm"})
        isEqualToArray:multiarch], "registration projection changed native order or added proxy architectures");

    FakePackage *package(BasePackage(@"runtime:iphoneos-arm"));
    package.architectureValue = @"iphoneos-arm";
    FakePackage *choice(BasePackage(@"runtime:iphoneos-arm"));
    choice.architectureValue = @"iphoneos-arm";
    package.downgradesValue = @[choice];
    NSMutableArray *registered([multiarch mutableCopy]);
    CydiaPackageDetailViewModel *model([[CydiaPackageDetailViewModel alloc]
        initWithPackage:(Package *)(id)package registeredArchitectures:registered]);
    [registered removeAllObjects];
    RequireString(model.displayName, @"Runtime Package", "caption altered the raw package display name");
    RequireString(model.identity, @"runtime:iphoneos-arm", "caption altered the package route");
    RequireString(model.architectureCaption, @"Additional · iphoneos-arm", "detail did not own its architecture caption");
    CydiaPackageDetailVersionChoice *version(model.modifyActions.lastObject.versions.firstObject);
    RequireString(version.architectureCaption, @"Additional · iphoneos-arm", "version choice lost architecture context");
    RequireString(model.legacyDepictionSnapshot[@"package"][@"values"][@"architecture"], @"iphoneos-arm",
        "native caption leaked into the depiction API");

    package.architectureValue = @"iphoneos-arm64";
    choice.architectureValue = @"iphoneos-arm64";
    model = [[CydiaPackageDetailViewModel alloc] initWithPackage:(Package *)(id)package
        registeredArchitectures:native];
    Require(model.architectureCaption == nil &&
        model.modifyActions.lastObject.versions.firstObject.architectureCaption == nil,
        "single-architecture detail or version choices changed their historical labels");
}


void TestExactArchitectureAndEpochVersionChoices() {
    FakePackage *package(BasePackage(@"runtime"));
    FakePackage *native(BasePackage(@"runtime"));
    native.architectureValue = @"iphoneos-arm64";
    native.latestValue = @"1.0";
    native.fullVersionValue = @"1:1.0";
    FakePackage *all(BasePackage(@"runtime"));
    all.architectureValue = @"all";
    all.latestValue = @"1.0";
    all.fullVersionValue = @"2:1.0";
    FakePackage *unsupported(BasePackage(@"runtime:iphoneos-arm"));
    unsupported.architectureSupportedValue = @NO;
    package.downgradesValue = @[native, all, unsupported];
    CydiaPackageDetailViewModel *model([[CydiaPackageDetailViewModel alloc]
        initWithPackage:(Package *)(id)package registeredArchitectures:@[@"iphoneos-arm64"]
        versionArchitecture:@"all"]);
    NSArray *choices(model.modifyActions.lastObject.versions);
    Require(choices.count == 1, "exact all route leaked native or unsupported version choices");
    CydiaPackageDetailVersionChoice *choice(choices.firstObject);
    RequireString(choice.architecture, @"all", "all was replaced by its native APT bucket");
    RequireString(choice.fullVersion, @"2:1.0", "epoch was discarded from exact version identity");
    RequireString(choice.version, @"2:1.0", "version picker hid the epoch distinguishing its choices");
    model = [[CydiaPackageDetailViewModel alloc] initWithPackage:(Package *)(id)package
        registeredArchitectures:@[@"iphoneos-arm64"]];
    Require(model.modifyActions.lastObject.versions.count == 2,
        "unqualified route lost valid native/all alternatives or exposed an unsupported one");
    package.architectureSupportedValue = @NO;
    package.downgradesValue = @[];
    package.canReinstallOverride = @NO;
    model = [[CydiaPackageDetailViewModel alloc] initWithPackage:(Package *)(id)package];
    for (CydiaPackageDetailModifyAction *action in model.modifyActions)
        Require(action.kind != CydiaPackageDetailModifyActionKindInstall &&
            action.kind != CydiaPackageDetailModifyActionKindUpgrade &&
            action.kind != CydiaPackageDetailModifyActionKindDowngrade &&
            action.kind != CydiaPackageDetailModifyActionKindReinstall,
            "unsupported installed package offered an installation action");
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
    Require([model.warnings count] == 1 && [model.applications count] == 0,
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

void TestDelayedAccountActionSelection() {
    FakePackage *package(BasePackage(@"runtime:iphoneos-arm64"));
    package.uninstalledValue = YES; package.installedValue = nil;
    FakePackageSource *source = [FakePackageSource new];
    source.keyValue = [@"source" mutableCopy]; source.rootValue = @"https://repo.example/";
    package.sourceValue = source;
    FakePackage *sameVersion(BasePackage(@"runtime:iphoneos-arm64"));
    sameVersion.sourceValue = source;
    FakePackageSource *otherSource = [FakePackageSource new]; otherSource.rootValue = @"https://another.example/";
    FakePackage *otherVersion(BasePackage(@"runtime:iphoneos-arm64")); otherVersion.sourceValue = otherSource;
    package.downgradesValue = @[sameVersion, otherVersion];
    NSURL *constraint = [NSURL URLWithString:source.rootValue];
    auto scoped = [[CydiaPackageDetailViewModel alloc] initWithPackage:(Package *)(id)package
        registeredArchitectures:@[@"iphoneos-arm64"] versionArchitecture:nil repositoryConstraint:constraint];
    Require(scoped.modifyActions.lastObject.versions.count == 1,
        "purchased source version picker included another repository's package");
    Require([[CydiaPackageDetailViewModel alloc] initWithPackage:(Package *)(id)otherVersion
        registeredArchitectures:@[@"iphoneos-arm64"] versionArchitecture:nil repositoryConstraint:constraint] == nil,
        "source-constrained snapshot accepted another repository's package");
    CydiaPackageDetailViewModel *(^snapshot)(void) = ^{
        return [[CydiaPackageDetailViewModel alloc] initWithPackage:(Package *)(id)package];
    };
    auto selected = snapshot();
    const auto install = CydiaPackageDetailModifyActionKindInstall;
    Require(CydiaPackageDetailCanPerformAction(selected, snapshot(), install), "fresh exact install refused");
    package.ignoredValue = YES;
    Require(!CydiaPackageDetailCanPerformAction(selected, snapshot(), install), "late hold did not retire download action");
    package.ignoredValue = NO; package.architectureSupportedValue = @NO;
    Require(!CydiaPackageDetailCanPerformAction(selected, snapshot(), install), "unsupported arch accepted delayed download");
    package.architectureSupportedValue = @YES;
    source.rootValue = @"https://another.example/";
    Require(!CydiaPackageDetailCanPerformAction(selected, snapshot(), install), "changed source accepted delayed download");
    source.rootValue = @"https://repo.example/"; source.keyValue = [@"another-source" mutableCopy];
    Require(!CydiaPackageDetailCanPerformAction(selected, snapshot(), install), "changed source stanza accepted delayed download");
    source.keyValue = [@"source" mutableCopy]; package.fullVersionValue = @"3:1.1";
    Require(!CydiaPackageDetailCanPerformAction(selected, snapshot(), install), "changed epoch accepted delayed download");
    package.fullVersionValue = nil; package.architectureValue = @"iphoneos-arm";
    Require(!CydiaPackageDetailCanPerformAction(selected, snapshot(), install), "changed arch accepted delayed download");
    package.architectureValue = @"iphoneos-arm64"; package.sourceValue = nil;
    Require(!CydiaPackageDetailCanPerformAction(selected, snapshot(), install), "removed source accepted delayed download");
    Require(!CydiaPackageDetailCanPerformAction(selected, nil, install), "missing fresh snapshot accepted download");
}

void TestReadonlyRepositorySnapshot() {
    CydiaAPT::RepositoryPackageAvailabilityData availability;
    availability.known = true;
    availability.displayName = "Repository Runtime";
    availability.version = "2:1.1";
    availability.architecture = "iphoneos-arm";
    availability.architectures = {"iphoneos-arm"};
    availability.record.displayName = "Lower Priority Record Name";
    availability.record.shortDescription = "Short repository description";
    availability.record.longDescription = "Long repository description\nSecond line";
    availability.record.tags = {"cydia::commercial", "purpose::console"};
    availability.record.fields = {
        {"Package", "runtime"}, {"Version", "2:1.1"}, {"Architecture", "iphoneos-arm"},
        {"Description", "Short repository description\n Long repository description"},
        {"Section", "System"}, {"Multi-Arch", "foreign"},
        {"Homepage", "https://example.test/runtime"},
        {"Author", "\"Runtime Author\" <author@example.test>"},
        {"Maintainer", "Runtime Packager <maintainer@example.test>"},
        {"Sponsor", "Runtime Sponsor <http://sponsor.example/project?ref=runtime>"},
        {"Icon", "https://repo.example/runtime.png"},
        {"Tag", "cydia::commercial, purpose::console"},
        {"Depiction", "https://repo.example/depiction?package=runtime"},
        {"Filename", "pool/private-runtime.deb"}, {"SHA256", "not-acquisition-authority"},
    };
    availability.record.raw = "Package: runtime\nFilename: pool/private-runtime.deb\n";
    NSMutableString *identifier([@"runtime" mutableCopy]);
    NSMutableString *sourceName([@"Owned Repository" mutableCopy]);
    NSMutableArray<NSString *> *architectures([NSMutableArray arrayWithObject:@"iphoneos-arm64"]);
    NSURL *sourceURL([NSURL URLWithString:@"https://repo.example/ios/"]);
    auto model = [[CydiaPackageDetailViewModel alloc] initWithRepositoryPackage:availability
        identifier:identifier sourceURL:sourceURL sourceName:sourceName registeredArchitectures:architectures];
    Require(model != nil && model.readOnly, "source-scoped unsupported record did not open readonly details");
    RequireString(model.identity, @"runtime", "readonly detail identifier changed");
    RequireString(model.displayName, @"Repository Runtime", "readonly detail lost source display name");
    RequireString(model.fullVersion, @"2:1.1", "readonly detail lost exact epoch version");
    RequireString(model.architecture, @"iphoneos-arm", "readonly detail borrowed another source architecture");
    RequireString(model.architectureCaption,
        CydiaPackageArchitectureCaption(@"iphoneos-arm", @[@"iphoneos-arm64"]),
        "readonly detail did not reuse the unsupported architecture caption");
    RequireString(model.displayDescription, @"Long repository description\nSecond line",
        "readonly detail lost multiline repository description");
    RequireString(model.rawSection, @"System", "readonly detail lost source section");
    RequireString(model.depictionURLString, @"https://repo.example/depiction?package=runtime",
        "readonly detail rejected safe repository depiction");
    RequireString(model.homepageURLString, @"https://example.test/runtime", "readonly detail lost safe homepage");
    RequireString(model.authorName, @"Runtime Author", "readonly detail lost the independent author name");
    RequireString(model.authorAddress, @"author@example.test", "readonly detail lost author mail address");
    RequireString(model.maintainerName, @"Runtime Packager", "readonly detail conflated maintainer with author");
    RequireString(model.maintainerAddress, @"maintainer@example.test", "readonly detail lost maintainer mail address");
    RequireString(model.sponsorName, @"Runtime Sponsor", "readonly detail lost sponsor name");
    RequireString(model.sponsorURLString, @"http://sponsor.example/project?ref=runtime", "Sponsor resource URI was treated as an email");
    RequireString(model.iconURLString, @"https://repo.example/runtime.png", "readonly detail lost the public package icon");
    Require([model.tags isEqual:@[@"cydia::commercial", @"purpose::console"]], "readonly detail lost inert package tags");
    RequireString(model.source.repositoryURLString, @"https://repo.example/ios/", "readonly detail broadened source scope");
    Require(model.isCommercial && !model.isInstalled && !model.isUpgradable && !model.isConsolePackage &&
        model.aptIdentity == nil && model.dpkgIdentity == nil && model.modifyActions.count == 0 &&
        model.primaryModifyTitleLocalizationKey == nil && model.applications.count == 0 && model.warnings.count == 1,
        "readonly detail invented package actions, local state, or executable identity");
    NSDictionary *legacyPackage(model.legacyDepictionSnapshot[@"package"]);
    RequireString(legacyPackage[@"author"][@"address"], @"author@example.test", "readonly depiction lost structured author");
    RequireString(legacyPackage[@"maintainer"][@"address"], @"maintainer@example.test", "readonly depiction lost structured maintainer");
    RequireString(legacyPackage[@"sponsor"][@"address"], @"http://sponsor.example/project?ref=runtime", "readonly depiction lost structured sponsor");
    RequireString(legacyPackage[@"values"][@"icon"], @"https://repo.example/runtime.png", "readonly depiction icon differed from safe metadata");
    RequireString(legacyPackage[@"fields"][@"Sponsor"], @"Runtime Sponsor <http://sponsor.example/project?ref=runtime>",
        "readonly depiction lost Sponsor's original control-field syntax");
    RequireString(legacyPackage[@"fields"][@"Tag"], @"cydia::commercial, purpose::console", "readonly depiction lost raw Tag metadata");
    RequireString(legacyPackage[@"fields"][@"Description"],
        @"Short repository description\n Long repository description", "readonly depiction lost scoped display fields");
    Require(legacyPackage[@"fields"][@"Filename"] == nil && legacyPackage[@"fields"][@"SHA256"] == nil &&
        legacyPackage[@"record"] == nil && legacyPackage[@"values"][@"aptId"] == nil &&
        legacyPackage[@"values"][@"dpkgId"] == nil,
        "readonly depiction retained archive or executable lookup authority");

    FakePackage *package(BasePackage(@"runtime"));
    package.uninstalledValue = YES; package.architectureValue = @"iphoneos-arm";
    FakePackageSource *source([FakePackageSource new]);
    source.rootValue = sourceURL.absoluteString; package.sourceValue = source;
    auto actionable = [[CydiaPackageDetailViewModel alloc] initWithPackage:(Package *)(id)package];
    Require([ActionKinds(actionable) containsObject:@(CydiaPackageDetailModifyActionKindInstall)] &&
        !CydiaPackageDetailCanPerformAction(model, actionable, CydiaPackageDetailModifyActionKindInstall),
        "readonly detail later acquired mutation authority through a normal package snapshot");

    NSString *caption(model.architectureCaption);
    [identifier appendString:@".changed"]; [sourceName appendString:@" Changed"]; [architectures removeAllObjects];
    availability.displayName = "Changed"; availability.version = "9.0"; availability.architecture = "changed";
    availability.architectures.clear(); availability.record.fields.clear(); availability.record.tags.clear();
    availability.record.longDescription = "Changed";
    RequireString(model.displayName, @"Repository Runtime", "readonly detail retained mutable repository name");
    RequireString(model.identity, @"runtime", "readonly detail retained mutable identifier");
    RequireString(model.source.name, @"Owned Repository", "readonly detail retained mutable source name");
    RequireString(model.fullVersion, @"2:1.1", "readonly detail retained mutable version");
    RequireString(model.architectureCaption, caption, "readonly detail retained mutable architecture inputs");
    RequireString(model.legacyDepictionSnapshot[@"package"][@"fields"][@"Section"], @"System",
        "readonly detail retained mutable control record fields");
    RequireString(model.authorAddress, @"author@example.test", "readonly contact retained mutable control data");
    RequireString(model.sponsorURLString, @"http://sponsor.example/project?ref=runtime", "readonly sponsor retained mutable control data");
    Require(model.tags.count == 2, "readonly tags retained mutable control data");

    availability.known = false;
    availability.record.fields["Depiction"] = "https://other.example/unknown";
    auto unknown = [[CydiaPackageDetailViewModel alloc] initWithRepositoryPackage:availability
        identifier:@"runtime" sourceURL:sourceURL sourceName:@"Owned Repository" registeredArchitectures:@[]];
    RequireString(unknown.displayName, @"runtime", "unknown detail trusted incidental external display metadata");
    Require(unknown.readOnly && unknown.architecture == nil && unknown.fullVersion == nil &&
        unknown.depictionURLString == nil && unknown.warnings.count == 1 && unknown.modifyActions.count == 0,
        "unknown repository detail invented metadata or modification authority, or omitted its availability notice");

    availability.known = true; availability.displayName = "Unsafe\nName";
    availability.record.displayName.clear(); availability.record.longDescription.clear();
    availability.record.fields["Homepage"] = "file:///tmp/runtime";
    availability.record.fields["Depiction"] = "https://repo.example/%0adepiction";
    availability.record.fields["Icon"] = "file:///tmp/runtime.png";
    availability.record.fields["Sponsor"] = "Named Sponsor <javascript:alert(1)>";
    availability.record.fields["Author"] = "Author <a?bcc=other@example.test>";
    availability.record.fields["Maintainer"] = "Packager <maintainer@example.test>";
    auto safe = [[CydiaPackageDetailViewModel alloc] initWithRepositoryPackage:availability
        identifier:@"runtime" sourceURL:sourceURL sourceName:@"Owned Repository" registeredArchitectures:@[]];
    RequireString(safe.displayName, @"runtime", "readonly detail displayed a control-bearing repository name");
    Require(safe.homepageURLString == nil && safe.depictionURLString == nil,
        "readonly detail accepted unsafe public metadata URLs");
    Require(safe.iconURLString == nil && safe.sponsorURLString == nil && safe.authorAddress == nil &&
        safe.legacyDepictionSnapshot[@"package"][@"fields"][@"Icon"] == nil,
        "readonly detail accepted an unsafe icon, sponsor, or mailto address");
    RequireString(safe.sponsorName, @"Named Sponsor", "unsafe sponsor link erased its safe display name");
    RequireString(safe.maintainerAddress, @"maintainer@example.test", "unsafe author erased independent safe maintainer metadata");
    availability.record.fields["Author"] = "author@example.test";
    availability.record.fields["Maintainer"] = "maintainer@example.test";
    availability.record.fields["Sponsor"] = "https://sponsor.example/project?ref=runtime";
    auto bare = [[CydiaPackageDetailViewModel alloc] initWithRepositoryPackage:availability
        identifier:@"runtime" sourceURL:sourceURL sourceName:@"Owned Repository" registeredArchitectures:@[]];
    RequireString(bare.authorAddress, @"author@example.test", "bare author email lost native clickability");
    RequireString(bare.maintainerAddress, @"maintainer@example.test", "bare maintainer email lost native clickability");
    RequireString(bare.sponsorURLString, @"https://sponsor.example/project?ref=runtime", "bare Sponsor URI lost native clickability");
    RequireString(bare.legacyDepictionSnapshot[@"package"][@"author"][@"address"], @"author@example.test",
        "bare contact email did not enter the readonly depiction snapshot");
}

void TestOrdinaryMetadataSnapshot() {
    FakePackage *package(BasePackage(@"runtime"));
    NSMutableString *icon([@"https://repo.example/icon.png" mutableCopy]);
    NSMutableString *sponsor([@"Runtime Sponsor <https://sponsor.example/>" mutableCopy]);
    NSMutableString *tag([@"purpose::utility" mutableCopy]);
    package.fieldsValue = @{@"Icon": icon, @"Sponsor": sponsor};
    package.tagsValue = [NSMutableArray arrayWithObjects:tag, @42, @"bad\ntag", nil];
    auto model = [[CydiaPackageDetailViewModel alloc] initWithPackage:(Package *)(id)package];
    RequireString(model.iconURLString, @"https://repo.example/icon.png", "ordinary detail lost safe public icon metadata");
    RequireString(model.sponsorName, @"Runtime Sponsor", "ordinary detail lost Sponsor name");
    RequireString(model.sponsorURLString, @"https://sponsor.example/", "ordinary detail lost Sponsor resource URI");
    Require([model.tags isEqual:@[@"purpose::utility"]], "ordinary tags retained malformed values");
    RequireString(model.legacyDepictionSnapshot[@"package"][@"values"][@"icon"], @"cydia://package-icon/runtime",
        "new public icon metadata changed the ordinary package icon route");
    [icon appendString:@".changed"]; [sponsor appendString:@" Changed"]; [tag appendString:@".changed"];
    [(NSMutableArray *)package.tagsValue removeAllObjects];
    RequireString(model.iconURLString, @"https://repo.example/icon.png", "ordinary icon metadata retained a mutable field");
    RequireString(model.sponsorURLString, @"https://sponsor.example/", "ordinary Sponsor retained a mutable field");
    Require([model.tags isEqual:@[@"purpose::utility"]], "ordinary tags retained mutable caller values");
    package.fieldsValue = @{@"Icon": @"file:///Applications/Runtime.app/icon.png"};
    auto localIcon = [[CydiaPackageDetailViewModel alloc] initWithPackage:(Package *)(id)package];
    Require(localIcon.iconURLString == nil, "new public icon metadata accepted a local file URI");
    RequireString(localIcon.legacyDepictionSnapshot[@"package"][@"fields"][@"Icon"],
        @"file:///Applications/Runtime.app/icon.png", "ordinary depiction lost its original raw Icon field");
    package.fieldsValue = @{@"Icon": @"https://user:secret@repo.example/icon.png", @"Sponsor": @"Sponsor <file:///tmp/site>"};
    auto unsafe = [[CydiaPackageDetailViewModel alloc] initWithPackage:(Package *)(id)package];
    Require(unsafe.iconURLString == nil && unsafe.sponsorURLString == nil, "ordinary detail accepted unsafe public metadata URLs");
}

int main() {
    @autoreleasepool {
        TestCompleteQualifiedSnapshotAndOwnership();
        TestInstallReinstallRemoveAndLocalActions();
        TestExactVersionActionsAndSafeguards();
        TestArchitecturePresentation();
        TestExactArchitectureAndEpochVersionChoices();
        TestNullabilityFallbackAndContactPriority();
        TestDelayedAccountActionSelection();
        TestReadonlyRepositorySnapshot();
        TestOrdinaryMetadataSnapshot();
    }
    std::cout << "[verify-package-detail-view-model][ ok ] immutable package snapshot"
              << std::endl;
    return 0;
}
