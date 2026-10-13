/* Parent-owned finite effects: pure fixtures, no dpkg child or host mutation.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderTriggerEffects.hpp"
#include <algorithm>
#include <cstdlib>
#include <iostream>

namespace {
namespace P = CydiaAPT::Provider;
void Require(bool value, const char *message) {
    if (value) return;
    std::cerr << "[apt-provider-trigger-effects] " << message << '\n'; std::exit(1);
}
std::string Row(const std::string &name, const std::string &version = "1", const std::string &arch = "amd64",
    const std::string &status = "installed", const std::string &multi = "", const std::string &pending = "", const std::string &awaited = "") {
    return name + '\t' + version + '\t' + arch + "\tinstall ok " + status + '\t' + multi + '\t' + pending + '\t' + awaited + '\n';
}
std::map<std::string, std::string> Controls(const std::string &multi = "no") {
    std::map<std::string, std::string> result; std::string error;
    Require(CydiaPackages::CanonicalPackageEffectControlFields({{"multi-arch", multi}}, &result, &error), "fixture controls");
    return result;
}
void Seal(P::TriggerEffectCheckpoint *point, const std::string &identity) {
    point->packages.packageStateIdentity = identity; point->metadata.packageStateIdentity = identity;
    point->identity = P::TriggerEffectCheckpointIdentity(*point);
    Require(!point->identity.empty(), "fixture checkpoint admission");
}
P::TriggerEffectCheckpoint Point(const std::string &rows, const std::map<std::string, std::string> &declarations,
    const std::map<std::string, std::string> &registry, const std::string &identity = "state-1") {
    P::TriggerEffectCheckpoint result; std::string error;
    Require(P::ParseDpkgState(rows, "amd64\n", "i386\n", identity, &result.packages, &error), "fixture structured state");
    result.registry.synchronized = true; result.registry.evidenceIdentity.assign(64, 'a');
    result.metadata.evidenceIdentity.assign(64, 'b');
    P::TriggerRegistryInput input; input.directoryPresent = true; input.files = registry; input.files["Lock"] = "";
    Require(P::ParseTriggerRegistry(input, &result.registry.state, &error), "fixture native registry");
    for (const auto &record : result.packages.packages) {
        if (record.second.package.version.empty()) continue;
        P::TriggerPackageMetadata metadata; metadata.package = record.second.package;
        metadata.evidenceIdentity.assign(64, 'c'); metadata.controls = Controls(record.second.multiArch.empty() ? "no" : record.second.multiArch);
        metadata.declarationIdentity.assign(64, 'd');
        metadata.diskStatus = record.second.status;
        if (record.second.status >= P::DpkgPackageStatus::TriggersAwaited) metadata.configVersion = record.second.package.version;
        const auto found = declarations.find(record.first);
        Require(P::ParseTriggerDeclarations(found == declarations.end() ? "" : found->second, &metadata.declarations, &error), "fixture declarations");
        result.metadata.packages.emplace(record.first, metadata);
    }
    Seal(&result, identity); return result;
}
P::ReviewedTransaction Review(const P::TriggerEffectCheckpoint &point) {
    P::ReviewedTransaction result; result.binding.packageStateIdentity = point.packages.packageStateIdentity; return result;
}
P::TriggerEffectEnvelope Envelope(const P::TriggerEffectCheckpoint &point, const P::ReviewedTransaction &review) {
    P::TriggerEffectEnvelope result; std::string error;
    Require(P::BuildTriggerEffectEnvelope(review, point, &result, &error), "fixture reviewed envelope"); return result;
}
P::ParentExecutionReply Success() { P::ParentExecutionReply result; result.started = true; result.exitCode = 0; return result; }
P::ReviewedAction Action(std::uint64_t id, P::ExecutionAction kind, const P::ExecutionPackage &package, const std::string &archive = "") {
    P::ReviewedAction result; result.identifier = id; result.action = kind; result.package = package; result.archive = archive; return result;
}
P::AuthorizedExecution Batch(std::uint64_t id, P::ExecutionAction action, std::vector<std::uint64_t> actions) {
    P::AuthorizedExecution result; result.batch = id; result.action = action; result.actions = std::move(actions);
    result.arguments = {"--no-triggers"}; return result;
}
const std::map<std::string, std::string> SharedDeclarations = {
    {"cache:amd64", "interest-await cache-native\n"}, {"cache:i386", "interest-noawait cache-foreign\n"}};
const std::map<std::string, std::string> SharedRegistry = {
    {"cache-native", "cache:amd64\n"}, {"cache-foreign", "cache:i386/noawait\n"}};
P::TriggerEffectCheckpoint Initial() {
    return Point(Row("cache", "1", "amd64", "triggers-pending", "same", "cache-native") +
        Row("cache", "1", "i386", "installed", "same") + Row("waiting", "1", "all", "triggers-awaited", "", "", "cache:amd64") +
        Row("unrelated", "2", "all"), SharedDeclarations, SharedRegistry);
}
void RepeatedDrains() {
    auto before = Initial(); auto envelope = Envelope(before, Review(before)); std::string error;
    Require(envelope.recipients.size() == 2 && envelope.awaiters.size() == 3, "finite pool distinguishes native, foreign and all waiter");
    P::TriggerEffectLedger ledger; P::TriggerDrainPlan pass;
    Require(ledger.Begin(envelope, before, &error) && !ledger.quiescent() && ledger.NextDrain(before.identity, &pass, &error) &&
        pass.pass == 1 && pass.targets.size() == 1 && pass.targets[0].architecture == "amd64", "first complete pending pass");
    auto middle = Point(Row("cache", "1", "amd64", "installed", "same") +
        Row("cache", "1", "i386", "triggers-pending", "same", "cache-foreign") + Row("waiting", "1", "all") +
        Row("unrelated", "2", "all"), SharedDeclarations, SharedRegistry, "state-2");
    Require(ledger.SettleDrain(pass.pass, Success(), middle, &error) && !ledger.quiescent() &&
        ledger.NextDrain(middle.identity, &pass, &error) && pass.pass == 2 && pass.targets.size() == 1 &&
        pass.targets[0].architecture == "i386", "new trigger on already reviewed foreign recipient has separate pass");
    auto after = Point(Row("cache", "1", "amd64", "installed", "same") + Row("cache", "1", "i386", "installed", "same") +
        Row("waiting", "1", "all") + Row("unrelated", "2", "all"), SharedDeclarations, SharedRegistry, "state-3");
    Require(ledger.SettleDrain(pass.pass, Success(), after, &error) && ledger.quiescent() && !ledger.indeterminate(), "settled finite graph");
    Require(!ledger.NextDrain(after.identity, &pass, &error) && ledger.active() && error == "provider_trigger_no_pending_effects",
        "quiescent graph does not invent a dpkg invocation");
}
void ReferenceOnlyDrains() {
    auto before = Initial(); P::DpkgState references; std::string error;
    Require(P::ParseDpkgState("old-reference\t\t\tunknown ok not-installed\tno\t\t\n", "amd64\n", "i386\n", "state-1", &references, &error),
        "native reference row fixture");
    before.packages.packages.insert(references.packages.begin(), references.packages.end()); Seal(&before, "state-1");
    auto after = Point(Row("cache", "1", "amd64", "installed", "same") + Row("cache", "1", "i386", "installed", "same") +
        Row("waiting", "1", "all") + Row("unrelated", "2", "all") +
        "new-reference\t\t\tunknown ok not-installed\tno\t\t\n", SharedDeclarations, SharedRegistry, "state-2");
    for (unsigned variant = 0; variant != 3; ++variant) {
        auto next = after;
        if (variant == 1) next.packages.packages.at("new-reference:").selection = P::DpkgSelection::Hold;
        if (variant == 2) next.packages.packages.at("new-reference:").selection = P::DpkgSelection::Install;
        Seal(&next, "state-2"); P::TriggerEffectLedger ledger; P::TriggerDrainPlan pass;
        Require(ledger.Begin(Envelope(before, Review(before)), before, &error) && ledger.NextDrain(before.identity, &pass, &error),
            "reviewed drain with retained raw reference rows");
        const bool accepted = ledger.SettleDrain(pass.pass, Success(), next, &error);
        Require(accepted == (variant == 0), "only unselected metadata-empty reference lifecycle is ignored during a real trigger transition");
    }
    // Dropping only a reference is not trigger progress and cannot justify
    // another repeated drain when the actual pending graph remains unchanged.
    auto unchanged = before; unchanged.packages.packages.erase("old-reference:"); Seal(&unchanged, "state-2");
    P::TriggerEffectLedger noProgress; P::TriggerDrainPlan pass;
    Require(noProgress.Begin(Envelope(before, Review(before)), before, &error) && noProgress.NextDrain(before.identity, &pass, &error) &&
        !noProgress.SettleDrain(pass.pass, Success(), unchanged, &error) && error == "provider_trigger_drain_no_progress",
        "reference-only churn does not conceal a stalled native trigger graph");
}
void DeferredQueues() {
    auto declarations = SharedDeclarations, registry = SharedRegistry;
    registry["Unincorp"] = "cache-native waiting:all -\n";
    auto before = Point(Row("cache", "1", "amd64", "triggers-pending", "same", "cache-native") +
        Row("cache", "1", "i386", "installed", "same") + Row("waiting", "1", "all", "triggers-awaited", "", "", "cache:amd64"), declarations, registry);
    P::TriggerEffectLedger ledger; P::TriggerDrainPlan pass; std::string error;
    Require(ledger.Begin(Envelope(before, Review(before)), before, &error) && ledger.NextDrain(before.identity, &pass, &error) &&
        pass.incorporateDeferred && pass.targets.size() == 1, "read-only incorporated view binds original deferred queue");
    registry["Unincorp"] = "";
    auto after = Point(Row("cache", "1", "amd64", "installed", "same") + Row("cache", "1", "i386", "installed", "same") +
        Row("waiting", "1", "all"), declarations, registry, "state-2");
    Require(ledger.SettleDrain(pass.pass, Success(), after, &error) && ledger.quiescent(), "queue and incorporated state settle together");
    before = Point(Row("requester", "1", "all"), {}, {{"Unincorp", "unused-trigger requester:all -\n"}});
    P::TriggerEffectLedger incorporate;
    Require(incorporate.Begin(Envelope(before, Review(before)), before, &error) && !incorporate.quiescent() &&
        incorporate.NextDrain(before.identity, &pass, &error) && pass.targets.empty() && pass.incorporateDeferred,
        "queue with no recipient needs explicit parent incorporation, not fake quiescence");
    after = Point(Row("requester", "1", "all"), {}, {{"Unincorp", ""}}, "state-2");
    Require(incorporate.SettleDrain(pass.pass, Success(), after, &error) && incorporate.quiescent(), "empty-target incorporation settles");
}
void Rejections() {
    const auto initial = Initial(); const auto envelope = Envelope(initial, Review(initial)); std::string error; P::TriggerDrainPlan pass;
    P::TriggerEffectLedger unchanged;
    Require(unchanged.Begin(envelope, initial, &error) && unchanged.NextDrain(initial.identity, &pass, &error), "cycle fixture begin");
    auto next = initial; Seal(&next, "different-file-timestamps");
    Require(!unchanged.SettleDrain(pass.pass, Success(), next, &error) && unchanged.indeterminate() &&
        error == "provider_trigger_drain_no_progress", "metadata rewrite cannot disguise no-progress trigger graph");
    P::TriggerEffectLedger stale;
    Require(stale.Begin(envelope, initial, &error) && !stale.NextDrain("stale", &pass, &error) && !stale.indeterminate(),
        "stale checkpoint denied before effects");
    P::TriggerEffectLedger hidden;
    Require(hidden.Begin(envelope, initial, &error) && hidden.NextDrain(initial.identity, &pass, &error), "hidden recipient fixture begin");
    auto declarations = SharedDeclarations, registry = SharedRegistry;
    declarations["unrelated:all"] = "interest-noawait surprise\n"; registry["surprise"] = "unrelated:all/noawait\n";
    next = Point(Row("cache", "1", "amd64", "installed", "same") + Row("cache", "1", "i386", "installed", "same") +
        Row("waiting", "1", "all") + Row("unrelated", "2", "all", "triggers-pending", "", "surprise"), declarations, registry, "state-2");
    Require(!hidden.SettleDrain(pass.pass, Success(), next, &error) && hidden.indeterminate(), "new recipient cannot silently expand approved pool");
    P::TriggerEffectLedger extraEffect;
    Require(extraEffect.Begin(envelope, initial, &error) && extraEffect.NextDrain(initial.identity, &pass, &error), "deconfigure fixture begin");
    next = Point(Row("cache", "1", "amd64", "installed", "same") + Row("cache", "1", "i386", "installed", "same") +
        Row("waiting", "1", "all") + Row("unrelated", "2", "all", "unpacked"), SharedDeclarations, SharedRegistry, "state-2");
    Require(!extraEffect.SettleDrain(pass.pass, Success(), next, &error), "drain cannot conceal deconfiguration");
    P::TriggerEffectLedger childFailed;
    Require(childFailed.Begin(envelope, initial, &error) && childFailed.NextDrain(initial.identity, &pass, &error), "failed child fixture begin");
    auto failure = Success(); failure.exitCode = 1;
    Require(!childFailed.SettleDrain(pass.pass, failure, initial, &error) && childFailed.indeterminate(), "started failure invalidates repeated drain");
    auto damaged = initial; damaged.registry.synchronized = false;
    P::TriggerEffectEnvelope rejected;
    Require(!P::BuildTriggerEffectEnvelope(Review(damaged), damaged, &rejected, &error), "observed unlocked evidence grants no execution allowance");
    damaged = initial; damaged.registry.state.interests[0].package = "cache:any";
    Require(P::TriggerEffectCheckpointIdentity(damaged).empty(), "any selector is never guessed from native architecture");
    damaged = initial; damaged.registry.state.interests[0].package = "cache";
    Require(P::TriggerEffectCheckpointIdentity(damaged).empty(), "coinstalled bare selector is unresolved");
}
P::VerifiedArchiveControlEvidence Incoming(const P::ArchiveManifest &manifest) {
    P::VerifiedArchiveControlEvidence result; result.archive.archive = manifest; result.archive.fileIdentity = "retained-file-proof";
    result.archive.inspection.complete = result.archive.inspection.identityVerified = true;
    result.control.complete = result.control.triggersPresent = true;
    result.control.identity = {manifest.package.package, manifest.package.version, manifest.package.architecture};
    result.control.controls = Controls(); result.control.triggers = "activate-await cache-native\n"; return result;
}
void IncomingAndPrimary() {
    auto before = Point(Row("cache"), {{"cache:amd64", "interest-await cache-native\n"}}, {{"cache-native", "cache:amd64\n"}});
    auto review = Review(before); P::ArchiveManifest archive;
    archive.identifier = "archive-1"; archive.package = {"portable", "2", "all"}; archive.path = "/fixture/portable.deb";
    review.execution.archives = {archive};
    review.execution.actions = {Action(1, P::ExecutionAction::Unpack, archive.package, archive.identifier),
        Action(2, P::ExecutionAction::Configure, archive.package)};
    auto envelope = Envelope(before, review); auto unpack = Batch(1, P::ExecutionAction::Unpack, {1});
    const auto proof = Incoming(archive); unpack.archives = {proof.archive}; std::string error;
    P::TriggerEffectLedger unrefined;
    Require(unrefined.Begin(envelope, before, &error) && !unrefined.PreparePrimary(before.identity, unpack, &error) &&
        !unrefined.indeterminate(), "incoming declarations must be verified before any child starts");
    P::TriggerEffectLedger ledger;
    Require(ledger.Begin(envelope, before, &error) && ledger.RefineIncoming({proof}, &error) &&
        ledger.PreparePrimary(before.identity, unpack, &error), "exact verified incoming proof enables reviewed unpack");
    auto middle = Point(Row("cache", "1", "amd64", "triggers-pending", "", "cache-native") +
        Row("portable", "2", "all", "unpacked", "", "", "cache:amd64"),
        {{"cache:amd64", "interest-await cache-native\n"}, {"portable:all", "activate-await cache-native\n"}},
        {{"cache-native", "cache:amd64\n"}}, "state-2");
    Require(ledger.Reconcile(unpack, Success(), middle, &error), "primary exact unpack admits only reviewed trigger side effects");
    P::TriggerDrainPlan pass;
    Require(ledger.NextDrain(middle.identity, &pass, &error) && pass.pass == 1 && pass.primaryCheckpoint == 1,
        "drain pass namespace independent from primary action 1");
    auto cleared = Point(Row("cache") + Row("portable", "2", "all", "unpacked"),
        {{"cache:amd64", "interest-await cache-native\n"}, {"portable:all", "activate-await cache-native\n"}},
        {{"cache-native", "cache:amd64\n"}}, "state-3");
    Require(ledger.SettleDrain(pass.pass, Success(), cleared, &error), "unpacked waiter stays unpacked after recipient processing");
    auto configure = Batch(2, P::ExecutionAction::Configure, {2});
    Require(ledger.PreparePrimary(cleared.identity, configure, &error), "ordinary configure follows settled trigger dependency");
    auto installed = Point(Row("cache") + Row("portable", "2", "all"),
        {{"cache:amd64", "interest-await cache-native\n"}, {"portable:all", "activate-await cache-native\n"}},
        {{"cache-native", "cache:amd64\n"}}, "state-4");
    Require(ledger.Reconcile(configure, Success(), installed, &error) && ledger.quiescent(), "all package exact version remains after configure");
    Require(!ledger.PreparePrimary(installed.identity, unpack, &error) && !ledger.indeterminate(), "completed primary IDs cannot be replayed as effects");
    P::TriggerEffectLedger wrongArchive; auto wrong = proof; wrong.archive.fileIdentity.clear();
    Require(wrongArchive.Begin(envelope, before, &error) && !wrongArchive.RefineIncoming({wrong}, &error), "claimed archive control without retained evidence rejected");
}
void PreDependsChildBoundaries() {
    const auto before = Point(Row("cache"), {{"cache:amd64", "interest-await cache-native\n"}}, {{"cache-native", "cache:amd64\n"}});
    auto review = Review(before); P::ArchiveManifest first, later;
    first.identifier = "first-archive"; first.package = {"portable", "2", "all"}; first.path = "/fixture/portable.deb";
    later.identifier = "later-archive"; later.package = {"helper", "2", "amd64"}; later.path = "/fixture/helper.deb";
    review.execution.archives = {first, later};
    review.execution.actions = {Action(10, P::ExecutionAction::Unpack, first.package, first.identifier),
        Action(20, P::ExecutionAction::Unpack, later.package, later.identifier)};
    auto firstProof = Incoming(first), laterProof = Incoming(later);
    auto batch = Batch(1, P::ExecutionAction::Unpack, {10, 20}); batch.archives = {firstProof.archive, laterProof.archive};
    std::string error;
    P::TriggerEffectLedger ordinary;
    Require(ordinary.Begin(Envelope(before, review), before, &error) && ordinary.RefineIncoming({firstProof, laterProof}, &error) &&
        ordinary.PreparePrimary(before.identity, batch, &error), "ordinary homogeneous unpack batching is retained");
    firstProof.control.controls["pre-depends"] = "cache (>= 1)";
    P::TriggerEffectLedger firstOnly;
    Require(firstOnly.Begin(Envelope(before, review), before, &error) && firstOnly.RefineIncoming({firstProof, laterProof}, &error) &&
        firstOnly.PreparePrimary(before.identity, batch, &error), "first member Pre-Depends has a pre-child checkpoint and is not rejected by the batching prerequisite");
    laterProof.control.controls["pre-depends"] = "cache (>= 1)";
    P::TriggerEffectLedger laterDenied;
    Require(laterDenied.Begin(Envelope(before, review), before, &error) && laterDenied.RefineIncoming({firstProof, laterProof}, &error) &&
        !laterDenied.PreparePrimary(before.identity, batch, &error) && !laterDenied.indeterminate() &&
        error == "provider_trigger_predepends_batch_boundary", "later member Pre-Depends requires another child before any execution starts");
    laterProof.control.controls["pre-depends"].clear();
    auto reorderedBatch = batch; reorderedBatch.actions = {20, 10};
    std::reverse(reorderedBatch.archives.begin(), reorderedBatch.archives.end());
    P::TriggerEffectLedger reorderedDenied;
    Require(reorderedDenied.Begin(Envelope(before, review), before, &error) && reorderedDenied.RefineIncoming({laterProof, firstProof}, &error) &&
        !reorderedDenied.PreparePrimary(before.identity, reorderedBatch, &error) && !reorderedDenied.indeterminate() &&
        error == "provider_trigger_predepends_batch_boundary", "authorized archive operand order determines the boundary independently of refinement storage order");
    std::reverse(review.execution.archives.begin(), review.execution.archives.end());
    std::reverse(review.execution.actions.begin(), review.execution.actions.end());
    P::TriggerEffectLedger reorderedAllowed;
    Require(reorderedAllowed.Begin(Envelope(before, review), before, &error) && reorderedAllowed.RefineIncoming({laterProof, firstProof}, &error) &&
        reorderedAllowed.PreparePrimary(before.identity, batch, &error), "review/archive/refinement storage order cannot move first-operand Pre-Depends to a guessed boundary");
    auto duplicateBatch = batch; duplicateBatch.archives = {firstProof.archive, firstProof.archive, laterProof.archive};
    P::TriggerEffectLedger duplicate;
    Require(duplicate.Begin(Envelope(before, review), before, &error) && duplicate.RefineIncoming({firstProof, laterProof}, &error) &&
        !duplicate.PreparePrimary(before.identity, duplicateBatch, &error) && !duplicate.indeterminate() &&
        error == "provider_trigger_incoming_unverified", "duplicate archive evidence cannot establish ordered complete unpack proof");
    P::TriggerEffectLedger unrefined;
    Require(unrefined.Begin(Envelope(before, review), before, &error) && !unrefined.PreparePrimary(before.identity, batch, &error) &&
        !unrefined.indeterminate() && error == "provider_trigger_incoming_unverified", "batch archive hints cannot replace complete parent control refinement");
    P::TriggerEffectLedger incomplete;
    Require(incomplete.Begin(Envelope(before, review), before, &error) && !incomplete.RefineIncoming({firstProof}, &error) &&
        !incomplete.indeterminate(), "partial refinement cannot establish any unpack boundary");
    auto changedProof = firstProof; changedProof.archive.fileIdentity = "different-file-proof";
    auto changedBatch = batch; changedBatch.archives = {changedProof.archive, laterProof.archive};
    P::TriggerEffectLedger changed;
    Require(changed.Begin(Envelope(before, review), before, &error) && changed.RefineIncoming({firstProof, laterProof}, &error) &&
        !changed.PreparePrimary(before.identity, changedBatch, &error) && !changed.indeterminate() &&
        error == "provider_trigger_incoming_unverified", "unretained archive identity is rejected before the boundary guard");
    // The boundary prerequisite does not relax the existing effect policy.
    auto autoDeconfigure = batch; autoDeconfigure.arguments.push_back("--auto-deconfigure");
    P::TriggerEffectLedger stillRefused;
    Require(stillRefused.Begin(Envelope(before, review), before, &error) && stillRefused.RefineIncoming({firstProof, laterProof}, &error) &&
        !stillRefused.PreparePrimary(before.identity, autoDeconfigure, &error) && !stillRefused.indeterminate() &&
        error == "provider_dpkg_effects_unknown", "existing auto-deconfiguration refusal remains before any child");
}
void AuthorizedUnpackOperandOrder() {
    const auto before = Point(Row("cache"), {{"cache:amd64", "interest-await cache-native\n"}}, {{"cache-native", "cache:amd64\n"}});
    auto review = Review(before); P::ReviewPolicy policy;
    auto &environment = policy.environment;
    environment.paths.dpkg = "/usr/bin/dpkg"; environment.paths.dpkgQuery = "/usr/bin/dpkg-query";
    environment.paths.dpkgDeb = "/usr/bin/dpkg-deb"; environment.paths.dpkgRoot = "/"; environment.paths.dpkgAdmin = "/var/lib/dpkg";
    environment.configurationIdentity = "config-v1"; environment.policyIdentity = "policy-v1"; environment.methodsIdentity = "methods-v1";
    environment.packageStateIdentity = before.packages.packageStateIdentity; environment.nativeArchitecture = "amd64";
    environment.registeredArchitectures = environment.acquisitionArchitectures = before.packages.registeredArchitectures;
    policy.layout = {"/", {"/var/jb"}}; policy.protectedDpkgOptions = {"--root=/", "--admindir=/var/lib/dpkg"};
    review.binding.providerIdentifier = "provider"; review.binding.session.assign(64, 'a');
    review.binding.configurationIdentity = environment.configurationIdentity; review.binding.policyIdentity = environment.policyIdentity;
    review.binding.cacheEpoch = review.binding.selectionRevision = 1; review.binding.review = "review-v1";
    review.transaction.registeredArchitectures = environment.registeredArchitectures;
    const auto archive = [&](const std::string &name, unsigned id) {
        const auto identity = CydiaAPT::BuildPackageIdentity(name, "amd64", "amd64", "amd64", CydiaAPT::MultiArchMode::None);
        review.transaction.installs.push_back(identity.routingName); review.transaction.packages[identity.routingName] = {identity, "2", name};
        P::ArchiveManifest value; value.identifier = name + "-archive"; value.package = {name, "2", "amd64"};
        value.sourceURI = "https://repository.invalid/"; value.sourceIndexIdentity = "SHA256:" + std::string(64, 'a');
        value.sourceDefinitionPath = "/etc/apt/sources.list.d/example.sources";
        value.sourceIndexPath = "/var/lib/apt/lists/repository.invalid_Packages"; value.sourceIndexURI = "https://repository.invalid/Packages";
        value.filename = "pool/" + name + ".deb"; value.recordOffset = id * 1024; value.recordSize = 512;
        value.path = "/cache/" + name + ".deb"; value.hashes = {{"SHA256", std::string(64, '1')}}; value.size = 4096; value.layout = policy.layout;
        return value;
    };
    const auto first = archive("alpha", 1), second = archive("beta", 2);
    review.execution.archives = {first, second};
    review.execution.actions = {Action(1, P::ExecutionAction::Unpack, first.package, first.identifier),
        Action(2, P::ExecutionAction::Unpack, second.package, second.identifier), Action(3, P::ExecutionAction::Configure, first.package),
        Action(4, P::ExecutionAction::Configure, second.package)};
    auto firstProof = Incoming(first), secondProof = Incoming(second);
    firstProof.archive.fileIdentity = "parent-file-proof:alpha"; secondProof.archive.fileIdentity = "parent-file-proof:beta";
    P::ParentExecutionEvidence evidence; evidence.binding = review.binding; evidence.frontendLockHeld = evidence.stateVerified = true;
    evidence.stateIdentity = review.binding.packageStateIdentity; evidence.statusDescriptor = 8;
    evidence.deconfigurationTargetsKnown = evidence.triggerTargetsKnown = true; evidence.archives = {firstProof.archive, secondProof.archive};
    P::ParentExecutionRequest request; request.binding = review.binding; request.batch = 1; request.action = P::ExecutionAction::Unpack;
    request.actions = {2, 1}; request.arguments = policy.protectedDpkgOptions;
    request.arguments.insert(request.arguments.end(), {"--status-fd", "8", "--no-triggers", "--unpack", second.path, first.path});
    P::ReviewAuthorization authorization; P::AuthorizedExecution ordered; std::string error;
    Require(authorization.Accept(review, policy, &error) && authorization.Authorize(request, evidence, &ordered, &error) &&
        ordered.actions == std::vector<std::uint64_t>({1, 2}) && ordered.archives.size() == 2 &&
        ordered.archives[0].archive.identifier == second.identifier && ordered.archives[1].archive.identifier == first.identifier,
        "genuine authorization sorts selected IDs while retaining validated requested archive operand order");
    // TransactionLease changes only each argv path value in place; manifests
    // and independently authorized operand order remain exactly as above.
    for (auto &argument : ordered.arguments) {
        if (argument == first.path) argument = "/retained/alpha.deb";
        else if (argument == second.path) argument = "/retained/beta.deb";
    }
    Require(ordered.arguments[ordered.arguments.size() - 2] == "/retained/beta.deb" && ordered.arguments.back() == "/retained/alpha.deb",
        "lease-style private argv substitution preserves second-then-first child order");
    firstProof.control.controls["pre-depends"] = "cache (>= 1)";
    P::TriggerEffectLedger denied;
    Require(denied.Begin(Envelope(before, review), before, &error) && denied.RefineIncoming({firstProof, secondProof}, &error) &&
        !denied.PreparePrimary(before.identity, ordered, &error) && !denied.indeterminate() &&
        error == "provider_trigger_predepends_batch_boundary", "sorted ID 1 is not the first child operand and its Pre-Depends requires a boundary");
    firstProof.control.controls["pre-depends"].clear(); secondProof.control.controls["pre-depends"] = "cache (>= 1)";
    P::TriggerEffectLedger allowed;
    Require(allowed.Begin(Envelope(before, review), before, &error) && allowed.RefineIncoming({secondProof, firstProof}, &error) &&
        allowed.PreparePrimary(before.identity, ordered, &error), "actual first operand ID 2 may have Pre-Depends even though sorted action IDs start with 1");
}
void ConfiguredVersions() {
    std::string error;
    for (const std::string previous : {std::string(), std::string("0")}) {
        auto before = Initial(); const auto original = before.identity;
        before.metadata.packages.at("waiting:all").configVersion = previous;
        Seal(&before, "state-1");
        Require(before.identity != original, "last-configured version is bound in checkpoint identity");
        auto after = Point(Row("cache", "1", "amd64", "installed", "same") + Row("cache", "1", "i386", "installed", "same") +
            Row("waiting", "1", "all") + Row("unrelated", "2", "all"), SharedDeclarations, SharedRegistry, "state-2");
        P::TriggerEffectLedger ledger; P::TriggerDrainPlan pass;
        Require(ledger.Begin(Envelope(before, Review(before)), before, &error) && ledger.NextDrain(before.identity, &pass, &error) &&
            ledger.SettleDrain(pass.pass, Success(), after, &error) && ledger.quiescent(),
            "successful drain can make an awaited historical or absent Config-Version synthesize current Version");
        auto incorporated = before;
        incorporated.packages.packages.at("waiting:all").status = P::DpkgPackageStatus::Installed;
        incorporated.packages.packages.at("waiting:all").triggersAwaited.clear(); Seal(&incorporated, "state-1");
        P::TriggerEffectLedger readOnly;
        Require(readOnly.Begin(Envelope(incorporated, Review(incorporated)), incorporated, &error) &&
            readOnly.NextDrain(incorporated.identity, &pass, &error) && readOnly.SettleDrain(pass.pass, Success(), after, &error),
            "read-only incorporated waiter retains disk historical version until actual native settlement");
        P::TriggerEffectLedger unrelated;
        Require(unrelated.Begin(Envelope(before, Review(before)), before, &error) && unrelated.NextDrain(before.identity, &pass, &error),
            "unrelated configured-version mutation fixture");
        after.metadata.packages.at("unrelated:all").configVersion = "1";
        after.metadata.packages.at("unrelated:all").diskStatus = P::DpkgPackageStatus::TriggersAwaited; Seal(&after, "state-2");
        Require(!unrelated.SettleDrain(pass.pass, Success(), after, &error), "drain cannot alter unrelated configured-version evidence");
    }
    auto before = Point(Row("target", "2", "all", "unpacked"), {}, {});
    before.metadata.packages.at("target:all").configVersion = "1"; Seal(&before, "state-1");
    auto review = Review(before); review.execution.actions = {Action(1, P::ExecutionAction::Configure, {"target", "2", "all"})};
    auto batch = Batch(1, P::ExecutionAction::Configure, {1});
    auto after = Point(Row("target", "2", "all"), {}, {}, "state-2");
    P::TriggerEffectLedger configured;
    Require(configured.Begin(Envelope(before, review), before, &error) && configured.PreparePrimary(before.identity, batch, &error) &&
        configured.Reconcile(batch, Success(), after, &error), "reviewed configure advances only target last-configured version");
    P::TriggerEffectLedger replaced;
    Require(replaced.Begin(Envelope(before, review), before, &error) && replaced.PreparePrimary(before.identity, batch, &error), "declaration identity fixture");
    after.metadata.packages.at("target:all").declarationIdentity.assign(64, 'e'); Seal(&after, "state-2");
    Require(!replaced.Reconcile(batch, Success(), after, &error), "configure cannot conceal declaration-file changes behind Config-Version transition");
}
void Parsers() {
    std::string error; std::vector<P::TriggerDeclaration> declarations;
    Require(P::ParseTriggerDeclarations(" # native comments\ninterest-await Cache.Refresh\ninterest-noawait Cache.Refresh\n"
        "activate-noawait /usr/share/icons\nactivate-await /usr/share/icons\n", &declarations, &error) && declarations.size() == 2 &&
        !declarations[0].await && declarations[1].await, "native declaration options and duplicate semantics");
    for (const auto &invalid : {"interest-await no-newline", "interest-await /bad//path\n", "interest-await cache_name\n",
        "unknown-action cache\n", "interest-await cache extra\n"})
        Require(!P::ParseTriggerDeclarations(invalid, &declarations, &error), "unsupported declaration cannot silently widen effects");
    auto point = Point(Row("portable", "2", "all"), {}, {}); std::map<std::string, P::TriggerPackageMetadata> packages;
    Require(P::ParseInstalledTriggerControl("Package: portable\nVersion: 2\nArchitecture: all\nStatus: install ok installed\n"
        "Depends: libc:any (>= 1),\n helper | alternative\n\n", point.packages, &packages, &error) &&
        packages.at("portable:all").controls.at("depends") == "libc:any (>= 1), helper | alternative" &&
        packages.at("portable:all").controls.at("multi-arch") == "no", "installed fields share canonical archive semantics");
    Require(!P::ParseInstalledTriggerControl("Package: portable\nVersion: 3\nArchitecture: all\nStatus: install ok installed\n\n",
        point.packages, &packages, &error), "raw status cannot silently change query version");
    Require(!P::ParseInstalledTriggerControl("Package: portable\nVersion: 2\nArchitecture: all\nStatus: hold ok installed\n\n",
        point.packages, &packages, &error), "read-only incorporation never changes wanted selection");
}
}
int main() {
    Parsers(); RepeatedDrains(); ReferenceOnlyDrains(); DeferredQueues(); Rejections(); IncomingAndPrimary(); PreDependsChildBoundaries(); AuthorizedUnpackOperandOrder(); ConfiguredVersions();
    std::cout << "apt-provider-trigger-effects tests passed\n";
}
