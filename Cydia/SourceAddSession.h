/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_SourceAddSession_H
#define Cydia_SourceAddSession_H
#import <Foundation/Foundation.h>
#include "Cydia/SourceDraft.hpp"
#include "Cydia/SourcePreflight.hpp"
@class Database, CydiaSourceDefinition;

/* One native draft, including the exact review which can later be committed.
 * Editing is main-thread-only; workers operate on copied values. */
@interface CydiaSourceAddSession : NSObject
- (instancetype)initWithDatabase:(Database *)database draft:(const CydiaSources::SourceDraft &)draft
                            row:(CydiaSourceDefinition *)row access:(CydiaSources::Access)access;
- (CydiaSources::SourceDraft &)draft;
- (const CydiaAPT::SourcePreflightResult &)checkResult;
@property(nonatomic, readonly) Database *database;
@property(nonatomic, readonly) CydiaSourceDefinition *existingSource;
/* nil selects a new file. An existing path is an explicit append destination. */
@property(nonatomic, copy) NSString *destinationPath;
@property(nonatomic, copy) NSString *sourceFilename;
@property(nonatomic, readonly) NSString *reviewedDestinationPath;
@property(nonatomic, readonly) BOOL busy, reviewed, ready, warning, disabled;
@property(nonatomic, readonly) NSString *message;
@property(nonatomic, readonly) NSString *reviewedDefinition;
@property(nonatomic, readonly) NSArray<NSString *> *fingerprints;
@property(nonatomic, readonly) NSString *keyProvenance;
@property(nonatomic, readonly) BOOL hasSelectedKey;
- (void)selectKey:(NSData *)bytes provenance:(NSString *)provenance
          package:(NSString *)package path:(NSString *)path;
- (void)clearSelectedKey;
/* Updates the automatic suggestion after draft edits, without replacing a
 * manually entered name. Occupied names are cached for the editing session;
 * review and the atomic writer independently recheck the actual destination. */
- (void)refreshSuggestedFilename;
- (void)draftFormatDidChangeFrom:(CydiaSources::Format)previous;
- (void)invalidateReview;
- (void)cancel;
- (void)checkDisabled:(BOOL)disabled completion:(void (^)(void))completion;
- (void)commitWithCompletion:(void (^)(BOOL success))completion;
@end
#endif
