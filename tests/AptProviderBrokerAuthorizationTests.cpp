/* Actual parent broker with a fixture-only privileged transport. No helper,
 * dpkg, account service or network is launched.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderBroker.hpp"
#include "Cydia/AptProviderBrokerPrivileged.hpp"
#include "Cydia/PrivilegedClient.h"
#include "Cydia/AptProviderTransactionRequest.hpp"
#include <algorithm>
#include <cstdlib>
#include <iostream>
#include <unistd.h>
namespace {
namespace P = CydiaAPT::Provider;
using Status = CydiaRuntime::RepositoryArchiveAuthorizationStatus;
P::DpkgState state;
CydiaAPT::Recovery::Snapshot recoverySnapshot;
unsigned recoveryReads = 0, registeredReads = 0;
bool recoveryReadable = false;
std::shared_ptr<P::EffectReviewBundle> pairedCaptureReply;
unsigned pairedCaptures = 0, triggerCaptures = 0;
void Require(bool value, const char *why) { if (!value) { std::cerr << why << '\n'; std::abort(); } }
#if defined(CYDIA_TRANSACTION_BROKER_TESTING)
// This mock covers only the app broker's lifecycle. Real service/owner tests
// separately verify privileged registration, archives, locks and execution.
enum class CommitReply { Accepted, ExtraPayload, MissingStarted, Indeterminate, TransportLost, Rejected };
struct TransactionMock {
    bool enabled = false, rejectBegin = false, loseExecute = false;
    std::string beginError, baseline;
    unsigned starts = 0, legacyExecutions = 0, legacyCommits = 0, closes = 0;
    unsigned beginTimeout = 0;
    CommitReply commit = CommitReply::Accepted;
    P::TransactionBeginRequest begin;
    std::vector<std::pair<P::TransactionChannel::Operation, std::string>> frames;
} transactionMock;
void UpdateMockState(P::ExecutionAction action, const std::vector<std::uint64_t> &ids) {
    for (auto id : ids) {
        const auto found = std::find_if(transactionMock.begin.review.execution.actions.begin(),
            transactionMock.begin.review.execution.actions.end(), [id](const P::ReviewedAction &value) { return value.identifier == id; });
        Require(found != transactionMock.begin.review.execution.actions.end() && found->action == action, "mock receives exact retained action ID");
        P::DpkgPackageState package; package.package = found->package; package.selection = P::DpkgSelection::Install;
        package.multiArch = "no";
        package.status = action == P::ExecutionAction::Unpack ? P::DpkgPackageStatus::Unpacked : P::DpkgPackageStatus::Installed;
        state.packages[package.package.package + ':' + package.package.architecture] = package;
    }
    state.packageStateIdentity = "fixture-state:" + std::to_string(transactionMock.frames.size() + transactionMock.legacyExecutions);
}
#endif
}
namespace CydiaRuntime { namespace PrivilegedClient {
class ProviderTransaction::Implementation {};
ProviderTransaction::~ProviderTransaction() = default;
#if defined(CYDIA_TRANSACTION_BROKER_TESTING)
ProviderTransaction::ProviderTransaction(std::unique_ptr<Implementation> implementation) : implementation_(std::move(implementation)) {}
std::unique_ptr<ProviderTransaction> ProviderTransaction::Start(const std::string &helper, const Privileged::Request &request,
    const std::string &digest, std::string *error, unsigned timeout, const std::function<bool()> &, bool scopedChildren, bool conffilePolicy) {
    Require(conffilePolicy, "retained broker requests freshly bound native conffile policy");
    Require(transactionMock.enabled, "archive denial must precede persistent transaction admission");
    ++transactionMock.starts; std::vector<std::string> fields;
    transactionMock.beginTimeout = timeout;
    Require(helper == "/fixture/cydo" && P::Decode(request.payload, &fields) && fields.size() == 3 && fields[0] == "CYDIA-BROKER-1" &&
        P::DecodeTransactionBegin(fields[2], &transactionMock.begin) && P::TransactionBeginDigest(transactionMock.begin) == digest,
        "broker sends canonical exact Begin digest and retained review");
    Require(scopedChildren, "Begin explicitly negotiates policy-scoped children with or without finite triggers");
    Require(transactionMock.begin.extendedState == transactionMock.baseline, "Begin retains original extended-state baseline");
    if (transactionMock.rejectBegin) { if (error) *error = transactionMock.beginError; return {}; }
    return std::unique_ptr<ProviderTransaction>(new ProviderTransaction(std::unique_ptr<Implementation>(new Implementation)));
}
ProviderTransactionResult ProviderTransaction::Request(P::TransactionChannel::Operation operation, const std::string &payload, int status,
    const std::vector<std::string> &, const std::function<void()> &started, unsigned, const std::function<bool()> &) {
    Require(transactionMock.enabled, "archive denial must never send a transaction request");
    transactionMock.frames.emplace_back(operation, payload);
    ProviderTransactionResult result; result.transportValid = result.success = true;
    if (operation == P::TransactionChannel::Operation::Capture) {
        Require(payload.empty() && P::EncodeBrokerState(state, &result.payload), "mock Capture returns exact structured state");
    } else if (operation == P::TransactionChannel::Operation::Execute) {
        P::ParentExecutionRequest execution;
        Require(status == 8 && P::Decode(payload, &execution) && P::SameBinding(execution.binding, transactionMock.begin.review.binding),
            "owner receives native review and status descriptor");
        if (transactionMock.loseExecute) {
            result.transportValid = result.success = false; result.indeterminate = true;
            result.errorCode = "provider_transaction_closed"; return result;
        }
        result.started = true; if (started) started(); UpdateMockState(execution.action, execution.actions);
        P::TransactionExecutionReply settled; settled.result.started = true; settled.result.exitCode = 0; settled.state = state;
        Require(P::EncodeTransactionExecutionReply(settled, &result.payload), "mock owner encodes actual action's resulting state");
    } else if (operation == P::TransactionChannel::Operation::Commit) {
        std::vector<std::string> fields; Privileged::Error error; P::ExtendedStateRequest changes;
        std::string expected, proposed;
        Require(Privileged::ParseFields(payload, 2, &fields, &error) && fields[0] == transactionMock.baseline &&
            P::Decode(fields[1], &changes) && P::SameBinding(changes.binding, transactionMock.begin.review.binding) &&
            P::Encode(changes.changes, &proposed) && P::Encode(transactionMock.begin.changes, &expected) && proposed == expected,
            "Commit carries exact approved binding, baseline and deltas");
        result.started = transactionMock.commit != CommitReply::MissingStarted;
        if (result.started && started) started();
        if (transactionMock.commit == CommitReply::ExtraPayload) result.payload = "unexpected body";
        if (transactionMock.commit == CommitReply::Indeterminate) result.indeterminate = true;
        if (transactionMock.commit == CommitReply::TransportLost) {
            result.transportValid = result.success = false; result.indeterminate = true;
        }
        if (transactionMock.commit == CommitReply::Rejected) result.success = false;
    } else Require(false, "unexpected transaction request");
    return result;
}
bool ProviderTransaction::Close(std::string *, unsigned) { ++transactionMock.closes; return true; }
#else
std::unique_ptr<ProviderTransaction> ProviderTransaction::Start(const std::string &, const Privileged::Request &,
    const std::string &, std::string *, unsigned, const std::function<bool()> &, bool, bool) {
    Require(false, "archive denial must precede persistent transaction admission"); return {};
}
ProviderTransactionResult ProviderTransaction::Request(P::TransactionChannel::Operation, const std::string &, int,
    const std::vector<std::string> &, const std::function<void()> &, unsigned, const std::function<bool()> &) {
    Require(false, "archive denial must never send a transaction request"); return {};
}
bool ProviderTransaction::Close(std::string *, unsigned) { return true; }
#endif
bool Result::succeeded() const { return !launchError && !exitCode && !termSignal && !outputLimitExceeded; }
Result Run(const std::string &, const std::string &command, const Privileged::Request &, std::size_t, unsigned) {
    Result result{};
    if (command == "--cydia-provider-state" || command == "--cydia-provider-state-effects")
        Require(P::EncodeBrokerState(state, &result.output), "fixture state encoding");
    else if (command == "--cydia-provider-review-effects" && pairedCaptureReply) {
        ++triggerCaptures; Require(P::EncodeTriggerEffectEnvelope(pairedCaptureReply->triggers, &result.output), "mock legacy trigger capture");
    } else if (command == "--cydia-provider-extended-read") {
#if defined(CYDIA_TRANSACTION_BROKER_TESTING)
        if (transactionMock.enabled) result.output = transactionMock.baseline;
#endif
    }
#if defined(CYDIA_TRANSACTION_BROKER_TESTING)
    else if (command == "--cydia-provider-extended-commit" && transactionMock.enabled) ++transactionMock.legacyCommits;
#endif
    else result.exitCode = 1;
    return result;
}
int OpenProviderLock(const std::string &, const Privileged::Request &, Privileged::Error *, unsigned) {
    char name[] = "/tmp/cydia-grant-lock-XXXXXX";
    const int fd = mkstemp(name); if (fd >= 0) unlink(name); return fd;
}
bool CaptureProviderDeconfigurationReview(const std::string &helper, const Privileged::Request &request,
    const P::ReviewedTransaction &review, const std::string &methods, std::shared_ptr<const P::EffectReviewBundle> *out,
    Privileged::Error *, unsigned, const std::function<bool()> &) {
    ++pairedCaptures; std::vector<std::string> fields; P::EffectReviewCaptureRequest captured;
    std::string expected, sent;
    Require(helper == "/fixture/cydo" && out && P::Decode(request.payload, &fields) && fields.size() == 3 &&
        P::DecodeEffectReviewCaptureRequest(fields[2], &captured) && captured.methodsIdentity == methods &&
        P::Encode(review, &expected) && P::Encode(captured.review, &sent) && expected == sent,
        "fixture receives exact read-only paired review/method request");
    Require(pairedCaptureReply && P::EffectReviewBundleMatches(*pairedCaptureReply, review, methods), "mock pair matches exact frontend review");
    *out = pairedCaptureReply; return true;
}
DpkgExecutionResult RunProviderDpkg(const std::string &, const std::string &, const Privileged::Request &request, int, const std::string *, const std::vector<std::string> &) {
#if defined(CYDIA_TRANSACTION_BROKER_TESTING)
    Require(transactionMock.enabled && transactionMock.rejectBegin && transactionMock.beginError == "provider_native_configuration_missing",
        "legacy executor requires the exact pre-mutation missing-declaration refusal");
    std::vector<std::string> fields; P::BrokerDpkgRequest execution;
    Require(P::Decode(request.payload, &fields) && fields.size() == 3 && P::DecodeBrokerDpkg(fields[2], &execution), "decode legacy batch");
    ++transactionMock.legacyExecutions;
    UpdateMockState(execution.action, {execution.action == P::ExecutionAction::Unpack ? 1u : 2u});
    DpkgExecutionResult result; result.started = true; result.indeterminate = false;
    result.result = {Dpkg::ResultKind::Exited, 0, 0}; return result;
#else
    (void)request;
    Require(false, "authorization must never execute dpkg"); return {};
#endif
}
bool ReadProviderSnapshot(const std::string &, const std::string &, const P::RegistrationIdentity *,
    P::RegisteredProviderSnapshot *, Privileged::Error *, unsigned, const std::function<bool()> &) { ++registeredReads; return false; }
bool ReadRecoverySnapshot(const std::string &, const CydiaAPT::Recovery::Preferences &, const CydiaAPT::Recovery::Identity *,
    CydiaAPT::Recovery::Snapshot *snapshot, Privileged::Error *, unsigned, const std::function<bool()> &) {
    ++recoveryReads; if (!recoveryReadable) return false; *snapshot = recoverySnapshot; return true;
}
}}
namespace CydiaAPT { namespace Provider {
#if !defined(CYDIA_TRANSACTION_BROKER_TESTING)
std::string TransactionBeginDigest(const TransactionBeginRequest &) {
    Require(false, "archive denial must precede canonical transaction hashing"); return {};
}
#endif
}}
namespace {
struct Fixture {
    P::BrokerOptions options;
    P::ReviewedTransaction review;
    unsigned calls = 0;
    bool stopAfterGrant = false, cancelled = false;
    Fixture() {
        pairedCaptureReply.reset(); pairedCaptures = triggerCaptures = 0;
#if defined(CYDIA_TRANSACTION_BROKER_TESTING)
        transactionMock = TransactionMock();
#endif
        options.capabilities = P::AuthorizedArchiveGrants;
        options.helperPath = "/fixture/cydo"; options.extendedStatesPath = "/fixture/extended_states";
        auto &authority = options.authority;
        authority.registrationPath = "/fixture/provider.conf"; authority.providerIdentifier = "fixture";
        authority.configurationIdentity = "config"; authority.policyIdentity = "policy";
        authority.methodsIdentity = "methods"; authority.libraryIdentity = "library"; authority.frontendIdentity = "frontend";
        auto &environment = options.policy.environment;
        environment.paths.dpkg = "/fixture/dpkg"; environment.paths.dpkgQuery = "/fixture/dpkg-query";
        environment.paths.dpkgDeb = "/fixture/dpkg-deb"; environment.paths.dpkgRoot = "/";
        environment.paths.dpkgAdmin = "/fixture/db";
        environment.configurationIdentity = "config"; environment.policyIdentity = "policy"; environment.methodsIdentity = "methods";
        environment.packageStateIdentity = "state"; environment.nativeArchitecture = "amd64";
        environment.registeredArchitectures = environment.acquisitionArchitectures = {"amd64"};
        options.policy.layout = {"/", {"/var/jb"}};
        auto &binding = review.binding;
        binding.providerIdentifier = "fixture"; binding.session = std::string(64, 'a');
        binding.configurationIdentity = "config"; binding.policyIdentity = "policy";
        binding.packageStateIdentity = "state"; binding.cacheEpoch = 1; binding.selectionRevision = 2; binding.review = "review";
        review.transaction.registeredArchitectures = {"amd64"};
        const auto identity = CydiaAPT::BuildPackageIdentity("sample", "amd64", "all", "amd64", CydiaAPT::MultiArchMode::None);
        review.transaction.installs = {identity.routingName}; review.transaction.packages[identity.routingName] = {identity, "1", "sample"};
        P::ArchiveManifest archive; archive.identifier = "approved"; archive.package = {"sample", "1", "all"};
        archive.sourceURI = "https://repo.invalid/"; archive.sourceIndexIdentity = "SHA256:" + std::string(64, 'a');
        archive.sourceDefinitionPath = "/fixture/sources.list"; archive.sourceIndexPath = "/fixture/lists/Packages";
        archive.sourceIndexURI = "https://repo.invalid/Packages"; archive.filename = "pool/sample.deb";
        archive.recordSize = 512; archive.path = "/fixture/archives/sample.deb"; archive.size = 4096;
        archive.hashes = {{"SHA256", std::string(64, 'b')}}; archive.layout = options.policy.layout;
        review.execution.archives = {archive};
        P::ReviewedAction unpack; unpack.identifier = 1; unpack.action = P::ExecutionAction::Unpack; unpack.package = archive.package; unpack.archive = archive.identifier;
        P::ReviewedAction configure; configure.identifier = 2; configure.action = P::ExecutionAction::Configure; configure.package = archive.package;
        review.execution.actions = {unpack, configure};
        options.authorizeArchive = [this](const P::ArchiveManifest &approved, const P::RequestControl &control) {
            Require(approved.identifier == "approved" && approved.sourceURI == "https://repo.invalid/" &&
                approved.package.package == "sample" && approved.package.version == "1" && approved.package.architecture == "all",
                "callback receives parent-retained exact archive identity");
            Require(control.remainingMilliseconds && control.remainingMilliseconds() <= 60000 && control.cancelled,
                "native authorization callback receives explicit bounds");
            ++calls; P::ArchiveAuthorizationReply result; result.status = Status::Authorized;
            result.transportURL = "https://cdn.invalid/file?token=secret";
            result.message = "native diagnostic https://name:secret@cdn.invalid/private?token=secret";
            if (stopAfterGrant) cancelled = true;
            return result;
        };
        state = P::DpkgState(); state.packageStateIdentity = "state"; state.nativeArchitecture = "amd64"; state.registeredArchitectures = {"amd64"};
    }
    P::Message Request(P::Operation operation) const {
        P::Message request; request.kind = P::MessageKind::ParentRequest; request.sequence = 1;
        request.operation = operation; request.binding = review.binding;
        if (operation == P::Operation::AuthorizeArchive) {
            P::ArchiveAuthorizationRequest grant; grant.binding = request.binding; grant.archive = "approved";
            Require(P::Encode(grant, &request.payload), "fixture grant encoding");
        }
        return request;
    }
    void Ready(P::Broker &broker, bool approve = true) {
        Require(broker.BindSession(review.binding), "bind fixture session");
        P::Message reply; broker.HandleParentRequest(Request(P::Operation::AcquireFrontendLock), &reply, {});
        Require(reply.succeeded && broker.lockHeld(), "parent owns fixture lock");
        if (approve) Require(broker.Approve(review, {}), broker.errorCode().c_str());
    }
};
void AcceptedAndDenied() {
    for (unsigned variant = 0; variant != 9; ++variant) {
        Fixture fixture;
        if (variant == 1) fixture.options.capabilities = 0;
        P::Broker broker(fixture.options); fixture.Ready(broker, variant != 2);
        auto request = fixture.Request(P::Operation::AuthorizeArchive);
        P::RequestControl control;
        if (variant == 3) ++request.binding.selectionRevision;
        if (variant == 4) {
            P::ArchiveAuthorizationRequest grant; grant.binding = request.binding; grant.archive = "unreviewed";
            P::Encode(grant, &request.payload);
        }
        if (variant == 5) state.packageStateIdentity = "changed";
        if (variant == 6) control.cancelled = [] { return true; };
        if (variant == 7) control.remainingMilliseconds = [] { return 0u; };
        if (variant == 8) {
            fixture.stopAfterGrant = true;
            control.cancelled = [&] { return fixture.cancelled; };
        }
        P::Message reply; broker.HandleParentRequest(request, &reply, control);
        P::ArchiveAuthorizationReply result;
        if (variant == 0) {
            Require(reply.succeeded && P::Decode(reply.payload, &result) && result.status == Status::Authorized && fixture.calls == 1,
                "approved grant succeeds");
            Require(result.transportURL.find("secret") != std::string::npos && result.message.find("secret") == std::string::npos,
                "grant stays private transport while native diagnostics redact secrets");
            P::Message released; broker.HandleParentRequest(fixture.Request(P::Operation::ReleaseFrontendLock), &released, {});
            Require(released.succeeded && !broker.lockHeld(), "release fixture lock");
            broker.HandleParentRequest(request, &reply, {});
            Require(!reply.succeeded && fixture.calls == 1, "released lock cannot authorize downloads");
        } else if (variant >= 6) {
            Require(reply.succeeded && P::Decode(reply.payload, &result) && result.status == Status::Cancelled && result.transportURL.empty() &&
                fixture.calls == (variant == 8 ? 1u : 0u), "cancellation or deadline discards grant");
        } else Require(!reply.succeeded && fixture.calls == 0, "missing approval/capability, stale review, unknown archive or changed state rejected");
        Require(!broker.mutationStarted(), "account authorization does not start a package mutation");
    }
}
void RecoveryAuthorityRouting() {
    namespace R = CydiaAPT::Recovery;
    Fixture fixture; auto original = fixture.options.authority;
    fixture.options.authority = P::RegistrationIdentity();
    auto authority = std::make_shared<R::RequestAuthority>();
    authority->identity.configuration = std::string(64, 'a'); authority->identity.policy = std::string(64, 'b');
    authority->identity.methods = std::string(64, 'c'); authority->identity.libraries = std::string(64, 'd');
    authority->identity.frontend = std::string(64, 'e'); authority->identity.dependencies = std::string(64, 'f');
    fixture.options.recoveryAuthority = authority;
    auto &environment = fixture.options.policy.environment;
    environment.configurationIdentity = authority->identity.configuration; environment.policyIdentity = authority->identity.policy;
    environment.methodsIdentity = authority->identity.methods;
    fixture.review.binding.providerIdentifier = R::ProviderIdentifier();
    fixture.review.binding.configurationIdentity = environment.configurationIdentity; fixture.review.binding.policyIdentity = environment.policyIdentity;
    recoverySnapshot = R::Snapshot(); recoverySnapshot.identity = authority->identity;
    auto &d = recoverySnapshot.runtime; d.architecture = environment.nativeArchitecture;
    d.registeredArchitectures = environment.registeredArchitectures; d.acquisitionArchitectures = environment.acquisitionArchitectures;
    d.dpkgRootDirectory = environment.paths.dpkgRoot; d.dpkgAdminDirectory = environment.paths.dpkgAdmin;
    d.dpkgExecutablePath = environment.paths.dpkg; d.dpkgQueryExecutablePath = environment.paths.dpkgQuery; d.dpkgDebExecutablePath = environment.paths.dpkgDeb;
    recoverySnapshot.packageStateIdentity = std::string(64, '2'); recoveryReadable = true; recoveryReads = registeredReads = 0;
    P::Broker broker(fixture.options); Require(broker.BindSession(fixture.review.binding), "bind independently identified recovery session");
    P::Message reply; broker.HandleParentRequest(fixture.Request(P::Operation::CaptureStateSnapshot), &reply, {});
    P::Environment captured;
    Require(reply.succeeded && P::Decode(reply.payload, &captured) && captured.packageStateIdentity == recoverySnapshot.packageStateIdentity &&
        recoveryReads == 1 && registeredReads == 0, "recovery state uses protected recovery snapshot route only");
    d.dpkgExecutablePath = "/different/dpkg";
    broker.HandleParentRequest(fixture.Request(P::Operation::CaptureStateSnapshot), &reply, {});
    Require(!reply.succeeded && reply.errorCode == "provider_environment_changed", "recovery snapshot cannot silently change selected paths");
    fixture.options.authority = original; P::Broker confused(fixture.options);
    Require(!confused.BindSession(fixture.review.binding), "mixed external and recovery authority rejected");
    std::string bytes; std::vector<std::string> fields;
    Require(P::BrokerRequestPayload(*authority, "fixture payload", &bytes) && P::Decode(bytes, &fields) && fields.size() == 3 &&
        fields[0] == "CYDIA-RECOVERY-BROKER-1" && fields[2] == "fixture payload", "recovery broker wrapper is distinctly tagged");
    P::RegistrationIdentity wrong;
    Require(!P::ParseRegistrationIdentity(fields[1], &wrong), "recovery authority is not an external registration");
    recoveryReadable = false;
}
void ArchiveDecoderAuthorityRouting() {
    // Both sources have the same selected bootstrap dpkg. Recovery alone has
    // an independently captured private acquisition/inspection tool path.
    P::RegisteredProviderEnvironment external;
    external.executableSearchPath = "/fixture/bootstrap/bin:/usr/bin:/bin";
    external.runtime.dpkgExecutablePath = "/fixture/bootstrap/bin/dpkg";
    external.environment.dpkg = external.runtime.dpkgExecutablePath;
    CydiaAPT::Recovery::Authority recovery;
    recovery.runtime = external.runtime; recovery.environment = external.environment;
    recovery.executableSearchPath = external.executableSearchPath;
    recovery.acquisitionSearchPath = "/fixture/cydia/recovery-bin:" + recovery.executableSearchPath;
    const P::BrokerEnvironment externalBroker(external), recoveryBroker(recovery);
    Require(externalBroker.archiveDecoderSearchPath == external.executableSearchPath &&
        recoveryBroker.archiveDecoderSearchPath == recovery.acquisitionSearchPath &&
        externalBroker.executableSearchPath == recoveryBroker.executableSearchPath &&
        recoveryBroker.environment.dpkg == external.environment.dpkg,
        "private archive decoders do not replace native dpkg or its PATH");
    recovery.acquisitionSearchPath.clear();
    const P::BrokerEnvironment incomplete(recovery);
    Require(incomplete.archiveDecoderSearchPath.empty() && !incomplete.executableSearchPath.empty(),
        "missing recovery decoder authority cannot silently borrow the dpkg PATH");
    Require(recoveryBroker.archiveDecoderSearchPath == "/fixture/cydia/recovery-bin:" + external.executableSearchPath,
        "broker retains copied decoder authority rather than mutable source preferences");
    const P::BrokerEnvironment unresolved;
    Require(unresolved.archiveDecoderSearchPath.empty() && unresolved.executableSearchPath.empty(),
        "unresolved broker has no ambient executable or decoder search path");
}
void AllArchivesBeforeFirstMutation() {
    for (unsigned variant = 0; variant != 5; ++variant) {
        Fixture fixture;
        auto second = fixture.review.execution.archives.front();
        second.identifier = "later"; second.package.package = "later";
        second.path = "/fixture/archives/later.deb"; second.filename = "pool/later.deb";
        second.recordOffset = 512;
        fixture.review.execution.archives.push_back(second);
        const auto identity = CydiaAPT::BuildPackageIdentity("later", "amd64", "all", "amd64", CydiaAPT::MultiArchMode::None);
        fixture.review.transaction.installs.push_back(identity.routingName);
        fixture.review.transaction.packages[identity.routingName] = {identity, "1", "later"};
        P::ReviewedAction unpack; unpack.identifier = 3; unpack.action = P::ExecutionAction::Unpack;
        unpack.package = second.package; unpack.archive = second.identifier;
        P::ReviewedAction configure; configure.identifier = 4; configure.action = P::ExecutionAction::Configure;
        configure.package = second.package;
        fixture.review.execution.actions.push_back(unpack); fixture.review.execution.actions.push_back(configure);
        // APT may remove a conflicting installed package before either unpack.
        const auto old = CydiaAPT::BuildPackageIdentity("old", "amd64", "amd64", "amd64", CydiaAPT::MultiArchMode::None);
        fixture.review.transaction.removes.push_back(old.routingName);
        fixture.review.transaction.packages[old.routingName] = {old, "1", "old"};
        P::ReviewedAction remove; remove.identifier = 5; remove.action = P::ExecutionAction::Remove;
        remove.package = {"old", "1", "amd64"};
        fixture.review.execution.actions.insert(fixture.review.execution.actions.begin(), remove);
        P::DpkgPackageState installed; installed.package = remove.package;
        installed.selection = P::DpkgSelection::Install; installed.status = P::DpkgPackageStatus::Installed;
        state.packages.emplace("old:amd64", installed);
        unsigned checks = 0;
        fixture.options.archives = [&](const P::ReviewedTransaction &, const std::vector<P::ArchiveManifest> &archives,
                                      const P::RequestControl &) {
            ++checks;
            Require(archives.size() == 2 && archives[0].identifier == "approved" && archives[1].identifier == "later",
                "first removal must verify every later approved archive");
            P::BrokerArchiveEvidence proof;
            for (const auto &archive : archives) {
                P::VerifiedArchiveEvidence item; item.archive = archive; item.fileIdentity = "opened:" + archive.identifier;
                item.inspection.status = CydiaPackages::ArchivePolicyStatus::Accepted;
                item.inspection.identityVerified = item.inspection.complete = true;
                proof.archives.push_back(item);
            }
            if (variant == 0) proof.errorCode = "fixture_later_archive_unreadable";
            if (variant == 1) proof.archives.pop_back();
            if (variant == 2) proof.archives.back().archive.hashes["SHA256"][0] = 'c';
            if (variant == 3) proof.archives.back().inspection.complete = false;
            if (variant == 4) proof.archives.push_back(proof.archives.back());
            return proof;
        };
        P::Broker broker(fixture.options); fixture.Ready(broker); broker.SetStatusDescriptor(8);
        auto request = fixture.Request(P::Operation::ExecuteDpkg);
        P::ParentExecutionRequest execution; execution.binding = fixture.review.binding;
        execution.batch = 1; execution.action = P::ExecutionAction::Remove; execution.actions = {5};
        execution.arguments = {"--status-fd", "99", "--no-triggers", "--force-depends", "--abort-after=1", "--remove", "old:amd64"};
        Require(P::Encode(execution, &request.payload), "encode first removal");
        P::Message reply; broker.HandleParentRequest(request, &reply, {}); P::ParentExecutionReply denied;
        Require(reply.succeeded && P::Decode(reply.payload, &denied) && !denied.started && denied.launchError != 0 &&
            checks == 1 && !broker.mutationStarted(), "bad later archive denies the first mutation without launching dpkg");
    }
}
#if defined(CYDIA_TRANSACTION_BROKER_TESTING)
void EnableLifecycle(Fixture &fixture, unsigned *archiveChecks) {
    transactionMock.enabled = true;
    fixture.options.archives = [archiveChecks](const P::ReviewedTransaction &review,
        const std::vector<P::ArchiveManifest> &archives, const P::RequestControl &) {
        ++*archiveChecks; P::BrokerArchiveEvidence proof;
        Require(archives.size() == review.execution.archives.size(), "initial parent proof covers every archive before Begin");
        for (const auto &archive : archives) {
            P::VerifiedArchiveEvidence item; item.archive = archive; item.fileIdentity = "opened:" + archive.identifier;
            item.inspection.status = CydiaPackages::ArchivePolicyStatus::Accepted;
            item.inspection.identityVerified = item.inspection.complete = true;
            proof.archives.push_back(item);
        }
        return proof;
    };
}
void ReadyLifecycle(Fixture &fixture, P::Broker &broker) {
    fixture.Ready(broker, false);
    Require(broker.Approve(fixture.review, {{"sample", "amd64", true}}), "approve exact lifecycle review and auto delta");
    broker.SetStatusDescriptor(8);
}
P::ParentExecutionReply ExecuteLifecycle(Fixture &fixture, P::Broker &broker, std::uint64_t id, std::uint64_t batch,
    const P::RequestControl &control = {}) {
    const auto found = std::find_if(fixture.review.execution.actions.begin(), fixture.review.execution.actions.end(),
        [id](const P::ReviewedAction &action) { return action.identifier == id; });
    Require(found != fixture.review.execution.actions.end(), "fixture action exists");
    P::ParentExecutionRequest execution; execution.binding = fixture.review.binding; execution.batch = batch;
    execution.actions = {id}; execution.action = found->action;
    std::string operand = found->package.package + ':' + found->package.architecture;
    if (found->action == P::ExecutionAction::Unpack) {
        const auto archive = std::find_if(fixture.review.execution.archives.begin(), fixture.review.execution.archives.end(),
            [&](const P::ArchiveManifest &value) { return value.identifier == found->archive; });
        Require(archive != fixture.review.execution.archives.end(), "fixture archive exists"); operand = archive->path;
    }
    execution.arguments = {"--status-fd=99", "--no-triggers", found->action == P::ExecutionAction::Unpack ? "--unpack" : "--configure", operand};
    auto request = fixture.Request(P::Operation::ExecuteDpkg); P::Message reply;
    Require(P::Encode(execution, &request.payload), "encode broker lifecycle child");
    broker.HandleParentRequest(request, &reply, control); P::ParentExecutionReply result;
    Require(reply.succeeded && P::Decode(reply.payload, &result), "broker returns typed execution result"); return result;
}
bool CommitLifecycle(Fixture &fixture, P::Broker &broker, unsigned malformed = 0) {
    P::ExtendedStateRequest commit; commit.binding = fixture.review.binding; commit.changes = {{"sample", "amd64", true}};
    if (malformed == 2) commit.changes[0].automatic = false;
    if (malformed == 3) ++commit.binding.selectionRevision;
    auto request = fixture.Request(P::Operation::CommitExtendedState); P::Message reply;
    Require(P::Encode(commit, &request.payload), "encode broker lifecycle Commit");
    if (malformed == 1) request.payload += "0:,";
    broker.HandleParentRequest(request, &reply, {}); return reply.succeeded;
}
void SuccessfulChildren(Fixture &fixture, P::Broker &broker) {
    for (std::uint64_t batch = 1; batch != 3; ++batch) {
        const auto result = ExecuteLifecycle(fixture, broker, batch, batch);
        Require(result.started && !result.exitCode && !result.signal && !result.launchError, "exact two-action transaction succeeds");
    }
}
void BeginFailuresNeverDowngrade() {
    for (unsigned variant = 0; variant != 5; ++variant) {
        Fixture fixture; unsigned checks = 0; EnableLifecycle(fixture, &checks);
        transactionMock.rejectBegin = true;
        transactionMock.beginError = variant == 1 ? "provider_native_configuration_invalid" :
            variant == 2 ? "provider_transaction_timeout" : variant == 3 ? "provider_authority_changed" : "";
        // This fits the read transport but not the canonical Begin's bounded
        // baseline. Failed local encoding must also permanently deny admission.
        if (!variant) transactionMock.baseline.assign(4 * 1024 * 1024 + 1, 'x');
        P::Broker broker(fixture.options); ReadyLifecycle(fixture, broker);
        for (unsigned retry = 0; retry != 2; ++retry) {
            const auto result = ExecuteLifecycle(fixture, broker, 1, 1);
            Require(!result.started && result.launchError && !broker.mutationStarted() && !broker.complete(),
                "invalid or refused Begin cannot become a later legacy child");
        }
        Require(transactionMock.starts == (variant ? 1u : 0u) && transactionMock.frames.empty() &&
            !transactionMock.legacyExecutions && !transactionMock.legacyCommits, "failed admission is attempted at most once without fallback");
    }
}
void MissingDeclarationKeepsLegacy() {
    Fixture fixture; unsigned checks = 0; EnableLifecycle(fixture, &checks);
    transactionMock.rejectBegin = true; transactionMock.beginError = "provider_native_configuration_missing";
    P::Broker broker(fixture.options); ReadyLifecycle(fixture, broker); SuccessfulChildren(fixture, broker);
    Require(CommitLifecycle(fixture, broker) && broker.complete() && broker.mutationStarted() && !broker.indeterminate(),
        "only missing native declaration preserves established restricted execution");
    Require(transactionMock.starts == 1 && transactionMock.legacyExecutions == 2 && transactionMock.legacyCommits == 1 &&
        transactionMock.frames.empty() && checks == 1, "legacy selected once before mutation, never a retained-owner retry");
}
void RetainedOwnerIgnoresOriginalArchives() {
    Fixture fixture; unsigned checks = 0; EnableLifecycle(fixture, &checks);
    auto archive = fixture.review.execution.archives.front(); archive.identifier = "later";
    archive.package.package = "later"; archive.path = "/fixture/archives/later.deb"; archive.filename = "pool/later.deb";
    fixture.review.execution.archives.push_back(archive);
    const auto identity = CydiaAPT::BuildPackageIdentity("later", "amd64", "all", "amd64", CydiaAPT::MultiArchMode::None);
    fixture.review.transaction.installs.push_back(identity.routingName);
    fixture.review.transaction.packages[identity.routingName] = {identity, "1", "later"};
    auto unpack = fixture.review.execution.actions.front(); unpack.identifier = 3; unpack.package = archive.package; unpack.archive = archive.identifier;
    auto configure = fixture.review.execution.actions.back(); configure.identifier = 4; configure.package = archive.package;
    fixture.review.execution.actions.push_back(unpack); fixture.review.execution.actions.push_back(configure);
    const auto initialProof = fixture.options.archives;
    fixture.options.archives = [&](const P::ReviewedTransaction &review, const std::vector<P::ArchiveManifest> &archives, const P::RequestControl &control) {
        Require(checks == 0, "active owner must not reopen original archive paths after retaining all copies");
        return initialProof(review, archives, control);
    };
    P::Broker broker(fixture.options); ReadyLifecycle(fixture, broker);
    for (std::uint64_t id = 1; id != 5; ++id) {
        const auto result = ExecuteLifecycle(fixture, broker, id, id);
        Require(result.started && !result.exitCode && !result.launchError, "retained owner settles each exact package action");
    }
    Require(CommitLifecycle(fixture, broker) && broker.complete() && checks == 1 && transactionMock.starts == 1 &&
        !transactionMock.legacyExecutions, "retained owner alone executes later unpacks");
    Require(transactionMock.frames.size() == 8 && transactionMock.frames.back().first == P::TransactionChannel::Operation::Commit,
        "recorded owner frames contain four executes, three captures and one commit");
}
void CompletionAndUncertaintySurviveCleanup() {
    for (bool lost : {false, true}) {
        Fixture fixture; unsigned checks = 0; EnableLifecycle(fixture, &checks); transactionMock.loseExecute = lost;
        P::Broker broker(fixture.options); ReadyLifecycle(fixture, broker);
        if (lost) {
            const auto result = ExecuteLifecycle(fixture, broker, 1, 1);
            Require(result.started && result.exitCode && broker.indeterminate() && !broker.complete(),
                "lost helper transport makes dispatched child indeterminate even without Started reply");
        } else {
            SuccessfulChildren(fixture, broker);
            Require(CommitLifecycle(fixture, broker) && broker.complete() && !broker.indeterminate(), "only acknowledged Commit completes transaction");
        }
        broker.Invalidate();
        Require(broker.complete() == !lost && broker.indeterminate() == lost && broker.mutationStarted() && !broker.lockHeld(),
            "worker cleanup retains acknowledged completion or unsettled mutation history");
        const unsigned previousStarts = transactionMock.starts;
        const bool approved = broker.Approve(fixture.review, {{"sample", "amd64", true}});
        if (lost) Require(!approved && broker.indeterminate() && broker.mutationStarted() && !broker.complete(),
            "new review cannot erase unknown execution outcome");
        else Require(approved && !broker.complete() && !broker.mutationStarted() && !broker.indeterminate(),
            "explicit new review clears prior determinate completion");
        Require(transactionMock.starts == previousStarts && !transactionMock.legacyExecutions, "cleanup and new approval cannot silently relaunch");
    }
}
void CommitCannotInventCompletion() {
    for (unsigned malformed = 1; malformed != 4; ++malformed) {
        Fixture fixture; unsigned checks = 0; EnableLifecycle(fixture, &checks);
        P::Broker broker(fixture.options); ReadyLifecycle(fixture, broker); SuccessfulChildren(fixture, broker);
        const auto count = transactionMock.frames.size();
        Require(!CommitLifecycle(fixture, broker, malformed) && !broker.complete() && transactionMock.frames.size() == count,
            "malformed, unapproved delta or stale-binding Commit never reaches helper");
    }
    for (auto invalid : {CommitReply::ExtraPayload, CommitReply::MissingStarted, CommitReply::Indeterminate,
                        CommitReply::TransportLost, CommitReply::Rejected}) {
        Fixture fixture; unsigned checks = 0; EnableLifecycle(fixture, &checks); transactionMock.commit = invalid;
        P::Broker broker(fixture.options); ReadyLifecycle(fixture, broker); SuccessfulChildren(fixture, broker);
        Require(!CommitLifecycle(fixture, broker) && !broker.complete(), "malformed or unsettled Commit reply cannot report completion");
        const bool uncertain = invalid != CommitReply::MissingStarted;
        Require(broker.indeterminate() == uncertain, "commit history distinguishes verified no-start from started unresolved work");
        broker.Invalidate(); Require(!broker.complete() && broker.indeterminate() == uncertain, "cleanup preserves Commit uncertainty");
    }
}
void FiniteReviewCannotDowngrade() {
    Fixture fixture; unsigned checks = 0; EnableLifecycle(fixture, &checks);
    fixture.options.finiteTriggerEffects = true; fixture.options.capabilities |= P::FiniteTriggerEffects;
    transactionMock.rejectBegin = true; transactionMock.beginError = "provider_native_configuration_missing";
    auto effects = std::make_shared<P::TriggerEffectEnvelope>(); effects->identity.assign(64, 'a');
    effects->initialCheckpoint.assign(64, 'b'); effects->nativeAuthorityIdentity.assign(64, 'c');
    effects->primaryReview = fixture.review; effects->recipients = {{"sample:all@1", {"sample", "1", "all"}}};
    effects->awaiters = effects->recipients; effects->incoming = {"sample:all@1"};
    P::Broker broker(fixture.options); fixture.Ready(broker, false);
    Require(!broker.Approve(fixture.review, {{"sample", "amd64", true}}), "finite session cannot approve a legacy review");
    Require(broker.Approve(fixture.review, {{"sample", "amd64", true}}, {}, {}, effects), "native immutable finite review approved");
    broker.SetStatusDescriptor(8);
    const auto denied = ExecuteLifecycle(fixture, broker, 1, 1);
    Require(!denied.started && denied.launchError && transactionMock.starts == 1 && !transactionMock.legacyExecutions &&
        !broker.mutationStarted(), "missing declaration cannot downgrade finite approval or start a legacy child");
}
void PairedCaptureAndImmutableApproval() {
    // A fixture-only routing selector is not native readiness proof. Every
    // paired case either refuses approval or mocks a pre-mutation Begin denial.
    for (unsigned mode = 0; mode != 10; ++mode) {
        Fixture fixture; unsigned checks = 0; EnableLifecycle(fixture, &checks);
        fixture.options.finiteTriggerEffects = true; fixture.options.capabilities |= P::FiniteTriggerEffects;
        bool ready = true;
        if (mode != 6) fixture.options.deconfigurationReadiness = [&](const P::ReviewedTransaction &, std::string *) { return ready; };
        pairedCaptureReply = std::make_shared<P::EffectReviewBundle>(); pairedCaptureReply->methodsIdentity = "methods";
        auto &pool(pairedCaptureReply->deconfiguration); pool.identity.assign(64, 'a'); pool.initialCheckpoint.assign(64, 'b');
        pool.nativeAuthorityIdentity.assign(64, 'c'); pool.primaryReview = fixture.review;
        auto &triggers(pairedCaptureReply->triggers); triggers.identity.assign(64, 'd'); triggers.initialCheckpoint = pool.initialCheckpoint;
        triggers.nativeAuthorityIdentity = pool.nativeAuthorityIdentity; triggers.primaryReview = fixture.review;
        triggers.recipients = {{"sample:all@1", {"sample", "1", "all"}}}; triggers.awaiters = triggers.recipients; triggers.incoming.insert("sample:all@1");
        P::Broker broker(fixture.options); fixture.Ready(broker, false);
        std::shared_ptr<const P::TriggerEffectEnvelope> effects; std::shared_ptr<const P::EffectReviewBundle> pair; std::string error;
        Require(broker.CaptureEffects(fixture.review, &effects, &error, &pair), "read-only capture selects its immutable mode");
        if (mode == 6) {
            Require(!pair && effects && pairedCaptures == 0 && triggerCaptures == 1,
                "missing readiness selector preserves the existing ordinary finite-trigger capture");
            Require(broker.Approve(fixture.review, { {"sample", "amd64", true} }, {}, {}, effects), "ordinary review is unchanged");
            continue;
        }
        Require(pair && effects.get() == &pair->triggers && pairedCaptures == 1 && triggerCaptures == 0,
            "trigger and conditional approval come from one exact shared capture object");
        if (mode == 1) pair = std::make_shared<const P::EffectReviewBundle>(*pair);
        if (mode == 2) effects = std::make_shared<const P::TriggerEffectEnvelope>(*effects);
        if (mode == 3) pair.reset();
        if (mode == 4) pairedCaptureReply->deconfiguration.identity.assign(64, 'e');
        if (mode == 5) ready = false;
        const bool approved(broker.Approve(fixture.review, { {"sample", "amd64", true} }, {}, {}, effects, pair));
        if (mode >= 1 && mode <= 5) {
            Require(!approved && transactionMock.starts == 0 && !broker.mutationStarted(),
                "copying, dropping, changing or invalidating the displayed pair cannot approve a new review");
            continue;
        }
        Require(approved, "unchanged exact paired review can be retained after explicit confirmation");
        broker.SetStatusDescriptor(8); transactionMock.rejectBegin = true; transactionMock.beginError = "provider_native_configuration_missing";
        if (mode == 7) pairedCaptureReply->deconfiguration.identity.assign(64, 'f');
        if (mode == 8) ready = false;
        P::RequestControl control; if (mode == 9) control.remainingMilliseconds = [] { return 1000u; };
        const auto result(ExecuteLifecycle(fixture, broker, 1, 1, control));
        Require(!result.started && result.launchError && !transactionMock.legacyExecutions && !broker.mutationStarted(),
            "paired Begin cannot fall through to legacy mutation after any denial");
        if (mode == 0) Require(transactionMock.starts == 1 && transactionMock.begin.reviewedDeconfiguration &&
            transactionMock.beginTimeout >= P::MinimumEffectReviewCaptureMilliseconds,
            "retained Begin carries exact pair and sufficient locked-recapture time");
        else Require(transactionMock.starts == 0, "post-confirmation changes or insufficient deadline refuse before dispatch");
    }
}
#endif
}
void CanonicalBeginApproval() {
    Fixture fixture; P::TransactionBeginRequest original, decoded; original.review = fixture.review;
    original.additionalActions = {1, 2}; original.archiveWarnings = {"approved"};
    original.changes = {{"sample", "amd64", true}}; original.extendedState = "baseline\n";
    std::string bytes;
    Require(P::EncodeTransactionBegin(original, &bytes) && P::DecodeTransactionBegin(bytes, &decoded) &&
        !decoded.reviewedEffects && decoded.extendedState == original.extendedState, "valid bound Begin encodes and roundtrips");
    Require(!P::DecodeTransactionBegin(bytes + "x", &decoded), "Begin rejects trailing data");
    auto effects = std::make_shared<P::TriggerEffectEnvelope>(); effects->identity.assign(64, 'a');
    effects->initialCheckpoint.assign(64, 'b'); effects->primaryReview = fixture.review;
    effects->nativeAuthorityIdentity.assign(64, 'c');
    effects->recipients = {{"sample:all@1", {"sample", "1", "all"}}}; effects->awaiters = effects->recipients;
    effects->incoming = {"sample:all@1"}; original.reviewedEffects = effects;
    Require(P::EncodeTransactionBegin(original, &bytes) && P::DecodeTransactionBegin(bytes, &decoded) &&
        decoded.reviewedEffects && decoded.reviewedEffects->identity == effects->identity &&
        decoded.reviewedEffects->recipients.size() == 1, "finite immutable approval roundtrips with primary review");
    const P::ExecutionPackage epoch{"cache", "2:1.0~rc1+vendor-3", "amd64"};
    effects->recipients["cache:amd64@2:1.0~rc1+vendor-3"] = epoch;
    effects->awaiters = effects->recipients;
    Require(P::EncodeTransactionBegin(original, &bytes) && P::DecodeTransactionBegin(bytes, &decoded),
        "native approval preserves Debian epoch, prerelease and revision version syntax");
    effects->primaryReview.binding.review = "another-review";
    Require(!P::EncodeTransactionBegin(original, &bytes), "effect approval cannot bind a different primary review");
    effects->primaryReview = fixture.review; effects->recipients.begin()->second.version = "2";
    Require(!P::EncodeTransactionBegin(original, &bytes), "generation key cannot conceal different version");
}
int main() {
    CanonicalBeginApproval();
    AcceptedAndDenied(); RecoveryAuthorityRouting(); ArchiveDecoderAuthorityRouting(); AllArchivesBeforeFirstMutation();
#if defined(CYDIA_TRANSACTION_BROKER_TESTING)
    BeginFailuresNeverDowngrade(); MissingDeclarationKeepsLegacy(); RetainedOwnerIgnoresOriginalArchives();
    CompletionAndUncertaintySurviveCleanup(); CommitCannotInventCompletion();
    FiniteReviewCannotDowngrade();
    PairedCaptureAndImmutableApproval();
#endif
    std::cout << "[apt-provider-broker-authorization] PASS\n";
}
