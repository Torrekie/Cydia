/* Pure native allowance fixtures; no dpkg execution or host mutation.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderDeconfigurationEffects.hpp"
#include <apt-pkg/debversion.h>
#include <algorithm>
#include <cstdlib>
#include <iostream>
#include <stdexcept>

namespace {
namespace A = CydiaAPT::Provider;
namespace B = A::BinaryRelationships;
namespace P = CydiaRuntime::Privileged;
void Require(bool value, const char *why) {
    if (!value) { std::cerr << "[deconfiguration-effects] " << why << '\n'; std::exit(1); }
}
B::VersionComparison Compare(const std::string &a, const std::string &b) {
    B::VersionComparison result; result.status = B::ComparisonStatus::Compared;
    result.ordering = debVS.CmpVersion(a, b); return result;
}
std::string Key(const A::ExecutionPackage &p) { return p.package + ':' + p.architecture; }
std::map<std::string, std::string> Controls(std::map<std::string, std::string> input = {}) {
    std::map<std::string, std::string> output; std::string error;
    Require(CydiaPackages::CanonicalPackageEffectControlFields(input, &output, &error), "canonical fixture controls"); return output;
}
A::ReviewedAction Action(std::uint64_t id, A::ExecutionAction kind, A::ExecutionPackage package, const std::string &archive = "") {
    A::ReviewedAction result; result.identifier = id; result.action = kind; result.package = std::move(package); result.archive = archive; return result;
}
P::Evidence File(const std::string &path, const std::string &bytes = "", bool absent = false) {
    P::Evidence result{}; result.path = path; result.bytes = bytes; result.absent = absent; result.adminAccess = true;
    // Native admin captures retain ReaderGroups' process metadata too; this
    // is not source-reader authority when sourceInput is false.
    result.sourceReaderGroups.valid = true; result.sourceReaderGroups.values = {0, 123};
    result.identity.st_mode = S_IFREG | 0755; result.identity.st_nlink = 1; result.identity.st_ino = 1;
    result.identity.st_size = bytes.size(); return result;
}
struct Fixture {
    A::TriggerEffectCheckpoint point;
    A::ReviewedTransaction review;
    std::vector<A::DeconfigurationIndexControl> incoming;
    Fixture() {
        point.packages.nativeArchitecture = "amd64"; point.packages.registeredArchitectures = {"amd64", "i386"};
        point.packages.packageStateIdentity = "state:fixture"; point.metadata.packageStateIdentity = "state:fixture";
        point.registry.synchronized = true; point.registry.evidenceIdentity.assign(64, 'a'); point.metadata.evidenceIdentity.assign(64, 'b');
        A::TriggerRegistryInput registry; registry.directoryPresent = true; registry.files["Lock"] = ""; std::string error;
        Require(A::ParseTriggerRegistry(registry, &point.registry.state, &error), "native empty registry");
        review.binding.providerIdentifier = "fixture"; review.binding.session.assign(64, '1');
        review.binding.configurationIdentity = "configuration:fixture"; review.binding.policyIdentity = "policy:fixture";
        review.binding.packageStateIdentity = point.packages.packageStateIdentity;
        review.binding.review = "review:fixture"; review.binding.cacheEpoch = review.binding.selectionRevision = 1;
        review.transaction.registeredArchitectures = point.packages.registeredArchitectures;
    }
    void Installed(A::ExecutionPackage package, std::map<std::string, std::string> fields = {},
        A::DpkgPackageStatus phase = A::DpkgPackageStatus::Installed) {
        A::DpkgPackageState state; state.package = package; state.selection = A::DpkgSelection::Install; state.status = phase;
        auto controls = Controls(std::move(fields)); state.multiArch = controls.at("multi-arch");
        point.packages.packages[Key(package)] = state;
        A::TriggerPackageMetadata metadata; metadata.package = package; metadata.controls = std::move(controls);
        metadata.diskStatus = phase; metadata.evidenceIdentity.assign(64, 'c'); metadata.declarationIdentity.assign(64, 'd');
        if (phase == A::DpkgPackageStatus::Installed || phase == A::DpkgPackageStatus::TriggersPending) metadata.configVersion = package.version;
        point.metadata.packages[Key(package)] = std::move(metadata);
    }
    void Archive(const std::string &id, A::ExecutionPackage package, std::map<std::string, std::string> fields = {}) {
        A::DeconfigurationIndexControl record; record.archive.identifier = id; record.archive.package = std::move(package);
        record.archive.path = "/archives/" + id + ".deb"; record.archive.size = 100;
        record.archive.hashes["SHA256"] = std::string(64, 'e'); record.controls = Controls(std::move(fields)); record.evidenceIdentity.assign(64, 'f');
        review.execution.archives.push_back(record.archive); incoming.push_back(std::move(record));
    }
    void Seal() {
        point.identity = A::TriggerEffectCheckpointIdentity(point); Require(!point.identity.empty(), "exact checkpoint");
    }
    bool Targets(std::vector<A::ExecutionPackage> *out, std::string *error, const B::VersionComparator &compare = Compare) {
        Seal(); return A::SelectDeconfigurationTargets(review, point, incoming, compare, out, error);
    }
    A::InstalledScriptMetadata Scripts(const std::vector<A::ExecutionPackage> &targets) const {
        A::InstalledScriptMetadata result; if (targets.empty()) return result;
        result.packageStateIdentity = point.packages.packageStateIdentity; result.evidenceIdentity.assign(64, 'a');
        auto directory = File("/fixture/admin/info"); directory.directory = directory.identityOnly = true;
        directory.identity.st_mode = S_IFDIR | 0755; directory.identity.st_nlink = 2;
        result.files = {File("/fixture/admin/status", "protected status\n"), directory,
            File("/fixture/admin/info/format", "1\n"), File("/fixture/admin/info/format-new", "", true)};
        for (const auto &target : targets) {
            const auto &metadata = point.metadata.packages.at(Key(target));
            A::InstalledPackageScripts selected; selected.package = target; selected.configVersion = metadata.configVersion;
            selected.diskStatus = metadata.diskStatus; selected.evidenceIdentity.assign(64, 'b');
            const bool qualified = metadata.controls.at("multi-arch") == "same";
            for (const char *kind : {"prerm", "postinst"}) {
                auto plain = File("/fixture/admin/info/" + target.package + '.' + kind, qualified ? "" : "trusted script\n", qualified);
                auto arch = File("/fixture/admin/info/" + Key(target) + '.' + kind, qualified ? "trusted script\n" : "", !qualified);
                if (std::string(kind) == "prerm") selected.prerm = qualified ? arch : plain;
                else selected.postinst = qualified ? arch : plain;
                result.files.push_back(plain); result.files.push_back(arch);
            }
            result.packages[Key(target)] = std::move(selected);
        }
        return result;
    }
    bool Build(A::DeconfigurationAllowanceSet *out, std::string *error) {
        std::vector<A::ExecutionPackage> targets;
        if (!Targets(&targets, error)) {
            std::cerr << "[deconfiguration-effects][selection] " << *error << '\n'; return false;
        }
        const bool built = A::BuildDeconfigurationAllowances(review, point, std::string(64, '9'), incoming, Scripts(targets), Compare, out, error);
        if (!built) std::cerr << "[deconfiguration-effects][binding] " << *error << '\n';
        return built;
    }
};
Fixture BreaksUpgrade() {
    Fixture f; f.Installed({"beta", "1", "amd64"}, {{"essential", "yes"}, {"protected", "yes"}});
    f.Archive("alpha-index", {"alpha", "2", "amd64"}, {{"breaks", "beta (<< 2)"}});
    f.Archive("beta-index", {"beta", "2", "amd64"});
    f.review.execution.actions = {Action(10, A::ExecutionAction::Unpack, {"alpha", "2", "amd64"}, "alpha-index"),
        Action(20, A::ExecutionAction::Unpack, {"beta", "2", "amd64"}, "beta-index"),
        Action(30, A::ExecutionAction::Configure, {"alpha", "2", "amd64"}),
        Action(40, A::ExecutionAction::Configure, {"beta", "2", "amd64"})}; return f;
}
void BoundOldVictimAndIdentity() {
    auto f = BreaksUpgrade(); A::DeconfigurationAllowanceSet pool; std::string error;
    Require(f.Build(&pool, &error) && pool.allowances.size() == 1, "protected/essential Breaks victim is not blanket excluded");
    const auto &allowance = pool.allowances.at("beta:amd64@1");
    Require(allowance.configVersion == "1" && allowance.causes.size() == 1 && allowance.causes[0].unpackAction == 10 &&
        allowance.causes[0].provide == B::DirectPackage && allowance.endpoint.action == 40 && allowance.endpoint.precedingUnpack == 20 &&
        allowance.endpoint.package.version == "2", "exact old generation, native witness and later new-generation configure bound");
    const auto first = pool.identity;
    std::reverse(f.incoming.begin(), f.incoming.end()); Require(f.Build(&pool, &error) && pool.identity == first, "index input order cannot renew approval");
    f.incoming.back().controls["essential"] = "yes";
    Require(f.Build(&pool, &error) && pool.identity != first, "canonical index controls bind identity even when opaque evidence token stays unchanged");
    f = BreaksUpgrade(); std::vector<A::ExecutionPackage> targets; Require(f.Targets(&targets, &error), "script subset");
    auto scripts = f.Scripts(targets); const auto unchangedTokens = scripts;
    auto &prerm = scripts.packages.at("beta:amd64").prerm; prerm.bytes = "different trusted script\n"; prerm.identity.st_size = prerm.bytes.size();
    for (auto &file : scripts.files) if (file.path == prerm.path) file = prerm;
    Require(A::BuildDeconfigurationAllowances(f.review, f.point, std::string(64, '9'), f.incoming, scripts, Compare, &pool, &error) && pool.identity != first,
        "exact script bytes bind identity without trusting asserted evidence hash alone");
    scripts = unchangedTokens; scripts.packages.at("beta:amd64").diskStatus = A::DpkgPackageStatus::Unpacked;
    Require(!A::BuildDeconfigurationAllowances(f.review, f.point, std::string(64, '9'), f.incoming, scripts, Compare, &pool, &error) && pool.identity.empty(),
        "raw phase conflict fails atomically");
    scripts = unchangedTokens; scripts.files.front().sourceDelegation.assign(A::MaximumDeconfigurationInputBytes + 1, 'x');
    Require(!A::BuildDeconfigurationAllowances(f.review, f.point, std::string(64, '9'), f.incoming, scripts, Compare, &pool, &error),
        "unbounded ancillary evidence is refused before serialization");
    scripts = unchangedTokens;
    scripts.files.front().sourceReaderGroups.values.assign(A::MaximumDeconfigurationEvidenceGroups + 1, 123);
    Require(!A::BuildDeconfigurationAllowances(f.review, f.point, std::string(64, '9'), f.incoming, scripts, Compare, &pool, &error),
        "supplementary-group metadata is bounded before serialization");
}
void EndpointsAndAtomicRefusal() {
    auto f = BreaksUpgrade(); std::vector<A::ExecutionPackage> targets{{"sentinel", "1", "all"}}; std::string error;
    f.review.execution.actions.pop_back(); Require(!f.Targets(&targets, &error) && targets.empty(), "missing endpoint grants no target");
    f = BreaksUpgrade(); f.review.execution.actions.push_back(Action(50, A::ExecutionAction::Remove, {"beta", "2", "amd64"}));
    Require(!f.Targets(&targets, &error), "competing configure/removal endpoints are not guessed");
    f = BreaksUpgrade(); f.review.execution.actions.back().package.version = "3";
    Require(!f.Targets(&targets, &error), "endpoint cannot invent an unreviewed victim version");
    f = BreaksUpgrade(); f.incoming.pop_back(); Require(!f.Targets(&targets, &error), "incomplete exact archive set refused");
    f = BreaksUpgrade(); f.incoming[0].archive.path += ".changed"; Require(!f.Targets(&targets, &error), "conflicting archive identity refused");
    f = BreaksUpgrade(); f.incoming[0].controls["breaks"] = "beta:native";
    Require(!f.Targets(&targets, &error), "native-unsupported relation never falls back to lexical or APT matching");
    f = BreaksUpgrade(); Require(!f.Targets(&targets, &error, {}), "missing trusted comparator is a refusal");
    f = BreaksUpgrade(); Require(!f.Targets(&targets, &error, [](const std::string &, const std::string &) -> B::VersionComparison { throw std::runtime_error("unavailable"); }),
        "comparator exception cannot authorize an allowance");
    Fixture paired; paired.Installed({"beta", "1", "amd64"}); paired.Archive("alpha", {"alpha", "2", "amd64"}, {{"breaks", "beta"}});
    paired.review.execution.actions = {Action(1, A::ExecutionAction::Unpack, {"alpha", "2", "amd64"}, "alpha"),
        Action(2, A::ExecutionAction::Remove, {"beta", "1", "amd64"}), Action(3, A::ExecutionAction::Purge, {"beta", "1", "amd64"}),
        Action(4, A::ExecutionAction::Configure, {"alpha", "2", "amd64"})};
    A::DeconfigurationAllowanceSet pool;
    Require(paired.Build(&pool, &error) && pool.allowances.at("beta:amd64@1").endpoint.action == 2 && pool.primaryReview.execution.actions.size() == 4,
        "ordinary Remove then Purge retains every primary ID with first terminating endpoint");
}
void MultiArchAndProviderOccurrences() {
    Fixture f; f.Installed({"alpha", "1", "amd64"}, {{"multi-arch", "same"}});
    f.Installed({"alpha", "1", "i386"}, {{"multi-arch", "same"}});
    f.Archive("native", {"alpha", "2", "amd64"}, {{"multi-arch", "same"}});
    f.Archive("foreign", {"alpha", "2", "i386"}, {{"multi-arch", "same"}});
    f.review.execution.actions = {Action(1, A::ExecutionAction::Unpack, {"alpha", "2", "amd64"}, "native"),
        Action(2, A::ExecutionAction::Unpack, {"alpha", "2", "i386"}, "foreign"),
        Action(3, A::ExecutionAction::Configure, {"alpha", "2", "amd64"}), Action(4, A::ExecutionAction::Configure, {"alpha", "2", "i386"})};
    A::DeconfigurationAllowanceSet pool; std::string error;
    Require(f.Build(&pool, &error) && pool.allowances.size() == 1 &&
        pool.allowances.at("alpha:i386@1").causes[0].kind == A::DeconfigurationCauseKind::SiblingVersionMismatch,
        "native sibling mismatch is bounded independently of auto-deconfigure and future unpacked native instance is not an old victim");
    Fixture direct; direct.Installed({"beta", "1", "amd64"}, {{"multi-arch", "same"}}); direct.Installed({"beta", "1", "i386"}, {{"multi-arch", "same"}});
    direct.Archive("alpha", {"alpha", "2", "amd64"}, {{"breaks", "beta"}});
    direct.review.execution.actions = {Action(1, A::ExecutionAction::Unpack, {"alpha", "2", "amd64"}, "alpha"),
        Action(2, A::ExecutionAction::Remove, {"beta", "1", "amd64"}), Action(3, A::ExecutionAction::Remove, {"beta", "1", "i386"}),
        Action(4, A::ExecutionAction::Configure, {"alpha", "2", "amd64"})};
    Require(direct.Build(&pool, &error) && pool.allowances.size() == 2,
        "distinct direct architectures and identical repeated bare-name absence evidence do not become virtual-provider ambiguity");
    Fixture provider; provider.Installed({"beta", "1", "amd64"}, {{"provides", "virtual (= 1)"}});
    provider.Archive("alpha", {"alpha", "2", "amd64"}, {{"breaks", "virtual (<< 2)"}});
    provider.review.execution.actions = {Action(1, A::ExecutionAction::Unpack, {"alpha", "2", "amd64"}, "alpha"),
        Action(2, A::ExecutionAction::Remove, {"beta", "1", "amd64"}), Action(3, A::ExecutionAction::Configure, {"alpha", "2", "amd64"})};
    Require(provider.Build(&pool, &error) && pool.allowances.at("beta:amd64@1").causes[0].provide == 0, "unique versioned provider witness retained");
    provider.Installed({"gamma", "1", "amd64"}, {{"provides", "virtual (= 1)"}});
    provider.review.execution.actions.push_back(Action(4, A::ExecutionAction::Remove, {"gamma", "1", "amd64"}));
    std::vector<A::ExecutionPackage> targets;
    Require(!provider.Targets(&targets, &error) && error == "provider_deconfiguration_provider_ambiguous", "multiple provider occurrences refuse");
    provider = Fixture(); provider.Installed({"beta", "1", "amd64"}, {{"provides", "beta (= 1)"}});
    provider.Archive("alpha", {"alpha", "2", "amd64"}, {{"breaks", "beta"}});
    provider.review.execution.actions = {Action(1, A::ExecutionAction::Unpack, {"alpha", "2", "amd64"}, "alpha"),
        Action(2, A::ExecutionAction::Remove, {"beta", "1", "amd64"}), Action(3, A::ExecutionAction::Configure, {"alpha", "2", "amd64"})};
    Require(!provider.Targets(&targets, &error) && error == "provider_deconfiguration_provider_ambiguous", "direct plus provided occurrence cannot be collapsed to one victim");
}
void ReplacementsAndFutureCutoff() {
    for (const bool toAll : {false, true}) {
        Fixture f; const std::string old = toAll ? "amd64" : "all", next = toAll ? "all" : "amd64";
        f.Installed({"alpha", "1", old}); f.Archive("alpha", {"alpha", "2", next});
        f.review.execution.actions = {Action(1, A::ExecutionAction::Unpack, {"alpha", "2", next}, "alpha"), Action(2, A::ExecutionAction::Configure, {"alpha", "2", next})};
        A::DeconfigurationAllowanceSet pool; std::string error;
        Require(f.Build(&pool, &error) && pool.allowances.empty() && pool.primaryReview.execution.actions.size() == 2,
            "single all/native replacement is a primary transition, not sibling deconfiguration");
    }
    Fixture removed; removed.Installed({"beta", "1", "amd64"}); removed.Archive("alpha", {"alpha", "2", "amd64"}, {{"breaks", "beta"}});
    removed.review.execution.actions = {Action(1, A::ExecutionAction::Remove, {"beta", "1", "amd64"}),
        Action(2, A::ExecutionAction::Unpack, {"alpha", "2", "amd64"}, "alpha"), Action(3, A::ExecutionAction::Configure, {"alpha", "2", "amd64"})};
    A::DeconfigurationAllowanceSet pool; std::string error; std::vector<A::ExecutionPackage> targets;
    Require(removed.Build(&pool, &error) && pool.allowances.empty(), "already explicitly removed generation needs no second endpoint");
    Fixture removedFuture; removedFuture.Installed({"beta", "1", "amd64"});
    removedFuture.Archive("beta", {"beta", "2", "amd64"}); removedFuture.Archive("alpha", {"alpha", "3", "amd64"}, {{"breaks", "beta (>= 2)"}});
    removedFuture.review.execution.actions = {Action(1, A::ExecutionAction::Unpack, {"beta", "2", "amd64"}, "beta"),
        Action(2, A::ExecutionAction::Configure, {"beta", "2", "amd64"}), Action(3, A::ExecutionAction::Remove, {"beta", "2", "amd64"}),
        Action(4, A::ExecutionAction::Unpack, {"alpha", "3", "amd64"}, "alpha"), Action(5, A::ExecutionAction::Configure, {"alpha", "3", "amd64"})};
    Require(removedFuture.Build(&pool, &error) && pool.allowances.empty(), "explicitly removed future generation is not retained as a later victim");
    Fixture future; future.Installed({"beta", "1", "amd64"}, {}, A::DpkgPackageStatus::Unpacked);
    future.Archive("alpha", {"alpha", "2", "amd64"}, {{"breaks", "beta"}});
    future.review.execution.actions = {Action(1, A::ExecutionAction::Configure, {"beta", "1", "amd64"}),
        Action(2, A::ExecutionAction::Unpack, {"alpha", "2", "amd64"}, "alpha"), Action(3, A::ExecutionAction::Configure, {"alpha", "2", "amd64"})};
    Require(!future.Targets(&targets, &error) && error == "provider_deconfiguration_future_generation_unavailable", "newly configured initial nonconfigured victim is outside capture");
    future = Fixture(); future.Installed({"alpha", "1", "i386"}, {{"multi-arch", "same"}}, A::DpkgPackageStatus::Unpacked);
    future.Archive("alpha", {"alpha", "2", "amd64"}, {{"multi-arch", "same"}});
    future.review.execution.actions = {Action(1, A::ExecutionAction::Configure, {"alpha", "1", "i386"}),
        Action(2, A::ExecutionAction::Unpack, {"alpha", "2", "amd64"}, "alpha"), Action(3, A::ExecutionAction::Configure, {"alpha", "2", "amd64"})};
    Require(!future.Targets(&targets, &error) && error == "provider_deconfiguration_future_generation_unavailable", "future configured sibling refuses without a Breaks field");
    Fixture crossgrade; crossgrade.Installed({"alpha", "1", "amd64"}); crossgrade.Archive("alpha", {"alpha", "2", "i386"});
    crossgrade.review.execution.actions = {Action(1, A::ExecutionAction::Unpack, {"alpha", "2", "i386"}, "alpha"),
        Action(2, A::ExecutionAction::Configure, {"alpha", "2", "i386"})};
    Require(!crossgrade.Targets(&targets, &error) && error == "provider_deconfiguration_sibling_unsupported", "foreign noncoinstallable crossgrade remains outside bounded admission");
    crossgrade.point.packages.packages.at("alpha:amd64").package.version = "2";
    auto &sameVersion = crossgrade.point.metadata.packages.at("alpha:amd64"); sameVersion.package.version = sameVersion.configVersion = "2";
    Require(!crossgrade.Targets(&targets, &error) && error == "provider_deconfiguration_sibling_unsupported", "same-version foreign crossgrade cannot bypass the cutoff");
    auto limit = BreaksUpgrade(); limit.review.execution.actions.resize(A::MaximumDeconfigurationActions + 1);
    Require(!limit.Targets(&targets, &error) && targets.empty(), "bounded action count refuses before deriving any partial pool");
}
}
int main() {
    BoundOldVictimAndIdentity(); EndpointsAndAtomicRefusal(); MultiArchAndProviderOccurrences(); ReplacementsAndFutureCutoff();
    std::cout << "[deconfiguration-effects] PASS: immutable old-generation causes, exact endpoints, evidence and conservative cutoffs\n";
}
