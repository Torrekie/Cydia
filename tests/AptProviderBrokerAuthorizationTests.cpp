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
DpkgExecutionResult RunProviderDpkg(const std::string &, const std::string &, const Privileged::Request &, int, const std::string *) {
    Require(false, "authorization must never execute dpkg"); return {};
}
bool ReadProviderSnapshot(const std::string &, const std::string &, const P::RegistrationIdentity *,
    P::RegisteredProviderSnapshot *, Privileged::Error *, unsigned, const std::function<bool()> &) { return false; }
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
}
int main() { AcceptedAndDenied(); std::cout << "[apt-provider-broker-authorization] PASS\n"; }
