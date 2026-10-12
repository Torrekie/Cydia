/* Actual parent broker with a fixture-only privileged transport. No helper,
 * dpkg, account service or network is launched.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderBroker.hpp"
#include "Cydia/AptProviderBrokerPrivileged.hpp"
#include "Cydia/PrivilegedClient.h"
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
void Require(bool value, const char *why) { if (!value) { std::cerr << why << '\n'; std::abort(); } }
}
namespace CydiaRuntime { namespace PrivilegedClient {
bool Result::succeeded() const { return !launchError && !exitCode && !termSignal && !outputLimitExceeded; }
Result Run(const std::string &, const std::string &command, const Privileged::Request &, std::size_t, unsigned) {
    Result result{};
    if (command == "--cydia-provider-state") Require(P::EncodeBrokerState(state, &result.output), "fixture state encoding");
    else if (command != "--cydia-provider-extended-read") result.exitCode = 1;
    return result;
}
int OpenProviderLock(const std::string &, const Privileged::Request &, Privileged::Error *, unsigned) {
    char name[] = "/tmp/cydia-grant-lock-XXXXXX";
    const int fd = mkstemp(name); if (fd >= 0) unlink(name); return fd;
}
DpkgExecutionResult RunProviderDpkg(const std::string &, const std::string &, const Privileged::Request &, int, const std::string *, const std::vector<std::string> &) {
    Require(false, "authorization must never execute dpkg"); return {};
}
bool ReadProviderSnapshot(const std::string &, const std::string &, const P::RegistrationIdentity *,
    P::RegisteredProviderSnapshot *, Privileged::Error *, unsigned, const std::function<bool()> &) { ++registeredReads; return false; }
bool ReadRecoverySnapshot(const std::string &, const CydiaAPT::Recovery::Preferences &, const CydiaAPT::Recovery::Identity *,
    CydiaAPT::Recovery::Snapshot *snapshot, Privileged::Error *, unsigned, const std::function<bool()> &) {
    ++recoveryReads; if (!recoveryReadable) return false; *snapshot = recoverySnapshot; return true;
}
}}
namespace {
struct Fixture {
    P::BrokerOptions options;
    P::ReviewedTransaction review;
    unsigned calls = 0;
    bool stopAfterGrant = false, cancelled = false;
    Fixture() {
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
}
int main() { AcceptedAndDenied(); RecoveryAuthorityRouting(); ArchiveDecoderAuthorityRouting(); AllArchivesBeforeFirstMutation(); std::cout << "[apt-provider-broker-authorization] PASS\n"; }
