/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderServer.hpp"
#include "Cydia/AptBackendImplementation.hpp"
#include <algorithm>
#include <chrono>
#include <climits>

namespace CydiaAPT { namespace Provider {
namespace {
using Clock = std::chrono::steady_clock;
constexpr unsigned MaximumMilliseconds = 3 * 60 * 60 * 1000;
bool StableCode(const std::string &code) {
    if (code.empty() || code.size() > 96 || code.front() < 'a' || code.front() > 'z') return false;
    for (char c : code) if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_')) return false;
    return true;
}
bool ChangesSelection(Operation op) {
    switch (op) {
        case Operation::ApplyStatus: case Operation::FixBroken: case Operation::MinimizeUpgrade:
        case Operation::ResolveDependencies: case Operation::ClearSelections: case Operation::PrepareDistUpgrade:
        case Operation::ClearPackage: case Operation::InstallPackage: case Operation::ReinstallPackage:
        case Operation::RemovePackage: return true;
        default: return false;
    }
}
bool Reviewed(Operation op) {
    return op == Operation::PrepareArchives || op == Operation::RunFetcher || op == Operation::RunPackageManager;
}
bool ProgressOperation(Operation op) {
    return op == Operation::RunFetcher || op == Operation::RunPackageManager || op == Operation::UpdateLists ||
        op == Operation::SourcePreflight || op == Operation::SourceResource;
}
Message Reply(const Message &request) {
    Message result; result.kind = MessageKind::Response; result.sequence = request.sequence;
    result.operation = request.operation; result.binding = request.binding; return result;
}
}

bool ServerFrameReader::Push(const char *bytes, std::size_t size, std::size_t *consumed,
                            std::string *frame, bool *complete) {
    if (consumed) *consumed = 0;
    if (complete) *complete = false;
    if (!error_.empty()) return false;
    if (!consumed || !frame || !complete || (!bytes && size)) { error_ = "provider_invalid_frame"; return false; }
    frame->clear();
    while (*consumed < size) {
        const std::size_t count(std::min(size - *consumed, expected_ - bytes_.size()));
        bytes_.append(bytes + *consumed, count); *consumed += count;
        if (bytes_.size() != expected_) break;
        if (expected_ == 8) {
            if (bytes_.compare(0, 4, "CYAP") != 0) { error_ = "provider_invalid_frame"; return false; }
            std::uint32_t body(0);
            for (unsigned i = 4; i != 8; ++i) body = (body << 8) | static_cast<unsigned char>(bytes_[i]);
            if (!body || body > MaximumMessageBytes - 8) { error_ = "provider_message_too_large"; return false; }
            expected_ += body;
        } else {
            Message message;
            if (!DecodeFrame(bytes_, &message)) { error_ = "provider_invalid_frame"; return false; }
            frame->swap(bytes_); expected_ = 8; *complete = true; break;
        }
    }
    return true;
}

class Server::Implementation {
public:
    Internal::BackendImplementation &backend;
    ServerHooks hooks;
    ServerLimits limits;
    Info info;
    Environment approved;
    Binding current;
    ReviewedTransaction review;
    std::vector<AutoInstalledDelta> reviewDeltas;
    Message active;
    Message completed;
    ServerRequestContext context;
    Clock::time_point deadline;
    std::string error;
    std::uint64_t nextSequence = 1, parentSequence = 0;
    std::size_t exchanged = 0;
    unsigned messages = 0;
    bool admitted = false, stopped = false, busy = false, locked = false;
    bool cancelling = false, cancelAcknowledged = false, polling = false, parentBusy = false, executionStarted = false;
    bool committed = false;
    bool completedCancellable = false;
    std::set<std::uint64_t> executed;

