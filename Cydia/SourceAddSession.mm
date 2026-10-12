/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#import "Cydia/SourceAddSession.h"
#import "Cydia/SourceFormControls.h"
#import "Cydia/Database.h"
#import "Cydia/FetchDiagnostics.h"
#import "Cydia/Source.h"
#import "Sources.h"
#include "Cydia/AptRuntime.hpp"
#include "Cydia/KeyringImport.hpp"
#include "Cydia/PrivilegedClient.h"
#include <atomic>
#include <cerrno>
#include <memory>
#include <sys/stat.h>

namespace Src = CydiaSources;
namespace Client = CydiaRuntime::PrivilegedClient;
namespace Keys = CydiaRuntime::Keyring;
static NSString *SourceString(const std::string &value) {
    return [[NSString alloc] initWithBytes:value.data() length:value.size() encoding:NSUTF8StringEncoding] ?: @"";
}
static std::string SourceBytes(NSString *value) { return [value UTF8String] ?: ""; }
static std::string Snapshot() {
    const auto result(Client::RunNativeCommand("--cydia-runtime-snapshot", "", 4096, 10000));
    if (!result.succeeded()) return {};
    std::string token(result.output);
    while (!token.empty() && (token.back() == '\n' || token.back() == '\r')) token.pop_back();
    if (token.size() != 64 || token.find_first_not_of("0123456789abcdef") != std::string::npos) return {};
    return token;
}
static BOOL DisableDraft(Src::SourceDraft *draft) {
    if (!draft->raw) { draft->enabled = false; return YES; }
    auto parsed(Src::ParseDocument("draft", draft->format, draft->rawContents));
    if (!parsed.valid()) return NO;
    for (std::size_t count = parsed.definitions.size(); count != 0; --count) {
        Src::Mutation mutation(Src::EditKind::SetEnabled); mutation.ordinal = count - 1; mutation.enabled = false;
        const auto edit(Src::PlanMutation(parsed, parsed.bytes, mutation));
        if (!edit.accepted()) return NO;
        parsed = Src::ParseDocument("draft", draft->format, edit.updated);
    }
    draft->rawContents = parsed.bytes; draft->enabled = false; return YES;
}
static NSString *DraftMessage(const Src::DraftDiagnostic &diagnostic) {
    if (diagnostic.code == "duplicate_source") return CydiaSourceText(@"SOURCE_ADD_DUPLICATE");
    if (diagnostic.code == "conflicting_options") return CydiaSourceText(@"SOURCE_ADD_CONFLICT");
    return CydiaSourceText(@"SOURCE_DEFINITION_INVALID");
}
static BOOL ValidNewFilename(NSString *filename, Src::Format format) {
    if (filename.length == 0 || [filename hasPrefix:@"."] ||
        ![filename hasSuffix:format == Src::Format::Deb822 ? @".sources" : @".list"]) return NO;
    const std::string bytes(SourceBytes(filename));
    if (bytes.empty() || bytes.size() > 255) return NO;
    for (const unsigned char character : bytes)
        if (!((character >= 'a' && character <= 'z') || (character >= 'A' && character <= 'Z') ||
              (character >= '0' && character <= '9') || character == '_' || character == '-' || character == '.')) return NO;
    return YES;
}

