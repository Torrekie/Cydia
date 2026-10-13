/* Copyright (C) 2026 Torrekie; GPL-3.0-or-later. */
#include "Cydia/AptProviderTransactionOwner.hpp"
#include "Cydia/AptProviderNativeDpkgAuthority.hpp"
#include "Cydia/AptProviderTransactionChannel.hpp"
#include "Cydia/AptProviderTriggerCapture.hpp"
#include "Cydia/AptProviderEffectReviewBundle.hpp"
#include "Cydia/AptProviderConditionalDeconfiguration.hpp"
#include "Cydia/AptProviderRestorationCapture.hpp"
#include "Cydia/AptProviderRestorationTriggerDecision.hpp"
#include "Cydia/AptProviderUnpackAdmission.hpp"
#include "Cydia/AptProviderPrimaryReadiness.hpp"
#include "Cydia/AptProviderNativeVersionComparison.hpp"
#include "Cydia/DpkgRunner.h"
#include "Cydia/ExtendedState.hpp"
#include "Cydia/RuntimeSnapshotInputs.hpp"
#include "Cydia/RuntimeState.hpp"
#include "Cydia/SourceDocumentCommit.hpp"
#include <apt-pkg/hashes.h>
#include <algorithm>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <fcntl.h>
#include <sys/stat.h>
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
std::string Hash(const std::string &bytes) {
    Hashes hash(Hashes::SHA256SUM);
    return hash.Add(bytes.data(), bytes.size()) ? hash.GetHashString(Hashes::SHA256SUM).HashValue() : "";
}
template<class T> std::string Wire(const T &value) { std::string bytes; return Encode(value, &bytes) ? bytes : ""; }
bool SameExpected(const P::ExpectedEnvironment &a, const P::ExpectedEnvironment &b) { return Wire(a) == Wire(b); }
}
class TransactionOwner::Implementation {
public:
    TransactionOwnerOptions options;
    ReviewPolicy authorizedPolicy; // Conditional allowance alias comes only from the independently rebuilt proof.
    NativeDpkgAuthority native;
    TransactionArchiveStore archives;
    TransactionLease lease;
    ComponentSuccession components;
    TriggerEffectLedger effects;
    std::shared_ptr<const ProtectedDeconfigurationReview> protectedDeconfiguration;
    std::shared_ptr<const ProtectedRestorationCheckpoint> restorationCheckpoint;
    RestorationDebtLedger restoration;
    TransactionLeaseIdentity identity;
    std::set<std::uint64_t> completedUnpacks;
    std::string initialState;
    bool begun = false, ready = false;
    std::atomic<bool> cancelled{false}, disconnected{false};
    explicit Implementation(const TransactionOwnerOptions &value) : options(value), authorizedPolicy(value.policy) {
        authorizedPolicy.conditionalDeconfiguration.reset();
    }
    bool Stop(std::string *error, const char *code) {
        ready = false; restoration.Invalidate(lease.mutationStarted());
        effects.Invalidate(lease.mutationStarted()); components.Invalidate(); lease.Cancel(); return Fail(error, code);
    }
    void SynchronizeCancellation() {
        if (disconnected.load()) lease.TransportLost();
        else if (cancelled.load()) lease.Cancel();
    }
    bool Active(const std::function<bool()> &cancel, std::string *error) {
        if (cancelled.load() || disconnected.load() || (cancel && cancel())) {
            cancelled.store(true); SynchronizeCancellation(); return Stop(error, "provider_cancelled");
        }
        return true;
    }
    std::function<bool()> Cancellation(const std::function<bool()> &outer) {
        return [this, outer] { return cancelled.load() || disconnected.load() || (outer && outer()); };
    }
    std::function<bool()> CaptureCancellation(const std::function<bool()> &outer) {
        const auto end = std::chrono::steady_clock::now() + std::chrono::milliseconds(30000);
        return [this, outer, end] {
            return std::chrono::steady_clock::now() >= end || cancelled.load() || disconnected.load() ||
                (outer && outer());
        };
    }
    bool Parent(TransactionLeaseContext *context, std::string *error) {
        P::ApplicationProcessIdentity app; uid_t uid = 0; P::Error ignored; pid_t owner = 0;
        struct stat lock;
        const auto &environment = options.selected.environment;
        if (!options.authenticate || !options.authenticate(&app, &uid, error) ||
            !(app == options.application) || uid != options.applicationUID ||
            !P::ValidApplicationProcessIdentity(app) || std::to_string(getppid()) != app.pid ||
            !P::FrontendLockOwner(environment.dpkgAdmin, &owner, &ignored) || std::to_string(owner) != app.pid ||
            lstat((environment.dpkgAdmin + "/lock-frontend").c_str(), &lock) != 0 || !S_ISREG(lock.st_mode) ||
            lock.st_nlink != 1 || static_cast<std::uint64_t>(lock.st_dev) != options.lock.device ||
            static_cast<std::uint64_t>(lock.st_ino) != options.lock.inode)
            return Fail(error, "provider_lease_authority_changed");
        if (context) {
            context->application = app; context->lock = options.lock; context->lockOwner = owner;
            context->operatingIdentity = identity.operatingIdentity;
            context->nativeConfigurationIdentity = native.configurationIdentity;
        }
        return true;
    }
    std::vector<std::string> ComponentPaths(const std::set<std::uint64_t> &unpacked) const {
        std::set<std::string> paths(native.componentPaths.begin(), native.componentPaths.end());
        for (const auto &action : options.review.execution.actions) {
            if (action.action != ExecutionAction::Unpack || !unpacked.count(action.identifier)) continue;
            const auto found = native.successorPaths.find(action.archive);
            if (found != native.successorPaths.end()) paths.insert(found->second.begin(), found->second.end());
        }
        return {paths.begin(), paths.end()};
    }
    bool ComponentFiles(const std::set<std::uint64_t> &unpacked, std::vector<InstalledComponentEvidence> *files,
        std::string *error, const std::function<bool()> &cancel) {
        files->clear(); const auto paths = ComponentPaths(unpacked);
        if (paths.empty() || paths.size() > MaximumTransactionComponents) return Fail(error, "provider_component_origin_invalid");
        for (const auto &path : paths) {
            InstalledComponentEvidence file;
            if (!CaptureTransactionComponent(path, &file, error, cancel)) return false;
            files->push_back(std::move(file));
        }
        return RevalidateNativeDpkgAuthority(native, *files, error);
    }
    bool Closure(const std::string &path, const std::vector<InstalledComponentEvidence> &files,
        ComponentClosureEvidence *proof, std::string *error, const std::function<bool()> &cancel) {
        return CaptureNativeDpkgClosure(native, path, files, proof, error, cancel) && components.AuthorizeLaunch(*proof, error);
    }
    bool FrozenSnapshot(std::string *token, std::string *error, const std::function<bool()> &cancel = {}) {
        // Configuration and component evidence is independently guarded above.
        // Re-reading registration/source/keyring policy here would wrongly
        // invalidate an approved package that legitimately replaces those files.
        P::Environment environment;
        environment.dpkgAdmin = options.selected.environment.dpkgAdmin;
        environment.extendedStates = options.selected.environment.extendedStates;
        std::vector<P::Evidence> inputs; P::Error ignored;
        if (!Active(cancel, error) || !P::CaptureSnapshotInputs(environment, P::SnapshotScope::PackageState,
            &inputs, &ignored, P::CaptureEvidence, P::CaptureSharedStateEvidence, P::CaptureSourceEvidence, cancel))
            return Fail(error, "provider_dpkg_state_unavailable");
        for (const auto &input : inputs) {
            if (input.path == environment.dpkgAdmin + "/updates")
                for (const auto &name : input.entries)
                    if (!name.empty() && name.find_first_not_of("0123456789") == std::string::npos)
                        return Fail(error, "provider_dpkg_journal_unsettled");
            if (!options.reviewedEffects && input.path == environment.dpkgAdmin + "/triggers/Unincorp" && !input.bytes.empty())
                return Fail(error, "provider_dpkg_trigger_state_unsettled");
        }
        for (const auto *group : {&inputs, &native.configurationEvidence})
            for (const auto &input : *group)
                if (!Active(cancel, error) || !P::RecheckEvidence({input}, &ignored))
                    return Fail(error, "provider_dpkg_state_changed");
        if (!Active(cancel, error)) return false;
        std::string bytes = "CYDIA-LEASE-STATE-1" + P::SerializeFields({identity.operatingIdentity, native.configurationIdentity});
        for (const auto &input : inputs) bytes += P::SerializeSnapshotEvidence(input);
        *token = Hash(bytes);
        return token->size() == 64 || Fail(error, "provider_dpkg_state_unavailable");
    }
    bool Query(const std::string &path, const std::vector<std::string> &arguments, std::size_t limit,
        const std::vector<InstalledComponentEvidence> &files, std::string *output, std::string *error,
        const std::function<bool()> &cancel) {
        ComponentClosureEvidence proof;
        if (!Parent(nullptr, error) || !Closure(path, files, &proof, error, cancel)) return false;
        CydiaRuntime::Dpkg::Runner reader(path);
        const auto queried = reader.RunAndCaptureBounded(arguments, native.launchEnvironment, output, limit, 3000, cancel);
        const auto &environment = options.selected.environment;
        const bool completeQuery = path == environment.dpkgQuery && arguments == std::vector<std::string>{
            "--admindir=" + environment.dpkgAdmin, "--showformat=" + std::string(DpkgStateQueryFormat()), "--show", "*"};
        if (!queried.succeeded() && !(completeQuery && queried.kind == CydiaRuntime::Dpkg::ResultKind::Exited &&
            queried.error == 0 && queried.code == 1 && output->empty() && EmptyQueryStatus(environment)))
            return Fail(error, "provider_dpkg_state_query_failed");
        return true;
    }
    TriggerStateSnapshot SnapshotReader(const std::function<bool()> &cancel = {}) {
        return [this, cancel](std::string *token, std::string *reason) {
            std::string bytes;
            if (!FrozenSnapshot(&bytes, reason, cancel)) return false;
            *token = bytes == initialState ? options.review.binding.packageStateIdentity : "lease:" + bytes;
            return true;
        };
    }
    bool CaptureRestoration(const DpkgState &state, const TriggerEffectCheckpoint &effect,
        std::shared_ptr<const ProtectedRestorationCheckpoint> *point, std::string *error,
        const std::function<bool()> &outerCancel) {
        const auto cancel = CaptureCancellation(outerCancel);
        if (!point || !protectedDeconfiguration) return Fail(error, "provider_restoration_capture_unavailable");
        TriggerCaptureLock lock; lock.parent = getppid();
        return ProtectedRestorationCheckpoint::Capture(options.selected.environment, state, lock,
            protectedDeconfiguration->allowances, point, error, cancel, SnapshotReader(cancel)) &&
            (*point)->observation().identity == effect.identity && (*point)->trigger().identity == effect.identity;
    }
    bool CaptureContext(const std::set<std::uint64_t> &unpacked, TransactionLeaseContext *context,
        DpkgState *state, std::string *error, const std::function<bool()> &outerCancel, TriggerEffectCheckpoint *effect = nullptr) {
        const auto cancel = CaptureCancellation(outerCancel);
        if (!context || !state) return Fail(error, "provider_lease_input_invalid");
        *context = TransactionLeaseContext(); *state = DpkgState();
        if ((cancel && cancel()) || !Parent(context, error) || !ComponentFiles(unpacked, &context->components, error, cancel) ||
            !components.Observe(unpacked, context->components, error) || !archives.Capture(&context->stagedArchives, error, cancel)) return false;
        std::string before, after, nativeArchitecture, foreignArchitectures, records;
        if (!FrozenSnapshot(&before, error, cancel)) return false;
        const auto &environment = options.selected.environment;
        std::vector<std::string> arguments{"--root=" + environment.dpkgRoot, "--admindir=" + environment.dpkgAdmin, "--print-architecture"};
        if (!Query(environment.dpkg, arguments, 32768, context->components, &nativeArchitecture, error, cancel)) return false;
        arguments.back() = "--print-foreign-architectures";
        if (!Query(environment.dpkg, arguments, 32768, context->components, &foreignArchitectures, error, cancel)) return false;
        arguments = {"--admindir=" + environment.dpkgAdmin, "--showformat=" + std::string(DpkgStateQueryFormat()), "--show", "*"};
        if (!Query(environment.dpkgQuery, arguments, 32 * 1024 * 1024, context->components, &records, error, cancel) ||
            !FrozenSnapshot(&after, error, cancel) || before != after || !Parent(context, error)) return false;
        std::vector<InstalledComponentEvidence> finalFiles;
        if (!ComponentFiles(unpacked, &finalFiles, error, cancel) || !components.Observe(unpacked, finalFiles, error) ||
            !archives.Capture(&context->stagedArchives, error, cancel)) return false;
        context->components.swap(finalFiles);
        if (initialState.empty()) initialState = after;
        // Preserve the approved initial binding only while the independently
        // captured frozen state is identical. Subsequent state is helper-owned.
        context->stateIdentity = after == initialState ? options.review.binding.packageStateIdentity : "lease:" + after;
        if (!ParseDpkgState(records, nativeArchitecture, foreignArchitectures, context->stateIdentity, state, error) ||
            state->nativeArchitecture != options.policy.environment.nativeArchitecture ||
            state->registeredArchitectures != options.policy.environment.registeredArchitectures)
            return Fail(error, "provider_architectures_changed");
        if (options.reviewedEffects) {
            TriggerCaptureLock lock; lock.parent = getppid(); TriggerEffectCheckpoint checkpoint;
            const auto snapshot = SnapshotReader(cancel);
            if (!CaptureTriggerEffectCheckpoint(options.selected.environment, *state, lock, &checkpoint, error, cancel, snapshot)) return false;
            if (effect) *effect = std::move(checkpoint);
        }
        return true;
    }
    bool PrepareConffiles(const std::vector<std::string> &source, std::size_t prefixSize, std::size_t statusIndex,
        int status, NativeEffectPolicy::Role role, const std::vector<InstalledComponentEvidence> &files,
        TransactionEffectChildChannels &channels, std::vector<std::string> *arguments, std::size_t *finalStatusIndex,
        std::string *error, const std::function<bool()> &cancel, std::size_t *finalPrefixSize = nullptr) {
        if (!channels.policy || !options.executePrepared || prefixSize > source.size() || statusIndex >= prefixSize)
            return Stop(error, "provider_conffile_policy_unavailable");
        P::Error ignored; std::vector<std::string> bound, prefix, head;
        // ParseBatch supplied boundaries; Bind performs the existing native
        // option/path validation. Never search opaque hook values for flags.
        if (!P::BindDpkgArguments(options.selected.environment, source, &bound, &ignored) ||
            !P::BindDpkgArguments(options.selected.environment, std::vector<std::string>(source.begin(), source.begin() + prefixSize), &prefix, &ignored) ||
            !P::BindDpkgArguments(options.selected.environment, std::vector<std::string>(source.begin(), source.begin() + statusIndex), &head, &ignored) ||
            prefix.size() > bound.size() || head.size() >= prefix.size() ||
            !std::equal(prefix.begin(), prefix.end(), bound.begin()) || !std::equal(head.begin(), head.end(), prefix.begin()) ||
            !FinalizeNativeChildArguments(bound, prefix.size(), head.size(), status, arguments))
            return Stop(error, "provider_conffile_policy_binding_invalid");
        ConffilePolicyDecision decision;
        if (!CaptureConffilePolicy(native, options.selected.environment.dpkg, files, role, *arguments,
            prefix.size(), &decision, error, cancel) || !channels.policy(decision, error))
            return Stop(error, "provider_conffile_policy_unavailable");
        // Acknowledgement permits no new authority. Recheck after its bounded
        // wait so changed configuration/components cannot use a stale decision.
        ComponentClosureEvidence closure;
        if (!Parent(nullptr, error) || !Active(cancel, error) ||
            !Closure(options.selected.environment.dpkg, files, &closure, error, cancel))
            return Stop(error, "provider_conffile_policy_changed");
        *finalStatusIndex = head.size(); if (finalPrefixSize) *finalPrefixSize = prefix.size(); return true;
    }
    bool MatchConditionalLaunch(const std::vector<std::string> &arguments, std::size_t prefix,
        NativeEffectPolicy::Role role, const std::vector<InstalledComponentEvidence> &files,
        std::string *error, const std::function<bool()> &cancel) {
        namespace N = NativeEffectPolicy;
        if (prefix > arguments.size() || !Parent(nullptr, error) || !Active(cancel, error)) return false;
        const auto match = MatchNativeEffectPolicy(native, options.selected.environment.dpkg, files,
            "dpkg-1.23.7-effects-1", role, {arguments.begin(), arguments.begin() + prefix}, error, cancel);
        if (native.effectRecordState != NativeEffectRecordState::Parsed || match.status != N::Status::Matched ||
            !match.settings) return Fail(error, "provider_native_effect_policy_unavailable");
        const auto &settings = *match.settings;
        if (settings.triggers != N::TriggerMode::Disabled || settings.noAct || settings.recursive ||
            settings.selectedOnly || settings.skipSameVersion || !settings.hooks.empty() ||
            !settings.statusLoggers.empty() || !settings.ignoreDepends.empty() || !settings.unmodeledOptions.empty() ||
            (role != N::Role::Unpack && settings.autoDeconfigure) ||
            (role != N::Role::TriggerDrain && settings.pending))
            return Fail(error, "provider_native_effect_policy_unsupported");
        for (const auto force : settings.forces)
            if (force == N::Force::ConfigureAny || force == N::Force::Depends || force == N::Force::DependsVersion ||
                force == N::Force::Conflicts || force == N::Force::OverwriteDir || force == N::Force::OverwriteDiverted)
                return Fail(error, "provider_native_effect_policy_unsupported");
        N::Inputs inputs; std::string launch; ComponentClosureEvidence closure;
        if (!BuildNativeEffectPolicyInputs(native, options.selected.environment.dpkg, files,
            "dpkg-1.23.7-effects-1", role, {arguments.begin(), arguments.begin() + prefix}, &inputs, error, cancel) ||
            !N::LaunchIdentity(inputs, arguments, Hash, &launch) || launch.empty() ||
            !Closure(options.selected.environment.dpkg, files, &closure, error, cancel))
            return Fail(error, "provider_native_effect_policy_changed");
        return true;
    }
    bool CapturePrimaryReadiness(ExecutionAction action, const std::vector<ExecutionPackage> &targets,
        const TransactionLeaseContext &context, const ProtectedRestorationCheckpoint &before,
        PrimaryReadinessResult *result, std::string *error, const std::function<bool()> &outerCancel) {
        const auto end = std::chrono::steady_clock::now() + std::chrono::milliseconds(30000);
        const auto cancel = [&] {
            return std::chrono::steady_clock::now() >= end || cancelled.load() || disconnected.load() ||
                (outerCancel && outerCancel());
        };
        const auto &point = before.trigger();
        std::vector<InstalledComponentEvidence> initial;
        if (!components.AuthorizeOrigin(options.review, native.configurationIdentity, native.platformIdentity,
                &initial, error) || !components.AuthorizeComponents(context.components, error))
            return Fail(error, "provider_primary_relationship_changed");
        const auto origin = TriggerNativeAuthorityIdentity(native, initial);
        const auto currentNative = TriggerNativeGenerationIdentity(native, context.components, origin);
        P::Error ignored;
        const auto stable = [&] {
            std::string current; ComponentClosureEvidence closure;
            return !cancel() && Parent(nullptr, error) && FrozenSnapshot(&current, error, cancel) &&
                (current == initialState ? options.review.binding.packageStateIdentity : "lease:" + current) == point.packages.packageStateIdentity &&
                P::RecheckEvidence(point.metadata.files, &ignored) && P::RecheckEvidence(before.scripts().files, &ignored) &&
                RecheckProtectedTriggerEvidence(options.selected.environment, point.registry, error, cancel) &&
                Closure(options.selected.environment.dpkg, context.components, &closure, error, cancel) &&
                components.AuthorizeComponents(context.components, error);
        };
        if (!result || currentNative.empty() || !stable()) return Fail(error, "provider_primary_relationship_changed");
        const NativeVersionQuery query = [&](const NativeVersionQueryRequest &request, const std::function<bool()> &boundedCancel) {
            NativeVersionQueryReply reply;
            if (request.nativeAuthorityIdentity != currentNative || request.maximumOutputBytes != 1 ||
                !request.timeoutMilliseconds || request.timeoutMilliseconds > 3000 || request.arguments.size() != 4 ||
                request.arguments[0] != "--compare-versions" ||
                (request.arguments[2] != "lt" && request.arguments[2] != "gt") || !stable()) return reply;
            std::vector<std::string> arguments;
            if (!P::BindDpkgArguments(options.selected.environment, request.arguments, &arguments, &ignored)) return reply;
            CydiaRuntime::Dpkg::Runner reader(options.selected.environment.dpkg);
            reply.result = reader.RunAndCaptureBounded(arguments, native.launchEnvironment, &reply.output, 1,
                request.timeoutMilliseconds, boundedCancel);
            if (!stable()) return NativeVersionQueryReply();
            reply.nativeAuthorityIdentity = currentNative; return reply;
        };
        const auto cachedCompare = MakeNativeVersionComparator(currentNative, query, cancel);
        const BinaryRelationships::VersionComparator compare = [&](const std::string &a, const std::string &b) {
            BinaryRelationships::VersionComparison failed; failed.status = BinaryRelationships::ComparisonStatus::Failed;
            if (!stable()) return failed;
            const auto compared = cachedCompare(a, b);
            return stable() ? compared : failed;
        };
        *result = EvaluatePrimaryRelationshipReadiness(point, action, targets, compare);
        if (!stable() || result->readiness != PrimaryReadiness::Ready)
            return Fail(error, result->reason.empty() ? "provider_primary_relationship_unavailable" : result->reason.c_str());
        return true;
    }
    ConditionalDeconfigurationAdmission Admission(const AuthorizedExecution &batch,
        const TriggerEffectCheckpoint &before, const ProtectedUnpackAdmission *unpack) const {
        ConditionalDeconfigurationAdmission result;
        result.approvalIdentity = protectedDeconfiguration->allowances.identity;
        result.checkpointIdentity = before.identity; result.stateIdentity = before.packages.packageStateIdentity;
        result.batch = batch.batch; result.actions = batch.actions;
        if (unpack) for (const auto &cause : unpack->causes()) result.causes.push_back({cause.installed, cause.cause});
        return result;
    }
    bool PrepareConditionalPrimary(const AuthorizedExecution &batch, const TransactionLeaseContext &context,
        const DpkgState &state, const TriggerEffectCheckpoint &checkpoint, const std::vector<std::string> &arguments,
        std::size_t prefix, int receivedStatus,
        std::shared_ptr<const ProtectedRestorationCheckpoint> *before,
        std::shared_ptr<const ProtectedUnpackAdmission> *unpack, ConditionalDeconfigurationAdmission *admission,
        PrimaryReadinessResult *readiness, std::string *error, const std::function<bool()> &outerCancel) {
        const auto cancel = CaptureCancellation(outerCancel);
        if (!protectedDeconfiguration || !before || !unpack || !admission || batch.actions.size() != 1 ||
            !restoration.active() || checkpoint.identity != restoration.stateIdentity() ||
            checkpoint.identity != effects.stateIdentity() ||
            !CaptureRestoration(state, checkpoint, before, error, cancel) || !restorationCheckpoint ||
            !SameRestorationCheckpoint((*before)->observation(), restorationCheckpoint->observation()))
            return Fail(error, "provider_restoration_primary_boundary_required");
        TriggerCaptureLock lock; lock.parent = getppid();
        if (batch.action == ExecutionAction::Unpack) {
            if (!ProtectedUnpackAdmission::Capture(options.selected, native, context.components, components,
                archives, *protectedDeconfiguration, restoration, **before, batch, arguments, receivedStatus, lock, unpack,
                error, cancel, SnapshotReader(cancel))) return false;
            if ((*unpack)->readiness() != UnpackAdmissionReadiness::FactsVerified ||
                (*unpack)->checkpoint().identity != checkpoint.identity ||
                !(*unpack)->singleArchiveNativeChecksReady())
                return Fail(error, "provider_unpack_fresh_boundary_required");
        } else {
            if (batch.action != ExecutionAction::Configure && batch.action != ExecutionAction::Remove &&
                batch.action != ExecutionAction::Purge) return Fail(error, "provider_restoration_primary_unsupported");
            std::vector<ExecutionPackage> targets;
            for (const auto &action : options.review.execution.actions)
                if (std::find(batch.actions.begin(), batch.actions.end(), action.identifier) != batch.actions.end()) targets.push_back(action.package);
            if (!CapturePrimaryReadiness(batch.action, targets, context, **before, readiness, error, cancel)) return false;
        }
        // The exact supported native profile disables automatic trigger work
        // and extra configuration. One explicit Configure target starts in its
        // real Unpacked/HalfConfigured phase with no pending/awaited lists, as
        // ApplyDpkgStateEvidenceWithConditional independently checked. Thus
        // process_queue cannot substitute that target's postinst triggered or
        // add an unreviewed --force-configure-any configuration. The retained
        // native dependency evaluation above separately proves immediate
        // readiness without forcing, cycle breaking or trigger repair.
        *admission = Admission(batch, checkpoint, unpack->get());
        if (!ValidateConditionalDeconfigurationAdmission(protectedDeconfiguration->allowances, batch, state,
            checkpoint.identity, *admission, error) ||
            !effects.PreparePrimaryWithConditional(checkpoint.identity, batch, protectedDeconfiguration->allowances, error) ||
            !restoration.PreparePrimary(checkpoint.identity, batch, error)) return false;
        // This final physical check is after all channel/policy waits and both
        // ledger reservations, immediately before the existing native executor.
        if (*unpack && !(*unpack)->Revalidate(options.selected, native, context.components, components,
            archives, restoration, **before, arguments, lock, error, cancel, SnapshotReader(cancel))) return false;
        NativeEffectPolicy::Role role = NativeEffectPolicy::Role::Unpack;
        if (batch.action == ExecutionAction::Configure) role = NativeEffectPolicy::Role::Configure;
        else if (batch.action == ExecutionAction::Remove) role = NativeEffectPolicy::Role::Remove;
        else if (batch.action == ExecutionAction::Purge) role = NativeEffectPolicy::Role::Purge;
        std::shared_ptr<const ProtectedRestorationCheckpoint> finalBefore;
        if (!(MatchConditionalLaunch(arguments, prefix, role, context.components, error, cancel) &&
            CaptureRestoration(state, checkpoint, &finalBefore, error, cancel) &&
            SameRestorationCheckpoint(finalBefore->observation(), (*before)->observation()) &&
            Parent(nullptr, error) && Active(cancel, error))) return false;
        // Protected capture and policy callbacks above may take time. Seal all
        // private copies after them; no later capture callback precedes spawn.
        std::vector<StagedArchiveEvidence> sealed;
        return archives.Capture(&sealed, error, cancel);
    }
    bool SettleConditionalPrimary(const AuthorizedExecution &batch, const ParentExecutionReply &reply,
        const DpkgState &state, const DpkgState &afterState, const TriggerEffectCheckpoint &afterEffects,
        const std::shared_ptr<const ProtectedRestorationCheckpoint> &before,
        const ConditionalDeconfigurationAdmission &admission, std::string *error) {
        std::shared_ptr<const ProtectedRestorationCheckpoint> after;
        if (!before || !CaptureRestoration(afterState, afterEffects, &after, error, {})) return false;
        ConditionalDeconfigurationTransition transition;
        transition.admission = admission; transition.before = before->observation(); transition.after = after->observation();
        transition.child.child = reply; transition.child.cancelled = cancelled.load() || disconnected.load();
        transition.child.uncertain = !reply.started || reply.exitCode || reply.signal || reply.launchError;
        TriggerCaptureLock lock; lock.parent = getppid();
        if (batch.action == ExecutionAction::Unpack && !VerifyRestorationSuccessors(options.selected.environment, lock,
            protectedDeconfiguration->allowances, batch, *before, *after, archives, &transition.successors, error, {}, SnapshotReader()))
            return false;
        // Publish neither ledger until both complete gates have passed. Every
        // projected successor comes from the retained Store and physical files.
        auto checkedEffects = effects; auto checkedDebt = restoration;
        if (!VerifyDpkgStateTransitionWithConditionalEffects(state, afterState, options.review, batch,
            protectedDeconfiguration->allowances, restoration, transition, error) ||
            !checkedEffects.ReconcileWithConditional(batch, reply, afterEffects,
                protectedDeconfiguration->allowances, restoration, transition, error) ||
            !checkedDebt.SettlePrimary(batch.batch, transition.child, transition.after, transition.successors, error)) return false;
        effects = std::move(checkedEffects); restoration = std::move(checkedDebt); restorationCheckpoint = std::move(after);
        return true;
    }
    bool DrainEffects(ParentExecutionReply *last, std::string *error, const std::function<bool()> &cancel,
        const std::function<void()> &started, DpkgState *finalState = nullptr) {
        if (!options.reviewedEffects) return true;
        while (!effects.quiescent()) {
            TransactionLeaseContext before; DpkgState state; TriggerEffectCheckpoint checkpoint;
            if (!Active(cancel, error) || !CaptureContext(completedUnpacks, &before, &state, error, cancel, &checkpoint) ||
                checkpoint.identity != effects.stateIdentity()) return Stop(error, "provider_trigger_state_changed");
            std::shared_ptr<const ProtectedRestorationCheckpoint> beforeRestoration;
            if (protectedDeconfiguration) {
                if (!CaptureRestoration(state, checkpoint, &beforeRestoration, error, cancel) || !restorationCheckpoint ||
                    !SameRestorationCheckpoint(beforeRestoration->observation(), restorationCheckpoint->observation()))
                    return Stop(error, "provider_restoration_capture_changed");
                const auto decision = DecideRestorationTriggerWork(protectedDeconfiguration->allowances, restoration, checkpoint);
                if (decision.work == RestorationTriggerWork::Defer) {
                    if (finalState) *finalState = state;
                    return true;
                }
                if (decision.work != RestorationTriggerWork::Drain)
                    return Stop(error, decision.reason.empty() ? "provider_restoration_drain_unavailable" : decision.reason.c_str());
            }
            TriggerDrainPlan plan;
            if (!effects.NextDrain(checkpoint.identity, &plan, error)) return Stop(error, "provider_trigger_drain_unavailable");
            TransactionEffectChildChannels channels; ParentExecutionReply reply;
            if (!options.effectChildChannels(plan, &channels, error)) {
                effects.Invalidate(); return Stop(error, "provider_trigger_child_channels_unavailable");
            }
            struct Scope {
                TransactionEffectChildChannels &channels; ParentExecutionReply &reply;
                ~Scope() { if (channels.settled) channels.settled(reply); }
            } scope{channels, reply};
            if (!channels.started || !channels.settled ||
                !TransactionChannel::ValidChildDescriptors(channels.inputDescriptor, channels.statusDescriptor))
                return Stop(error, "provider_trigger_child_channels_invalid");
            auto arguments = options.policy.protectedDpkgOptions;
            const std::size_t statusIndex = arguments.size();
            arguments.insert(arguments.end(), {"--status-fd=" + std::to_string(channels.statusDescriptor), "--no-triggers", "--triggers-only"});
            std::size_t targetBytes = 0;
            for (const auto &target : plan.targets) targetBytes += target.package.size() + target.architecture.size() + 2;
            // The plan already contains every fresh pending target. Native
            // --pending preserves that complete set without exceeding exec's
            // argument limit on a large but otherwise admitted installation.
            if (plan.targets.empty() || targetBytes > 32768) arguments.push_back("--pending");
            const std::size_t prefixSize = arguments.size();
            if (!plan.targets.empty() && targetBytes <= 32768)
                for (const auto &target : plan.targets) arguments.push_back(target.package + ':' + target.architecture);
            P::Error ignored; ComponentClosureEvidence closure;
            TransactionLeaseContext refreshed; DpkgState currentState; TriggerEffectCheckpoint currentCheckpoint;
            PrimaryReadinessResult drainReadiness;
            if (!CaptureContext(completedUnpacks, &refreshed, &currentState, error, cancel, &currentCheckpoint) ||
                currentCheckpoint.identity != plan.checkpointIdentity ||
                !Parent(nullptr, error) || !P::ValidateDpkgArguments(options.selected.environment, arguments, &ignored) ||
                !Closure(options.selected.environment.dpkg, refreshed.components, &closure, error, cancel) || !Active(cancel, error) ||
                (protectedDeconfiguration && !CapturePrimaryReadiness(ExecutionAction::Triggers, plan.targets,
                    refreshed, *beforeRestoration, &drainReadiness, error, cancel)) ||
                !lease.AuthorizeEffects(refreshed, plan.envelopeIdentity, plan.pass, closure, error))
                return Stop(error, "provider_trigger_drain_not_authorized");
            std::size_t finalStatusIndex = 0, finalPrefixSize = prefixSize;
            if (options.requireConffilePolicy) {
                if (!PrepareConffiles(arguments, prefixSize, statusIndex, channels.statusDescriptor, NativeEffectPolicy::Role::TriggerDrain,
                    refreshed.components, channels, &arguments, &finalStatusIndex, error, cancel, &finalPrefixSize)) return false;
            } else if (!P::BindDpkgArguments(options.selected.environment, arguments, &arguments, &ignored))
                return Stop(error, "provider_dpkg_options_changed");
            std::shared_ptr<const ProtectedRestorationCheckpoint> finalBeforeRestoration;
            if (protectedDeconfiguration && (!MatchConditionalLaunch(arguments, finalPrefixSize,
                NativeEffectPolicy::Role::TriggerDrain, refreshed.components, error, cancel) ||
                currentCheckpoint.identity != restoration.stateIdentity() ||
                !CaptureRestoration(currentState, currentCheckpoint, &finalBeforeRestoration, error, cancel) ||
                !SameRestorationCheckpoint(finalBeforeRestoration->observation(), beforeRestoration->observation())))
                return Stop(error, "provider_restoration_drain_not_authorized");
            const auto childStarted = [&] {
                std::string ignoredStart; lease.StartedEffects(plan.pass, &ignoredStart);
                channels.started(); if (started) started();
            };
            if (cancel && cancel()) reply.launchError = ECANCELED;
            else if (options.requireConffilePolicy) reply = options.executePrepared(options.selected.environment.dpkg, arguments,
                channels.inputDescriptor, channels.statusDescriptor, childStarted, native.launchEnvironment, finalStatusIndex);
            else reply = options.execute(options.selected.environment.dpkg, arguments, channels.inputDescriptor,
                channels.statusDescriptor, childStarted, native.launchEnvironment);
            if (last) *last = reply;
            SynchronizeCancellation();
            TransactionLeaseContext after; DpkgState afterState; TriggerEffectCheckpoint next; std::string reason;
            const bool success = reply.started && !reply.exitCode && !reply.signal && !reply.launchError;
            const bool captured = success && CaptureContext(completedUnpacks, &after, &afterState, &reason, {}, &next);
            bool verified = false;
            if (captured && protectedDeconfiguration) {
                std::shared_ptr<const ProtectedRestorationCheckpoint> afterRestoration;
                auto checkedEffects = effects; auto checkedDebt = restoration;
                RestorationChildResult observed; observed.child = reply;
                observed.cancelled = cancelled.load() || disconnected.load();
                observed.uncertain = !success;
                verified = CaptureRestoration(afterState, next, &afterRestoration, &reason, {}) &&
                    checkedEffects.SettleDrain(plan.pass, reply, next, &reason) &&
                    checkedDebt.ObserveEffects(beforeRestoration->observation().identity, observed,
                        afterRestoration->observation(), &reason);
                if (verified) {
                    effects = std::move(checkedEffects); restoration = std::move(checkedDebt);
                    restorationCheckpoint = std::move(afterRestoration);
                }
            } else verified = captured && effects.SettleDrain(plan.pass, reply, next, &reason);
            const bool settled = lease.SettleEffects(plan.pass, reply, after, verified, &reason);
            if (!settled) { effects.Invalidate(reply.started); return Stop(error, "provider_trigger_drain_unsettled"); }
            if (finalState) *finalState = std::move(afterState);
        }
        return true;
    }
};
TransactionOwner::TransactionOwner(const TransactionOwnerOptions &options) : implementation_(new Implementation(options)) {}
TransactionOwner::~TransactionOwner() = default;
bool TransactionOwner::Begin(std::string *error, const std::function<bool()> &cancelled) {
    auto &s = *implementation_; const auto &o = s.options; const auto &environment = o.selected.environment;
    const auto &runtime = o.selected.runtime; const auto &binding = runtime.binding;
    const auto cancel = s.Cancellation(cancelled);
    if (s.begun) return s.Stop(error, "provider_lease_reused");
    s.begun = true;
    if (o.requireConffilePolicy && (!o.primaryChildChannels || !o.executePrepared))
        return s.Stop(error, "provider_conffile_policy_unavailable");
    if (o.reviewedEffects) {
        if (!o.effectChildChannels || !o.primaryChildChannels) return s.Stop(error, "provider_trigger_child_channels_unavailable");
        if (Wire(o.reviewedEffects->primaryReview) != Wire(o.review)) return s.Stop(error, "provider_trigger_review_changed");
        for (const auto &action : o.review.execution.actions)
            if (action.action == ExecutionAction::Triggers || action.action == ExecutionAction::Deconfigure)
                return s.Stop(error, "provider_trigger_review_unsupported");
    }
    if (o.reviewedDeconfiguration) {
        std::string approved, paired;
        if (!o.requireConffilePolicy || !o.reviewedEffects ||
            !EffectReviewBundleMatches(*o.reviewedDeconfiguration, o.review, runtime.binding.methodsIdentity) ||
            !EncodeTriggerEffectEnvelope(*o.reviewedEffects, &approved) ||
            !EncodeTriggerEffectEnvelope(o.reviewedDeconfiguration->triggers, &paired) || approved != paired)
            return s.Stop(error, "provider_deconfiguration_review_changed");
    }
    if (!s.Active(cancel, error) || !s.Parent(nullptr, error)) return false;
    if (!o.execute ||
        !SameExpected(o.policy.environment.paths, environment) || o.policy.protectedDpkgOptions != o.selected.runtime.dpkgOptions ||
        o.policy.layout.prefix != runtime.packageInstallPrefix ||
        o.policy.environment.nativeArchitecture != runtime.architecture ||
        o.policy.environment.registeredArchitectures != runtime.registeredArchitectures ||
        o.policy.environment.acquisitionArchitectures != runtime.acquisitionArchitectures ||
        o.policy.environment.configurationIdentity != binding.configurationIdentity ||
        o.policy.environment.policyIdentity != binding.policyIdentity ||
        o.policy.environment.methodsIdentity != binding.methodsIdentity ||
        o.review.binding.providerIdentifier != binding.providerIdentifier ||
        o.review.binding.configurationIdentity != binding.configurationIdentity ||
        o.review.binding.policyIdentity != binding.policyIdentity ||
        (!binding.session.empty() && o.review.binding.session != binding.session))
        return s.Stop(error, "provider_lease_admission_invalid");
    ReviewAuthorization review; P::Error ignored; std::string originalState;
    if (!review.Accept(o.review, s.authorizedPolicy, error) || !P::RuntimeSnapshot(environment, &originalState, &ignored) ||
        originalState != o.review.binding.packageStateIdentity)
        return s.Stop(error, "provider_lease_state_changed");
    if (!ResolveNativeDpkgAuthority(o.selected, o.review, &s.native, error, cancel)) {
        s.ready = false; return false; // Preserve the typed missing/unsupported authority diagnostic.
    }
    if (o.reviewedDeconfiguration) {
        // No decoded DTO creates native authority. Reconstruct one protected
        // checkpoint and derive both approvals before creating private copies.
        std::shared_ptr<const ProtectedDeconfigurationReview> captured;
        if (!CaptureReviewedDeconfiguration(CydiaRuntime::PackageDatabasePaths::Current(), o.selected, o.review,
            &captured, error, cancel)) {
            const std::string code(error && !error->empty() ? *error : "provider_deconfiguration_capture_failed");
            return s.Stop(error, code.c_str());
        }
        EffectReviewBundle rebuilt; rebuilt.methodsIdentity = runtime.binding.methodsIdentity;
        rebuilt.deconfiguration = captured->allowances;
        std::string approved, observed;
        if (!BuildTriggerEffectEnvelope(o.review, captured->checkpoint, &rebuilt.triggers, error, captured->allowances.nativeAuthorityIdentity) ||
            !EncodeEffectReviewBundle(rebuilt, &observed) || !EncodeEffectReviewBundle(*o.reviewedDeconfiguration, &approved) ||
            observed != approved)
            return s.Stop(error, "provider_deconfiguration_review_changed");
        if (!s.Parent(nullptr, error) || !s.Active(cancel, error)) return false;
        if (captured->allowances.allowances.empty())
            return s.Stop(error, "provider_deconfiguration_empty_pool");
        s.protectedDeconfiguration = std::move(captured);
        s.authorizedPolicy.conditionalDeconfiguration = std::shared_ptr<const DeconfigurationAllowanceSet>(
            s.protectedDeconfiguration, &s.protectedDeconfiguration->allowances);
        // This reconstructed approval selects the conditional owner route.
        // Every actual child still needs fresh native policy/effect admission
        // and protected restoration settlement; no DTO grants a launch.
    }
    CydiaSources::ProtectedFileSnapshot baseline;
    if (!CydiaSources::ReadSharedStateFile(environment.extendedStates, &baseline) || baseline.bytes != o.expectedExtendedState)
        return s.Stop(error, "provider_extended_state_changed");
    auto &identity = s.identity;
    identity.application = o.application; identity.lock = o.lock; identity.nonce = o.nonce; identity.reviewDigest = o.reviewDigest;
    identity.originIdentity = Hash(Wire(o.policy.environment));
    identity.nativeConfigurationIdentity = s.native.configurationIdentity; identity.platformIdentity = s.native.platformIdentity;
    identity.extendedStateIdentity = Hash(baseline.bytes);
    if (o.reviewedEffects) identity.effectIdentity = o.reviewedEffects->identity;
    if (s.protectedDeconfiguration) identity.conditionalDeconfigurationIdentity = s.protectedDeconfiguration->allowances.identity;
    identity.operatingIdentity = Hash(P::SerializeFields({Wire(o.policy.environment.paths), Wire(o.selected.runtime.dpkgOptions),
        o.selected.executableSearchPath, environment.extendedStates, o.policy.layout.prefix, Wire(o.policy.layout.foreignPrefixes),
        Wire(o.policy.environment.registeredArchitectures), s.native.configurationIdentity}));
    std::vector<InstalledComponentEvidence> files;
    if (!s.ComponentFiles({}, &files, error, cancel) ||
        !s.archives.Begin(o.privateStateDirectory, o.selected.runtime, o.review, o.policy, o.selected.archiveDecoderSearchPath,
            s.native.successorPaths, error, cancel, bool(o.reviewedEffects))) return s.Stop(error, "provider_lease_files_unverified");
    identity.stagingDirectory = s.archives.directory();
    if (!s.components.Begin(o.review, o.policy, files, s.archives.successors(),
        s.native.configurationIdentity, s.native.platformIdentity, error)) return s.Stop(error, "provider_lease_components_unverified");
    TransactionLeaseContext context; DpkgState state; TriggerEffectCheckpoint checkpoint;
    if (!s.CaptureContext({}, &context, &state, error, cancel, &checkpoint) ||
        !P::RuntimeSnapshot(environment, &originalState, &ignored) || originalState != o.review.binding.packageStateIdentity ||
        !s.Active(cancel, error)) return s.Stop(error, "provider_lease_admission_changed");
    if (o.reviewedEffects && (o.reviewedEffects->nativeAuthorityIdentity != TriggerNativeAuthorityIdentity(s.native, files) ||
        o.reviewedEffects->nativeAuthorityIdentity.empty() || !s.effects.Begin(*o.reviewedEffects, checkpoint, error) ||
        !s.effects.RefineIncoming(s.archives.effectControls(), error))) return s.Stop(error, "provider_trigger_review_changed");
    if (s.protectedDeconfiguration) {
        if (!s.CaptureRestoration(state, checkpoint, &s.restorationCheckpoint, error, cancel) ||
            !s.restoration.Begin(s.protectedDeconfiguration->allowances, s.restorationCheckpoint->observation(), error))
            return s.Stop(error, "provider_restoration_initial_changed");
    }
    if (!s.lease.Begin(identity, o.review, s.authorizedPolicy, context, s.archives.archives(),
            s.archives.successors(), o.changes, error)) return s.Stop(error, "provider_lease_admission_changed");
    s.ready = true; if (error) error->clear(); return true;
}
bool TransactionOwner::Capture(const TransactionLeaseEnvelope &envelope, DpkgState *state, std::string *error,
    const std::function<bool()> &cancelled) {
    auto &s = *implementation_; TransactionLeaseContext context; TriggerEffectCheckpoint effect;
    const auto cancel = s.Cancellation(cancelled);
    std::shared_ptr<const ProtectedRestorationCheckpoint> observedRestoration;
    if (!s.ready || !s.Active(cancel, error) || !s.CaptureContext(s.completedUnpacks, &context, state, error, cancel, &effect) ||
        (s.options.reviewedEffects && effect.identity != s.effects.stateIdentity()) ||
        (s.protectedDeconfiguration && (!s.restoration.active() || effect.identity != s.restoration.stateIdentity() ||
            !s.restorationCheckpoint || !s.CaptureRestoration(*state, effect, &observedRestoration, error, cancel) ||
            !SameRestorationCheckpoint(observedRestoration->observation(), s.restorationCheckpoint->observation()))) ||
        !s.lease.Capture(envelope, context, error)) return s.Stop(error, "provider_lease_capture_failed");
    return true;
}
bool TransactionOwner::Execute(const TransactionLeaseEnvelope &envelope, const ParentExecutionRequest &request,
    int input, int status, ParentExecutionReply *result, DpkgState *afterState, std::string *error,
    const std::function<bool()> &cancelled, const std::function<void()> &started) {
    auto &s = *implementation_;
    const auto cancel = s.Cancellation(cancelled);
    if (!result || !afterState) return s.Stop(error, "provider_lease_input_invalid");
    *result = ParentExecutionReply(); *afterState = DpkgState();
    bool observedStart = false;
    struct StartedResult {
        ParentExecutionReply *reply; bool &observed;
        ~StartedResult() { reply->started = reply->started || observed; }
    } startedResult{result, observedStart};
    const auto notifyStarted = [&] { observedStart = true; if (started) started(); };
    TransactionLeaseContext before; DpkgState state; TriggerEffectCheckpoint beforeEffects;
    if (!s.ready || (!s.options.primaryChildChannels && (status < 3 || input < 0)) || !s.Active(cancel, error) ||
        !s.lease.Expects(envelope) || !SameBinding(request.binding, s.options.review.binding) ||
        !s.DrainEffects(result, error, cancel, notifyStarted) ||
        !s.CaptureContext(s.completedUnpacks, &before, &state, error, cancel, &beforeEffects) ||
        (s.options.reviewedEffects && ((!s.protectedDeconfiguration && !s.effects.quiescent()) ||
            beforeEffects.identity != s.effects.stateIdentity())))
        return s.Stop(error, "provider_lease_capture_failed");
    // Earlier drains can have started, but this new scope owns only the
    // primary child's outcome. StartedResult retains the outer cumulative fact.
    *result = ParentExecutionReply(); result->launchError = EACCES;
    TransactionEffectChildChannels primary;
    struct PrimaryScope {
        TransactionEffectChildChannels &channels; ParentExecutionReply &reply; bool finished = false;
        PrimaryScope(TransactionEffectChildChannels &value, ParentExecutionReply &result) : channels(value), reply(result) {}
        void Finish() { if (!finished && channels.settled) { finished = true; channels.settled(reply); } }
        ~PrimaryScope() { Finish(); }
    } primaryScope{primary, *result};
    if (s.options.primaryChildChannels) {
        if (!s.options.primaryChildChannels(request, &primary, error) || !primary.started || !primary.settled ||
            !TransactionChannel::ValidChildDescriptors(primary.inputDescriptor, primary.statusDescriptor))
            return s.Stop(error, "provider_primary_child_channels_invalid");
        input = primary.inputDescriptor; status = primary.statusDescriptor;
    }
    ParentExecutionEvidence evidence; evidence.binding = s.options.review.binding; evidence.frontendLockHeld = true;
    evidence.statusDescriptor = status;
    ComponentClosureEvidence closure; AuthorizedExecution batch; P::Error ignored;
    const bool stateEvidence = s.protectedDeconfiguration ? ApplyDpkgStateEvidenceWithConditional(state,
        s.options.review, request, s.protectedDeconfiguration->allowances, &evidence, error) :
        ApplyDpkgStateEvidence(state, s.options.review, request, &evidence, error);
    if (!stateEvidence ||
        !P::ValidateDpkgArguments(s.options.selected.environment, request.arguments, &ignored) ||
        !s.Closure(s.options.selected.environment.dpkg, before.components, &closure, error, cancel) ||
        !s.Active(cancel, error) || !s.lease.Authorize(envelope, before, request, evidence, closure, &batch, error))
        return s.Stop(error, "provider_lease_batch_not_authorized");
    if (s.options.reviewedEffects && !s.protectedDeconfiguration && !s.effects.PreparePrimary(beforeEffects.identity, batch, error)) {
        ParentExecutionReply denied; denied.launchError = EPERM; std::string ignoredSettlement;
        *result = denied;
        s.lease.Settle(batch.batch, denied, {}, false, &ignoredSettlement);
        return s.Stop(error, "provider_trigger_primary_not_authorized");
    }
    auto arguments = batch.arguments;
    P::Error pathError; std::size_t finalStatusIndex = 0, finalPrefixSize = batch.optionPrefixSize;
    if (s.options.requireConffilePolicy) {
        NativeEffectPolicy::Role role;
        switch (batch.action) {
            case ExecutionAction::Unpack: role = NativeEffectPolicy::Role::Unpack; break;
            case ExecutionAction::Configure: role = NativeEffectPolicy::Role::Configure; break;
            case ExecutionAction::Remove: role = NativeEffectPolicy::Role::Remove; break;
            case ExecutionAction::Purge: role = NativeEffectPolicy::Role::Purge; break;
            case ExecutionAction::Triggers: role = NativeEffectPolicy::Role::TriggerDrain; break;
            default: return s.Stop(error, "provider_conffile_policy_unavailable");
        }
        if (!s.PrepareConffiles(arguments, batch.optionPrefixSize, batch.statusOptionIndex, status, role,
            before.components, primary, &arguments, &finalStatusIndex, error, cancel, &finalPrefixSize)) {
            if (s.protectedDeconfiguration) {
                ParentExecutionReply denied; denied.launchError = EPERM; *result = denied;
                std::string ignoredSettlement; s.lease.Settle(batch.batch, denied, {}, false, &ignoredSettlement);
            }
            return false;
        }
    } else if (!P::BindDpkgArguments(s.options.selected.environment, arguments, &arguments, &pathError))
        return s.Stop(error, "provider_dpkg_options_changed");
    std::shared_ptr<const ProtectedRestorationCheckpoint> beforeRestoration;
    std::shared_ptr<const ProtectedUnpackAdmission> unpackAdmission;
    ConditionalDeconfigurationAdmission admission;
    PrimaryReadinessResult primaryReadiness;
    if (s.protectedDeconfiguration && !s.PrepareConditionalPrimary(batch, before, state, beforeEffects,
        arguments, finalPrefixSize, status, &beforeRestoration, &unpackAdmission, &admission, &primaryReadiness, error, cancel)) {
        ParentExecutionReply denied; denied.launchError = EPERM; *result = denied;
        std::string ignoredSettlement;
        s.lease.Settle(batch.batch, denied, {}, false, &ignoredSettlement);
        const std::string reason(error && !error->empty() ? *error : "provider_restoration_primary_not_authorized");
        return s.Stop(error, reason.c_str());
    }
    // Direct executor owns actual spawn/reap. It must not propagate exceptions
    // or return while a child remains live; channel cancellation never kills it.
    const auto childStarted = [&] {
        std::string ignoredStart; s.lease.Started(batch.batch, &ignoredStart);
        if (primary.started) primary.started();
        notifyStarted();
    };
    if (cancel()) result->launchError = ECANCELED;
    else if (s.options.requireConffilePolicy) *result = s.options.executePrepared(s.options.selected.environment.dpkg, arguments,
        input, status, childStarted, s.native.launchEnvironment, finalStatusIndex);
    else *result = s.options.execute(s.options.selected.environment.dpkg, arguments, input, status, childStarted, s.native.launchEnvironment);
    primaryScope.Finish();
    s.SynchronizeCancellation();
    auto completed = s.completedUnpacks;
    for (auto id : batch.actions)
        for (const auto &action : s.options.review.execution.actions)
            if (id == action.identifier && action.action == ExecutionAction::Unpack) completed.insert(id);
    TransactionLeaseContext after; std::string settlementError; TriggerEffectCheckpoint afterEffects;
    const bool success = result->started && !result->exitCode && !result->signal && !result->launchError;
    const bool captured = success && s.CaptureContext(completed, &after, afterState, &settlementError, {}, &afterEffects);
    const bool verified = captured && (s.protectedDeconfiguration ?
        s.SettleConditionalPrimary(batch, *result, state, *afterState, afterEffects, beforeRestoration, admission, &settlementError) :
        s.options.reviewedEffects ? s.effects.Reconcile(batch, *result, afterEffects, &settlementError) :
        VerifyDpkgStateTransition(state, *afterState, s.options.review, batch, &settlementError));
    const bool settled = s.lease.Settle(batch.batch, *result, after, verified, &settlementError);
    if (!settled) return s.Stop(error, "provider_lease_requires_new_review");
    s.completedUnpacks.swap(completed);
    return s.DrainEffects(result, error, cancel, notifyStarted, afterState);
}
bool TransactionOwner::Commit(const TransactionLeaseEnvelope &envelope, const std::vector<AutoInstalledDelta> &changes,
    const std::string &expected, std::string *error, const std::function<void()> &started) {
    auto &s = *implementation_; TransactionLeaseContext context; DpkgState state; TriggerEffectCheckpoint effect;
    std::shared_ptr<const ProtectedRestorationCheckpoint> finalRestoration;
    if (!s.ready || !s.Active({}, error) || expected != s.options.expectedExtendedState ||
        !s.CaptureContext(s.completedUnpacks, &context, &state, error, {}, &effect) ||
        (s.options.reviewedEffects && (!s.effects.quiescent() || effect.identity != s.effects.stateIdentity())) ||
        (s.protectedDeconfiguration && (!s.restoration.complete() || effect.identity != s.restoration.stateIdentity() ||
            !s.restorationCheckpoint || !s.CaptureRestoration(state, effect, &finalRestoration, error, {}) ||
            !SameRestorationCheckpoint(finalRestoration->observation(), s.restorationCheckpoint->observation()))) ||
        !s.lease.BeginCommit(envelope, context, changes, Hash(expected), error))
        return s.Stop(error, "provider_lease_commit_not_authorized");
    const auto &environment = s.options.selected.environment;
    CydiaSources::ProtectedFileSnapshot before, status, finalStatus;
    std::vector<CydiaRuntime::AutoStateDelta> deltas;
    for (const auto &change : changes) deltas.push_back({change.package, change.architecture, change.automatic});
    std::string updated, finalState; P::Error ignored;
    bool prepared = CydiaSources::ReadSharedStateFile(environment.extendedStates, &before) && before.bytes == expected &&
        CydiaSources::ReadSharedStateFile(environment.dpkgAdmin + "/status", &status) && status.identity.exists &&
        CydiaRuntime::MergeExtendedState(before.bytes, status.bytes, state.nativeArchitecture, state.registeredArchitectures, deltas, &updated) &&
        CydiaSources::ReadSharedStateFile(environment.dpkgAdmin + "/status", &finalStatus) &&
        finalStatus.identity.sameVersion(status.identity) && finalStatus.bytes == status.bytes && s.Parent(nullptr, error) &&
        P::RecheckEvidence(s.native.configurationEvidence, &ignored) && s.FrozenSnapshot(&finalState, error) &&
        (finalState == s.initialState ? s.options.review.binding.packageStateIdentity : "lease:" + finalState) == context.stateIdentity &&
        !s.cancelled.load() && !s.disconnected.load();
    if (prepared && s.protectedDeconfiguration) {
        std::shared_ptr<const ProtectedRestorationCheckpoint> recaptured;
        prepared = s.CaptureRestoration(state, effect, &recaptured, error, {}) &&
            SameRestorationCheckpoint(recaptured->observation(), finalRestoration->observation()) &&
            s.restoration.complete() && s.effects.quiescent() && s.Parent(nullptr, error) &&
            !s.cancelled.load() && !s.disconnected.load();
    }
    // From this point the channel must await settlement even when notification
    // delivery fails. The protected compare-and-replace determines the result.
    if (prepared && started) started();
    const bool committed = prepared && CydiaSources::ReplaceSharedStateFile(environment.extendedStates, before, updated).succeeded();
    s.SynchronizeCancellation();
    const bool settled = s.lease.SettleCommit(committed, error);
    s.ready = false; return settled;
}
void TransactionOwner::Cancel() { implementation_->cancelled.store(true); }
void TransactionOwner::TransportLost() { implementation_->disconnected.store(true); implementation_->cancelled.store(true); }
bool TransactionOwner::Close(std::string *error) {
    auto &s = *implementation_; s.SynchronizeCancellation();
    const bool closed = s.lease.Close(error); if (closed) s.ready = false; return closed;
}
bool TransactionOwner::mutationStarted() const { return implementation_->lease.mutationStarted(); }
bool TransactionOwner::complete() const { return implementation_->lease.complete(); }
bool TransactionOwner::indeterminate() const { return implementation_->lease.indeterminate(); }
}}
