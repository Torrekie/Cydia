/* Pure parent-projection fixtures. No native capture, file proof or execution.
 * Every control/script/native approval below is explicitly synthetic.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderConditionalDeconfiguration.hpp"
#include <algorithm>
#include <cstdlib>
#include <iostream>

namespace {
namespace P = CydiaAPT::Provider;
void Require(bool value, const char *message) {
    if (!value) { std::cerr << "[conditional-deconfiguration] " << message << '\n'; std::exit(1); }
}
std::string Hash(char c) { return std::string(64, c); }
std::string Row(const P::ExecutionPackage &p, const std::string &phase = "installed", bool hold = false,
    const std::string &multi = "no") {
    return p.package + '\t' + p.version + '\t' + p.architecture + '\t' + (hold ? "hold" : "install") + " ok " + phase + '\t' + multi + "\t\t\n";
}
P::DpkgState State(const std::string &rows, const std::string &identity) {
    P::DpkgState state; std::string error;
    Require(P::ParseDpkgState(rows, "amd64\n", "i386\n", identity, &state, &error), "parse explicit fixture state"); return state;
}
struct Fixture {
    P::ReviewPolicy policy;
    P::ReviewedTransaction review;
    std::shared_ptr<P::DeconfigurationAllowanceSet> approval = std::make_shared<P::DeconfigurationAllowanceSet>();
    P::RestorationCheckpoint initial;
    P::ExecutionPackage oldVictim{"victim", "1", "amd64"};
    P::ExecutionPackage oldPrimary{"breaker", "1", "amd64"};
    std::string multi = "no";
    explicit Fixture(bool sibling = false) {
        if (sibling) { oldVictim.architecture = "i386"; oldPrimary.package = "victim"; multi = "same"; }
        auto &e = policy.environment; e.paths.dpkg = "/usr/bin/dpkg"; e.paths.dpkgQuery = "/usr/bin/dpkg-query";
        e.paths.dpkgDeb = "/usr/bin/dpkg-deb"; e.paths.dpkgRoot = "/"; e.paths.dpkgAdmin = "/var/lib/dpkg";
        e.configurationIdentity = "configuration:fixture"; e.policyIdentity = "policy:fixture"; e.methodsIdentity = "methods:fixture";
        e.packageStateIdentity = "state-1"; e.nativeArchitecture = "amd64";
        e.registeredArchitectures = e.acquisitionArchitectures = {"amd64", "i386"};
        policy.layout = {"/", {"/var/jb"}}; policy.protectedDpkgOptions = {"--root=/", "--admindir=/var/lib/dpkg"};
        auto &b = review.binding; b.providerIdentifier = "fixture"; b.session = Hash('1');
        b.configurationIdentity = e.configurationIdentity; b.policyIdentity = e.policyIdentity; b.packageStateIdentity = e.packageStateIdentity;
        b.cacheEpoch = 1; b.selectionRevision = 1; b.review = "review:fixture";
        review.transaction.registeredArchitectures = e.registeredArchitectures;
        Install({oldPrimary.package, "2", oldPrimary.architecture}, 1, "breaker-index");
        Install({oldVictim.package, "2", oldVictim.architecture}, 3, "victim-index");
        approval->identity = Hash('c'); approval->initialCheckpoint = Hash('a'); approval->nativeAuthorityIdentity = Hash('b');
        approval->primaryReview = review; P::DeconfigurationAllowance allowance;
        allowance.installed = oldVictim; allowance.selection = P::DpkgSelection::Hold;
        allowance.initialStatus = allowance.diskStatus = P::DpkgPackageStatus::Installed; allowance.configVersion = "1";
        allowance.installedControlIdentity = Hash('e'); allowance.installedScriptsIdentity = Hash('f');
        P::DeconfigurationCause cause; cause.unpackAction = 1; cause.archive = "breaker-index"; cause.comparedVersion = "1";
        if (sibling) cause.kind = P::DeconfigurationCauseKind::SiblingVersionMismatch;
        else cause.canonicalRelation = "victim (<< 2)";
        allowance.causes.push_back(cause); allowance.endpoint.action = 4; allowance.endpoint.precedingUnpack = 3;
        allowance.endpoint.package = {oldVictim.package, "2", oldVictim.architecture};
        approval->allowances[Generation(oldVictim)] = allowance; policy.conditionalDeconfiguration = approval;
        initial.identity = approval->initialCheckpoint; initial.deferredQueueEmpty = true;
        P::RestorationObservation observation; observation.present = true; observation.package = oldVictim;
        observation.selection = allowance.selection; observation.status = observation.diskStatus = P::DpkgPackageStatus::Installed;
        observation.configVersion = "1"; observation.controlIdentity = allowance.installedControlIdentity;
        observation.scriptsIdentity = allowance.installedScriptsIdentity; observation.contentIdentity = Hash('1'); observation.scriptContentIdentity = Hash('2');
        initial.packages[Slot(oldVictim)] = observation;
    }
    static std::string Slot(const P::ExecutionPackage &p) { return p.package + ':' + p.architecture; }
    static std::string Generation(const P::ExecutionPackage &p) { return Slot(p) + '@' + p.version; }
    void Install(const P::ExecutionPackage &package, std::uint64_t id, const std::string &archiveID) {
        const auto mode = multi == "same" ? CydiaAPT::MultiArchMode::Same : CydiaAPT::MultiArchMode::None;
        const auto identity = CydiaAPT::BuildPackageIdentity(package.package, package.architecture, package.architecture, "amd64", mode);
        review.transaction.installs.push_back(identity.routingName); review.transaction.packages[identity.routingName] = {identity, package.version, package.package};
        P::ArchiveManifest archive; archive.identifier = archiveID; archive.package = package; archive.path = "/archives/" + archiveID + ".deb";
        archive.sourceURI = "https://example.invalid/"; archive.sourceIndexIdentity = "SHA256:" + Hash('a');
        archive.sourceDefinitionPath = "/etc/apt/sources.list.d/example.sources"; archive.sourceDefinitionOrdinal = 1;
        archive.sourceIndexPath = "/lists/Packages"; archive.sourceIndexURI = "https://example.invalid/Packages";
        archive.filename = "pool/" + archiveID + ".deb"; archive.recordOffset = id * 1024; archive.recordSize = 512;
        archive.hashes["SHA256"] = Hash('d'); archive.size = 4096; archive.layout = policy.layout;
        review.execution.archives.push_back(archive); P::ReviewedAction action;
        action.identifier = id; action.action = P::ExecutionAction::Unpack; action.package = package; action.archive = archiveID;
        review.execution.actions.push_back(action); action.identifier = id + 1; action.action = P::ExecutionAction::Configure; action.archive.clear();
        review.execution.actions.push_back(action);
    }
    P::DpkgState Before() const { return State(Row(oldPrimary, "installed", false, multi) + Row(oldVictim, "installed", true, multi) + Row({"keep", "1", "all"}), "state-1"); }
    P::DpkgState After(bool used = true) const {
        auto incoming = oldPrimary; incoming.version = "2";
        return State(Row(incoming, "unpacked", false, multi) + Row(oldVictim, used ? "half-configured" : "installed", true, multi) + Row({"keep", "1", "all"}), "state-2");
    }
    P::ParentExecutionRequest Request(bool autoDeconfigure = true) const {
        P::ParentExecutionRequest request; request.binding = review.binding; request.batch = 1;
        request.action = P::ExecutionAction::Unpack; request.actions = {1}; request.arguments = policy.protectedDpkgOptions;
        request.arguments.insert(request.arguments.end(), {"--status-fd=99", "--no-triggers", "--unpack"});
        if (autoDeconfigure) request.arguments.push_back("--auto-deconfigure");
        request.arguments.push_back(review.execution.archives[0].path); return request;
    }
    P::ParentExecutionEvidence Evidence(const P::DpkgState &state, const P::ParentExecutionRequest &request, bool conditional = true) const {
        P::ParentExecutionEvidence evidence; evidence.binding = review.binding; evidence.frontendLockHeld = true; evidence.statusDescriptor = 8;
        P::VerifiedArchiveEvidence archive; archive.archive = review.execution.archives[0]; archive.fileIdentity = "retained:breaker";
        archive.inspection.status = CydiaPackages::ArchivePolicyStatus::Accepted; archive.inspection.complete = archive.inspection.identityVerified = true;
        evidence.archives.push_back(archive); std::string error;
        Require(conditional ? P::ApplyDpkgStateEvidenceWithConditional(state, review, request, *approval, &evidence, &error) :
            P::ApplyDpkgStateEvidence(state, review, request, &evidence, &error), "state adapter publishes provisional primary routing"); return evidence;
    }
    P::AuthorizedExecution Authorize(bool autoDeconfigure = true) const {
        P::ReviewAuthorization authorization; P::AuthorizedExecution batch; std::string error; const auto request = Request(autoDeconfigure);
        Require(authorization.Accept(review, policy, &error) && authorization.Authorize(request, Evidence(Before(), request), &batch, &error), "conditional exact primary authorization");
        Require(batch.actions == std::vector<std::uint64_t>{1} && batch.conditionalDeconfigurationIdentity == approval->identity,
            "conditional allowance adds no action IDs"); return batch;
    }
    P::ConditionalDeconfigurationAdmission Admission(const P::AuthorizedExecution &batch, bool used = true) const {
        P::ConditionalDeconfigurationAdmission admission; admission.approvalIdentity = approval->identity;
        admission.checkpointIdentity = initial.identity; admission.stateIdentity = "state-1"; admission.batch = batch.batch; admission.actions = batch.actions;
        if (used) admission.causes.push_back({oldVictim, approval->allowances.at(Generation(oldVictim)).causes.front()}); return admission;
    }
    P::ConditionalDeconfigurationTransition Transition(const P::AuthorizedExecution &batch, bool used = true) const {
        P::ConditionalDeconfigurationTransition transition; transition.admission = Admission(batch, used); transition.before = initial;
        transition.after = initial; transition.after.identity = Hash('d'); transition.child.child.started = true; transition.child.child.exitCode = 0;
        if (used) { auto &victim = transition.after.packages.at(Slot(oldVictim)); victim.status = victim.diskStatus = P::DpkgPackageStatus::HalfConfigured;
            victim.controlIdentity = Hash('3'); victim.scriptsIdentity = Hash('4'); } return transition;
    }
    P::RestorationDebtLedger Prepared(const P::AuthorizedExecution &batch) const {
        P::RestorationDebtLedger debt; std::string error;
        Require(debt.Begin(*approval, initial, &error) && debt.PreparePrimary(initial.identity, batch, &error), "prepare pure debt copy"); return debt;
    }
};
void ConditionalPrimaryAndDefaults() {
    Fixture fixture; std::string error; auto request = fixture.Request(); auto evidence = fixture.Evidence(fixture.Before(), request);
    P::ParentExecutionEvidence denied = evidence;
    Require(!P::ApplyDpkgStateEvidence(fixture.Before(), fixture.review, request, &denied, &error) && !denied.stateVerified &&
        denied.conditionalDeconfigurationIdentity.empty(), "default auto-deconfiguration preguard remains");
    auto batch = fixture.Authorize(); Require(P::ValidateConditionalDeconfigurationAdmission(*fixture.approval, batch, fixture.Before(), fixture.initial.identity,
        fixture.Admission(batch), &error), "exact observed queued Breaks matches approval");
    for (unsigned mode = 0; mode != 7; ++mode) {
        auto admission = fixture.Admission(batch); auto candidate = batch;
        if (mode == 0) admission.approvalIdentity = Hash('0');
        if (mode == 1) admission.checkpointIdentity = Hash('0');
        if (mode == 2) admission.stateIdentity = "stale";
        if (mode == 3) admission.actions = {2};
        if (mode == 4) admission.causes.front().cause.comparedVersion = "9";
        if (mode == 5) admission.causes.push_back(admission.causes.front());
        if (mode == 6) admission.causes.front().cause.archive = "wrong-archive";
        Require(!P::ValidateConditionalDeconfigurationAdmission(*fixture.approval, candidate, fixture.Before(), fixture.initial.identity, admission, &error), "stale/duplicate/unapproved causes refuse");
    }
    auto nativeConfigured = batch;
    nativeConfigured.arguments.erase(std::find(nativeConfigured.arguments.begin(), nativeConfigured.arguments.end(), "--auto-deconfigure"));
    Require(P::ValidateConditionalDeconfigurationAdmission(*fixture.approval, nativeConfigured, fixture.Before(), fixture.initial.identity,
        fixture.Admission(nativeConfigured), &error), "effective native configuration can enable Breaks; raw argv absence is not policy proof");
    P::ReviewAuthorization authorization; P::AuthorizedExecution allowed;
    Require(authorization.Accept(fixture.review, fixture.policy, &error), "conditional review retained"); evidence.conditionalDeconfigurationIdentity.clear();
    Require(!authorization.Authorize(request, evidence, &allowed, &error), "missing conditional state binding cannot authorize");
    evidence = fixture.Evidence(fixture.Before(), request); evidence.deconfigurationTargets = {fixture.oldVictim};
    Require(!authorization.Authorize(request, evidence, &allowed, &error), "legacy deconfiguration boolean/vector cannot override conditional policy");
    auto synthetic = fixture.review; auto action = synthetic.execution.actions.front(); action.identifier = 99; action.action = P::ExecutionAction::Deconfigure;
    action.package = fixture.oldVictim; action.archive.clear(); synthetic.execution.actions.insert(synthetic.execution.actions.begin(), action);
    auto policy = fixture.policy; policy.additionalActionsReviewed.insert(99);
    Require(!authorization.Accept(synthetic, policy, &error), "opt-in does not consume invented Deconfigure IDs");
    policy = fixture.policy; policy.conditionalDeconfiguration.reset(); request = fixture.Request(false);
    Require(authorization.Accept(fixture.review, policy, &error) && authorization.Authorize(request,
        fixture.Evidence(fixture.Before(), request, false), &allowed, &error) && allowed.conditionalDeconfigurationIdentity.empty(), "ordinary primary behavior remains");
}
void ExactStateAndFailure() {
    Fixture fixture; const auto batch = fixture.Authorize(); auto prepared = fixture.Prepared(batch); auto transition = fixture.Transition(batch); std::string error;
    Require(P::VerifyDpkgStateTransitionWithConditional(fixture.Before(), fixture.After(), fixture.review, batch, *fixture.approval,
        prepared, transition, &error), "actual old HalfConfigured effect passes full state projection");
    Require(prepared.completedActions() == 0 && prepared.debts().empty() && prepared.active(), "verification copy consumes no real IDs/debt");
    Require(!P::VerifyDpkgStateTransition(fixture.Before(), fixture.After(), fixture.review, batch, &error), "ordinary state verifier still refuses conditional effects");
    for (unsigned mode = 0; mode != 13; ++mode) {
        auto state = fixture.After(); auto proof = transition;
        if (mode == 0) state.packages.at("keep:all").package.version = "9";
        if (mode == 1) state.packages.at("victim:amd64").selection = P::DpkgSelection::Install;
        if (mode == 2) proof.admission.causes.clear();
        if (mode == 3) proof.after.packages.at("victim:amd64").scriptContentIdentity = Hash('9');
        if (mode == 4) proof.child.cancelled = true;
        if (mode == 5) proof.child.child.started = false;
        if (mode == 6) proof.child.child.exitCode = 1;
        if (mode == 7) proof.child.uncertain = true;
        if (mode == 8) state.packages.at("victim:amd64").multiArch = "foreign";
        if (mode == 9) proof.before.packages.at("victim:amd64").configVersion = "999";
        if (mode == 10) proof.before.packages.at("victim:amd64").controlIdentity = Hash('9');
        if (mode == 11) proof.before.packages.at("victim:amd64").diskStatus = P::DpkgPackageStatus::Unpacked;
        if (mode == 12) proof.before.packages.at("victim:amd64").scriptContentIdentity = Hash('9');
        Require(!P::VerifyDpkgStateTransitionWithConditional(fixture.Before(), state, fixture.review, batch, *fixture.approval,
            prepared, proof, &error) && prepared.completedActions() == 0 && prepared.active(), "wrong full state/proof or failed/no-start/cancelled/uncertain child grants no settlement");
    }
    auto failed = prepared; auto failure = transition.child; failure.child.started = false;
    Require(!failed.SettlePrimary(batch.batch, failure, transition.after, {}, &error) && !failed.active() && failed.completedActions() == 0 &&
        !failed.PreparePrimary(fixture.initial.identity, batch, &error), "real no-start rejection consumes no IDs and retires authority");
    Require(prepared.SettlePrimary(batch.batch, transition.child, transition.after, {}, &error) &&
        prepared.completedActions() == 1 && prepared.debts().size() == 1 && !prepared.complete(), "actual settlement records genuine debt and exact primary ID only");
}
void UnusedAndSibling() {
    Fixture fixture; const auto batch = fixture.Authorize(); auto prepared = fixture.Prepared(batch); auto unused = fixture.Transition(batch, false); std::string error;
    Require(P::VerifyDpkgStateTransitionWithConditional(fixture.Before(), fixture.After(false), fixture.review, batch, *fixture.approval,
        prepared, unused, &error) && prepared.SettlePrimary(batch.batch, unused.child, unused.after, {}, &error) && prepared.debts().empty(),
        "unused allowance requires no fabricated deconfiguration or restoration");
    Fixture sibling(true); const auto siblingBatch = sibling.Authorize(false); auto siblingDebt = sibling.Prepared(siblingBatch);
    Require(P::ValidateConditionalDeconfigurationAdmission(*sibling.approval, siblingBatch, sibling.Before(), sibling.initial.identity,
        sibling.Admission(siblingBatch), &error) && P::VerifyDpkgStateTransitionWithConditional(sibling.Before(), sibling.After(), sibling.review,
            siblingBatch, *sibling.approval, siblingDebt, sibling.Transition(siblingBatch), &error), "native sibling cause does not rely on --auto-deconfigure");
    P::ParentExecutionEvidence evidence; auto request = sibling.Request(false);
    Require(!P::ApplyDpkgStateEvidence(sibling.Before(), sibling.review, request, &evidence, &error), "ordinary unsupported sibling preguard remains");
}
void SuccessorAndCompleteBookkeeping() {
    Fixture fixture; std::string error; auto first = fixture.Authorize(); auto debt = fixture.Prepared(first); auto initial = fixture.Transition(first);
    Require(debt.SettlePrimary(1, initial.child, initial.after, {}, &error), "establish actual old-generation HalfConfigured boundary");
    const auto batch = [&](std::uint64_t id, P::ExecutionAction kind, std::uint64_t ordinal) {
        P::AuthorizedExecution value; value.batch = ordinal; value.action = kind; value.actions = {id}; value.arguments = {"--no-triggers"};
        value.conditionalDeconfigurationIdentity = fixture.approval->identity;
        if (kind == P::ExecutionAction::Unpack) {
            P::VerifiedArchiveEvidence archive; archive.archive = fixture.review.execution.archives[1]; archive.fileIdentity = "retained:victim";
            value.archives.push_back(archive);
        }
        return value;
    };
    const auto admission = [&](const P::AuthorizedExecution &value, const P::RestorationCheckpoint &point, const P::DpkgState &state) {
        P::ConditionalDeconfigurationAdmission scope; scope.approvalIdentity = fixture.approval->identity; scope.batch = value.batch;
        scope.actions = value.actions; scope.checkpointIdentity = point.identity; scope.stateIdentity = state.packageStateIdentity; return scope;
    };
    auto beforeState = fixture.After(); auto point = initial.after;
    auto configuredBreaker = State(Row({"breaker", "2", "amd64"}) + Row(fixture.oldVictim, "half-configured", true) + Row({"keep", "1", "all"}), "state-3");
    auto configureBreaker = batch(2, P::ExecutionAction::Configure, 2);
    P::ConditionalDeconfigurationTransition configured; configured.before = point; configured.after = point; configured.after.identity = Hash('e');
    configured.admission = admission(configureBreaker, point, beforeState); configured.child.child.started = true; configured.child.child.exitCode = 0;
    Require(debt.PreparePrimary(point.identity, configureBreaker, &error) && P::VerifyDpkgStateTransitionWithConditional(beforeState, configuredBreaker,
        fixture.review, configureBreaker, *fixture.approval, debt, configured, &error) &&
        debt.SettlePrimary(2, configured.child, configured.after, {}, &error), "unrelated primary configure leaves real debt HalfConfigured");
    point = configured.after; beforeState = configuredBreaker; auto successor = batch(3, P::ExecutionAction::Unpack, 3);
    auto afterState = State(Row({"breaker", "2", "amd64"}) + Row({"victim", "2", "amd64"}, "unpacked", true) + Row({"keep", "1", "all"}), "state-4");
    P::ConditionalDeconfigurationTransition unpacked; unpacked.before = point; unpacked.after = point; unpacked.after.identity = Hash('f');
    unpacked.admission = admission(successor, point, beforeState); unpacked.child.child.started = true; unpacked.child.child.exitCode = 0;
    auto &observed = unpacked.after.packages.at("victim:amd64"); observed.package.version = "2";
    observed.status = observed.diskStatus = P::DpkgPackageStatus::Unpacked; observed.controlIdentity = Hash('5'); observed.scriptsIdentity = Hash('6');
    observed.contentIdentity = Hash('7'); observed.scriptContentIdentity = Hash('8');
    P::RestorationSuccessorProof proof; proof.unpackAction = 3; proof.oldGeneration = "victim:amd64@1"; proof.archive = "victim-index";
    proof.retainedArchiveIdentity = "retained:victim"; proof.beforeCheckpoint = point.identity; proof.afterCheckpoint = unpacked.after.identity;
    proof.installedControlIdentity = observed.controlIdentity; proof.installedScriptsIdentity = observed.scriptsIdentity;
    proof.installedContentIdentity = observed.contentIdentity; proof.installedScriptContentIdentity = observed.scriptContentIdentity; proof.installedMultiArch = "no";
    unpacked.successors.push_back(proof);
    Require(debt.PreparePrimary(point.identity, successor, &error), "reserve reviewed successor only after real old-generation boundary");
    for (unsigned mode = 0; mode != 4; ++mode) {
        auto refused = unpacked;
        if (mode == 0) refused.successors.clear();
        if (mode == 1) refused.successors.front().installedMultiArch.clear();
        if (mode == 2) refused.successors.front().installedMultiArch = "same";
        if (mode == 3) refused.successors.front().installedScriptsIdentity = Hash('9');
        Require(!P::VerifyDpkgStateTransitionWithConditional(beforeState, afterState, fixture.review, successor, *fixture.approval,
            debt, refused, &error) && debt.completedActions() == 2 && debt.debts().size() == 1, "missing/wrong actual successor metadata cannot advance debt or primary IDs");
    }
    Require(P::VerifyDpkgStateTransitionWithConditional(beforeState, afterState, fixture.review, successor, *fixture.approval,
        debt, unpacked, &error) && debt.SettlePrimary(3, unpacked.child, unpacked.after, unpacked.successors, &error) &&
        debt.debts().begin()->second.phase == P::RestorationDebtPhase::SuccessorUnpacked, "verified native successor remains genuinely Unpacked debt");
    beforeState = afterState; point = unpacked.after; auto configure = batch(4, P::ExecutionAction::Configure, 4);
    auto finalState = State(Row({"breaker", "2", "amd64"}) + Row({"victim", "2", "amd64"}, "installed", true) + Row({"keep", "1", "all"}), "state-5");
    P::ConditionalDeconfigurationTransition restored; restored.before = point; restored.after = point; restored.after.identity = Hash('1');
    restored.admission = admission(configure, point, beforeState); restored.child.child.started = true; restored.child.child.exitCode = 0;
    auto &done = restored.after.packages.at("victim:amd64"); done.status = done.diskStatus = P::DpkgPackageStatus::Installed;
    done.configVersion = "2"; done.controlIdentity = Hash('9'); done.scriptsIdentity = Hash('a');
    Require(debt.PreparePrimary(point.identity, configure, &error) && P::VerifyDpkgStateTransitionWithConditional(beforeState, finalState,
        fixture.review, configure, *fixture.approval, debt, restored, &error) && debt.SettlePrimary(4, restored.child, restored.after, {}, &error) &&
        debt.complete() && debt.completedActions() == 4, "exact observed endpoint discharges debt after every primary ID; owner quiescence/CAS still required");
    auto joined = first; joined.actions = {1, 3}; joined.archives.push_back(successor.archives.front()); auto cause = fixture.Admission(joined);
    Require(!P::ValidateConditionalDeconfigurationAdmission(*fixture.approval, joined, fixture.Before(), fixture.initial.identity, cause, &error) &&
        error == "provider_conditional_fresh_boundary_required", "one child cannot invent old HalfConfigured plus later successor boundaries");
}

void ActualPairedTriggerPhases() {
    Fixture fixture; std::string error; const auto batch = fixture.Authorize(); auto debt = fixture.Prepared(batch); auto transition = fixture.Transition(batch);
    auto incoming = fixture.oldPrimary; incoming.version = "2";
    const auto after = State(Row(incoming, "unpacked") + Row(fixture.oldVictim, "half-configured", true) +
        "keep\t1\tall\tinstall ok triggers-pending\tno\tcache-refresh\t\n", "state-2");
    Require(!P::VerifyDpkgStateTransitionWithConditional(fixture.Before(), after, fixture.review, batch, *fixture.approval, debt, transition, &error) &&
        P::VerifyDpkgStateTransitionWithConditionalEffects(fixture.Before(), after, fixture.review, batch, *fixture.approval, debt, transition, &error),
        "paired route retains actual unrelated trigger phase without normalizing genuine HalfConfigured debt");
    for (unsigned mode = 0; mode != 4; ++mode) {
        auto unexpected = after; auto &other = unexpected.packages.at("keep:all");
        if (mode == 0) { other.status = P::DpkgPackageStatus::HalfConfigured; other.triggersPending.clear(); }
        if (mode == 1) other.package.version = "9";
        if (mode == 2) other.selection = P::DpkgSelection::Hold;
        if (mode == 3) other.reinstallRequired = true;
        Require(!P::VerifyDpkgStateTransitionWithConditionalEffects(fixture.Before(), unexpected, fixture.review, batch, *fixture.approval,
            debt, transition, &error), "trigger projection never grants unrelated repair/version/selection/error changes");
    }
    Require(debt.SettlePrimary(1, transition.child, transition.after, {}, &error), "settle initial conditional bookkeeping after independent graph gate in real owner");
    P::AuthorizedExecution configure; configure.batch = 2; configure.action = P::ExecutionAction::Configure; configure.actions = {2};
    configure.arguments = {"--no-triggers"}; configure.conditionalDeconfigurationIdentity = fixture.approval->identity;
    P::ConditionalDeconfigurationTransition configured; configured.before = transition.after; configured.after = configured.before;
    configured.after.identity = Hash('e'); configured.child.child.started = true; configured.child.child.exitCode = 0;
    configured.admission.approvalIdentity = fixture.approval->identity; configured.admission.checkpointIdentity = configured.before.identity;
    configured.admission.stateIdentity = "state-2"; configured.admission.batch = 2; configured.admission.actions = {2};
    const auto pending = State("breaker\t2\tamd64\tinstall ok triggers-pending\tno\trefresh\t\n" +
        Row(fixture.oldVictim, "half-configured", true) + Row({"keep", "1", "all"}), "state-3");
    Require(debt.PreparePrimary(configured.before.identity, configure, &error) &&
        P::VerifyDpkgStateTransitionWithConditionalEffects(fixture.After(), pending, fixture.review, configure, *fixture.approval, debt, configured, &error),
        "ordinary Configure may leave actual pending status only from genuine Unpacked/HalfConfigured");
    auto invented = fixture.After(); invented.packages.at("breaker:amd64").status = P::DpkgPackageStatus::Installed;
    Require(!P::VerifyDpkgStateTransitionWithConditionalEffects(invented, pending, fixture.review, configure, *fixture.approval, debt, configured, &error),
        "Installed-to-pending projection cannot pretend an ordinary postinst configure ran");
}

}
int main() {
    ConditionalPrimaryAndDefaults(); ExactStateAndFailure(); UnusedAndSibling(); SuccessorAndCompleteBookkeeping(); ActualPairedTriggerPhases();
    std::cout << "conditional deconfiguration parent projections passed\n";
}
