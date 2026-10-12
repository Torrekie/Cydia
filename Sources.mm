/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#import "Sources.h"
#import "Cydia/AptRuntime.hpp"
#import "Cydia/PackageDatabasePaths.hpp"
#import "Cydia/PrivilegedClient.h"
#include <algorithm>

NSString *Cache_;
static bool LastMutationSucceeded_ = true;
static NSString *SourceText(const std::string &value) {
    return [[NSString alloc] initWithBytes:value.data() length:value.size() encoding:NSUTF8StringEncoding] ?:
        [[NSString alloc] initWithBytes:value.data() length:value.size() encoding:NSISOLatin1StringEncoding];
}
static NSArray *SourceWords(const std::vector<std::string> &values) {
    NSMutableArray *result([NSMutableArray arrayWithCapacity:values.size()]);
    for (const auto &value : values) [result addObject:SourceText(value) ?: @""];
    return result;
}
NSString *Cache(const char *file) { return [NSString stringWithFormat:@"%@/%s", Cache_, file]; }
static NSString *SourceMessage(NSString *key) {
    return [[NSBundle mainBundle] localizedStringForKey:key value:key table:@"Sources"];
}
static bool SourceFailure(NSError **error, NSString *key, NSInteger code = 1) {
    if (error != nullptr) *error = [NSError errorWithDomain:@"CydiaSources" code:code
        userInfo:@{NSLocalizedDescriptionKey:SourceMessage(key)}];
    LastMutationSucceeded_ = false;
    return false;
}

@implementation CydiaSourceDefinition
- (instancetype)initWithSnapshot:(const CydiaSources::StoredDocument &)snapshot ordinal:(NSUInteger)ordinal {
    if ((self = [super init]) != nil) { snapshot_ = snapshot; ordinal_ = ordinal; }
    return self;
}
- (const CydiaSources::StoredDocument &)snapshot { return snapshot_; }
- (const CydiaSources::Definition &)definition { return snapshot_.document.definitions.at(ordinal_); }
- (NSString *)filePath { return SourceText(snapshot_.document.path); }
- (NSUInteger)ordinal { return ordinal_; }
- (NSUInteger)lineNumber {
    return 1 + std::count(snapshot_.document.bytes.begin(),
        snapshot_.document.bytes.begin() + [self definition].span.begin, '\n');
}
- (BOOL)enabled { return [self definition].enabled; }
- (NSString *)original { return SourceText([self definition].original); }
- (NSArray *)uris { return SourceWords([self definition].uris); }
- (NSArray *)suites { return SourceWords([self definition].suites); }
- (NSArray *)components { return SourceWords([self definition].components); }
- (NSArray *)types { return SourceWords([self definition].types); }
@end

