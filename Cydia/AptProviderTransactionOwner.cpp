/* Copyright (C) 2026 Torrekie; GPL-3.0-or-later. */
#include "Cydia/AptProviderTransactionOwner.hpp"
#include "Cydia/AptProviderNativeDpkgAuthority.hpp"
#include "Cydia/DpkgRunner.h"
#include "Cydia/ExtendedState.hpp"
#include "Cydia/RuntimeSnapshotInputs.hpp"
#include "Cydia/RuntimeState.hpp"
#include "Cydia/SourceDocumentCommit.hpp"
#include <apt-pkg/hashes.h>
#include <algorithm>
#include <atomic>
#include <cerrno>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

namespace CydiaAPT { namespace Provider {
namespace {
namespace P = CydiaRuntime::Privileged;
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
    NativeDpkgAuthority native;
    TransactionArchiveStore archives;
    TransactionLease lease;
    ComponentSuccession components;
    TriggerEffectLedger effects;
    TransactionLeaseIdentity identity;
    std::set<std::uint64_t> completedUnpacks;
    std::string initialState;
    bool begun = false, ready = false;
    std::atomic<bool> cancelled{false}, disconnected{false};
    explicit Implementation(const TransactionOwnerOptions &value) : options(value) {}
    bool Stop(std::string *error, const char *code) {
        ready = false; lease.Cancel(); return Fail(error, code);
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
    bool FrozenSnapshot(std::string *token, std::string *error) {
        // Configuration and component evidence is independently guarded above.
        // Re-reading registration/source/keyring policy here would wrongly
        // invalidate an approved package that legitimately replaces those files.
        P::Environment environment;
        environment.dpkgAdmin = options.selected.environment.dpkgAdmin;
        environment.extendedStates = options.selected.environment.extendedStates;
        std::vector<P::Evidence> inputs; P::Error ignored;
        if (!P::CaptureSnapshotInputs(environment, P::SnapshotScope::PackageState, &inputs, &ignored))
            return Fail(error, "provider_dpkg_state_unavailable");
        for (const auto &input : inputs) {
            if (input.path == environment.dpkgAdmin + "/updates")
                for (const auto &name : input.entries)
                    if (!name.empty() && name.find_first_not_of("0123456789") == std::string::npos)
                        return Fail(error, "provider_dpkg_journal_unsettled");
            if (!options.reviewedEffects && input.path == environment.dpkgAdmin + "/triggers/Unincorp" && !input.bytes.empty())
                return Fail(error, "provider_dpkg_trigger_state_unsettled");
        }
        if (!P::RecheckEvidence(inputs, &ignored) || !P::RecheckEvidence(native.configurationEvidence, &ignored))
            return Fail(error, "provider_dpkg_state_changed");
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
        if (!reader.RunAndCaptureBounded(arguments, output, limit, 3000, cancel).succeeded())
            return Fail(error, "provider_dpkg_state_query_failed");
        return true;
    }
    bool CaptureContext(const std::set<std::uint64_t> &unpacked, TransactionLeaseContext *context,
        DpkgState *state, std::string *error, const std::function<bool()> &cancel, TriggerEffectCheckpoint *effect = nullptr) {
        if (!context || !state) return Fail(error, "provider_lease_input_invalid");
        *context = TransactionLeaseContext(); *state = DpkgState();
        if ((cancel && cancel()) || !Parent(context, error) || !ComponentFiles(unpacked, &context->components, error, cancel) ||
            !components.Observe(unpacked, context->components, error) || !archives.Capture(&context->stagedArchives, error, cancel)) return false;
        std::string before, after, nativeArchitecture, foreignArchitectures, records;
        if (!FrozenSnapshot(&before, error)) return false;
        const auto &environment = options.selected.environment;
        std::vector<std::string> arguments{"--root=" + environment.dpkgRoot, "--admindir=" + environment.dpkgAdmin, "--print-architecture"};
        if (!Query(environment.dpkg, arguments, 32768, context->components, &nativeArchitecture, error, cancel)) return false;
        arguments.back() = "--print-foreign-architectures";
        if (!Query(environment.dpkg, arguments, 32768, context->components, &foreignArchitectures, error, cancel)) return false;
        arguments = {"--admindir=" + environment.dpkgAdmin, "--showformat=" + std::string(DpkgStateQueryFormat()), "--show"};
        if (!Query(environment.dpkgQuery, arguments, 32 * 1024 * 1024, context->components, &records, error, cancel) ||
            !FrozenSnapshot(&after, error) || before != after || !Parent(context, error)) return false;
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
            const auto snapshot = [&](std::string *token, std::string *reason) {
                std::string bytes;
                if (!FrozenSnapshot(&bytes, reason)) return false;
                *token = bytes == initialState ? options.review.binding.packageStateIdentity : "lease:" + bytes; return true;
            };
            if (!CaptureTriggerEffectCheckpoint(options.selected.environment, *state, lock, &checkpoint, error, cancel, snapshot)) return false;
            if (effect) *effect = std::move(checkpoint);
        }
        return true;
    }
    bool DrainEffects(ParentExecutionReply *last, std::string *error, const std::function<bool()> &cancel,
        const std::function<void()> &started, DpkgState *finalState = nullptr) {
        if (!options.reviewedEffects) return true;
        while (!effects.quiescent()) {
            TransactionLeaseContext before; DpkgState state; TriggerEffectCheckpoint checkpoint;
            if (!Active(cancel, error) || !CaptureContext(completedUnpacks, &before, &state, error, cancel, &checkpoint) ||
                checkpoint.identity != effects.stateIdentity()) return Stop(error, "provider_trigger_state_changed");
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
            struct stat input, status;
            if (channels.inputDescriptor < 3 || channels.statusDescriptor < 3 || channels.inputDescriptor == channels.statusDescriptor ||
                !channels.started || !channels.settled || fstat(channels.inputDescriptor, &input) != 0 ||
                fstat(channels.statusDescriptor, &status) != 0 || !S_ISFIFO(input.st_mode) || !S_ISFIFO(status.st_mode) ||
                (input.st_dev == status.st_dev && input.st_ino == status.st_ino) ||
                (fcntl(channels.inputDescriptor, F_GETFL) & O_ACCMODE) != O_RDONLY ||
                (fcntl(channels.statusDescriptor, F_GETFL) & O_ACCMODE) != O_WRONLY)
                return Stop(error, "provider_trigger_child_channels_invalid");
            auto arguments = options.policy.protectedDpkgOptions;
            arguments.insert(arguments.end(), {"--status-fd=" + std::to_string(channels.statusDescriptor), "--no-triggers", "--triggers-only"});
            std::size_t targetBytes = 0;
            for (const auto &target : plan.targets) targetBytes += target.package.size() + target.architecture.size() + 2;
            // The plan already contains every fresh pending target. Native
            // --pending preserves that complete set without exceeding exec's
            // argument limit on a large but otherwise admitted installation.
            if (plan.targets.empty() || targetBytes > 32768) arguments.push_back("--pending");
            else for (const auto &target : plan.targets) arguments.push_back(target.package + ':' + target.architecture);
            P::Error ignored; ComponentClosureEvidence closure;
            TransactionLeaseContext refreshed; DpkgState currentState; TriggerEffectCheckpoint currentCheckpoint;
            if (!CaptureContext(completedUnpacks, &refreshed, &currentState, error, cancel, &currentCheckpoint) ||
                currentCheckpoint.identity != plan.checkpointIdentity ||
                !Parent(nullptr, error) || !P::ValidateDpkgArguments(options.selected.environment, arguments, &ignored) ||
                !Closure(options.selected.environment.dpkg, refreshed.components, &closure, error, cancel) || !Active(cancel, error) ||
                !lease.AuthorizeEffects(refreshed, plan.envelopeIdentity, plan.pass, closure, error))
                return Stop(error, "provider_trigger_drain_not_authorized");
            arguments.insert(arguments.begin(), {"--root=" + options.selected.environment.dpkgRoot,
                "--admindir=" + options.selected.environment.dpkgAdmin});
            if (cancel && cancel()) reply.launchError = ECANCELED;
            else reply = options.execute(options.selected.environment.dpkg, arguments, channels.inputDescriptor, channels.statusDescriptor, [&] {
                std::string ignoredStart; lease.StartedEffects(plan.pass, &ignoredStart);
                channels.started(); if (started) started();
            });
            if (last) *last = reply;
            SynchronizeCancellation();
            TransactionLeaseContext after; DpkgState afterState; TriggerEffectCheckpoint next; std::string reason;
            const bool success = reply.started && !reply.exitCode && !reply.signal && !reply.launchError;
            const bool captured = success && CaptureContext(completedUnpacks, &after, &afterState, &reason, {}, &next);
            const bool verified = captured && effects.SettleDrain(plan.pass, reply, next, &reason);
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
    if (o.reviewedEffects) {
        if (!o.effectChildChannels) return s.Stop(error, "provider_trigger_child_channels_unavailable");
        if (Wire(o.reviewedEffects->primaryReview) != Wire(o.review)) return s.Stop(error, "provider_trigger_review_changed");
        for (const auto &action : o.review.execution.actions)
            if (action.action == ExecutionAction::Triggers || action.action == ExecutionAction::Deconfigure)
                return s.Stop(error, "provider_trigger_review_unsupported");
    }
    if (!s.Active(cancel, error) || !o.execute || !s.Parent(nullptr, error) ||
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
    if (!review.Accept(o.review, o.policy, error) || !P::RuntimeSnapshot(environment, &originalState, &ignored) ||
        originalState != o.review.binding.packageStateIdentity)
        return s.Stop(error, "provider_lease_state_changed");
    if (!ResolveNativeDpkgAuthority(o.selected, o.review, &s.native, error, cancel)) {
        s.ready = false; return false; // Preserve the typed missing/unsupported authority diagnostic.
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
    if (o.reviewedEffects && (!s.effects.Begin(*o.reviewedEffects, checkpoint, error) ||
        !s.effects.RefineIncoming(s.archives.effectControls(), error))) return s.Stop(error, "provider_trigger_review_changed");
    if (!s.lease.Begin(identity, o.review, o.policy, context, s.archives.archives(),
            s.archives.successors(), o.changes, error)) return s.Stop(error, "provider_lease_admission_changed");
    s.ready = true; if (error) error->clear(); return true;
}
bool TransactionOwner::Capture(const TransactionLeaseEnvelope &envelope, DpkgState *state, std::string *error,
    const std::function<bool()> &cancelled) {
    auto &s = *implementation_; TransactionLeaseContext context; TriggerEffectCheckpoint effect;
    const auto cancel = s.Cancellation(cancelled);
    if (!s.ready || !s.Active(cancel, error) || !s.CaptureContext(s.completedUnpacks, &context, state, error, cancel, &effect) ||
        (s.options.reviewedEffects && effect.identity != s.effects.stateIdentity()) ||
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
    if (!s.ready || status < 3 || input < 0 || !s.Active(cancel, error) ||
        !s.lease.Expects(envelope) || !SameBinding(request.binding, s.options.review.binding) ||
        !s.DrainEffects(result, error, cancel, notifyStarted) ||
        !s.CaptureContext(s.completedUnpacks, &before, &state, error, cancel, &beforeEffects) ||
        (s.options.reviewedEffects && (!s.effects.quiescent() || beforeEffects.identity != s.effects.stateIdentity())))
        return s.Stop(error, "provider_lease_capture_failed");
    ParentExecutionEvidence evidence; evidence.binding = s.options.review.binding; evidence.frontendLockHeld = true;
    evidence.statusDescriptor = status;
    ComponentClosureEvidence closure; AuthorizedExecution batch; P::Error ignored;
    if (!ApplyDpkgStateEvidence(state, s.options.review, request, &evidence, error) ||
        !P::ValidateDpkgArguments(s.options.selected.environment, request.arguments, &ignored) ||
        !s.Closure(s.options.selected.environment.dpkg, before.components, &closure, error, cancel) ||
        !s.Active(cancel, error) || !s.lease.Authorize(envelope, before, request, evidence, closure, &batch, error))
        return s.Stop(error, "provider_lease_batch_not_authorized");
    if (s.options.reviewedEffects && !s.effects.PreparePrimary(beforeEffects.identity, batch, error)) {
        ParentExecutionReply denied; denied.launchError = EPERM; std::string ignoredSettlement;
        s.lease.Settle(batch.batch, denied, {}, false, &ignoredSettlement);
        return s.Stop(error, "provider_trigger_primary_not_authorized");
    }
    auto arguments = batch.arguments;
    arguments.insert(arguments.begin(), {"--root=" + s.options.selected.environment.dpkgRoot,
        "--admindir=" + s.options.selected.environment.dpkgAdmin});
    // Direct executor owns actual spawn/reap. It must not propagate exceptions
    // or return while a child remains live; channel cancellation never kills it.
    if (cancel()) result->launchError = ECANCELED;
    else *result = s.options.execute(s.options.selected.environment.dpkg, arguments, input, status, [&] {
        std::string ignoredStart; s.lease.Started(batch.batch, &ignoredStart);
        notifyStarted();
    });
    s.SynchronizeCancellation();
    auto completed = s.completedUnpacks;
    for (auto id : batch.actions)
        for (const auto &action : s.options.review.execution.actions)
            if (id == action.identifier && action.action == ExecutionAction::Unpack) completed.insert(id);
    TransactionLeaseContext after; std::string settlementError; TriggerEffectCheckpoint afterEffects;
    const bool success = result->started && !result->exitCode && !result->signal && !result->launchError;
    const bool captured = success && s.CaptureContext(completed, &after, afterState, &settlementError, {}, &afterEffects);
    const bool verified = captured && (s.options.reviewedEffects ? s.effects.Reconcile(batch, *result, afterEffects, &settlementError) :
        VerifyDpkgStateTransition(state, *afterState, s.options.review, batch, &settlementError));
    const bool settled = s.lease.Settle(batch.batch, *result, after, verified, &settlementError);
    if (!settled) return s.Stop(error, "provider_lease_requires_new_review");
    s.completedUnpacks.swap(completed);
    return s.DrainEffects(result, error, cancel, notifyStarted, afterState);
}
bool TransactionOwner::Commit(const TransactionLeaseEnvelope &envelope, const std::vector<AutoInstalledDelta> &changes,
    const std::string &expected, std::string *error, const std::function<void()> &started) {
    auto &s = *implementation_; TransactionLeaseContext context; DpkgState state; TriggerEffectCheckpoint effect;
    if (!s.ready || !s.Active({}, error) || expected != s.options.expectedExtendedState ||
        !s.CaptureContext(s.completedUnpacks, &context, &state, error, {}, &effect) ||
        (s.options.reviewedEffects && (!s.effects.quiescent() || effect.identity != s.effects.stateIdentity())) ||
        !s.lease.BeginCommit(envelope, context, changes, Hash(expected), error))
        return s.Stop(error, "provider_lease_commit_not_authorized");
    const auto &environment = s.options.selected.environment;
    CydiaSources::ProtectedFileSnapshot before, status, finalStatus;
    std::vector<CydiaRuntime::AutoStateDelta> deltas;
    for (const auto &change : changes) deltas.push_back({change.package, change.architecture, change.automatic});
    std::string updated, finalState; P::Error ignored;
    const bool prepared = CydiaSources::ReadSharedStateFile(environment.extendedStates, &before) && before.bytes == expected &&
        CydiaSources::ReadSharedStateFile(environment.dpkgAdmin + "/status", &status) && status.identity.exists &&
        CydiaRuntime::MergeExtendedState(before.bytes, status.bytes, state.nativeArchitecture, state.registeredArchitectures, deltas, &updated) &&
        CydiaSources::ReadSharedStateFile(environment.dpkgAdmin + "/status", &finalStatus) &&
        finalStatus.identity.sameVersion(status.identity) && finalStatus.bytes == status.bytes && s.Parent(nullptr, error) &&
        P::RecheckEvidence(s.native.configurationEvidence, &ignored) && s.FrozenSnapshot(&finalState, error) &&
        (finalState == s.initialState ? s.options.review.binding.packageStateIdentity : "lease:" + finalState) == context.stateIdentity &&
        !s.cancelled.load() && !s.disconnected.load();
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
