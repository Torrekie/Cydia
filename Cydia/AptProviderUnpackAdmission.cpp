/* Reads only independently selected native state and retained private archives.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderUnpackAdmission.hpp"
#include "Cydia/AptProviderConffilePolicy.hpp"
#include "Cydia/AptProviderDeconfigurationApproval.hpp"
#include "Cydia/AptProviderNativeVersionComparison.hpp"
#include "Cydia/RuntimeState.hpp"
#include "Cydia/RuntimeSnapshotInputs.hpp"
#include <apt-pkg/hashes.h>
#include <algorithm>
#include <chrono>
#include <unistd.h>

namespace CydiaAPT { namespace Provider {
namespace {
namespace P = CydiaRuntime::Privileged;
namespace N = NativeEffectPolicy;
namespace B = BinaryRelationships;
bool Fail(std::string *error, const char *code) {
    if (error) *error = code;
    return false;
}
std::string Key(const ExecutionPackage &p) { return p.package + ':' + p.architecture; }
std::string Generation(const ExecutionPackage &p) { return Key(p) + '@' + p.version; }
bool Same(const ExecutionPackage &a, const ExecutionPackage &b) {
    return a.package == b.package && a.architecture == b.architecture && a.version == b.version;
}
std::string Hash(const std::string &bytes) {
    Hashes hash(Hashes::SHA256SUM);
    return hash.Add(bytes.data(), bytes.size()) ? hash.GetHashString(Hashes::SHA256SUM).HashValue() : "";
}
bool WireEqual(const ArchiveManifest &a, const ArchiveManifest &b) {
    std::string x, y; return Encode(a, &x) && Encode(b, &y) && x == y;
}
bool AdmissionSnapshot(const P::Environment &environment, const TriggerStateSnapshot &reader,
    const std::function<bool()> &cancelled, std::string *value, std::string *error) {
    if (cancelled && cancelled()) return Fail(error, "provider_cancelled");
    P::Error reason;
    try {
        return reader ? reader(value, error) : (P::RuntimeSnapshot(environment, value, &reason, cancelled) ||
            Fail(error, "provider_dpkg_state_unavailable"));
    } catch (...) { return Fail(error, "provider_dpkg_state_unavailable"); }
}
bool Fresh(const BrokerEnvironment &selected, const NativeDpkgAuthority &native,
    const std::vector<InstalledComponentEvidence> &components, const ComponentSuccession &succession, const TriggerCaptureLock &lock,
    const std::function<bool()> &cancelled, std::string *error) {
    if ((cancelled && cancelled()) || geteuid() != 0 || !TriggerCaptureLockHeld(selected.environment, lock) ||
        selected.environment.dpkgRoot != native.dpkgRoot || selected.environment.dpkgAdmin != native.dpkgAdmin ||
        selected.executableSearchPath != native.executableSearchPath ||
        !RevalidateNativeDpkgAuthority(native, components, error) ||
        !succession.AuthorizeComponents(components, error)) return Fail(error, "provider_unpack_authority_changed");
    for (const auto &expected : components) {
        InstalledComponentEvidence actual;
        if (!CaptureTransactionComponent(expected.file.metadata.path, &actual, error, cancelled) ||
            !SameInstalledComponent(expected, actual)) return Fail(error, "provider_unpack_authority_changed");
    }
    std::set<std::string> executables(native.commands.begin(), native.commands.end());
    executables.insert(selected.environment.dpkg); executables.insert(selected.environment.dpkgQuery);
    for (const auto &path : executables) {
        ComponentClosureEvidence closure;
        if (!CaptureNativeDpkgClosure(native, path, components, &closure, error, cancelled) ||
            !succession.AuthorizeLaunch(closure, error)) return Fail(error, "provider_unpack_authority_changed");
    }
    return true;
}
bool AdmissionOrigin(const NativeDpkgAuthority &native, const ComponentSuccession &succession,
    const ReviewedTransaction &review, const std::string &expected, std::string *error) {
    std::vector<InstalledComponentEvidence> initial;
    return !expected.empty() && succession.AuthorizeOrigin(review, native.configurationIdentity, native.platformIdentity,
        &initial, error) && TriggerNativeAuthorityIdentity(native, initial) == expected ? true :
        Fail(error, "provider_unpack_origin_changed");
}
std::string AdmissionNativeGeneration(const NativeDpkgAuthority &native,
    const std::vector<InstalledComponentEvidence> &components, const std::string &origin) {
    // Identity-only view covers the physically recaptured current set, including
    // ledger-approved new dependency paths. It never changes the retained native
    // declaration, its componentPaths, producer inputs or initial approval.
    return TriggerNativeGenerationIdentity(native, components, origin);
}
bool EmptyStatus(const P::Environment &environment) {
    P::Evidence status; P::Error ignored;
    return P::CaptureSharedStateEvidence(environment.dpkgAdmin + "/status", false, false, &status, &ignored) &&
        !status.absent && status.bytes.find_first_not_of(" \t\r\n\v\f") == std::string::npos && P::RecheckEvidence({status}, &ignored);
}
bool MatchLaunch(const BrokerEnvironment &selected, const NativeDpkgAuthority &native,
    const std::vector<InstalledComponentEvidence> &components, const std::vector<std::string> &arguments,
    std::size_t prefixSize, N::Match *match, std::string *launch, std::string *error,
    const std::function<bool()> &cancelled) {
    if (prefixSize > arguments.size() || !N::SupportedProfile("dpkg-1.23.7-effects-1"))
        return Fail(error, "provider_unpack_launch_invalid");
    N::Inputs inputs;
    if (!BuildNativeEffectPolicyInputs(native, selected.environment.dpkg, components, "dpkg-1.23.7-effects-1",
        N::Role::Unpack, {arguments.begin(), arguments.begin() + prefixSize}, &inputs, error, cancelled)) return false;
    *match = N::MatchRecord(native.effectRecords, inputs, Hash);
    return (native.effectRecordState == NativeEffectRecordState::Parsed && match->status == N::Status::Matched &&
        match->settings && N::LaunchIdentity(inputs, arguments, Hash, launch)) || Fail(error, "provider_unpack_policy_unavailable");
}
// These are unmodeled effects of the current admission implementation, not
// assertions of dpkg defaults. The complete distribution record supplies the
// enabled force subset; absence of a flag is never guessed from argv.
bool Modeled(const N::Settings &settings) {
    if (settings.triggers != N::TriggerMode::Disabled || settings.noAct || settings.recursive || settings.pending ||
        settings.selectedOnly || settings.skipSameVersion || !settings.hooks.empty() || !settings.statusLoggers.empty() ||
        !settings.ignoreDepends.empty() || !settings.unmodeledOptions.empty()) return false;
    for (const auto force : settings.forces)
        if (force == N::Force::ConfigureAny || force == N::Force::Conflicts || force == N::Force::Depends ||
            force == N::Force::DependsVersion || force == N::Force::OverwriteDir ||
            force == N::Force::OverwriteDiverted) return false;
    return true;
}
bool Parse(const ExecutionPackage &identity, const std::map<std::string, std::string> &controls,
    std::shared_ptr<const B::Package> *package, std::map<B::Kind, std::shared_ptr<const B::Field>> *fields,
    std::string *error) {
    std::map<std::string, std::string> canonical; B::Error reason;
    if (!CydiaPackages::CanonicalPackageEffectControlFields(controls, &canonical, error) || canonical != controls ||
        !B::ParsePackage(identity.package, identity.version, identity.architecture,
            canonical.at("multi-arch"), canonical.at("provides"), package, &reason))
        return Fail(error, "provider_unpack_relationship_unsupported");
    for (const auto &entry : std::vector<std::pair<const char *, B::Kind>>{
        {"depends", B::Kind::Depends}, {"pre-depends", B::Kind::PreDepends}, {"breaks", B::Kind::Breaks},
        {"conflicts", B::Kind::Conflicts}, {"provides", B::Kind::Provides}, {"replaces", B::Kind::Replaces}}) {
        std::shared_ptr<const B::Field> field;
        if (!B::ParseField(entry.second, canonical.at(entry.first), &field, &reason))
            return Fail(error, "provider_unpack_relationship_unsupported");
        for (const auto &group : field->groups) for (const auto &atom : group.alternatives)
            if (atom.qualifier == B::Qualifier::Native) return Fail(error, "provider_unpack_relationship_unsupported");
        fields->emplace(entry.second, std::move(field));
    }
    return true;
}
std::string AdmissionGroupText(const B::Group &group) {
    std::string text;
    for (const auto &atom : group.alternatives) {
        if (!text.empty()) text += " | ";
        text += atom.package;
        if (atom.qualifier != B::Qualifier::Implicit)
            text += ':' + (atom.qualifier == B::Qualifier::Any ? std::string("any") :
                atom.qualifier == B::Qualifier::Native ? std::string("native") : atom.architecture);
        const char *relation = nullptr;
        switch (atom.relation) {
            case B::Relation::None: break;
            case B::Relation::Less: relation = "<<"; break;
            case B::Relation::LessEqual: relation = "<="; break;
            case B::Relation::Equal: relation = "="; break;
            case B::Relation::GreaterEqual: relation = ">="; break;
            case B::Relation::Greater: relation = ">>"; break;
        }
        if (relation) text += " (" + std::string(relation) + ' ' + atom.version + ')';
    }
    return text;
}
B::Kind AdmissionFieldKind(const std::string &name) {
    if (name == "pre-depends") return B::Kind::PreDepends;
    if (name == "breaks") return B::Kind::Breaks;
    if (name == "conflicts") return B::Kind::Conflicts;
    if (name == "provides") return B::Kind::Provides;
    if (name == "replaces") return B::Kind::Replaces;
    return B::Kind::Depends; // Only a separately validated captured sequence reaches here.
}
bool SameCause(const DeconfigurationCause &a, const DeconfigurationCause &b) {
    return a.kind == b.kind && a.unpackAction == b.unpackAction && a.archive == b.archive &&
        a.canonicalRelation == b.canonicalRelation && a.comparedVersion == b.comparedVersion &&
        a.group == b.group && a.alternative == b.alternative && a.provide == b.provide;
}
bool SameScript(const P::Evidence &a, const P::Evidence &b) {
    return P::SerializeSnapshotEvidence(a) == P::SerializeSnapshotEvidence(b);
}
bool AdmissionRestorationPoint(const P::Environment &environment, const RestorationDebtLedger &debt,
    const ProtectedRestorationCheckpoint &current, const DeconfigurationAllowanceSet &approval,
    const TriggerEffectCheckpoint &actual, std::string *error, const std::function<bool()> &cancelled) {
    P::Error ignored;
    return debt.AuthorizeCheckpoint(approval, current.observation(), error) &&
        current.observation().identity == actual.identity && current.trigger().identity == actual.identity &&
        current.trigger().packages.packageStateIdentity == actual.packages.packageStateIdentity &&
        P::RecheckEvidence(current.trigger().metadata.files, &ignored) && P::RecheckEvidence(current.scripts().files, &ignored) &&
        RecheckProtectedTriggerEvidence(environment, current.trigger().registry, error, cancelled) ? true :
        Fail(error, "provider_unpack_restoration_changed");
}
bool AdmissionSealArchives(const TransactionArchiveStore &store, const std::vector<StagedArchiveEvidence> &expected,
    std::string *error, const std::function<bool()> &cancelled) {
    std::vector<StagedArchiveEvidence> sealed;
    if (!store.Capture(&sealed, error, cancelled) || sealed.size() != expected.size()) return Fail(error, "provider_unpack_archive_changed");
    for (std::size_t i = 0; i < sealed.size(); ++i)
        if (!SameInstalledComponent(sealed[i].identity, expected[i].identity) || sealed[i].hashes != expected[i].hashes)
            return Fail(error, "provider_unpack_archive_changed");
    return true;
}
class AdmissionResultWriter {
    std::string bytes_ = "CYDIA-UNPACK-ORDERED-PREDEPENDS-1";
public:
    bool Field(const std::string &value) {
        const std::string size = std::to_string(value.size());
        if (size.size() + 2 > MaximumDeconfigurationOutputBytes - bytes_.size() ||
            value.size() > MaximumDeconfigurationOutputBytes - bytes_.size() - size.size() - 2) return false;
        bytes_ += size + ':' + value + ',';
        return true;
    }
    bool Number(std::uint64_t value) { return Field(std::to_string(value)); }
    bool Candidate(const PreDependsEvidence::CandidateEvidence &candidate) {
        const auto &match = candidate.match;
        return Number(match.group) && Number(match.alternative) && Number(match.candidate) && Number(match.provide) &&
            Field(match.package) && Field(match.version) && Field(match.architecture) && Field(match.comparedVersion) &&
            Number(static_cast<unsigned>(candidate.origin)) && Number(static_cast<unsigned>(candidate.queryStatus)) &&
            Number(static_cast<unsigned>(candidate.diskStatus)) && Field(candidate.configVersion) && Field(candidate.metadataIdentity);
    }
    std::string Identity() const { return Hash(bytes_); }
};
bool AdmissionResultBytes(const OrderedPreDependsEvidence &row, std::size_t *retained) {
    const auto add = [&](std::size_t amount) {
        if (amount > MaximumDeconfigurationOutputBytes - *retained) return false;
        *retained += amount; return true;
    };
    const auto candidate = [&](const PreDependsEvidence::CandidateEvidence &value) {
        return add(value.match.package.size()) && add(value.match.version.size()) && add(value.match.architecture.size()) &&
            add(value.match.comparedVersion.size()) && add(value.configVersion.size()) && add(value.metadataIdentity.size());
    };
    if (!add(sizeof(row)) || !add(row.archive.size()) || !add(row.canonicalGroup.size()) || !add(row.result.packageStateIdentity.size())) return false;
    for (const auto &group : row.result.groups) {
        if (!add(sizeof(group))) return false;
        for (const auto &witness : group.witnesses) if (!add(sizeof(witness)) || !candidate(witness.candidate)) return false;
        for (const auto &blocker : group.blockers) if (!add(sizeof(blocker)) || !candidate(blocker.candidate)) return false;
    }
    return true;
}
bool AdmissionResultsIdentity(const std::vector<OrderedPreDependsEvidence> &rows, std::string *identity) {
    AdmissionResultWriter writer;
    if (!writer.Number(rows.size())) return false;
    for (const auto &row : rows) {
        if (!writer.Number(row.unpackAction) || !writer.Field(row.archive) || !writer.Field(row.canonicalGroup) ||
            !writer.Number(row.field) || !writer.Number(row.group) || !writer.Number(static_cast<unsigned>(row.result.readiness)) ||
            !writer.Number(static_cast<unsigned>(row.result.error.code)) || !writer.Number(row.result.error.offset) ||
            !writer.Field(row.result.packageStateIdentity) || !writer.Number(row.result.groups.size())) return false;
        for (const auto &group : row.result.groups) {
            if (!writer.Number(group.witnesses.size()) || !writer.Number(group.blockers.size())) return false;
            for (const auto &witness : group.witnesses)
                if (!writer.Candidate(witness.candidate) || !writer.Number(witness.historicalVersionRequired)) return false;
            for (const auto &blocker : group.blockers)
                if (!writer.Number(blocker.group) || !writer.Number(blocker.alternative) || !writer.Number(static_cast<unsigned>(blocker.reason)) ||
                    !writer.Number(blocker.hasCandidate) || !writer.Candidate(blocker.candidate)) return false;
        }
    }
    *identity = writer.Identity(); return !identity->empty();
}
}
struct ProtectedUnpackAdmission::Data {
    UnpackAdmissionReadiness readiness = UnpackAdmissionReadiness::Unsupported;
    std::string identity, nativeIdentity, initialNativeIdentity, launchIdentity, approvalBytes;
    const ComponentSuccession *succession = nullptr;
    const RestorationDebtLedger *restoration = nullptr;
    DeconfigurationAllowanceSet approvalScope;
    N::Match policy;
    std::vector<std::string> arguments;
    std::size_t prefixSize = 0;
    TriggerEffectCheckpoint checkpoint;
    InstalledOwnershipMetadata installedOwnership;
    InstalledScriptMetadata scripts;
    std::vector<StagedArchiveEvidence> archives;
    std::vector<UnpackOwnershipArchive> inventories;
    std::shared_ptr<const ArchiveEvidenceSnapshot> sourceSnapshot;
    std::vector<VerifiedIndexControlEvidence> indexControls;
    std::vector<AdmittedDeconfigurationCause> causes;
    std::vector<OrderedPreDependsEvidence> orderedPreDepends;
    std::string orderedPreDependsIdentity;
    bool singleArchive = false, orderedChecksComplete = false;
    UnpackOwnershipResult ownership;
};
ProtectedUnpackAdmission::ProtectedUnpackAdmission(std::shared_ptr<const Data> data) : data_(std::move(data)) {}
UnpackAdmissionReadiness ProtectedUnpackAdmission::readiness() const { return data_->readiness; }
const std::string &ProtectedUnpackAdmission::identity() const { return data_->identity; }
const TriggerEffectCheckpoint &ProtectedUnpackAdmission::checkpoint() const { return data_->checkpoint; }
const std::vector<AdmittedDeconfigurationCause> &ProtectedUnpackAdmission::causes() const { return data_->causes; }
const UnpackOwnershipResult &ProtectedUnpackAdmission::ownership() const { return data_->ownership; }
const std::vector<OrderedPreDependsEvidence> &ProtectedUnpackAdmission::orderedPreDepends() const { return data_->orderedPreDepends; }
bool ProtectedUnpackAdmission::singleArchiveNativeChecksReady() const {
    return data_ && data_->readiness == UnpackAdmissionReadiness::FactsVerified && data_->singleArchive &&
        data_->orderedChecksComplete && !data_->orderedPreDependsIdentity.empty() && data_->checkpoint.registry.synchronized &&
        data_->checkpoint.registry.state.deferredPresent && data_->checkpoint.registry.state.deferred.empty() &&
        data_->policy.status == N::Status::Matched && data_->policy.settings && Modeled(*data_->policy.settings) &&
        std::all_of(data_->orderedPreDepends.begin(), data_->orderedPreDepends.end(), [](const OrderedPreDependsEvidence &row) {
            return row.result.readiness == PreDependsEvidence::Readiness::Ready;
        });
}

bool ProtectedUnpackAdmission::Capture(const BrokerEnvironment &selected, const NativeDpkgAuthority &native,
    const std::vector<InstalledComponentEvidence> &components, const ComponentSuccession &succession, const TransactionArchiveStore &store,
    const ProtectedDeconfigurationReview &approved, const RestorationDebtLedger &restoration,
    const ProtectedRestorationCheckpoint &currentPoint, const AuthorizedExecution &batch,
    const std::vector<std::string> &arguments, int receivedStatus, const TriggerCaptureLock &lock,
    std::shared_ptr<const ProtectedUnpackAdmission> *output, std::string *error,
    const std::function<bool()> &cancelled, const TriggerStateSnapshot &snapshot) {
    if (!output) return false;
    output->reset();
    const auto end = std::chrono::steady_clock::now() + std::chrono::milliseconds(30000);
    const auto cancel = [&] {
        try { return std::chrono::steady_clock::now() >= end || (cancelled && cancelled()); }
        catch (...) { return true; }
    };
    const TriggerStateSnapshot effectiveSnapshot = [&](std::string *value, std::string *reason) {
        return AdmissionSnapshot(selected.environment, snapshot, cancel, value, reason);
    };
    auto data = std::make_shared<Data>(); P::Error ignored;
    if (batch.action != ExecutionAction::Unpack || !batch.batch || batch.actions.empty() ||
        batch.actions.size() > MaximumDeconfigurationActions || batch.actions.size() != batch.archives.size() ||
        batch.optionPrefixSize > batch.arguments.size() || batch.statusOptionIndex >= batch.optionPrefixSize ||
        !approved.sourceSnapshot || !EncodeDeconfigurationApproval(approved.allowances, &data->approvalBytes, error) ||
        approved.allowances.initialCheckpoint != approved.checkpoint.identity ||
        !Fresh(selected, native, components, succession, lock, cancel, error)) return Fail(error, "provider_unpack_input_invalid");
    data->sourceSnapshot = approved.sourceSnapshot; data->succession = &succession;
    data->singleArchive = batch.archives.size() == 1;
    data->approvalScope = approved.allowances; data->restoration = &restoration;
    data->initialNativeIdentity = approved.allowances.nativeAuthorityIdentity;
    if (!AdmissionOrigin(native, succession, data->approvalScope.primaryReview, data->initialNativeIdentity, error)) return false;
    data->nativeIdentity = AdmissionNativeGeneration(native, components, data->initialNativeIdentity);
    if (data->nativeIdentity.empty()) return Fail(error, "provider_unpack_authority_changed");
    // Reproduce the exact native child argument preparation from retained
    // parser offsets. No searching for options among opaque operand/hook text.
    std::vector<std::string> bound, prefix, head, finalized;
    if (!P::BindDpkgArguments(selected.environment, batch.arguments, &bound, &ignored) ||
        !P::BindDpkgArguments(selected.environment, {batch.arguments.begin(), batch.arguments.begin() + batch.optionPrefixSize}, &prefix, &ignored) ||
        !P::BindDpkgArguments(selected.environment, {batch.arguments.begin(), batch.arguments.begin() + batch.statusOptionIndex}, &head, &ignored) ||
        prefix.size() > bound.size() || head.size() >= prefix.size() ||
        !std::equal(prefix.begin(), prefix.end(), bound.begin()) || !std::equal(head.begin(), head.end(), prefix.begin()) ||
        !FinalizeNativeChildArguments(bound, prefix.size(), head.size(), receivedStatus, &finalized) || finalized != arguments ||
        arguments.size() - prefix.size() != batch.archives.size())
        return Fail(error, "provider_unpack_launch_invalid");
    data->arguments = arguments; data->prefixSize = prefix.size();
    if (!MatchLaunch(selected, native, components, arguments, data->prefixSize, &data->policy,
        &data->launchIdentity, error, cancel)) return false;
    if (!Modeled(*data->policy.settings)) return Fail(error, "provider_unpack_policy_unsupported");
    std::string frozen;
    if (!AdmissionSnapshot(selected.environment, snapshot, cancel, &frozen, error)) return false;
    const auto stable = [&]() {
        std::string current;
        return Fresh(selected, native, components, succession, lock, cancel, error) &&
            AdmissionOrigin(native, succession, data->approvalScope.primaryReview, data->initialNativeIdentity, error) &&
            AdmissionSnapshot(selected.environment, snapshot, cancel, &current, error) && current == frozen;
    };
    const auto query = [&](const std::string &tool, const std::vector<std::string> &argv,
        std::size_t limit, std::string *bytes, bool allowEmpty) {
        if (!stable()) return false;
        CydiaRuntime::Dpkg::Runner reader(tool);
        const auto result = reader.RunAndCaptureBounded(argv, native.launchEnvironment, bytes, limit, 3000, cancel);
        const bool empty = allowEmpty && result.kind == CydiaRuntime::Dpkg::ResultKind::Exited &&
            result.error == 0 && result.code == 1 && bytes->empty() && EmptyStatus(selected.environment);
        return (result.succeeded() || empty) && stable();
    };
    std::string architecture, foreign, records; DpkgState state;
    const auto &environment = selected.environment;
    if (!query(environment.dpkg, {"--root=" + environment.dpkgRoot, "--admindir=" + environment.dpkgAdmin,
            "--print-architecture"}, 32768, &architecture, false) ||
        !query(environment.dpkg, {"--root=" + environment.dpkgRoot, "--admindir=" + environment.dpkgAdmin,
            "--print-foreign-architectures"}, 32768, &foreign, false) ||
        !query(environment.dpkgQuery, {"--admindir=" + environment.dpkgAdmin,
            "--showformat=" + std::string(DpkgStateQueryFormat()), "--show", "*"}, 32 * 1024 * 1024, &records, true) ||
        !ParseDpkgState(records, architecture, foreign, frozen, &state, error) ||
        state.nativeArchitecture != selected.runtime.architecture || state.registeredArchitectures != selected.runtime.registeredArchitectures ||
        !CaptureTriggerEffectCheckpoint(environment, state, lock, &data->checkpoint, error, cancel, effectiveSnapshot))
        return Fail(error, "provider_unpack_state_unavailable");
    if (!AdmissionRestorationPoint(environment, restoration, currentPoint, approved.allowances, data->checkpoint, error, cancel)) return false;
    InstalledOwnershipError ownershipError;
    if (!CaptureInstalledOwnership(environment, state, lock, &data->installedOwnership, &ownershipError, cancel, effectiveSnapshot) ||
        !store.Capture(&data->archives, error, cancel) || !stable()) return Fail(error, "provider_unpack_evidence_changed");
    const auto versionQuery = [&](const NativeVersionQueryRequest &request, const std::function<bool()> &boundedCancel) {
        NativeVersionQueryReply reply;
        if (request.nativeAuthorityIdentity != data->nativeIdentity || request.maximumOutputBytes != 1 ||
            request.timeoutMilliseconds > 3000 || !request.timeoutMilliseconds || request.arguments.size() != 4 ||
            request.arguments[0] != "--compare-versions" || (request.arguments[2] != "lt" && request.arguments[2] != "gt") || !stable()) return reply;
        std::vector<std::string> argv;
        if (!P::BindDpkgArguments(environment, request.arguments, &argv, &ignored)) return reply;
        CydiaRuntime::Dpkg::Runner reader(environment.dpkg);
        reply.result = reader.RunAndCaptureBounded(argv, native.launchEnvironment, &reply.output, 1, 3000, boundedCancel);
        if (!stable()) return NativeVersionQueryReply();
        reply.nativeAuthorityIdentity = data->nativeIdentity; return reply;
    };
    const auto cachedCompare = MakeNativeVersionComparator(data->nativeIdentity, versionQuery, cancel);
    const B::VersionComparator compare = [&](const std::string &a, const std::string &b) {
        B::VersionComparison failed; failed.status = B::ComparisonStatus::Failed;
        if (!stable()) return failed;
        auto value = cachedCompare(a, b);
        return stable() ? value : failed;
    };
    std::vector<VerifiedIndexControlEvidence> index;
    if (!approved.sourceSnapshot->ControlEvidence(approved.allowances.primaryReview.execution.archives, &index, cancel, error) ||
        index.size() != approved.indexControls.size()) return Fail(error, "provider_unpack_index_changed");
    for (std::size_t i = 0; i < index.size(); ++i)
        if (!index[i].dependencyOrderVerified || !approved.indexControls[i].dependencyOrderVerified ||
            !CydiaPackages::ValidPackageEffectControlFieldOrder(index[i].controls, index[i].dependencyOrder) ||
            !WireEqual(index[i].archive, approved.indexControls[i].archive) || index[i].controls != approved.indexControls[i].controls ||
            index[i].dependencyOrder != approved.indexControls[i].dependencyOrder || index[i].rawControlRecord != approved.indexControls[i].rawControlRecord ||
            index[i].evidenceIdentity != approved.indexControls[i].evidenceIdentity) return Fail(error, "provider_unpack_index_changed");
    data->indexControls = index;
    struct Installed {
        std::shared_ptr<const B::Package> package;
        std::map<B::Kind, std::shared_ptr<const B::Field>> fields;
    };
    std::map<std::string, Installed> installed;
    for (const auto &item : data->checkpoint.metadata.packages) {
        const auto actual = state.packages.find(item.first);
        if (actual == state.packages.end() || !Same(actual->second.package, item.second.package) ||
            !item.second.dependencyOrderVerified || item.second.rawControlRecord.empty() ||
            !CydiaPackages::ValidPackageEffectControlFieldOrder(item.second.controls, item.second.dependencyOrder)) return Fail(error, "provider_unpack_state_changed");
        Installed parsed;
        if (!Parse(item.second.package, item.second.controls, &parsed.package, &parsed.fields, error)) return false;
        installed.emplace(item.first, std::move(parsed));
    }
    std::map<std::string, std::string> decoders;
    if (!CydiaPackages::ResolveTrustedArchiveDecoders(selected.archiveDecoderSearchPath, &decoders, error)) return false;
    std::set<std::uint64_t> actions; std::set<std::string> requested, victims;
    const bool forceBreaks = std::find(data->policy.settings->forces.begin(), data->policy.settings->forces.end(),
        N::Force::Breaks) != data->policy.settings->forces.end();
    bool blocked = false; std::size_t inventoryBytes = 0, causeBytes = 0, relationshipSteps = 0, preDependsBytes = 0;
    const auto charge = [&](std::size_t amount) {
        if (amount > MaximumDeconfigurationSteps - relationshipSteps) return false;
        relationshipSteps += amount; return true;
    };
    const auto evaluate = [&](const B::Field &field, const B::Package &source,
        const std::vector<std::shared_ptr<const B::Package>> &candidates, B::Evaluation *result) {
        std::size_t width = 0;
        for (const auto &candidate : candidates) {
            if (candidate->provides->atomCount >= MaximumDeconfigurationSteps - width) return false;
            width += 1 + candidate->provides->atomCount;
        }
        if (field.atomCount && width > (MaximumDeconfigurationSteps - relationshipSteps) / field.atomCount) return false;
        B::Error reason;
        return charge(width * field.atomCount) && B::Evaluate(field, source, candidates, state.nativeArchitecture,
            B::Use::UnpackChecks, compare, result, &reason);
    };
    for (std::size_t p = 0; p < batch.archives.size(); ++p) {
        const auto &archive = batch.archives[p]; const ReviewedAction *action = nullptr;
        for (const auto &candidate : approved.allowances.primaryReview.execution.actions)
            if (candidate.action == ExecutionAction::Unpack && candidate.archive == archive.archive.identifier) action = &candidate;
        const RetainedTransactionArchive *retained = nullptr; const VerifiedArchiveControlEvidence *control = nullptr;
        for (const auto &candidate : store.archives()) if (candidate.source.archive.identifier == archive.archive.identifier) retained = &candidate;
        for (const auto &candidate : store.effectControls()) if (candidate.archive.archive.identifier == archive.archive.identifier) control = &candidate;
        if (!action || !actions.insert(action->identifier).second ||
            batch.actions[p] != action->identifier ||
            !Same(action->package, archive.archive.package) || !retained || !control || !requested.insert(action->archive).second ||
            arguments[data->prefixSize + p] != retained->copy.identity.file.metadata.path ||
            !WireEqual(retained->source.archive, archive.archive) || retained->source.fileIdentity != archive.fileIdentity ||
            !WireEqual(control->archive.archive, archive.archive) || control->archive.fileIdentity != archive.fileIdentity)
            return Fail(error, "provider_unpack_archive_changed");
        const VerifiedIndexControlEvidence *record = nullptr;
        for (const auto &candidate : index) if (candidate.archive.identifier == action->archive) record = &candidate;
        if (!record || !control->control.complete || !control->control.dependencyOrderVerified ||
            control->control.rawControlRecord.empty() ||
            !CydiaPackages::ValidPackageEffectControlFieldOrder(control->control.controls, control->control.dependencyOrder) ||
            control->control.controls != record->controls)
            return Fail(error, "provider_unpack_control_changed");
        std::shared_ptr<const B::Package> incoming; std::map<B::Kind, std::shared_ptr<const B::Field>> fields;
        if (!Parse(action->package, control->control.controls, &incoming, &fields, error)) return false;
        const auto inspected = CydiaPackages::InspectPackageArchiveDataInventoryWithDecoders(retained->copy.identity.file.metadata.path,
            {action->package.package, action->package.version, action->package.architecture}, archive.archive.layout,
            decoders, CydiaPackages::ArchiveLimits(), cancel);
        if (!inspected.archive.complete || !inspected.archive.identityVerified || !inspected.inventory.complete)
            return Fail(error, "provider_unpack_inventory_unavailable");
        for (const auto &member : inspected.inventory.entries) {
            for (const auto amount : {sizeof(member), member.name.size(), member.link.size(), member.hardlinkTarget.size()}) {
                if (amount > MaximumUnpackOwnershipBytes - inventoryBytes) return Fail(error, "provider_unpack_inventory_limit");
                inventoryBytes += amount;
            }
        }
        UnpackOwnershipArchive inventory; inventory.action = *action; inventory.archiveFileIdentity = archive.fileIdentity;
        inventory.multiArch = control->control.controls.at("multi-arch");
        inventory.inventory = std::make_shared<const CydiaPackages::ArchiveDataInventory>(inspected.inventory);
        data->inventories.push_back(std::move(inventory));
        // Later archive native state/list generations need an actual boundary.
        // Retain its bytes/inventory but never reuse this first snapshot as a
        // claim about earlier successes/failures or a new child-local queue.
        if (p) continue;
        std::vector<std::shared_ptr<const B::Package>> conflictCandidates, breakCandidates;
        for (const auto &item : installed) {
            if (!charge(1) || cancel()) return Fail(error, "provider_unpack_relationship_limit");
            const auto &actual = state.packages.at(item.first);
            // Native INSTALLNEW replaces this exact slot; its old Provides do
            // not participate. all/native replacement is handled by ownership.
            if (item.second.package->name == incoming->name && (item.second.package->architecture == incoming->architecture ||
                item.second.package->architecture == "all" || incoming->architecture == "all")) continue;
            if (actual.status > DpkgPackageStatus::ConfigFiles) conflictCandidates.push_back(item.second.package);
            if (actual.status > DpkgPackageStatus::HalfConfigured) breakCandidates.push_back(item.second.package);
        }
        const auto add = [&](const ExecutionPackage &victim, DeconfigurationCause cause) {
            const auto allowance = approved.allowances.allowances.find(Generation(victim));
            if (allowance == approved.allowances.allowances.end() ||
                std::none_of(allowance->second.causes.begin(), allowance->second.causes.end(),
                    [&](const DeconfigurationCause &approvedCause) { return SameCause(cause, approvedCause); }))
                return Fail(error, "provider_unpack_deconfiguration_unapproved");
            if (data->causes.size() >= MaximumDeconfigurationCauses) return Fail(error, "provider_unpack_relationship_limit");
            for (const auto amount : {sizeof(AdmittedDeconfigurationCause), victim.package.size(), victim.version.size(),
                victim.architecture.size(), cause.archive.size(), cause.canonicalRelation.size(), cause.comparedVersion.size()}) {
                if (amount > MaximumDeconfigurationOutputBytes - causeBytes) return Fail(error, "provider_unpack_relationship_limit");
                causeBytes += amount;
            }
            data->causes.push_back({victim, std::move(cause)}); victims.insert(Key(victim)); return true;
        };
        for (const auto &candidate : breakCandidates) {
            if (candidate->name != incoming->name || candidate->architecture == incoming->architecture) continue;
            if (candidate->multiArch != B::MultiArch::Same || incoming->multiArch != B::MultiArch::Same)
                return Fail(error, "provider_unpack_sibling_unsupported");
            const auto compared = compare(candidate->version, incoming->version);
            if (compared.status != B::ComparisonStatus::Compared) return Fail(error, "provider_unpack_comparison_unavailable");
            if (!compared.ordering) continue;
            DeconfigurationCause cause; cause.kind = DeconfigurationCauseKind::SiblingVersionMismatch;
            cause.unpackAction = action->identifier; cause.archive = action->archive; cause.comparedVersion = candidate->version;
            if (!add({candidate->name, candidate->version, candidate->architecture}, std::move(cause))) return false;
        }
        const auto reverseConflicts = [&](const std::shared_ptr<const B::Package> &actualIncoming, const std::string &selector) {
            for (const auto &item : installed) {
                if (!charge(1) || cancel()) return Fail(error, "provider_unpack_relationship_limit");
                if (item.second.package->name == incoming->name || victims.count(item.first) ||
                    state.packages.at(item.first).status <= DpkgPackageStatus::ConfigFiles) continue;
                // Native reverse-link lookup visits only this real/provided
                // name. A different direct or virtual conflict is checked at
                // its own native point, not prematurely through a full map.
                for (const auto &candidate : item.second.fields.at(B::Kind::Conflicts)->groups) {
                    if (candidate.alternatives.size() != 1 || candidate.alternatives.front().package != selector) continue;
                    std::shared_ptr<const B::Field> relation; B::Error relationError;
                    if (!B::ParseField(B::Kind::Conflicts, AdmissionGroupText(candidate), &relation, &relationError))
                        return Fail(error, "provider_unpack_relationship_unsupported");
                    B::Evaluation reverse;
                    if (!evaluate(*relation, *item.second.package, {actualIncoming}, &reverse))
                        return Fail(error, "provider_unpack_relationship_unsupported");
                    blocked = blocked || reverse.anyGroupMatched;
                }
            }
            return true;
        };
        // pkg_check_depcon walks each dependency node in actual archive field
        // encounter order. Groups are appended in textual comma order. Never
        // substitute index order, canonical-map order or status writer order.
        for (std::size_t fieldPosition = 0; fieldPosition < control->control.dependencyOrder.size(); ++fieldPosition) {
            const auto &fieldName = control->control.dependencyOrder[fieldPosition];
            const auto kind = AdmissionFieldKind(fieldName);
            const auto &fullField = *fields.at(kind);
            for (std::size_t groupIndex = 0; groupIndex < fullField.groups.size(); ++groupIndex) {
                if (!charge(1) || cancel()) return Fail(error, "provider_unpack_relationship_limit");
                std::shared_ptr<const B::Field> group; B::Error groupError;
                if (!B::ParseField(kind, AdmissionGroupText(fullField.groups[groupIndex]), &group, &groupError) || group->groups.size() != 1)
                    return Fail(error, "provider_unpack_relationship_unsupported");
                if (kind == B::Kind::Conflicts) {
                    B::Evaluation conflicts;
                    if (!evaluate(*group, *incoming, conflictCandidates, &conflicts))
                        return Fail(error, "provider_unpack_relationship_unsupported");
                    blocked = conflicts.anyGroupMatched;
                } else if (kind == B::Kind::Breaks && !forceBreaks) {
                    // Siblings were queued before the native field loop;
                    // prior Breaks nodes update this same actual child queue.
                    std::vector<std::shared_ptr<const B::Package>> live;
                    for (const auto &candidate : breakCandidates)
                        if (!victims.count(candidate->name + ':' + candidate->architecture)) live.push_back(candidate);
                    B::Evaluation breaks;
                    if (!evaluate(*group, *incoming, live, &breaks))
                        return Fail(error, "provider_unpack_relationship_unsupported");
                    const auto &matches = breaks.groups.front().witnesses;
                    if (matches.size() > 1 || (!matches.empty() && !data->policy.settings->autoDeconfigure)) blocked = true;
                    else for (const auto &w : matches) {
                        DeconfigurationCause cause; cause.kind = DeconfigurationCauseKind::Breaks; cause.unpackAction = action->identifier;
                        cause.archive = action->archive; cause.canonicalRelation = fullField.canonical;
                        cause.comparedVersion = w.comparedVersion; cause.group = groupIndex; cause.alternative = w.alternative; cause.provide = w.provide;
                        if (!add({w.package, w.version, w.architecture}, std::move(cause))) return false;
                    }
                } else if (kind == B::Kind::PreDepends) {
                    std::vector<ExecutionPackage> queued;
                    for (const auto &victim : victims) queued.push_back(state.packages.at(victim).package);
                    // Native INSTALLNEW self-dependencies consult the whole
                    // already-parsed available Provides value. The current
                    // queue, however, includes only earlier native nodes.
                    OrderedPreDependsEvidence row; row.unpackAction = action->identifier; row.archive = action->archive;
                    row.field = fieldPosition; row.group = groupIndex; row.canonicalGroup = group->canonical;
                    row.result = PreDependsEvidence::Evaluate(*group, *incoming, state,
                        data->checkpoint.metadata, state.nativeArchitecture, compare, queued);
                    const auto readiness = row.result.readiness;
                    if (readiness == PreDependsEvidence::Readiness::Unsupported || readiness == PreDependsEvidence::Readiness::ComparisonFailed)
                        return Fail(error, "provider_unpack_predepends_unavailable");
                    if (!AdmissionResultBytes(row, &preDependsBytes)) return Fail(error, "provider_unpack_predepends_limit");
                    data->orderedPreDepends.push_back(std::move(row));
                    blocked = readiness != PreDependsEvidence::Readiness::Ready;
                } else if (kind == B::Kind::Provides) {
                    // Native checks reverse Conflicts for this provided group
                    // at this point, not every future provided node at once.
                    std::shared_ptr<const B::Package> provided; B::Error providedError;
                    if (!B::ParsePackage(incoming->name, incoming->version, incoming->architecture,
                        control->control.controls.at("multi-arch"), group->canonical, &provided, &providedError) ||
                        !reverseConflicts(provided, fullField.groups[groupIndex].alternatives.front().package))
                        return Fail(error, "provider_unpack_relationship_unsupported");
                }
                // Depends/Replaces are not checked in this native unpack loop.
                // A blocked node never fabricates later queue additions.
                if (blocked) break;
            }
            if (blocked) break;
        }
        if (!blocked) {
            // Native performs the real-name reverse Conflicts check after all
            // incoming nodes. Virtual names were checked at their Provides nodes.
            std::shared_ptr<const B::Package> real; B::Error realError;
            if (!B::ParsePackage(incoming->name, incoming->version, incoming->architecture,
                control->control.controls.at("multi-arch"), "", &real, &realError) || !reverseConflicts(real, incoming->name))
                return Fail(error, "provider_unpack_relationship_unsupported");
        }
        // Multi-archive success/failure list continuity is not proven here.
        // A blocked first archive must not manufacture effects of a later one.
        if (blocked) break;
        data->orderedChecksComplete = true;
    }
    if (!AdmissionResultsIdentity(data->orderedPreDepends, &data->orderedPreDependsIdentity))
        return Fail(error, "provider_unpack_predepends_limit");
    std::vector<ExecutionPackage> scriptTargets;
    for (const auto &key : victims) scriptTargets.push_back(state.packages.at(key).package);
    if (!CaptureInstalledScripts(environment, state, lock, scriptTargets, &data->scripts, error, cancel, effectiveSnapshot)) return false;
    for (const auto &key : victims) {
        const auto original = approved.installedScripts.packages.find(key);
        const auto fresh = data->scripts.packages.find(key);
        const auto originalControl = approved.checkpoint.metadata.packages.find(key);
        const auto freshControl = data->checkpoint.metadata.packages.find(key);
        const auto currentScript = currentPoint.scripts().packages.find(key);
        const auto currentControl = currentPoint.trigger().metadata.packages.find(key);
        const auto observed = currentPoint.observation().packages.find(key);
        if (original == approved.installedScripts.packages.end() || fresh == data->scripts.packages.end() ||
            originalControl == approved.checkpoint.metadata.packages.end() || freshControl == data->checkpoint.metadata.packages.end() ||
            currentScript == currentPoint.scripts().packages.end() || currentControl == currentPoint.trigger().metadata.packages.end() ||
            observed == currentPoint.observation().packages.end() || !observed->second.present ||
            !Same(original->second.package, fresh->second.package) || !Same(currentScript->second.package, fresh->second.package) ||
            !Same(observed->second.package, fresh->second.package) ||
            currentScript->second.configVersion != fresh->second.configVersion || observed->second.configVersion != fresh->second.configVersion ||
            currentScript->second.diskStatus != fresh->second.diskStatus || observed->second.diskStatus != fresh->second.diskStatus ||
            currentControl->second.evidenceIdentity != freshControl->second.evidenceIdentity ||
            currentScript->second.evidenceIdentity != fresh->second.evidenceIdentity ||
            !SameScript(currentScript->second.prerm, fresh->second.prerm) || !SameScript(currentScript->second.postinst, fresh->second.postinst) ||
            !SameScript(original->second.prerm, fresh->second.prerm) || !SameScript(original->second.postinst, fresh->second.postinst) ||
            originalControl->second.controls != freshControl->second.controls)
            return Fail(error, "provider_unpack_old_generation_changed");
    }
    data->ownership = EvaluateUnpackOwnership(data->installedOwnership, data->inventories, state.nativeArchitecture);
    if (blocked || data->ownership.readiness == UnpackOwnershipReadiness::PotentialDisappearance)
        data->readiness = UnpackAdmissionReadiness::Blocked;
    else if (data->ownership.readiness == UnpackOwnershipReadiness::RequiresFreshBoundary || batch.archives.size() > 1)
        data->readiness = UnpackAdmissionReadiness::RequiresFreshBoundary;
    else if (data->ownership.readiness == UnpackOwnershipReadiness::Ready)
        data->readiness = UnpackAdmissionReadiness::FactsVerified;
    std::vector<StagedArchiveEvidence> finalArchives; N::Match finalPolicy; std::string finalLaunch;
    if (!stable() || !store.Capture(&finalArchives, error, cancel) || finalArchives.size() != data->archives.size() ||
        !P::RecheckEvidence(data->installedOwnership.files, &ignored) || !P::RecheckEvidence(data->scripts.files, &ignored) ||
        !P::RecheckEvidence(data->checkpoint.metadata.files, &ignored) ||
        !RecheckProtectedTriggerEvidence(environment, data->checkpoint.registry, error, cancel) ||
        !MatchLaunch(selected, native, components, arguments, data->prefixSize, &finalPolicy, &finalLaunch, error, cancel) ||
        finalPolicy.inputIdentity != data->policy.inputIdentity || finalPolicy.recordIdentity != data->policy.recordIdentity || finalLaunch != data->launchIdentity)
        return Fail(error, "provider_unpack_evidence_changed");
    std::vector<VerifiedIndexControlEvidence> finalIndex;
    if (!data->sourceSnapshot->ControlEvidence(approved.allowances.primaryReview.execution.archives, &finalIndex, cancel, error) ||
        finalIndex.size() != data->indexControls.size()) return Fail(error, "provider_unpack_index_changed");
    for (std::size_t i = 0; i < finalIndex.size(); ++i)
        if (finalIndex[i].evidenceIdentity != data->indexControls[i].evidenceIdentity ||
            !WireEqual(finalIndex[i].archive, data->indexControls[i].archive) || finalIndex[i].controls != data->indexControls[i].controls ||
            finalIndex[i].dependencyOrderVerified != data->indexControls[i].dependencyOrderVerified ||
            finalIndex[i].dependencyOrder != data->indexControls[i].dependencyOrder ||
            finalIndex[i].rawControlRecord != data->indexControls[i].rawControlRecord)
            return Fail(error, "provider_unpack_index_changed");
    for (std::size_t i = 0; i < finalArchives.size(); ++i)
        if (!SameInstalledComponent(finalArchives[i].identity, data->archives[i].identity) || finalArchives[i].hashes != data->archives[i].hashes)
            return Fail(error, "provider_unpack_archive_changed");
    if (!stable() || !P::RecheckEvidence(data->installedOwnership.files, &ignored) ||
        !P::RecheckEvidence(data->scripts.files, &ignored) || !P::RecheckEvidence(data->checkpoint.metadata.files, &ignored) ||
        !RecheckProtectedTriggerEvidence(environment, data->checkpoint.registry, error, cancel) ||
        !AdmissionRestorationPoint(environment, restoration, currentPoint, approved.allowances, data->checkpoint, error, cancel))
        return Fail(error, "provider_unpack_evidence_changed");
    data->identity = Hash("CYDIA-PROTECTED-UNPACK-1" + P::SerializeFields({data->nativeIdentity, data->launchIdentity,
        data->policy.inputIdentity, data->policy.recordIdentity, data->checkpoint.identity, data->installedOwnership.evidenceIdentity,
        data->scripts.evidenceIdentity, Hash(data->approvalBytes), data->orderedPreDependsIdentity,
        data->singleArchive ? "single" : "multiple", data->orderedChecksComplete ? "checked" : "incomplete", std::to_string(batch.batch)}));
    if (data->identity.empty() || cancel() || !Fresh(selected, native, components, succession, lock, cancel, error) ||
        !AdmissionOrigin(native, succession, data->approvalScope.primaryReview, data->initialNativeIdentity, error) ||
        !MatchLaunch(selected, native, components, arguments, data->prefixSize, &finalPolicy, &finalLaunch, error, cancel) ||
        finalPolicy.inputIdentity != data->policy.inputIdentity || finalPolicy.recordIdentity != data->policy.recordIdentity ||
        finalLaunch != data->launchIdentity) return Fail(error, "provider_unpack_evidence_changed");
    // No index/state/restoration callback runs after this final private-copy
    // rehash. Earlier Store captures cannot seal a later callback boundary.
    if (!AdmissionSealArchives(store, data->archives, error, cancel)) return false;
    *output = std::shared_ptr<const ProtectedUnpackAdmission>(new ProtectedUnpackAdmission(std::move(data)));
    if (error) error->clear();
    return true;
}
bool ProtectedUnpackAdmission::Revalidate(const BrokerEnvironment &selected, const NativeDpkgAuthority &native,
    const std::vector<InstalledComponentEvidence> &components, const ComponentSuccession &succession, const TransactionArchiveStore &store,
    const RestorationDebtLedger &restoration, const ProtectedRestorationCheckpoint &currentPoint,
    const std::vector<std::string> &arguments, const TriggerCaptureLock &lock, std::string *error,
    const std::function<bool()> &cancelled, const TriggerStateSnapshot &snapshot) const {
    const auto end = std::chrono::steady_clock::now() + std::chrono::milliseconds(30000);
    const auto cancel = [&] {
        try { return std::chrono::steady_clock::now() >= end || (cancelled && cancelled()); }
        catch (...) { return true; }
    };
    P::Error ignored; std::string state, launch; N::Match policy; std::vector<StagedArchiveEvidence> archives;
    if (!data_ || data_->succession != &succession || data_->restoration != &restoration || data_->readiness != UnpackAdmissionReadiness::FactsVerified || arguments != data_->arguments ||
        !Fresh(selected, native, components, succession, lock, cancel, error) ||
        !AdmissionOrigin(native, succession, data_->approvalScope.primaryReview, data_->initialNativeIdentity, error) ||
        AdmissionNativeGeneration(native, components, data_->initialNativeIdentity) != data_->nativeIdentity ||
        !AdmissionRestorationPoint(selected.environment, restoration, currentPoint, data_->approvalScope, data_->checkpoint, error, cancel) ||
        !AdmissionSnapshot(selected.environment, snapshot, cancel, &state, error) || state != data_->checkpoint.packages.packageStateIdentity ||
        !P::RecheckEvidence(data_->installedOwnership.files, &ignored) || !P::RecheckEvidence(data_->scripts.files, &ignored) ||
        !P::RecheckEvidence(data_->checkpoint.metadata.files, &ignored) ||
        !RecheckProtectedTriggerEvidence(selected.environment, data_->checkpoint.registry, error, cancel) || !store.Capture(&archives, error, cancel) ||
        archives.size() != data_->archives.size() ||
        !MatchLaunch(selected, native, components, arguments, data_->prefixSize, &policy, &launch, error, cancel) ||
        policy.inputIdentity != data_->policy.inputIdentity || policy.recordIdentity != data_->policy.recordIdentity || launch != data_->launchIdentity)
        return Fail(error, "provider_unpack_admission_changed");
    std::vector<ArchiveManifest> manifests; std::vector<VerifiedIndexControlEvidence> index;
    for (const auto &record : data_->indexControls) manifests.push_back(record.archive);
    if (!data_->sourceSnapshot->ControlEvidence(manifests, &index, cancel, error) || index.size() != data_->indexControls.size())
        return Fail(error, "provider_unpack_index_changed");
    for (std::size_t i = 0; i < index.size(); ++i)
        if (index[i].evidenceIdentity != data_->indexControls[i].evidenceIdentity ||
            !WireEqual(index[i].archive, data_->indexControls[i].archive) || index[i].controls != data_->indexControls[i].controls ||
            index[i].dependencyOrderVerified != data_->indexControls[i].dependencyOrderVerified ||
            index[i].dependencyOrder != data_->indexControls[i].dependencyOrder ||
            index[i].rawControlRecord != data_->indexControls[i].rawControlRecord)
            return Fail(error, "provider_unpack_index_changed");
    for (std::size_t i = 0; i < archives.size(); ++i)
        if (!SameInstalledComponent(archives[i].identity, data_->archives[i].identity) || archives[i].hashes != data_->archives[i].hashes)
            return Fail(error, "provider_unpack_archive_changed");
    std::string finalState;
    if (!Fresh(selected, native, components, succession, lock, cancel, error) ||
        !AdmissionOrigin(native, succession, data_->approvalScope.primaryReview, data_->initialNativeIdentity, error) ||
        AdmissionNativeGeneration(native, components, data_->initialNativeIdentity) != data_->nativeIdentity ||
        !AdmissionRestorationPoint(selected.environment, restoration, currentPoint, data_->approvalScope, data_->checkpoint, error, cancel) ||
        !AdmissionSnapshot(selected.environment, snapshot, cancel, &finalState, error) || finalState != state ||
        !P::RecheckEvidence(data_->installedOwnership.files, &ignored) || !P::RecheckEvidence(data_->scripts.files, &ignored) ||
        !P::RecheckEvidence(data_->checkpoint.metadata.files, &ignored) ||
        !RecheckProtectedTriggerEvidence(selected.environment, data_->checkpoint.registry, error, cancel) || cancel())
        return Fail(error, "provider_unpack_admission_changed");
    if (!Fresh(selected, native, components, succession, lock, cancel, error) ||
        !AdmissionOrigin(native, succession, data_->approvalScope.primaryReview, data_->initialNativeIdentity, error) ||
        !MatchLaunch(selected, native, components, arguments, data_->prefixSize, &policy, &launch, error, cancel) ||
        policy.inputIdentity != data_->policy.inputIdentity || policy.recordIdentity != data_->policy.recordIdentity || launch != data_->launchIdentity)
        return Fail(error, "provider_unpack_admission_changed");
    if (!AdmissionSealArchives(store, data_->archives, error, cancel)) return false;
    if (error) error->clear();
    return true;
}
}}
