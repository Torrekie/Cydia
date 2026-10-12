/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderProtocol.hpp"
#include <cstdlib>
#include <iostream>

namespace {
using namespace CydiaAPT;
namespace P = CydiaAPT::Provider;
void Require(bool value, const char *message) {
    if (value) return;
    std::cerr << "[apt-provider][FAIL] " << message << '\n'; std::exit(1);
}
template<class T> T RoundTrip(const T &value) {
    std::string bytes;
    Require(P::Encode(value, &bytes), "encode value");
    T decoded;
    Require(P::Decode(bytes, &decoded), "decode value");
    std::string repeated;
    Require(P::Encode(decoded, &repeated) && bytes == repeated, "value was not losslessly preserved");
    return decoded;
}
P::Environment Environment() {
    P::Environment value;
    value.paths.dpkg = "/distribution/bin/dpkg";
    value.paths.dpkgQuery = "/distribution/bin/dpkg-query";
    value.paths.dpkgDeb = "/distribution/bin/dpkg-deb";
    value.paths.dpkgAdmin = "/distribution/state/dpkg";
    value.paths.dpkgRoot = "/distribution";
    value.paths.sourceList = "/distribution/etc/apt/sources.list";
    value.paths.sourceParts = "/distribution/etc/apt/sources.list.d";
    value.configurationIdentity = "configuration-v1";
    value.policyIdentity = "distribution-policy-v1";
    value.methodsIdentity = "methods-v1";
    value.packageStateIdentity = "state-v1";
    value.nativeArchitecture = "native";
    value.registeredArchitectures = {"native", "foreign"};
    value.acquisitionArchitectures = {"native", "foreign"};
    return value;
}
void PackageValues() {
    PackageSnapshot package;
    package.handle = PackageHandle(17);
    package.registeredArchitectures = {"native", "foreign"};
    package.identity = BuildPackageIdentity("example", "foreign", "foreign", "native", MultiArchMode::Same);
    package.installedIdentity = package.identity;
    package.record.fields = {{"Architecture", "foreign"}, {"Multi-Arch", "same"}, {"Depends", "runtime:any"}};
    package.record.tags = {"role::enduser", "cydia::commercial"};
    package.record.displayName = "Example";
    package.record.maintainer = "Maintainer";
    package.record.shortDescription = "Résumé";
    package.record.longDescription = "Description\nwith a continuation";
    package.record.raw = "Package: example\nArchitecture: foreign\n";
    package.state.state = "installed"; package.state.selection = "hold";
    package.state.mode = "upgrade"; package.state.hasCurrent = true;
    package.state.ignored = true; package.state.architectureSupported = true;
    package.state.versionPriority = -32768; package.state.versionComparison = -1;
    package.identifier = "example:foreign"; package.version = "2:1.2-3";
    package.installedVersion = "2:1.1-1"; package.section = "Utilities";
    package.architecture = "foreign"; package.installedSize = 1ull << 40;
    package.sourceFileID = 42; package.hasSourceFile = true; package.defaultPriority = false;
    const auto result = RoundTrip(package);
    Require(result.identity.dpkgName == "example:foreign" && result.state.versionPriority == -32768 &&
            result.installedSize == (1ull << 40) && result.record.Field("architecture") == "foreign",
            "wire changed foreign identity, signed values, large sizes or record fields");
    TransactionData transaction;
    transaction.registeredArchitectures = package.registeredArchitectures;
    transaction.upgrades = {"example:foreign"}; transaction.downloading = 1ull << 40;
    transaction.packages["example:foreign"] = {package.identity, package.version, package.record.displayName};
    TransactionClauseData clause;
    clause.package = "runtime:any"; clause.comparison = ">="; clause.version = "1";
    clause.providers = {PackageHandle(19), PackageHandle(23)}; clause.reason = "unavailable";
    TransactionReasonData reason; reason.relationship = "Depends"; reason.clauses = {clause};
    TransactionIssueData issue; issue.package = package.identifier; issue.kind = "broken"; issue.reasons = {reason};
    transaction.issues = {issue};
    const auto plan = RoundTrip(transaction);
    Require(plan.issues.front().reasons.front().clauses.front().providers[1].value == 23 &&
            plan.packages.at("example:foreign").identity.versionArchitecture == "foreign",
            "nested dependency targets or transaction identity changed");
    SourcePreflightResult preflight;
    preflight.status = SourceCheckStatus::Complete; preflight.allowed = true;
    preflight.architecture = SourceArchitectureAvailability::Supported;
    SourceMetadata source;
    source.uri = "https://repo.invalid/"; source.suitePath = "suite";
    source.metadataBaseURI = source.uri + "dists/suite/";
    source.architectures = {"foreign"}; source.components = {"main"};
    source.metadata = std::string("Release\0bytes", 13);
    source.detachedSignature = std::string("\0\xff\x01", 3);
    preflight.repositories = {source};
    FetchFailureData warning; warning.kind = FetchDiagnosticKind::RepositoryTrustDowngrade;
    warning.uri = source.uri; warning.error = "Localized upstream diagnostic";
    preflight.warnings = {warning}; preflight.errors = {{"Upstream text", true}};
    const auto checked = RoundTrip(preflight);
    Require(checked.repositories.front().detachedSignature == source.detachedSignature &&
            checked.warnings.front().kind == FetchDiagnosticKind::RepositoryTrustDowngrade,
            "raw signature bytes or typed authentication diagnostics changed");
    Require(checked.errors.front().message == "Upstream text" && checked.errors.front().cydiaCode.empty(),
            "upstream diagnostic acquired a Cydia identity");
    const auto local = RoundTrip(ErrorData{"", false, "provider_cancelled"});
    Require(local.message.empty() && local.cydiaCode == "provider_cancelled" && !local.warning,
            "Cydia-owned diagnostic identity was lost or converted to upstream text");
    InitializationOptions options;
    options.architecture = "native"; options.aptConfigDirectory = "/distribution/etc/apt";
    options.repositorySecurityMode = RepositorySecurityMode::Distribution;
    Require(RoundTrip(options).repositorySecurityMode == RepositorySecurityMode::Distribution,
            "initialization lost distribution inheritance");
    P::ProgressEvent progress;
    progress.sourceActivity = P::SourceActivity::Started;
    progress.sourceURI = "https://repo.invalid/dists/stable/Release";
    progress.current = 12; progress.total = 37; progress.cancellable = true;
    const auto activity(RoundTrip(progress));
    Require(activity.sourceURI == progress.sourceURI && activity.sourceActivity == P::SourceActivity::Started &&
            activity.current == 12 && P::ValidProgressEvent(activity), "source activity identity was lost");
    progress.sourceActivity = P::SourceActivity::None;
    Require(!P::ValidProgressEvent(progress), "activity-free source identity accepted");
    progress.sourceActivity = P::SourceActivity::Finished; progress.sourceURI += '\n';
    Require(!P::ValidProgressEvent(progress), "control byte accepted in activity URI");
}
void RejectionAndBinding() {
    ErrorData before = {"unchanged", true, "unchanged_code"}; std::string encoded;
    Require(P::Encode(before, &encoded), "encode diagnostic");
    for (std::size_t i = 0; i < encoded.size(); ++i) {
        ErrorData target = before;
        Require(!P::Decode(encoded.substr(0, i), &target) && target.message == "unchanged" && target.warning &&
                target.cydiaCode == "unchanged_code",
                "truncated payload changed its output");
    }
    encoded.back() = 2;
    Require(!P::Decode(encoded, &before), "noncanonical bool accepted");
    P::Operation operation = P::Operation::Hello;
    Require(!P::Decode(std::string(4, '\xff'), &operation), "unknown operation accepted");
    std::vector<PackageHandle> handles;
    Require(!P::Decode(std::string(4, '\xff'), &handles), "unbounded collection accepted");
    P::Writer duplicate;
    Require(duplicate.integer(2, 4) && duplicate(std::string("same"), std::string("a"),
        std::string("same"), std::string("b")), "encode duplicate fixture");
    std::map<std::string, std::string> fields;
    Require(!P::Decode(duplicate.result(), &fields), "duplicate field accepted");
    P::Message request; request.sequence = 7; request.operation = P::Operation::RunPackageManager;
    request.binding.providerIdentifier = "provider-v1";
    request.binding.session = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    request.binding.configurationIdentity = "config"; request.binding.policyIdentity = "policy";
    request.binding.packageStateIdentity = "state"; request.binding.review = "reviewed-plan";
    request.binding.cacheEpoch = 4; request.binding.selectionRevision = 2;
    P::Message response(request); response.kind = P::MessageKind::Response; response.succeeded = true;
    Require(P::ValidateReply(request, response), "matching reply rejected");
    auto unreviewed = request; unreviewed.binding.review.clear();
    Require(!P::ValidRequestBinding(unreviewed), "transaction can run without a review binding");
    auto wrongDirection = request; wrongDirection.operation = P::Operation::ExecuteDpkg;
    Require(!P::ValidRequestBinding(wrongDirection), "worker execution request can bypass parent delegation");
    wrongDirection.kind = P::MessageKind::ParentRequest;
    Require(P::ValidRequestBinding(wrongDirection), "reviewed parent execution request refused");
    for (const auto op : {P::Operation::PackageSnapshot, P::Operation::SourceSnapshot,
                         P::Operation::InstallPackage, P::Operation::TransactionData,
                         P::Operation::LockForTransaction}) {
        auto unbound = request; unbound.operation = op; unbound.binding.cacheEpoch = 0;
        Require(!P::ValidRequestBinding(unbound), "cache-dependent request accepted an uninitialized epoch");
    }
    auto beforeCache = request; beforeCache.operation = P::Operation::Reset; beforeCache.binding.cacheEpoch = 0;
    Require(P::ValidRequestBinding(beforeCache), "initial reset could not establish an epoch");
    for (const std::string &bad : {std::string("policy\0hidden", 13), std::string("policy\nline"),
                                 std::string("policy token"), std::string(513, 'a')}) {
        auto malformed = request; malformed.binding.policyIdentity = bad;
        Require(!P::ValidRequestBinding(malformed), "invalid identity token accepted");
    }
    Require(!P::ValidChallenge("") && !P::ValidChallenge("replayed-short-token") &&
            !P::ValidChallenge(std::string(33, 'a')) && !P::ValidChallenge(std::string(64, 'g')),
            "malformed session challenge accepted");
    response.binding.cacheEpoch++;
    Require(!P::ValidateReply(request, response), "foreign cache epoch accepted");
    response = request; response.kind = P::MessageKind::Response; response.binding.policyIdentity = "other-policy";
    Require(!P::ValidateReply(request, response), "changed policy accepted for reviewed transaction");
    response = request; response.kind = P::MessageKind::Response; response.sequence++;
    Require(!P::ValidateReply(request, response), "replayed response accepted");
    std::string frame;
    Require(P::EncodeFrame(request, &frame), "encode frame");
    P::Message parsed;
    Require(P::DecodeFrame(frame, &parsed), "decode frame");
    Require(!P::DecodeFrame(frame + "extra", &parsed) && !P::DecodeFrame(frame.substr(0, frame.size() - 1), &parsed),
            "frame length mismatch accepted");
    frame[0] = 'X'; Require(!P::DecodeFrame(frame, &parsed), "unframed provider output accepted");
}
void Capabilities() {
    P::Info info;
    info.availability = P::Availability::Ready; info.capabilities = P::RequiredCapabilities;
    info.identifier = "test-provider"; info.implementationVersion = "1";
    info.libraryIdentity = "libapt-identity"; info.frontendIdentity = "apt-get-policy";
    info.environment = Environment();
    std::string reason;
    Require(P::Compatible(RoundTrip(info), info.environment, &reason), "complete provider refused");
    for (const auto flag : {P::ParentFrontendLocks, P::ParentPackageExecutor, P::ParentExtendedStateWriter,
                            P::SourceChecks, P::ExactQueueReview, P::RevalidateReviewedState,
                            P::ReviewedExecutionManifest}) {
        auto incomplete = info; incomplete.capabilities &= ~static_cast<std::uint64_t>(flag);
        Require(!P::Compatible(incomplete, info.environment, &reason), "partial provider selected");
    }
    auto changed = info.environment; changed.paths.dpkgAdmin = "/different/database";
    Require(!P::Compatible(info, changed, &reason), "provider with another dpkg database selected");
    changed = info.environment; changed.policyIdentity = "other-policy";
    Require(!P::Compatible(info, changed, &reason), "provider with another distribution policy selected");
    Require(!P::Compatible(info, P::Environment(), &reason), "empty expected environment accepted");
    changed = info.environment; changed.paths.dpkg = std::string("/bin/dpkg\0hidden", 16);
    Require(!P::ValidEnvironment(changed), "environment path with an embedded NUL accepted");
    changed = info.environment; changed.registeredArchitectures.push_back("native");
    Require(!P::ValidEnvironment(changed), "duplicate architecture identity accepted");
    P::Hello hello;
    hello.options.repositorySecurityMode = RepositorySecurityMode::Distribution;
    hello.expected = info.environment;
    hello.challenge = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    Require(P::ValidHello(hello), "valid handshake refused");
    hello.options.repositorySecurityMode = RepositorySecurityMode::Warning;
    Require(!P::ValidHello(hello), "explicit security choice accepted without negotiating its capability");
    hello.requiredCapabilities |= P::ExplicitSecurityOverrides;
    Require(P::ValidHello(hello), "explicit security choice rejected despite negotiating its capability");
    hello.options.repositorySecurityMode = RepositorySecurityMode::Distribution;
    hello.requiredCapabilities = P::RequiredCapabilities;
    P::Message response; response.kind = P::MessageKind::Response;
    response.operation = P::Operation::Hello; response.sequence = 1; response.succeeded = true;
    response.binding.providerIdentifier = info.identifier;
    response.binding.session = hello.challenge;
    response.binding.configurationIdentity = info.environment.configurationIdentity;
    response.binding.policyIdentity = info.environment.policyIdentity;
    response.binding.packageStateIdentity = info.environment.packageStateIdentity;
    Require(P::Encode(info, &response.payload), "handshake payload encoding");
    P::Info accepted;
    Require(P::ValidateHelloReply(hello, response, &accepted), "matching nonce/provider handshake refused");
    response.binding.session[0] = 'a';
    Require(!P::ValidateHelloReply(hello, response, &accepted), "another session handshake accepted");
    response.binding.session = hello.challenge; response.binding.review = "unreviewed";
    Require(!P::ValidateHelloReply(hello, response, &accepted), "handshake granted an unreviewed transaction token");
    info.protocolVersion++;
    Require(!P::Compatible(info, info.environment, &reason), "unknown protocol selected by version text");
}
}
int main() {
    PackageValues(); RejectionAndBinding(); Capabilities();
    std::cout << "[apt-provider][ ok ] value roundtrips, bounded frames, environment and transaction bindings\n";
}
