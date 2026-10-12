/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/SourceDocumentCommit.hpp"
#include <algorithm>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <sys/stat.h>
#include <unistd.h>

using namespace CydiaSources;
namespace {
void Expect(bool value, const char *message) {
    if (!value) { std::cerr << "[source-commit] FAIL: " << message << '\n'; std::exit(1); }
}
struct Fixture {
    std::string directory, main, parts, policy;
    Fixture() {
        char path[] = "/tmp/cydia-source-commit-XXXXXX";
        char *result(mkdtemp(path)); Expect(result != NULL, "private fixture directory");
        directory = result; main = directory + "/main.sources";
        parts = directory + "/parts"; policy = directory + "/source-protection";
        Expect(mkdir(parts.c_str(), 0700) == 0, "fixture sourceparts");
    }
    ~Fixture() {
        unlink(main.c_str()); unlink(policy.c_str()); unlink((parts + "/chosen.list").c_str());
        rmdir(parts.c_str()); rmdir(directory.c_str());
    }
    EffectiveLocations locations() const { return {main, parts}; }
    void write(const std::string &path, const std::string &bytes) {
        std::ofstream out(path.c_str(), std::ios::binary); out << bytes; out.close();
        Expect(out.good(), "write fixture");
    }
};
void Codec() {
    CommitRequest request, decoded;
    request.expected = NewDocument("/fixture/parts/chosen.sources", Format::Deb822);
    request.mutation = Mutation(EditKind::AppendDefinition);
    request.mutation.contents = "Types: deb\nURIs: https://repo.invalid/\nSuites: ./\n";
    const std::string bytes(SerializeCommitRequest(request));
    Expect(ParseCommitRequest(bytes, &decoded) && decoded.expected.document.path == request.expected.document.path &&
        decoded.mutation.contents == request.mutation.contents, "bounded request round trip");
    Expect(!ParseCommitRequest(bytes + "trailing", &decoded), "reject trailing request data");
    Expect(!ParseCommitRequest("CYDIA-SOURCE-COMMIT-1\n99999999999999999999999:x,", &decoded), "reject overflowing length");
    std::vector<ProtectionSelector> selectors;
    Expect(!ParseProtectionPolicy("CYDIA-SOURCE-PROTECTION-1\n1:1,", &selectors), "reject incomplete protection policy");
}
void Commits() {
    Fixture fixture;
    const std::string original("# retain this\nTypes: deb\nURIs: https://bootstrap.invalid/\nSuites: ./\nX-Custom: retained\n");
    fixture.write(fixture.main, original); chmod(fixture.main.c_str(), 0640);
    const StoredDocument visible(ReadDocument(fixture.main, Format::Deb822).documents[0]);
    CommitRequest removal; removal.expected = visible;
    Expect(CommitSourceRequest(fixture.locations(), fixture.policy, removal, getuid()).status == CommitStatus::ProtectionReviewRequired,
        "missing role metadata never silently unprotects repositories");
    CommitRequest review; review.kind = CommitKind::SetProtectionPolicy;
    review.access = Access::AdvancedSettings; review.initializePolicy = true;
    review.selectors.push_back(SelectorForDefinition("bootstrap", visible.document.definitions[0]));
    Expect(CommitSourceRequest(fixture.locations(), fixture.policy, review, getuid()).succeeded(), "explicit bootstrap role review");
    removal.expectedPolicy = ReadProtectionPolicy(fixture.policy, getuid()).bytes;
    Expect(CommitSourceRequest(fixture.locations(), fixture.policy, removal, getuid()).status == CommitStatus::ProtectedDefinition,
        "ordinary source deletion cannot remove a protected stanza");
    CommitRequest add; add.expected = NewDocument(fixture.parts + "/chosen.list", Format::OneLine);
    add.expectedPolicy = removal.expectedPolicy; add.mutation = Mutation(EditKind::AppendDefinition);
    add.mutation.contents = "deb https://user.invalid/ stable main\n";
    Expect(CommitSourceRequest(fixture.locations(), fixture.policy, add, getuid()).succeeded(), "explicit source addition");
    const StoredDocument first(ReadDocument(add.expected.document.path, Format::OneLine).documents[0]);
    CommitRequest edit; edit.expected = first; edit.expectedPolicy = add.expectedPolicy;
    edit.mutation = Mutation(EditKind::SetEnabled); edit.mutation.enabled = false;
    Expect(CommitSourceRequest(fixture.locations(), fixture.policy, edit, getuid()).succeeded(), "lossless source disable");
    Expect(CommitSourceRequest(fixture.locations(), fixture.policy, edit, getuid()).status == CommitStatus::StaleSnapshot,
        "stale preimage cannot overwrite a later source change");
    Expect(ReadDocument(fixture.main, Format::Deb822).documents[0].document.bytes == original,
        "unrelated bootstrap bytes survive ordinary editing");
    removal.access = Access::AdvancedSettings;
    Expect(CommitSourceRequest(fixture.locations(), fixture.policy, removal, getuid()).succeeded(), "advanced protected source removal");
    struct stat st; Expect(stat(fixture.main.c_str(), &st) == 0 && (st.st_mode & 0777) == 0640,
        "atomic edit preserves source ownership and permissions");
    review.expectedPolicy = removal.expectedPolicy; review.selectors.clear(); review.initializePolicy = false;
    Expect(CommitSourceRequest(fixture.locations(), fixture.policy, review, getuid()).succeeded(), "explicit advanced role removal");
    fixture.write(fixture.policy, "broken role policy");
    edit.expected = ReadDocument(add.expected.document.path, Format::OneLine).documents[0];
    edit.expectedPolicy = "broken role policy";
    Expect(CommitSourceRequest(fixture.locations(), fixture.policy, edit, getuid()).status == CommitStatus::ProtectionReviewRequired,
        "malformed role metadata fails closed");
    chmod(fixture.policy.c_str(), 0666);
    Expect(!ReadProtectionPolicy(fixture.policy, getuid()).valid, "untrusted writable policy rejected");
}
bool StopRoleRefresh(void *) { return false; }
void ProtectionRefresh() {
    for (bool interrupt : {false, true}) {
        Fixture fixture;
        const std::string original("Types: deb\nURIs: https://bootstrap.invalid/\nSuites: ./\nX-Custom: retained\n");
        fixture.write(fixture.main, original);
        const StoredDocument visible(ReadDocument(fixture.main, Format::Deb822).documents[0]);
        const auto selector(SelectorForDefinition("bootstrap", visible.document.definitions[0]));
        fixture.write(fixture.policy, SerializeProtectionPolicy({selector}));
        CommitRequest edit; edit.access = Access::AdvancedSettings; edit.expected = visible;
        edit.expectedPolicy = ReadProtectionPolicy(fixture.policy, getuid()).bytes;
        edit.mutation = Mutation(EditKind::ReplaceDefinition);
        edit.mutation.contents = original + "Signed-By: /private/cydia/keyrings/public.gpg\n";
        const auto result(CommitSourceRequestWithProtectionRefresh(fixture.locations(), fixture.policy, edit, getuid(),
            interrupt ? StopRoleRefresh : nullptr));
        const auto fresh(ReadDocument(fixture.main, Format::Deb822).documents[0]);
        Expect(fresh.document.bytes == edit.mutation.contents, "reviewed trust binding survives role refresh interruption");
        const auto policy(ReadProtectionPolicy(fixture.policy, getuid()));
        Expect(policy.valid && policy.selectors.size() == 1 && policy.selectors[0].setIdentifier == "bootstrap", "role identity is preserved");
        CommitRequest ordinary; ordinary.expected = fresh; ordinary.expectedPolicy = policy.bytes;
        const auto removal(CommitSourceRequest(fixture.locations(), fixture.policy, ordinary, getuid()));
        if (interrupt) {
            Expect(result.status == CommitStatus::SourceAppliedPolicyReviewRequired, "distinguish source-applied role-review failure");
            Expect(policy.bytes == edit.expectedPolicy, "interrupted refresh never silently clears old role policy");
            Expect(removal.status == CommitStatus::ProtectionReviewRequired, "ordinary edit fails closed after interrupted role refresh");
        } else {
            Expect(result.succeeded() && policy.selectors[0].semanticKey == fresh.document.definitions[0].semanticKey,
                "successful scoped trust change refreshes only the protected reference");
            Expect(removal.status == CommitStatus::ProtectedDefinition, "new trust binding remains bootstrap-protected");
        }
    }
}
void AdvancedDefinitionActions() {
    Fixture fixture;
    const std::string first("Types: deb\nURIs: https://bootstrap.invalid/ https://mirror.invalid/\nSuites: stable testing\nComponents: main\nX-Custom: retained\n");
    const std::string second("Types: deb\nURIs: https://other.invalid/\nSuites: ./\n");
    fixture.write(fixture.main, first + "\n" + second);
    StoredDocument visible(ReadDocument(fixture.main, Format::Deb822).documents[0]);
    fixture.write(fixture.policy, SerializeProtectionPolicy({
        SelectorForDefinition("bootstrap", visible.document.definitions[0]),
        SelectorForDefinition("system", visible.document.definitions[0]),
        SelectorForDefinition("other", visible.document.definitions[1])}));
    CommitRequest edit; edit.access = Access::AdvancedSettings; edit.expected = visible;
    edit.expectedPolicy = ReadProtectionPolicy(fixture.policy, getuid()).bytes;
    edit.mutation = Mutation(EditKind::SetEnabled); edit.mutation.enabled = false;
    Expect(CommitSourceRequestWithProtectionRefresh(fixture.locations(), fixture.policy, edit, getuid()).succeeded(),
        "advanced whole multi-URI and multi-suite disable preserves protection");
    visible = ReadDocument(fixture.main, Format::Deb822).documents[0];
    const auto disabledPolicy(ReadProtectionPolicy(fixture.policy, getuid()));
    Expect(!visible.document.definitions[0].enabled && disabledPolicy.bytes == edit.expectedPolicy,
        "enabled state does not silently change bootstrap set membership");
    CommitRequest ordinary; ordinary.expected = visible; ordinary.expectedPolicy = disabledPolicy.bytes;
    Expect(CommitSourceRequest(fixture.locations(), fixture.policy, ordinary, getuid()).status == CommitStatus::ProtectedDefinition,
        "disabled bootstrap definition remains protected in ordinary Sources");
    edit.expected = visible; edit.expectedPolicy = disabledPolicy.bytes;
    edit.mutation = Mutation(EditKind::ReplaceDefinition);
    edit.mutation.contents = "Types: deb\nURIs: https://updated.invalid/\nSuites: stable\nComponents: main\nSigned-By: /fixture/keyrings/chosen.gpg\n";
    Expect(CommitSourceRequestWithProtectionRefresh(fixture.locations(), fixture.policy, edit, getuid()).succeeded(),
        "advanced semantic edit updates every role of only the chosen definition");
    visible = ReadDocument(fixture.main, Format::Deb822).documents[0];
    const auto editedPolicy(ReadProtectionPolicy(fixture.policy, getuid()));
    Expect(editedPolicy.selectors.size() == 3 && editedPolicy.selectors[0].setIdentifier == "bootstrap" &&
        editedPolicy.selectors[1].setIdentifier == "system" &&
        editedPolicy.selectors[0].semanticKey == visible.document.definitions[0].semanticKey &&
        editedPolicy.selectors[1].semanticKey == visible.document.definitions[0].semanticKey &&
        editedPolicy.selectors[2].semanticKey == visible.document.definitions[1].semanticKey,
        "role refresh preserves set IDs and unrelated protected stanza");
    edit.expected = visible; edit.expectedPolicy = editedPolicy.bytes;
    edit.mutation = Mutation(EditKind::RemoveDefinition);
    Expect(CommitSourceRequestWithProtectionRefresh(fixture.locations(), fixture.policy, edit, getuid()).succeeded(),
        "advanced delete removes the chosen definition and its exact policy references");
    visible = ReadDocument(fixture.main, Format::Deb822).documents[0];
    const auto removedPolicy(ReadProtectionPolicy(fixture.policy, getuid()));
    Expect(visible.document.definitions.size() == 1 && visible.document.definitions[0].original == second &&
        removedPolicy.selectors.size() == 1 && removedPolicy.selectors[0].setIdentifier == "other" &&
        removedPolicy.selectors[0].semanticKey == visible.document.definitions[0].semanticKey,
        "removal preserves the other actual stanza and its protection");
}
void PairedDefinitionProtection() {
    for (bool reversed : {false, true}) {
        Fixture fixture;
        const std::string path(fixture.parts + "/chosen.list");
        const std::string unrelated("deb https://other.invalid/ ./\n");
        fixture.write(path, unrelated + "deb https://bootstrap.invalid/ stable main\n");
        const StoredDocument visible(ReadDocument(path, Format::OneLine).documents[0]);
        const ProtectionSelector other(SelectorForDefinition("other", visible.document.definitions[0]));
        fixture.write(fixture.policy, SerializeProtectionPolicy({
            other, SelectorForDefinition("bootstrap", visible.document.definitions[1]),
            SelectorForDefinition("system", visible.document.definitions[1])}));
        CommitRequest edit; edit.access = Access::AdvancedSettings; edit.expected = visible;
        edit.expectedPolicy = ReadProtectionPolicy(fixture.policy, getuid()).bytes;
        edit.mutation = Mutation(EditKind::ReplaceDefinition); edit.mutation.ordinal = 1;
        const std::string binary("deb [signed-by=/fixture/keyrings/chosen.gpg] https://updated.invalid/ stable main\n");
        const std::string source("deb-src [signed-by=/fixture/keyrings/chosen.gpg] https://updated.invalid/ stable main\n");
        edit.mutation.contents = reversed ? source + binary : binary + source;
        Expect(CommitSourceRequestWithProtectionRefresh(fixture.locations(), fixture.policy, edit, getuid()).succeeded(),
            "protected source can become a binary/source pair in either order");
        const StoredDocument fresh(ReadDocument(path, Format::OneLine).documents[0]);
        const auto policy(ReadProtectionPolicy(fixture.policy, getuid()));
        Expect(fresh.document.bytes == unrelated + edit.mutation.contents && policy.valid && policy.selectors.size() == 5,
            "pair replacement preserves exact bytes and expands every original role");
        Expect(policy.selectors[0].setIdentifier == other.setIdentifier &&
            policy.selectors[0].semanticKey == other.semanticKey && policy.selectors[0].uris == other.uris &&
            policy.selectors[0].originPath == other.originPath,
            "pair replacement leaves unrelated protection unchanged");
        for (std::size_t ordinal(1); ordinal != 3; ++ordinal) {
            const ProtectionResult protection(EvaluateProtection({fresh.document}, policy.selectors, path, ordinal));
            Expect(protection.state == ProtectionState::Protected && protection.sets.size() == 2 &&
                std::find(protection.sets.begin(), protection.sets.end(), "bootstrap") != protection.sets.end() &&
                std::find(protection.sets.begin(), protection.sets.end(), "system") != protection.sets.end(),
                "both pair members retain all protected role IDs");
            CommitRequest ordinary; ordinary.expected = fresh; ordinary.expectedPolicy = policy.bytes;
            ordinary.mutation.ordinal = ordinal;
            Expect(CommitSourceRequest(fixture.locations(), fixture.policy, ordinary, getuid()).status == CommitStatus::ProtectedDefinition,
                "ordinary removal cannot delete either protected pair member");
        }
        Expect(ReadDocument(path, Format::OneLine).documents[0].document.bytes == fresh.document.bytes,
            "blocked ordinary pair removals do not modify the source file");
    }
}
void InterruptedRemovalAndAmbiguity() {
    for (bool duplicate : {false, true}) {
        Fixture fixture;
        const std::string source("Types: deb\nURIs: https://bootstrap.invalid/\nSuites: ./\n");
        fixture.write(fixture.main, source + (duplicate ? "\n" + source : ""));
        const StoredDocument visible(ReadDocument(fixture.main, Format::Deb822).documents[0]);
        fixture.write(fixture.policy, SerializeProtectionPolicy({SelectorForDefinition("bootstrap", visible.document.definitions[0])}));
        CommitRequest edit; edit.access = Access::AdvancedSettings; edit.expected = visible;
        edit.expectedPolicy = ReadProtectionPolicy(fixture.policy, getuid()).bytes;
        const auto result(CommitSourceRequestWithProtectionRefresh(fixture.locations(), fixture.policy, edit, getuid(), StopRoleRefresh));
        const auto fresh(ReadDocument(fixture.main, Format::Deb822).documents[0]);
        Expect(ReadProtectionPolicy(fixture.policy, getuid()).bytes == edit.expectedPolicy,
            "unsuccessful role update retains reviewed old policy");
        if (duplicate) {
            Expect(result.status == CommitStatus::ProtectionReviewRequired && fresh.document.bytes == visible.document.bytes,
                "ambiguous protected selector denies advanced source deletion before any write");
        } else {
            Expect(result.status == CommitStatus::SourceAppliedPolicyReviewRequired && fresh.document.definitions.empty(),
                "interrupted deletion distinguishes changed source from failed role update");
            CommitRequest add; add.expected = NewDocument(fixture.parts + "/chosen.list", Format::OneLine);
            add.expectedPolicy = edit.expectedPolicy; add.mutation = Mutation(EditKind::AppendDefinition);
            add.mutation.contents = "deb https://user.invalid/ ./\n";
            Expect(CommitSourceRequest(fixture.locations(), fixture.policy, add, getuid()).status == CommitStatus::ProtectionReviewRequired,
                "ordinary edits stay blocked after interrupted protected removal");
        }
    }
}
}
int main() { Codec(); Commits(); ProtectionRefresh(); AdvancedDefinitionActions(); PairedDefinitionProtection(); InterruptedRemovalAndAmbiguity(); std::cout << "[source-commit] PASS\n"; }
