/* Real socket service, owner, fcntl lock, archive staging and child settlement.
 * Native Darwin declaration/loader and registration producers are the only
 * fixture authorities; all files and children belong to this disposable tree.
 * Copyright (C) 2026 Torrekie; GPL-3.0-or-later. */
#define CYDIA_TRANSACTION_FILES_FIXTURE_ONLY 1
#include "AptProviderTransactionFilesTests.cpp"
#include "Cydia/AptProviderTransactionService.hpp"
#include "Cydia/AptProviderTriggerCapture.hpp"
#include <chrono>
#include <iterator>
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
// These v3 cases deliberately substitute ONLY the native policy/loader
// producers, using a disposable shell program with known fixture behavior.
// A successful assertion match here is not native dpkg policy/readiness proof.
// Owner::PrepareConffiles, CaptureConffilePolicy, the service handshake,
// protected rechecks, fork/exec with frozen envp, descriptors and settlement
// are the production paths. NativeDpkgAuthorityTests covers its real producer.
namespace N = P::NativeEffectPolicy;
std::string ReadFixture(const std::string &path) {
    std::ifstream file(path, std::ios::binary);
    Require(file.good(), "open disposable fixture bytes");
    return std::string(std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>());
}
bool FixtureConffileInputs(const P::NativeDpkgAuthority &authority, const std::string &executable,
    const std::vector<P::InstalledComponentEvidence> &files, const std::string &profile, N::Role role,
    const std::vector<std::string> &prefix, N::Inputs *out, std::string *error, const std::function<bool()> &cancelled) {
    if (cancelled && cancelled()) return false;
    N::Inputs inputs; inputs.semanticProfile = profile; inputs.executorPath = executable;
    inputs.platformIdentity = authority.platformIdentity; inputs.environment = authority.launchEnvironment;
    inputs.dpkgRoot = serviceEnvironment.environment.dpkgRoot; inputs.dpkgAdmin = serviceEnvironment.environment.dpkgAdmin;
    inputs.executableSearchPath = serviceEnvironment.executableSearchPath; inputs.role = role; inputs.optionPrefix = prefix;
    // Protected graph recheck happened in the labelled shared test seam before
    // this read. The exact fixture's one native-read file is fully accounted.
    Require(authority.configurationEvidence.size() == 1, "exact disposable native config graph");
    N::ContentInput config; config.path = authority.configurationEvidence.front().path;
    const auto bytes = ReadFixture(config.path); config.present = true; config.size = bytes.size(); config.sha256 = Hash(bytes);
    inputs.configuration.push_back(config);
    for (const auto &file : files) {
        N::ComponentInput component; component.path = file.file.metadata.path; component.sha256 = file.file.sha256;
        inputs.components.push_back(component);
        if (component.path == executable) inputs.executorSHA256 = component.sha256;
    }
    std::string encoded;
    if (!N::EncodeInputs(inputs, &encoded)) {
        if (error) *error = "fixture_policy_inputs_invalid";
        return false;
    }
    *out = std::move(inputs);
    if (error) error->clear();
    return true;
}
std::vector<P::InstalledComponentEvidence> CaptureFixtureExecutors() {
    std::vector<P::InstalledComponentEvidence> files; fixtureAuthority.executorGenerations.clear();
    for (const auto &path : fixtureAuthority.componentPaths) {
        P::InstalledComponentEvidence file; std::string error;
        Require(P::CaptureTransactionComponent(path, &file, &error), "capture conffile fixture executables");
        fixtureAuthority.executorGenerations[path].insert(file.file.sha256); files.push_back(file);
    }
    return files;
}
P::TransactionBeginRequest PrepareConffileFixture(Fixture &fixture, int *lock, unsigned mode) {
    auto begin = Prepare(fixture, lock);
    serviceEnvironment.runtime.dpkgOptions = {"--admindir", serviceEnvironment.environment.dpkgAdmin, "--root=/"};
    // A real execve child checks the exact frozen environment and dedicated
    // stdin/status roles. It is not a dpkg simulator or native policy oracle.
    Write(fixture.root + "/dpkg", R"SH(#!/bin/sh
for arg do
 case "$arg" in
 --print-architecture) printf 'amd64\n'; exit 0;;
 --print-foreign-architectures) exit 0;;
 esac
