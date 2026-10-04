/* Cydia Refurbished bounded repository-depiction compatibility facade.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef Cydia_PackageDepictionJavaScriptFacade_H
#define Cydia_PackageDepictionJavaScriptFacade_H

#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>

NS_ASSUME_NONNULL_BEGIN

/* This object is deliberately a data-and-policy boundary, not a general
 * WebKit bridge.  The only values injected into repository HTML are an
 * immutable package/source snapshot and the small read/rendering helper set
 * documented in the migration inventory. */
@interface CydiaPackageDepictionJavaScriptFacade : NSObject <WKScriptMessageHandler>

@property(nonatomic, copy, readonly) NSURL *origin;
@property(nonatomic, copy, readonly) NSString *packageIdentity;
@property(nonatomic, readonly) NSUInteger generation;
@property(nonatomic, readonly, getter=isRevoked) BOOL revoked;
@property(nonatomic, readonly) BOOL lastMessageAccepted;

- (nullable instancetype)initWithSnapshot:(NSDictionary *)snapshot
                                    origin:(NSURL *)origin
                          packageIdentity:(NSString *)packageIdentity
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

/* Must be called before the WKWebView is created.  User scripts are main-frame
 * only; no child frame inherits the facade. */
- (void)installOnConfiguration:(WKWebViewConfiguration *)configuration;
- (void)bindToWebView:(WKWebView *)webView;

/* A reload receives a fresh binding token and generation.  The old script and
 * message handler are removed before the new document is loaded. */
- (void)rotateForReloadOnConfiguration:(WKWebViewConfiguration *)configuration;
- (void)revokeFromConfiguration:(WKWebViewConfiguration *)configuration;

/* Host/simulator tests can exercise the exact generated source without
 * creating a WebKit process. */
+ (nullable NSString *)scriptForSnapshot:(NSDictionary *)snapshot
                                  origin:(NSURL *)origin
                        packageIdentity:(NSString *)packageIdentity
                              generation:(NSUInteger)generation
                           bindingToken:(NSString *)bindingToken;
+ (BOOL)allowlistedReachabilityURL:(NSURL *)URL origin:(NSURL *)origin;

@end

NS_ASSUME_NONNULL_END

#endif // Cydia_PackageDepictionJavaScriptFacade_H
