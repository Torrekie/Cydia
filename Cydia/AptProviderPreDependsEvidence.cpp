/* Native dpkg 1.21/1.23 src/main/depcon.c::depisok and
 * lib/dpkg/{depcon,parse,version}.c; no dependency repair or execution.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderPreDependsEvidence.hpp"
#include <set>
#include <utility>

namespace CydiaAPT { namespace Provider { namespace PreDependsEvidence {
namespace {
namespace B = BinaryRelationships;
using Package = std::shared_ptr<const B::Package>;
struct Budget {
    std::size_t bytes = 0, output = 0, steps = 0;
    bool Input(std::size_t n) { if (n > MaximumInputBytes - bytes) return false; bytes += n; return true; }
    bool Output(std::size_t n) { if (n > MaximumOutputBytes - output) return false; output += n; return true; }
    bool Step() { return ++steps <= MaximumSteps; }
};
std::string Key(const ExecutionPackage &p) { return p.package + ':' + p.architecture; }
bool Same(const ExecutionPackage &a, const ExecutionPackage &b) {
    return a.package == b.package && a.version == b.version && a.architecture == b.architecture;
}
bool Digest(const std::string &s) { return s.size() == 64 && s.find_first_not_of("0123456789abcdef") == std::string::npos; }
bool Identity(const std::string &s) {
    if (s.empty() || s.size() > 4096) return false;
    for (unsigned char c : s) if (c <= 32 || c >= 127) return false;
    return true;
}
bool Configured(DpkgPackageStatus s) { return s >= DpkgPackageStatus::TriggersAwaited; }
bool Active(DpkgPackageStatus s) { return s == DpkgPackageStatus::Installed || s == DpkgPackageStatus::TriggersPending; }
bool Historical(DpkgPackageStatus s) {
    return s == DpkgPackageStatus::Unpacked || s == DpkgPackageStatus::HalfConfigured || s == DpkgPackageStatus::TriggersAwaited;
}
Result Failure(B::ErrorCode code) {
    Result result; result.error.code = code;
    switch (code) {
        case B::ErrorCode::ComparisonUnavailable: case B::ErrorCode::ComparisonInvalidVersion:
        case B::ErrorCode::ComparisonFailed: result.readiness = Readiness::ComparisonFailed; break;
        default: break;
    }
    return result;
}
Result Failure(const B::Error &error) { auto result = Failure(error.code); result.error = error; return result; }
bool PackageBytes(const B::Package &p, Budget *budget) {
    return p.provides && budget->Input(p.name.size()) && budget->Input(p.version.size()) &&
        budget->Input(p.architecture.size()) && budget->Input(p.provides->canonical.size());
}
std::string Versionless(const B::Field &field) {
    std::string text;
    for (const auto &group : field.groups) {
        if (!text.empty()) text += ", ";
        bool first = true;
        for (const auto &atom : group.alternatives) {
            if (!first) text += " | "; first = false; text += atom.package;
            if (atom.qualifier != B::Qualifier::Implicit) text += ':' + atom.architecture;
        }
    }
    return text;
}
bool Satisfies(const B::Atom &atom, const std::string &version, const B::VersionComparator &compare,
    Budget *budget, bool *matches, B::ErrorCode *error) {
    *matches = false;
    if (atom.relation == B::Relation::None) { *matches = true; return true; }
    // Native versioned Provides cannot borrow the real package's Version.
    if (version.empty()) return true;
    if (!budget->Step()) { *error = B::ErrorCode::LimitExceeded; return false; }
    if (!compare) { *error = B::ErrorCode::ComparisonUnavailable; return false; }
    B::VersionComparison compared;
    try { compared = compare(version, atom.version); }
    catch (...) { *error = B::ErrorCode::ComparisonFailed; return false; }
    switch (compared.status) {
        case B::ComparisonStatus::Unavailable: *error = B::ErrorCode::ComparisonUnavailable; return false;
        case B::ComparisonStatus::InvalidVersion: *error = B::ErrorCode::ComparisonInvalidVersion; return false;
        case B::ComparisonStatus::Failed: *error = B::ErrorCode::ComparisonFailed; return false;
        case B::ComparisonStatus::Compared: break;
        default: *error = B::ErrorCode::ComparisonFailed; return false;
    }
    switch (atom.relation) {
        case B::Relation::Less: *matches = compared.ordering < 0; break;
        case B::Relation::LessEqual: *matches = compared.ordering <= 0; break;
        case B::Relation::Equal: *matches = compared.ordering == 0; break;
        case B::Relation::GreaterEqual: *matches = compared.ordering >= 0; break;
        case B::Relation::Greater: *matches = compared.ordering > 0; break;
        case B::Relation::None: break;
    }
    return true;
}
struct Candidate {
    Package package;
    const DpkgPackageState *state = nullptr;
    const TriggerPackageMetadata *metadata = nullptr;
    bool queued = false;
    Candidate(Package package, const DpkgPackageState *state, const TriggerPackageMetadata *metadata, bool queued) :
        package(std::move(package)), state(state), metadata(metadata), queued(queued) {}
};
bool OutputBytes(const CandidateEvidence &c, Budget *budget) {
    return budget->Output(sizeof(CandidateEvidence) + c.match.package.size() + c.match.version.size() +
        c.match.architecture.size() + c.match.comparedVersion.size() + c.configVersion.size() + c.metadataIdentity.size());
}
bool StateBytes(const DpkgPackageState &record, Budget *budget) {
    if (!budget->Input(record.package.package.size()) || !budget->Input(record.package.version.size()) ||
        !budget->Input(record.package.architecture.size()) || !budget->Input(record.multiArch.size())) return false;
    for (const auto *list : {&record.triggersPending, &record.triggersAwaited}) {
        if (list->size() > MaximumPackages) return false;
        for (const auto &entry : *list) if (!budget->Input(entry.size())) return false;
    }
    return true;
}
}

Result Evaluate(const B::Field &field, const B::Package &incoming, const DpkgState &state,
    const InstalledTriggerMetadata &metadata, const std::string &native, const B::VersionComparator &compare,
    const std::vector<ExecutionPackage> &queued) {
    Budget budget; B::Error parsed;
    if (field.kind != B::Kind::PreDepends) return Failure(B::ErrorCode::UnsupportedUse);
    if (!Identity(state.packageStateIdentity) || metadata.packageStateIdentity != state.packageStateIdentity ||
        state.nativeArchitecture != native || state.packages.size() > MaximumPackages || metadata.packages.size() > MaximumPackages ||
        queued.size() > MaximumPackages || !budget.Input(field.canonical.size()) || !PackageBytes(incoming, &budget) ||
        !budget.Input(state.packageStateIdentity.size()) || !budget.Input(metadata.evidenceIdentity.size()))
        return Failure(B::ErrorCode::InvalidInput);
    Package probe;
    if (native == "all" || !B::ParsePackage("native-probe", "1", native, "no", "", &probe, &parsed))
        return Failure(B::ErrorCode::InvalidArchitecture);
    if (state.registeredArchitectures.empty() || state.registeredArchitectures.size() > 256 ||
        state.registeredArchitectures.front() != native) return Failure(B::ErrorCode::InvalidArchitecture);
    std::set<std::string> architectures;
    for (const auto &architecture : state.registeredArchitectures) {
        if (architecture == "all" || !B::ParsePackage("native-probe", "1", architecture, "no", "", &probe, &parsed) ||
            !architectures.insert(architecture).second || !budget.Input(architecture.size()))
            return Failure(B::ErrorCode::InvalidArchitecture);
    }
    if (incoming.architecture != "all" && !architectures.count(incoming.architecture)) return Failure(B::ErrorCode::InvalidArchitecture);
    std::map<std::string, ExecutionPackage> queuedByInstance;
    for (const auto &generation : queued) {
        if (!budget.Input(generation.package.size()) || !budget.Input(generation.version.size()) ||
            !budget.Input(generation.architecture.size())) return Failure(B::ErrorCode::LimitExceeded);
        const auto found = state.packages.find(Key(generation));
        if (found == state.packages.end() || !Same(found->second.package, generation) ||
            !Configured(found->second.status) || !queuedByInstance.emplace(Key(generation), generation).second)
            return Failure(B::ErrorCode::InvalidInput);
    }
    std::vector<Candidate> candidates;
    std::set<std::string> usedMetadata;
    std::size_t sameNameInstances = 0;
    for (const auto &item : state.packages) if (item.second.package.package == incoming.name &&
        item.second.status != DpkgPackageStatus::NotInstalled) ++sameNameInstances;
    for (const auto &item : state.packages) {
        const auto &record = item.second;
        if (!budget.Input(item.first.size()) || !StateBytes(record, &budget)) return Failure(B::ErrorCode::LimitExceeded);
        if (item.first != Key(record.package) || static_cast<unsigned>(record.status) > static_cast<unsigned>(DpkgPackageStatus::Installed) ||
            static_cast<unsigned>(record.selection) > static_cast<unsigned>(DpkgSelection::Purge))
            return Failure(B::ErrorCode::InvalidInput);
        if (record.package.version.empty() && record.package.architecture.empty()) {
            if (record.status != DpkgPackageStatus::NotInstalled || record.reinstallRequired || !record.multiArch.empty() ||
                !record.triggersPending.empty() || !record.triggersAwaited.empty()) return Failure(B::ErrorCode::InvalidInput);
            continue;
        }
        const auto retained = metadata.packages.find(item.first);
        if (retained == metadata.packages.end() || !Same(retained->second.package, record.package)) return Failure(B::ErrorCode::InvalidInput);
        const auto &control = retained->second; usedMetadata.insert(item.first);
        if (static_cast<unsigned>(control.diskStatus) > static_cast<unsigned>(DpkgPackageStatus::Installed) ||
            (record.status != control.diskStatus && !(Configured(record.status) && Configured(control.diskStatus))) ||
            !Digest(control.evidenceIdentity) || (!control.configVersion.empty() && !B::ValidVersion(control.configVersion)) ||
            (Active(control.diskStatus) && control.configVersion != record.package.version) ||
            (control.diskStatus == DpkgPackageStatus::NotInstalled && !control.configVersion.empty()) ||
            !budget.Input(control.configVersion.size()) || !budget.Input(control.evidenceIdentity.size()))
            return Failure(B::ErrorCode::InvalidInput);
        for (const auto &value : control.controls)
            if (!budget.Input(value.first.size()) || !budget.Input(value.second.size())) return Failure(B::ErrorCode::LimitExceeded);
        std::map<std::string, std::string> canonical; std::string ignored;
        if (!CydiaPackages::CanonicalPackageEffectControlFields(control.controls, &canonical, &ignored) || canonical != control.controls ||
            canonical["multi-arch"] != (record.multiArch.empty() ? "no" : record.multiArch)) return Failure(B::ErrorCode::InvalidInput);
        Package package;
        if (!B::ParsePackage(record.package.package, record.package.version, record.package.architecture,
            canonical["multi-arch"], canonical["provides"], &package, &parsed)) return Failure(parsed);
        if (package->architecture != "all" && !architectures.count(package->architecture)) return Failure(B::ErrorCode::InvalidArchitecture);
        // parse.c reuses the single installed instance for all/native changes;
        // coinstalled Multi-Arch:same foreign instances remain separate.
        bool replaced = package->name == incoming.name && package->architecture == incoming.architecture;
        if (package->name == incoming.name && record.status != DpkgPackageStatus::NotInstalled && !replaced &&
            !(package->multiArch == B::MultiArch::Same && incoming.multiArch == B::MultiArch::Same)) {
            if (sameNameInstances > 1 || !((package->architecture == "all" && incoming.architecture == native) ||
                (incoming.architecture == "all" && package->architecture == native))) return Failure(B::ErrorCode::UnsupportedUse);
            replaced = true;
        }
        if (replaced) {
            // INSTALLNEW and DECONFIGURE cannot simultaneously describe this
            // instance. Do not resolve contradictory parent claims by order.
            if (queuedByInstance.count(item.first)) return Failure(B::ErrorCode::InvalidInput);
            continue;
        }
        candidates.push_back({std::move(package), &record, &control, queuedByInstance.count(item.first) != 0});
    }
    if (usedMetadata.size() != metadata.packages.size()) return Failure(B::ErrorCode::InvalidInput);
    // Package is immutable/factory-created. The borrowed alias lives only for
    // this call and neither creates new provenance nor changes the source.
    candidates.push_back({Package(&incoming, [](const B::Package *) {}), nullptr, nullptr, false});
    std::vector<Package> matching;
    std::size_t workPerAtom = 0;
    for (const auto &candidate : candidates) {
        if (candidate.package->provides->atomCount >= MaximumSteps - workPerAtom) return Failure(B::ErrorCode::LimitExceeded);
        workPerAtom += 1 + candidate.package->provides->atomCount;
        matching.push_back(candidate.package);
    }
    if (field.atomCount && workPerAtom > MaximumSteps / field.atomCount) return Failure(B::ErrorCode::LimitExceeded);
    budget.steps = workPerAtom * field.atomCount;
    std::shared_ptr<const B::Field> shape;
    if (!B::ParseField(B::Kind::PreDepends, Versionless(field), &shape, &parsed)) return Failure(parsed);
    B::Evaluation structural;
    if (!B::Evaluate(*shape, incoming, matching, native, B::Use::UnpackChecks, compare, &structural, &parsed)) return Failure(parsed);
    Result result; result.readiness = Readiness::Ready; result.packageStateIdentity = state.packageStateIdentity;
    for (std::size_t g = 0; g < field.groups.size(); ++g) {
        GroupEvidence group;
        if (!budget.Output(sizeof(GroupEvidence))) return Failure(B::ErrorCode::LimitExceeded);
        std::vector<bool> present(field.groups[g].alternatives.size(), false);
        for (const auto &match : structural.groups[g].witnesses) {
            present[match.alternative] = true;
            const auto &candidate = candidates[match.candidate]; const auto &atom = field.groups[g].alternatives[match.alternative];
            CandidateEvidence evidence; evidence.match = match;
            if (candidate.state) {
                evidence.queryStatus = candidate.state->status; evidence.diskStatus = candidate.metadata->diskStatus;
                evidence.configVersion = candidate.metadata->configVersion; evidence.metadataIdentity = candidate.metadata->evidenceIdentity;
            } else evidence.origin = Origin::Incoming;
            Reason reason = Reason::PhaseNotEligible; bool accepted = false, historical = false;
            B::ErrorCode error = B::ErrorCode::None; bool current = false, configured = false;
            if (candidate.queued) reason = Reason::QueuedDeconfiguration;
            else if (candidate.state && ((match.provide != B::DirectPackage && !Active(candidate.state->status)) ||
                (match.provide == B::DirectPackage && !Active(candidate.state->status) && !Historical(candidate.state->status))))
                reason = Reason::PhaseNotEligible;
            else if (candidate.state && match.provide == B::DirectPackage && Historical(candidate.state->status) &&
                evidence.configVersion.empty()) reason = Reason::NeverConfigured;
            else {
                if (!Satisfies(atom, match.comparedVersion, compare, &budget, &current, &error)) return Failure(error);
                if (!current) reason = Reason::CurrentVersionMismatch;
                else {
                    historical = candidate.state && match.provide == B::DirectPackage && Historical(candidate.state->status);
                    if (historical && !Satisfies(atom, evidence.configVersion, compare, &budget, &configured, &error)) return Failure(error);
                    if (historical && !configured) reason = Reason::ConfiguredVersionMismatch;
                    else accepted = true;
                }
            }
            if (!OutputBytes(evidence, &budget)) return Failure(B::ErrorCode::LimitExceeded);
            if (accepted) { Witness witness; witness.candidate = std::move(evidence); witness.historicalVersionRequired = historical; group.witnesses.push_back(std::move(witness)); }
            else { Blocker blocker; blocker.group = g; blocker.alternative = match.alternative; blocker.reason = reason;
                blocker.hasCandidate = true; blocker.candidate = std::move(evidence); group.blockers.push_back(std::move(blocker)); }
        }
        for (std::size_t a = 0; a < present.size(); ++a) if (!present[a]) {
            if (!budget.Output(sizeof(Blocker))) return Failure(B::ErrorCode::LimitExceeded);
            Blocker blocker; blocker.group = g; blocker.alternative = a; group.blockers.push_back(std::move(blocker));
        }
        if (group.witnesses.empty()) result.readiness = Readiness::Blocked;
        else group.blockers.clear();
        result.groups.push_back(std::move(group));
    }
    return result;
}
}}} // namespace CydiaAPT::Provider::PreDependsEvidence
