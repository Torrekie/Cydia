/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptBackendImplementation.hpp"
#include "Cydia/AptProviderSession.hpp"
#include "Cydia/RedactedURL.hpp"

#include <utility>

namespace CydiaAPT {
namespace Internal {
namespace P = Provider;

class RemoteBackend final : public BackendImplementation {
    std::unique_ptr<P::Session> session_;
    RemoteBackendOptions options_;
    BackendFailure failure_;
    std::vector<ErrorData> errors_;
    P::ReviewedTransaction review_;
    bool reviewed_ = false;
    bool requestExecutionStarted_ = false;

    static bool stableCode(const std::string &code) {
        if (code.empty() || code.size() > 96 || code[0] < 'a' || code[0] > 'z') return false;
        for (char byte : code)
            if (!((byte >= 'a' && byte <= 'z') || (byte >= '0' && byte <= '9') || byte == '_')) return false;
        return true;
    }
    static void redact(std::vector<ErrorData> *errors) {
        for (ErrorData &error : *errors) error.message = CydiaRuntime::RedactDiagnosticURLs(error.message);
    }
    static void redactFailures(std::vector<FetchFailureData> *failures) {
        for (FetchFailureData &failure : *failures) {
            failure.error = CydiaRuntime::RedactDiagnosticURLs(failure.error);
            failure.uri = CydiaRuntime::RedactDiagnosticURLs(failure.uri);
        }
    }
    template<class T> static void redact(T *) {}
    static void redact(FetchResultData *result) { redactFailures(&result->warnings); redactFailures(&result->failures); }
    static void redact(UpdateResultData *result) { redactFailures(&result->warnings); redactFailures(&result->failures); }
    static void redact(P::PackageManagerReply *result) { redact(&result->archives); }
    static void redact(SourcePreflightResult *result) {
        redact(&result->errors); redactFailures(&result->warnings); redactFailures(&result->failures);
    }
    static void redact(SourceResourceResult *result) { redact(&result->errors); }

    void fail(const std::string &code, bool disconnect = false) {
        if (disconnect && session_) session_->Close();
        // errorCode is machine state, never an upstream message or URL. Do not
        // queue raw worker text here; diagnostics have their own redacted DTO.
        failure_.code = stableCode(code) ? code : "provider_request_failed";
        failure_.indeterminate = failure_.indeterminate || (session_ && session_->indeterminate());
        if (errors_.size() < 256 && (errors_.empty() || errors_.back().message != failure_.code))
            errors_.push_back({failure_.code, false});
    }

    bool request(P::Operation operation, const std::string &payload, P::Message *reply,
                 AcquireStatus *status = nullptr, int statusFd = -1, unsigned timeoutMilliseconds = 0,
                 const std::function<bool()> &cancelled = std::function<bool()>(), bool *observedCancellation = nullptr) {
        requestExecutionStarted_ = false;
        if (!session_ || !session_->active()) {
            fail(failure_.code.empty() ? "provider_session_unavailable" : failure_.code);
            return false;
        }
        bool success(false), callbackFailed(false), callEntered(false);
        const bool cleanup(operation == P::Operation::UnlockForTransaction || operation == P::Operation::DrainErrors ||
                           operation == P::Operation::DiscardErrors);
        try {
            if (options_.operationContext)
                options_.operationContext(status == nullptr ? options_.status : status, statusFd);
            const unsigned timeout(cleanup ? 2000 : timeoutMilliseconds != 0 ? timeoutMilliseconds :
                operation == P::Operation::RunPackageManager || operation == P::Operation::RunFetcher ||
                operation == P::Operation::UpdateLists ? options_.transactionTimeoutMilliseconds : options_.requestTimeoutMilliseconds);
            const auto shouldCancel = [&]() {
                const bool stopping((options_.cancelled && options_.cancelled()) || (cancelled && cancelled()));
                if (observedCancellation != nullptr && stopping) *observedCancellation = true;
                return stopping;
            };
            callEntered = true;
            success = session_->Call(operation, payload, reply, timeout,
                cleanup ? std::function<bool()>() : std::function<bool()>(shouldCancel));
            requestExecutionStarted_ = session_->lastCallExecutionStarted();
        } catch (...) {
            if (callEntered) requestExecutionStarted_ = session_->lastCallExecutionStarted();
            fail("provider_operation_callback_failed", true);
            callbackFailed = true;
        }
        try {
            if (options_.operationContext) options_.operationContext(nullptr, -1);
        } catch (...) {
            fail("provider_operation_callback_failed", true);
            return false;
        }
        if (callbackFailed) return false;
        if (!success) {
            fail(session_->lastError().empty() ? failure_.code : session_->lastError());
            return false;
        }
        if (!reply->succeeded) { fail(reply->errorCode); return false; }
        return true;
    }

