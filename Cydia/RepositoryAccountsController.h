/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#import "CyteKit/ViewController.h"

@interface RepositoryAccountsController : CyteViewController
/* A dependency account returns to the existing transaction review; it never
 * installs that dependency independently or confirms the transaction. */
@property(nonatomic) BOOL returnsToTransactionReview;
@property(nonatomic) BOOL downloadEngineUnsupported;
- (instancetype)init;
- (instancetype)initWithSourceURL:(NSURL *)sourceURL name:(NSString *)name package:(NSString *)package;
/* The caller retains the exact package selection and revalidates it before
 * returning to normal install/review. This is never a direct archive fetch. */
- (instancetype)initWithSourceURL:(NSURL *)sourceURL name:(NSString *)name package:(NSString *)package
                   downloadAction:(void (^)(void))downloadAction purchaseURL:(NSURL *)purchaseURL;
- (instancetype)initWithSourceURL:(NSURL *)sourceURL name:(NSString *)name package:(NSString *)package
                      packageName:(NSString *)packageName version:(NSString *)version architecture:(NSString *)architecture
                   downloadAction:(void (^)(void))downloadAction purchaseURL:(NSURL *)purchaseURL;
- (instancetype)initWithSourceURL:(NSURL *)sourceURL name:(NSString *)name package:(NSString *)package
                      packageName:(NSString *)packageName version:(NSString *)version architecture:(NSString *)architecture
                   downloadAction:(void (^)(void))downloadAction purchaseURL:(NSURL *)purchaseURL
               selectionIsCurrent:(BOOL (^)(void))selectionIsCurrent;
- (instancetype)initWithSourceURL:(NSURL *)sourceURL name:(NSString *)name package:(NSString *)package
                      packageName:(NSString *)packageName version:(NSString *)version architecture:(NSString *)architecture
                   downloadAction:(void (^)(void))downloadAction purchaseURL:(NSURL *)purchaseURL
               selectionIsCurrent:(BOOL (^)(void))selectionIsCurrent
                 prepareSelection:(void (^)(void (^)(BOOL)))prepareSelection;
@end
