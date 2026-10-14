/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_PackageDetailMetadata_H
#define Cydia_PackageDetailMetadata_H

#import <UIKit/UIKit.h>

@class CydiaPackageDetailViewModel;

NS_ASSUME_NONNULL_BEGIN

/* Owning display rows: NSString id/title/detail, plus an optional validated
 * NSString url. No package lookup or modification authority is retained. */
FOUNDATION_EXPORT NSArray<NSDictionary *> *CydiaPackageDetailMetadataRows(
    CydiaPackageDetailViewModel *viewModel);
FOUNDATION_EXPORT UITableViewCell *CydiaPackageDetailMetadataCell(
    UITableView *table, NSDictionary *row, UITraitCollection *traits);

NS_ASSUME_NONNULL_END
#endif