    Implementation(Internal::BackendImplementation &backend, const ServerHooks &hooks, const ServerLimits &limits) :
        backend(backend), hooks(hooks), limits(limits) {
        if (!limits.requestMilliseconds || limits.requestMilliseconds > MaximumMilliseconds ||
            !limits.operationMilliseconds || limits.operationMilliseconds > MaximumMilliseconds ||
            limits.exchangeBytes < MaximumMessageBytes || limits.exchangeBytes > 256u * 1024u * 1024u ||
            !limits.exchangeMessages || limits.exchangeMessages > 4096) Fail("provider_invalid_options");
    }
    bool Fail(const char *code) { error = code; stopped = true; admitted = false; return false; }
    bool Budget(std::size_t bytes) {
        if (++messages > limits.exchangeMessages || bytes > limits.exchangeBytes - exchanged)
            return Fail("provider_message_limit");
        exchanged += bytes; return true;
    }
    unsigned Remaining() const {
        const auto value(std::chrono::duration_cast<std::chrono::milliseconds>(deadline - Clock::now()).count());
        return value <= 0 ? 0 : static_cast<unsigned>(std::min<decltype(value)>(value, UINT_MAX));
    }
    bool Emit(const Message &message) {
        std::string frame;
        if (!EncodeFrame(message, &frame) || !Budget(frame.size())) return Fail("provider_message_too_large");
        if (!hooks.emitFrame || !hooks.emitFrame(frame, context.control)) return Fail("provider_channel_failed");
        return true;
    }
    bool Cancelled() {
        if (stopped || cancelAcknowledged) return true;
        if (polling) return Remaining() == 0;
        polling = true;
        std::string frame;
        bool polled(false);
        try { polled = hooks.pollControl && hooks.pollControl(&frame, context.control); }
        catch (...) { polling = false; return !Fail("provider_channel_failed"); }
        polling = false;
        if (!polled) return !Fail("provider_channel_failed");
        if (!frame.empty()) {
            Message cancel; std::uint64_t target(0);
            if (!Budget(frame.size()) || !DecodeFrame(frame, &cancel) || !ValidRequestBinding(cancel) ||
                cancel.operation != Operation::Cancel || cancel.kind != MessageKind::Request ||
                cancel.sequence != nextSequence || !SameBinding(cancel.binding, active.binding) ||
                !Decode(cancel.payload, &target) || target != active.sequence || cancel.succeeded || !cancel.errorCode.empty())
                return !Fail("provider_invalid_cancel_request");
            ++nextSequence; cancelling = cancelAcknowledged = true;
            Message response(Reply(cancel)); response.succeeded = true;
            if (!Emit(response)) return true;
        }
        if (Remaining() == 0) cancelling = true;
        return cancelling;
    }
    bool Progress(const ProgressEvent &event) {
        if (!busy || stopped || !ProgressOperation(active.operation) || Cancelled()) return false;
        if (!ValidProgressEvent(event)) return Fail("provider_invalid_progress");
        Message message; message.kind = MessageKind::Event; message.sequence = active.sequence;
        message.operation = Operation::Progress; message.binding = active.binding;
        if (!Encode(event, &message.payload)) return Fail("provider_message_too_large");
        return Emit(message);
    }
    bool ParentAllowed(Operation op) const {
        switch (op) {
            case Operation::AcquireFrontendLock: return active.operation == Operation::LockForTransaction && !locked;
            case Operation::ReleaseFrontendLock: return active.operation == Operation::UnlockForTransaction && locked;
            case Operation::ExecuteDpkg: case Operation::CommitExtendedState:
                return active.operation == Operation::RunPackageManager && locked && !current.review.empty();
            case Operation::AuthorizeArchive: return active.operation == Operation::RunFetcher && locked &&
                !current.review.empty() && (info.capabilities & AuthorizedArchiveGrants);
            case Operation::CaptureStateSnapshot: return active.operation != Operation::Hello;
            default: return false;
        }
    }
    bool Parent(Operation op, const std::string &payload, Message *result) {
        if (!result || !busy || stopped || parentBusy || !ParentAllowed(op) || parentSequence == UINT64_MAX)
            return Fail("provider_invalid_parent_request");
        const bool cancelled(Cancelled());
        if (stopped) return false;
        if (cancelled && op != Operation::ReleaseFrontendLock && op != Operation::CaptureStateSnapshot) {
            *result = Message(); result->errorCode = "provider_cancelled"; return true;
        }
        ParentExecutionRequest execution;
        if (op == Operation::ExecuteDpkg) {
            if (committed || !Decode(payload, &execution) || !SameBinding(execution.binding, current) || execution.actions.empty())
                return Fail("provider_invalid_execution_request");
            std::set<std::uint64_t> unique;
            for (auto id : execution.actions) {
                if (!unique.insert(id).second || executed.count(id)) return Fail("provider_invalid_execution_request");
                bool found(false);
                for (const auto &action : review.execution.actions) if (action.identifier == id) found = true;
                if (!found) return Fail("provider_invalid_execution_request");
            }
        } else if (op == Operation::CommitExtendedState) {
            ExtendedStateRequest state; std::string expectedDeltas, actualDeltas;
            if (committed || executed.size() != review.execution.actions.size() || !Decode(payload, &state) ||
                !SameBinding(state.binding, current) || !Encode(reviewDeltas, &expectedDeltas) ||
                !Encode(state.changes, &actualDeltas) || expectedDeltas != actualDeltas)
                return Fail("provider_invalid_state_request");
        } else if (op == Operation::AuthorizeArchive) {
            ArchiveAuthorizationRequest grant;
            if (!Decode(payload, &grant) || !SameBinding(grant.binding, current) ||
                std::none_of(review.execution.archives.begin(), review.execution.archives.end(),
                    [&](const ArchiveManifest &archive) { return archive.identifier == grant.archive; }))
                return Fail("provider_invalid_authorization_request");
        } else if (!payload.empty()) return Fail("provider_invalid_parent_request");
        Message request; request.kind = MessageKind::ParentRequest; request.operation = op;
        request.sequence = ++parentSequence; request.binding = active.binding; request.payload = payload;
        std::string outgoing, incoming;
        if (!ValidRequestBinding(request) || !EncodeFrame(request, &outgoing) || !Budget(outgoing.size()))
            return Fail("provider_invalid_parent_request");
        parentBusy = true;
        bool received(false);
        try { received = hooks.parentExchange && hooks.parentExchange(outgoing, &incoming, context.control); }
        catch (...) { parentBusy = false; return Fail("provider_parent_operation_failed"); }
        parentBusy = false;
        if (!received) return Fail("provider_channel_failed");
        Message response;
        if (!Budget(incoming.size()) || !DecodeFrame(incoming, &response) || !ValidateReply(request, response))
            return Fail("provider_invalid_parent_reply");
        if (!response.succeeded) {
            response.errorCode = StableCode(response.errorCode) ? response.errorCode : "provider_parent_operation_failed";
            response.payload.clear();
        } else if (op == Operation::ExecuteDpkg) {
            ParentExecutionReply status;
            if (!Decode(response.payload, &status)) return Fail("provider_invalid_parent_reply");
            executionStarted = executionStarted || status.started;
            if (status.started && status.exitCode == 0 && !status.signal && !status.launchError)
                executed.insert(execution.actions.begin(), execution.actions.end());
        } else if (op == Operation::AuthorizeArchive) {
            ArchiveAuthorizationReply grant;
            if (!Decode(response.payload, &grant)) return Fail("provider_invalid_authorization_reply");
        } else if (op == Operation::CaptureStateSnapshot) {
            Environment snapshot;
            if (!Decode(response.payload, &snapshot) || !ValidEnvironment(snapshot)) return Fail("provider_invalid_parent_snapshot");
            Environment expected(approved); expected.packageStateIdentity = snapshot.packageStateIdentity;
            if (!SameEnvironment(expected, snapshot)) return Fail("provider_environment_changed");
            approved = snapshot;
        } else if (!response.payload.empty()) return Fail("provider_invalid_parent_reply");
        if (response.succeeded && op == Operation::AcquireFrontendLock) locked = true;
        if (response.succeeded && op == Operation::ReleaseFrontendLock) locked = false;
        if (response.succeeded && op == Operation::CommitExtendedState) committed = true;
        *result = std::move(response); return true;
    }
    bool Snapshot() {
        Message response;
        return Parent(Operation::CaptureStateSnapshot, "", &response) && response.succeeded;
    }
    bool Reject(Message *response, const std::string &code) {
        response->succeeded = false; response->payload.clear();
        response->errorCode = StableCode(code) ? code : "provider_request_failed";
        error = response->errorCode; return true;
    }
    template<class T> bool Result(const T &value, Message *response) {
        if (!Encode(value, &response->payload)) return Fail("provider_message_too_large");
        return true;
    }
    bool Empty(const Message &request, Message *response) {
        return request.payload.empty() || (Reject(response, "provider_invalid_request") && false);
    }
    bool Dispatch(const Message &request, Message *response) {
        response->succeeded = true;
        switch (request.operation) {
            case Operation::Reset: case Operation::OpenCache: {
                if (!Empty(request, response)) return true;
                if (locked) return Reject(response, "provider_cache_change_while_locked");
                if (current.cacheEpoch == UINT64_MAX) return Fail("provider_revision_exhausted");
                if (!Snapshot()) return stopped ? false : Reject(response, "provider_parent_operation_failed");
                CacheReply cache; cache.binding = current;
                if (request.operation == Operation::Reset) backend.reset();
                else cache.opened = backend.openCache();
                if (request.operation == Operation::Reset || cache.opened) {
                    ++cache.binding.cacheEpoch; cache.binding.selectionRevision = 0; cache.binding.review.clear();
                    cache.binding.packageStateIdentity = approved.packageStateIdentity;
                    current = cache.binding; review = ReviewedTransaction(); reviewDeltas.clear();
                }
                return Result(cache, response);
            }
            case Operation::LockForTransaction: case Operation::UnlockForTransaction: {
                if (!Empty(request, response)) return true;
                const bool acquire(request.operation == Operation::LockForTransaction);
                if (acquire == locked) return Reject(response, "provider_invalid_lock_request");
                Message parent;
                if (!Parent(acquire ? Operation::AcquireFrontendLock : Operation::ReleaseFrontendLock, "", &parent)) return false;
                if (acquire) return Result(parent.succeeded, response);
                return parent.succeeded || Reject(response, parent.errorCode);
            }
            case Operation::TransactionData: {
                if (!Empty(request, response)) return true;
                // Cydia captures the native review while holding the short
                // parent frontend lock. That lock does not require an older
                // review token; the snapshot must still match this cache.
                if (!Snapshot() || current.packageStateIdentity != approved.packageStateIdentity)
                    return stopped ? false : Reject(response, "provider_package_state_changed");
                ReviewedTransaction candidate; candidate.transaction = backend.transactionData(); candidate.binding = current;
                candidate.binding.review = "review:" + std::to_string(current.cacheEpoch) + ":" +
                    std::to_string(current.selectionRevision) + ":" + std::to_string(request.sequence);
                std::string reason;
                if (!hooks.buildReview(candidate.transaction, candidate.binding, &candidate.execution, &reason))
                    return Reject(response, reason.empty() ? "provider_review_unavailable" : reason);
                if (info.finiteTriggerEffects)
                    for (const auto &action : candidate.execution.actions)
                        if (action.action == ExecutionAction::Triggers || action.action == ExecutionAction::Deconfigure)
                            return Reject(response, "provider_trigger_review_unsupported");
                const auto deltas(backend.autoInstalledDeltas()); std::string deltaBytes;
                if (!Encode(deltas, &deltaBytes)) return Fail("provider_message_too_large");
                if (!Result(candidate, response)) return false;
                current = candidate.binding; review = std::move(candidate); reviewDeltas = deltas; return true;
            }
            case Operation::RunPackageManager: {
                if (!Empty(request, response)) return true;
                const auto manager(hooks.runPackageManager(review, reviewDeltas, context));
                if (manager.started != executionStarted) return Fail("provider_invalid_execution_reply");
                if (manager.result == PackageManagerResult::Completed &&
                    (executed.size() != review.execution.actions.size() || !committed))
                    return Fail("provider_incomplete_execution");
                return Result(manager, response);
            }
            case Operation::RunFetcher: case Operation::UpdateLists: {
                std::uint32_t interval;
                if (!Decode(request.payload, &interval) || interval > INT_MAX) return Reject(response, "provider_invalid_request");
                return request.operation == Operation::RunFetcher ? Result(backend.runFetcher(interval), response) :
                    Result(hooks.updateLists(interval, context), response);
            }
            case Operation::SourcePreflight: {
                SourcePreflightRequest check;
                if (!Decode(request.payload, &check) || !check.timeoutSeconds || check.timeoutSeconds > MaximumMilliseconds / 1000 ||
                    !check.maximumBytes || check.maximumBytes > 128u * 1024u * 1024u)
                    return Reject(response, "provider_invalid_request");
                return Result(backend.sourcePreflight(check, context.control.cancelled), response);
            }
            case Operation::SourceResource: {
                SourceResourceRequest check;
                if (!Decode(request.payload, &check) || !check.timeoutSeconds || check.timeoutSeconds > MaximumMilliseconds / 1000 ||
                    !check.maximumBytes || check.maximumBytes > MaximumStringBytes)
                    return Reject(response, "provider_invalid_request");
                return Result(backend.sourceResource(check, context.control.cancelled), response);
            }
            case Operation::SetSecurityMode: {
                RepositorySecurityMode mode;
                if (!Decode(request.payload, &mode)) return Reject(response, "provider_invalid_request");
                if (locked) return Reject(response, "provider_configuration_change_while_locked");
                if (!(info.capabilities & ExplicitSecurityOverrides) || !hooks.setSecurityMode)
                    return Reject(response, "provider_security_override_unsupported");
                const bool changed(hooks.setSecurityMode(mode, context)); if (changed) admitted = false;
                return Result(changed, response);
            }
            case Operation::RefreshArchitectures: {
                if (!Empty(request, response)) return true;
                if (locked) return Reject(response, "provider_configuration_change_while_locked");
                if (!hooks.refreshArchitectures) return Reject(response, "provider_operation_unsupported");
                const bool changed(hooks.refreshArchitectures(context)); if (changed) admitted = false;
                return Result(changed, response);
            }
            case Operation::LookupPackage: case Operation::PackageHandle: {
                LookupRequest lookup;
                if (!Decode(request.payload, &lookup)) return Reject(response, "provider_invalid_request");
                return request.operation == Operation::LookupPackage ?
                    Result(backend.lookupPackage(lookup.name, lookup.preferredArchitecture), response) :
                    Result(backend.packageHandle(lookup.name, lookup.preferredArchitecture), response);
            }
            case Operation::RemovePackage: {
                RemoveRequest removal;
                if (!Decode(request.payload, &removal) || !removal.handle.valid()) return Reject(response, "provider_invalid_request");
                return Result(backend.removePackage(removal.handle, removal.purge), response);
            }
            case Operation::SourceField: {
                SourceFieldRequest field;
                if (!Decode(request.payload, &field) || !field.handle.valid()) return Reject(response, "provider_invalid_request");
                return Result(backend.sourceField(field.handle, field.name), response);
            }
#define PACKAGE_CASE(operation, method) case Operation::operation: { \
    PackageHandle handle; if (!Decode(request.payload, &handle) || !handle.valid()) return Reject(response, "provider_invalid_request"); \
    return Result(backend.method(handle), response); }
            PACKAGE_CASE(DowngradeHandles, downgradeHandles)
            PACKAGE_CASE(VersionHandles, versionHandles)
            PACKAGE_CASE(PackageSnapshot, packageSnapshot)
            PACKAGE_CASE(RecordData, recordData)
            PACKAGE_CASE(PackageState, packageState)
            PACKAGE_CASE(Relations, relations)
            PACKAGE_CASE(ClearPackage, clearPackage)
            PACKAGE_CASE(InstallPackage, installPackage)
            PACKAGE_CASE(ReinstallPackage, reinstallPackage)
#undef PACKAGE_CASE
#define SOURCE_CASE(operation, method) case Operation::operation: { \
    SourceHandle handle; if (!Decode(request.payload, &handle) || !handle.valid()) return Reject(response, "provider_invalid_request"); \
    return Result(backend.method(handle), response); }
            SOURCE_CASE(SourceSnapshot, sourceSnapshot)
            SOURCE_CASE(SourceFileIDs, sourceFileIDs)
#undef SOURCE_CASE
#define VALUE_CASE(operation, method) case Operation::operation: { \
    if (!Empty(request, response)) { return true; } return Result(backend.method(), response); }
            VALUE_CASE(DrainErrors, drainErrors)
            VALUE_CASE(LoadSources, loadSources)
            VALUE_CASE(AutoInstalledDeltas, autoInstalledDeltas)
            VALUE_CASE(CacheState, cacheState)
            VALUE_CASE(ApplyStatus, applyStatus)
            VALUE_CASE(FixBroken, fixBroken)
            VALUE_CASE(MinimizeUpgrade, minimizeUpgrade)
            VALUE_CASE(CleanArchives, cleanArchives)
            VALUE_CASE(PrepareArchives, prepareArchives)
            VALUE_CASE(SourceList, sourceList)
            VALUE_CASE(PackageHandles, packageHandles)
            VALUE_CASE(ResolveDependencies, resolveDependencies)
            VALUE_CASE(PrepareDistUpgrade, prepareDistUpgrade)
            VALUE_CASE(SourceHandles, sourceHandles)
#undef VALUE_CASE
#define VOID_CASE(operation, method) case Operation::operation: { \
    if (!Empty(request, response)) { return true; } backend.method(); return true; }
            VOID_CASE(CreateCacheViews, createCacheViews)
            VOID_CASE(DiscardErrors, discardErrors)
            VOID_CASE(ClearSelections, clearSelections)
#undef VOID_CASE
            default: return Reject(response, "provider_operation_unsupported");
        }
    }
    bool HelloRequest(const Message &request, Message *response) {
        Hello hello;
        if (!Decode(request.payload, &hello) || !ValidHello(hello)) return Fail("provider_invalid_session");
        if (!hooks.admit || !hooks.pollControl || !hooks.emitFrame || !hooks.parentExchange || !hooks.operationContext ||
            !hooks.buildReview || !hooks.updateLists || !hooks.runPackageManager)
            return Fail("provider_server_hooks_incomplete");
        std::string reason;
        if (!hooks.admit(hello, &info, &reason)) { stopped = true; return Reject(response, reason.empty() ? "provider_admission_denied" : reason); }
        if (!Compatible(info, hello.expected, &reason) || (info.capabilities & hello.requiredCapabilities) != hello.requiredCapabilities)
            return Fail("provider_environment_changed");
        if (info.finiteTriggerEffects != hello.finiteTriggerEffects)
            return Fail("provider_trigger_mode_mismatch");
        if ((info.capabilities & ExplicitSecurityOverrides) && !hooks.setSecurityMode)
            return Fail("provider_server_hooks_incomplete");
        current.providerIdentifier = info.identifier; current.session = hello.challenge;
        current.configurationIdentity = info.environment.configurationIdentity;
        current.policyIdentity = info.environment.policyIdentity; current.packageStateIdentity = info.environment.packageStateIdentity;
        if (!SameBinding(request.binding, current)) return Fail("provider_invalid_session");
        approved = info.environment; admitted = true; response->succeeded = true;
        return Result(info, response);
    }
    bool Frame(const std::string &frame, std::string *output) {
        if (!output || stopped || busy) return Fail("provider_session_unavailable");
        output->clear(); exchanged = 0; messages = 0; error.clear();
        Message request;
        if (!Budget(frame.size()) || !DecodeFrame(frame, &request) || !ValidRequestBinding(request) ||
            request.kind != MessageKind::Request || request.sequence != nextSequence ||
            request.succeeded || !request.errorCode.empty() ||
            request.operation >= Operation::AcquireFrontendLock || nextSequence >= UINT64_MAX - 1)
            return Fail("provider_invalid_request");
        if (request.operation == Operation::Cancel) {
            // The client checks cancellation before consuming a buffered
            // response. Its Cancel can therefore arrive after our final poll
            // and completed response write. Settle exactly that request once,
            // using its original binding: cache/review state may already have
            // advanced. Never dispatch it again or undo a completed mutation.
            std::uint64_t target(0);
            if (!admitted || !completedCancellable || !Decode(request.payload, &target) ||
                target != completed.sequence || !SameBinding(request.binding, completed.binding))
                return Fail("provider_invalid_cancel_request");
            ++nextSequence; completedCancellable = false;
            Message response(Reply(request)); response.succeeded = true;
            if (!EncodeFrame(response, output) || !Budget(output->size())) return Fail("provider_message_too_large");
            return true;
        }
        if (!admitted && (request.operation != Operation::Hello || nextSequence != 1)) return Fail("provider_invalid_session");
        if (admitted && (request.operation == Operation::Hello || !SameBinding(request.binding, current)))
            return Fail("provider_binding_invalid");
        ++nextSequence; active = request; completedCancellable = false;
        busy = true; cancelling = cancelAcknowledged = false;
        executionStarted = committed = false; executed.clear();
        deadline = Clock::now() + std::chrono::milliseconds(ProgressOperation(request.operation) ?
            limits.operationMilliseconds : limits.requestMilliseconds);
        context.operation = request.operation;
        context.control.remainingMilliseconds = [this]() { return Remaining(); };
        context.control.cancelled = [this]() { return Cancelled(); };
        context.progress = [this](const ProgressEvent &event) { return Progress(event); };
        context.parentRequest = [this](Operation op, const std::string &payload, Message *reply) { return Parent(op, payload, reply); };
        Message response(Reply(request)); bool success(false), entered(false);
        try {
            if (request.operation == Operation::Hello) success = HelloRequest(request, &response);
            else if (ChangesSelection(request.operation) && current.selectionRevision == UINT64_MAX)
                success = Fail("provider_revision_exhausted");
            else if (Reviewed(request.operation) && (!locked || current.review.empty() || !SameBinding(review.binding, current)))
                success = Reject(&response, "provider_review_or_lock_required");
            else {
                entered = true; hooks.operationContext(&context);
                if (Cancelled()) success = stopped ? false : Reject(&response, "provider_cancelled");
                else if (Reviewed(request.operation) && (!Snapshot() || current.packageStateIdentity != approved.packageStateIdentity))
                    success = stopped ? false : Reject(&response, "provider_package_state_changed");
                else success = Dispatch(request, &response);
            }
        } catch (...) { success = Fail("provider_operation_callback_failed"); }
        if (entered) {
            try {
                // A Cancel may have arrived after the backend's last pulse.
                // Preserve the actual result/binding while acknowledging it.
                if (!stopped) (void) Cancelled();
            }
            catch (...) { success = Fail("provider_operation_callback_failed"); }
            // Clearing the adapter context must also run when the last
            // cancellation acknowledgement or its transport callback throws.
            try { hooks.operationContext(nullptr); }
            catch (...) { success = Fail("provider_operation_callback_failed"); }
        }
        busy = false;
        if (!success || (stopped && response.succeeded)) return false;
        if (response.succeeded && ChangesSelection(request.operation)) {
            ++current.selectionRevision; current.review.clear(); review = ReviewedTransaction(); reviewDeltas.clear();
        }
        if (request.operation == Operation::RunPackageManager) {
            current.review.clear(); review = ReviewedTransaction(); reviewDeltas.clear();
        }
        if (!EncodeFrame(response, output) || !Budget(output->size())) return Fail("provider_message_too_large");
        if (!admitted && request.operation != Operation::Hello) stopped = true;
        completed = Message(); completed.sequence = request.sequence;
        completed.operation = request.operation; completed.binding = request.binding;
        completedCancellable = admitted && !stopped && !cancelAcknowledged && request.operation != Operation::Hello;
        return true;
    }
};

Server::Server(Internal::BackendImplementation &backend, const ServerHooks &hooks, const ServerLimits &limits) :
    implementation_(new Implementation(backend, hooks, limits)) {}
Server::~Server() {}
bool Server::DispatchFrame(const std::string &request, std::string *response) { return implementation_->Frame(request, response); }
bool Server::ready() const { return implementation_->admitted && !implementation_->stopped; }
bool Server::closed() const { return implementation_->stopped; }
const Binding &Server::binding() const { return implementation_->current; }
const std::string &Server::lastError() const { return implementation_->error; }
}} // namespace CydiaAPT::Provider
