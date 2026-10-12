/* Synthetic helper-owned evidence exercises the pure model. These fixtures
 * do not establish filesystem capture, dyld closure or device execution.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderTransactionLease.hpp"
#include <algorithm>
#include <cstdlib>
#include <iostream>

namespace {
using namespace CydiaAPT;
namespace P = CydiaAPT::Provider;
void Require(bool value, const char *message) {
    if (value) return;
    std::cerr << "[apt-provider-transaction-lease][FAIL] " << message << '\n'; std::exit(1);
}
P::InstalledComponentEvidence File(const std::string &path, char hash, unsigned mode, std::uint64_t inode) {
    P::InstalledComponentEvidence result;
    result.file.metadata.path = path; result.file.metadata.size = 1024;
    result.file.metadata.mode = mode; result.file.sha256 = std::string(64, hash);
    result.kind = P::ComponentFileKind::Regular; result.device = 1; result.inode = inode; result.links = 1;
    result.parentsIdentity = std::string(64, '9'); return result;
}
P::ReviewedAction Action(std::uint64_t identifier, P::ExecutionAction kind, const P::ExecutionPackage &package,
    const std::string &archive = "") {
    P::ReviewedAction result; result.identifier = identifier; result.action = kind;
    result.package = package; result.archive = archive; return result;
}
struct Fixture {
    P::TransactionLeaseIdentity identity;
    P::TransactionLeaseContext before, after;
    P::ReviewedTransaction review;
    P::ReviewPolicy policy;
    std::vector<P::RetainedTransactionArchive> archives;
    std::vector<P::RetainedComponentArchive> replacements;
    std::vector<AutoInstalledDelta> deltas;
    Fixture(const std::string &bucket = "amd64", const std::string &versionArchitecture = "amd64", bool sha512Only = false) {
        auto &environment = policy.environment;
        environment.paths.dpkg = "/usr/bin/dpkg";
        environment.paths.dpkgQuery = "/usr/bin/dpkg-query";
        environment.paths.dpkgDeb = "/usr/bin/dpkg-deb";
        environment.paths.dpkgRoot = "/"; environment.paths.dpkgAdmin = "/var/lib/dpkg";
        environment.configurationIdentity = "config-v1"; environment.policyIdentity = "policy-v1";
        environment.methodsIdentity = "methods-v1"; environment.packageStateIdentity = "state-v1";
        environment.nativeArchitecture = "amd64"; environment.registeredArchitectures = {"amd64", "i386"};
        environment.acquisitionArchitectures = environment.registeredArchitectures;
        policy.layout = {"/", {"/var/jb"}};
        policy.protectedDpkgOptions = {"--root=/", "--admindir=/var/lib/dpkg"};
        review.binding.providerIdentifier = "provider"; review.binding.session = std::string(64, 'a');
        review.binding.configurationIdentity = environment.configurationIdentity;
        review.binding.policyIdentity = environment.policyIdentity;
        review.binding.packageStateIdentity = environment.packageStateIdentity;
        review.binding.cacheEpoch = 1; review.binding.selectionRevision = 1; review.binding.review = "review-1";
        review.transaction.registeredArchitectures = environment.registeredArchitectures;
        auto package = BuildPackageIdentity("dpkg", bucket, versionArchitecture, "amd64",
            versionArchitecture == "all" ? MultiArchMode::None : MultiArchMode::Same);
        review.transaction.upgrades = {package.routingName};
        review.transaction.packages[package.routingName] = {package, "2", "dpkg"};
        P::ArchiveManifest archive;
        archive.identifier = "dpkg-archive"; archive.package = {"dpkg", "2", versionArchitecture};
        archive.sourceURI = "https://repository.invalid/";
        archive.sourceIndexIdentity = "SHA256:" + std::string(64, 'a');
        archive.sourceDefinitionPath = "/etc/apt/sources.list.d/example.sources";
        archive.sourceIndexPath = "/var/lib/apt/lists/repository.invalid_Packages";
        archive.sourceIndexURI = "https://repository.invalid/Packages";
        archive.filename = "pool/dpkg.deb"; archive.recordOffset = 1024; archive.recordSize = 512;
        archive.path = "/cache/dpkg.deb";
        if (sha512Only) archive.hashes["SHA512"] = std::string(128, 'e');
        else archive.hashes["SHA256"] = std::string(64, 'f');
        archive.size = 4096; archive.layout = policy.layout;
        review.execution.archives.push_back(archive);
        review.execution.actions.push_back(Action(1, P::ExecutionAction::Unpack, archive.package, archive.identifier));
        review.execution.actions.push_back(Action(2, P::ExecutionAction::Configure, archive.package));
        identity.application = {"123", "10.1", "20.2", std::string(40, 'a') + std::string(40, 'b')};
        identity.lock.device = 1; identity.lock.inode = 99;
        identity.nonce = std::string(64, '1'); identity.reviewDigest = std::string(64, '2');
        identity.originIdentity = std::string(64, '3'); identity.operatingIdentity = std::string(64, '4');
        identity.nativeConfigurationIdentity = std::string(64, '5'); identity.platformIdentity = std::string(64, '6');
        identity.extendedStateIdentity = std::string(64, '7'); identity.stagingDirectory = "/state/transaction";
        before.application = identity.application; before.lock = identity.lock; before.lockOwner = 123;
        before.operatingIdentity = identity.operatingIdentity;
        before.nativeConfigurationIdentity = identity.nativeConfigurationIdentity; before.stateIdentity = "state-v1";
        before.components = {File("/usr/bin/dpkg", 'e', 0755, 10), File("/usr/lib/libfixture.dylib", 'a', 0644, 20)};
        after = before; after.stateIdentity = "state-v2";
        after.components = {File("/usr/bin/dpkg", 'b', 0755, 110), File("/usr/lib/libfixture.dylib", 'c', 0644, 120),
            File("/usr/lib/libnew.dylib", 'd', 0644, 130)};
        P::RetainedTransactionArchive staged;
        staged.source.archive = archive; staged.source.fileIdentity = "retained-copy-1";
        staged.source.inspection.complete = staged.source.inspection.identityVerified = true;
        staged.copy.identity = File(identity.stagingDirectory + "/0.deb", 'f', 0600, 100);
        staged.copy.identity.file.metadata.size = archive.size;
        // Synthetic outputs of hashing the same retained descriptor. The pure
        // fixture checks comparison semantics, not real cryptographic capture.
        staged.copy.hashes["SHA256"] = std::string(64, 'f');
        if (sha512Only) staged.copy.hashes["SHA512"] = std::string(128, 'e');
        archives.push_back(staged);
        before.stagedArchives = after.stagedArchives = {staged.copy};
        P::RetainedComponentArchive incoming; incoming.archive = staged.source;
        incoming.payload.archive = staged.source.inspection; incoming.payload.payload.complete = true;
        for (const auto &file : after.components) incoming.payload.files[file.file.metadata.path] = file.file;
        replacements.push_back(incoming);
        deltas = {{"dpkg", bucket, false}};
    }
    bool Begin(P::TransactionLease &lease, std::string *error) const {
        return lease.Begin(identity, review, policy, before, archives, replacements, deltas, error);
    }
    bool Components(P::ComponentSuccession &value, std::string *error) const {
        return value.Begin(review, policy, before.components, replacements,
            identity.nativeConfigurationIdentity, identity.platformIdentity, error);
    }
    P::TransactionLeaseEnvelope Envelope(std::uint64_t sequence) const {
        P::TransactionLeaseEnvelope value; value.nonce = identity.nonce; value.reviewDigest = identity.reviewDigest;
        value.sequence = sequence; return value;
    }
    P::ComponentClosureEvidence Closure(const P::TransactionLeaseContext &context) const {
        P::ComponentClosureEvidence value;
        value.executable = "/usr/bin/dpkg"; value.nativeConfigurationIdentity = identity.nativeConfigurationIdentity;
        value.platformIdentity = identity.platformIdentity;
        for (const auto &file : context.components) {
            P::ComponentClosureNode node; node.file = file;
            if (file.file.metadata.path == value.executable) {
                for (const auto &dependency : context.components) if (dependency.file.metadata.path != value.executable) {
                    P::ComponentDependencyEvidence edge; edge.path = dependency.file.metadata.path; node.dependencies.push_back(edge);
                }
            }
            P::ComponentDependencyEvidence platform;
            platform.kind = P::ComponentDependencyKind::Platform; platform.path = "/usr/lib/libSystem.B.dylib";
            node.dependencies.push_back(platform); value.nodes.push_back(node);
        }
        return value;
    }
    P::ParentExecutionRequest Request(bool configure = false) const {
        P::ParentExecutionRequest request; request.binding = review.binding;
        request.batch = configure ? 2 : 1; request.action = configure ? P::ExecutionAction::Configure : P::ExecutionAction::Unpack;
        request.actions = {configure ? 2u : 1u}; request.arguments = policy.protectedDpkgOptions;
        const auto &package = review.execution.actions[1].package;
        request.arguments.insert(request.arguments.end(), {"--status-fd=99", "--no-triggers",
            configure ? "--configure" : "--unpack", configure ? package.package + ':' + package.architecture : "/cache/dpkg.deb"});
        return request;
    }
    P::ParentExecutionEvidence Evidence(const P::TransactionLeaseContext &context) const {
        P::ParentExecutionEvidence evidence;
        evidence.binding = review.binding; evidence.frontendLockHeld = evidence.stateVerified = true;
        evidence.stateIdentity = context.stateIdentity; evidence.statusDescriptor = 8;
        evidence.deconfigurationTargetsKnown = evidence.triggerTargetsKnown = true; return evidence;
    }
};
P::ParentExecutionReply Success() { P::ParentExecutionReply result; result.started = true; result.exitCode = 0; return result; }

void ComponentGenerations() {
    Fixture fixture; std::string error; P::ComponentSuccession components;
    Require(fixture.Components(components, &error), "initial component evidence refused");
    Require(components.AuthorizeLaunch(fixture.Closure(fixture.before), &error), "initial exact closure refused");
    Require(components.Observe({1}, fixture.after.components, &error), "approved exact successor set refused");
    Require(!components.AuthorizeLaunch(fixture.Closure(fixture.before), &error), "stale old closure accepted after replacement");
    Require(components.AuthorizeLaunch(fixture.Closure(fixture.after), &error), "new exact closure refused");
    Require(components.Observe({1}, fixture.after.components, &error), "unchanged successor generation refused");
    auto changed = fixture.after.components; ++changed[0].inode;
    Require(!components.Observe({1}, changed, &error) && !components.active(), "old unpack permission reused for later replacement");
    Require(!components.Observe({1}, fixture.after.components, &error), "invalidated component ledger revived");
    for (unsigned variant = 0; variant != 10; ++variant) {
        P::ComponentSuccession trial; Require(fixture.Components(trial, &error), "component fixture refused");
        auto observed = fixture.after.components; std::set<std::uint64_t> actions{1};
        switch (variant) {
            case 0: actions.clear(); break;
            case 1: observed[0].file.sha256[0] = '0'; break;
            case 2: ++observed[0].file.metadata.size; break;
            case 3: observed[0].file.metadata.mode = 0700; break;
            case 4: observed[0].file.metadata.uid = 501; break;
            case 5: ++observed[0].file.metadata.gid; break;
            case 6: observed[0].kind = P::ComponentFileKind::Symlink; break;
            case 7: observed[0].links = 2; break;
            case 8: observed[0].parentsIdentity[0] = '0'; break;
            case 9: observed.pop_back(); break;
        }
        Require(!trial.Observe(actions, observed, &error), "unproved successor accepted");
    }
    for (unsigned variant = 0; variant != 8; ++variant) {
        P::ComponentSuccession trial; Require(fixture.Components(trial, &error), "component fixture refused");
        auto closure = fixture.Closure(fixture.before);
        switch (variant) {
            case 0: closure.nativeConfigurationIdentity[0] = '0'; break;
            case 1: closure.platformIdentity[0] = '0'; break;
            case 2: ++closure.nodes[0].file.inode; break;
            case 3: closure.nodes.pop_back(); break;
            case 4: closure.nodes[0].dependencies[0].path = "/usr/lib/unreviewed.dylib"; break;
            case 5: closure.nodes[0].dependencies[0].kind = P::ComponentDependencyKind::Platform; break;
            case 6: closure.nodes.push_back(closure.nodes.back()); break;
            case 7: closure.executable = "/usr/lib/libfixture.dylib"; break;
        }
        Require(!trial.AuthorizeLaunch(closure, &error), "unbound/incomplete launch graph accepted");
    }
    auto duplicated = fixture.replacements; duplicated.push_back(duplicated.front());
    P::ComponentSuccession ambiguous;
    Require(!ambiguous.Begin(fixture.review, fixture.policy, fixture.before.components, duplicated,
        fixture.identity.nativeConfigurationIdentity, fixture.identity.platformIdentity, &error), "duplicate successor archive accepted");
}
void CompleteLease(const std::string &bucket, const std::string &versionArchitecture, bool sha512Only = false) {
    Fixture fixture(bucket, versionArchitecture, sha512Only); P::TransactionLease lease; P::AuthorizedExecution batch; std::string error;
    Require(fixture.Begin(lease, &error), "lease admission refused");
    Require(lease.Capture(fixture.Envelope(1), fixture.before, &error), "same-generation capture refused");
    Require(lease.Authorize(fixture.Envelope(2), fixture.before, fixture.Request(), fixture.Evidence(fixture.before),
        fixture.Closure(fixture.before), &batch, &error), "approved first batch refused");
    Require(batch.arguments.back() == "/state/transaction/0.deb" &&
        std::find(batch.arguments.begin(), batch.arguments.end(), "--status-fd=8") != batch.arguments.end(),
        "private staged archive or parent status descriptor not substituted");
    Require(!lease.Close(&error), "active child could be discarded");
    Require(lease.Started(1, &error), "child start refused");
    Require(lease.Settle(1, Success(), fixture.after, true, &error), "approved upgrade settlement refused");
    Require(lease.mutationStarted() && !lease.complete(), "uncommitted mutation state lost");
    Require(lease.Authorize(fixture.Envelope(3), fixture.after, fixture.Request(true), fixture.Evidence(fixture.after),
        fixture.Closure(fixture.after), &batch, &error), "verified replacement dpkg could not configure");
    Require(lease.Started(2, &error), "configure start refused");
    auto final = fixture.after; final.stateIdentity = "state-v3";
    Require(lease.Settle(2, Success(), final, true, &error), "configure settlement refused");
    Require(lease.BeginCommit(fixture.Envelope(4), final, fixture.deltas, fixture.identity.extendedStateIdentity, &error),
        "exact once-only commit refused");
    Require(lease.SettleCommit(true, &error) && lease.complete(), "successful CAS completion lost");
    Require(!lease.BeginCommit(fixture.Envelope(5), final, fixture.deltas, fixture.identity.extendedStateIdentity, &error), "commit replay accepted");
    Require(lease.complete() && lease.Close(&error) && lease.complete(), "closing changed known committed outcome");
    Require(!fixture.Begin(lease, &error), "completed lease reopened");
}
void AdmissionAndRequestFailures() {
    std::string error;
    for (unsigned variant = 0; variant != 13; ++variant) {
        Fixture fixture;
        switch (variant) {
            case 0: fixture.archives.clear(); break;
            case 1: fixture.archives[0].source.archive.sourceURI = "https://other.invalid/"; break;
            case 2: fixture.archives[0].copy.identity.file.sha256[0] = '0'; break;
            case 3: fixture.archives[0].copy.identity.file.metadata.path = "/cache/dpkg.deb"; break;
            case 4: fixture.archives[0].copy.identity.file.metadata.mode = 0644; break;
            case 5: fixture.replacements[0].archive.fileIdentity = "another-copy"; break;
            case 6: fixture.identity.application.hash = "bad"; break;
            case 7: fixture.before.lockOwner = 456; break;
            case 8: fixture.before.lock.inode++; break;
            case 9: fixture.identity.nativeConfigurationIdentity.clear(); break;
            case 10: fixture.deltas.push_back({"unreviewed", "amd64", true}); break;
            case 11: fixture.archives[0].source.inspection.complete = false; break;
            case 12: fixture.before.stagedArchives.clear(); break;
        }
        P::TransactionLease lease;
        Require(!fixture.Begin(lease, &error) && lease.phase() == P::TransactionLeasePhase::Failed && !lease.mutationStarted(),
            "incomplete/changed pre-mutation authority accepted");
    }
    for (unsigned variant = 0; variant != 11; ++variant) {
        Fixture fixture; P::TransactionLease lease; Require(fixture.Begin(lease, &error), "lease fixture refused");
        auto envelope = fixture.Envelope(1); auto context = fixture.before;
        switch (variant) {
            case 0: envelope.nonce[0] = '0'; break;
            case 1: envelope.reviewDigest[0] = '0'; break;
            case 2: envelope.sequence = 2; break;
            case 3: context.application.start = "21.2"; break;
            case 4: context.lock.inode++; break;
            case 5: context.lockOwner = 456; break;
            case 6: context.operatingIdentity[0] = '0'; break;
            case 7: context.nativeConfigurationIdentity[0] = '0'; break;
            case 8: context.stateIdentity = "another-state"; break;
            case 9: context.stagedArchives[0].identity.file.sha256[0] = '0'; break;
            case 10: ++context.stagedArchives[0].identity.inode; break;
        }
        Require(!lease.Capture(envelope, context, &error), "wrong lease/app/lock/state frame accepted");
        Require(!lease.Capture(fixture.Envelope(1), fixture.before, &error), "failed lease resumed with old frame");
    }
    Fixture fixture; P::TransactionLease replay;
    Require(fixture.Begin(replay, &error) && replay.Capture(fixture.Envelope(1), fixture.before, &error), "capture fixture refused");
    Require(!replay.Capture(fixture.Envelope(1), fixture.before, &error), "frame replay accepted");
    P::TransactionLease premature;
    Require(fixture.Begin(premature, &error), "commit fixture refused");
    Require(!premature.BeginCommit(fixture.Envelope(1), fixture.before, fixture.deltas,
        fixture.identity.extendedStateIdentity, &error), "commit before primary actions accepted");
}
void StagedHashEvidence() {
    std::string error;
    for (unsigned variant = 0; variant != 6; ++variant) {
        Fixture fixture("amd64", "amd64", true);
        auto &copy = fixture.archives[0].copy;
        switch (variant) {
            case 0: copy.hashes["SHA512"][0] = '0'; break;
            case 1: copy.hashes.erase("SHA512"); break;
            case 2: copy.hashes.erase("SHA256"); break;
            case 3: copy.hashes["SHA256"][0] = '0'; break;
            case 4: copy.identity.file.sha256[0] = '0'; break;
            case 5: copy.hashes["unrequested-hash"] = "unbound"; break;
        }
        // A matching fresh checkpoint must not conceal a bad initial proof.
        fixture.before.stagedArchives = {copy};
        P::TransactionLease lease;
        Require(!fixture.Begin(lease, &error), "SHA512-only source accepted missing/mismatched retained-copy hashes");
    }
    for (unsigned variant = 0; variant != 3; ++variant) {
        Fixture fixture("amd64", "amd64", true); P::TransactionLease lease;
        Require(fixture.Begin(lease, &error), "SHA512-only archive fixture refused");
        auto changed = fixture.before;
        if (variant == 0) changed.stagedArchives[0].hashes["SHA512"][0] = '0';
        else if (variant == 1) changed.stagedArchives[0].hashes.erase("SHA512");
        else ++changed.stagedArchives[0].identity.inode;
        Require(!lease.Capture(fixture.Envelope(1), changed, &error), "fresh staged SHA512/inode change accepted");
    }
    // Check every requested algorithm even when a matching strong hash exists.
    Fixture multiple;
    multiple.review.execution.archives[0].hashes["SHA512"] = std::string(128, 'e');
    multiple.review.execution.archives[0].hashes["SHA1"] = std::string(40, 'd');
    multiple.archives[0].source.archive = multiple.review.execution.archives[0];
    multiple.replacements[0].archive.archive = multiple.review.execution.archives[0];
    multiple.archives[0].copy.hashes = multiple.review.execution.archives[0].hashes;
    multiple.before.stagedArchives = {multiple.archives[0].copy};
    P::TransactionLease accepted;
    Require(multiple.Begin(accepted, &error), "complete multiple-algorithm staged proof refused");
    multiple.archives[0].copy.hashes["SHA1"][0] = '0';
    multiple.before.stagedArchives = {multiple.archives[0].copy};
    P::TransactionLease mismatch;
    Require(!multiple.Begin(mismatch, &error), "matching SHA256 concealed another requested hash mismatch");

    Fixture fixture("amd64", "amd64", true); P::TransactionLease lease; P::AuthorizedExecution batch;
    Require(fixture.Begin(lease, &error) && lease.Authorize(fixture.Envelope(1), fixture.before, fixture.Request(),
        fixture.Evidence(fixture.before), fixture.Closure(fixture.before), &batch, &error) && lease.Started(1, &error),
        "SHA512 child fixture refused");
    auto after = fixture.after; after.stagedArchives[0].hashes["SHA512"][0] = '0';
    Require(!lease.Settle(1, Success(), after, true, &error) && lease.mutationStarted() &&
        lease.phase() == P::TransactionLeasePhase::Failed, "changed retained SHA512 accepted after child settlement");
}
void InterruptedChildren() {
    for (unsigned variant = 0; variant != 9; ++variant) {
        Fixture fixture; P::TransactionLease lease; P::AuthorizedExecution batch; std::string error;
        Require(fixture.Begin(lease, &error) && lease.Authorize(fixture.Envelope(1), fixture.before, fixture.Request(),
            fixture.Evidence(fixture.before), fixture.Closure(fixture.before), &batch, &error), "child fixture refused");
        auto reply = Success(); auto after = fixture.after; bool verified = true;
        if (variant != 0 && variant != 8) Require(lease.Started(1, &error), "child start fixture refused");
        switch (variant) {
            case 0: reply.started = false; reply.launchError = 5; break;
            case 1: lease.Cancel(); break;
            case 2: lease.TransportLost(); break;
            case 3: reply.exitCode = 1; break;
            case 4: verified = false; break;
            case 5: after.components[0].file.sha256[0] = '0'; break;
            case 6: Require(!lease.Capture(fixture.Envelope(2), fixture.before, &error), "concurrent frame accepted"); break;
            case 7: ++after.stagedArchives[0].identity.inode; break;
            case 8: break; // Child observed at settlement without start notification.
        }
        Require(!lease.Close(&error), "unsettled execution could close");
        Require(!lease.Settle(1, reply, after, verified, &error) && lease.phase() == P::TransactionLeasePhase::Failed,
            "failed/cancelled/uncertain child retained authority");
        Require(lease.mutationStarted() == (variant != 0) && lease.indeterminate() == (variant == 2), "child history lost");
        Require(!lease.Authorize(fixture.Envelope(2), fixture.before, fixture.Request(), fixture.Evidence(fixture.before),
            fixture.Closure(fixture.before), &batch, &error), "failed mutation became retryable");
        Require(lease.Close(&error), "settled failed lease could not close");
    }
}
void SeparateEffectPasses() {
    Fixture fixture; fixture.identity.effectIdentity = std::string(64, '8');
    P::TransactionLease lease; std::string error; P::AuthorizedExecution batch;
    Require(fixture.Begin(lease, &error) && lease.AuthorizeEffects(fixture.before, fixture.identity.effectIdentity, 1,
        fixture.Closure(fixture.before), &error) && lease.StartedEffects(1, &error), "effect pass owns its actual child");
    Require(!lease.Close(&error), "live effect child prevents close");
    auto drained = fixture.before; drained.stateIdentity = "effect-state-1";
    Require(lease.SettleEffects(1, Success(), drained, true, &error) && lease.Expects(fixture.Envelope(1)) &&
        lease.stateIdentity() == drained.stateIdentity, "effect pass advances state without consuming external request sequence");
    Require(lease.Authorize(fixture.Envelope(1), drained, fixture.Request(), fixture.Evidence(drained),
        fixture.Closure(drained), &batch, &error) && batch.actions == std::vector<std::uint64_t>{1} &&
        lease.Started(1, &error), "effect pass did not consume primary action ID 1");
    Require(lease.Settle(1, Success(), fixture.after, true, &error), "primary child after effect preserves exact component succession");
    Require(lease.AuthorizeEffects(fixture.after, fixture.identity.effectIdentity, 2, fixture.Closure(fixture.after), &error) &&
        lease.StartedEffects(2, &error), "second internal pass uses post-unpack executable closure");
    auto final = fixture.after; final.stateIdentity = "effect-state-2";
    Require(lease.SettleEffects(2, Success(), final, true, &error) && lease.Expects(fixture.Envelope(2)), "internal pass numbering stays separate");
    Require(!lease.AuthorizeEffects(final, fixture.identity.effectIdentity, 2, fixture.Closure(final), &error), "effect pass cannot replay");
    for (unsigned variant = 0; variant != 5; ++variant) {
        P::TransactionLease interrupted; Require(fixture.Begin(interrupted, &error), "effect failure fixture");
        if (variant == 0) {
            Require(!interrupted.AuthorizeEffects(fixture.before, std::string(64, '7'), 1, fixture.Closure(fixture.before), &error),
                "effect approval identity cannot change"); continue;
        }
        Require(interrupted.AuthorizeEffects(fixture.before, fixture.identity.effectIdentity, 1, fixture.Closure(fixture.before), &error),
            "effect execution fixture");
        if (variant != 4) Require(interrupted.StartedEffects(1, &error), "effect actual start fixture");
        if (variant == 1) interrupted.Cancel();
        if (variant == 2) interrupted.TransportLost();
        auto reply = Success(); if (variant == 3) reply.exitCode = 1;
        Require(!interrupted.Close(&error) && !interrupted.SettleEffects(1, reply, drained, true, &error) &&
            interrupted.mutationStarted() && interrupted.indeterminate() == (variant == 2) && interrupted.Close(&error),
            "effect failure/cancellation/missing start observer retains mutation and releases only after settlement");
    }
}
}
int main() {
    ComponentGenerations(); CompleteLease("amd64", "amd64"); CompleteLease("i386", "i386");
    CompleteLease("amd64", "all"); CompleteLease("amd64", "amd64", true);
    AdmissionAndRequestFailures(); StagedHashEvidence(); InterruptedChildren(); SeparateEffectPasses();
    std::cout << "[apt-provider-transaction-lease][ ok ] retained review, generations, staged archives, replay and settlement\n";
}
