/* Cydia Refurbished native confirmation model.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef Cydia_ConfirmationViewModel_H
#define Cydia_ConfirmationViewModel_H

#import <Foundation/Foundation.h>

#include <stdint.h>

#ifdef __cplusplus
namespace CydiaAPT {
struct TransactionData;
}
#endif

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, CydiaConfirmationChangeKind) {
    CydiaConfirmationChangeKindInstall,
    CydiaConfirmationChangeKindReinstall,
    CydiaConfirmationChangeKindUpgrade,
    CydiaConfirmationChangeKindDowngrade,
    CydiaConfirmationChangeKindRemove,
    CydiaConfirmationChangeKindPurge,
};

typedef NS_ENUM(NSUInteger, CydiaConfirmationClauseStatus) {
    CydiaConfirmationClauseStatusUnknown,
    CydiaConfirmationClauseStatusMissing,
    CydiaConfirmationClauseStatusInstalled,
    CydiaConfirmationClauseStatusUninstalled,
    CydiaConfirmationClauseStatusUninstallable,
    CydiaConfirmationClauseStatusVirtual,
};

typedef NS_ENUM(NSUInteger, CydiaConfirmationEssentialRemovalPolicy) {
    CydiaConfirmationEssentialRemovalPolicyNone,
    CydiaConfirmationEssentialRemovalPolicyBlocked,
    CydiaConfirmationEssentialRemovalPolicyForceAllowed,
};

typedef NS_ENUM(NSUInteger, CydiaConfirmationUserAction) {
    CydiaConfirmationUserActionCancel,
    CydiaConfirmationUserActionContinueQueuing,
    CydiaConfirmationUserActionConfirm,
    CydiaConfirmationUserActionBlockedEssentialAcknowledged,
    CydiaConfirmationUserActionForceRemovalCancelled,
    CydiaConfirmationUserActionForceRemovalConfirmed,
};

typedef NS_ENUM(NSUInteger, CydiaConfirmationActionEffect) {
    CydiaConfirmationActionEffectNone,
    CydiaConfirmationActionEffectCancelAndClear,
    CydiaConfirmationActionEffectContinueQueuing,
    CydiaConfirmationActionEffectConfirm,
    CydiaConfirmationActionEffectDismissWithoutDelegate,
    CydiaConfirmationActionEffectPresentBlockedEssentialAlert,
    CydiaConfirmationActionEffectPresentForceRemovalAlert,
};

typedef NS_ENUM(NSUInteger, CydiaConfirmationTableSectionKind) {
    CydiaConfirmationTableSectionKindIssueNotice,
    CydiaConfirmationTableSectionKindQueue,
    CydiaConfirmationTableSectionKindSizes,
    CydiaConfirmationTableSectionKindModifications,
    CydiaConfirmationTableSectionKindIssueDetails,
};

typedef NSString * _Nullable (^CydiaConfirmationPackageNameResolver)(NSString *packageIdentity);

@interface CydiaConfirmationPackageReference : NSObject

@property (nonatomic, readonly, copy) NSString *identity;
@property (nonatomic, readonly, copy) NSString *displayName;

- (instancetype) init NS_UNAVAILABLE;
+ (instancetype) new NS_UNAVAILABLE;

@end

@interface CydiaConfirmationChangeGroup : NSObject

@property (nonatomic, readonly) CydiaConfirmationChangeKind kind;
@property (nonatomic, readonly, copy) NSString *titleLocalizationKey;
@property (nonatomic, readonly, copy) NSArray<CydiaConfirmationPackageReference *> *packages;

- (instancetype) init NS_UNAVAILABLE;
+ (instancetype) new NS_UNAVAILABLE;

@end


@interface CydiaConfirmationClause : NSObject

@property (nonatomic, readonly, strong) CydiaConfirmationPackageReference *package;
@property (nonatomic, readonly, copy, nullable) NSString *comparisonOperator;
@property (nonatomic, readonly, copy, nullable) NSString *requiredVersion;
@property (nonatomic, readonly) CydiaConfirmationClauseStatus status;
@property (nonatomic, readonly, copy) NSString *rawStatusIdentifier;
/* This is the version selected by the transaction plan, not necessarily the
   version currently installed by dpkg. */