done
[ "$FIXTURE_FROZEN" = before ] && [ "${FIXTURE_EMPTY+x}" = x ] && [ -z "$FIXTURE_EMPTY" ] || exit 81
[ "${FIXTURE_ABSENT+x}" != x ] && [ "$LC_MESSAGES" = C ] && [ "$DPKG_FRONTEND_LOCKED" = 1 ] || exit 82
base=${0%/*}
state=unpacked
for arg do [ "$arg" != --configure ] || state=installed; done
printf 'status: /etc/fixture.conf : conffile-prompt : fixture\n' >&3 || exit 83
if [ ! -f "$base/automatic" ]; then
 IFS= read -r answer || exit 84
 [ "$answer" = N ] || exit 85
fi
printf 'Package: sample\nVersion: 1\nArchitecture: all\nStatus: install ok %s\n\n' "$state" > "$base/admin/status"
printf 'sample\t1\tall\tinstall ok %s\tno\t\t\n' "$state" > "$base/dpkg-query.rows"
printf 'child-complete\n' >&3
exit 0
)SH", 0755);
    if (mode == 21) Write(fixture.root + "/automatic", "known fixture automatic answer");
    Require(CydiaRuntime::NativeLaunchEnvironment::FromEntries({"PATH=/usr/bin:/bin", "DPKG_FRONTEND_LOCKED=1",
        "LANG=C", "LC_MESSAGES=C", "FIXTURE_FROZEN=before", "FIXTURE_EMPTY="}, &fixtureAuthority.launchEnvironment),
        "freeze exact fixture child environment");
    fixtureAuthority.launchEnvironmentBytes = V::SerializeFields(fixtureAuthority.launchEnvironment.entries());
    const auto files = CaptureFixtureExecutors(); fixturePolicyProducer = FixtureConffileInputs;
    fixtureAuthority.effectRecordState = P::NativeEffectRecordState::Parsed;
    for (unsigned batch = 1; batch <= 2; ++batch) {
        N::Inputs inputs; std::string error;
        const std::vector<std::string> prefix = {"--root=/", "--admindir=" + serviceEnvironment.environment.dpkgAdmin,
            "--status-fd=3", "--no-triggers", batch == 1 ? "--unpack" : "--configure"};
        const auto role = batch == 1 ? N::Role::Unpack : N::Role::Configure;
        Require(P::BuildNativeEffectPolicyInputs(fixtureAuthority, serviceEnvironment.environment.dpkg, files,
            "dpkg-1.23.7-effects-1", role, prefix, &inputs, &error), "build labelled fixture content inputs");
        N::Record record; record.semanticProfile = inputs.semanticProfile; record.executorPath = inputs.executorPath;
        record.executorSHA256 = inputs.executorSHA256; record.role = role; record.optionPrefix = prefix;
        Require(N::InputIdentity(inputs, [](const std::string &bytes) { return Hash(bytes); }, &record.inputIdentity), "bind fixture policy input");
        record.settings.triggers = N::TriggerMode::Disabled; record.settings.statusDescriptors = {3};
        // This is an assertion about the known fixture program only. The two
        // production force projections are also exercised by protected tests.
        if (mode == 21) record.settings.forces = {batch == 1 ? N::Force::Confold : N::Force::Confdef};
        fixtureAuthority.effectRecords.push_back(record);
    }
    V::Error snapshotError;
    Require(V::RuntimeSnapshot(serviceEnvironment.environment, &begin.review.binding.packageStateIdentity, &snapshotError),
        "capture v3 state after complete fixture setup");
    return begin;
}
void RunConffileService(Fixture &fixture, int socket, unsigned mode) {
    P::TransactionServiceOptions options; options.nonmutatingMilliseconds = 5000;
    options.application = {std::to_string(getppid()), "10.1", "20.2", std::string(40, 'a')}; options.applicationUID = getuid();
    bool changed = false; unsigned children = 0;
    options.authenticate = [&](V::ApplicationProcessIdentity *app, uid_t *uid, std::string *) {
        *app = options.application; *uid = options.applicationUID;
        // Service authenticates immediately after receiving ChildPolicyAccepted.
        // Mutate deterministically inside that callback, after the match/ACK
        // wait but before Owner's required final graph/component recheck.
        if (!changed && (mode == 22 || mode == 23) && access((fixture.root + "/policy-ack").c_str(), F_OK) == 0) {
            changed = true;
            if (mode == 22) Write(fixture.root + "/native.conf", "changed after policy acknowledgement\n");
            else Write(fixture.root + "/dpkg", "#!/bin/sh\nexit 99\n", 0755);
        }
        return true;
    };
    options.prepareEnvironment = [](P::BrokerEnvironment *, std::string *) { return true; };
    options.execute = [](const std::string &, const std::vector<std::string> &, int, int,
        const std::function<void()> &, const CydiaRuntime::NativeLaunchEnvironment &) {
        Require(false, "v3 cannot fall back to the legacy executor");
        return P::ParentExecutionReply();
    };
    // Mutation of ambient state must not change the matched or actual child env.
    Require(setenv("FIXTURE_FROZEN", "ambient-after-capture", 1) == 0 &&
        setenv("FIXTURE_ABSENT", "ambient-only", 1) == 0, "change helper ambient environment after freeze");
    options.executePrepared = [&](const std::string &tool, const std::vector<std::string> &arguments, int input, int status,
        const std::function<void()> &started, const CydiaRuntime::NativeLaunchEnvironment &environment, std::size_t statusIndex) {
        Require(statusIndex == 2 && P::ValidFinalNativeChildArguments(arguments, statusIndex) && arguments.size() == 6 &&
            arguments[0] == "--root=/" && arguments[1] == "--admindir=" + serviceEnvironment.environment.dpkgAdmin &&
            arguments[2] == "--status-fd=3" && arguments[3] == "--no-triggers",
            "actual final root/admin/status span after split-option binding");
        Require(tool == serviceEnvironment.environment.dpkg && environment.entries() == fixtureAuthority.launchEnvironment.entries(),
            "actual executor and env are independently retained authority");
        Require(children < 2 && arguments[4] == (children == 0 ? "--unpack" : "--configure"), "ordered exact native role");
        if (children == 0) {
            Require(arguments[5] != fixture.review.execution.archives.front().path &&
                arguments[5].compare(0, (fixture.root + "/private/").size(), fixture.root + "/private/") == 0 &&
                ReadFixture(arguments[5]) == fixture.deb, "Unpack uses exact retained private archive bytes instead of source operand");
            struct stat staged;
            Require(lstat(arguments[5].c_str(), &staged) == 0 && S_ISREG(staged.st_mode) &&
                (staged.st_mode & 07777) == 0600 && staged.st_uid == 0 && staged.st_nlink == 1,
                "retained Unpack operand has protected staging identity");
        } else Require(arguments[5] == "sample:all", "Configure retains exact reviewed package architecture operand");
        N::Inputs inputs; std::string error, launch;
        std::vector<P::InstalledComponentEvidence> files;
        for (const auto &path : fixtureAuthority.componentPaths) {
            P::InstalledComponentEvidence file;
            Require(P::CaptureTransactionComponent(path, &file, &error), "fresh executor evidence at test launch"); files.push_back(file);
        }
        Require(P::BuildNativeEffectPolicyInputs(fixtureAuthority, tool, files, "dpkg-1.23.7-effects-1",
            children == 0 ? N::Role::Unpack : N::Role::Configure,
            std::vector<std::string>(arguments.begin(), arguments.begin() + 5), &inputs, &error) &&
            N::LaunchIdentity(inputs, arguments, [](const std::string &bytes) { return Hash(bytes); }, &launch) &&
            ReadFixture(fixture.root + "/policy-ack") == launch,
            "acknowledged policy binds exact actual role, rewritten archive operand and frozen launch environment");
        Require(unlink((fixture.root + "/policy-ack").c_str()) == 0, "consume exact child acknowledgement marker");
        CydiaRuntime::NativeLaunchEnvironment::Envp envp; Require(environment.BuildEnvp(&envp), "owned explicit execve envp");
        std::vector<std::string> storage{tool}; storage.insert(storage.end(), arguments.begin(), arguments.end());
        std::vector<char *> argv; for (auto &arg : storage) argv.push_back(&arg[0]); argv.push_back(nullptr);
        const int childInput = fcntl(input, F_DUPFD_CLOEXEC, 10), childStatus = fcntl(status, F_DUPFD_CLOEXEC, 10);
        Require(childInput >= 10 && childStatus >= 10, "protect dup2 from child descriptor collision");
        const pid_t child = fork(); Require(child >= 0, "actual policy-scoped execve child");
        if (!child) {
            if (dup2(childInput, 0) < 0 || dup2(childStatus, 3) < 0) _exit(86);
            close(childInput); close(childStatus);
            execve(tool.c_str(), argv.data(), envp.data()); _exit(87);
        }
        close(childInput); close(childStatus); ++children; started();
        int state; Require(waitpid(child, &state, 0) == child, "actual conffile child reaped before settlement");
        P::ParentExecutionReply reply; reply.started = true; reply.exitCode = WIFEXITED(state) ? WEXITSTATUS(state) : -1;
        reply.signal = WIFSIGNALED(state) ? WTERMSIG(state) : 0; return reply;
    };
    std::string error;
    const bool success = P::ServeProviderTransaction(socket,
        CydiaRuntime::PackageDatabasePaths::ForLayout(CydiaRuntime::PackageDatabaseLayout::Rootful), options, &error);
    const bool expected = mode == 20 || mode == 21;
    if (success != expected) std::cerr << "[transaction-service][conffile] mode=" << mode << " error=" << error << '\n';
    Require(success == expected && resolutions == 1, "v3 helper exact result and one initial authority resolution");
    Require(children == (expected ? 2u : mode == 25 ? 1u : 0u), "no premature, changed-authority or replayed child spawn");
    if (mode == 22 || mode == 23) Require(changed && error == "provider_conffile_policy_changed", "post-ACK graph/loader change stops launch");
}
void ConffileServiceScenario(unsigned mode) {
    Fixture fixture; int lock = -1; auto begin = PrepareConffileFixture(fixture, &lock, mode);
    int sockets[2]; Require(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) == 0, "v3 socketpair");
    const pid_t helper = fork(); Require(helper >= 0, "fork v3 service fixture");
    if (!helper) { close(sockets[0]); close(lock); RunConffileService(fixture, sockets[1], mode); _exit(0); }
    close(sockets[1]); TC::Channel channel(sockets[0]);
    std::string payload; Require(P::EncodeTransactionBegin(begin, &payload), "v3 reviewed begin");
    V::Request wrapped; wrapped.expected = serviceEnvironment.environment;
    Require(P::BrokerRequestPayload(serviceRegistration, payload, &wrapped.payload), "v3 protected authority wrapper");
    TC::Frame request; request.scopedChildren = request.conffilePolicy = true;
    request.reviewDigest = P::TransactionBeginDigest(begin); request.payload = V::SerializeRequest(wrapped);
    Require(channel.Send(request), "negotiate v3 policy-scoped ordinary children");
    auto response = Receive(channel);
    Require(response.success && response.scopedChildren && response.conffilePolicy, "v3 admitted without trigger effect envelope");
    request.nonce = response.nonce;
    TC::Frame firstAck;
    const bool complete = mode == 20 || mode == 21;
    for (unsigned batch = 1; batch <= (complete || mode == 25 ? 2u : 1u); ++batch) {
        P::ParentExecutionRequest execution; execution.binding = begin.review.binding; execution.batch = batch; execution.actions = {batch};
        execution.action = batch == 1 ? P::ExecutionAction::Unpack : P::ExecutionAction::Configure;
        execution.arguments = serviceEnvironment.runtime.dpkgOptions;
        execution.arguments.insert(execution.arguments.end(), {"--status-fd=99", "--no-triggers", batch == 1 ? "--unpack" : "--configure",
            batch == 1 ? begin.review.execution.archives[0].path : "sample:all"});
        request.operation = TC::Operation::Execute; ++request.sequence;
        Require(P::Encode(execution, &request.payload) && channel.Send(request), "send v3 exact reviewed operation");
        response = Receive(channel); TC::ChildDescriptor descriptor;
        Require(response.event == TC::Event::ChildNeeded && response.childOrdinal == batch &&
            TC::DecodeChildDescriptor(response.childDescriptor, &descriptor) && descriptor.purpose == TC::ChildPurpose::Primary &&
            descriptor.primaryBatch == batch && descriptor.primaryActions == execution.actions, "ordinary child scope bound to exact primary IDs");
        int input[2], status[2]; Require(socketpair(AF_UNIX, SOCK_STREAM, 0, input) == 0 && pipe(status) == 0, "real child-specific v3 pipes");
        auto answer = response; answer.event = TC::Event::ChildChannels; answer.success = true;
        Require(channel.Send(answer, {input[0], status[1]}), "provide channels before policy capture"); close(input[0]); close(status[1]);
        auto policy = Receive(channel); P::ConffilePolicyDecision decision;
        Require(policy.event == TC::Event::ChildPolicy && policy.childOrdinal == batch && policy.childDescriptor == response.childDescriptor &&
            policy.sequence == request.sequence && TC::DecodeConffilePolicy(policy.payload, &decision) && decision.match == N::Status::Matched &&
            decision.input == (mode == 21 ? CydiaRuntime::Dpkg::ConffileInputPolicy::Automatic : CydiaRuntime::Dpkg::ConffileInputPolicy::Interactive),
            "freshly matched conffile policy precedes every actual start");
        // A byte written before ACK would let a broken implementation pass.
        // Only queue the interactive reply AFTER receiving the actual Started.
        Write(fixture.root + "/policy-ack", decision.launchIdentity);
        answer = policy; answer.event = TC::Event::ChildPolicyAccepted;
        if (batch == 1) firstAck = answer;
        if (mode == 24) ++answer.childOrdinal;
        if (mode == 25 && batch == 2) answer = firstAck;
        if (mode == 26) {
            decision.launchIdentity[0] = decision.launchIdentity[0] == 'a' ? 'b' : 'a';
            Require(TC::EncodeConffilePolicy(decision, &answer.payload), "valid but mismatched policy acknowledgement");
        }
        Require(channel.Send(answer), "send exact policy acknowledgement or explicit adversarial variant");
        auto event = Receive(channel);
        const bool shouldStart = complete || (mode == 25 && batch == 1);
        if (shouldStart) {
            Require(event.event == TC::Event::ChildStarted && event.childOrdinal == batch && event.mutationStarted, "ACK precedes actual Start");
            if (mode != 21) Require(write(input[1], "N\n", 2) == 2, "reply only into acknowledged interactive child");
            event = Receive(channel);
        }
        P::ParentExecutionReply outcome;
        Require(event.event == TC::Event::ChildSettled && event.childOrdinal == batch && event.childDescriptor == policy.childDescriptor &&
            P::Decode(event.payload, &outcome) && outcome.started == shouldStart && event.mutationStarted == shouldStart &&
            (!shouldStart || !outcome.exitCode), "settlement retains exact child start and exit facts");
        std::string output; char bytes[256]; ssize_t count;
        while ((count = read(status[0], bytes, sizeof(bytes))) > 0) output.append(bytes, static_cast<std::size_t>(count));
        Require(count == 0 && (shouldStart ? output.find("child-complete\n") != std::string::npos : output.empty()),
            "actual child status or EOF without any refused-child output");
        close(input[1]); close(status[0]);
        answer = event; answer.payload.clear(); answer.event = TC::Event::ChildReleased;
        Require(channel.Send(answer), "release exact settled policy scope");
        response = Receive(channel);
        Require(response.event == TC::Event::Settled && response.success == shouldStart && response.mutationStarted == shouldStart,
            "outer result cannot conceal policy refusal or invent a child start");
    }
    if (complete) {
        P::ExtendedStateRequest commit; commit.binding = begin.review.binding; commit.changes = begin.changes;
        std::string changes; Require(P::Encode(commit, &changes), "v3 approved CAS delta");
        request.operation = TC::Operation::Commit; ++request.sequence; request.payload = V::SerializeFields({begin.extendedState, changes});
        Require(channel.Send(request) && Receive(channel).event == TC::Event::Started && Receive(channel).success, "v3 complete settlement then one CAS");
        request.operation = TC::Operation::Close; ++request.sequence; request.payload.clear();
        Require(channel.Send(request) && Receive(channel).success, "close fully settled v3 owner");
    }
    int state; Require(waitpid(helper, &state, 0) == helper && WIFEXITED(state) && !WEXITSTATUS(state), "v3 helper fully reaped");
    close(lock); fixturePolicyProducer = FixturePolicyProducer();
}

}
int main() {
    // The shared fixture's other entry points remain separate build targets.
    (void)&CaptureFiles; (void)&StagedArchives; (void)&OwnerTransactions;
    for (unsigned mode : {0u, 1u, 2u, 3u, 4u, 5u, 6u, 7u, 8u, 9u, 11u, 12u}) Scenario(mode);
    for (unsigned mode : {13u, 14u, 15u, 16u}) ScopedScenario(mode);
    for (unsigned mode : {20u, 21u, 22u, 23u, 24u, 25u, 26u}) ConffileServiceScenario(mode);
    std::cout << "[transaction-service] real owner, transport, identity, lock, fresh descriptors and settlement passed\n";
}