CydiaSources::EffectiveLocations CydiaEffectiveSourceLocations() {
    return {CydiaAPT::SourceListPath(), CydiaAPT::SourcePartsDirectory()};
}
CydiaSources::StoreSnapshot CydiaReadSourceDocuments() {
    return CydiaSources::ReadEffectiveDocuments(CydiaEffectiveSourceLocations());
}
CydiaSources::PolicySnapshot CydiaReadSourceProtection() {
    return CydiaSources::ReadProtectionPolicy(CydiaRuntime::PackageDatabasePaths::Current().CydiaStateDirectory() + "/source-protection");
}
NSArray<CydiaSourceDefinition *> *CydiaReadSourceDefinitions(NSArray<NSString *> **diagnostics) {
    const auto snapshot(CydiaReadSourceDocuments());
    NSMutableArray *rows([NSMutableArray array]);
    NSMutableArray *messages([NSMutableArray array]);
    for (const auto &document : snapshot.documents)
        for (std::size_t ordinal = 0; ordinal < document.document.definitions.size(); ++ordinal)
            [rows addObject:[[CydiaSourceDefinition alloc] initWithSnapshot:document ordinal:ordinal]];
    for (const auto &diagnostic : snapshot.diagnostics)
        [messages addObject:[NSString stringWithFormat:@"%@\n%@", SourceText(diagnostic.path), SourceMessage(@"SOURCE_FILE_UNAVAILABLE")]];
    if (diagnostics != nullptr) *diagnostics = messages;
    return rows;
}
static std::vector<CydiaSources::Document> SourceDocuments(const CydiaSources::StoreSnapshot &snapshot) {
    std::vector<CydiaSources::Document> result;
    for (const auto &stored : snapshot.documents) result.push_back(stored.document);
    return result;
}
bool CydiaCanEditSources(CydiaSources::Access access) {
    const auto policy(CydiaReadSourceProtection());
    const auto snapshot(CydiaReadSourceDocuments());
    if (!CydiaAPT::MutationEnvironmentValid() || !policy.valid || !snapshot.ready()) return false;
    return access == CydiaSources::Access::AdvancedSettings ||
        CydiaSources::EvaluateProtection(SourceDocuments(snapshot), policy.selectors, "", 0).state !=
        CydiaSources::ProtectionState::ReviewRequired;
}
bool CydiaSourceDefinitionCanEdit(CydiaSourceDefinition *row, CydiaSources::Access access) {
    if (row == nil || !CydiaCanEditSources(access)) return false;
    CydiaSources::Mutation mutation(CydiaSources::EditKind::SetEnabled);
    mutation.ordinal = row.ordinal; mutation.enabled = row.enabled;
    return CydiaSources::PlanStoredMutation(CydiaEffectiveSourceLocations(), [row snapshot], mutation,
        CydiaReadSourceProtection().selectors, access).ready();
}
NSIndexSet *CydiaReadSourceDisplayEditability(NSArray<CydiaSourceDefinition *> *rows, CydiaSources::Access access) {
    NSMutableIndexSet *editable([NSMutableIndexSet indexSet]);
    if (rows.count == 0 || !CydiaAPT::MutationEnvironmentValid()) return editable;
    const auto policy(CydiaReadSourceProtection());
    const auto snapshot(CydiaReadSourceDocuments());
    if (!policy.valid || !snapshot.ready()) return editable;
    const auto documents(SourceDocuments(snapshot));
    if (access == CydiaSources::Access::Ordinary &&
        CydiaSources::EvaluateProtection(documents, policy.selectors, "", 0).state ==
            CydiaSources::ProtectionState::ReviewRequired) return editable;
    for (NSUInteger index = 0; index != rows.count; ++index) {
        CydiaSourceDefinition *row(rows[index]);
        const auto &expected([row snapshot]);
        for (const auto &current : snapshot.documents) {
            if (current.document.path != expected.document.path) continue;
            if (current.readOnly || current.identity.links != 1 ||
                !expected.identity.sameVersion(current.identity) ||
                expected.canonicalPath != current.canonicalPath ||
                expected.document.bytes != current.document.bytes) break;
            CydiaSources::Mutation mutation(CydiaSources::EditKind::SetEnabled);
            mutation.ordinal = row.ordinal; mutation.enabled = row.enabled;
            if (CydiaSources::PlanMutation(expected.document, current.document.bytes, mutation,
                documents, policy.selectors, access).accepted()) [editable addIndex:index];
            break;
        }
    }
    return editable;
}
NSArray<CydiaSourceDefinition *> *CydiaSourceDefinitionsForKey(NSString *key) {
    NSMutableArray *matches([NSMutableArray array]);
    for (CydiaSourceDefinition *row in CydiaReadSourceDefinitions())
        for (NSString *type in row.types)
            for (NSString *uri in row.uris)
                for (NSString *suite in row.suites)
                    if ([[NSString stringWithFormat:@"%@:%@:%@", type, uri, suite] isEqual:key]) {
                        if (![matches containsObject:row]) [matches addObject:row];
                    }
    return matches;
}
bool CydiaCommitSourceMutation(const CydiaSources::StoredDocument &expected,
                              const CydiaSources::Mutation &mutation, NSError **error, CydiaSources::Access access) {
    const auto policy(CydiaReadSourceProtection());
    if (!policy.valid) return SourceFailure(error, @"SOURCE_PROTECTION_REVIEW_REQUIRED");
    if (!CydiaAPT::MutationEnvironmentValid()) return SourceFailure(error, @"SOURCE_ENVIRONMENT_UNAVAILABLE");
    const auto plan(CydiaSources::PlanStoredMutation(CydiaEffectiveSourceLocations(), expected, mutation, policy.selectors, access));
    if (!plan.ready()) {
        switch (plan.edit.status) {
            case CydiaSources::EditStatus::ProtectedDefinition: return SourceFailure(error, @"SOURCE_PROTECTED");
            case CydiaSources::EditStatus::ProtectionReviewRequired: return SourceFailure(error, @"SOURCE_PROTECTION_REVIEW_REQUIRED");
            case CydiaSources::EditStatus::InvalidMutation: return SourceFailure(error, @"SOURCE_DEFINITION_INVALID");
            default: return SourceFailure(error, @"SOURCE_RELOAD_REQUIRED");
        }
    }
    CydiaSources::CommitRequest request;
    request.expected = expected; request.mutation = mutation; request.expectedPolicy = policy.bytes;
    request.access = access;
    const auto result(CydiaRuntime::PrivilegedClient::RunNativeCommand(
        access == CydiaSources::Access::AdvancedSettings ? "--cydia-source-advanced" : "--cydia-source",
        CydiaSources::SerializeCommitRequest(request)));
    if (!result.succeeded()) return SourceFailure(error, result.exitCode == 75 ? @"SOURCE_RELOAD_REQUIRED" :
        result.exitCode == 74 ? @"SOURCE_POLICY_SAVE_INCOMPLETE" : @"SOURCE_SAVE_FAILED", result.exitCode);
    LastMutationSucceeded_ = true;
    return true;
}
NSString *CydiaSourceDraftForLegacySource(NSDictionary *source) {
    if (![source isKindOfClass:[NSDictionary class]]) return nil;
    NSString *type(source[@"Type"]), *uri(source[@"URI"]), *suite(source[@"Distribution"]);
    NSArray *components(source[@"Sections"] ?: @[]);
    if (![type isKindOfClass:[NSString class]] || ![uri isKindOfClass:[NSString class]] ||
        ![suite isKindOfClass:[NSString class]] || ![components isKindOfClass:[NSArray class]]) return nil;
    for (id item in components) if (![item isKindOfClass:[NSString class]]) return nil;
    NSString *text([NSString stringWithFormat:@"%@ %@ %@%@%@\n", type, uri, suite,
        components.count == 0 ? @"" : @" ", [components componentsJoinedByString:@" "]]);
    const auto parsed(CydiaSources::ParseDocument("/draft.list", CydiaSources::Format::OneLine, [text UTF8String] ?: ""));
    return parsed.valid() && parsed.definitions.size() == 1 ? text : nil;
}

