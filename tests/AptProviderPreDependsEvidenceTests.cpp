/* Native depisok Pre-Depends fixtures based on dpkg's unpack/depcon call sites
 * and t-provides/t-multiarch cases. No dpkg child or filesystem mutation.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderPreDependsEvidence.hpp"
#if defined(CYDIA_PREDEPENDS_NATIVE_APT)
#include <apt-pkg/debversion.h>
#include <apt-pkg/pkgcache.h>
#endif
#include <cstdlib>
#include <iostream>
#include <stdexcept>
#include <utility>

namespace {
namespace A = CydiaAPT::Provider;
namespace B = A::BinaryRelationships;
namespace E = A::PreDependsEvidence;
using Package = std::shared_ptr<const B::Package>;
void Require(bool yes, const char *message) {
    if (!yes) { std::cerr << "[predepends-evidence] " << message << '\n'; std::exit(1); }
}
B::VersionComparison Compare(const std::string &a, const std::string &b) {
    B::VersionComparison result;
#if defined(CYDIA_PREDEPENDS_NATIVE_APT)
    result.status = B::ComparisonStatus::Compared; result.ordering = debVS.CmpVersion(a, b); return result;
#else
    // Explicit fixture answers only. This is not another production Debian
    // version comparator, nor a fallback when native comparison is absent.
    const std::vector<std::string> order{"1", "2", "3", "20"};
    for (std::size_t i = 0; i < order.size(); ++i) for (std::size_t j = 0; j < order.size(); ++j)
        if (a == order[i] && b == order[j]) {
            result.status = B::ComparisonStatus::Compared; result.ordering = i == j ? 0 : i < j ? -1 : 1; return result;
        }
    result.status = B::ComparisonStatus::InvalidVersion; return result;
#endif
}
Package P(const std::string &name = "consumer", const std::string &version = "2", const std::string &architecture = "amd64",
    const std::string &multi = "no", const std::string &provides = "") {
    Package result; B::Error error;
    Require(B::ParsePackage(name, version, architecture, multi, provides, &result, &error), "immutable package fixture"); return result;
}
std::string Key(const A::ExecutionPackage &package) { return package.package + ':' + package.architecture; }
struct Fixture {
    A::DpkgState state;
    A::InstalledTriggerMetadata metadata;
    Fixture() {
        state.packageStateIdentity = metadata.packageStateIdentity = "state:fixture";
        state.nativeArchitecture = "amd64"; state.registeredArchitectures = {"amd64", "i386"};
        metadata.evidenceIdentity.assign(64, 'a');
    }
    void Add(const A::ExecutionPackage &package, A::DpkgPackageStatus phase = A::DpkgPackageStatus::Installed,
        const std::string &configVersion = "", const std::string &provides = "", const std::string &multi = "no") {
        A::DpkgPackageState record; record.package = package; record.status = phase; record.selection = A::DpkgSelection::Install;
        record.multiArch = multi;
        if (phase == A::DpkgPackageStatus::TriggersPending) record.triggersPending = {"fixture-trigger"};
        if (phase == A::DpkgPackageStatus::TriggersAwaited) record.triggersAwaited = {"recipient:amd64"};
        state.packages[Key(package)] = record;
        A::TriggerPackageMetadata retained; retained.package = package; retained.diskStatus = phase;
        retained.configVersion = phase == A::DpkgPackageStatus::Installed || phase == A::DpkgPackageStatus::TriggersPending ? package.version : configVersion;
        retained.evidenceIdentity.assign(64, 'b'); retained.declarationIdentity.assign(64, 'c');
        std::string ignored;
        Require(CydiaPackages::CanonicalPackageEffectControlFields({{"multi-arch", multi}, {"provides", provides}}, &retained.controls, &ignored),
            "canonical retained fixture controls");
        metadata.packages[Key(package)] = retained;
    }
    E::Result Check(const std::string &text, const Package &incoming = P(),
        const std::vector<A::ExecutionPackage> &queued = {}, const B::VersionComparator &compare = Compare) const {
        std::shared_ptr<const B::Field> field; B::Error error;
        Require(B::ParseField(B::Kind::PreDepends, text, &field, &error), "immutable Pre-Depends fixture");
        return E::Evaluate(*field, *incoming, state, metadata, "amd64", compare, queued);
    }
};
E::Blocker OnlyBlocker(const E::Result &result, E::Reason reason) {
    Require(result.readiness == E::Readiness::Blocked && result.groups.size() == 1 &&
        result.groups[0].witnesses.empty() && result.groups[0].blockers.size() == 1 && result.groups[0].blockers[0].reason == reason,
        "exact expected native blocker"); return result.groups[0].blockers[0];
}
void NativeMetadataFreeReferenceRows() {
    Fixture fixture; fixture.Add({"target", "2", "amd64"});
    A::DpkgPackageState reference; reference.package.package = "unrelated-virtual";
    reference.status = A::DpkgPackageStatus::NotInstalled; reference.multiArch = "no";
    fixture.state.packages["unrelated-virtual:"] = reference;
    Require(fixture.Check("target (>= 2)").readiness == E::Readiness::Ready,
        "native Multi-Arch:no metadata-free reference cannot obstruct an unrelated real Pre-Depends");
    OnlyBlocker(fixture.Check("unrelated-virtual"), E::Reason::MissingCandidate);
    for (const auto *multi : {"foreign", "same", "allowed"}) {
        auto invalid = fixture;
        invalid.state.packages.at("unrelated-virtual:").multiArch = multi;
        Require(invalid.Check("target").readiness == E::Readiness::Unsupported,
            "an actual binary Multi-Arch mode cannot be inferred for a metadata-free reference");
    }
    for (unsigned variant = 0; variant != 5; ++variant) {
        auto invalid = fixture; auto &row = invalid.state.packages.at("unrelated-virtual:");
        if (variant == 0) row.status = A::DpkgPackageStatus::ConfigFiles;
        if (variant == 1) row.reinstallRequired = true;
        if (variant == 2) row.triggersPending = {"unexpected"};
        if (variant == 3) row.triggersAwaited = {"target:amd64"};
        if (variant == 4) row.package.architecture = "amd64";
        Require(invalid.Check("target").readiness == E::Readiness::Unsupported,
            "metadata-free spelling never hides phase/error/trigger/partial-identity corruption");
    }
    fixture.state.packages.at("unrelated-virtual:").multiArch.clear();
    Require(fixture.Check("target").readiness == E::Readiness::Ready, "previous empty native reference spelling remains supported");
}
void DirectCurrentAndHistoricalVersions() {
    for (const auto phase : {A::DpkgPackageStatus::Installed, A::DpkgPackageStatus::TriggersPending}) {
        Fixture f; f.Add({"target", "2", "amd64"}, phase);
        auto result = f.Check("target (>= 2)");
        Require(result.readiness == E::Readiness::Ready && result.groups[0].witnesses.size() == 1 &&
            !result.groups[0].witnesses[0].historicalVersionRequired && result.groups[0].witnesses[0].candidate.queryStatus == phase &&
            result.groups[0].witnesses[0].candidate.match.comparedVersion == "2", "configured current version and actual phase retained");
        OnlyBlocker(f.Check("target (>> 2)"), E::Reason::CurrentVersionMismatch);
    }
    for (const auto phase : {A::DpkgPackageStatus::Unpacked, A::DpkgPackageStatus::HalfConfigured, A::DpkgPackageStatus::TriggersAwaited}) {
        Fixture f; f.Add({"target", "2", "amd64"}, phase, "1");
        auto result = f.Check("target (>= 1)");
        Require(result.readiness == E::Readiness::Ready && result.groups[0].witnesses[0].historicalVersionRequired &&
            result.groups[0].witnesses[0].candidate.queryStatus == phase && result.groups[0].witnesses[0].candidate.diskStatus == phase &&
            result.groups[0].witnesses[0].candidate.configVersion == "1", "direct historical eligibility never normalizes actual phase");
        const auto &history = OnlyBlocker(f.Check("target (>= 2)"), E::Reason::ConfiguredVersionMismatch);
        Require(history.hasCandidate && history.candidate.match.version == "2" && history.candidate.configVersion == "1",
            "current version cannot substitute for latest configured version");
        f.metadata.packages.at("target:amd64").configVersion = "3";
        OnlyBlocker(f.Check("target (>= 3)"), E::Reason::CurrentVersionMismatch);
        f.metadata.packages.at("target:amd64").configVersion.clear();
        OnlyBlocker(f.Check("target"), E::Reason::NeverConfigured);
    }
    for (const auto phase : {A::DpkgPackageStatus::NotInstalled, A::DpkgPackageStatus::ConfigFiles, A::DpkgPackageStatus::HalfInstalled}) {
        Fixture f; f.Add({"target", "2", "amd64"}, phase, phase == A::DpkgPackageStatus::NotInstalled ? "" : "2");
        OnlyBlocker(f.Check("target"), E::Reason::PhaseNotEligible);
    }
    Fixture incorporated; incorporated.Add({"target", "2", "amd64"});
    incorporated.state.packages.at("target:amd64").status = A::DpkgPackageStatus::TriggersAwaited;
    incorporated.state.packages.at("target:amd64").triggersAwaited = {"recipient:amd64"};
    const auto evidence = incorporated.Check("target (>= 2)");
    Require(evidence.readiness == E::Readiness::Ready && evidence.groups[0].witnesses[0].candidate.queryStatus == A::DpkgPackageStatus::TriggersAwaited &&
        evidence.groups[0].witnesses[0].candidate.diskStatus == A::DpkgPackageStatus::Installed,
        "query-incorporated awaiter uses raw installed Config-Version without hiding either phase");
}
void VirtualProvidersAndAlternatives() {
    for (const auto phase : {A::DpkgPackageStatus::Installed, A::DpkgPackageStatus::TriggersPending}) {
        Fixture f; f.Add({"provider", "20", "i386"}, phase, "", "virtual (= 1), virtual (= 3)");
        const auto result = f.Check("virtual (>= 3)");
        Require(result.readiness == E::Readiness::Ready && result.groups[0].witnesses[0].candidate.match.provide == 1 &&
            result.groups[0].witnesses[0].candidate.match.comparedVersion == "3" &&
            result.groups[0].witnesses[0].candidate.match.version == "20", "unpack virtual matching preserves provided version and native call-site architecture rule");
    }
    for (const auto phase : {A::DpkgPackageStatus::Unpacked, A::DpkgPackageStatus::HalfConfigured, A::DpkgPackageStatus::TriggersAwaited}) {
        Fixture f; f.Add({"provider", "20", "amd64"}, phase, "20", "virtual (= 3)");
        const auto &blocker = OnlyBlocker(f.Check("virtual (>= 3)"), E::Reason::PhaseNotEligible);
        Require(blocker.candidate.match.provide == 0 && blocker.candidate.configVersion == "20", "provider historical version cannot rescue unconfigured or awaited phase");
        OnlyBlocker(f.Check("virtual (>= 3)", P(), {}, [](const std::string &, const std::string &) -> B::VersionComparison {
            throw std::runtime_error("must not consult ineligible provider version");
        }), E::Reason::PhaseNotEligible);
    }
    Fixture versionless; versionless.Add({"provider", "20", "amd64"}, A::DpkgPackageStatus::Installed, "", "virtual");
    Require(versionless.Check("virtual").readiness == E::Readiness::Ready, "versionless Provides satisfies versionless Pre-Depends");
    OnlyBlocker(versionless.Check("virtual (>= 1)"), E::Reason::CurrentVersionMismatch);
    Fixture alternatives; alternatives.Add({"history", "2", "amd64"}, A::DpkgPackageStatus::HalfConfigured, "1");
    alternatives.Add({"provider", "20", "amd64"}, A::DpkgPackageStatus::Installed, "", "virtual (= 3)");
    const auto result = alternatives.Check("missing | virtual (>= 3), history (>= 1) | absent");
    Require(result.readiness == E::Readiness::Ready && result.groups.size() == 2 && result.groups[0].blockers.empty() &&
        result.groups[0].witnesses[0].candidate.match.alternative == 1 && result.groups[1].witnesses[0].candidate.match.alternative == 0,
        "OR alternatives and AND groups retain exact witnesses without irrelevant blockers");
    const auto blocked = alternatives.Check("virtual (>= 3), absent");
    Require(blocked.readiness == E::Readiness::Blocked && blocked.groups[0].witnesses.size() == 1 &&
        blocked.groups[1].blockers.size() == 1 && !blocked.groups[1].blockers[0].hasCandidate && blocked.groups[1].blockers[0].group == 1,
        "a missing later group blocks the complete field and names its exact group");
}
void QueuedEffectsAndIncomingIdentity() {
    Fixture f; f.Add({"target", "2", "amd64"});
    f.Add({"provider", "20", "amd64"}, A::DpkgPackageStatus::Installed, "", "virtual (= 3)");
    OnlyBlocker(f.Check("target (>= 1)", P(), {{"target", "2", "amd64"}}), E::Reason::QueuedDeconfiguration);
    OnlyBlocker(f.Check("virtual (>= 1)", P(), {{"provider", "20", "amd64"}}), E::Reason::QueuedDeconfiguration);
    f.state.packages.at("target:amd64").status = f.metadata.packages.at("target:amd64").diskStatus = A::DpkgPackageStatus::HalfConfigured;
    Require(f.Check("target (>= 1)").readiness == E::Readiness::Ready, "already observed prior-child deconfiguration may use actual retained history");
    Require(f.Check("target", P(), {{"target", "2", "amd64"}}).readiness == E::Readiness::Unsupported,
        "nonconfigured actual generation cannot masquerade as a newly queued configured victim");
    Fixture self;
    auto result = self.Check("consumer (= 2), virtual (= 3)", P("consumer", "2", "amd64", "no", "virtual (= 3)"));
    Require(result.readiness == E::Readiness::Ready && result.groups[0].witnesses[0].candidate.origin == E::Origin::Incoming &&
        result.groups[1].witnesses[0].candidate.origin == E::Origin::Incoming && result.groups[0].witnesses[0].candidate.metadataIdentity.empty(),
        "exact INSTALLNEW real and Provides self witnesses are distinct from installed evidence");
    OnlyBlocker(self.Check("consumer:i386 (= 2)"), E::Reason::MissingCandidate);
    self.Add({"consumer", "1", "amd64"}, A::DpkgPackageStatus::Installed, "", "old-virtual (= 1)");
    OnlyBlocker(self.Check("old-virtual (= 1)"), E::Reason::MissingCandidate);
    Require(self.Check("consumer (= 2)").readiness == E::Readiness::Ready, "INSTALLNEW uses incoming version rather than replaced old version");
    Require(self.Check("consumer", P(), {{"consumer", "1", "amd64"}}).readiness == E::Readiness::Unsupported,
        "contradictory INSTALLNEW and queued-deconfiguration identity does not authorize self rescue");
    Fixture portable; portable.Add({"consumer", "1", "all"}, A::DpkgPackageStatus::Installed, "", "old-virtual");
    Require(portable.Check("consumer (= 2)").readiness == E::Readiness::Ready, "all-to-native singleton replacement keeps exact incoming self identity");
    OnlyBlocker(portable.Check("old-virtual"), E::Reason::MissingCandidate);
    Fixture coinstalled; coinstalled.Add({"consumer", "1", "i386"}, A::DpkgPackageStatus::Installed, "", "foreign-virtual", "same");
    result = coinstalled.Check("foreign-virtual", P("consumer", "2", "amd64", "same"));
    Require(result.readiness == E::Readiness::Ready && result.groups[0].witnesses[0].candidate.origin == E::Origin::Installed,
        "distinct coinstalled Multi-Arch:same provider is not mistaken for replaced self");
    Fixture foreign; foreign.Add({"target", "2", "i386"});
    OnlyBlocker(foreign.Check("target"), E::Reason::MissingCandidate);
    foreign.metadata.packages.at("target:i386").controls["multi-arch"] = foreign.state.packages.at("target:i386").multiArch = "foreign";
    Require(foreign.Check("target").readiness == E::Readiness::Ready, "native Multi-Arch:foreign direct eligibility is retained");
    Fixture forgotten; forgotten.Add({"consumer", "1", "i386"}, A::DpkgPackageStatus::NotInstalled, "", "old-virtual");
    Require(forgotten.Check("").readiness == E::Readiness::Ready && forgotten.Check("consumer (= 2)").readiness == E::Readiness::Ready,
        "not-installed foreign metadata is not an installed singleton crossgrade");
    OnlyBlocker(forgotten.Check("old-virtual"), E::Reason::PhaseNotEligible);
}
void AtomicUnsupportedAndComparisonFailures() {
    Fixture f; f.Add({"target", "2", "amd64"});
    auto result = f.Check("target:native");
    Require(result.readiness == E::Readiness::Unsupported && result.error.code == B::ErrorCode::UnsupportedNativeQualifier && result.groups.empty(),
        "APT-only native qualifier is not guessed into native dpkg evidence");
    for (const auto status : {B::ComparisonStatus::Unavailable, B::ComparisonStatus::InvalidVersion, B::ComparisonStatus::Failed}) {
        result = f.Check("target (>= 1)", P(), {}, [status](const std::string &, const std::string &) {
            B::VersionComparison comparison; comparison.status = status; return comparison;
        });
        Require(result.readiness == E::Readiness::ComparisonFailed && result.groups.empty() && result.packageStateIdentity.empty(),
            "trusted comparison failure returns no partial readiness evidence");
    }
    result = f.Check("target (>= 1)", P(), {}, {});
    Require(result.readiness == E::Readiness::ComparisonFailed && result.error.code == B::ErrorCode::ComparisonUnavailable && result.groups.empty(),
        "missing trusted comparator cannot use lexical fallback");
    result = f.Check("target (>= 1)", P(), {}, [](const std::string &, const std::string &) -> B::VersionComparison { throw std::runtime_error("failure"); });
    Require(result.readiness == E::Readiness::ComparisonFailed && result.error.code == B::ErrorCode::ComparisonFailed && result.groups.empty(),
        "throwing comparator fails atomically");
    f.metadata.packages.at("target:amd64").configVersion = "1";
    Require(f.Check("target").readiness == E::Readiness::Unsupported, "raw installed phase cannot assert a different configured version");
    f.metadata.packages.at("target:amd64").configVersion = "2";
    f.metadata.packageStateIdentity = "different:state";
    Require(f.Check("target").readiness == E::Readiness::Unsupported, "metadata from a different protected state is unavailable");
    f.metadata.packageStateIdentity = f.state.packageStateIdentity; f.metadata.packages.erase("target:amd64");
    Require(f.Check("target").readiness == E::Readiness::Unsupported, "missing retained installed controls cannot be inferred");
    Fixture limit; limit.Add({"target", "2", "amd64"});
    limit.metadata.packages.at("target:amd64").controls["depends"].assign(E::MaximumInputBytes + 1, 'x');
    result = limit.Check("target");
    Require(result.readiness == E::Readiness::Unsupported && result.error.code == B::ErrorCode::LimitExceeded && result.groups.empty(),
        "oversized retained controls refuse before parsing or witness allocation");
    Fixture empty; Require(empty.Check("").readiness == E::Readiness::Ready, "empty Pre-Depends is vacuously ready without invented work");
    Fixture work; std::string provides, groups;
    for (unsigned i = 0; i < 256; ++i) {
        if (i) { provides += ", "; groups += ", "; }
        provides += "virtual" + std::to_string(i) + " (= 1)"; groups += "unmatched";
    }
    work.Add({"provider", "20", "amd64"}, A::DpkgPackageStatus::Installed, "", provides);
    result = work.Check(groups);
    Require(result.readiness == E::Readiness::Unsupported && result.error.code == B::ErrorCode::LimitExceeded && result.groups.empty(),
        "relationship/provider product is bounded before quadratic scans or partial blockers");
}
#if defined(CYDIA_PREDEPENDS_NATIVE_APT)
void NativeVersionSemantics() {
    // Production debVS ordering, rather than fixture numeric order, decides
    // both independently checked historical and current Debian versions.
    Fixture f; f.Add({"target", "1:2.0-1", "amd64"}, A::DpkgPackageStatus::HalfConfigured, "1:2.0~rc1-1");
    const std::vector<std::pair<std::string, int>> relations{{"<<", pkgCache::Dep::Less}, {"<=", pkgCache::Dep::LessEq},
        {"=", pkgCache::Dep::Equals}, {">=", pkgCache::Dep::GreaterEq}, {">>", pkgCache::Dep::Greater}};
    for (const auto &relation : relations) for (const auto &limit : {"1:2.0~rc1-1", "1:2.0-1", "1:2.0-2"}) {
        const bool expected = debVS.CheckDep("1:2.0-1", relation.second, limit) && debVS.CheckDep("1:2.0~rc1-1", relation.second, limit);
        Require((f.Check("target (" + relation.first + ' ' + limit + ')').readiness == E::Readiness::Ready) == expected,
            "native CheckDep differential covers both versions and every supported relation");
    }
    Require(f.Check("target (>= 1:2.0~rc1-1)").readiness == E::Readiness::Ready,
        "native epoch/tilde ordering permits both actual and historical version");
    OnlyBlocker(f.Check("target (>= 1:2.0-1)"), E::Reason::ConfiguredVersionMismatch);
    f.metadata.packages.at("target:amd64").configVersion = "1:2.0-01";
    Require(f.Check("target (= 1:2.0-1)").readiness == E::Readiness::Ready, "native equivalent revision spelling satisfies history");
    Fixture provider; provider.Add({"provider", "9:99", "amd64"}, A::DpkgPackageStatus::Installed, "", "virtual (= 1:2.0~rc1-1)");
    OnlyBlocker(provider.Check("virtual (>= 1:2.0-1)"), E::Reason::CurrentVersionMismatch);
}
#endif
}
int main() {
    NativeMetadataFreeReferenceRows();
    DirectCurrentAndHistoricalVersions(); VirtualProvidersAndAlternatives(); QueuedEffectsAndIncomingIdentity();
    AtomicUnsupportedAndComparisonFailures();
#if defined(CYDIA_PREDEPENDS_NATIVE_APT)
    NativeVersionSemantics();
#endif
    std::cout << "[predepends-evidence] PASS: native current/history/providers, exact queued effects, incoming self and typed failures\n";
}
