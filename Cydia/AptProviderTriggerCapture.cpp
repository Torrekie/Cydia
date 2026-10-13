/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderTriggerCapture.hpp"
#include "Cydia/AptProviderNativeDpkgAuthority.hpp"
#include "Cydia/AptProviderComponentCapture.hpp"
#include "Cydia/AptProviderNativeVersionComparison.hpp"
#include "Cydia/DpkgRunner.h"
#include "Cydia/RuntimeSnapshotInputs.hpp"
#include "Cydia/RuntimeState.hpp"
#include <algorithm>
#include <chrono>
#include <cerrno>
#include <unistd.h>

namespace CydiaAPT { namespace Provider {
namespace {
namespace P = CydiaRuntime::Privileged;
bool EmptyQueryStatus(const P::Environment &environment) {
    P::Evidence status; P::Error ignored;
    return P::CaptureSharedStateEvidence(environment.dpkgAdmin + "/status", false, false, &status, &ignored) &&
        !status.absent && status.bytes.find_first_not_of(" \t\r\n\v\f") == std::string::npos &&
        P::RecheckEvidence({status}, &ignored);
}

bool Fail(std::string *error, const char *code) { if (error) *error = code; return false; }
bool Active(const std::function<bool()> &cancelled, std::string *error) {
    return !(cancelled && cancelled()) || Fail(error, "provider_cancelled");
}
bool Parent(const BrokerEnvironment &selected, std::string *error) {
    P::Error ignored; pid_t owner = 0; const auto parent = getppid();
    return geteuid() == 0 && parent > 1 &&
        P::FrontendLockOwner(selected.environment.dpkgAdmin, &owner, &ignored) && owner == parent ? true :
        Fail(error, "provider_frontend_lock_missing");
}
class Deadline {
    const std::function<bool()> &cancelled_;
    const std::chrono::steady_clock::time_point end_;
    bool expired_ = false, cancelledSeen_ = false;
public:
    explicit Deadline(const std::function<bool()> &cancelled) : cancelled_(cancelled),
        end_(std::chrono::steady_clock::now() + std::chrono::milliseconds(MaximumDeconfigurationCaptureMilliseconds)) {}
    bool Cancelled() {
        if (expired_ || cancelledSeen_) return true;
        if (std::chrono::steady_clock::now() >= end_) { expired_ = true; return true; }
        try { cancelledSeen_ = cancelled_ && cancelled_(); } catch (...) { cancelledSeen_ = true; }
        return cancelledSeen_;
    }
    bool Finish(std::string *error) {
        if (!Cancelled()) return true;
        return Fail(error, expired_ ? "provider_deconfiguration_capture_timeout" : "provider_cancelled");
    }
};
bool Recheck(const std::vector<P::Evidence> &files, const std::function<bool()> &cancelled, P::Error *error) {
    for (const auto &file : files) {
        if (cancelled && cancelled()) return false;
        if (!P::RecheckEvidence({file}, error)) return false;
    }
    return !cancelled || !cancelled();
}
class Capture {
    const BrokerEnvironment &selected_;
    const std::function<bool()> &cancelled_;
    NativeDpkgAuthority authority_;
    std::vector<InstalledComponentEvidence> components_;
    const TriggerEffectCheckpoint *frozen_ = nullptr;
    const InstalledScriptMetadata *scripts_ = nullptr;
    std::string frozenNative_;
    bool invalid_ = false;
public:
    Capture(const BrokerEnvironment &selected, const std::function<bool()> &cancelled) :
        selected_(selected), cancelled_(cancelled) {}
    std::string NativeIdentity() const { return TriggerNativeAuthorityIdentity(authority_, components_); }
    bool Components(std::string *error) {
        if (!Active(cancelled_, error)) return false;
        std::vector<InstalledComponentEvidence> observed;
        if (authority_.componentPaths.empty() || authority_.componentPaths.size() > MaximumTransactionComponents)
            return Fail(error, "provider_component_origin_invalid");
        for (const auto &path : authority_.componentPaths) {
            InstalledComponentEvidence file;
            if (!CaptureTransactionComponent(path, &file, error, cancelled_)) return false;
            observed.push_back(std::move(file));
        }
        if (!RevalidateNativeDpkgAuthority(authority_, observed, error)) return false;
        if (!components_.empty()) {
            if (observed.size() != components_.size()) return Fail(error, "provider_component_origin_changed");
            for (std::size_t i = 0; i != observed.size(); ++i)
                if (!SameInstalledComponent(observed[i], components_[i])) return Fail(error, "provider_component_origin_changed");
        }
        components_ = std::move(observed); return true;
    }
    bool Closure(const std::string &path, std::string *error) {
        ComponentClosureEvidence proof;
        return Components(error) && CaptureNativeDpkgClosure(authority_, path, components_, &proof, error, cancelled_);
    }
    bool Ready(const CydiaRuntime::PackageDatabasePaths &paths, const ReviewedTransaction &review, std::string *error) {
        P::Error ignored;
        if (geteuid() != 0) return Fail(error, "provider_native_authority_required");
        if (!Active(cancelled_, error)) return false;
        if (!Recheck(selected_.environment.evidence, cancelled_, &ignored)) return Fail(error, "provider_environment_changed");
        if (!ResolveNativeDpkgAuthority(paths, selected_, review, &authority_, error, cancelled_) ||
            !Closure(selected_.environment.dpkg, error) || !Closure(selected_.environment.dpkgQuery, error)) return false;
        return !NativeIdentity().empty() || Fail(error, "provider_native_authority_invalid");
    }
    bool Snapshot(std::string *identity, std::string *error) {
        if (!Active(cancelled_, error) || !Parent(selected_, error) || !Components(error)) return false;
        std::vector<P::Evidence> inputs; P::Error ignored;
        if (!P::CaptureSnapshotInputs(selected_.environment, P::SnapshotScope::PackageState, &inputs, &ignored,
            P::CaptureEvidence, P::CaptureSharedStateEvidence, P::CaptureSourceEvidence, cancelled_))
            return Fail(error, "provider_dpkg_state_unavailable");
        for (const auto &input : inputs)
            if (input.path == selected_.environment.dpkgAdmin + "/updates")
                for (const auto &name : input.entries)
                    if (!name.empty() && name.find_first_not_of("0123456789") == std::string::npos)
                        return Fail(error, "provider_dpkg_journal_unsettled");
        if (!P::RuntimeSnapshot(selected_.environment, identity, &ignored, cancelled_) || !Recheck(inputs, cancelled_, &ignored))
            return Fail(error, "provider_dpkg_state_changed");
        return true;
    }
    bool Query(const std::string &path, const std::vector<std::string> &arguments, std::size_t maximum,
        std::string *bytes, std::string *error) {
        if (!Parent(selected_, error) || !Closure(path, error)) return false;
        CydiaRuntime::Dpkg::Runner runner(path);
        const auto queried = runner.RunAndCaptureBounded(arguments, authority_.launchEnvironment, bytes, maximum, 3000, cancelled_);
        const bool completeQuery = path == selected_.environment.dpkgQuery && arguments == std::vector<std::string>{
            "--admindir=" + selected_.environment.dpkgAdmin, "--showformat=" + std::string(DpkgStateQueryFormat()), "--show", "*"};
        if (!queried.succeeded() && !(completeQuery && queried.kind == CydiaRuntime::Dpkg::ResultKind::Exited &&
            queried.error == 0 && queried.code == 1 && bytes->empty() && EmptyQueryStatus(selected_.environment)))
            return Fail(error, cancelled_ && cancelled_() ? "provider_cancelled" : "provider_dpkg_state_query_failed");
        return Parent(selected_, error) && Components(error);
    }
    bool Freeze(const TriggerEffectCheckpoint &point, std::string *error) {
        if (frozen_ || point.identity.empty() || point.identity != TriggerEffectCheckpointIdentity(point))
            return Fail(error, "provider_deconfiguration_checkpoint_invalid");
        frozen_ = &point; frozenNative_ = NativeIdentity();
        return Frozen(error);
    }
    bool Scripts(std::string *error) {
        if (!scripts_) return true;
        P::Error ignored;
        if (!Recheck(scripts_->files, cancelled_, &ignored))
            return Fail(error, "provider_deconfiguration_scripts_changed");
        // Generic configuration evidence permits protected aliases; native
        // installed script leaves retain their stricter no-alias semantics.
        for (const auto &entry : scripts_->packages) for (const auto *file : {&entry.second.prerm, &entry.second.postinst}) {
            if (!Active(cancelled_, error)) return false;
            struct stat named;
            if (lstat(file->path.c_str(), &named) != 0) {
                if (file->absent && errno == ENOENT) continue;
                return Fail(error, "provider_deconfiguration_scripts_changed");
            }
            if (file->absent || !S_ISREG(named.st_mode) || named.st_nlink != 1 ||
                named.st_dev != file->identity.st_dev || named.st_ino != file->identity.st_ino)
                return Fail(error, "provider_deconfiguration_scripts_changed");
        }
        return true;
    }
    bool Frozen(std::string *error) {
        if (invalid_) return Fail(error, "provider_deconfiguration_capture_changed");
        P::Error ignored; std::string state;
        // Do not retain the trigger lock across a subprocess. The specialized
        // recheck opens/locks/rechecks/releases it without POSIX close hazards.
        const bool valid = frozen_ && !frozenNative_.empty() && Parent(selected_, error) &&
            Recheck(selected_.environment.evidence, cancelled_, &ignored) && Closure(selected_.environment.dpkg, error) &&
            Closure(selected_.environment.dpkgQuery, error) && Snapshot(&state, error) &&
            state == frozen_->packages.packageStateIdentity && NativeIdentity() == frozenNative_ &&
            Recheck(frozen_->metadata.files, cancelled_, &ignored) &&
            RecheckProtectedTriggerEvidence(selected_.environment, frozen_->registry, error, cancelled_) &&
            Scripts(error) && Active(cancelled_, error);
        if (valid) return true;
        invalid_ = true;
        if (!error || error->empty()) return Fail(error, "provider_deconfiguration_capture_changed");
        return false;
    }
    bool RetainScripts(const InstalledScriptMetadata &scripts, std::string *error) {
        if (scripts_ || !frozen_) return Fail(error, "provider_deconfiguration_scripts_invalid");
        scripts_ = &scripts; return Frozen(error);
    }
    BinaryRelationships::VersionComparator Comparator(std::string *failure) {
        const auto query = [this, failure](const NativeVersionQueryRequest &request, const std::function<bool()> &cancelled) {
            NativeVersionQueryReply reply;
            if (request.nativeAuthorityIdentity != frozenNative_ || request.maximumOutputBytes != 1 ||
                !request.timeoutMilliseconds || request.timeoutMilliseconds > 3000 || request.arguments.size() != 4 ||
                request.arguments[0] != "--compare-versions" || (request.arguments[2] != "lt" && request.arguments[2] != "gt") ||
                !BinaryRelationships::ValidVersion(request.arguments[1]) || !BinaryRelationships::ValidVersion(request.arguments[3]) ||
                !Frozen(failure)) return reply;
            std::vector<std::string> arguments; P::Error ignored;
            if (!P::BindDpkgArguments(selected_.environment, request.arguments, &arguments, &ignored)) {
                invalid_ = true; Fail(failure, "provider_deconfiguration_comparison_invalid"); return reply;
            }
            CydiaRuntime::Dpkg::Runner runner(selected_.environment.dpkg);
            reply.result = runner.RunAndCaptureBounded(arguments, authority_.launchEnvironment, &reply.output,
                request.maximumOutputBytes, request.timeoutMilliseconds, cancelled);
            if (!Frozen(failure)) return NativeVersionQueryReply();
            reply.nativeAuthorityIdentity = frozenNative_; return reply;
        };
        const auto compare = MakeNativeVersionComparator(frozenNative_, query, cancelled_);
        // The pure comparator caches values. This outer guard checks complete
        // native and state evidence before AND after cache reuse as well.
        return [this, compare, failure](const std::string &left, const std::string &right) {
            BinaryRelationships::VersionComparison result; result.status = BinaryRelationships::ComparisonStatus::Failed;
            if (!Frozen(failure)) return result;
            result = compare(left, right);
            if (result.status != BinaryRelationships::ComparisonStatus::Compared && failure && failure->empty())
                *failure = "provider_deconfiguration_comparison_failed";
            if (!Frozen(failure)) { result.status = BinaryRelationships::ComparisonStatus::Failed; result.ordering = 0; }
            return result;
        };
    }
    bool Checkpoint(TriggerEffectCheckpoint *result, std::string *error) {
        std::string before, after, native, foreign, records;
        if (!Snapshot(&before, error)) return false;
        const auto &environment = selected_.environment;
        std::vector<std::string> arguments{"--root=" + environment.dpkgRoot,
            "--admindir=" + environment.dpkgAdmin, "--print-architecture"};
        if (!Query(environment.dpkg, arguments, 32768, &native, error)) return false;
        arguments.back() = "--print-foreign-architectures";
        if (!Query(environment.dpkg, arguments, 32768, &foreign, error)) return false;
        arguments = {"--admindir=" + environment.dpkgAdmin,
            "--showformat=" + std::string(DpkgStateQueryFormat()), "--show", "*"};
        if (!Query(environment.dpkgQuery, arguments, 32 * 1024 * 1024, &records, error) || !Snapshot(&after, error)) return false;
        if (before != after) return Fail(error, "provider_dpkg_state_changed");
        DpkgState state;
        if (!ParseDpkgState(records, native, foreign, after, &state, error)) return false;
        if (state.nativeArchitecture != selected_.runtime.architecture ||
            state.registeredArchitectures != selected_.runtime.registeredArchitectures)
            return Fail(error, "provider_architectures_changed");
        TriggerCaptureLock lock; lock.parent = getppid(); TriggerEffectCheckpoint checkpoint;
        if (!CaptureTriggerEffectCheckpoint(environment, state, lock, &checkpoint, error, cancelled_,
            [this](std::string *value, std::string *failure) { return Snapshot(value, failure); }) ||
            !Snapshot(&after, error)) return false;
        if (after != before) return Fail(error, "provider_dpkg_state_changed");
        if (!Active(cancelled_, error)) return false;
        *result = std::move(checkpoint); if (error) error->clear(); return true;
    }
};
}
bool NativeTriggerEffectsReady(const CydiaRuntime::PackageDatabasePaths &paths, const BrokerEnvironment &selected,
    std::string *error, const std::function<bool()> &cancelled) {
    if (error) error->clear();
    Capture capture(selected, cancelled); return capture.Ready(paths, ReviewedTransaction(), error);
}
bool CaptureEffectAwareDpkgState(const CydiaRuntime::PackageDatabasePaths &paths, const BrokerEnvironment &selected,
    DpkgState *state, std::string *error, const std::function<bool()> &cancelled) {
    if (!state) return Fail(error, "provider_dpkg_state_invalid");
    *state = DpkgState(); Capture capture(selected, cancelled); TriggerEffectCheckpoint checkpoint;
    if (!Parent(selected, error) || !capture.Ready(paths, ReviewedTransaction(), error) || !capture.Checkpoint(&checkpoint, error)) return false;
    *state = std::move(checkpoint.packages); return true;
}
bool CaptureReviewedTriggerEffects(const CydiaRuntime::PackageDatabasePaths &paths, const BrokerEnvironment &selected,
    const ReviewedTransaction &review, TriggerEffectEnvelope *envelope, std::string *error,
    const std::function<bool()> &cancelled) {
    if (!envelope) return Fail(error, "provider_trigger_envelope_invalid");
    *envelope = TriggerEffectEnvelope();
    Message bound; bound.sequence = 1; bound.operation = Operation::RunPackageManager; bound.binding = review.binding;
    const auto &binding = selected.runtime.binding;
    if (!ValidRequestBinding(bound) || review.binding.providerIdentifier != binding.providerIdentifier ||
        review.binding.configurationIdentity != binding.configurationIdentity || review.binding.policyIdentity != binding.policyIdentity ||
        review.transaction.registeredArchitectures != selected.runtime.registeredArchitectures)
        return Fail(error, "provider_trigger_review_changed");
    for (const auto &action : review.execution.actions)
        if (action.action == ExecutionAction::Triggers || action.action == ExecutionAction::Deconfigure)
            return Fail(error, "provider_trigger_review_unsupported");
    Capture capture(selected, cancelled); TriggerEffectCheckpoint checkpoint;
    if (!Parent(selected, error) || !capture.Ready(paths, review, error) || !capture.Checkpoint(&checkpoint, error)) return false;
    const auto nativeIdentity = capture.NativeIdentity();
    if (nativeIdentity.empty()) return Fail(error, "provider_native_authority_invalid");
    return BuildTriggerEffectEnvelope(review, checkpoint, envelope, error, nativeIdentity);
}
bool CaptureReviewedDeconfiguration(const CydiaRuntime::PackageDatabasePaths &paths, const BrokerEnvironment &selected,
    const ReviewedTransaction &review, std::shared_ptr<const ProtectedDeconfigurationReview> *output, std::string *error,
    const std::function<bool()> &cancelled) {
    if (error) error->clear();
    if (!output) return Fail(error, "provider_deconfiguration_output_invalid");
    output->reset();
    Deadline deadline(cancelled); const std::function<bool()> bounded = [&deadline] { return deadline.Cancelled(); };
    Message message; message.sequence = 1; message.operation = Operation::RunPackageManager; message.binding = review.binding;
    const auto &binding = selected.runtime.binding;
    if (!ValidRequestBinding(message) || review.binding.providerIdentifier != binding.providerIdentifier ||
        review.binding.session != binding.session || review.binding.configurationIdentity != binding.configurationIdentity ||
        review.binding.policyIdentity != binding.policyIdentity || review.transaction.registeredArchitectures != selected.runtime.registeredArchitectures ||
        review.execution.actions.empty() || review.execution.actions.size() > MaximumDeconfigurationActions ||
        review.execution.archives.size() > MaximumDeconfigurationActions)
        return Fail(error, "provider_deconfiguration_review_changed");
    for (const auto &action : review.execution.actions)
        if (action.action == ExecutionAction::Triggers || action.action == ExecutionAction::Deconfigure)
            return Fail(error, "provider_deconfiguration_review_unsupported");
    {
        std::string encoded;
        if (!Encode(review, &encoded) || encoded.size() > MaximumDeconfigurationInputBytes)
            return Fail(error, "provider_deconfiguration_input_invalid");
    }
    if (!deadline.Finish(error)) return false;
    Capture capture(selected, bounded); auto result = std::make_shared<ProtectedDeconfigurationReview>();
    if (!Parent(selected, error) || !capture.Ready(paths, review, error) || !capture.Checkpoint(&result->checkpoint, error) ||
        result->checkpoint.packages.packageStateIdentity != review.binding.packageStateIdentity || !capture.Freeze(result->checkpoint, error)) {
        if (!deadline.Finish(error)) return false;
        if (!error || error->empty()) return Fail(error, "provider_deconfiguration_review_changed");
        return false;
    }
    auto snapshot = ArchiveEvidenceSnapshot::Capture(selected.runtime, review, selected.archiveDecoderSearchPath, bounded, error);
    if (!snapshot || !snapshot->ControlEvidence(review.execution.archives, &result->indexControls, bounded, error) || !capture.Frozen(error)) {
        deadline.Finish(error); return false;
    }
    std::string comparisonFailure; const auto compare = capture.Comparator(&comparisonFailure);
    std::vector<ExecutionPackage> targets;
    if (!SelectDeconfigurationTargets(review, result->checkpoint, result->indexControls, compare, &targets, error)) {
        if (!comparisonFailure.empty() && error) *error = comparisonFailure;
        deadline.Finish(error); return false;
    }
    TriggerCaptureLock lock; lock.parent = getppid();
    if (!capture.Frozen(error) || !CaptureInstalledScripts(selected.environment, result->checkpoint.packages, lock, targets,
        &result->installedScripts, error, bounded,
        [&capture](std::string *value, std::string *failure) { return capture.Snapshot(value, failure); }) || !capture.RetainScripts(result->installedScripts, error) ||
        !BuildDeconfigurationAllowances(review, result->checkpoint, capture.NativeIdentity(), result->indexControls,
            result->installedScripts, compare, &result->allowances, error)) {
        if (!comparisonFailure.empty() && error) *error = comparisonFailure;
        deadline.Finish(error); return false;
    }
    // The second batch rechecks every retained source/index after native
    // comparisons and script capture. Native/state checks also surround cached
    // comparisons; the source/index capture itself never creates native policy.
    std::vector<VerifiedIndexControlEvidence> checked;
    if (!snapshot->ControlEvidence(review.execution.archives, &checked, bounded, error)) {
        deadline.Finish(error); return false;
    }
    if (checked.size() != result->indexControls.size())
        return Fail(error, "provider_deconfiguration_index_changed");
    for (std::size_t i = 0; i < checked.size(); ++i)
        if (checked[i].evidenceIdentity != result->indexControls[i].evidenceIdentity)
            return Fail(error, "provider_deconfiguration_index_changed");
    if (!capture.Frozen(error)) { deadline.Finish(error); return false; }
    if (!deadline.Finish(error)) return false;
    result->sourceSnapshot = snapshot; *output = result;
    if (error) error->clear();
    return true;
}
}}
