/* Pure parent-evidence fixtures; no native capture, execution or activation.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderRestorationDebt.hpp"
#include <algorithm>
#include <cstdlib>
#include <iostream>

namespace {
namespace P = CydiaAPT::Provider;
using Phase = P::DpkgPackageStatus;
void Require(bool value, const char *why) {
    if (!value) { std::cerr << "[restoration-debt] " << why << '\n'; std::exit(1); }
}
std::string Hash(char c) { return std::string(64, c); }
const std::string Slot = "victim:amd64", Old = "victim:amd64@1";
P::ReviewedAction Action(std::uint64_t id, P::ExecutionAction kind, P::ExecutionPackage package, const std::string &archive = "") {
    P::ReviewedAction a; a.identifier = id; a.action = kind; a.package = package; a.archive = archive; return a;
}
P::ArchiveManifest Archive(const std::string &id, P::ExecutionPackage package) {
    P::ArchiveManifest a; a.identifier = id; a.package = package; a.path = "/archives/" + id + ".deb";
    a.sourceURI = "https://example.invalid/"; a.sourceIndexIdentity = "SHA256:" + Hash('e');
    a.sourceDefinitionPath = "/etc/apt/sources.list"; a.sourceIndexPath = "/lists/Packages";
    a.sourceIndexURI = "https://example.invalid/Packages"; a.filename = id + ".deb"; a.recordSize = 200;
    a.hashes["SHA256"] = Hash('f'); a.size = 1024; a.layout.prefix = "/"; return a;
}
P::DeconfigurationAllowanceSet Approval(bool successor = true, P::ExecutionAction endpoint = P::ExecutionAction::Configure) {
    P::DeconfigurationAllowanceSet a; a.identity = Hash('a'); a.initialCheckpoint = Hash('b'); a.nativeAuthorityIdentity = Hash('c');
    auto &r = a.primaryReview; r.binding.providerIdentifier = "fixture"; r.binding.session = Hash('1');
    r.binding.configurationIdentity = "configuration:fixture"; r.binding.policyIdentity = "policy:fixture";
    r.binding.packageStateIdentity = "state:fixture"; r.binding.review = "review:fixture"; r.binding.cacheEpoch = 1; r.binding.selectionRevision = 2;
    r.execution.archives.push_back(Archive("alpha", {"alpha", "2", "amd64"}));
    r.execution.actions.push_back(Action(10, P::ExecutionAction::Unpack, {"alpha", "2", "amd64"}, "alpha"));
    if (successor) {
        r.execution.archives.push_back(Archive("victim", {"victim", "2", "amd64"}));
        r.execution.actions.push_back(Action(20, P::ExecutionAction::Unpack, {"victim", "2", "amd64"}, "victim"));
    }
    const P::ExecutionPackage target{"victim", successor ? "2" : "1", "amd64"};
    r.execution.actions.push_back(Action(40, endpoint, target));
    if (endpoint == P::ExecutionAction::Remove) r.execution.actions.push_back(Action(41, P::ExecutionAction::Purge, target));
    r.execution.actions.push_back(Action(50, P::ExecutionAction::Configure, {"alpha", "2", "amd64"}));
    P::DeconfigurationAllowance d; d.installed = {"victim", "1", "amd64"}; d.selection = P::DpkgSelection::Hold;
    d.initialStatus = d.diskStatus = Phase::Installed; d.configVersion = "1";
    d.installedControlIdentity = Hash('d'); d.installedScriptsIdentity = Hash('e');
    P::DeconfigurationCause c; c.unpackAction = 10; c.archive = "alpha"; c.canonicalRelation = "victim (<< 2)"; c.comparedVersion = "1";
    d.causes.push_back(c); d.endpoint.action = 40; d.endpoint.precedingUnpack = successor ? 20 : 0; d.endpoint.kind = endpoint; d.endpoint.package = target;
    a.allowances[Old] = d; return a;
}
P::RestorationCheckpoint Initial() {
    P::RestorationCheckpoint p; p.identity = Hash('b'); p.deferredQueueEmpty = true;
    P::RestorationObservation o; o.present = true; o.package = {"victim", "1", "amd64"}; o.selection = P::DpkgSelection::Hold;
    o.status = o.diskStatus = Phase::Installed; o.configVersion = "1"; o.controlIdentity = Hash('d'); o.scriptsIdentity = Hash('e');
    o.contentIdentity = Hash('f'); o.scriptContentIdentity = Hash('0'); p.packages[Slot] = o; return p;
}
P::RestorationCheckpoint Changed(P::RestorationCheckpoint p, char identity, Phase phase, const std::string &version = "1") {
    p.identity = Hash(identity); auto &o = p.packages.at(Slot); o.status = o.diskStatus = phase; o.package.version = version;
    if (phase == Phase::Installed || phase == Phase::TriggersPending) o.configVersion = version;
    o.controlIdentity = Hash(identity); o.scriptsIdentity = Hash(identity);
    o.triggersPending.clear(); o.triggersAwaited.clear();
    if (phase == Phase::TriggersPending) o.triggersPending = {"fixture-trigger"};
    if (phase == Phase::TriggersAwaited) o.triggersAwaited = {"recipient:amd64"};
    return p;
}
P::RestorationChildResult Success() { P::RestorationChildResult r; r.child.started = true; r.child.exitCode = 0; return r; }
P::AuthorizedExecution Batch(const P::DeconfigurationAllowanceSet &a, std::uint64_t number, std::initializer_list<std::uint64_t> ids) {
    P::AuthorizedExecution b; b.batch = number; b.actions = ids;
    for (const auto &action : a.primaryReview.execution.actions) if (std::find(ids.begin(), ids.end(), action.identifier) != ids.end()) {
        b.action = action.action;
        if (action.action == P::ExecutionAction::Unpack) for (const auto &archive : a.primaryReview.execution.archives) if (archive.identifier == action.archive) {
            P::VerifiedArchiveEvidence v; v.archive = archive; v.fileIdentity = "sha256:" + Hash('3'); b.archives.push_back(v);
        }
    }
    return b;
}
P::RestorationSuccessorProof Proof(const P::RestorationCheckpoint &before, const P::RestorationCheckpoint &after) {
    P::RestorationSuccessorProof p; p.unpackAction = 20; p.oldGeneration = Old; p.archive = "victim"; p.retainedArchiveIdentity = "sha256:" + Hash('3');
    p.beforeCheckpoint = before.identity; p.afterCheckpoint = after.identity; const auto &o = after.packages.at(Slot);
    p.installedControlIdentity = o.controlIdentity; p.installedScriptsIdentity = o.scriptsIdentity;
    p.installedContentIdentity = o.contentIdentity; p.installedScriptContentIdentity = o.scriptContentIdentity; return p;
}
void Execute(P::RestorationDebtLedger &ledger, const P::DeconfigurationAllowanceSet &approval, std::uint64_t batch,
    std::initializer_list<std::uint64_t> ids, const P::RestorationCheckpoint &after,
    const std::vector<P::RestorationSuccessorProof> &proof = {}) {
    std::string error;
    Require(ledger.PreparePrimary(ledger.stateIdentity(), Batch(approval, batch, ids), &error), "prepare exact next reviewed primary");
    Require(ledger.SettlePrimary(batch, Success(), after, proof, &error), "settle successful observed primary");
}
void SuccessorAndDelayedRestoration() {
    const auto a = Approval(); auto initial = Initial(); P::RestorationDebtLedger ledger; std::string error;
    Require(ledger.Begin(a, initial, &error) && ledger.debts().empty(), "allowance alone creates no debt");
    const auto half = Changed(initial, '1', Phase::HalfConfigured);
    Execute(ledger, a, 1, {10}, half);
    Require(ledger.debts().size() == 1 && ledger.debts().at(Old).phase == P::RestorationDebtPhase::HalfConfigured &&
        ledger.debts().at(Old).causeAction == 10 && !ledger.complete(), "only observed old-generation half-configured debt is recorded");
    auto unpacked = Changed(half, '2', Phase::Unpacked, "2"); unpacked.packages.at(Slot).contentIdentity = Hash('4');
    unpacked.packages.at(Slot).scriptContentIdentity = Hash('5');
    Execute(ledger, a, 2, {20}, unpacked, {Proof(half, unpacked)});
    Require(ledger.debts().at(Old).current.version == "2" && ledger.debts().at(Old).original.version == "1" &&
        ledger.debts().at(Old).phase == P::RestorationDebtPhase::SuccessorUnpacked, "exact successor transfer keeps original debt and endpoint");
    auto awaited = Changed(unpacked, '6', Phase::TriggersAwaited, "2");
    Execute(ledger, a, 3, {40}, awaited);
    Require(ledger.debts().at(Old).configureAction == 40 && !ledger.complete(), "successful Configure with awaited triggers retains debt");
    auto pending = Changed(awaited, '7', Phase::TriggersPending, "2");
    Require(ledger.ObserveEffects(awaited.identity, Success(), pending, &error) && !ledger.debts().empty(), "pending trigger checkpoint cannot clear debt");
    auto installed = Changed(pending, '8', Phase::Installed, "2"); installed.deferredQueueEmpty = false;
    Require(ledger.ObserveEffects(pending.identity, Success(), installed, &error) && !ledger.debts().empty(), "global deferred work prevents premature settlement");
    auto settled = installed; settled.identity = Hash('9'); settled.deferredQueueEmpty = true;
    Require(ledger.ObserveEffects(installed.identity, Success(), settled, &error) && ledger.debts().empty() && !ledger.complete(),
        "verified incorporation closes configured debt but does not complete unrelated primary IDs");
    auto last = settled; last.identity = Hash('a'); Execute(ledger, a, 4, {50}, last);
    Require(ledger.complete() && ledger.completedActions() == 4, "zero debt and every exact primary are necessary for bookkeeping completion");
}
void RemovalDoesNotCompletePurge() {
    const auto a = Approval(false, P::ExecutionAction::Remove); P::RestorationDebtLedger ledger; std::string error;
    Require(ledger.Begin(a, Initial(), &error), "begin removal endpoint"); auto half = Changed(Initial(), '1', Phase::HalfConfigured);
    Execute(ledger, a, 1, {10}, half);
    auto removed = Changed(half, '2', Phase::ConfigFiles); removed.packages.at(Slot).selection = P::DpkgSelection::Deinstall;
    Execute(ledger, a, 2, {40}, removed);
    Require(ledger.debts().empty() && !ledger.complete() && ledger.completedActions() == 2, "Remove closes debt without completing later Purge");
    auto purged = removed; purged.identity = Hash('3'); purged.packages.at(Slot) = P::RestorationObservation();
    Execute(ledger, a, 3, {41}, purged);
    auto last = purged; last.identity = Hash('4'); Execute(ledger, a, 4, {50}, last);
    Require(ledger.complete(), "explicit Purge and remaining primary are still required");
}
void PurgeAndEffectBudget() {
    const auto a = Approval(false, P::ExecutionAction::Purge); P::RestorationDebtLedger ledger; std::string error;
    Require(ledger.Begin(a, Initial(), &error), "begin exact Purge endpoint");
    const auto half = Changed(Initial(), '1', Phase::HalfConfigured); Execute(ledger, a, 1, {10}, half);
    auto absent = half; absent.identity = Hash('2'); absent.packages.at(Slot) = P::RestorationObservation();
    Execute(ledger, a, 2, {40}, absent);
    Require(ledger.debts().empty() && !ledger.complete(), "exact successful Purge terminal absence discharges debt only");
    auto empty = Approval(false); empty.allowances.clear(); P::RestorationCheckpoint p; p.identity = empty.initialCheckpoint;
    P::RestorationDebtLedger bounded; Require(bounded.Begin(empty, p, &error), "begin bounded effect observer");
    for (unsigned i = 0; i < P::MaximumTriggerPassesPerTransaction; ++i) {
        auto next = p; next.identity = Hash(i % 2 ? '1' : '2');
        Require(bounded.ObserveEffects(p.identity, Success(), next, &error), "bounded verified parent effect checkpoint"); p = next;
    }
    auto next = p; next.identity = Hash('3');
    Require(!bounded.ObserveEffects(p.identity, Success(), next, &error) && !bounded.active() &&
        bounded.completedActions() == 0 && bounded.stateIdentity() == p.identity, "effect observation budget retires atomically");
}
void FailuresAreAtomic() {
    for (unsigned mode = 0; mode < 4; ++mode) {
        const auto a = Approval(false); P::RestorationDebtLedger ledger; std::string error;
        Require(ledger.Begin(a, Initial(), &error), "begin failure fixture"); auto half = Changed(Initial(), '1', Phase::HalfConfigured);
        Execute(ledger, a, 1, {10}, half); Require(ledger.PreparePrimary(half.identity, Batch(a, 2, {40}), &error), "prepare restore");
        auto reply = Success(); if (mode == 0) reply.child.exitCode = 1; if (mode == 1) reply.cancelled = true;
        if (mode == 2) reply.uncertain = true; if (mode == 3) reply.child.started = false;
        Require(!ledger.SettlePrimary(2, reply, Changed(half, '2', Phase::Installed), {}, &error) && !ledger.active() &&
            ledger.debts().size() == 1 && ledger.completedActions() == 1 && ledger.stateIdentity() == half.identity && !ledger.complete(),
            "failed/cancelled/uncertain/unstarted child cannot clear debt or complete endpoint");
        Require(!ledger.PreparePrimary(half.identity, Batch(a, 2, {40}), &error), "retired ledger cannot retry");
    }
    const auto a = Approval(); std::string error;
    for (unsigned mode = 0; mode < 7; ++mode) {
        P::RestorationDebtLedger ledger; Require(ledger.Begin(a, Initial(), &error), "begin malformed successor fixture");
        const auto half = Changed(Initial(), '1', Phase::HalfConfigured); Execute(ledger, a, 1, {10}, half);
        auto next = Changed(half, '2', Phase::Unpacked, "2"); auto proof = Proof(half, next);
        if (mode == 0) proof.retainedArchiveIdentity = "sha256:" + Hash('4');
        if (mode == 1) proof.unpackAction = 10;
        if (mode == 2) proof.beforeCheckpoint = Hash('e');
        if (mode == 3) next.packages.at(Slot).package.version = "3";
        if (mode == 4) next.packages.at(Slot).configVersion = "0.5";
        if (mode == 5) proof.installedScriptContentIdentity = Hash('c');
        if (mode == 6) next.packages.at(Slot).status = Phase::HalfConfigured;
        Require(ledger.PreparePrimary(half.identity, Batch(a, 2, {20}), &error), "prepare exact successor");
        Require(!ledger.SettlePrimary(2, Success(), next, {proof}, &error) && ledger.indeterminate() &&
            ledger.debts().at(Old).current.version == "1" && ledger.completedActions() == 1 && ledger.stateIdentity() == half.identity,
            "bad successor history/generation/retained proof refuses without partial transfer");
    }
}
void UnusedAllowanceConfigure() {
    for (const auto phase : {Phase::Installed, Phase::TriggersPending, Phase::TriggersAwaited}) {
        auto a = Approval(false); auto initial = Changed(Initial(), 'b', phase);
        if (phase == Phase::TriggersAwaited) initial.packages.at(Slot).configVersion = "0.9";
        auto &allowance = a.allowances.at(Old); const auto &observed = initial.packages.at(Slot);
        allowance.initialStatus = observed.status; allowance.diskStatus = observed.diskStatus; allowance.configVersion = observed.configVersion;
        allowance.installedControlIdentity = observed.controlIdentity; allowance.installedScriptsIdentity = observed.scriptsIdentity;
        for (unsigned transition = 0; transition < 2; ++transition) {
            P::RestorationDebtLedger ledger; std::string error;
            Require(ledger.Begin(a, initial, &error), "begin unused installed/pending/awaited allowance");
            auto caused = initial; caused.identity = Hash('1'); Execute(ledger, a, 1, {10}, caused);
            auto after = transition ? Changed(caused, '2', Phase::Installed) : caused; after.identity = Hash('2');
            // An unchanged Installed no-op keeps the same phase-bound metadata
            // identities; synthetic rehashes with no changed inputs refuse.
            if (phase == Phase::Installed) after = caused;
            after.identity = Hash('2'); Execute(ledger, a, 2, {40}, after);
            Require(ledger.debts().empty() && ledger.completedActions() == 2 && !ledger.complete(),
                "unused Configure no-op/trigger transition completes its ID without counting restoration");
            after.identity = Hash('3'); Execute(ledger, a, 3, {50}, after);
            Require(ledger.complete(), "unused allowance has no invented restoration obligation");
        }
    }
    for (unsigned changed = 0; changed < 4; ++changed) {
        const auto a = Approval(false); P::RestorationDebtLedger ledger; std::string error;
        Require(ledger.Begin(a, Initial(), &error), "begin refused unused endpoint mutation");
        auto cause = Initial(); cause.identity = Hash('1'); Execute(ledger, a, 1, {10}, cause);
        auto next = cause; next.identity = Hash('2'); auto &o = next.packages.at(Slot);
        if (changed == 0) o.scriptContentIdentity = Hash('6');
        if (changed == 1) { o.package.version = "2"; o.configVersion = "2"; }
        if (changed == 2) o.selection = P::DpkgSelection::Install;
        if (changed == 3) o.controlIdentity = Hash('7');
        Require(ledger.PreparePrimary(cause.identity, Batch(a, 2, {40}), &error), "prepare unused exact Configure endpoint");
        Require(!ledger.SettlePrimary(2, Success(), next, {}, &error) && ledger.debts().empty() &&
            ledger.completedActions() == 1 && ledger.stateIdentity() == cause.identity,
            "unused allowance cannot authorize changed script/generation/selection/metadata");
    }
}
void PrimaryDeferredSettlementAndUnconfiguredNoOp() {
    const auto a = Approval(false); P::RestorationDebtLedger ledger; std::string error;
    Require(ledger.Begin(a, Initial(), &error), "begin primary deferred settlement");
    const auto half = Changed(Initial(), '1', Phase::HalfConfigured); Execute(ledger, a, 1, {10}, half);
    auto configured = Changed(half, '2', Phase::Installed); configured.deferredQueueEmpty = false;
    Execute(ledger, a, 2, {40}, configured);
    Require(ledger.debts().size() == 1 && ledger.debts().at(Old).configureAction == 40, "deferred queue retains an actually configured debtor");
    auto settled = configured; settled.identity = Hash('3'); settled.deferredQueueEmpty = true;
    Execute(ledger, a, 3, {50}, settled);
    Require(ledger.complete() && ledger.debts().empty(), "unrelated verified primary may settle only the queue without fabricating package state");

    const auto upgrade = Approval(); P::RestorationDebtLedger unused;
    Require(unused.Begin(upgrade, Initial(), &error), "begin unused successor allowance");
    auto unchanged = Initial(); unchanged.identity = Hash('1'); Execute(unused, upgrade, 1, {10}, unchanged);
    auto unpacked = Changed(unchanged, '2', Phase::Unpacked, "2");
    Execute(unused, upgrade, 2, {20}, unpacked, {Proof(unchanged, unpacked)});
    auto noop = unpacked; noop.identity = Hash('3');
    Require(unused.PreparePrimary(unpacked.identity, Batch(upgrade, 3, {40}), &error), "prepare unconfigured primary endpoint");
    Require(!unused.SettlePrimary(3, Success(), noop, {}, &error) && unused.completedActions() == 2 && unused.debts().empty(),
        "no debt does not allow an Unpacked Configure no-op to complete its ordinary obligation");
}
void NoInventedRestorationOrDebt() {
    const auto a = Approval(false); std::string error;
    {
        P::RestorationDebtLedger ledger; auto initial = Initial(); Require(ledger.Begin(a, initial, &error), "begin unused allowance");
        initial.identity = Hash('1'); Execute(ledger, a, 1, {10}, initial);
        Require(ledger.debts().empty(), "unused prediction is not a debt or synthetic action");
    }
    {
        auto malformed = a; malformed.allowances.at(Old).initialStatus = Phase::HalfConfigured;
        auto historical = Changed(Initial(), 'b', Phase::HalfConfigured); malformed.allowances.at(Old).diskStatus = Phase::HalfConfigured;
        malformed.allowances.at(Old).installedControlIdentity = historical.packages.at(Slot).controlIdentity;
        malformed.allowances.at(Old).installedScriptsIdentity = historical.packages.at(Slot).scriptsIdentity;
        P::RestorationDebtLedger ledger;
        Require(!ledger.Begin(malformed, historical, &error) && ledger.debts().empty(), "historical half-configured is not an initial allowance");
    }
    for (unsigned mode = 0; mode < 3; ++mode) {
        P::RestorationDebtLedger ledger; Require(ledger.Begin(a, Initial(), &error), "begin no fabricated restore");
        const auto half = Changed(Initial(), '1', Phase::HalfConfigured); Execute(ledger, a, 1, {10}, half);
        auto next = Changed(half, '2', mode == 0 ? Phase::Installed : Phase::HalfConfigured);
        if (mode == 1) next.packages.at(Slot).scriptContentIdentity = Hash('6');
        if (mode == 2) next.packages.at(Slot).configVersion = "0.5";
        Require(!ledger.ObserveEffects(half.identity, Success(), next, &error) && ledger.debts().size() == 1,
            "trigger-only work cannot invent configure, replace scripts or rewrite configured history");
    }
    {
        const auto upgraded = Approval(); P::RestorationDebtLedger ledger; Require(ledger.Begin(upgraded, Initial(), &error), "begin boundary fixture");
        Require(!ledger.PreparePrimary(ledger.stateIdentity(), Batch(upgraded, 1, {10, 20}), &error) && ledger.completedActions() == 0,
            "cause and successor in one child need an actual observation boundary");
    }
    {
        P::RestorationDebtLedger ledger; Require(ledger.Begin(a, Initial(), &error), "begin ordering fixture");
        Require(!ledger.PreparePrimary(ledger.stateIdentity(), Batch(a, 1, {40}), &error), "endpoint cannot skip preceding reviewed cause");
    }
}
void EmptyAllowanceAndBounds() {
    auto a = Approval(false); a.allowances.clear(); P::RestorationCheckpoint p; p.identity = a.initialCheckpoint;
    P::RestorationDebtLedger ledger; std::string error;
    Require(ledger.Begin(a, p, &error) && !ledger.complete(), "empty pool still retains all primary obligations");
    auto next = p; next.identity = Hash('1'); Execute(ledger, a, 1, {10}, next);
    next.identity = Hash('2'); Execute(ledger, a, 2, {40}, next);
    next.identity = Hash('3'); Execute(ledger, a, 3, {50}, next);
    Require(ledger.complete(), "empty pool completes only after exact primary sequence");
    auto bad = Initial(); bad.packages.at(Slot).triggersPending = {std::string(65537, 'a')}; P::RestorationDebtLedger oversized;
    Require(!oversized.Begin(Approval(), bad, &error) && !oversized.active() && oversized.debts().empty(), "oversized observations fail before retention");
    bad = Initial(); bad.packages.at(Slot).triggersPending.resize(P::MaximumDeconfigurationCauses + 1, "trigger");
    P::RestorationDebtLedger many; Require(!many.Begin(Approval(), bad, &error), "trigger observation lists have a hard count bound");
    bad = Initial(); bad.packages.at(Slot).triggersPending.assign(160, std::string(65536, 'a'));
    P::RestorationDebtLedger total; Require(!total.Begin(Approval(), bad, &error), "aggregate observations refuse above byte bound");
}
void SuccessorTriggerPhase() {
    const auto a = Approval(); P::RestorationDebtLedger ledger; std::string error;
    Require(ledger.Begin(a, Initial(), &error), "begin native successor trigger phase");
    const auto half = Changed(Initial(), '1', Phase::HalfConfigured); Execute(ledger, a, 1, {10}, half);
    auto next = Changed(half, '2', Phase::TriggersPending, "2"); Execute(ledger, a, 2, {20}, next, {Proof(half, next)});
    Require(ledger.debts().at(Old).phase == P::RestorationDebtPhase::SuccessorUnpacked && !ledger.complete(),
        "actual successor trigger phase transfers debt without pretending restoration");
    Require(ledger.PreparePrimary(next.identity, Batch(a, 3, {40}), &error), "prepare pending-generation Configure claim");
    Require(!ledger.SettlePrimary(3, Success(), Changed(next, '3', Phase::Installed, "2"), {}, &error) &&
        ledger.debts().size() == 1 && ledger.completedActions() == 2,
        "native Configure from TriggersPending could be trigger-only and cannot prove restoration");
}
void AtomicMultiRecipientAndImmediateConfigure() {
    auto a = Approval(false); auto extra = a.allowances.at(Old); extra.installed.package = "zzsecond"; extra.endpoint.package.package = "zzsecond";
    extra.endpoint.action = 60; extra.causes[0].canonicalRelation = "zzsecond (<< 2)";
    a.allowances["zzsecond:amd64@1"] = extra;
    a.primaryReview.execution.actions.insert(a.primaryReview.execution.actions.begin() + 2,
        Action(60, P::ExecutionAction::Configure, {"zzsecond", "1", "amd64"}));
    auto initial = Initial(); initial.packages["zzsecond:amd64"] = initial.packages.at(Slot); initial.packages.at("zzsecond:amd64").package.package = "zzsecond";
    P::RestorationDebtLedger ledger; std::string error;
    Require(ledger.Begin(a, initial, &error), "begin multiple parent-selected recipients");
    auto next = Changed(initial, '1', Phase::HalfConfigured);
    next.packages.at("zzsecond:amd64").scriptContentIdentity = Hash('6');
    Require(ledger.PreparePrimary(initial.identity, Batch(a, 1, {10}), &error), "prepare shared reviewed cause");
    Require(!ledger.SettlePrimary(1, Success(), next, {}, &error) && ledger.debts().empty() && ledger.completedActions() == 0 &&
        ledger.stateIdentity() == initial.identity, "later recipient mismatch publishes no earlier recipient debt");
    const auto direct = Approval(false); P::RestorationDebtLedger restored;
    Require(restored.Begin(direct, Initial(), &error), "begin direct restoration");
    const auto half = Changed(Initial(), '1', Phase::HalfConfigured); Execute(restored, direct, 1, {10}, half);
    auto configured = Changed(half, '2', Phase::Installed); Execute(restored, direct, 2, {40}, configured);
    Require(restored.debts().empty() && restored.completedActions() == 2 && !restored.complete(), "actual Configure with settled obligations clears exact debt immediately");
    configured.identity = Hash('3'); Execute(restored, direct, 3, {50}, configured); Require(restored.complete(), "direct restoration completes remaining review");
}
}
int main() {
    SuccessorAndDelayedRestoration(); RemovalDoesNotCompletePurge(); PurgeAndEffectBudget(); FailuresAreAtomic(); UnusedAllowanceConfigure(); PrimaryDeferredSettlementAndUnconfiguredNoOp(); NoInventedRestorationOrDebt();
    EmptyAllowanceAndBounds(); SuccessorTriggerPhase(); AtomicMultiRecipientAndImmediateConfigure();
    std::cout << "[restoration-debt] PASS: bounded exact primary debt, successor and terminal settlement\n";
}
