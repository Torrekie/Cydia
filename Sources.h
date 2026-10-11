/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Sources_H
#define Sources_H
#import <Foundation/Foundation.h>
#include "Cydia/SourceDocumentCommit.hpp"

@interface CydiaSourceDefinition : NSObject {
    CydiaSources::StoredDocument snapshot_;
    NSUInteger ordinal_;
}
- (instancetype)initWithSnapshot:(const CydiaSources::StoredDocument &)snapshot ordinal:(NSUInteger)ordinal;
- (const CydiaSources::StoredDocument &)snapshot;
- (const CydiaSources::Definition &)definition;
@property(nonatomic, readonly) NSString *filePath;
@property(nonatomic, readonly) NSUInteger ordinal;
@property(nonatomic, readonly) NSUInteger lineNumber;
@property(nonatomic, readonly) BOOL enabled;
@property(nonatomic, readonly) NSString *original;
@property(nonatomic, readonly) NSArray<NSString *> *uris;
@property(nonatomic, readonly) NSArray<NSString *> *suites;
@property(nonatomic, readonly) NSArray<NSString *> *components;
@property(nonatomic, readonly) NSArray<NSString *> *types;
@end

CydiaSources::EffectiveLocations CydiaEffectiveSourceLocations();
CydiaSources::StoreSnapshot CydiaReadSourceDocuments();
CydiaSources::PolicySnapshot CydiaReadSourceProtection();
NSArray<CydiaSourceDefinition *> *CydiaReadSourceDefinitions(NSArray<NSString *> **diagnostics = nullptr);
NSArray<CydiaSourceDefinition *> *CydiaSourceDefinitionsForKey(NSString *key);
bool CydiaCanEditSources(CydiaSources::Access access = CydiaSources::Access::Ordinary);
bool CydiaSourceDefinitionCanEdit(CydiaSourceDefinition *definition,
    CydiaSources::Access access = CydiaSources::Access::Ordinary);
bool CydiaCommitSourceMutation(const CydiaSources::StoredDocument &expected,
    const CydiaSources::Mutation &mutation, NSError **error = nullptr,
    CydiaSources::Access access = CydiaSources::Access::Ordinary);
NSString *CydiaSourceDraftForLegacySource(NSDictionary *source);

/* Compatibility spellings: actual APT documents and separately root-owned
 * role policy are authoritative. No private plist or marker grants ownership. */
bool CydiaWriteSources();
void CydiaSetManagedSourceListPath(NSString *path);
NSString *CydiaManagedSourceListPath();
bool CydiaCanEditManagedSources();
bool CydiaHasManagedSourceListPath();
bool CydiaManagedSourceKeyIsOwned(NSString *key);
bool CydiaUpdateSourceSection(NSString *key, NSString *section, bool add);
void CydiaRemoveSource(NSString *key);
void CydiaAddSource(NSDictionary *source);
void CydiaAddSource(NSString *href, NSString *distribution, NSArray *sections = nil);

extern NSString *Cache_;
NSString *Cache(const char *file);
#endif
