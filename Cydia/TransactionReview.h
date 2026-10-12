/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_TransactionReview_H
#define Cydia_TransactionReview_H
#import <Foundation/Foundation.h>
#include "Cydia/AptProviderProtocol.hpp"

// Immutable parent-owned value retained by both Database and its confirmation
// controller. Its object identity is the approval token; no worker token alone
// can authorize an operation or replace what the controller displayed.
@interface CydiaTransactionReview : NSObject
@property(nonatomic, copy, readonly) NSArray<NSDictionary<NSString *, NSString *> *> *operations;
@property(nonatomic, copy, readonly) NSArray<NSDictionary<NSString *, NSString *> *> *archiveWarningRows;
@property(nonatomic, copy, readonly) NSString *runtimeNotice;
- (instancetype)initWithTransaction:(const CydiaAPT::TransactionData &)transaction
    providerReview:(const CydiaAPT::Provider::ReviewedTransaction *)providerReview;
- (const CydiaAPT::TransactionData &)transaction;
- (const std::set<std::uint64_t> &)displayedActions;
- (const std::set<std::string> &)displayedArchiveWarnings;
- (bool)matchesTransaction:(const CydiaAPT::TransactionData &)transaction;
@end
#endif
