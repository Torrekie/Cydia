/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#import "Cydia/PackageDetailController.h"

@interface PackageDetailController (RepositoryAccounts)
- (void)showRepositoryAccount;
@end

/* The account route returns through the ordinary package action dispatcher. */
@interface PackageDetailController (PackageActions)
- (void)selectModifyAction:(CydiaPackageDetailModifyAction *)action;
@end
