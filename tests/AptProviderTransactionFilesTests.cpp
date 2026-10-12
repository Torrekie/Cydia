/* Real disposable files and .deb bytes, run under fakeroot. No host package
 * database or device is used. Copyright (C) 2026 Torrekie; GPL-3.0-or-later. */
#include "Cydia/AptProviderTransactionFiles.hpp"
#include <apt-pkg/hashes.h>
#include <apt-pkg/strutl.h>
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <fcntl.h>
#include <sys/wait.h>
#include <unistd.h>
#if defined(CYDIA_TRANSACTION_OWNER_TESTING)
#include "Cydia/AptProviderTransactionOwner.hpp"
#include "Cydia/AptProviderNativeDpkgAuthority.hpp"
#include "Cydia/RuntimeState.hpp"
#endif

namespace {
namespace P = CydiaAPT::Provider;
void Require(bool value, const char *message) {
    if (!value) { std::cerr << "[transaction-files] " << message << '\n'; std::exit(1); }
}
std::string Hash(const std::string &bytes, Hashes::SupportedHashes algorithm = Hashes::SHA256SUM) {
    Hashes hash(algorithm); Require(hash.Add(bytes.data(), bytes.size()), "hash fixture");
    return hash.GetHashString(algorithm).HashValue();
}
void Write(const std::string &path, const std::string &bytes, mode_t mode = 0644) {
    std::ofstream file(path, std::ios::binary | std::ios::trunc); file.write(bytes.data(), bytes.size()); file.close();
    Require(file.good() && chmod(path.c_str(), mode) == 0, "write fixture");
}
void Octal(char *field, std::size_t size, unsigned long long value) {
    std::snprintf(field, size, "%0*llo", static_cast<int>(size - 1), value);
}
std::string Tar(const std::string &name, const std::string &bytes) {
    char header[512] = {}; Require(name.size() < 100, "short tar fixture name");
    std::memcpy(header, name.data(), name.size());
    Octal(header + 100, 8, 0644); Octal(header + 108, 8, 0); Octal(header + 116, 8, 0);
    Octal(header + 124, 12, bytes.size()); Octal(header + 136, 12, 0);
    std::memset(header + 148, ' ', 8); header[156] = '0';
    std::memcpy(header + 257, "ustar\0", 6); std::memcpy(header + 263, "00", 2);
    unsigned checksum = 0; for (unsigned char byte : header) checksum += byte;
    Octal(header + 148, 7, checksum); header[155] = ' ';
    return std::string(header, sizeof(header)) + bytes + std::string((512 - bytes.size() % 512) % 512 + 1024, '\0');
}
std::string Ar(const std::string &name, const std::string &bytes) {
    char header[61]; std::snprintf(header, sizeof(header), "%-16s%-12d%-6d%-6d%-8o%-10llu`\n", name.c_str(), 0, 0, 0,
        0644, static_cast<unsigned long long>(bytes.size()));
    return std::string(header, 60) + bytes + (bytes.size() % 2 ? "\n" : "");
}
struct Fixture {
    std::string root, deb;
    CydiaAPT::RuntimeDescriptor runtime;
    P::ReviewedTransaction review;
    P::ReviewPolicy policy;
    Fixture() {
        std::string pattern = std::filesystem::current_path().string() + "/transaction-files.XXXXXX";
        std::vector<char> bytes(pattern.begin(), pattern.end()); bytes.push_back('\0');
        const char *created = mkdtemp(bytes.data()); Require(created != nullptr, "private fixture directory"); root = created;
        std::filesystem::create_directory(root + "/private"); std::filesystem::create_directory(root + "/lists");
        runtime.sourceListPath = root + "/sources.list"; runtime.listsDirectory = root + "/lists";
        runtime.architecture = "amd64"; runtime.registeredArchitectures = runtime.acquisitionArchitectures = {"amd64"};
        runtime.binding.providerIdentifier = review.binding.providerIdentifier = "fixture-provider";
        runtime.binding.session = review.binding.session = std::string(64, 'a');
        runtime.binding.configurationIdentity = review.binding.configurationIdentity = "config-v1";
        runtime.binding.policyIdentity = review.binding.policyIdentity = "policy-v1";
        runtime.binding.methodsIdentity = "methods-v1";
        review.binding.packageStateIdentity = "state-v1"; review.binding.cacheEpoch = review.binding.selectionRevision = 1;
        review.binding.review = "review-v1";
        auto &environment = policy.environment;
        environment.paths.dpkg = "/usr/bin/dpkg"; environment.paths.dpkgQuery = "/usr/bin/dpkg-query";
        environment.paths.dpkgDeb = "/usr/bin/dpkg-deb"; environment.paths.dpkgRoot = "/"; environment.paths.dpkgAdmin = root;
        environment.configurationIdentity = "config-v1"; environment.policyIdentity = "policy-v1";
        environment.methodsIdentity = "methods-v1"; environment.packageStateIdentity = "state-v1";
        environment.nativeArchitecture = "amd64"; environment.registeredArchitectures = environment.acquisitionArchitectures = {"amd64"};
        policy.layout = {"/", {"/var/jb"}}; policy.protectedDpkgOptions = {"--root=/", "--admindir=" + root};
        review.transaction.registeredArchitectures = {"amd64"};
        const auto identity = CydiaAPT::BuildPackageIdentity("sample", "amd64", "all", "amd64", CydiaAPT::MultiArchMode::None);
        review.transaction.installs = {identity.routingName}; review.transaction.packages[identity.routingName] = {identity, "1", "sample"};
        Write(runtime.sourceListPath, "deb https://example.invalid/ ./\n");
        deb = "!<arch>\n" + Ar("debian-binary", "2.0\n") + Ar("control.tar", Tar("control",
            "Package: sample\nVersion: 1\nArchitecture: all\nDescription: fixture\n")) +
            Ar("data.tar", Tar("usr/lib/fixture", "approved library bytes"));
        P::ArchiveManifest archive; archive.identifier = "sample"; archive.package = {"sample", "1", "all"};
        archive.sourceDefinitionPath = runtime.sourceListPath; archive.sourceURI = "https://example.invalid/";
        archive.sourceIndexURI = "https://example.invalid/./Packages";
        archive.sourceIndexPath = runtime.listsDirectory + '/' + URItoFileName(archive.sourceIndexURI);
        archive.filename = "pool/sample.deb"; archive.path = root + "/sample.deb"; archive.size = deb.size();
        archive.hashes["SHA512"] = Hash(deb, Hashes::SHA512SUM); archive.layout = policy.layout;
        const std::string record = "Package: sample\nVersion: 1\nArchitecture: all\nFilename: pool/sample.deb\nSize: " +
            std::to_string(archive.size) + "\nSHA512: " + archive.hashes["SHA512"] + "\n\n";
        archive.recordSize = record.size(); archive.sourceIndexIdentity = "SHA256:" + Hash(record);
        Write(archive.sourceIndexPath, record); Write(archive.path, deb); review.execution.archives.push_back(archive);
        P::ReviewedAction unpack; unpack.identifier = 1; unpack.action = P::ExecutionAction::Unpack;
        unpack.package = archive.package; unpack.archive = archive.identifier;
        review.execution.actions.push_back(unpack); unpack.identifier = 2; unpack.action = P::ExecutionAction::Configure;
        unpack.archive.clear(); review.execution.actions.push_back(unpack);
    }
    ~Fixture() { std::filesystem::remove_all(root); }
    bool Begin(P::TransactionArchiveStore &store, std::string *error, const std::function<bool()> &cancelled = {}) {
        return store.Begin(root + "/private", runtime, review, policy, "/usr/bin:/bin",
            {{"sample", {"/usr/lib/fixture"}}}, error, cancelled);
    }
};
void CaptureFiles() {
    Fixture fixture; std::string error; const std::string path = fixture.root + "/component";
    Write(path, "component", 0755); P::InstalledComponentEvidence first, changed;
    Require(P::CaptureTransactionComponent(path, &first, &error) && first.file.sha256 == Hash("component") &&
        first.file.metadata.size == 9 && first.file.metadata.mode == 0755 && first.links == 1, "actual protected file bytes and metadata");
    Require(P::CaptureTransactionComponent(path, &changed, &error) && P::SameInstalledComponent(first, changed), "stable repeated file capture");
    Write(path, "changed", 0755);
    Require(P::CaptureTransactionComponent(path, &changed, &error) && !P::SameInstalledComponent(first, changed), "file content change is visible");
    const auto alias = fixture.root + "/alias";
    Require(link(path.c_str(), alias.c_str()) == 0 && !P::CaptureTransactionComponent(path, &changed, &error), "hardlinked component rejected");
    Require(unlink(alias.c_str()) == 0 && symlink("component", alias.c_str()) == 0 &&
        !P::CaptureTransactionComponent(alias, &changed, &error), "final symlink rejected");
    Require(!P::CaptureTransactionComponent(path, &changed, &error, [] { return true; }), "cancelled file read refused");
    Require(chmod(path.c_str(), 0775) == 0 && !P::CaptureTransactionComponent(path, &changed, &error), "writable component rejected");
}
void StagedArchives() {
    for (unsigned variant = 0; variant != 5; ++variant) {
        Fixture fixture; P::TransactionArchiveStore store; std::string error;
        Require(fixture.Begin(store, &error), error.c_str());
        Require(store.archives().size() == 1 && store.successors().size() == 1, "all archives and payload evidence retained");
        const auto &archive = store.archives()[0]; const auto path = archive.copy.identity.file.metadata.path;
        Require(path != fixture.review.execution.archives[0].path && archive.copy.identity.file.metadata.mode == 0600 &&
            archive.copy.hashes.at("SHA512") == Hash(fixture.deb, Hashes::SHA512SUM) &&
            archive.copy.hashes.at("SHA256") == Hash(fixture.deb) &&
            store.successors()[0].payload.files.at("/usr/lib/fixture").sha256 == Hash("approved library bytes"),
            "actual SHA512-only source and payload hashes preserved");
        std::vector<P::StagedArchiveEvidence> observed;
        Require(store.Capture(&observed, &error) && observed.size() == 1, "unchanged retained descriptors recheck");
        switch (variant) {
            case 0: Write(path, "wrong", 0600); break;
            case 1: Require(unlink(path.c_str()) == 0, "unlink stage"); Write(path, fixture.deb, 0600); break;
            case 2: Require(chmod(path.c_str(), 0644) == 0, "change stage mode"); break;
            case 3: Require(link(path.c_str(), (store.directory() + "/alias").c_str()) == 0, "alias stage"); break;
            case 4: Require(!store.Capture(&observed, &error, [] { return true; }), "cancelled retained capture"); continue;
        }
        Require(!store.Capture(&observed, &error) && observed.empty(), "changed staged bytes/inode/mode/links rejected");
    }
    Fixture changed; P::TransactionArchiveStore refused; std::string error;
    Write(changed.review.execution.archives[0].path, "corrupt");
    Require(!changed.Begin(refused, &error), "bad archive cannot create ready store");
    Fixture cancelled; P::TransactionArchiveStore noStore;
    Require(!cancelled.Begin(noStore, &error, [] { return true; }) && noStore.archives().empty(), "cancel before staging leaves no ready evidence");
}
}
#if defined(CYDIA_TRANSACTION_OWNER_TESTING)
// Linux cannot load Darwin executables. This target alone replaces the native
// declaration/loader producers with explicit fixture authority for isolated
// query scripts. Every owner, archive, state, lock, child and CAS path is real.
// Production links AptProviderNativeDpkgAuthority.cpp instead of these symbols.
namespace {
P::NativeDpkgAuthority fixtureAuthority;
bool fixtureAuthorityAvailable = true;
}
namespace CydiaAPT { namespace Provider {
bool ResolveNativeDpkgAuthority(const BrokerEnvironment &, const ReviewedTransaction &, NativeDpkgAuthority *out,
    std::string *error, const std::function<bool()> &) {
    if (!fixtureAuthorityAvailable) { if (error) *error = "provider_native_configuration_missing"; return false; }
    *out = fixtureAuthority; return true;
}
bool RevalidateNativeDpkgAuthority(const NativeDpkgAuthority &authority, const std::vector<InstalledComponentEvidence> &files,
    std::string *error) {
    CydiaRuntime::Privileged::Error ignored;
    if (!CydiaRuntime::Privileged::RecheckEvidence(authority.configurationEvidence, &ignored)) return false;
    for (const auto &file : files) {
        const auto expected = authority.executorGenerations.find(file.file.metadata.path);
        if (expected == authority.executorGenerations.end() || !expected->second.count(file.file.sha256)) {
            if (error) *error = "fixture_generation_changed";
            return false;
        }
    }
    return true;
}
bool CaptureNativeDpkgClosure(const NativeDpkgAuthority &authority, const std::string &executable,
    const std::vector<InstalledComponentEvidence> &files, ComponentClosureEvidence *proof, std::string *error,
    const std::function<bool()> &cancelled) {
    if (!RevalidateNativeDpkgAuthority(authority, files, error) || (cancelled && cancelled())) return false;
    *proof = ComponentClosureEvidence(); proof->executable = executable;
    proof->nativeConfigurationIdentity = authority.configurationIdentity; proof->platformIdentity = authority.platformIdentity;
    for (const auto &file : files) if (file.file.metadata.path == executable) {
        InstalledComponentEvidence actual;
        if (!CaptureTransactionComponent(executable, &actual, error, cancelled) || !SameInstalledComponent(file, actual)) return false;
        ComponentClosureNode node; node.file = file; proof->nodes.push_back(node); return true;
    }
    return false;
}
}}
namespace {
P::TransactionLeaseEnvelope Envelope(std::uint64_t sequence) {
    P::TransactionLeaseEnvelope value; value.sequence = sequence;
    value.nonce = std::string(64, '1'); value.reviewDigest = std::string(64, '2'); return value;
}
void OwnerChild(Fixture &fixture, const P::TransactionOwnerOptions &provided, unsigned mode) {
    auto options = provided; P::TransactionOwner *ownerPointer = nullptr; unsigned executions = 0, notifications = 0;
    unsigned effectScopes = 0, effectStarts = 0, effectSettlements = 0;
    const bool effects = mode >= 6;
    options.authenticate = [options](CydiaRuntime::Privileged::ApplicationProcessIdentity *app, uid_t *uid, std::string *) {
        *app = options.application; *uid = options.applicationUID; return true;
    };
    if (effects && mode != 7) options.effectChildChannels = [&](const P::TriggerDrainPlan &plan,
        P::TransactionEffectChildChannels *channels, std::string *) {
        Require(plan.targets.size() == 1 && plan.targets[0].package == "cache" && plan.targets[0].architecture == "amd64",
            "helper selects complete exact pending targets without worker argv");
        auto descriptors = std::make_shared<std::vector<int>>(4);
        Require(pipe(descriptors->data()) == 0 && pipe(descriptors->data() + 2) == 0, "fresh effect-only child channels");
        ++effectScopes; channels->inputDescriptor = (*descriptors)[0]; channels->statusDescriptor = (*descriptors)[3];
        channels->started = [&] { ++effectStarts; };
        channels->settled = [&, descriptors](const P::ParentExecutionReply &reply) {
            Require(reply.started, "effect channel closes only after actual child was reaped");
            for (int fd : *descriptors) close(fd); ++effectSettlements;
        };
        return true;
    };
    options.execute = [&](const std::string &, const std::vector<std::string> &arguments, int, int,
        const std::function<void()> &started) {
        ++executions;
        const bool configure = std::find(arguments.begin(), arguments.end(), "--configure") != arguments.end();
        const bool drain = std::find(arguments.begin(), arguments.end(), "--triggers-only") != arguments.end();
        const pid_t child = fork(); Require(child >= 0, "spawn isolated transaction child");
        if (child == 0) {
            const std::string status = configure ? "installed" : "unpacked";
            const bool pending = effects && !configure && (!drain || mode == 8);
            std::string control = "Package: sample\nVersion: 1\nArchitecture: all\nStatus: install ok " + status + '\n';
            if (pending) control += "Triggers-Awaited: cache:amd64\n";
            control += '\n';
            std::string rows = "sample\t1\tall\tinstall ok " + status + "\tno\t\t" + (pending ? "cache:amd64" : "") + '\n';
            if (effects) {
                control += std::string("Package: cache\nVersion: 1\nArchitecture: amd64\nStatus: install ok ") +
                    (pending ? "triggers-pending\nTriggers-Pending: cache-refresh\n\n" : "installed\n\n");
                rows += std::string("cache\t1\tamd64\tinstall ok ") +
                    (pending ? "triggers-pending\tno\tcache-refresh\t\n" : "installed\tno\t\t\n");
                Write(options.selected.environment.dpkgAdmin + "/triggers/Unincorp", pending ? "cache-refresh sample:all\n" : "");
            }
            Write(options.selected.environment.dpkgAdmin + "/status", control);
            Write(options.selected.environment.dpkgQuery + ".rows", rows);
            _exit(mode == 4 || (mode == 8 && drain) ? 1 : 0);
        }
        started();
        if (mode == 2) ownerPointer->Cancel();
        if (mode == 3) ownerPointer->TransportLost();
        int status; Require(waitpid(child, &status, 0) == child, "reap isolated child despite cancellation");
        P::ParentExecutionReply result; result.started = true;
        result.exitCode = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
        result.signal = WIFSIGNALED(status) ? WTERMSIG(status) : 0; return result;
    };
    P::TransactionOwner owner(options); ownerPointer = &owner; std::string error;
    if (mode == 7) {
        Require(!owner.Begin(&error) && error == "provider_trigger_child_channels_unavailable" && !executions,
            "approved effect pool alone cannot reuse another child input scope"); return;
    }
    if (mode == 5) {
        fixtureAuthorityAvailable = false;
        Require(!owner.Begin(&error) && error == "provider_native_configuration_missing" && executions == 0 && !owner.mutationStarted(),
            "missing distribution declaration is not mutation-ready"); return;
    }
    Require(owner.Begin(&error), error.c_str());
    if (mode == 1) {
        for (const auto &directory : std::filesystem::directory_iterator(fixture.root + "/private"))
            if (directory.is_directory()) Write(directory.path().string() + "/0.deb", "tampered", 0600);
        P::DpkgState state;
        Require(!owner.Capture(Envelope(1), &state, &error) && executions == 0 && !owner.mutationStarted(),
            "real staged-copy tampering blocks the first child"); return;
    }
    P::ParentExecutionRequest request; request.binding = options.review.binding; request.batch = 1;
    request.action = P::ExecutionAction::Unpack; request.actions = {1}; request.arguments = options.policy.protectedDpkgOptions;
    request.arguments.insert(request.arguments.end(), {"--status-fd=99", "--no-triggers", "--unpack", options.review.execution.archives[0].path});
    int input[2], status[2]; Require(pipe(input) == 0 && pipe(status) == 0, "real child channels");
    P::ParentExecutionReply result; P::DpkgState after;
    const bool success = owner.Execute(Envelope(1), request, input[0], status[1], &result, &after, &error, {}, [&] {
        Require(owner.mutationStarted(), "notification follows actual spawn record"); ++notifications;
    });
    Require(notifications == (effects ? 2u : 1u), "one observed notification per actual child");
    if ((mode >= 2 && mode <= 4) || mode == 8) {
        Require(!success && owner.mutationStarted() && executions == (effects ? 2u : 1u) && owner.indeterminate() == (mode == 3),
            "started failed/cancelled/lost child retains irreversible outcome");
        Require(!owner.Execute(Envelope(1), request, input[0], status[1], &result, &after, &error) && executions == (effects ? 2u : 1u),
            "failed child cannot replay");
    } else {
        Require(success && after.packages.at("sample:all").status == P::DpkgPackageStatus::Unpacked, error.c_str());
        if (effects) Require(after.packages.at("cache:amd64").status == P::DpkgPackageStatus::Installed &&
            after.packages.at("sample:all").triggersAwaited.empty(), "owner returns quiescent effect state before next primary request");
        request.batch = 2; request.action = P::ExecutionAction::Configure; request.actions = {2};
        request.arguments = options.policy.protectedDpkgOptions;
        request.arguments.insert(request.arguments.end(), {"--status-fd=99", "--no-triggers", "--configure", "sample:all"});
        Require(owner.Execute(Envelope(2), request, input[0], status[1], &result, &after, &error, {}, [&] { ++notifications; }), error.c_str());
        Require(owner.Commit(Envelope(3), options.changes, options.expectedExtendedState, &error, [&] { ++notifications; }) &&
            owner.complete() && notifications == (effects ? 4u : 3u), error.c_str());
        Require(!owner.Commit(Envelope(4), options.changes, options.expectedExtendedState, &error) && owner.complete(), "completed CAS not replayed");
    }
    Require(owner.Close(&error), "settled owner closes");
    if (effects) Require(effectScopes == 1 && effectStarts == 1 && effectSettlements == 1,
        "effect child has an independent scope and settles exactly once");
    close(input[0]); close(input[1]); close(status[0]); close(status[1]);
}
void OwnerTransactions() {
    for (unsigned mode = 0; mode != 9; ++mode) {
        Fixture fixture; P::TransactionOwnerOptions options;
        const auto admin = fixture.root + "/admin"; std::filesystem::create_directory(admin);
        std::filesystem::create_directory(admin + "/updates");
        Write(admin + "/status", ""); Write(fixture.root + "/extended_states", "");
        Write(fixture.root + "/dpkg", "#!/bin/sh\nfor arg do\ncase \"$arg\" in\n--print-architecture) printf 'amd64\\n'; exit 0;;\n--print-foreign-architectures) exit 0;;\nesac\ndone\nexit 1\n", 0755);
        Write(fixture.root + "/dpkg-query", "#!/bin/sh\nexec /bin/cat \"$0.rows\"\n", 0755);
        Write(fixture.root + "/dpkg-query.rows", ""); Write(fixture.root + "/native.conf", "fixture native graph\n");
        if (mode >= 6) {
            std::filesystem::create_directory(admin + "/info"); std::filesystem::create_directory(admin + "/triggers");
            Write(admin + "/status", "Package: cache\nVersion: 1\nArchitecture: amd64\nStatus: install ok installed\n\n");
            Write(fixture.root + "/dpkg-query.rows", "cache\t1\tamd64\tinstall ok installed\tno\t\t\n");
            Write(admin + "/info/cache.triggers", "interest-await cache-refresh\n");
            Write(admin + "/triggers/Lock", "", 0600); Write(admin + "/triggers/Unincorp", "");
            Write(admin + "/triggers/cache-refresh", "cache:amd64\n");
        }
        options.selected.runtime = fixture.runtime;
        auto &environment = options.selected.environment;
        environment.dpkg = fixture.root + "/dpkg"; environment.dpkgQuery = fixture.root + "/dpkg-query";
        environment.dpkgDeb = "/usr/bin/dpkg-deb"; environment.dpkgRoot = "/"; environment.dpkgAdmin = admin;
        environment.sourceList = fixture.runtime.sourceListPath; environment.extendedStates = fixture.root + "/extended_states";
        options.selected.executableSearchPath = options.selected.archiveDecoderSearchPath = "/usr/bin:/bin";
        options.selected.runtime.dpkgOptions = {"--root=/", "--admindir=" + admin};
        options.selected.runtime.packageInstallPrefix = "/";
        options.privateStateDirectory = fixture.root + "/private";
        options.application = {std::to_string(getpid()), "10.1", "20.2", std::string(40, 'a')}; options.applicationUID = getuid();
        options.nonce = std::string(64, '1'); options.reviewDigest = std::string(64, '2');
        options.policy = fixture.policy; options.policy.environment.paths = environment;
        options.policy.protectedDpkgOptions = options.selected.runtime.dpkgOptions;
        options.review = fixture.review; options.changes = {{"sample", "amd64", true}};
        const int lock = open((admin + "/lock-frontend").c_str(), O_CREAT | O_RDWR, 0600);
        struct stat identity; struct flock request = {}; request.l_type = F_WRLCK; request.l_whence = SEEK_SET;
        Require(lock >= 0 && fstat(lock, &identity) == 0 && fcntl(lock, F_SETLK, &request) == 0, "parent holds actual frontend lock");
        options.lock.device = identity.st_dev; options.lock.inode = identity.st_ino;
        CydiaRuntime::Privileged::Error ignored;
        Require(CydiaRuntime::Privileged::RuntimeSnapshot(environment, &options.review.binding.packageStateIdentity, &ignored), "initial full native snapshot");
        options.selected.runtime.binding.packageStateIdentity = options.review.binding.packageStateIdentity;
        options.policy.environment.packageStateIdentity = options.review.binding.packageStateIdentity;
        if (mode >= 6) {
            std::string error; P::DpkgState initial; P::TriggerEffectCheckpoint checkpoint; P::TriggerCaptureLock held; held.descriptor = lock;
            Require(P::ParseDpkgState("cache\t1\tamd64\tinstall ok installed\tno\t\t\n", "amd64\n", "",
                options.review.binding.packageStateIdentity, &initial, &error) &&
                P::CaptureTriggerEffectCheckpoint(environment, initial, held, &checkpoint, &error), "capture native review recipients");
            auto approved = std::make_shared<P::TriggerEffectEnvelope>();
            Require(P::BuildTriggerEffectEnvelope(options.review, checkpoint, approved.get(), &error), "build immutable native-reviewed effect pool");
            options.reviewedEffects = approved;
        }
        fixtureAuthority = P::NativeDpkgAuthority(); fixtureAuthorityAvailable = true;
        fixtureAuthority.configurationIdentity = Hash("fixture native graph\n"); fixtureAuthority.platformIdentity = std::string(64, 'a');
        CydiaRuntime::Privileged::Evidence config;
        Require(CydiaRuntime::Privileged::CaptureEvidence(fixture.root + "/native.conf", false, false, &config, &ignored), "capture fixture declaration");
        fixtureAuthority.configurationEvidence = {config}; fixtureAuthority.componentPaths = {environment.dpkg, environment.dpkgQuery};
        for (const auto &path : fixtureAuthority.componentPaths) {
            P::InstalledComponentEvidence file; std::string error;
            Require(P::CaptureTransactionComponent(path, &file, &error), "capture fixture executable bytes");
            fixtureAuthority.executorGenerations[path].insert(file.file.sha256);
        }
        const pid_t child = fork(); Require(child >= 0, "fork direct helper owner");
        if (child == 0) { close(lock); OwnerChild(fixture, options, mode); _exit(0); }
        int status; Require(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0,
            "isolated helper owner scenario");
        close(lock);
    }
}
}
#endif
#if !defined(CYDIA_TRANSACTION_FILES_FIXTURE_ONLY)
int main() {
    CaptureFiles(); StagedArchives();
#if defined(CYDIA_TRANSACTION_OWNER_TESTING)
    OwnerTransactions();
#endif
    std::cout << "[transaction-files] protected copies, payload bytes, SHA512, tamper and cancellation passed\n";
}
#endif
