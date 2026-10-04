/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef Cydia_NativeMutationEvidence_H
#define Cydia_NativeMutationEvidence_H

#import <Foundation/Foundation.h>

/* App-owned observation only. No compatibility member or route exposes this
 * interface. The path opt-in grants no mutation authority. JSONL records are
 * bounded, exclusive-created, private, ordered, and synced after each event.
 * A missing/failed/incomplete journal is never evidence of zero effects. */
@interface CydiaNativeMutationEvidence : NSObject
- (instancetype) initWithEnvironment:(NSDictionary *)environment
                       runtimeVersion:(NSString *)runtimeVersion;
- (instancetype) init NS_UNAVAILABLE;
+ (instancetype) new NS_UNAVAILABLE;
@property (nonatomic, readonly, getter=isHealthy) BOOL healthy;
- (NSString *) beginRequestWithSession:(id)session target:(id)target
                            presenter:(id)presenter operation:(NSString *)operation
                           effectKind:(NSString *)effectKind;
- (void) recordEvent:(NSString *)event request:(NSString *)request;
@end

/* UIKit and the host tests use this same one-shot action implementation.
 * YES means the guarded typed provider body returned after its effect/call;
 * NO means authority was rejected before the effect. Persistence, downstream
 * asynchronous transactions, and installed acceptance are not inferred. */
@interface CydiaNativeMutationAction : NSObject
- (instancetype) initWithEvidence:(CydiaNativeMutationEvidence *)evidence
                          request:(NSString *)request
                          execute:(BOOL (^)(void))execute;
- (instancetype) init NS_UNAVAILABLE;
+ (instancetype) new NS_UNAVAILABLE;
- (void) presentationRequested;
- (void) presented;
- (void) presentationRejected;
- (void) accept;
- (void) cancel;
@end

#endif // Cydia_NativeMutationEvidence_H
