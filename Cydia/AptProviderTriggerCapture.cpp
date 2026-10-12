/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderTriggerCapture.hpp"
#include "Cydia/AptProviderNativeDpkgAuthority.hpp"
#include "Cydia/AptProviderComponentCapture.hpp"
#include "Cydia/DpkgRunner.h"
#include "Cydia/RuntimeSnapshotInputs.hpp"
#include "Cydia/RuntimeState.hpp"
#include <algorithm>
#include <unistd.h>

namespace CydiaAPT { namespace Provider {
namespace {
namespace P = CydiaRuntime::Privileged;
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
class Capture {
    const BrokerEnvironment &selected_;
    const std::function<bool()> &cancelled_;
    NativeDpkgAuthority authority_;
    std::vector<InstalledComponentEvidence> components_;
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
        if (!P::RecheckEvidence(selected_.environment.evidence, &ignored)) return Fail(error, "provider_environment_changed");
        if (!ResolveNativeDpkgAuthority(paths, selected_, review, &authority_, error, cancelled_) ||
            !Closure(selected_.environment.dpkg, error) || !Closure(selected_.environment.dpkgQuery, error)) return false;
        return !NativeIdentity().empty() || Fail(error, "provider_native_authority_invalid");
    }
    bool Snapshot(std::string *identity, std::string *error) {
        if (!Active(cancelled_, error) || !Parent(selected_, error) || !Components(error)) return false;
        std::vector<P::Evidence> inputs; P::Error ignored;
        if (!P::CaptureSnapshotInputs(selected_.environment, P::SnapshotScope::PackageState, &inputs, &ignored))
            return Fail(error, "provider_dpkg_state_unavailable");
        for (const auto &input : inputs)
            if (input.path == selected_.environment.dpkgAdmin + "/updates")
                for (const auto &name : input.entries)
                    if (!name.empty() && name.find_first_not_of("0123456789") == std::string::npos)
                        return Fail(error, "provider_dpkg_journal_unsettled");
        if (!P::RuntimeSnapshot(selected_.environment, identity, &ignored) || !P::RecheckEvidence(inputs, &ignored))
            return Fail(error, "provider_dpkg_state_changed");
        return true;
    }
    bool Query(const std::string &path, const std::vector<std::string> &arguments, std::size_t maximum,
        std::string *bytes, std::string *error) {
        if (!Parent(selected_, error) || !Closure(path, error)) return false;
        CydiaRuntime::Dpkg::Runner runner(path);
        if (!runner.RunAndCaptureBounded(arguments, bytes, maximum, 3000, cancelled_).succeeded())
            return Fail(error, cancelled_ && cancelled_() ? "provider_cancelled" : "provider_dpkg_state_query_failed");
        return Parent(selected_, error) && Components(error);
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
            "--showformat=" + std::string(DpkgStateQueryFormat()), "--show"};
        if (!Query(environment.dpkgQuery, arguments, 32 * 1024 * 1024, &records, error) || !Snapshot(&after, error)) return false;
        if (before != after) return Fail(error, "provider_dpkg_state_changed");
        DpkgState state;
        if (!ParseDpkgState(records, native, foreign, after, &state, error)) return false;
        if (state.nativeArchitecture != selected_.runtime.architecture ||
            state.registeredArchitectures != selected_.runtime.registeredArchitectures)
            return Fail(error, "provider_architectures_changed");
        TriggerCaptureLock lock; lock.parent = getppid(); TriggerEffectCheckpoint checkpoint;
        if (!CaptureTriggerEffectCheckpoint(environment, state, lock, &checkpoint, error, cancelled_) ||
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
}}
