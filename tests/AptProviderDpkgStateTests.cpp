/* Pure parent dpkg-state fixtures; capture/execution requires the real helper.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderDpkgState.hpp"
#include <cstdlib>
#include <iostream>

namespace {
namespace P = CydiaAPT::Provider;
void Require(bool value, const char *message) {
    if (value) return;
    std::cerr << "[apt-provider-dpkg-state][FAIL] " << message << '\n'; std::exit(1);
}
std::string Row(const std::string &name, const std::string &version, const std::string &arch,
                const std::string &status = "install ok installed", const std::string &multi = "",
                const std::string &pending = "", const std::string &awaited = "") {
    return name + '\t' + version + '\t' + arch + '\t' + status + '\t' + multi + '\t' + pending + '\t' + awaited + '\n';
}
P::DpkgState State(const std::string &rows, const std::string &identity = "state-1") {
    P::DpkgState result; std::string error;
    Require(P::ParseDpkgState(rows, "amd64\n", "i386\n", identity, &result, &error), "fixture parse");
    return result;
}
P::ReviewedAction Action(std::uint64_t id, P::ExecutionAction kind,
                         const std::string &name, const std::string &version, const std::string &arch) {
    P::ReviewedAction result; result.identifier = id; result.action = kind;
    result.package = {name, version, arch}; return result;
}
P::AuthorizedExecution Batch(P::ExecutionAction kind, const std::vector<std::uint64_t> &ids) {
    P::AuthorizedExecution result; result.batch = 1; result.action = kind; result.actions = ids;
    result.arguments = {"--no-triggers"}; return result;
}
void ParsingAndPending() {
    const auto rows = Row("native", "1:2.0-3", "amd64", "install ok unpacked", "same") +
        Row("native", "1:2.0-3", "i386", "hold ok half-configured", "same") +
        Row("portable", "4", "all") + Row("legacy", "1", "old-arch") +
        Row("triggered", "2", "amd64", "hold ok triggers-pending", "", "cache-update /usr/share/info") +
        Row("waiting", "3", "amd64", "install ok triggers-awaited", "", "", "triggered") +
        Row("remove-me", "1", "amd64", "deinstall ok installed") +
        Row("leave-config", "1", "amd64", "deinstall ok config-files") +
        Row("purge-me", "1", "amd64", "purge ok config-files") +
        Row("selection-only", "", "", "install ok not-installed");
    const auto state = State(rows); std::vector<P::ExecutionPackage> pending; std::string error;
    Require(state.packages.size() == 10 && state.packages.at("native:i386").selection == P::DpkgSelection::Hold &&
        state.packages.at("portable:all").package.architecture == "all" &&
        state.packages.at("legacy:old-arch").package.architecture == "old-arch" &&
        state.packages.at("selection-only:").package.version.empty(), "lost actual architectures/selections");
    Require(P::DpkgPendingTargets(state, P::ExecutionAction::Configure, &pending, &error) && pending.size() == 3 &&
        pending[0].architecture == "amd64" && pending[1].architecture == "i386" && pending[2].package == "triggered",
        "configure pending does not match dpkg");
    Require(P::DpkgPendingTargets(state, P::ExecutionAction::Triggers, &pending, &error) &&
        pending.size() == 1 && pending[0].package == "triggered", "trigger pending includes awaiters");
    Require(P::DpkgPendingTargets(state, P::ExecutionAction::Remove, &pending, &error) && pending.size() == 2 &&
        pending[0].package == "purge-me" && pending[1].package == "remove-me", "remove pending selection changed");
    Require(P::DpkgPendingTargets(state, P::ExecutionAction::Purge, &pending, &error) && pending.size() == 2,
        "purge pending differs from upstream shared selector");
    Require(!P::DpkgPendingTargets(state, P::ExecutionAction::Unpack, &pending, &error), "unpack pending inferred");
    for (const auto &invalid : {
        Row("bad", "1", "amd64", "ii "), Row("bad", "1", "amd64", "install ok unknown"),
        Row("bad", "1", "all", "install ok installed", "same"),
        Row("bad", "1", "amd64", "install ok triggers-pending"),
        Row("bad", "1", "amd64", "install ok installed", "", "same same"),
        Row("bad", "1", "amd64", "install ok installed", "", "", "invalid:architecture:extra"),
        Row("bad", "1", "amd64", "install ok triggers-awaited", "", "", "target:any"),
        Row("bad", "1", "amd64", "install ok installed", "", "pending-trigger"),
        Row("bad", "1", "amd64") + Row("bad", "2", "amd64"),
        Row("bad", "", "", "install ok installed"),
        std::string("bad\t1\tamd64\tinstall ok installed\t\t\t"),
        Row("bad", "1", "amd64") + std::string(1, '\0')
    }) {
        P::DpkgState parsed;
        Require(!P::ParseDpkgState(invalid, "amd64\n", "i386\n", "state", &parsed, &error) &&
            parsed.packages.empty(), "malformed/truncated state accepted");
    }
    P::DpkgState parsed;
    Require(!P::ParseDpkgState(rows, "amd64\n", "amd64\n", "state", &parsed, &error), "duplicate native architecture");
    Require(!P::ParseDpkgState(rows, "amd64\n", "i386\n", "", &parsed, &error), "missing state identity");
    Require(!P::ParseDpkgState(rows, "amd64\r\n", "i386\n", "state", &parsed, &error), "noncanonical native architecture");
}
void Evidence() {
    auto state = State(Row("shared", "1", "amd64", "install ok unpacked", "same") +
        Row("shared", "1", "i386", "install ok unpacked", "same") + Row("portable", "1", "all"));
    P::ReviewedTransaction review;
    review.execution.actions.push_back(Action(1, P::ExecutionAction::Configure, "shared", "1", "amd64"));
    review.execution.actions.push_back(Action(2, P::ExecutionAction::Configure, "shared", "1", "i386"));
    P::ParentExecutionRequest request; request.action = P::ExecutionAction::Configure; request.actions = {1, 2};
    request.arguments = {"--no-triggers", "--configure", "--pending"};
    P::ParentExecutionEvidence evidence; evidence.frontendLockHeld = true; evidence.statusDescriptor = 8;
    std::string error;
    Require(P::ApplyDpkgStateEvidence(state, review, request, &evidence, &error) && evidence.stateVerified &&
        evidence.pendingTargetsKnown && evidence.pendingTargets.size() == 2 &&
        !evidence.barePackageTargets.count("shared") && evidence.barePackageTargets.at("portable").architecture == "all" &&
        evidence.statusDescriptor == 8 && evidence.frontendLockHeld, "ambiguous package alias or lost parent proof");
    request.arguments.push_back("--auto-deconfigure");
    Require(!P::ApplyDpkgStateEvidence(state, review, request, &evidence, &error) && !evidence.stateVerified,
        "auto-deconfigure effects guessed");
    request.arguments = {"--configure", "shared:amd64"};
    Require(!P::ApplyDpkgStateEvidence(state, review, request, &evidence, &error), "implicit triggers assumed empty");
    request.arguments = {"--no-triggers", "--configure", "shared:amd64"}; request.actions = {1};
    state.packages.at("shared:amd64").triggersPending = {"cache-update"};
    Require(!P::ApplyDpkgStateEvidence(state, review, request, &evidence, &error), "explicit configure concealed trigger execution");
    request.action = P::ExecutionAction::Triggers;
    Require(!P::ApplyDpkgStateEvidence(state, review, request, &evidence, &error), "unknown trigger dependencies assumed safe");
}
void ImplicitMultiarchDeconfiguration() {
    // dpkg's unpack.c sibling loop runs even without --auto-deconfigure.
    // Keep these refusals before any child, rather than discovering the
    // additional half-configured package only during settlement.
    P::ReviewedTransaction review;
    review.execution.actions = {Action(1, P::ExecutionAction::Unpack, "shared", "2", "amd64")};
    P::ParentExecutionRequest request; request.action = P::ExecutionAction::Unpack; request.actions = {1};
    request.arguments = {"--no-triggers", "--unpack", "/archives/shared.deb"};
    P::ParentExecutionEvidence evidence; std::string error;
    const auto admitted = [&](const std::string &rows) {
        return P::ApplyDpkgStateEvidence(State(rows), review, request, &evidence, &error);
    };
    const auto native = Row("shared", "1", "amd64", "install ok installed", "same");
    for (const auto &sibling : {
        Row("shared", "1", "i386", "install ok installed", "same"),
        Row("shared", "1", "i386", "hold ok installed", "same"),
        Row("shared", "1", "i386", "install ok triggers-pending", "same", "cache"),
        Row("shared", "1", "i386", "install ok triggers-awaited", "same", "", "cache:amd64")
    }) Require(!admitted(native + sibling) && error == "provider_deconfiguration_unknown" && !evidence.stateVerified,
        "implicit sibling deconfiguration admitted before unpack");
    review.execution.actions.push_back(Action(2, P::ExecutionAction::Unpack, "shared", "2", "i386"));
    request.actions.push_back(2);
    Require(!admitted(native + Row("shared", "1", "i386", "install ok installed", "same")),
        "later sibling upgrade concealed first unpack's deconfiguration");
    review.execution.actions.resize(1); request.actions = {1};
    Require(admitted(native), "single-instance multiarch upgrade rejected");
    Require(admitted(native + Row("unrelated", "1", "i386", "install ok installed", "same")),
        "unrelated foreign package blocked native upgrade");
    Require(admitted(native + Row("shared", "2", "i386", "install ok installed", "same")),
        "already synchronized sibling blocked unpack");
    for (const char *status : {"install ok not-installed", "deinstall ok config-files", "install ok half-installed",
            "install ok unpacked", "install ok half-configured"})
        Require(admitted(native + Row("shared", "1", "i386", status, "same")),
            "sibling outside native deconfiguration status gate rejected");
    review.execution.actions[0].package.architecture = "i386";
    Require(!admitted(native + Row("shared", "1", "i386", "install ok installed", "same")),
        "foreign upgrade omitted native sibling deconfiguration");
    Require(admitted(Row("shared", "1", "i386", "install ok installed", "same")),
        "single foreign instance upgrade rejected");
    review.execution.actions[0].package.architecture = "amd64";
    // Equality follows dpkg version.c/parsehelp.c, including absent revision,
    // numeric runs and epochs, rather than a string or semantic-version test.
    const std::vector<std::pair<std::string, std::string>> equal = {
        {"1", "0:1-0"}, {"1.00", "1.0"}, {"1.0002-0003", "1.2-3"},
        {"0002:1~rc0001-0", "2:1~rc1"}, {"1a0", "1a"},
        {"2147483647:1-0", "02147483647:1"}, {"+1:1", "1:1-0"}, {"-0:1", "1"}
    };
    for (const auto &versions : equal) {
        review.execution.actions[0].package.version = versions.first;
        Require(admitted(Row("shared", versions.second, "i386", "install ok installed", "same")),
            "dpkg-equivalent sibling version rejected");
    }
    const std::vector<std::pair<std::string, std::string>> different = {
        {"1", "1-1"}, {"1:1", "1"}, {"1~rc1", "1"}, {"1~~", "1~"},
        {"1.01", "1.10"}, {"1a0b", "1ab"}, {"1+0", "1"}, {"1-2", "1-02.0"},
        {"1", "2147483648:1"}, {"1", "-1:1"}, {"1", "1-"}
    };
    for (const auto &versions : different) {
        review.execution.actions[0].package.version = versions.first;
        Require(!admitted(Row("shared", versions.second, "i386", "install ok installed", "same")) &&
            error == "provider_deconfiguration_unknown", "different or unparseable sibling version admitted");
    }
}
void BoundedTriggers() {
    // dpkg trig_clear_awaiters preserves an unpacked waiter's status, and
    // modstatdb_shutdown checkpoints its cleared links. Sources:
    // https://git.dpkg.org/cgit/dpkg/dpkg.git/tree/lib/dpkg/triglib.c
    // https://git.dpkg.org/cgit/dpkg/dpkg.git/tree/lib/dpkg/dbmodify.c
    const std::string rows = Row("cache", "2", "amd64", "install ok triggers-pending", "same", "cache-native") +
        Row("cache", "2", "i386", "hold ok triggers-pending", "same", "cache-foreign") +
        Row("waiting", "1", "all", "install ok triggers-awaited", "", "", "cache:amd64 cache:i386") +
        Row("partial", "1", "amd64", "install ok unpacked", "", "", "cache:amd64") + Row("untouched", "3", "all");
    auto before = State(rows);
    auto after = State(Row("cache", "2", "amd64", "install ok installed", "same") +
        Row("cache", "2", "i386", "hold ok installed", "same") + Row("waiting", "1", "all") +
        Row("partial", "1", "amd64", "install ok unpacked") + Row("untouched", "3", "all"), "state-2");
    P::ReviewedTransaction review;
    review.execution.actions = {Action(1, P::ExecutionAction::Triggers, "cache", "2", "amd64"),
        Action(2, P::ExecutionAction::Triggers, "cache", "2", "i386")};
    P::ParentExecutionRequest request; request.action = P::ExecutionAction::Triggers; request.actions = {1, 2};
    request.arguments = {"--no-triggers", "--triggers-only", "cache:amd64", "cache:i386"};
    P::ParentExecutionEvidence evidence; std::string error;
    Require(P::ApplyDpkgStateEvidence(before, review, request, &evidence, &error) && evidence.stateVerified &&
        evidence.triggerTargetsKnown && evidence.triggerTargets.empty(), "bounded explicit trigger evidence rejected");
    auto batch = Batch(P::ExecutionAction::Triggers, {1, 2});
    Require(P::VerifyDpkgStateTransition(before, after, review, batch, &error),
        "explicit triggers lost multiarch/hold or deterministic waiter updates");
    request.arguments = {"--no-triggers", "--triggers-only", "--pending"};
    Require(P::ApplyDpkgStateEvidence(before, review, request, &evidence, &error) &&
        evidence.pendingTargetsKnown && evidence.pendingTargets.size() == 2,
        "exact trigger-pending set rejected");
    request.actions = {1};
    Require(!P::ApplyDpkgStateEvidence(before, review, request, &evidence, &error),
        "subset of pending recipients accepted without dependency evidence");
    request.actions = {1, 2}; request.arguments = {"--triggers-only", "--pending"};
    Require(!P::ApplyDpkgStateEvidence(before, review, request, &evidence, &error), "unbounded trigger processing accepted");
    request.arguments.insert(request.arguments.begin(), "--no-triggers");
    auto ambiguous = before; ambiguous.packages.at("waiting:all").triggersAwaited = {"cache"};
    Require(!P::ApplyDpkgStateEvidence(ambiguous, review, request, &evidence, &error), "bare multiarch waiter guessed");
    auto stale = before; stale.packages.at("waiting:all").triggersAwaited = {"untouched"};
    Require(!P::ApplyDpkgStateEvidence(stale, review, request, &evidence, &error), "implicit stale waiter repair authorized");
    auto unwanted = before; unwanted.packages.at("cache:i386").selection = P::DpkgSelection::Deinstall;
    Require(!P::ApplyDpkgStateEvidence(unwanted, review, request, &evidence, &error), "pending recipient outside install/hold accepted");
    auto changedReview = review; changedReview.execution.actions[1].package.version = "3";
    Require(!P::ApplyDpkgStateEvidence(before, changedReview, request, &evidence, &error), "trigger version mismatch accepted");
    for (unsigned variant = 0; variant != 7; ++variant) {
        auto changed = after;
        switch (variant) {
            case 0: changed.packages.at("cache:amd64") = before.packages.at("cache:amd64"); break;
            case 1: changed.packages.at("untouched:all").status = P::DpkgPackageStatus::TriggersPending;
                changed.packages.at("untouched:all").triggersPending = {"new-trigger"}; break;
            case 2: changed.packages.at("waiting:all").package.version = "9"; break;
            case 3: changed.packages.at("cache:i386").selection = P::DpkgSelection::Install; break;
            case 4: changed.packages.at("partial:amd64").status = P::DpkgPackageStatus::Installed; break;
            case 5: changed.packages.erase("cache:i386"); break;
            case 6: changed.packages.at("waiting:all") = before.packages.at("waiting:all"); break;
            default: Require(false, "missing trigger transition variant");
        }
        Require(!P::VerifyDpkgStateTransition(before, changed, review, batch, &error),
            "new or incomplete trigger effects accepted");
    }
    // A recipient may itself await another recipient. Both must be reviewed;
    // successful processing clears the graph without changing either identity.
    before.packages.at("cache:amd64").status = P::DpkgPackageStatus::TriggersAwaited;
    before.packages.at("cache:amd64").triggersAwaited = {"cache:i386"};
    Require(P::ApplyDpkgStateEvidence(before, review, request, &evidence, &error) &&
        P::VerifyDpkgStateTransition(before, after, review, batch, &error), "reviewed trigger dependency graph rejected");
    batch.actions.push_back(2);
    Require(!P::VerifyDpkgStateTransition(before, after, review, batch, &error), "duplicate trigger action accepted");
}
void Transitions() {
    const auto foreign = Row("shared", "1", "i386", "install ok installed", "same");
    auto before = State(Row("shared", "1", "amd64", "install ok installed", "same") + foreign);
    auto after = State(Row("shared", "2", "amd64", "install ok unpacked", "same") + foreign, "state-2");
    P::ReviewedTransaction review; std::string error;
    review.execution.actions.push_back(Action(1, P::ExecutionAction::Unpack, "shared", "2", "amd64"));
    auto batch = Batch(P::ExecutionAction::Unpack, {1});
    Require(P::VerifyDpkgStateTransition(before, after, review, batch, &error), "ordinary native unpack rejected");
    for (unsigned variant = 0; variant != 6; ++variant) {
        auto changed = after;
        switch (variant) {
            case 0: changed.packages.at("shared:amd64").package.version = "3"; break;
            case 1: changed.packages.at("shared:amd64").status = P::DpkgPackageStatus::HalfInstalled; break;
            case 2: changed.packages.at("shared:i386").selection = P::DpkgSelection::Hold; break;
            case 3: changed.packages.erase("shared:i386"); break;
            case 4: changed.packages.at("shared:i386").triggersPending = {"new-trigger"}; break;
            case 5: changed.registeredArchitectures.pop_back(); break;
        }
        Require(!P::VerifyDpkgStateTransition(before, changed, review, batch, &error), "unreviewed or incomplete transition accepted");
    }
    before = after; after.packages.at("shared:amd64").status = P::DpkgPackageStatus::Installed;
    review.execution.actions = {Action(2, P::ExecutionAction::Configure, "shared", "2", "amd64")};
    batch = Batch(P::ExecutionAction::Configure, {2});
    Require(P::VerifyDpkgStateTransition(before, after, review, batch, &error), "ordinary configure rejected");
    batch.actions.push_back(2);
    Require(!P::VerifyDpkgStateTransition(before, after, review, batch, &error), "duplicate execution action accepted");
    for (const bool toAll : {false, true}) {
        const std::string oldArch = toAll ? "amd64" : "all", newArch = toAll ? "all" : "amd64";
        before = State(Row("portable", "1", oldArch));
        after = State(Row("portable", "2", newArch, "install ok unpacked"), "state-3");
        review.execution.actions = {Action(3, P::ExecutionAction::Unpack, "portable", "2", newArch)};
        batch = Batch(P::ExecutionAction::Unpack, {3});
        Require(P::VerifyDpkgStateTransition(before, after, review, batch, &error), "all/native replacement rejected");
        if (toAll) {
            before = State(Row("portable", "1", oldArch) + Row("portable", "1", "i386"));
            Require(!P::VerifyDpkgStateTransition(before, after, review, batch, &error), "all transition hid foreign removal");
        }
    }
    before = State(Row("removed", "1", "amd64") + Row("keep", "2", "all"));
    after = State(Row("removed", "1", "amd64", "deinstall ok config-files") + Row("keep", "2", "all"), "state-4");
    review.execution.actions = {Action(4, P::ExecutionAction::Remove, "removed", "1", "amd64")};
    batch = Batch(P::ExecutionAction::Remove, {4});
    Require(P::VerifyDpkgStateTransition(before, after, review, batch, &error), "remove with conffiles rejected");
    auto gone = State(Row("keep", "2", "all"), "state-5");
    Require(P::VerifyDpkgStateTransition(before, gone, review, batch, &error), "remove without conffiles rejected");
    before = after; after = State(Row("removed", "", "", "purge ok not-installed") + Row("keep", "2", "all"), "state-6");
    review.execution.actions = {Action(5, P::ExecutionAction::Purge, "removed", "1", "amd64")};
    batch = Batch(P::ExecutionAction::Purge, {5});
    Require(P::VerifyDpkgStateTransition(before, after, review, batch, &error), "purged selection-only record rejected");
    Require(P::VerifyDpkgStateTransition(before, gone, review, batch, &error), "purged absent record rejected");
    batch.arguments.clear();
    Require(!P::VerifyDpkgStateTransition(before, gone, review, batch, &error), "implicit trigger effects accepted");
}
}
int main() {
    ParsingAndPending(); Evidence(); ImplicitMultiarchDeconfiguration(); BoundedTriggers(); Transitions();
    std::cout << "[apt-provider-dpkg-state] OK\n";
}
