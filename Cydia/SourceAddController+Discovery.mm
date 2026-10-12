/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#import "Cydia/SourceAddController_Internal.h"
#import "Cydia/SourceRepositoryOptionsController.h"
#import "Cydia/Database.h"
#include "Cydia/SourceDiscovery.hpp"
#include "Cydia/SourceKeyDiscovery.hpp"
#include <algorithm>
#include <sstream>

namespace {
NSString *Text(const std::string &value) {
    return [[NSString alloc] initWithBytes:value.data() length:value.size() encoding:NSUTF8StringEncoding] ?: @"";
}
std::string Bytes(NSString *value) { return [value UTF8String] ?: ""; }
NSArray<NSString *> *Strings(const std::vector<std::string> &values) {
    NSMutableArray<NSString *> *result([NSMutableArray array]);
    for (const auto &value : values) [result addObject:Text(value)];
    return result;
}
NSArray<NSDictionary *> *PublisherKeys(const CydiaAPT::SourceDiscoveryResult &discovered) {
    NSMutableArray<NSDictionary *> *result([NSMutableArray array]);
    for (const auto &key : discovered.keyLinks) [result addObject:@{@"uri":Text(key.uri), @"label":Text(key.label)}];
    return result;
}
std::string RepositoryURI(const CydiaSources::SourceDraft &draft) {
    if (!draft.raw) return draft.uri;
    const auto document(CydiaSources::ParseDocument("draft", draft.format, draft.rawContents));
    std::string uri;
    if (!document.valid()) return uri;
    for (const auto &definition : document.definitions) for (const auto &candidate : definition.uris) {
        if (!uri.empty() && candidate != uri) return std::string();
        uri = candidate;
    }
    return uri;
}
std::vector<std::string> SigningPaths(const CydiaSources::Document &document) {
    std::vector<std::string> paths;
    for (const auto &definition : document.definitions) for (const auto &field : definition.fields) {
        std::string name(field.name);
        if (document.format == CydiaSources::Format::Deb822)
            for (char &c : name) if (c >= 'A' && c <= 'Z') c += 'a' - 'A';
        if (name != "signed-by" || field.value.find("-----BEGIN PGP") != std::string::npos) continue;
        std::string value(field.value);
        if (document.format == CydiaSources::Format::OneLine) std::replace(value.begin(), value.end(), ',', ' ');
        std::istringstream input(value);
        for (std::string path; input >> path;)
            if (path[0] == '/' && std::find(paths.begin(), paths.end(), path) == paths.end()) paths.push_back(path);
    }
    return paths;
}
NSString *Provenance(const CydiaAPT::SourceSigningKeyCandidate &candidate) {
    using CydiaAPT::SourceKeyProvenance;
    NSString *key;
    switch (candidate.provenance) {
        case SourceKeyProvenance::LocalFile: key = @"SOURCE_ADD_KEY_PROVENANCE_LOCAL"; break;
        case SourceKeyProvenance::InstalledPackage: key = @"SOURCE_ADD_KEY_PROVENANCE_INSTALLED"; break;
        case SourceKeyProvenance::PublisherLink: key = @"SOURCE_ADD_KEY_PROVENANCE_PUBLISHER"; break;
        case SourceKeyProvenance::Keyserver: key = @"SOURCE_ADD_KEY_PROVENANCE_KEYSERVER"; break;
        case SourceKeyProvenance::AvailablePackage: key = @"SOURCE_ADD_KEY_PROVENANCE_AVAILABLE"; break;
    }
    NSMutableArray<NSString *> *parts([NSMutableArray arrayWithObject:CydiaSourceText(key)]);
    if (!candidate.package.empty()) {
        NSString *package(Text(candidate.package));
        if (!candidate.packageVersion.empty()) package = [package stringByAppendingFormat:@" %@", Text(candidate.packageVersion)];
        [parts addObject:package];
    }
    if (!candidate.provenanceURI.empty()) {
        NSURLComponents *URL([NSURLComponents componentsWithString:Text(candidate.provenanceURI)]);
        if (URL.scheme.length) { URL.user = nil; URL.password = nil; URL.query = nil; URL.fragment = nil; }
        [parts addObject:URL.scheme.length ? URL.string ?: @"" : Text(candidate.provenanceURI)];
    } else if (!candidate.referencePath.empty()) [parts addObject:Text(candidate.referencePath)];
    return [parts componentsJoinedByString:@"\n"];
}
}

@interface CydiaSourceAddController (DiscoveryPrivate)
- (void)continueFindSigningKey;
@end

@implementation CydiaSourceAddController (Discovery)
- (void)cancelDiscovery { [self.discoveryProgress cancel]; }