@implementation CydiaSourceAddSession {
    Database *database_;
    CydiaSourceDefinition *existing_;
    Src::Access access_;
    Src::SourceDraft draft_;
    CydiaAPT::SourcePreflightResult result_;
    Src::CommitRequest commit_;
    CydiaRuntime::Privileged::Request request_;
    Keys::Input key_;
    Keys::Review keyReview_;
    NSString *provenance_, *message_, *definition_;
    NSArray<NSString *> *fingerprints_;
    std::string snapshot_;
    CydiaAPT::RepositorySecurityMode policy_;
    std::shared_ptr<std::atomic<bool>> cancelled_;
    std::vector<std::string> occupiedBasenames_;
    BOOL filenameEdited_, filenamesLoaded_;
    BOOL busy_, reviewed_, ready_, warning_, disabled_;
}
- (instancetype)initWithDatabase:(Database *)database draft:(const Src::SourceDraft &)draft
                            row:(CydiaSourceDefinition *)row access:(Src::Access)access {
    if ((self = [super init]) != nil) {
        database_ = database; draft_ = draft; existing_ = row; access_ = access;
        _destinationPath = row.filePath; fingerprints_ = @[];
        cancelled_ = std::make_shared<std::atomic<bool>>(false);
        [self refreshSuggestedFilename];
    }
    return self;
}
- (Database *)database { return database_; }
- (CydiaSourceDefinition *)existingSource { return existing_; }
- (Src::SourceDraft &)draft { return draft_; }
- (const CydiaAPT::SourcePreflightResult &)checkResult { return result_; }
- (BOOL)busy { return busy_; }
- (BOOL)reviewed { return reviewed_; }
- (BOOL)ready { return ready_; }
- (BOOL)warning { return warning_; }
- (BOOL)disabled { return disabled_; }
- (NSString *)message { return message_; }
- (NSString *)reviewedDefinition { return definition_ ?: @""; }
- (NSString *)reviewedDestinationPath { return reviewed_ ? SourceString(commit_.expected.document.path) : nil; }
- (NSArray<NSString *> *)fingerprints { return fingerprints_; }
- (NSString *)keyProvenance { return provenance_; }
- (BOOL)hasSelectedKey { return !key_.bytes.empty(); }
- (void)invalidateReview {
    cancelled_->store(true); reviewed_ = ready_ = warning_ = NO; message_ = nil; definition_ = nil;
    snapshot_.clear(); key_.token.clear(); fingerprints_ = @[];
}
- (void)cancel { cancelled_->store(true); }
- (void)setDestinationPath:(NSString *)path {
    if ([_destinationPath isEqual:path]) return;
    _destinationPath = [path copy]; [self invalidateReview];
}
- (void)setSourceFilename:(NSString *)filename {
    filenameEdited_ = YES;
    if ([_sourceFilename isEqual:filename]) return;
    _sourceFilename = [filename copy]; [self invalidateReview];
}
- (void)refreshSuggestedFilename {
    if (existing_ != nil || filenameEdited_) return;
    if (!filenamesLoaded_) {
        filenamesLoaded_ = YES;
        const auto locations(CydiaEffectiveSourceLocations());
        // Include ignored files and directory/symlink entries too: a suggested
        // name is not permission to replace any existing filesystem object.
        if (!locations.partsDirectory.empty() && locations.partsDirectory != "/dev/null")
            for (NSString *filename in [[NSFileManager defaultManager]
                contentsOfDirectoryAtPath:SourceString(locations.partsDirectory) error:nil])
                occupiedBasenames_.push_back(SourceBytes(filename));
    }
    NSString *suggested(SourceString(Src::SuggestedSourceFilename(draft_, occupiedBasenames_)));
    if ([_sourceFilename isEqual:suggested]) return;
    _sourceFilename = suggested; [self invalidateReview];
}
- (void)draftFormatDidChangeFrom:(Src::Format)previous {
    if (filenameEdited_ && ValidNewFilename(_sourceFilename, previous)) {
        _sourceFilename = [[_sourceFilename stringByDeletingPathExtension]
            stringByAppendingPathExtension:draft_.format == Src::Format::Deb822 ? @"sources" : @"list"];
        [self invalidateReview];
    } else [self refreshSuggestedFilename];
}
- (void)selectKey:(NSData *)bytes provenance:(NSString *)provenance package:(NSString *)package path:(NSString *)path {
    [self invalidateReview]; key_ = Keys::Input();
    if (bytes.length != 0 && bytes.length <= Keys::MaximumKeyBytes)
        key_.bytes.assign(static_cast<const char *>(bytes.bytes), bytes.length);
    key_.referencePackage = SourceBytes(package); key_.referencePath = SourceBytes(path); provenance_ = [provenance copy];
}
- (void)clearSelectedKey { [self invalidateReview]; key_ = Keys::Input(); provenance_ = nil; }
- (void)checkDisabled:(BOOL)disabled completion:(void (^)(void))completion {
    if (busy_) return;
    [self invalidateReview]; busy_ = YES;
    cancelled_ = std::make_shared<std::atomic<bool>>(false);
    const auto cancellation(cancelled_); const auto originalDraft(draft_); const auto originalKey(key_);
    NSString *destination([_destinationPath copy]);
    NSString *filename([_sourceFilename copy]);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            Src::SourceDraft draft(originalDraft); Keys::Input key(originalKey);
            // Saving an unverified draft disabled cannot grant new trust.
            if (disabled) key = Keys::Input();
            NSString *message(nil); Src::CommitRequest commit; Keys::Review keyReview;
            CydiaAPT::SourcePreflightResult checked; std::string before;
            CydiaRuntime::Privileged::Request request;
            auto mode(CydiaAPT::RepositorySecurityMode::Warning);
            const BOOL acquired([database_ beginSettingsChange]);
            if (!acquired) message = CydiaSourceText(@"SOURCE_WAIT_FOR_OPERATION");
            else {
                @try { @synchronized(database_) {
                    if (!CydiaCanEditSources(access_)) message = CydiaSourceText(@"SOURCE_PROTECTION_REVIEW_REQUIRED");
                    if (message == nil && disabled && !DisableDraft(&draft)) message = CydiaSourceText(@"SOURCE_DEFINITION_INVALID");
                    const auto store(CydiaReadSourceDocuments()); const auto locations(CydiaEffectiveSourceLocations());
                    std::vector<Src::Document> documents;
                    for (const auto &file : store.documents) {
                        documents.push_back(file.document);
                    }
                    std::string path(SourceBytes(destination));
                    const BOOL newFile(path.empty());
                    if (message == nil && newFile) {
                        if (locations.partsDirectory.empty() || locations.partsDirectory == "/dev/null")
                            message = CydiaSourceText(@"SOURCE_ADD_DESTINATION_REQUIRED");
                        else if (!ValidNewFilename(filename, draft.format))
                            message = CydiaSourceText(@"SOURCE_FILENAME_INVALID");
                        else {
                            std::string directory(locations.partsDirectory);
                            while (!directory.empty() && directory.back() == '/') directory.pop_back();
                            path = directory + '/' + SourceBytes(filename);
                            struct stat occupied;
                            if (lstat(path.c_str(), &occupied) == 0)
                                message = CydiaSourceText(@"SOURCE_FILE_EXISTS");
                            else if (errno != ENOENT) message = CydiaSourceText(@"SOURCE_RELOAD_REQUIRED");
                        }
                    }
                    auto built(Src::BuildSourceDraft(draft, path, documents,
                        existing_ ? SourceBytes(existing_.filePath) : "", existing_ ? existing_.ordinal : std::string::npos));
                    if (message == nil && !built.valid())
                        message = built.diagnostics.empty() ? CydiaSourceText(@"SOURCE_DEFINITION_INVALID") : DraftMessage(built.diagnostics.front());
                    if (message == nil) {
                        commit.access = access_; commit.expectedPolicy = CydiaReadSourceProtection().bytes;
                        commit.expected = Src::NewDocument(path, draft.format);
                        if (!newFile) {
                            for (const auto &file : store.documents) if (file.document.path == path) commit.expected = file;
                            if (!commit.expected.identity.exists) message = CydiaSourceText(@"SOURCE_RELOAD_REQUIRED");
                        }
                        if (existing_) commit.expected = [existing_ snapshot];
                        commit.mutation = Src::Mutation(existing_ ? Src::EditKind::ReplaceDefinition : Src::EditKind::AppendDefinition);
                        commit.mutation.ordinal = existing_ ? existing_.ordinal : 0;
                        commit.mutation.contents = built.document.bytes;
                        if (commit.expected.document.format != built.document.format)
                            message = CydiaSourceText(@"SOURCE_ADD_FORMAT_DESTINATION");
                        else if (!Src::PlanStoredMutation(locations, commit.expected, commit.mutation,
                            CydiaReadSourceProtection().selectors, access_).ready()) message = CydiaSourceText(@"SOURCE_RELOAD_REQUIRED");
                    }
                    if (message == nil) {
                        before = Snapshot(); if (before.empty()) message = CydiaSourceText(@"SOURCE_ENVIRONMENT_UNAVAILABLE");
                    }
                    if (message == nil && !key.bytes.empty()) {
                        key.source = commit; key.token.clear();
                        const auto preview(Client::RunNativeCommand("--cydia-key-preview", Keys::SerializeInput(key)));
                        CydiaRuntime::Privileged::Error error;
                        if (!preview.succeeded() || !Keys::ParseReview(preview.output, &keyReview, &error))
                            message = CydiaSourceText(@"SOURCE_ADD_KEY_REVIEW_FAILED");
                        else { key.source = keyReview.source; key.token = keyReview.token; commit = key.source; }
                    }
                    if (message == nil && !cancellation->load()) {
                        mode = CydiaAPT::GetRepositorySecurityMode();
                        if (disabled) { checked.status = CydiaAPT::SourceCheckStatus::Complete; checked.allowed = true; }
                        else {
                            CydiaAPT::SourcePreflightRequest check;
                            check.definition = commit.mutation.contents; check.format = commit.expected.document.format;
                            check.temporaryParent = SourceBytes(NSTemporaryDirectory());
                            check.candidatePublicKey = key.bytes;
                            // Retain known authentication when editing the same
                            // repository. A fresh private lists directory must
                            // not hide an authenticated-to-unsigned transition.
                            if (existing_) for (Source *source in [database_ sources]) {
                                if (![source trusted]) continue;
                                std::string uri(SourceBytes([source rooturi]));
                                while (!uri.empty() && uri.back() == '/') uri.pop_back();
                                for (const auto &definition : built.document.definitions)
                                    for (auto candidate : definition.uris) {
                                        while (!candidate.empty() && candidate.back() == '/') candidate.pop_back();
                                        if (candidate != uri) continue;
                                        for (const auto &suite : definition.suites)
                                            if (suite == SourceBytes([source distribution])) check.previouslyAuthenticated = true;
                                    }
                            }
                            checked = CydiaAPT::RunSourcePreflight(check, [cancellation]() { return cancellation->load(); });
                        }
                        if (Snapshot() != before) message = CydiaSourceText(@"SOURCE_RELOAD_REQUIRED");
                        request = Client::RuntimeRequest("");
                    }
                } } @finally { [database_ endSettingsChange]; }
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                busy_ = NO;
                if (cancellation->load()) { if (completion) completion(); return; }
                message_ = message; commit_ = commit; request_ = request; key_ = key; keyReview_ = keyReview;
                result_ = checked; snapshot_ = before; policy_ = mode; disabled_ = disabled;
                reviewed_ = message == nil; ready_ = reviewed_ && checked.allowed;
                warning_ = ready_ && !disabled && !checked.authenticated && mode == CydiaAPT::RepositorySecurityMode::Warning;
                definition_ = SourceString(commit.mutation.contents);
                NSMutableArray *fingerprints([NSMutableArray array]);
                for (const auto &fingerprint : keyReview.fingerprints) [fingerprints addObject:SourceString(fingerprint)];
                fingerprints_ = fingerprints;
                if (message_ == nil && !ready_) {
                    for (const auto &failure : checked.failures)
                        if (failure.kind != CydiaAPT::FetchDiagnosticKind::General) { message_ = CydiaFetchDiagnosticMessage(failure); break; }
                    if (message_ == nil && checked.architecture == CydiaAPT::SourceArchitectureAvailability::Unsupported)
                        message_ = CydiaSourceText(@"SOURCE_ADD_NO_COMPATIBLE_PACKAGES");
                    if (message_ == nil && !checked.failures.empty()) message_ = CydiaFetchDiagnosticMessage(checked.failures.front());
                    if (message_.length == 0) message_ = CydiaSourceText(@"SOURCE_ADD_CHECK_FAILED");
                } else if (warning_ && !checked.warnings.empty()) message_ = CydiaFetchDiagnosticMessage(checked.warnings.front());
                if (completion) completion();
            });
        }
    });
}
- (void)commitWithCompletion:(void (^)(BOOL))completion {
    if (busy_ || !ready_ || !reviewed_) return;
    busy_ = YES; const auto commit(commit_); const auto key(key_); const auto originalRequest(request_);
    const auto snapshot(snapshot_); const auto policy(policy_);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            auto request(originalRequest);
            BOOL success(NO); NSString *message(CydiaSourceText(@"SOURCE_WAIT_FOR_OPERATION"));
            const BOOL acquired([database_ beginSettingsChange]);
            if (acquired) {
                @try { @synchronized(database_) {
                    if (CydiaAPT::GetRepositorySecurityMode() != policy || Snapshot() != snapshot)
                        message = CydiaSourceText(@"SOURCE_RELOAD_REQUIRED");
                    else {
                        std::string command;
                        if (!key.bytes.empty()) { command = "--cydia-key-import"; request.payload = Keys::SerializeInput(key); }
                        else {
                            command = commit.access == Src::Access::AdvancedSettings ? "--cydia-source-checked-advanced" : "--cydia-source-checked";
                            request.payload = CydiaRuntime::Privileged::SerializeFields({snapshot, Src::SerializeCommitRequest(commit)});
                        }
                        const auto result(Client::Run(CydiaAPT::PrivilegedHelperPath(), command, request));
                        success = result.succeeded();
                        message = success ? nil : CydiaSourceText(result.exitCode == 75 ? @"SOURCE_RELOAD_REQUIRED" : @"SOURCE_SAVE_FAILED");
                    }
                } } @finally { [database_ endSettingsChange]; }
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                busy_ = NO; message_ = message; ready_ = reviewed_ = warning_ = NO;
                if (completion) completion(success);
            });
        }
    });
}
@end
