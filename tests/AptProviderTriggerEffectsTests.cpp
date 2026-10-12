/* Parent-owned finite effects: pure fixtures, no dpkg child or host mutation.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderTriggerEffects.hpp"
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
    Parsers(); RepeatedDrains(); DeferredQueues(); Rejections(); IncomingAndPrimary();
    std::cout << "apt-provider-trigger-effects tests passed\n";
}