@property (nonatomic, readonly, copy, nullable) NSString *plannedVersion;

- (instancetype) init NS_UNAVAILABLE;
+ (instancetype) new NS_UNAVAILABLE;

@end


@interface CydiaConfirmationReason : NSObject

@property (nonatomic, readonly, copy) NSString *relationship;
@property (nonatomic, readonly, copy) NSArray<CydiaConfirmationClause *> *clauses;

- (instancetype) init NS_UNAVAILABLE;
+ (instancetype) new NS_UNAVAILABLE;

@end


@interface CydiaConfirmationIssue : NSObject

@property (nonatomic, readonly, strong, nullable) CydiaConfirmationPackageReference *package;
@property (nonatomic, readonly, copy) NSArray<CydiaConfirmationReason *> *reasons;
@property (nonatomic, readonly, copy) NSString *kind;

- (instancetype) init NS_UNAVAILABLE;
+ (instancetype) new NS_UNAVAILABLE;

@end


@interface CydiaConfirmationViewModel : NSObject

/* Only non-empty groups are exposed, in the stable install, reinstall,
   upgrade, downgrade, remove, purge order used by the native table. */
@property (nonatomic, readonly, copy) NSArray<CydiaConfirmationChangeGroup *> *groups;
@property (nonatomic, readonly, copy) NSArray<CydiaConfirmationIssue *> *issues;
@property (nonatomic, readonly) uint64_t downloadingBytes;
@property (nonatomic, readonly) uint64_t resumingBytes;
@property (nonatomic, readonly) CydiaConfirmationEssentialRemovalPolicy essentialRemovalPolicy;
@property (nonatomic, readonly) BOOL requiresSubstrateRestart;
@property (nonatomic, readonly) BOOL hasChanges;
@property (nonatomic, readonly) BOOL hasBlockingIssues;
/* Dependency and package-protection issues block confirmation. */
@property (nonatomic, readonly) BOOL showsConfirmAction;

- (instancetype) init NS_UNAVAILABLE;
+ (instancetype) new NS_UNAVAILABLE;

#ifdef __cplusplus
- (instancetype) initWithTransactionData:(const CydiaAPT::TransactionData &)transaction
                      advancedModeEnabled:(BOOL)advancedModeEnabled
                      packageNameResolver:(nullable CydiaConfirmationPackageNameResolver)packageNameResolver NS_DESIGNATED_INITIALIZER;
#endif

- (nullable CydiaConfirmationChangeGroup *) groupForKind:(CydiaConfirmationChangeKind)kind;

@end


@interface CydiaConfirmationActionState : NSObject

@property (nonatomic, readonly, getter=isTerminal) BOOL terminal;

- (instancetype) init NS_UNAVAILABLE;
+ (instancetype) new NS_UNAVAILABLE;

- (instancetype) initWithBlockingIssues:(BOOL)blockingIssues
                  essentialRemovalPolicy:(CydiaConfirmationEssentialRemovalPolicy)essentialRemovalPolicy NS_DESIGNATED_INITIALIZER;
- (CydiaConfirmationActionEffect) effectForUserAction:(CydiaConfirmationUserAction)userAction;

@end


@interface CydiaConfirmationTableSection : NSObject

@property (nonatomic, readonly) CydiaConfirmationTableSectionKind kind;
@property (nonatomic, readonly, strong, nullable) CydiaConfirmationIssue *issue;
@property (nonatomic, readonly, copy) NSArray<CydiaConfirmationChangeGroup *> *changeGroups;
@property (nonatomic, readonly) NSUInteger rowCount;

- (instancetype) init NS_UNAVAILABLE;
+ (instancetype) new NS_UNAVAILABLE;

@end


FOUNDATION_EXPORT NSArray<CydiaConfirmationTableSection *> *
CydiaConfirmationBuildTableSections(CydiaConfirmationViewModel *viewModel);


NS_ASSUME_NONNULL_END

#endif // Cydia_ConfirmationViewModel_H