- (void)findOptions {
    if (self.cancelled || self.finding || self.session.busy) return;
    CydiaSources::SourceDraft draft;
    if (![self formFields:&draft]) return;
    const std::string uri(draft.uri);
    NSURL *URL([NSURL URLWithString:Text(uri)]);
    if (![@[@"http", @"https"] containsObject:URL.scheme.lowercaseString] || URL.host.length == 0) return;
    if (uri.empty()) { [self showMessage:CydiaSourceText(@"SOURCE_ADD_DISCOVERY_SINGLE_URI")]; return; }
    NSProgress *progress([NSProgress progressWithTotalUnitCount:1]);
    self.discoveryProgress = progress; self.finding = YES; [self refreshForm];
    self.title = CydiaSourceText(@"SOURCE_ADD_FINDING_OPTIONS");
    Database *database(self.session.database); NSString *temporaryParent(NSTemporaryDirectory());
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            CydiaAPT::SourceDiscoveryResult result; NSString *message(nil);
            const BOOL acquired([database beginSettingsChange]);
            if (!acquired) message = CydiaSourceText(@"SOURCE_WAIT_FOR_OPERATION");
            else {
                @try { @synchronized(database) {
                    result = CydiaAPT::DiscoverSourceOptions(uri, Bytes(temporaryParent), [progress]() { return progress.cancelled; });
                } } @finally { [database endSettingsChange]; }
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self.discoveryProgress != progress) return;
                self.discoveryProgress = nil; self.finding = NO; [self refreshForm];
                if (self.cancelled || progress.cancelled) return;
                if (message != nil) { [self showMessage:message]; return; }
                self.discoveredRepositoryURI = Text(uri); self.discoveredPublisherKeys = PublisherKeys(result);
                if (result.discoveryUnavailable) {
                    [self showMessage:CydiaSourceText(result.status == CydiaAPT::SourceCheckStatus::TimedOut ?
                        @"SOURCE_ADD_DISCOVERY_TIMEOUT" : @"SOURCE_ADD_OPTIONS_UNAVAILABLE")]; return;
                }
                NSMutableArray<NSDictionary *> *options([NSMutableArray array]);
                if (result.flatMetadataAvailable) [options addObject:@{@"suite":@"./", @"components":@[], @"architectures":@[], @"flat":@YES}];
                for (const auto &suite : result.suites) [options addObject:@{@"suite":Text(suite.suitePath),
                    @"components":Strings(suite.components), @"architectures":Strings(suite.architectures), @"flat":@NO}];
                __weak CydiaSourceAddController *weakSelf(self);
                CydiaSourceRepositoryOptionsController *chooser([[CydiaSourceRepositoryOptionsController alloc]
                    initWithOptions:options selectedSuite:Text(draft.distribution) selectedComponents:[NSSet setWithArray:Strings(draft.components)]
                    saved:^(NSString *suite, NSSet<NSString *> *components) {
                        CydiaSourceAddController *owner(weakSelf); if (owner == nil || owner.cancelled) return;
                        CydiaSources::SourceDraft selected;
                        if (![owner formFields:&selected]) return;
                        selected.distribution = Bytes(suite); selected.exactPath = [suite hasSuffix:@"/"]; selected.components.clear();
                        for (NSString *component in [[components allObjects] sortedArrayUsingSelector:@selector(compare:)])
                            selected.components.push_back(Bytes(component));
                        [owner applyFields:selected];
                    }]);
                chooser.delegate = self.delegate;
                [self.navigationController pushViewController:chooser animated:YES];
            });
        }
    });
}

- (void)findSigningKey {
    if (self.cancelled || self.finding || self.session.busy) return;
    if (!self.session.reviewed || [self.session checkResult].repositories.empty()) {
        [self.session checkDisabled:NO completion:^{
            [self refreshForm];
            if (self.cancelled) return;
            if ([self.session checkResult].repositories.empty()) {
                [self showMessage:self.session.message.length ? self.session.message : CydiaSourceText(@"SOURCE_ADD_KEY_METADATA_UNAVAILABLE")];
                return;
            }
            [self continueFindSigningKey];
        }];
        [self refreshForm]; return;
    }
    [self continueFindSigningKey];
}

