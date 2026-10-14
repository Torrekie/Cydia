/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#import "Cydia/PackageDetailController+Accounts.h"
#import "Cydia/RepositoryAccountsController.h"
#import "Cydia/RepositoryPackagePresentation.h"
#import "Cydia/Database.h"
#import "Cydia/Package.h"

@implementation PackageDetailController (RepositoryAccounts)
- (void)showRepositoryAccount {
    CydiaPackageDetailViewModel *selection = self.viewModel;
    Database *database = [Database sharedInstance];
    const unsigned era = database.era;
    CydiaPackageDetailModifyAction *download = nil;
    for (CydiaPackageDetailModifyAction *candidate in selection.modifyActions) {
        switch (candidate.kind) {
            case CydiaPackageDetailModifyActionKindInstall:
            case CydiaPackageDetailModifyActionKindUpgrade:
            case CydiaPackageDetailModifyActionKindDowngrade:
            case CydiaPackageDetailModifyActionKindReinstall:
                download = candidate;
                break;
            default: break;
        }
        if (download != nil) break;
    }
    __weak PackageDetailController *weakSelf = self;
    void (^downloadAction)(void) = nil;
    BOOL (^selectionIsCurrent)(void) = nil;
    void (^prepareSelection)(void (^)(BOOL)) = nil;
    if (download != nil) {
        selectionIsCurrent = ^BOOL {
            PackageDetailController *self = weakSelf;
            if (!self || self.viewModel != selection || database.era != era ||
                ![self.navigationController.viewControllers containsObject:self] ||
                !database.repositoryAuthorizedDownloadsSupported) return NO;
            Package *package = [database packageWithName:selection.identity];
            if (!package) return NO;
            CydiaPackageDetailViewModel *current = [[CydiaPackageDetailViewModel alloc]
                initWithPackage:package registeredArchitectures:package.registeredArchitectures
                versionArchitecture:selection.architecture];
            return CydiaPackageDetailCanPerformAction(selection, current, download.kind);
        };
        prepareSelection = ^(void (^completion)(BOOL)) {
            [database validatePackageSelectionForEra:era completion:^(BOOL current) {
                completion(current && selectionIsCurrent());
            }];
        };
        downloadAction = ^{
            PackageDetailController *self = weakSelf;
            if (!self || !selectionIsCurrent()) return;
            [self.navigationController popToViewController:self animated:YES];
            [self selectModifyAction:download];
        };
    }
    RepositoryAccountsController *controller = [[RepositoryAccountsController alloc]
        initWithSourceURL:[NSURL URLWithString:selection.source.repositoryURLString]
        name:selection.source.name package:selection.baseIdentity ?: selection.identity
        packageName:selection.displayName version:selection.fullVersion architecture:selection.architecture
        downloadAction:downloadAction purchaseURL:CydiaRepositoryPurchaseWebsite(
            [NSURL URLWithString:selection.source.repositoryURLString],
            selection.homepageURLString ? [NSURL URLWithString:selection.homepageURLString] : nil)
        selectionIsCurrent:selectionIsCurrent prepareSelection:prepareSelection];
    controller.downloadEngineUnsupported = !database.repositoryAuthorizedDownloadsSupported;
    [self.navigationController pushViewController:controller animated:YES];
}
@end
