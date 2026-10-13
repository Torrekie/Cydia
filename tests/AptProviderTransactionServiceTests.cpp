/* Real socket service, owner, fcntl lock, archive staging and child settlement.
 * Native Darwin declaration/loader and registration producers are the only
 * fixture authorities; all files and children belong to this disposable tree.
 * Copyright (C) 2026 Torrekie; GPL-3.0-or-later. */
#define CYDIA_TRANSACTION_FILES_FIXTURE_ONLY 1
#include "AptProviderTransactionFilesTests.cpp"
#include "Cydia/AptProviderTransactionService.hpp"
#include "Cydia/AptProviderTriggerCapture.hpp"
#include <chrono>
#include <sys/socket.h>
#include <thread>

namespace {
namespace V = CydiaRuntime::Privileged;
namespace TC = P::TransactionChannel;
P::BrokerEnvironment serviceEnvironment;
P::RegistrationIdentity serviceRegistration;
std::string serviceStateDirectory;
unsigned resolutions = 0;
}
namespace CydiaAPT { namespace Provider {
std::string TransactionServiceTestingStateDirectory() { return serviceStateDirectory; }
// Host files cannot supply the Darwin registration/loader authority. This
// target substitutes its independently prepared fixture, then still checks
// exact expected authority and paths before the real service/owner executes.
bool ResolveBrokerRequest(const CydiaRuntime::PackageDatabasePaths &, const V::Request &request, uid_t uid,
    BrokerEnvironment *selected, std::string *payload, V::Error *error, const Recovery::DependencyInspector &) {
    ++resolutions; std::vector<std::string> fields; RegistrationIdentity identity;
    std::string actual, expected;
    if (uid != getuid() || !Decode(request.payload, &fields) || fields.size() != 3 || fields[0] != "CYDIA-BROKER-1" ||
        !ParseRegistrationIdentity(fields[1], &identity) || !SameRegistrationIdentity(identity, serviceRegistration) ||
        !Encode(request.expected, &actual) || !Encode(static_cast<const V::ExpectedEnvironment &>(serviceEnvironment.environment), &expected) ||
        actual != expected) {
        if (error) error->code = "provider_authority_changed";
        return false;
    }
    *selected = serviceEnvironment; *payload = fields[2]; return true;
}
}}
namespace {
P::TransactionBeginRequest Prepare(Fixture &fixture, int *lock, bool scoped = false, bool initialPending = false) {
    const auto admin = fixture.root + "/admin";
    std::filesystem::create_directory(admin); std::filesystem::create_directory(admin + "/updates");
    Write(admin + "/status", ""); Write(fixture.root + "/extended_states", "");
    Write(fixture.root + "/dpkg", "#!/bin/sh\nfor arg do\ncase \"$arg\" in\n--print-architecture) printf 'amd64\\n'; exit 0;;\n--print-foreign-architectures) exit 0;;\nesac\ndone\nexit 1\n", 0755);
    Write(fixture.root + "/dpkg-query", "#!/bin/sh\nexec /bin/cat \"$0.rows\"\n", 0755);
    Write(fixture.root + "/dpkg-query.rows", ""); Write(fixture.root + "/native.conf", "fixture native graph\n");
    const std::string initialRows = "cache\t1\tamd64\tinstall ok " + std::string(initialPending ? "triggers-pending" : "installed") +
        "\tno\t" + (initialPending ? "cache-refresh" : "") + "\t\n";
    if (scoped) {
        std::filesystem::create_directory(admin + "/info"); std::filesystem::create_directory(admin + "/triggers");
        Write(admin + "/status", "Package: cache\nVersion: 1\nArchitecture: amd64\nStatus: install ok " +
            std::string(initialPending ? "triggers-pending\nTriggers-Pending: cache-refresh\n\n" : "installed\n\n"));
        Write(fixture.root + "/dpkg-query.rows", initialRows);
        Write(admin + "/info/cache.triggers", "interest-await cache-refresh\n");
        Write(admin + "/triggers/Lock", "", 0600); Write(admin + "/triggers/Unincorp", "");
        Write(admin + "/triggers/cache-refresh", "cache:amd64\n");
    }
    serviceEnvironment = P::BrokerEnvironment(); serviceEnvironment.runtime = fixture.runtime;
    auto &environment = serviceEnvironment.environment;
    environment.dpkg = fixture.root + "/dpkg"; environment.dpkgQuery = fixture.root + "/dpkg-query";
    environment.dpkgDeb = "/usr/bin/dpkg-deb"; environment.dpkgRoot = "/"; environment.dpkgAdmin = admin;
    environment.sourceList = fixture.runtime.sourceListPath; environment.extendedStates = fixture.root + "/extended_states";
    serviceEnvironment.executableSearchPath = serviceEnvironment.archiveDecoderSearchPath = "/usr/bin:/bin";
    serviceEnvironment.runtime.dpkgOptions = {"--admindir=" + admin, "--root=/"};
    serviceEnvironment.runtime.packageInstallPrefix = "/";
    serviceStateDirectory = fixture.root + "/private";
    serviceRegistration = {fixture.root + "/registration", "fixture-provider", "config-v1", "policy-v1", "methods-v1", "libraries-v1", "frontend-v1"};
    *lock = open((admin + "/lock-frontend").c_str(), O_CREAT | O_RDWR, 0600);
    struct flock request = {}; request.l_type = F_WRLCK; request.l_whence = SEEK_SET;
    Require(*lock >= 0 && fcntl(*lock, F_SETLK, &request) == 0, "parent owns actual service lock");
    P::TransactionBeginRequest begin; begin.review = fixture.review; begin.changes = {{"sample", "amd64", true}};
    V::Error error;
    Require(V::RuntimeSnapshot(environment, &begin.review.binding.packageStateIdentity, &error), "capture initial service snapshot");
    fixtureAuthority = P::NativeDpkgAuthority(); fixtureAuthorityAvailable = true;
    Require(CydiaRuntime::NativeLaunchEnvironment::FromEntries({"PATH=/usr/bin:/bin", "DPKG_FRONTEND_LOCKED=1"},
            &fixtureAuthority.launchEnvironment), "construct explicit fixture native launch snapshot");
    fixtureAuthority.launchEnvironmentBytes = CydiaRuntime::Privileged::SerializeFields(fixtureAuthority.launchEnvironment.entries());
    fixtureAuthority.configurationIdentity = Hash("fixture native graph\n"); fixtureAuthority.platformIdentity.assign(64, 'a');
    V::Evidence config;
    Require(V::CaptureEvidence(fixture.root + "/native.conf", false, false, &config, &error), "capture service fixture declaration");
    fixtureAuthority.configurationEvidence = {config}; fixtureAuthority.componentPaths = {environment.dpkg, environment.dpkgQuery};
    std::vector<P::InstalledComponentEvidence> nativeFiles;
    for (const auto &path : fixtureAuthority.componentPaths) {
        P::InstalledComponentEvidence file; std::string failure;
        Require(P::CaptureTransactionComponent(path, &file, &failure), "capture service fixture executables");
        fixtureAuthority.executorGenerations[path].insert(file.file.sha256); nativeFiles.push_back(file);
    }
    if (scoped) {
        std::string reason; P::DpkgState initial; P::TriggerEffectCheckpoint checkpoint; P::TriggerCaptureLock held; held.descriptor = *lock;
        Require(P::ParseDpkgState(initialRows, "amd64\n", "",
            begin.review.binding.packageStateIdentity, &initial, &reason) &&
            P::CaptureTriggerEffectCheckpoint(environment, initial, held, &checkpoint, &reason), "capture actual service trigger checkpoint");
        auto approved = std::make_shared<P::TriggerEffectEnvelope>();
        Require(P::BuildTriggerEffectEnvelope(begin.review, checkpoint, approved.get(), &reason, P::TriggerNativeAuthorityIdentity(fixtureAuthority, nativeFiles)), "review exact service trigger pool");
        begin.reviewedEffects = approved;
    }
    return begin;
}
void RunService(Fixture &fixture, int socket, unsigned mode) {
    P::TransactionServiceOptions options; options.nonmutatingMilliseconds = mode == 12 ? 80 : 5000;
    options.application = {std::to_string(getppid()), "10.1", "20.2", std::string(40, 'a')}; options.applicationUID = getuid();
    options.authenticate = [&](V::ApplicationProcessIdentity *app, uid_t *uid, std::string *) {
        *app = options.application; *uid = access((fixture.root + "/revoke").c_str(), F_OK) == 0 ? options.applicationUID + 1 : options.applicationUID;
        return true;
    };
    options.prepareEnvironment = [](P::BrokerEnvironment *environment, std::string *) {
        Require(environment->executableSearchPath == "/usr/bin:/bin", "prepare only selected native environment"); return true;
    };
    unsigned children = 0;
    options.execute = [&](const std::string &tool, const std::vector<std::string> &arguments, int input, int status,
        const std::function<void()> &started, const CydiaRuntime::NativeLaunchEnvironment &launchEnvironment) {
        Require(launchEnvironment.initialized(), "service carries retained explicit child environment");
        Require(arguments.size() > 1 && arguments[0] == "--root=" + serviceEnvironment.environment.dpkgRoot &&
            arguments[1] == "--admindir=" + serviceEnvironment.environment.dpkgAdmin &&
            std::count(arguments.begin(), arguments.end(), arguments[0]) == 1 &&
            std::count(arguments.begin(), arguments.end(), arguments[1]) == 1,
            "service normalizes protected reset options to the selected root/admin");
        Require(tool == serviceEnvironment.environment.dpkg, "executor path comes from fixture authority"); ++children;
        Require(std::find(arguments.begin(), arguments.end(), "--status-fd=" + std::to_string(status)) != arguments.end(),
            "owner maps worker status placeholder to actual received descriptor");
        const bool configure = std::find(arguments.begin(), arguments.end(), "--configure") != arguments.end();
        const bool drain = std::find(arguments.begin(), arguments.end(), "--triggers-only") != arguments.end();
        const pid_t child = fork(); Require(child >= 0, "actual service child spawn");
        if (!child) {
            char answer[2]; Require(read(input, answer, 2) == 2 && std::string(answer, 2) == "N\n", "fresh child stdin received");
            Require(write(status, "child\n", 6) == 6, "fresh child status received");
            if (mode == 6) std::this_thread::sleep_for(std::chrono::milliseconds(150));
            const bool pending = mode >= 13 && !configure && !drain;
            // Unpack has not configured sample. Pending trigger bookkeeping
            // may coexist with its unpacked state; triggers-awaited would
            // instead claim a configured package awaiting trigger completion.
            const std::string state = configure ? "installed" : "unpacked";
            std::string control = "Package: sample\nVersion: 1\nArchitecture: all\nStatus: install ok " + state + "\n";
            if (pending) control += "Triggers-Awaited: cache:amd64\n";
            control += '\n';
            std::string rows = "sample\t1\tall\tinstall ok " + state + "\tno\t\t" + (pending ? "cache:amd64" : "") + "\n";
            // This initial drain precedes the denied primary action. It must
            // settle only cache, never invent the not-yet-unpacked package.
            if (mode == 16) { Require(drain, "only the initial drain may spawn"); control.clear(); rows.clear(); }
            if (mode >= 13) {
                control += "Package: cache\nVersion: 1\nArchitecture: amd64\nStatus: install ok " +
                    std::string(pending ? "triggers-pending\nTriggers-Pending: cache-refresh\n\n" : "installed\n\n");
                rows += "cache\t1\tamd64\tinstall ok " + std::string(pending ? "triggers-pending" : "installed") +
                    "\tno\t" + (pending ? "cache-refresh" : "") + "\t\n";
            }
            Write(serviceEnvironment.environment.dpkgAdmin + "/status", control);
            Write(serviceEnvironment.environment.dpkgQuery + ".rows", rows);
            _exit(mode == 11 ? 1 : 0);
        }
        started(); int state;
        Require(waitpid(child, &state, 0) == child, "service child always settles");
        Write(fixture.root + "/settled", std::to_string(children));
        P::ParentExecutionReply result; result.started = true;
        result.exitCode = WIFEXITED(state) ? WEXITSTATUS(state) : -1; result.signal = WIFSIGNALED(state) ? WTERMSIG(state) : 0;
        return result;
    };
    if (mode == 2) fixtureAuthorityAvailable = false;
    std::string error;
    const bool success = P::ServeProviderTransaction(socket,
        CydiaRuntime::PackageDatabasePaths::ForLayout(CydiaRuntime::PackageDatabaseLayout::Rootful), options, &error);
    if (success != (mode == 0 || mode == 13)) std::cerr << "[transaction-service][helper] mode=" << mode
        << " success=" << success << " error=" << error << " children=" << children << '\n';
    Require(success == (mode == 0 || mode == 13), "service reports exact scenario outcome");
    Require(resolutions == (mode == 12 ? 0u : 1u), "authority resolved once per lifetime before mutations");
    if (mode == 2) Require(error == "provider_native_configuration_missing", "missing native declaration remains distinct");
    Require(children == (mode == 13 ? 3u : (mode == 0 || mode == 7) ? 2u : (mode == 6 || mode == 11 || mode == 14 || mode == 16) ? 1u : 0u), "no extra or replayed child");
}
TC::Frame Receive(TC::Channel &channel) {
    TC::Frame frame; std::vector<int> descriptors;
    Require(channel.Receive(&frame, &descriptors, 5000) && descriptors.empty(), channel.error().c_str()); return frame;
}
void Scenario(unsigned mode) {
    Fixture fixture; int lock = -1; auto begin = Prepare(fixture, &lock);
    int sockets[2]; Require(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) == 0, "service socketpair");
    const pid_t helper = fork(); Require(helper >= 0, "fork direct authenticated helper");
    if (!helper) { close(sockets[0]); close(lock); RunService(fixture, sockets[1], mode); _exit(0); }
    close(sockets[1]); TC::Channel channel(sockets[0]);
    if (mode == 8) { close(lock); lock = -1; }
    if (mode != 12) {
        std::string payload; Require(P::EncodeTransactionBegin(begin, &payload), "canonical begin payload");
        V::Request wrapped; wrapped.expected = serviceEnvironment.environment;
        auto authority = serviceRegistration; if (mode == 9) authority.policyIdentity = "forged-policy";
        Require(P::BrokerRequestPayload(authority, payload, &wrapped.payload), "wrapped fixture authority");
        TC::Frame request; request.reviewDigest = P::TransactionBeginDigest(begin);
        request.payload = V::SerializeRequest(wrapped); if (mode == 1) request.reviewDigest.assign(64, 'f');
        Require(channel.Send(request), "send actual Begin"); auto response = Receive(channel);
        if (mode == 1 || mode == 2 || mode == 8 || mode == 9) {
            const char *code = mode == 1 ? "provider_transaction_review_mismatch" : mode == 2 ? "provider_native_configuration_missing" :
                mode == 8 ? "provider_frontend_lock_required" : "provider_authority_changed";
            Require(!response.success && !response.mutationStarted && response.errorCode == code, "typed pre-mutation refusal");
        } else {
            Require(response.success && response.nonce.size() == 64, "helper generates transaction nonce");
            request.nonce = response.nonce; request.sequence = 1; request.operation = TC::Operation::Capture; request.payload.clear();
            if (mode == 3) request.nonce[0] = request.nonce[0] == 'a' ? 'b' : 'a';
            if (mode == 5) Write(fixture.root + "/revoke", "revoked");
            Require(channel.Send(request), "capture current owner state"); response = Receive(channel);
            if (mode == 3 || mode == 5) Require(!response.success && !response.mutationStarted, "reject nonce/caller changes before child");
            else {
                P::DpkgState state; Require(response.success && P::DecodeBrokerState(response.payload, &state) && state.packages.empty(), "initial Capture uses actual empty fixture database");
                if (mode == 4) {
                    Require(channel.Send(request), "repeat old sequence"); response = Receive(channel);
                    Require(!response.success && response.errorCode == "provider_transaction_binding_invalid", "replay rejected");
                } else {
                    for (unsigned batch = 1; batch <= (mode == 6 || mode == 11 ? 1u : 2u); ++batch) {
                        P::ParentExecutionRequest execution; execution.binding = begin.review.binding; execution.batch = batch;
                        execution.actions = {batch}; execution.action = batch == 1 ? P::ExecutionAction::Unpack : P::ExecutionAction::Configure;
                        execution.arguments = serviceEnvironment.runtime.dpkgOptions;
                        execution.arguments.insert(execution.arguments.end(), {"--status-fd=99", "--no-triggers", batch == 1 ? "--unpack" : "--configure",
                            batch == 1 ? begin.review.execution.archives[0].path : "sample:all"});
                        request.operation = TC::Operation::Execute; ++request.sequence;
                        Require(P::Encode(execution, &request.payload), "encode exact child batch");
                        int input[2], status[2]; Require(pipe(input) == 0 && pipe(status) == 0, "fresh batch descriptors");
                        Require(write(input[1], "N\n", 2) == 2 && channel.Send(request, {input[0], status[1]}), "send exact descriptors");
                        close(input[0]); close(input[1]); close(status[1]);
                        response = Receive(channel); Require(response.event == TC::Event::Started && response.mutationStarted, "real spawn produces Started first");
                        if (mode == 6) channel.Close();
                        else {
                            response = Receive(channel);
                            Require(response.event == TC::Event::Settled && response.mutationStarted && response.success == (mode != 11), "settlement preserves exact start flag");
                            if (response.success) {
                                P::TransactionExecutionReply result;
                                Require(P::DecodeTransactionExecutionReply(response.payload, &result) && result.result.started && !result.result.exitCode &&
                                    result.state.packages.at("sample:all").status == (batch == 1 ? P::DpkgPackageStatus::Unpacked : P::DpkgPackageStatus::Installed),
                                    "settled child carries protected new state");
                            }
                        }
                        char bytes[6]; Require(read(status[0], bytes, sizeof(bytes)) == 6 && std::string(bytes, 6) == "child\n", "new status channel works each batch"); close(status[0]);
                    }
                    if (mode != 6 && mode != 11) {
                        P::ExtendedStateRequest changes; changes.binding = begin.review.binding; changes.changes = begin.changes;
                        std::string delta; Require(P::Encode(changes, &delta), "encode approved extended-state changes");
                        request.operation = TC::Operation::Commit; ++request.sequence;
                        request.payload = V::SerializeFields({mode == 7 ? "wrong baseline" : begin.extendedState, delta});
                        Require(channel.Send(request), "send CAS commit"); response = Receive(channel);
                        if (mode == 7) Require(!response.success && !response.mutationStarted, "invalid CAS never claims Started");
                        else {
                            Require(response.event == TC::Event::Started && response.mutationStarted, "CAS Started precedes settlement");
                            response = Receive(channel); Require(response.success && response.mutationStarted, "CAS settles successfully");
                            request.operation = TC::Operation::Close; ++request.sequence; request.payload.clear();
                            Require(channel.Send(request), "close settled transaction"); response = Receive(channel);
                            Require(response.success && !response.mutationStarted, "Close never inherits prior child start flag");
                        }
                    }
                }
            }
        }
    }
    int state; Require(waitpid(helper, &state, 0) == helper && WIFEXITED(state) && !WEXITSTATUS(state), "service fixture helper settled");
    if (mode == 6) Require(access((fixture.root + "/settled").c_str(), F_OK) == 0, "connection loss cannot abandon actual child");
    if (lock >= 0) close(lock);
}
void ScopedScenario(unsigned mode) {
    Fixture fixture; int lock = -1; auto begin = Prepare(fixture, &lock, true, mode == 16);
    int sockets[2]; Require(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) == 0, "scoped service socketpair");
    const pid_t helper = fork(); Require(helper >= 0, "fork scoped helper");
    if (!helper) { close(sockets[0]); close(lock); RunService(fixture, sockets[1], mode); _exit(0); }
    close(sockets[1]); TC::Channel channel(sockets[0]);
    std::string payload; Require(P::EncodeTransactionBegin(begin, &payload), "encode reviewed effect approval");
    V::Request wrapped; wrapped.expected = serviceEnvironment.environment;
    Require(P::BrokerRequestPayload(serviceRegistration, payload, &wrapped.payload), "scope wrapper");
    TC::Frame request; request.scopedChildren = true; request.reviewDigest = P::TransactionBeginDigest(begin); request.payload = V::SerializeRequest(wrapped);
    Require(channel.Send(request), "request finite child negotiation"); auto response = Receive(channel);
    Require(response.success && response.scopedChildren, "owner independently admits finite effects before negotiation succeeds");
    request.nonce = response.nonce;
    unsigned scopes = 0, drains = 0;
    for (unsigned batch = 1; batch <= (mode == 13 ? 2u : 1u); ++batch) {
        P::ParentExecutionRequest execution; execution.binding = begin.review.binding; execution.batch = batch;
        execution.actions = {batch}; execution.action = batch == 1 ? P::ExecutionAction::Unpack : P::ExecutionAction::Configure;
        execution.arguments = serviceEnvironment.runtime.dpkgOptions;
        execution.arguments.insert(execution.arguments.end(), {"--status-fd=99", "--no-triggers", batch == 1 ? "--unpack" : "--configure",
            batch == 1 ? begin.review.execution.archives[0].path : "sample:all"});
        if (mode == 16) execution.arguments.insert(execution.arguments.begin(), "--unapproved-fixture-option");
        request.operation = TC::Operation::Execute; ++request.sequence;
        Require(P::Encode(execution, &request.payload) && channel.Send(request), "scoped outer execute has no inherited channels");
        for (;;) {
            response = Receive(channel);
            if (response.event == TC::Event::Settled) {
                const bool expected = response.success == (mode == 13) && response.mutationStarted == (mode != 15);
                if (!expected) std::cerr << "[transaction-service][outer] mode=" << mode << " batch=" << batch
                    << " error=" << response.errorCode << " success=" << response.success << " started=" << response.mutationStarted
                    << " indeterminate=" << response.indeterminate << " scopes=" << scopes << " drains=" << drains << '\n';
                Require(expected, "outer scope reports exact aggregate execution outcome");
                if (mode == 16) Require(!response.indeterminate && response.errorCode == "provider_lease_batch_not_authorized",
                    "initial drain plus denied primary remains settled without transport loss");
                break;
            }
            TC::ChildDescriptor descriptor;
            Require(response.event == TC::Event::ChildNeeded && response.sequence == request.sequence && response.childOrdinal == ++scopes &&
                P::SameBinding(execution.binding, begin.review.binding) && TC::DecodeChildDescriptor(response.childDescriptor, &descriptor), "helper asks for unique child in bound outer request");
            if (descriptor.purpose == TC::ChildPurpose::Primary)
                Require(descriptor.primaryBatch == batch && descriptor.primaryActions == execution.actions, "primary scope retains exact approved action IDs");
            else {
                ++drains;
                Require(descriptor.envelopeIdentity == begin.reviewedEffects->identity && descriptor.pass == 1 && descriptor.targets.size() == 1 &&
                    descriptor.targets[0].package == "cache" && descriptor.targets[0].version == "1" && descriptor.targets[0].architecture == "amd64",
                    "effect scope names independently reconciled exact recipient generation");
            }
            int input[2], status[2]; Require(socketpair(AF_UNIX, SOCK_STREAM, 0, input) == 0 && pipe(status) == 0, "fresh production-shaped child channels");
            Require(write(input[1], "N\n", 2) == 2, "queue child-specific reply");
            auto answer = response; answer.event = TC::Event::ChildChannels; answer.success = true;
            if (mode == 15) ++answer.childOrdinal;
            Require(channel.Send(answer, {input[0], status[1]}), "provide exact child channel pair");
            close(input[0]); close(status[1]);
            if (mode == 15) { close(input[1]); close(status[0]); continue; }
            auto event = Receive(channel);
            if (mode == 16 && descriptor.purpose == TC::ChildPurpose::Primary) {
                P::ParentExecutionReply denied;
                Require(scopes == 2 && drains == 1 && event.event == TC::Event::ChildSettled &&
                    event.childOrdinal == response.childOrdinal && event.childDescriptor == response.childDescriptor &&
                    !event.mutationStarted && P::Decode(event.payload, &denied) && !denied.started && denied.launchError == EACCES,
                    "denied primary has its own no-spawn settlement after successful initial drain");
                char unused; Require(read(status[0], &unused, 1) == 0, "denied primary closes unused status without child output");
                close(input[1]); close(status[0]);
                answer = event; answer.payload.clear(); answer.event = TC::Event::ChildReleased;
                Require(channel.Send(answer), "release nonstarted primary while retaining prior drain outcome");
                continue;
            }
            Require(event.event == TC::Event::ChildStarted && event.childOrdinal == response.childOrdinal &&
                event.childDescriptor == response.childDescriptor, "start belongs to requested child only");
            event = Receive(channel); P::ParentExecutionReply result;
            Require(event.event == TC::Event::ChildSettled && event.childOrdinal == response.childOrdinal &&
                event.childDescriptor == response.childDescriptor && P::Decode(event.payload, &result) && result.started && !result.exitCode,
                "child settlement follows real reap");
            char bytes[6]; Require(read(status[0], bytes, 6) == 6 && std::string(bytes, 6) == "child\n", "child-specific status received");
            close(input[1]); close(status[0]);
            answer = event; answer.payload.clear(); answer.event = mode == 14 ? TC::Event::ChildCancelled : TC::Event::ChildReleased;
            answer.success = mode != 14; answer.errorCode = mode == 14 ? "provider_cancelled" : "";
            Require(channel.Send(answer), "release finished child before next scope");
        }
    }
    if (mode == 13) {
        Require(scopes == 3 && drains == 1, "one primary/effect/primary generation without outer sequence expansion");
        P::ExtendedStateRequest commit; commit.binding = begin.review.binding; commit.changes = begin.changes;
        std::string changes; Require(P::Encode(commit, &changes), "scoped Commit changes");
        request.operation = TC::Operation::Commit; ++request.sequence; request.payload = V::SerializeFields({begin.extendedState, changes});
        Require(channel.Send(request) && Receive(channel).event == TC::Event::Started && Receive(channel).success, "finite owner commits after quiescent effect drain");
        request.operation = TC::Operation::Close; ++request.sequence; request.payload.clear();
        Require(channel.Send(request) && Receive(channel).success, "finite owner closes");
    } else if (mode == 16) Require(scopes == 2 && drains == 1, "initial drain followed by exactly one nonstarted primary scope");
    else Require(scopes == 1 && !drains, "cancellation or wrong ordinal cannot reach another child");
    int state; Require(waitpid(helper, &state, 0) == helper && WIFEXITED(state) && !WEXITSTATUS(state), "scoped helper fully settled");
    close(lock);
}
}
int main() {
    // The shared fixture's other entry points remain separate build targets.
    (void)&CaptureFiles; (void)&StagedArchives; (void)&OwnerTransactions;
    for (unsigned mode : {0u, 1u, 2u, 3u, 4u, 5u, 6u, 7u, 8u, 9u, 11u, 12u}) Scenario(mode);
    for (unsigned mode : {13u, 14u, 15u, 16u}) ScopedScenario(mode);
    std::cout << "[transaction-service] real owner, transport, identity, lock, fresh descriptors and settlement passed\n";
}
