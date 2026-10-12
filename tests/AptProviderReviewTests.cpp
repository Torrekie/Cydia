/* Parent review policy uses synthetic parent evidence; it does not claim file
 * verification, privileged launch or real provider acceptance.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderReview.hpp"
#include <cstdlib>
#include <iostream>

namespace {
using namespace CydiaAPT;
namespace P = CydiaAPT::Provider;
void Require(bool value, const char *message) {
    if (value) return;
    std::cerr << "[apt-provider-review][FAIL] " << message << '\n'; std::exit(1);
}
P::ReviewedAction Action(std::uint64_t identifier, P::ExecutionAction kind,
                         const P::ExecutionPackage &package, const std::string &archive = "") {
    P::ReviewedAction action;
    action.identifier = identifier; action.action = kind;
    action.package = package; action.archive = archive;
    return action;
}
struct Fixture {
    P::ReviewedTransaction review;
    P::ReviewPolicy policy;
    Fixture() {
        auto &environment = policy.environment;
        environment.paths.dpkg = "/usr/bin/dpkg";
        environment.paths.dpkgQuery = "/usr/bin/dpkg-query";
        environment.paths.dpkgDeb = "/usr/bin/dpkg-deb";
        environment.paths.dpkgRoot = "/";
        environment.paths.dpkgAdmin = "/var/lib/dpkg";
        environment.configurationIdentity = "config-v1";
        environment.policyIdentity = "policy-v1";
        environment.methodsIdentity = "methods-v1";
        environment.packageStateIdentity = "state-v1";
        environment.nativeArchitecture = "amd64";
        environment.registeredArchitectures = {"amd64", "i386"};
        environment.acquisitionArchitectures = environment.registeredArchitectures;
        policy.layout = {"/", {"/var/jb"}};
        policy.protectedDpkgOptions = {"--root=/", "--admindir=/var/lib/dpkg", "--force-confold"};
        auto &binding = review.binding;
        binding.providerIdentifier = "provider"; binding.session = std::string(64, 'a');
        binding.configurationIdentity = environment.configurationIdentity;
        binding.policyIdentity = environment.policyIdentity;
        binding.packageStateIdentity = environment.packageStateIdentity;
        binding.cacheEpoch = 1; binding.selectionRevision = 2; binding.review = "review-v1";
        review.transaction.registeredArchitectures = environment.registeredArchitectures;
        AddInstall("alpha", "amd64", "amd64", 1, "alpha-native");
        AddInstall("alpha", "i386", "i386", 3, "alpha-foreign");
        AddInstall("portable", "amd64", "all", 5, "portable");
        AddRemoval("old", false, 7);
        AddRemoval("residual", true, 8);
        review.execution.actions.push_back(Action(10, P::ExecutionAction::Triggers, {"triggered", "2", "amd64"}));
        review.execution.actions.push_back(Action(11, P::ExecutionAction::Configure, {"pending", "1", "amd64"}));
        policy.additionalActionsReviewed = {10, 11};
    }
    void AddInstall(const std::string &name, const std::string &bucket, const std::string &arch,
                    std::uint64_t id, const std::string &archiveID) {
        const auto identity = BuildPackageIdentity(name, bucket, arch, "amd64",
            arch == "all" ? MultiArchMode::None : MultiArchMode::Same);
        review.transaction.installs.push_back(identity.routingName);
        review.transaction.packages[identity.routingName] = {identity, "1", name};
        P::ArchiveManifest archive;
        archive.identifier = archiveID; archive.package = {name, "1", arch};
        archive.sourceURI = "https://repository.invalid/"; archive.sourceIndexIdentity = "SHA256:" + std::string(64, 'a');
        archive.sourceDefinitionPath = "/etc/apt/sources.list.d/example.sources";
        archive.sourceIndexPath = "/var/lib/apt/lists/repository.invalid_Packages";
        archive.sourceIndexURI = "https://repository.invalid/Packages";
        archive.filename = "pool/" + archiveID + ".deb"; archive.recordOffset = id * 1024; archive.recordSize = 512;
        archive.path = "/cache/" + archiveID + ".deb"; archive.hashes = {{"SHA256", std::string(64, '1')}};
        archive.size = 4096; archive.layout = policy.layout;
        review.execution.archives.push_back(archive);
        review.execution.actions.push_back(Action(id, P::ExecutionAction::Unpack, archive.package, archiveID));
        review.execution.actions.push_back(Action(id + 1, P::ExecutionAction::Configure, archive.package));
    }
    void AddRemoval(const std::string &name, bool purge, std::uint64_t id) {
        auto identity = BuildPackageIdentity(name, "amd64", "amd64", "amd64", MultiArchMode::None);
        (purge ? review.transaction.purges : review.transaction.removes).push_back(name);
        review.transaction.packages[name] = {identity, "1", name};
        review.execution.actions.push_back(Action(id, P::ExecutionAction::Remove, {name, "1", "amd64"}));
        if (purge) review.execution.actions.push_back(Action(id + 1, P::ExecutionAction::Purge, {name, "1", "amd64"}));
    }
    P::ParentExecutionRequest Request(P::ExecutionAction action, std::vector<std::uint64_t> actions,
                                     const std::vector<std::string> &tail, bool noTriggers = true) const {
        P::ParentExecutionRequest request;
        request.binding = review.binding; request.batch = 1; request.action = action; request.actions = actions;
        request.arguments = policy.protectedDpkgOptions;
        request.arguments.insert(request.arguments.end(), {"--status-fd", "99"});
        if (noTriggers) request.arguments.push_back("--no-triggers");
        request.arguments.insert(request.arguments.end(), tail.begin(), tail.end());
        return request;
    }
    P::ParentExecutionEvidence Evidence() const {
        P::ParentExecutionEvidence evidence;
        evidence.binding = review.binding; evidence.frontendLockHeld = true; evidence.stateVerified = true;
        evidence.stateIdentity = review.binding.packageStateIdentity; evidence.statusDescriptor = 8;
        evidence.deconfigurationTargetsKnown = evidence.triggerTargetsKnown = true;
        return evidence;
    }
    P::ParentExecutionEvidence ArchiveEvidence() const {
        auto evidence = Evidence();
        for (const auto &archive : review.execution.archives) {
            P::VerifiedArchiveEvidence verified; verified.archive = archive;
            verified.fileIdentity = "parent-open-file:" + archive.identifier;
            verified.inspection.status = CydiaPackages::ArchivePolicyStatus::Accepted;
            verified.inspection.identityVerified = verified.inspection.complete = true;
            evidence.archives.push_back(verified);
        }
        return evidence;
    }
};
P::ParentExecutionReply Success() {
    P::ParentExecutionReply result; result.started = true; result.exitCode = 0; return result;
}
void ReviewAndWire() {
    Fixture fixture; P::ReviewAuthorization authorization; std::string error, bytes;
    Require(P::ProtocolVersion == 3 && (P::RequiredCapabilities & P::ReviewedExecutionManifest), "unnegotiated execution manifest");
    Require(P::Encode(fixture.review, &bytes), "manifest encoding");
    P::ReviewedTransaction decoded;
    Require(P::Decode(bytes, &decoded) && decoded.execution.archives.size() == 3 &&
        decoded.execution.actions[2].package.architecture == "i386" &&
        decoded.execution.archives[2].package.architecture == "all", "manifest lost concrete package architecture");
    Require(authorization.Accept(decoded, fixture.policy, &error), "complete parent-approved review refused");
    for (unsigned variant = 0; variant != 16; ++variant) {
        auto review = fixture.review; auto policy = fixture.policy;
        switch (variant) {
            case 0: review.execution.archives.front().hashes = {{"SHA1", std::string(40, '1')}}; break;
            case 1: review.execution.archives.front().size = 0; break;
            case 2: review.execution.archives.front().path = "/cache/../different.deb"; break;
            case 3: review.execution.archives.front().layout.prefix = "/var/jb"; break;
            case 4: review.execution.actions.push_back(review.execution.actions.front()); break;
            case 5: policy.additionalActionsReviewed.erase(10); break;
            case 6: review.execution.actions.erase(review.execution.actions.begin() + 1); break;
            case 7: policy.protectedDpkgOptions.push_back("--force-all"); break;
            case 8: // Configure alone must not stand in for a planned install.
                review.execution.actions.erase(review.execution.actions.begin());
                review.execution.archives.erase(review.execution.archives.begin());
                break;
            case 9: std::swap(review.execution.actions[0], review.execution.actions[1]); break;
            case 10: std::swap(review.execution.actions[7], review.execution.actions[8]); break;
            case 11: review.execution.archives.front().sourceIndexIdentity = "index-sha256:abc"; break;
            case 12: review.execution.archives.front().sourceDefinitionPath = "/etc/apt/../elsewhere"; break;
            case 13: review.execution.archives.front().recordSize = 0; break;
            case 14: review.execution.archives.front().recordOffset = UINT64_MAX; break;
            case 15: review.execution.archives.front().filename.clear(); break;
            default: Require(false, "missing manifest rejection variant");
        }
        Require(!authorization.Accept(review, policy, &error) && !authorization.active(), "invalid manifest accepted");
    }
}
void OrdinaryBatches() {
    Fixture fixture; P::ReviewAuthorization authorization; P::AuthorizedExecution allowed; std::string error;
    Require(authorization.Accept(fixture.review, fixture.policy, &error), "review refused");
    auto unpack = fixture.Request(P::ExecutionAction::Unpack, {1, 3, 5},
        {"--unpack", "--auto-deconfigure", "/cache/alpha-native.deb", "/cache/alpha-foreign.deb", "/cache/portable.deb"});
    auto evidence = fixture.ArchiveEvidence();
    Require(authorization.Authorize(unpack, evidence, &allowed, &error) && allowed.archives.size() == 3 &&
        allowed.arguments[fixture.policy.protectedDpkgOptions.size() + 1] == "8", "ordinary multiarch unpack or parent fd substitution refused");
    Require(!authorization.Authorize(unpack, evidence, &allowed, &error), "concurrent batch accepted");
    Require(authorization.Settle(1, Success(), "state-v2", true, &error), "unpack completion refused");
    Require(!authorization.Authorize(unpack, evidence, &allowed, &error), "old batch replay accepted");

    auto configure = fixture.Request(P::ExecutionAction::Configure, {2, 4, 6, 11}, {"--configure", "--pending"}, false);
    configure.batch = 2; evidence = fixture.Evidence(); evidence.stateIdentity = "state-v2";
    evidence.pendingTargetsKnown = true;
    evidence.pendingTargets = {{"alpha", "1", "amd64"}, {"alpha", "1", "i386"},
        {"portable", "1", "all"}, {"pending", "1", "amd64"}};
    evidence.triggerTargets = {{"triggered", "2", "amd64"}};
    Require(authorization.Authorize(configure, evidence, &allowed, &error) && allowed.actions.size() == 5,
        "independently enumerated pending configure and reviewed trigger refused");
    Require(authorization.Settle(2, Success(), "state-v3", true, &error), "configure completion refused");

    auto remove = fixture.Request(P::ExecutionAction::Remove, {7, 8},
        {"--force-depends", "--abort-after=1", "--remove", "old:amd64", "residual:amd64"});
    remove.batch = 3; evidence = fixture.Evidence(); evidence.stateIdentity = "state-v3";
    Require(authorization.Authorize(remove, evidence, &allowed, &error) &&
        authorization.Settle(3, Success(), "state-v4", true, &error), "ordinary remove-before-purge batch refused");
    auto purge = fixture.Request(P::ExecutionAction::Purge, {9}, {"--purge", "--pending"});
    purge.batch = 4; evidence.stateIdentity = "state-v4"; evidence.pendingTargetsKnown = true;
    evidence.pendingTargets = {{"residual", "1", "amd64"}};
    Require(authorization.Authorize(purge, evidence, &allowed, &error) &&
        authorization.Settle(4, Success(), "state-v5", true, &error) && authorization.complete(), "bounded pending purge failed");
}
void ExplicitTriggerBatch() {
    Fixture fixture; P::ReviewAuthorization authorization; P::AuthorizedExecution allowed; std::string error;
    Require(authorization.Accept(fixture.review, fixture.policy, &error), "review refused");
    auto request = fixture.Request(P::ExecutionAction::Triggers, {10}, {"--triggers-only", "triggered:amd64"});
    auto evidence = fixture.Evidence();
    // --no-triggers inhibits the deferred queue, while the explicit action
    // still executes its reviewed recipient. The state layer proves scope.
    Require(authorization.Authorize(request, evidence, &allowed, &error) &&
        allowed.action == P::ExecutionAction::Triggers && allowed.actions == request.actions,
        "explicit trigger batch with deferred processing disabled rejected");
    Require(authorization.Settle(1, Success(), "state-v2", true, &error), "explicit trigger settlement rejected");
    Require(!authorization.Authorize(request, evidence, &allowed, &error), "trigger batch replay accepted");
}
void EvidenceAndBatchRejection() {
    Fixture fixture; P::ReviewAuthorization authorization; P::AuthorizedExecution allowed; std::string error;
    auto unpack = fixture.Request(P::ExecutionAction::Unpack, {1, 3, 5},
        {"--unpack", "--auto-deconfigure", "/cache/alpha-native.deb", "/cache/alpha-foreign.deb", "/cache/portable.deb"});
    Require(authorization.Accept(fixture.review, fixture.policy, &error), "review refused");
    for (unsigned variant = 0; variant != 18; ++variant) {
        auto evidence = fixture.ArchiveEvidence();
        switch (variant) {
            case 0: evidence.frontendLockHeld = false; break;
            case 1: evidence.stateIdentity = "different-state"; break;
            case 2: evidence.archives.front().archive.package.version = "2"; break;
            case 3: evidence.archives.front().archive.sourceURI = "https://different.invalid/"; break;
            case 4: evidence.archives.front().archive.sourceIndexIdentity = "new-index"; break;
            case 5: evidence.archives.front().archive.hashes["SHA256"] = std::string(64, '2'); break;
            case 6: ++evidence.archives.front().archive.size; break;
            case 7: evidence.archives.front().inspection.status = CydiaPackages::ArchivePolicyStatus::LayoutMismatch; break;
            case 8: evidence.archives.front().inspection.complete = false; break;
            case 9: evidence.deconfigurationTargetsKnown = false; break;
            case 10: evidence.deconfigurationTargets = {{"outside", "1", "amd64"}}; break;
            case 11: evidence.archives.front().archive.sourceDefinitionPath = "/etc/apt/sources.list.d/other.sources"; break;
            case 12: ++evidence.archives.front().archive.sourceDefinitionOrdinal; break;
            case 13: evidence.archives.front().archive.sourceIndexPath = "/var/lib/apt/lists/other_Packages"; break;
            case 14: evidence.archives.front().archive.sourceIndexURI = "https://different.invalid/Packages"; break;
            case 15: ++evidence.archives.front().archive.recordOffset; break;
            case 16: ++evidence.archives.front().archive.recordSize; break;
            case 17: evidence.archives.front().archive.filename = "pool/different.deb"; break;
            default: Require(false, "missing evidence rejection variant");
        }
        Require(!authorization.Authorize(unpack, evidence, &allowed, &error), "changed parent archive/state evidence accepted");
    }
    for (const auto &option : {"--force-all", "--root=/different", "--recursive", "--pending", "-a"}) {
        auto request = unpack; request.arguments.insert(request.arguments.end() - 3, option);
        Require(!authorization.Authorize(request, fixture.ArchiveEvidence(), &allowed, &error), "unsupported dpkg scope accepted");
    }
    auto request = unpack; request.actions[1] = 1;
    Require(!authorization.Authorize(request, fixture.ArchiveEvidence(), &allowed, &error), "duplicate action accepted");
    request = unpack; request.arguments.back() = "/unreviewed/archive.deb";
    Require(!authorization.Authorize(request, fixture.ArchiveEvidence(), &allowed, &error), "unreviewed archive operand accepted");
    auto configure = fixture.Request(P::ExecutionAction::Configure, {2}, {"--configure", "alpha:amd64"});
    Require(!authorization.Authorize(configure, fixture.Evidence(), &allowed, &error), "configure ran before its reviewed unpack");
    auto pending = fixture.Request(P::ExecutionAction::Configure, {11}, {"--configure", "--pending"});
    auto evidence = fixture.Evidence();
    Require(!authorization.Authorize(pending, evidence, &allowed, &error), "unknown pending set accepted");
    evidence.pendingTargetsKnown = true; evidence.pendingTargets = {{"pending", "1", "amd64"}, {"outside", "1", "amd64"}};
    Require(!authorization.Authorize(pending, evidence, &allowed, &error), "unreviewed pending recipient accepted");
    auto bare = fixture.Request(P::ExecutionAction::Configure, {11}, {"--configure", "pending"});
    evidence = fixture.Evidence();
    Require(!authorization.Authorize(bare, evidence, &allowed, &error), "bare dpkg package inferred from review alone");
    evidence.barePackageTargets["pending"] = {"pending", "1", "i386"};
    Require(!authorization.Authorize(bare, evidence, &allowed, &error), "bare dpkg name resolved to wrong foreign instance");
    evidence.barePackageTargets["pending"] = {"pending", "1", "amd64"};
    Require(authorization.Authorize(bare, evidence, &allowed, &error), "parent-resolved legacy dpkg name refused");
    auto failed = Success(); failed.exitCode = 1;
    Require(!authorization.Settle(1, failed, "state-partial", true, &error) && !authorization.active(),
        "partial dpkg failure retained reviewed execution authority");
}
void ExplicitTriggersAndWarnings() {
    Fixture fixture; P::ReviewAuthorization authorization; P::AuthorizedExecution allowed; std::string error;
    Require(authorization.Accept(fixture.review, fixture.policy, &error), "review refused");
    auto trigger = fixture.Request(P::ExecutionAction::Triggers, {10}, {"--triggers-only", "--pending"}, false);
    auto evidence = fixture.Evidence(); evidence.pendingTargetsKnown = true;
    evidence.pendingTargets = evidence.triggerTargets = {{"triggered", "2", "amd64"}};
    Require(authorization.Authorize(trigger, evidence, &allowed, &error) &&
        authorization.Settle(1, Success(), "state-v2", true, &error), "reviewed pending trigger batch refused");
    fixture.policy.unverifiedArchiveWarningsAccepted = {"alpha-native"};
    Require(authorization.Accept(fixture.review, fixture.policy, &error), "accepted archive advisory refused");
    auto unpack = fixture.Request(P::ExecutionAction::Unpack, {1, 3, 5},
        {"--unpack", "/cache/alpha-native.deb", "/cache/alpha-foreign.deb", "/cache/portable.deb"});
    evidence = fixture.ArchiveEvidence(); evidence.archives.front().inspection.status = CydiaPackages::ArchivePolicyStatus::Unverified;
    Require(authorization.Authorize(unpack, evidence, &allowed, &error), "parent-approved complete archive warning was made fatal");
    Require(!authorization.Settle(1, Success(), "state-v2", false, &error) && !authorization.active(),
        "unverified post-execution state retained authority");

    // Unpacking another package may deconfigure an installed old version,
    // while the reviewed upgrade later configures its replacement version.
    fixture = Fixture();
    fixture.review.execution.actions.insert(fixture.review.execution.actions.begin(),
        Action(12, P::ExecutionAction::Deconfigure, {"alpha", "0.9", "amd64"}));
    fixture.policy.additionalActionsReviewed.insert(12);
    Require(authorization.Accept(fixture.review, fixture.policy, &error), "reviewed deconfiguration side effect refused");
    unpack = fixture.Request(P::ExecutionAction::Unpack, {1, 3, 5},
        {"--unpack", "--auto-deconfigure", "/cache/alpha-native.deb", "/cache/alpha-foreign.deb", "/cache/portable.deb"});
    evidence = fixture.ArchiveEvidence(); evidence.deconfigurationTargets = {{"alpha", "0.9", "amd64"}};
    Require(authorization.Authorize(unpack, evidence, &allowed, &error) && allowed.actions.size() == 4,
        "exact old-version deconfiguration could not accompany a reviewed replacement");
}
}
int main() {
    ReviewAndWire(); OrdinaryBatches(); ExplicitTriggerBatch(); EvidenceAndBatchRejection(); ExplicitTriggersAndWarnings();
    std::cout << "[apt-provider-review][ ok ] manifests, exact batches, pending sets and parent evidence\n";
}
