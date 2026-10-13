/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderPrimaryReadiness.hpp"
#include <algorithm>
namespace CydiaAPT { namespace Provider {
namespace {
namespace B = BinaryRelationships;
std::string Key(const ExecutionPackage &p) { return p.package + ':' + p.architecture; }
bool Same(const ExecutionPackage &a, const ExecutionPackage &b) {
    return a.package == b.package && a.version == b.version && a.architecture == b.architecture;
}
struct Package { std::shared_ptr<const B::Package> parsed; std::map<B::Kind, std::shared_ptr<const B::Field>> fields; };
}
PrimaryReadinessResult EvaluatePrimaryRelationshipReadiness(const TriggerEffectCheckpoint &point,
    ExecutionAction action, const std::vector<ExecutionPackage> &targets, const B::VersionComparator &compare) {
    PrimaryReadinessResult result; result.checkpointIdentity = point.identity;
    result.reason = "provider_primary_relationship_unsupported";
    if (point.identity.empty() || point.identity != TriggerEffectCheckpointIdentity(point) ||
        !point.registry.synchronized || !point.registry.state.deferredPresent || !compare ||
        point.packages.packages.size() > B::MaximumCandidates || targets.size() > B::MaximumCandidates ||
        (action != ExecutionAction::Configure && action != ExecutionAction::Remove && action != ExecutionAction::Purge &&
         action != ExecutionAction::Triggers) ||
        (action != ExecutionAction::Triggers && targets.size() != 1)) return result;
    std::map<std::string, Package> parsed; std::size_t input = 0, steps = 0, output = 0;
    const auto charge = [&](std::size_t amount, std::size_t limit, std::size_t &used) {
        if (amount > limit - used) return false;
        used += amount;
        return true;
    };
    B::Error error;
    for (const auto &entry : point.metadata.packages) {
        const auto actual = point.packages.packages.find(entry.first);
        if (actual == point.packages.packages.end() || !Same(actual->second.package, entry.second.package)) return result;
        std::map<std::string, std::string> canonical; std::string reason;
        if (!CydiaPackages::CanonicalPackageEffectControlFields(entry.second.controls, &canonical, &reason) ||
            canonical != entry.second.controls || !entry.second.dependencyOrderVerified || entry.second.rawControlRecord.empty() ||
            !CydiaPackages::ValidPackageEffectControlFieldOrder(canonical, entry.second.dependencyOrder)) return result;
        for (const auto &field : canonical)
            if (!charge(field.first.size() + field.second.size(), B::MaximumInputBytes, input)) return result;
        Package p;
        if (!B::ParsePackage(entry.second.package.package, entry.second.package.version, entry.second.package.architecture,
            canonical.at("multi-arch"), canonical.at("provides"), &p.parsed, &error)) return result;
        for (const auto &field : std::vector<std::pair<const char *, B::Kind>>{
            {"depends", B::Kind::Depends}, {"pre-depends", B::Kind::PreDepends}, {"breaks", B::Kind::Breaks}}) {
            std::shared_ptr<const B::Field> value;
            if (!B::ParseField(field.second, canonical.at(field.first), &value, &error)) return result;
            p.fields.emplace(field.second, std::move(value));
        }
        parsed.emplace(entry.first, std::move(p));
    }
    std::set<std::string> selected;
    for (const auto &target : targets) {
        const auto found = point.packages.packages.find(Key(target));
        if (!selected.insert(Key(target)).second || found == point.packages.packages.end() ||
            !Same(found->second.package, target) || found->second.reinstallRequired || !parsed.count(found->first)) return result;
        if (action == ExecutionAction::Configure &&
            ((found->second.status != DpkgPackageStatus::Unpacked && found->second.status != DpkgPackageStatus::HalfConfigured) ||
             !found->second.triggersPending.empty() || !found->second.triggersAwaited.empty())) return result;
        if (action == ExecutionAction::Triggers && (found->second.triggersPending.empty() ||
            found->second.status < DpkgPackageStatus::TriggersAwaited)) return result;
    }
    const bool removal = action == ExecutionAction::Remove || action == ExecutionAction::Purge;
    std::vector<std::shared_ptr<const B::Package>> eligible;
    for (const auto &entry : point.packages.packages) if (parsed.count(entry.first) &&
        (!removal || !selected.count(entry.first)) && !entry.second.reinstallRequired &&
        (entry.second.status == DpkgPackageStatus::Installed || entry.second.status == DpkgPackageStatus::TriggersPending))
        eligible.push_back(parsed.at(entry.first).parsed);
    auto trustedCompare = [&](const std::string &a, const std::string &b) {
        B::VersionComparison value;
        try { value = compare(a, b); } catch (...) { value.status = B::ComparisonStatus::Failed; }
        return value;
    };
    const auto evaluate = [&](const std::string &slot, B::Kind kind,
        const std::vector<std::shared_ptr<const B::Package>> &candidates, bool mustMatch) {
        const auto &source = parsed.at(slot); const auto &field = *source.fields.at(kind);
        std::size_t width = 0;
        for (const auto &candidate : candidates) {
            if (candidate->provides->atomCount >= B::MaximumMatchSteps - width) return false;
            width += candidate->provides->atomCount + 1;
        }
        if (field.atomCount && width > (B::MaximumMatchSteps - steps) / field.atomCount) return false;
        steps += width * field.atomCount;
        PrimaryRelationshipObservation observation; observation.source = point.packages.packages.at(slot).package;
        observation.kind = kind; observation.canonical = field.canonical;
        if (!B::Evaluate(field, *source.parsed, candidates, point.packages.nativeArchitecture,
            B::Use::ConfigureChecks, trustedCompare, &observation.matches, &error)) {
            if (error.code == B::ErrorCode::ComparisonUnavailable || error.code == B::ErrorCode::ComparisonFailed ||
                error.code == B::ErrorCode::ComparisonInvalidVersion) result.readiness = PrimaryReadiness::ComparisonFailed;
            return false;
        }
        if (!charge(sizeof(observation) + observation.canonical.size(), B::MaximumWitnessBytes, output)) return false;
        for (const auto &group : observation.matches.groups) for (const auto &witness : group.witnesses)
            if (!charge(sizeof(witness) + witness.package.size() + witness.version.size() + witness.architecture.size() +
                witness.comparedVersion.size(), B::MaximumWitnessBytes, output)) return false;
        const bool accepted = mustMatch ? observation.matches.allGroupsMatched : !observation.matches.anyGroupMatched;
        result.relationships.push_back(std::move(observation));
        if (!accepted) { result.readiness = PrimaryReadiness::Blocked; result.reason = "provider_primary_relationship_blocked"; }
        return accepted;
    };
    // Native Configure checks all coinstalled instances before dependencies.
    if (action == ExecutionAction::Configure) for (const auto &entry : point.packages.packages) {
        if (entry.second.package.package != targets.front().package || selected.count(entry.first) ||
            entry.second.status <= DpkgPackageStatus::ConfigFiles) continue;
        if (entry.second.status < DpkgPackageStatus::Unpacked) { result.readiness = PrimaryReadiness::Blocked; return result; }
        const auto value = trustedCompare(entry.second.package.version, targets.front().version);
        if (value.status != B::ComparisonStatus::Compared) { result.readiness = PrimaryReadiness::ComparisonFailed; return result; }
        if (value.ordering) { result.readiness = PrimaryReadiness::Blocked; result.reason = "provider_primary_sibling_version_mismatch"; return result; }
    }
    for (const auto &entry : parsed) {
        const auto &state = point.packages.packages.at(entry.first);
        if (removal ? (selected.count(entry.first) || state.status < DpkgPackageStatus::Unpacked) : !selected.count(entry.first)) continue;
        if (!evaluate(entry.first, B::Kind::Depends, eligible, true) ||
            !evaluate(entry.first, B::Kind::PreDepends, eligible, true)) return result;
    }
    // Breaks against a package being configured use every real installed
    // breaker above ConfigFiles, including Unpacked/HalfConfigured breakers.
    if (action == ExecutionAction::Configure) {
        const std::vector<std::shared_ptr<const B::Package>> broken{parsed.at(Key(targets.front())).parsed};
        for (const auto &entry : parsed) if (!selected.count(entry.first) &&
            point.packages.packages.at(entry.first).status > DpkgPackageStatus::ConfigFiles &&
            !evaluate(entry.first, B::Kind::Breaks, broken, false)) return result;
    }
    result.readiness = PrimaryReadiness::Ready; result.reason.clear(); return result;
}
}}