- (void)continueFindSigningKey {
    if (self.cancelled || self.finding || self.session.busy) return;
    const auto draft([self.session draft]); const auto built(CydiaSources::BuildSourceDraft(draft, "draft"));
    const auto preflight([self.session checkResult]); const std::string uri(RepositoryURI(draft));
    if (!built.valid()) { [self showMessage:CydiaSourceText(@"SOURCE_DEFINITION_INVALID")]; return; }
    if (uri.empty()) { [self showMessage:CydiaSourceText(@"SOURCE_ADD_DISCOVERY_SINGLE_URI")]; return; }
    CydiaAPT::SourceKeyDiscoveryRequest request;
    request.repositoryURI = uri; request.temporaryParent = Bytes(NSTemporaryDirectory());
    request.definition = built.document.bytes; request.format = draft.format; request.sourceKeyringPaths = SigningPaths(built.document);
    const BOOL hadDiscovery([self.discoveredRepositoryURI isEqual:Text(uri)]);
    if (hadDiscovery) for (NSDictionary *key in self.discoveredPublisherKeys)
        request.publisherKeys.push_back({Bytes(key[@"uri"]), Bytes(key[@"label"])});
    NSProgress *progress([NSProgress progressWithTotalUnitCount:1]);
    self.discoveryProgress = progress; self.finding = YES; [self refreshForm];
    self.title = CydiaSourceText(@"SOURCE_ADD_FINDING_KEY");
    Database *database(self.session.database);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            auto lookup(request); CydiaAPT::SourceDiscoveryResult discovered; CydiaAPT::SourceKeyDiscoveryResult result;
            NSString *message(nil); const BOOL acquired([database beginSettingsChange]);
            if (!acquired) message = CydiaSourceText(@"SOURCE_WAIT_FOR_OPERATION");
            else {
                @try { @synchronized(database) {
                    const auto cancelled([progress]() { return progress.cancelled; });
                    if (!hadDiscovery) {
                        discovered = CydiaAPT::DiscoverSourceOptions(uri, lookup.temporaryParent, cancelled);
                        lookup.publisherKeys = discovered.keyLinks;
                    }
                    if (!progress.cancelled) result = CydiaAPT::DiscoverSourceSigningKeys(database, preflight, lookup, cancelled);
                } } @finally { [database endSettingsChange]; }
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self.discoveryProgress != progress) return;
                self.discoveryProgress = nil; self.finding = NO; [self refreshForm];
                if (self.cancelled || progress.cancelled) return;
                if (message != nil) { [self showMessage:message]; return; }
                if (!hadDiscovery) { self.discoveredRepositoryURI = Text(uri); self.discoveredPublisherKeys = PublisherKeys(discovered); }
                if (result.candidates.empty()) {
                    NSString *key(@"SOURCE_ADD_KEY_DISCOVERY_EMPTY");
                    if (result.status == CydiaAPT::SourceKeyDiscoveryStatus::NoSignedMetadata) key = @"SOURCE_ADD_KEY_NO_SIGNATURE";
                    else if (result.status == CydiaAPT::SourceKeyDiscoveryStatus::MetadataUnavailable) key = @"SOURCE_ADD_KEY_METADATA_UNAVAILABLE";
                    else if (result.status == CydiaAPT::SourceKeyDiscoveryStatus::VerifierUnavailable) key = @"SOURCE_ADD_KEY_VERIFIER_UNAVAILABLE";
                    else if (result.status == CydiaAPT::SourceKeyDiscoveryStatus::TimedOut) key = @"SOURCE_ADD_DISCOVERY_TIMEOUT";
                    [self showMessage:CydiaSourceText(key)]; return;
                }
                NSMutableArray<NSDictionary *> *choices([NSMutableArray array]), *candidates([NSMutableArray array]);
                for (const auto &candidate : result.candidates) {
                    NSString *provenance(Provenance(candidate)); NSString *identifier([NSString stringWithFormat:@"%lu", (unsigned long)candidates.count]);
                    NSMutableArray<NSString *> *fingerprints([Strings(candidate.fingerprints) mutableCopy]);
                    for (NSString *signer in Strings(candidate.signerFingerprints)) if (![fingerprints containsObject:signer]) [fingerprints addObject:signer];
                    [choices addObject:@{@"value":identifier, @"title":provenance,
                        @"detail":[NSString stringWithFormat:CydiaSourceText(@"SOURCE_ADD_KEY_FULL_FINGERPRINTS"), [fingerprints componentsJoinedByString:@"\n"]]}];
                    const std::string &bytes(candidate.referencePackage.empty() ? candidate.publicBytes : candidate.referenceBytes);
                    [candidates addObject:@{@"bytes":[NSData dataWithBytes:bytes.data() length:bytes.size()],
                        @"provenance":provenance, @"package":Text(candidate.referencePackage), @"path":Text(candidate.referencePath)}];
                }
                __weak CydiaSourceAddController *weakSelf(self);
                CydiaSourceChoicesController *chooser([[CydiaSourceChoicesController alloc] initWithTitle:CydiaSourceText(@"SOURCE_ADD_MATCHING_KEYS")
                    choices:choices selected:[NSSet set] multiple:NO explanation:CydiaSourceText(@"SOURCE_ADD_MATCHING_KEYS_NOTICE") saved:^(NSSet<NSString *> *values) {
                        CydiaSourceAddController *owner(weakSelf); if (owner == nil || owner.cancelled || values.count != 1) return;
                        NSUInteger index(values.anyObject.integerValue); if (index >= candidates.count) return;
                        NSDictionary *candidate(candidates[index]);
                        [owner.session selectKey:candidate[@"bytes"] provenance:candidate[@"provenance"]
                            package:[candidate[@"package"] length] ? candidate[@"package"] : nil
                            path:[candidate[@"path"] length] ? candidate[@"path"] : nil];
                        [owner changed]; [owner check];
                    }]);
                chooser.delegate = self.delegate; [self.navigationController pushViewController:chooser animated:YES];
            });
        }
    });
}
@end