    template<class T> bool decode(const P::Message &reply, T *value) {
        if (P::Decode(reply.payload, value)) { redact(value); return true; }
        fail("provider_invalid_payload", true);
        return false;
    }
    template<class T> T value(P::Operation operation, const std::string &payload = std::string()) {
        P::Message reply; T result{};
        if (!request(operation, payload, &reply) || !decode(reply, &result)) return T();
        return result;
    }
    template<class T, class A> T argument(P::Operation operation, const A &input) {
        std::string payload;
        if (!P::Encode(input, &payload)) { fail("provider_invalid_request"); return T(); }
        return value<T>(operation, payload);
    }
    bool empty(P::Operation operation) {
        P::Message reply;
        if (!request(operation, "", &reply)) return false;
        if (!reply.payload.empty()) { fail("provider_invalid_payload", true); return false; }
        return true;
    }
    bool interval(int pulseInterval, std::string *payload) {
        if (pulseInterval < 0 || !P::Encode(static_cast<std::uint32_t>(pulseInterval), payload)) {
            fail("provider_invalid_request"); return false;
        }
        return true;
    }
    template<class T, class R> T sourceOperation(P::Operation operation, const R &input,
                                                const std::function<bool()> &cancelled) {
        T result;
        // The worker owns its acquisition deadline. Allow its bounded result
        // to arrive before the transport begins the separate cancel grace.
        constexpr unsigned ReplyAllowanceMilliseconds = 2000;
        constexpr unsigned MaximumSeconds = (3u * 60u * 60u * 1000u - ReplyAllowanceMilliseconds) / 1000u;
        std::string payload;
        if (input.timeoutSeconds == 0 || input.timeoutSeconds > MaximumSeconds || !P::Encode(input, &payload)) {
            fail("provider_invalid_request"); result.status = SourceCheckStatus::InvalidDefinition; return result;
        }
        bool cancelledDuringCall(false); P::Message reply;
        if (request(operation, payload, &reply, nullptr, -1, input.timeoutSeconds * 1000u + ReplyAllowanceMilliseconds,
                    cancelled, &cancelledDuringCall) && decode(reply, &result)) return result;
        if (cancelledDuringCall || failure_.code == "provider_cancelled") result.status = SourceCheckStatus::Cancelled;
        else if (failure_.code == "provider_timeout" || failure_.code == "provider_write_timeout" ||
                 failure_.code == "provider_cancellation_unsettled") result.status = SourceCheckStatus::TimedOut;
        result.errors.push_back({failure_.code, false});
        return result;
    }

public:
    RemoteBackend(std::unique_ptr<P::Session> session, const RemoteBackendOptions &options) :
        session_(std::move(session)), options_(options) {
        if (!session_ || !session_->active()) fail("provider_session_unavailable");
        if (options_.requestTimeoutMilliseconds == 0 || options_.transactionTimeoutMilliseconds == 0 ||
            options_.requestTimeoutMilliseconds > 3u * 60u * 60u * 1000u ||
            options_.transactionTimeoutMilliseconds > 3u * 60u * 60u * 1000u)
            fail("provider_invalid_options", true);
    }
    BackendFailure providerFailure() const override {
        BackendFailure result(failure_);
        result.indeterminate = result.indeterminate || (session_ && session_->indeterminate());
        return result;
    }
    bool providerReview(P::ReviewedTransaction *review) const override {
        if (review == nullptr || !reviewed_ || !session_ || !session_->active() ||
            !P::SameBinding(review_.binding, session_->binding()) || review_.binding.review.empty()) return false;
        *review = review_; return true;
    }
    void reset() override { (void) value<P::CacheReply>(P::Operation::Reset); }
    void createCacheViews() override { empty(P::Operation::CreateCacheViews); }
    std::vector<ErrorData> drainErrors() override {
        std::vector<ErrorData> remote;
        if (session_ && session_->active()) remote = value<std::vector<ErrorData>>(P::Operation::DrainErrors);
        remote.insert(remote.end(), errors_.begin(), errors_.end());
        redact(&remote);
        errors_.clear();
        return remote;
    }
    void discardErrors() override {
        if (empty(P::Operation::DiscardErrors)) { errors_.clear(); failure_ = BackendFailure(); }
    }
    bool loadSources() override { return value<bool>(P::Operation::LoadSources); }
    bool openCache() override { return value<P::CacheReply>(P::Operation::OpenCache).opened; }
    bool lockForTransaction() override { return value<bool>(P::Operation::LockForTransaction); }
    void unlockForTransaction() override {
        // This API is void, so a denied/invalid release must not strand an
        // active worker with the parent's lock. The coordinator's closed
        // callback reconciles any pending executor and releases owned locks.
        if (!empty(P::Operation::UnlockForTransaction)) fail(failure_.code, true);
    }
    std::vector<AutoInstalledDelta> autoInstalledDeltas() override { return value<std::vector<AutoInstalledDelta>>(P::Operation::AutoInstalledDeltas); }
    CacheStateSummary cacheState() override { return value<CacheStateSummary>(P::Operation::CacheState); }
    bool applyStatus() override { return value<bool>(P::Operation::ApplyStatus); }
    bool fixBroken() override { return value<bool>(P::Operation::FixBroken); }
    bool minimizeUpgrade() override { return value<bool>(P::Operation::MinimizeUpgrade); }
    bool cleanArchives() override { return value<bool>(P::Operation::CleanArchives); }
    bool prepareArchives() override { return value<bool>(P::Operation::PrepareArchives); }
    SourceListData sourceList() override { return value<SourceListData>(P::Operation::SourceList); }
    FetchResultData runFetcher(int pulseInterval) override {
        std::string payload;
        return interval(pulseInterval, &payload) ? value<FetchResultData>(P::Operation::RunFetcher, payload) : FetchResultData();
    }
    PackageManagerResult runPackageManager(int statusFd, FetchResultData *archiveValidation, bool *started) override {
        if (archiveValidation != nullptr) *archiveValidation = FetchResultData();
        if (started != nullptr) *started = false;
        P::Message reply; P::PackageManagerReply manager;
        if (!request(P::Operation::RunPackageManager, "", &reply, nullptr, statusFd) || !decode(reply, &manager)) {
            // An unacknowledged execution is never reported as safe to retry.
            if (started != nullptr) *started = requestExecutionStarted_ || (session_ && session_->indeterminate());
            return PackageManagerResult::Failed;
        }
        if (archiveValidation != nullptr) *archiveValidation = std::move(manager.archives);
        if (started != nullptr) *started = manager.started;
        return manager.result;
    }
    UpdateResultData updateLists(AcquireStatus &status, int pulseInterval) override {
        std::string payload; P::Message reply; UpdateResultData result;
        if (!interval(pulseInterval, &payload) || !request(P::Operation::UpdateLists, payload, &reply, &status) ||
            !decode(reply, &result)) return UpdateResultData();
        return result;
    }
    std::vector<PackageHandle> packageHandles() override { return value<std::vector<PackageHandle>>(P::Operation::PackageHandles); }
    PackageLookupResult lookupPackage(const std::string &name, const std::string &architecture) override {
        P::LookupRequest lookup; lookup.name = name; lookup.preferredArchitecture = architecture;
        return argument<PackageLookupResult>(P::Operation::LookupPackage, lookup);
    }
    PackageHandle packageHandle(const std::string &name, const std::string &architecture) override {
        P::LookupRequest lookup; lookup.name = name; lookup.preferredArchitecture = architecture;
        return argument<PackageHandle>(P::Operation::PackageHandle, lookup);
    }
    std::vector<PackageHandle> downgradeHandles(PackageHandle handle) override { return argument<std::vector<PackageHandle>>(P::Operation::DowngradeHandles, handle); }
    std::vector<PackageHandle> versionHandles(PackageHandle handle) override { return argument<std::vector<PackageHandle>>(P::Operation::VersionHandles, handle); }
    PackageSnapshot packageSnapshot(PackageHandle handle) override {
        PackageSnapshot snapshot(argument<PackageSnapshot>(P::Operation::PackageSnapshot, handle));
        if (snapshot.handle.valid() && snapshot.handle.value != handle.value) {
            fail("provider_package_handle_mismatch", true); return PackageSnapshot();
        }
        return snapshot;
    }
    PackageRecordData recordData(PackageHandle handle) override { return argument<PackageRecordData>(P::Operation::RecordData, handle); }
    PackageStateData packageState(PackageHandle handle) override { return argument<PackageStateData>(P::Operation::PackageState, handle); }
    std::vector<RelationData> relations(PackageHandle handle) override { return argument<std::vector<RelationData>>(P::Operation::Relations, handle); }
    TransactionData transactionData() override {
        reviewed_ = false;
        P::Message reply; P::ReviewedTransaction review;
        if (!request(P::Operation::TransactionData, "", &reply) || !decode(reply, &review)) return TransactionData();
        review_ = std::move(review); reviewed_ = true;
        return review_.transaction;
    }
    bool resolveDependencies() override { return value<bool>(P::Operation::ResolveDependencies); }
    void clearSelections() override { empty(P::Operation::ClearSelections); }
    bool prepareDistUpgrade() override { return value<bool>(P::Operation::PrepareDistUpgrade); }
    bool clearPackage(PackageHandle handle) override { return argument<bool>(P::Operation::ClearPackage, handle); }
    bool installPackage(PackageHandle handle) override { return argument<bool>(P::Operation::InstallPackage, handle); }
    bool reinstallPackage(PackageHandle handle) override { return argument<bool>(P::Operation::ReinstallPackage, handle); }
    bool removePackage(PackageHandle handle, bool purge) override {
        P::RemoveRequest removal; removal.handle = handle; removal.purge = purge;
        return argument<bool>(P::Operation::RemovePackage, removal);
    }
    std::vector<SourceHandle> sourceHandles() override { return value<std::vector<SourceHandle>>(P::Operation::SourceHandles); }
    SourceSnapshot sourceSnapshot(SourceHandle handle) override {
        SourceSnapshot snapshot(argument<SourceSnapshot>(P::Operation::SourceSnapshot, handle));
        if (snapshot.handle.valid() && snapshot.handle.value != handle.value) {
            fail("provider_source_handle_mismatch", true); return SourceSnapshot();
        }
        return snapshot;
    }
    std::string sourceField(SourceHandle handle, const std::string &name) override {
        P::SourceFieldRequest field; field.handle = handle; field.name = name;
        return argument<std::string>(P::Operation::SourceField, field);
    }
    std::vector<std::uint32_t> sourceFileIDs(SourceHandle handle) override { return argument<std::vector<std::uint32_t>>(P::Operation::SourceFileIDs, handle); }
    SourcePreflightResult sourcePreflight(const SourcePreflightRequest &input,
            const std::function<bool()> &cancelled) override {
        return sourceOperation<SourcePreflightResult>(P::Operation::SourcePreflight, input, cancelled);
    }
    SourceResourceResult sourceResource(const SourceResourceRequest &input,
            const std::function<bool()> &cancelled) override {
        return sourceOperation<SourceResourceResult>(P::Operation::SourceResource, input, cancelled);
    }
};
} // namespace Internal

AptBackend::AptBackend(std::unique_ptr<Provider::Session> session, const RemoteBackendOptions &options) :
    implementation_(new Internal::RemoteBackend(std::move(session), options)) {}
} // namespace CydiaAPT
