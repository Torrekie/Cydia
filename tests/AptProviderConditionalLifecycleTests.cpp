/* Combined pure lifecycle fixtures; every checkpoint/script/native identity is
 * synthetic. No capture factory, spawn, device or mutation permission occurs.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderConditionalDeconfiguration.hpp"
#include "Cydia/AptProviderRestorationTriggerDecision.hpp"
#include <algorithm>
#include <cstdlib>
#include <iostream>
namespace {
namespace P = CydiaAPT::Provider;
void Require(bool ok, const char *why) { if (!ok) { std::cerr << "[conditional-lifecycle] " << why << '\n'; std::exit(1); } }
std::string Hash(char value) { return std::string(64, value); }
std::string Row(const std::string &name, const std::string &version = "1", const std::string &phase = "installed",
    const std::string &pending = "", const std::string &awaited = "") {
    return name + '\t' + version + "\tamd64\tinstall ok " + phase + "\tno\t" + pending + '\t' + awaited + '\n';
}
std::map<std::string, std::string> Controls(const std::string &name) {
    std::map<std::string, std::string> controls; std::string error;
    const auto fields = name == "breaker" ? std::map<std::string, std::string>{{"breaks", "victim (<< 2)"}} :
        name == "victim" ? std::map<std::string, std::string>{{"depends", "lib"}} : std::map<std::string, std::string>();
    Require(CydiaPackages::CanonicalPackageEffectControlFields(fields, &controls, &error), "fixture controls"); return controls;
}
std::string Declaration(const std::string &name) {
    return name == "cache" ? "interest-await cache-native\n" : name == "breaker" ? "activate-await cache-native\n" : "";
}
P::TriggerEffectCheckpoint Point(const std::string &rows, const std::string &state) {
    P::TriggerEffectCheckpoint p; std::string error;
    Require(P::ParseDpkgState(rows, "amd64\n", "", state, &p.packages, &error), "actual-phase synthetic query");
    p.registry.synchronized = true; p.registry.evidenceIdentity = Hash('a'); p.metadata.evidenceIdentity = Hash('b');
    P::TriggerRegistryInput input; input.directoryPresent = true;
    input.files = {{"Lock", ""}, {"Unincorp", ""}, {"cache-native", "cache:amd64\n"}};
    Require(P::ParseTriggerRegistry(input, &p.registry.state, &error), "fixture registry");
    for (const auto &entry : p.packages.packages) {
        P::TriggerPackageMetadata m; m.package = entry.second.package; m.diskStatus = entry.second.status;
        m.controls = Controls(entry.second.package.package);
        if (m.diskStatus >= P::DpkgPackageStatus::TriggersAwaited) m.configVersion = m.package.version;
        else if (m.package.package == "victim") m.configVersion = "1";
        m.evidenceIdentity = Hash(m.diskStatus == P::DpkgPackageStatus::HalfConfigured ? 'e' :
            m.diskStatus == P::DpkgPackageStatus::Unpacked ? 'f' : 'c'); m.declarationIdentity = Hash('d');
        Require(CydiaPackages::Dpkg1237WrittenPackageEffectControlFieldOrder(m.controls, &m.dependencyOrder), "native status order fixture");
        m.dependencyOrderVerified = true; m.rawControlRecord = "Package: " + m.package.package + "\nVersion: " + m.package.version + "\n";
        Require(P::ParseTriggerDeclarations(Declaration(m.package.package), &m.declarations, &error), "fixture declarations");
        p.metadata.packages[entry.first] = std::move(m);
    }
    p.metadata.packageStateIdentity = state; p.identity = P::TriggerEffectCheckpointIdentity(p);
    Require(!p.identity.empty(), "sealed synthetic complete checkpoint"); return p;
}
P::RestorationCheckpoint Observation(const P::TriggerEffectCheckpoint &point) {
    P::RestorationCheckpoint r; r.identity = point.identity; r.deferredQueueEmpty = point.registry.state.deferred.empty();
    const auto &state = point.packages.packages.at("victim:amd64"); const auto &meta = point.metadata.packages.at("victim:amd64");
    P::RestorationObservation o; o.present = true; o.package = state.package; o.selection = state.selection; o.status = state.status;
    o.diskStatus = meta.diskStatus; o.configVersion = meta.configVersion; o.controlIdentity = meta.evidenceIdentity;
    o.scriptsIdentity = meta.evidenceIdentity; o.contentIdentity = Hash(state.package.version == "1" ? '1' : '2');
    o.scriptContentIdentity = Hash(state.package.version == "1" ? '3' : '4');
    o.triggersPending = state.triggersPending; o.triggersAwaited = state.triggersAwaited;
    r.packages["victim:amd64"] = o; return r;
}
P::ArchiveManifest Archive(const std::string &name) {
    P::ArchiveManifest a; a.identifier = name; a.package = {name, "2", "amd64"}; a.path = "/archives/" + name + ".deb";
    a.sourceURI = "https://example.invalid/"; a.sourceIndexIdentity = "SHA256:" + Hash('1');
    a.sourceDefinitionPath = "/etc/apt/sources.list"; a.sourceIndexPath = "/lists/Packages";
    a.sourceIndexURI = "https://example.invalid/Packages"; a.filename = name + ".deb"; a.recordSize = 200;
    a.hashes["SHA256"] = Hash('2'); a.size = 1024; a.layout.prefix = "/"; return a;
}
P::ReviewedAction Action(std::uint64_t id, P::ExecutionAction kind, P::ExecutionPackage package, const std::string &archive = "") {
    P::ReviewedAction a; a.identifier = id; a.action = kind; a.package = package; a.archive = archive; return a;
}
P::DeconfigurationAllowanceSet Approval(const P::TriggerEffectCheckpoint &initial) {
    P::DeconfigurationAllowanceSet a; a.primaryReview.transaction.registeredArchitectures = {"amd64"}; a.identity = Hash('a'); a.initialCheckpoint = initial.identity; a.nativeAuthorityIdentity = Hash('b');
    auto &r = a.primaryReview; r.binding.providerIdentifier = "fixture"; r.binding.session = Hash('1');
    r.binding.configurationIdentity = "configuration:fixture"; r.binding.policyIdentity = "policy:fixture";
    r.binding.packageStateIdentity = initial.packages.packageStateIdentity; r.binding.review = "review:fixture";
    r.binding.cacheEpoch = 1; r.binding.selectionRevision = 2;
    r.execution.archives = {Archive("breaker"), Archive("victim")};
    r.execution.actions = {Action(10, P::ExecutionAction::Unpack, {"breaker", "2", "amd64"}, "breaker"),
        Action(20, P::ExecutionAction::Unpack, {"victim", "2", "amd64"}, "victim"),
        Action(40, P::ExecutionAction::Configure, {"victim", "2", "amd64"}),
        Action(50, P::ExecutionAction::Configure, {"breaker", "2", "amd64"})};
    P::DeconfigurationAllowance d; d.installed = {"victim", "1", "amd64"}; d.selection = P::DpkgSelection::Install;
    d.initialStatus = d.diskStatus = P::DpkgPackageStatus::Installed; d.configVersion = "1";
    const auto o = Observation(initial).packages.at("victim:amd64"); d.installedControlIdentity = o.controlIdentity; d.installedScriptsIdentity = o.scriptsIdentity;
    P::DeconfigurationCause c; c.unpackAction = 10; c.archive = "breaker"; c.canonicalRelation = "victim (<< 2)"; c.comparedVersion = "1";
    d.causes.push_back(c); d.endpoint.action = 40; d.endpoint.precedingUnpack = 20; d.endpoint.package = {"victim", "2", "amd64"};
    a.allowances["victim:amd64@1"] = d; return a;
}
P::VerifiedArchiveControlEvidence Incoming(const P::ArchiveManifest &archive) {
    P::VerifiedArchiveControlEvidence p; p.archive.archive = archive; p.archive.fileIdentity = "sha256:" + Hash('3');
    p.archive.inspection.complete = p.archive.inspection.identityVerified = true;
    p.control.complete = p.control.triggersPresent = true; p.control.identity = {archive.package.package, "2", "amd64"};
    p.control.controls = Controls(archive.package.package); p.control.triggers = Declaration(archive.package.package);
    p.control.dependencyOrderVerified = true; p.control.rawControlRecord = "Package: " + archive.package.package + "\nVersion: 2\n";
    Require(CydiaPackages::Dpkg1237WrittenPackageEffectControlFieldOrder(p.control.controls, &p.control.dependencyOrder), "fixture archive native order"); return p;
}
P::AuthorizedExecution Batch(const P::DeconfigurationAllowanceSet &a, std::uint64_t number, std::uint64_t id) {
    P::AuthorizedExecution b; b.batch = number; b.actions = {id}; b.arguments = {"--no-triggers"}; b.conditionalDeconfigurationIdentity = a.identity;
    for (const auto &action : a.primaryReview.execution.actions) if (action.identifier == id) {
        b.action = action.action;
        if (b.action == P::ExecutionAction::Unpack) for (const auto &archive : a.primaryReview.execution.archives)
            if (archive.identifier == action.archive) b.archives.push_back(Incoming(archive).archive);
    }
    return b;
}
P::ParentExecutionReply Success() { P::ParentExecutionReply r; r.started = true; r.exitCode = 0; return r; }
P::ConditionalDeconfigurationTransition Transition(const P::DeconfigurationAllowanceSet &a, const P::AuthorizedExecution &batch,
    const P::TriggerEffectCheckpoint &before, const P::TriggerEffectCheckpoint &after) {
    P::ConditionalDeconfigurationTransition t; t.before = Observation(before); t.after = Observation(after); t.child.child = Success();
    t.admission.approvalIdentity = a.identity; t.admission.checkpointIdentity = before.identity;
    t.admission.stateIdentity = before.packages.packageStateIdentity; t.admission.batch = batch.batch; t.admission.actions = batch.actions;
    if (batch.actions == std::vector<std::uint64_t>{10}) t.admission.causes.push_back({{"victim", "1", "amd64"}, a.allowances.at("victim:amd64@1").causes.front()});
    if (batch.actions == std::vector<std::uint64_t>{20}) {
        P::RestorationSuccessorProof p; p.unpackAction = 20; p.oldGeneration = "victim:amd64@1"; p.archive = "victim";
        p.retainedArchiveIdentity = "sha256:" + Hash('3'); p.beforeCheckpoint = before.identity; p.afterCheckpoint = after.identity;
        const auto &o = t.after.packages.at("victim:amd64"); p.installedControlIdentity = o.controlIdentity; p.installedScriptsIdentity = o.scriptsIdentity;
        p.installedContentIdentity = o.contentIdentity; p.installedScriptContentIdentity = o.scriptContentIdentity; p.installedMultiArch = "no";
        t.successors.push_back(p);
    }
    return t;
}
void CombinedActualPhases() {
    const auto initial = Point(Row("victim") + Row("cache") + Row("lib"), "state:initial"); const auto a = Approval(initial);
    P::TriggerEffectEnvelope envelope; P::TriggerEffectLedger effects; P::RestorationDebtLedger debt; std::string error;
    Require(P::BuildTriggerEffectEnvelope(a.primaryReview, initial, &envelope, &error, a.nativeAuthorityIdentity) &&
        effects.Begin(envelope, initial, &error) && effects.RefineIncoming({Incoming(a.primaryReview.execution.archives[0]), Incoming(a.primaryReview.execution.archives[1])}, &error) &&
        debt.Begin(a, Observation(initial), &error), "paired trigger/debt initialization creates no effects");
    auto current = initial;
    const auto settle = [&](std::uint64_t number, std::uint64_t id, const P::TriggerEffectCheckpoint &next) {
        const auto batch = Batch(a, number, id); const auto transition = Transition(a, batch, current, next);
        Require(effects.PreparePrimaryWithConditional(current.identity, batch, a, &error) && debt.PreparePrimary(current.identity, batch, &error), "reserve exact primary only");
        auto trialEffects = effects; auto trialDebt = debt;
        Require(trialEffects.ReconcileWithConditional(batch, Success(), next, a, debt, transition, &error) &&
            trialDebt.SettlePrimary(batch.batch, transition.child, transition.after, transition.successors, &error), "full graph/state/debt settlement uses observed phases");
        effects = std::move(trialEffects); debt = std::move(trialDebt); current = next;
    };
    settle(1, 10, Point(Row("victim", "1", "half-configured") + Row("cache", "1", "triggers-pending", "cache-native") + Row("lib") +
        Row("breaker", "2", "unpacked", "", "cache:amd64"), "state:half"));
    Require(debt.debts().at("victim:amd64@1").phase == P::RestorationDebtPhase::HalfConfigured &&
        current.packages.packages.at("victim:amd64").status == P::DpkgPackageStatus::HalfConfigured &&
        P::DecideRestorationTriggerWork(a, debt, current).work == P::RestorationTriggerWork::Defer, "real HalfConfigured debt defers triggers");
    settle(2, 20, Point(Row("victim", "2", "unpacked") + Row("cache", "1", "triggers-pending", "cache-native") + Row("lib") +
        Row("breaker", "2", "unpacked", "", "cache:amd64"), "state:successor"));
    Require(P::DecideRestorationTriggerWork(a, debt, current).work == P::RestorationTriggerWork::Defer &&
        debt.debts().at("victim:amd64@1").phase == P::RestorationDebtPhase::SuccessorUnpacked, "successor Unpacked is not treated as Installed");
    settle(3, 40, Point(Row("victim", "2", "triggers-awaited", "", "cache:amd64") + Row("cache", "1", "triggers-pending", "cache-native") +
        Row("lib") + Row("breaker", "2", "unpacked", "", "cache:amd64"), "state:configured"));
    Require(P::DecideRestorationTriggerWork(a, debt, current).work == P::RestorationTriggerWork::Drain && !debt.complete(), "real Configure permits required effect drain");
    P::TriggerDrainPlan plan; Require(effects.NextDrain(current.identity, &plan, &error) && plan.targets.size() == 1, "complete real pending pool");
    const auto drained = Point(Row("victim", "2") + Row("cache") + Row("lib") + Row("breaker", "2", "unpacked"), "state:drained");
    P::RestorationChildResult observed; observed.child = Success();
    Require(effects.SettleDrain(plan.pass, Success(), drained, &error) && debt.ObserveEffects(current.identity, observed, Observation(drained), &error), "actual successful drain clears configured debt");
    current = drained; Require(debt.debts().empty() && !debt.complete() && effects.quiescent(), "zero debt alone never completes remaining primary");
    settle(4, 50, Point(Row("victim", "2") + Row("cache") + Row("lib") + Row("breaker", "2"), "state:done"));
    Require(debt.complete() && effects.quiescent() && debt.completedActions() == 4, "every exact primary plus zero debt/quiescence required before owner CAS");
    auto changed = Observation(current); changed.packages.at("victim:amd64").scriptContentIdentity = Hash('f');
    Require(!P::SameRestorationCheckpoint(changed, Observation(current)), "unchanged trigger identity cannot conceal script changes at final CAS");
    auto stale = current; stale.identity = Hash('f');
    Require(P::DecideRestorationTriggerWork(a, debt, stale).work == P::RestorationTriggerWork::Refuse, "stale checkpoint refuses scheduling");
}
void RejectUnobservedOrUnrelatedEffects() {
    const auto initial = Point(Row("victim") + Row("cache") + Row("lib"), "state:initial"); const auto a = Approval(initial);
    const auto batch = Batch(a, 1, 10); std::string error;
    const auto validAfter = Point(Row("victim", "1", "half-configured") + Row("cache", "1", "triggers-pending", "cache-native") +
        Row("lib") + Row("breaker", "2", "unpacked", "", "cache:amd64"), "state:half");
    for (unsigned variant = 0; variant != 5; ++variant) {
        P::TriggerEffectEnvelope envelope; P::TriggerEffectLedger effects; P::RestorationDebtLedger debt;
        Require(P::BuildTriggerEffectEnvelope(a.primaryReview, initial, &envelope, &error, a.nativeAuthorityIdentity) &&
            effects.Begin(envelope, initial, &error) && effects.RefineIncoming({Incoming(a.primaryReview.execution.archives[0]), Incoming(a.primaryReview.execution.archives[1])}, &error) &&
            debt.Begin(a, Observation(initial), &error) && effects.PreparePrimaryWithConditional(initial.identity, batch, a, &error) &&
            debt.PreparePrimary(initial.identity, batch, &error), "prepare independent refusal case");
        auto after = validAfter; auto transition = Transition(a, batch, initial, after);
        if (variant == 0) {
            after = Point(Row("victim") + Row("cache", "1", "triggers-pending", "cache-native") + Row("lib") +
                Row("breaker", "2", "unpacked", "", "cache:amd64"), "state:fake-installed");
            transition.after = Observation(after);
        }
        if (variant == 1) {
            after = Point(Row("victim", "1", "half-configured") + Row("cache", "1", "triggers-pending", "cache-native") +
                Row("lib", "1", "half-configured") + Row("breaker", "2", "unpacked", "", "cache:amd64"), "state:unapproved");
            transition.after = Observation(after);
        }
        if (variant == 2) transition.admission.causes.front().cause.comparedVersion = "9";
        if (variant == 3) transition.child.cancelled = true;
        if (variant == 4) transition.child.child.started = false;
        auto trial = effects;
        Require(!trial.ReconcileWithConditional(batch, Success(), after, a, debt, transition, &error) &&
            debt.completedActions() == 0 && debt.debts().empty() && debt.stateIdentity() == initial.identity,
            "fake phase normalization/unrelated deconfiguration/changed cause/cancel/unstarted child cannot publish debt or primary progress");
    }
}

}
int main() { CombinedActualPhases(); RejectUnobservedOrUnrelatedEffects(); std::cout << "conditional lifecycle fixtures passed\n"; }
