/* Cydia Refurbished native confirmation model.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/ConfirmationViewModel.h"

#include "Cydia/AptCompatibility.hpp"

#include <string>
#include <vector>

namespace {

NSString *StringFromUTF8(const std::string &value) {
    if (value.empty())
        return @"";

    NSString *string([[NSString alloc] initWithBytes:value.data()
                                               length:value.size()
                                             encoding:NSUTF8StringEncoding]);
    if (string == nil)
        string = [[NSString alloc] initWithBytes:value.data()
                                          length:value.size()
                                        encoding:NSISOLatin1StringEncoding];
    return string ?: @"";
}

CydiaConfirmationClauseStatus ClauseStatus(NSString *identifier) {
    if ([identifier isEqualToString:@"missing"])
        return CydiaConfirmationClauseStatusMissing;
    if ([identifier isEqualToString:@"installed"])
        return CydiaConfirmationClauseStatusInstalled;
    if ([identifier isEqualToString:@"uninstalled"])
        return CydiaConfirmationClauseStatusUninstalled;
    if ([identifier isEqualToString:@"uninstallable"])
        return CydiaConfirmationClauseStatusUninstallable;
    if ([identifier isEqualToString:@"virtual"])
        return CydiaConfirmationClauseStatusVirtual;
    return CydiaConfirmationClauseStatusUnknown;
}

} // namespace


@interface CydiaConfirmationPackageReference ()
- (instancetype) initWithIdentity:(NSString *)identity displayName:(NSString *)displayName;
@end

@implementation CydiaConfirmationPackageReference

- (instancetype) initWithIdentity:(NSString *)identity displayName:(NSString *)displayName {
    if ((self = [super init]) != nil) {
        _identity = [identity copy];
        _displayName = [displayName copy];
    }
    return self;
}

@end


@interface CydiaConfirmationChangeGroup ()
- (instancetype) initWithKind:(CydiaConfirmationChangeKind)kind
          titleLocalizationKey:(NSString *)titleLocalizationKey
                      packages:(NSArray<CydiaConfirmationPackageReference *> *)packages;
@end

@implementation CydiaConfirmationChangeGroup

- (instancetype) initWithKind:(CydiaConfirmationChangeKind)kind
          titleLocalizationKey:(NSString *)titleLocalizationKey
                      packages:(NSArray<CydiaConfirmationPackageReference *> *)packages {
    if ((self = [super init]) != nil) {
        _kind = kind;
        _titleLocalizationKey = [titleLocalizationKey copy];
        _packages = [packages copy];
    }
    return self;
}

@end


@interface CydiaConfirmationClause ()
- (instancetype) initWithPackage:(CydiaConfirmationPackageReference *)package
              comparisonOperator:(nullable NSString *)comparisonOperator
                 requiredVersion:(nullable NSString *)requiredVersion
                           status:(CydiaConfirmationClauseStatus)status
              rawStatusIdentifier:(NSString *)rawStatusIdentifier
                   plannedVersion:(nullable NSString *)plannedVersion;
@end

@implementation CydiaConfirmationClause

- (instancetype) initWithPackage:(CydiaConfirmationPackageReference *)package
              comparisonOperator:(NSString *)comparisonOperator
                 requiredVersion:(NSString *)requiredVersion
                           status:(CydiaConfirmationClauseStatus)status
              rawStatusIdentifier:(NSString *)rawStatusIdentifier
                   plannedVersion:(NSString *)plannedVersion {
    if ((self = [super init]) != nil) {
        _package = package;
        _comparisonOperator = [comparisonOperator copy];
        _requiredVersion = [requiredVersion copy];
        _status = status;
        _rawStatusIdentifier = [rawStatusIdentifier copy];
        _plannedVersion = [plannedVersion copy];
    }
    return self;
}

@end


@interface CydiaConfirmationReason ()
- (instancetype) initWithRelationship:(NSString *)relationship
                               clauses:(NSArray<CydiaConfirmationClause *> *)clauses;
@end

@implementation CydiaConfirmationReason

- (instancetype) initWithRelationship:(NSString *)relationship
                               clauses:(NSArray<CydiaConfirmationClause *> *)clauses {
    if ((self = [super init]) != nil) {
        _relationship = [relationship copy];
        _clauses = [clauses copy];
    }
    return self;
}

@end


@interface CydiaConfirmationIssue ()
- (instancetype) initWithPackage:(nullable CydiaConfirmationPackageReference *)package
                           reasons:(NSArray<CydiaConfirmationReason *> *)reasons;
@end

@implementation CydiaConfirmationIssue

- (instancetype) initWithPackage:(CydiaConfirmationPackageReference *)package
                           reasons:(NSArray<CydiaConfirmationReason *> *)reasons {
    if ((self = [super init]) != nil) {
        _package = package;
        _reasons = [reasons copy];
    }
    return self;
}

@end


namespace {

CydiaConfirmationPackageReference *PackageReference(
    const std::string &value,
    CydiaConfirmationPackageNameResolver resolver,
    NSMutableDictionary<NSString *, CydiaConfirmationPackageReference *> *cache) {
    NSString *identity(StringFromUTF8(value));
    CydiaConfirmationPackageReference *reference([cache objectForKey:identity]);
    if (reference != nil)
        return reference;

    NSString *displayName(resolver == nil ? nil : resolver(identity));
    if ([displayName length] == 0)
        displayName = identity;

    reference = [[CydiaConfirmationPackageReference alloc]
        initWithIdentity:identity
             displayName:displayName];
    [cache setObject:reference forKey:identity];
    return reference;
}

CydiaConfirmationChangeGroup *ChangeGroup(
    CydiaConfirmationChangeKind kind,
    NSString *localizationKey,
    const std::vector<std::string> &values,
    CydiaConfirmationPackageNameResolver resolver,
    NSMutableDictionary<NSString *, CydiaConfirmationPackageReference *> *cache) {
    if (values.empty())
        return nil;

    NSMutableArray<CydiaConfirmationPackageReference *> *packages(
        [NSMutableArray arrayWithCapacity:values.size()]);
    for (std::vector<std::string>::const_iterator value(values.begin());
         value != values.end(); ++value)
        [packages addObject:PackageReference(*value, resolver, cache)];

    return [[CydiaConfirmationChangeGroup alloc]
        initWithKind:kind
        titleLocalizationKey:localizationKey
        packages:packages];
}

} // namespace


@implementation CydiaConfirmationViewModel

- (instancetype) initWithTransactionData:(const CydiaAPT::TransactionData &)transaction
                      advancedModeEnabled:(BOOL)advancedModeEnabled
                      packageNameResolver:(CydiaConfirmationPackageNameResolver)packageNameResolver {
    if ((self = [super init]) != nil) {
        NSMutableDictionary<NSString *, CydiaConfirmationPackageReference *> *references(
            [NSMutableDictionary dictionaryWithCapacity:32]);
        NSMutableArray<CydiaConfirmationChangeGroup *> *groups(
            [NSMutableArray arrayWithCapacity:5]);

        CydiaConfirmationChangeGroup *group;
        group = ChangeGroup(CydiaConfirmationChangeKindInstall, @"INSTALL",
                            transaction.installs, packageNameResolver, references);
        if (group != nil)
            [groups addObject:group];
        group = ChangeGroup(CydiaConfirmationChangeKindReinstall, @"REINSTALL",
                            transaction.reinstalls, packageNameResolver, references);
        if (group != nil)
            [groups addObject:group];
        group = ChangeGroup(CydiaConfirmationChangeKindUpgrade, @"UPGRADE",
                            transaction.upgrades, packageNameResolver, references);
        if (group != nil)
            [groups addObject:group];
        group = ChangeGroup(CydiaConfirmationChangeKindDowngrade, @"DOWNGRADE",
                            transaction.downgrades, packageNameResolver, references);
        if (group != nil)
            [groups addObject:group];
        group = ChangeGroup(CydiaConfirmationChangeKindRemove, @"REMOVE",
                            transaction.removes, packageNameResolver, references);
        if (group != nil)
            [groups addObject:group];

        NSMutableArray<CydiaConfirmationIssue *> *issues(
            [NSMutableArray arrayWithCapacity:transaction.issues.size()]);
        for (std::vector<CydiaAPT::TransactionIssueData>::const_iterator issue(transaction.issues.begin());
             issue != transaction.issues.end(); ++issue) {
            NSMutableArray<CydiaConfirmationReason *> *reasons(
                [NSMutableArray arrayWithCapacity:issue->reasons.size()]);
            for (std::vector<CydiaAPT::TransactionReasonData>::const_iterator reason(issue->reasons.begin());
                 reason != issue->reasons.end(); ++reason) {
                NSMutableArray<CydiaConfirmationClause *> *clauses(
                    [NSMutableArray arrayWithCapacity:reason->clauses.size()]);
                for (std::vector<CydiaAPT::TransactionClauseData>::const_iterator clause(reason->clauses.begin());
                     clause != reason->clauses.end(); ++clause) {
                    NSString *rawStatus(StringFromUTF8(clause->reason));
                    NSString *comparison(clause->comparison.empty() ? nil : StringFromUTF8(clause->comparison));
                    NSString *required(clause->version.empty() ? nil : StringFromUTF8(clause->version));
                    NSString *planned(clause->installed.empty() ? nil : StringFromUTF8(clause->installed));
                    [clauses addObject:[[CydiaConfirmationClause alloc]
                        initWithPackage:PackageReference(clause->package, packageNameResolver, references)
                        comparisonOperator:comparison
                        requiredVersion:required
                        status:ClauseStatus(rawStatus)
                        rawStatusIdentifier:rawStatus
                        plannedVersion:planned]];
                }

                [reasons addObject:[[CydiaConfirmationReason alloc]
                    initWithRelationship:StringFromUTF8(reason->relationship)
                    clauses:clauses]];
            }

            CydiaConfirmationPackageReference *package(issue->package.empty() ? nil :
                PackageReference(issue->package, packageNameResolver, references));
            [issues addObject:[[CydiaConfirmationIssue alloc]
                initWithPackage:package
                reasons:reasons]];
        }

        _groups = [groups copy];
        _issues = [issues copy];
        _downloadingBytes = transaction.downloading;
        _resumingBytes = transaction.resuming;
        if (!transaction.removesEssential)
            _essentialRemovalPolicy = CydiaConfirmationEssentialRemovalPolicyNone;
        else if (advancedModeEnabled)
            _essentialRemovalPolicy = CydiaConfirmationEssentialRemovalPolicyForceAllowed;
        else
            _essentialRemovalPolicy = CydiaConfirmationEssentialRemovalPolicyBlocked;
        _requiresSubstrateRestart = transaction.substrate;
        _hasChanges = [_groups count] != 0;
        _hasBlockingIssues = [_issues count] != 0;
        _showsConfirmAction = !_hasBlockingIssues;
    }
    return self;
}

- (CydiaConfirmationChangeGroup *) groupForKind:(CydiaConfirmationChangeKind)kind {
    for (CydiaConfirmationChangeGroup *group in _groups)
        if ([group kind] == kind)
            return group;
    return nil;
}

@end