// Compatibility calls never reconstruct or flush a source model. Commits
// already target explicit, reviewed actual APT file bytes.
bool CydiaWriteSources() { const bool result(LastMutationSucceeded_); LastMutationSucceeded_ = true; return result; }
void CydiaSetManagedSourceListPath(NSString *) {}
NSString *CydiaManagedSourceListPath() { return nil; }
bool CydiaHasManagedSourceListPath() { return CydiaCanEditSources(); }
bool CydiaCanEditManagedSources() { return CydiaCanEditSources(); }
bool CydiaManagedSourceKeyIsOwned(NSString *key) {
    NSArray *rows(CydiaSourceDefinitionsForKey(key));
    return rows.count == 1 && CydiaSourceDefinitionCanEdit(rows.firstObject);
}
bool CydiaUpdateSourceSection(NSString *key, NSString *section, bool add) {
    NSArray *rows(CydiaSourceDefinitionsForKey(key));
    if (rows.count != 1 || ![section isKindOfClass:[NSString class]]) return false;
    CydiaSourceDefinition *row(rows.firstObject);
    auto components([row definition].components);
    const std::string component([section UTF8String] ?: "");
    const auto found(std::find(components.begin(), components.end(), component));
    if (add && found == components.end()) components.push_back(component);
    else if (!add && found != components.end()) components.erase(found);
    else return CydiaSourceDefinitionCanEdit(row);
    std::string replacement;
    if (!CydiaSources::SourceWithComponents([row snapshot].document, row.ordinal, components, &replacement)) return false;
    CydiaSources::Mutation mutation(CydiaSources::EditKind::ReplaceDefinition);
    mutation.ordinal = row.ordinal; mutation.contents = replacement;
    return CydiaCommitSourceMutation([row snapshot], mutation);
}
void CydiaRemoveSource(NSString *key) {
    NSArray *rows(CydiaSourceDefinitionsForKey(key));
    if (rows.count != 1) { LastMutationSucceeded_ = false; return; }
    CydiaSourceDefinition *row(rows.firstObject);
    CydiaSources::Mutation mutation(CydiaSources::EditKind::RemoveDefinition); mutation.ordinal = row.ordinal;
    CydiaCommitSourceMutation([row snapshot], mutation);
}
void CydiaAddSource(NSDictionary *source) {
    NSString *draft(CydiaSourceDraftForLegacySource(source));
    NSString *path(source[@"SourceFile"]);
    if (draft == nil || ![path isKindOfClass:[NSString class]]) { LastMutationSucceeded_ = false; return; }
    const std::string destination([path fileSystemRepresentation] ?: "");
    const auto snapshot(CydiaSources::ReadDocument(destination, CydiaSources::Format::OneLine));
    CydiaSources::StoredDocument expected(snapshot.documents.empty() ?
        CydiaSources::NewDocument(destination, CydiaSources::Format::OneLine) : snapshot.documents.front());
    CydiaSources::Mutation mutation(CydiaSources::EditKind::AppendDefinition); mutation.contents = [draft UTF8String] ?: "";
    CydiaCommitSourceMutation(expected, mutation);
}
void CydiaAddSource(NSString *href, NSString *distribution, NSArray *sections) {
    CydiaAddSource(@{@"Type":@"deb", @"URI":href ?: @"", @"Distribution":distribution ?: @"", @"Sections":sections ?: @[]});
}
