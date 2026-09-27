/* Cydia Refurbished native error presentation.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef Cydia_ErrorViewController_H
#define Cydia_ErrorViewController_H

#import "Cydia/ErrorViewModel.h"
#import "CyteKit/ViewController.h"

NS_ASSUME_NONNULL_BEGIN

@class ErrorViewController;

@protocol ErrorViewControllerDelegate <NSObject>
- (void)errorViewControllerDidRequestRetry:(ErrorViewController *)controller;
@end

/* Reusable opaque UIKit failure surface. The owning loader retains and retries
 * the original request; this controller receives only a sanitized snapshot. */
@interface ErrorViewController : CyteViewController

@property(nonatomic, strong, readonly) CydiaErrorViewModel *viewModel;
@property(nonatomic, readonly, getter=isDetailsVisible) BOOL detailsVisible;
@property(nonatomic, readonly, getter=isRetryAvailable) BOOL retryAvailable;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
- (instancetype)initWithViewModel:(CydiaErrorViewModel *)viewModel
                   retryAvailable:(BOOL)retryAvailable
                          delegate:(nullable id<ErrorViewControllerDelegate>)delegate;

- (void)retryButtonClicked;
- (void)detailsButtonClicked;

@end

NS_ASSUME_NONNULL_END

#endif // Cydia_ErrorViewController_H
