/* Protected native declaration and actual Mach-O byte fixtures. The sole
 * substitutions are declaration locations and a fixed host-test target/cache;
 * no executable is loaded and no package database is modified.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderNativeDpkgAuthority.hpp"
#include "Cydia/AptProviderConffilePolicy.hpp"
#include "Cydia/AptProviderComponentCapture.hpp"
#include "Cydia/AptRecoveryDependencyInspector.hpp"
#include "Cydia/AptRecoveryMachO.hpp"
#include <apt-pkg/hashes.h>
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <sys/stat.h>
#include <unistd.h>
#ifndef CYDIA_NATIVE_DPKG_AUTHORITY_TESTING
#error This fixture requires the explicit declaration-location/platform test seam.
#endif
namespace {
namespace A = CydiaAPT::Provider;
namespace R = CydiaAPT::Recovery;
namespace P = CydiaRuntime::Privileged;
namespace N = A::NativeEffectPolicy;
void Require(bool value, const char *message) {
    if (!value) { std::fprintf(stderr, "[native-dpkg-authority] %s\n", message); std::exit(1); }
}
std::string Hash(const std::string &bytes) {
    Hashes hash(Hashes::SHA256SUM); Require(hash.Add(bytes.data(), bytes.size()), "hash fixture bytes");
    return hash.GetHashString(Hashes::SHA256SUM).HashValue();
}
void Write(const std::string &path, const std::string &bytes, mode_t mode = 0644) {
    std::ofstream stream(path, std::ios::binary | std::ios::trunc); stream.write(bytes.data(), bytes.size()); stream.close();
    Require(stream.good() && chmod(path.c_str(), mode) == 0, "write protected fixture");
}
void Word(std::string &bytes, std::size_t offset, uint32_t value) {
    Require(offset <= bytes.size() && bytes.size() - offset >= 4, "fixture word in range");
    for (unsigned index = 0; index != 4; ++index) bytes[offset + index] = value >> (8 * index);
}
std::string Command(uint32_t kind, std::size_t size) {
    std::string bytes(size, '\0'); Word(bytes, 0, kind); Word(bytes, 4, size); return bytes;
}
std::string StringCommand(uint32_t kind, const std::string &text, unsigned header = 12) {
    auto bytes = Command(kind, (header + text.size() + 8) & ~std::size_t(7));
    Word(bytes, 8, header); bytes.replace(header, text.size(), text); return bytes;
}
std::string Dylib(uint32_t kind, const std::string &name, uint32_t current = 0x20000) {
    auto bytes = StringCommand(kind, name, 24); Word(bytes, 16, current); Word(bytes, 20, 0x10000); return bytes;
}
std::string Image(bool executable, const std::vector<std::string> &dependencies = {},
    const std::vector<std::string> &rpaths = {}, uint32_t current = 0x20000, uint32_t cpu = 0x100000c) {
    auto segment = Command(0x19, 72); segment.replace(8, 6, "__TEXT"); Word(segment, 60, 5);
    auto platform = Command(0x32, 24); Word(platform, 8, 2); Word(platform, 12, 0xc0000);
    std::vector<std::string> commands{segment, platform};
    commands.push_back(executable ? StringCommand(0xe, "/usr/lib/dyld") : Dylib(0xd, "@rpath/libfixture.dylib", current));
    for (const auto &path : rpaths) commands.push_back(StringCommand(0x8000001c, path));
    for (const auto &path : dependencies) commands.push_back(Dylib(0xc, path));
    if (executable) commands.push_back(Command(0x80000028u, 24));
    std::string bytes(32, '\0'); Word(bytes, 0, 0xfeedfacf); Word(bytes, 4, cpu);
    Word(bytes, 12, executable ? 2 : 6); Word(bytes, 16, commands.size()); Word(bytes, 24, 0x80);
    for (const auto &command : commands) bytes += command;
    Word(bytes, 20, bytes.size() - 32);
    if (executable) Word(bytes, bytes.size() - 16, bytes.size());
    bytes += std::string(4, '\0'); Word(bytes, 32 + 48, bytes.size()); Word(bytes, 32 + 32, bytes.size()); return bytes;
}
struct Fixture {
    std::string root, primary, fallback, program, query, library, optional;
    std::map<std::string, std::string> bytes;
    A::BrokerEnvironment selected;
    A::ReviewedTransaction review;
    std::vector<std::string> fields, components, commands;
    Fixture() {
        std::string pattern = std::filesystem::current_path().string() + "/native-dpkg-authority.XXXXXX";
        std::vector<char> buffer(pattern.begin(), pattern.end()); buffer.push_back('\0');
        const char *created = mkdtemp(buffer.data()); Require(created, "fixture directory"); root = created;
        for (const char *name : {"bin", "lib", "conf", "conf.d"}) std::filesystem::create_directory(root + '/' + name);
        primary = root + "/native-dpkg.conf"; fallback = root + "/fallback.conf";
        program = root + "/bin/dpkg"; query = root + "/bin/dpkg-query"; library = root + "/lib/libfixture.dylib";
        optional = root + "/conf/optional";
        Put(program, Image(true, {"@rpath/libfixture.dylib"}, {"@executable_path/../lib"}));
        Put(query, Image(true)); Put(library, Image(false));
        components = {program, query, library};
        Write(root + "/conf/dpkg", "no-force\n"); Write(root + "/conf.d/a", "log configured\n");
        selected.environment.dpkg = program; selected.environment.dpkgQuery = query;
        selected.environment.dpkgRoot = "/"; selected.environment.dpkgAdmin = root + "/admin";
        selected.executableSearchPath = root + "/bin:/usr/bin:/bin";
        A::ArchiveManifest archive; archive.identifier = "dpkg-archive"; archive.package = {"dpkg", "2", "iphoneos-arm64"};
        review.execution.archives.push_back(archive);
        R::SetTransactionTargetForTesting({0x100000c, 0, 2, 0x100000});
        A::SetNativeDpkgAuthorityTestPaths(primary, fallback); Declaration();
    }
    ~Fixture() { std::filesystem::remove_all(root); }
    void Put(const std::string &path, const std::string &value) { bytes[path] = value; Write(path, value, 0755); }
    void Declaration() {
        std::vector<std::string> executors{program, Hash(bytes.at(program)), query, Hash(bytes.at(query))};
        for (const auto &command : commands) { executors.push_back(command); executors.push_back(Hash(bytes.at(command))); }
        fields = {"CYDIA-NATIVE-DPKG-1", P::SerializeFields(executors), P::SerializeFields({root + "/conf/dpkg"}),
            P::SerializeFields({root + "/conf.d"}), P::SerializeFields({optional}), "", P::SerializeFields(commands),
            P::SerializeFields(components), P::SerializeFields({"dpkg:iphoneos-arm64", P::SerializeFields({program})}), "complete-native-graph"};
        Save();
    }
    void Save() { Write(primary, P::SerializeFields(fields)); }
    bool Resolve(A::NativeDpkgAuthority *authority, std::string *error, const std::function<bool()> &cancelled = {}) {
        return A::ResolveNativeDpkgAuthority(selected, review, authority, error, cancelled);
    }
    std::vector<A::InstalledComponentEvidence> Capture() {
        std::vector<A::InstalledComponentEvidence> result; std::string error;
        for (const auto &path : components) {
            A::InstalledComponentEvidence file;
            Require(A::CaptureTransactionComponent(path, &file, &error), "capture real component identity"); result.push_back(file);
        }
        return result;
    }
};
void Declarations() {
    {
        Fixture f; A::NativeDpkgAuthority authority; std::string error;
        Require(f.Resolve(&authority, &error), error.c_str());
        Require(authority.configurationIdentity.size() == 64 && authority.platformIdentity.size() == 64 &&
            authority.successorPaths.at("dpkg-archive") == std::vector<std::string>{f.program}, "real declaration derives identities and exact archive successor association");
        Require(A::RevalidateNativeDpkgAuthority(authority, f.Capture(), &error), "unchanged declaration and graph revalidate");
        Require(authority.launchEnvironment.initialized() &&
            std::find(authority.launchEnvironment.entries().begin(), authority.launchEnvironment.entries().end(), "PATH=" + f.selected.executableSearchPath) != authority.launchEnvironment.entries().end() &&
            std::find(authority.launchEnvironment.entries().begin(), authority.launchEnvironment.entries().end(), "DPKG_FRONTEND_LOCKED=1") != authority.launchEnvironment.entries().end(),
            "authority captures exact selected path and parent-lock overlay");
        auto changedEnvironment = authority;
        Require(changedEnvironment.launchEnvironment.Overlay({"PATH=" + f.selected.executableSearchPath + ":/changed"}, {}, &changedEnvironment.launchEnvironment) &&
            !A::RevalidateNativeDpkgAuthority(changedEnvironment, f.Capture(), &error),
            "launch environment cannot change behind its retained binding");
        Write(f.optional, "new optional native policy\n");
        Require(!A::RevalidateNativeDpkgAuthority(authority, f.Capture(), &error), "previously absent native configuration cannot appear during a lease");
    }
    {
        Fixture f; A::NativeDpkgAuthority authority; std::string error;
        Require(f.Resolve(&authority, &error), "directory configuration captures"); Write(f.root + "/conf.d/a", "changed\n");
        Require(!A::RevalidateNativeDpkgAuthority(authority, f.Capture(), &error), "declared directory contents are read and rechecked");
    }
    {
        Fixture f; A::NativeDpkgAuthority authority; std::string error;
        Require(rename(f.primary.c_str(), f.fallback.c_str()) == 0 && f.Resolve(&authority, &error), "absent primary allows protected distribution declaration");
        Write(f.primary, "bad declaration");
        Require(!f.Resolve(&authority, &error) && error == "provider_native_configuration_invalid" && authority.configurationIdentity.empty(),
            "present invalid primary never falls through or retains stale authority");
        Require(unlink(f.primary.c_str()) == 0 && unlink(f.fallback.c_str()) == 0 && !f.Resolve(&authority, &error) &&
            error == "provider_native_configuration_missing", "missing declaration remains explicitly unsupported");
    }
    for (unsigned variant = 0; variant != 9; ++variant) {
        Fixture f; A::NativeDpkgAuthority authority; std::string error;
        switch (variant) {
            case 0: f.fields[0] = "CYDIA-NATIVE-DPKG-2"; f.Save(); break;
            case 1: f.fields[1] = P::SerializeFields({f.program, std::string(64, 'z'), f.query, Hash(f.bytes[f.query])}); f.Save(); break;
            case 2: f.fields[7] = P::SerializeFields({f.program, f.query, f.library, f.library}); f.Save(); break;
            case 3: f.fields[2] = P::SerializeFields({f.root + "/conf/../conf/dpkg"}); f.Save(); break;
            case 4: f.fields[8] = P::SerializeFields({"dpkg:any", P::SerializeFields({f.program})}); f.Save(); break;
            case 5: f.fields[9] = "partial-graph"; f.Save(); break;
            case 6: Require(chmod(f.primary.c_str(), 0664) == 0, "make declaration writable"); break;
            case 7: Write(f.program, Image(true), 0755); break;
            case 8: Require(chmod((f.root + "/conf/dpkg").c_str(), 0664) == 0, "make native input writable"); break;
        }
        Require(!f.Resolve(&authority, &error) && authority.configurationIdentity.empty() && !error.empty(),
            "invalid, unprotected or binary-mismatched declaration never produces authority");
    }
    {
        Fixture f; A::NativeDpkgAuthority authority; std::string error;
        const auto valid = P::SerializeFields(f.fields);
        for (std::size_t size : {std::size_t(0), std::size_t(1), valid.size()/2, valid.size()-1}) {
            Write(f.primary, valid.substr(0, size)); Require(!f.Resolve(&authority, &error), "truncated netstrings refuse");
        }
        f.Save(); Require(!f.Resolve(&authority, &error, [] { return true; }), "cancel before protected declaration admission");
    }
}
void ConfiguredAutomaticDeconfiguration() {
    const std::vector<std::string> configured{"auto-deconfigure\n", "auto-deconfigure  \n", "auto-deconfigure=# value\n",
        "\t--auto-deconfigure\n", "# harmless comment\nauto-deconfigure\n"};
    for (const auto &bytes : configured) {
        Fixture f; A::NativeDpkgAuthority authority; std::string error;
        A::ReviewedAction unpack; unpack.identifier = 1; unpack.action = A::ExecutionAction::Unpack;
        unpack.package = f.review.execution.archives.front().package; unpack.archive = "dpkg-archive";
        f.review.execution.actions = {unpack}; Write(f.root + "/conf.d/a", bytes);
        Require(!f.Resolve(&authority, &error) && error == "provider_native_auto_deconfigure_unsupported" &&
            authority.configurationIdentity.empty() && authority.configurationEvidence.empty(),
            "configured automatic deconfiguration cannot bypass absent argv switch or publish authority");
        f.review.execution.actions.front().action = A::ExecutionAction::Configure;
        Require(f.Resolve(&authority, &error), "known Unpack effect does not forbid an unrelated Configure review");
    }
    for (const char *bytes : {"# auto-deconfigure\n", "  # --auto-deconfigure\n", "pre-invoke echo auto-deconfigure\n",
        "log /auto-deconfigure\n", "auto-deconfigure-extra\n", "\n"}) {
        Fixture f; A::NativeDpkgAuthority authority; std::string error;
        A::ReviewedAction unpack; unpack.identifier = 1; unpack.action = A::ExecutionAction::Unpack;
        f.review.execution.actions = {unpack}; Write(f.root + "/conf/dpkg", bytes);
        Require(f.Resolve(&authority, &error), "comments and other option values do not become automatic deconfiguration");
    }
}
std::vector<std::string> Prefix(const Fixture &f) {
    return {"--root=" + f.selected.environment.dpkgRoot, "--admindir=" + f.selected.environment.dpkgAdmin,
        "--no-triggers", "--status-fd=3", "--unpack"};
}
N::Inputs EffectInputs(Fixture &f, const A::NativeDpkgAuthority &authority) {
    N::Inputs inputs; std::string error;
    Require(A::BuildNativeEffectPolicyInputs(authority, f.program, f.Capture(), "dpkg-1.23.7-effects-1",
        N::Role::Unpack, Prefix(f), &inputs, &error), error.c_str());
    return inputs;
}
N::Record EffectRecord(Fixture &f, const A::NativeDpkgAuthority &authority) {
    const auto inputs = EffectInputs(f, authority); N::Record record;
    record.semanticProfile = inputs.semanticProfile; record.executorPath = inputs.executorPath;
    record.executorSHA256 = inputs.executorSHA256; record.role = inputs.role; record.optionPrefix = inputs.optionPrefix;
    Require(N::InputIdentity(inputs, Hash, &record.inputIdentity), "hash independently captured content-only native inputs");
    record.settings.triggers = N::TriggerMode::Disabled; record.settings.abortAfter = 50; record.settings.statusDescriptors = {3};
    return record;
}
void VersionTwo(Fixture &f, const std::string &container) {
    f.fields.resize(10); f.fields[0] = "CYDIA-NATIVE-DPKG-2";
    f.fields.push_back(container); f.fields.push_back("complete-native-effect-policy"); f.Save();
}
void VersionTwo(Fixture &f, const std::vector<N::Record> &records) {
    std::string container; Require(N::EncodeRecords(records, &container), "encode bounded protected effect fixture");
    VersionTwo(f, container);
}
N::Match Match(Fixture &f, const A::NativeDpkgAuthority &authority) {
    std::string error;
    return A::MatchNativeEffectPolicy(authority, f.program, f.Capture(), "dpkg-1.23.7-effects-1",
        N::Role::Unpack, Prefix(f), &error);
}
void ConffilePolicyCapture() {
    namespace D = CydiaRuntime::Dpkg;
    for (const auto force : {N::Force::Confold, N::Force::Confnew, N::Force::Confdef}) {
        Fixture f; A::NativeDpkgAuthority authority; std::string error;
        Write(f.root + "/conf/dpkg", force == N::Force::Confold ? "force-confold\n" :
            (force == N::Force::Confnew ? "force-confnew\n" : "force-confdef\n"));
        Require(f.Resolve(&authority, &error), "capture actual configured force input");
        auto prefix = Prefix(f); prefix.back() = "--configure";
        N::Inputs inputs;
        Require(A::BuildNativeEffectPolicyInputs(authority, f.program, f.Capture(), "dpkg-1.23.7-effects-1",
            N::Role::Configure, prefix, &inputs, &error), "capture configure input and frozen environment");
        N::Record record; record.semanticProfile = inputs.semanticProfile; record.executorPath = inputs.executorPath;
        record.executorSHA256 = inputs.executorSHA256; record.role = inputs.role; record.optionPrefix = prefix;
        Require(N::InputIdentity(inputs, Hash, &record.inputIdentity), "bind exact config force record");
        record.settings.forces = {force}; record.settings.statusDescriptors = {3};
        VersionTwo(f, std::vector<N::Record>{record});
        Require(f.Resolve(&authority, &error), "resolve protected policy record");
        auto arguments = prefix; arguments.push_back("sample:arm64");
        A::ConffilePolicyDecision decision;
        Require(A::CaptureConffilePolicy(authority, f.program, f.Capture(), N::Role::Configure, arguments, prefix.size(),
            &decision, &error) && decision.match == N::Status::Matched && decision.input == D::ConffileInputPolicy::Automatic,
            "configuration-supplied force choice suppresses native question input");
        const auto first = decision;
        arguments.back() = "another:arm64";
        Require(A::CaptureConffilePolicy(authority, f.program, f.Capture(), N::Role::Configure, arguments, prefix.size(), &decision, &error) &&
            decision.inputIdentity == first.inputIdentity && decision.launchIdentity != first.launchIdentity,
            "complete actual child operands belong to launch binding rather than policy lookup");
        Write(f.root + "/conf/dpkg", "# policy changed\n");
        Require(!A::CaptureConffilePolicy(authority, f.program, f.Capture(), N::Role::Configure, arguments, prefix.size(), &decision, &error) &&
            decision.launchIdentity.empty(), "fresh protected config mismatch prevents launch and clears decision");
    }
    {
        Fixture f; A::NativeDpkgAuthority authority; std::string error;
        Write(f.root + "/conf/dpkg", "force-confold\n");
        Require(f.Resolve(&authority, &error), "capture cfg-old refusal scene");
        auto prefix = Prefix(f); prefix.back() = "--configure"; prefix.insert(prefix.begin() + 2, "--refuse-confold");
        N::Inputs inputs;
        Require(A::BuildNativeEffectPolicyInputs(authority, f.program, f.Capture(), "dpkg-1.23.7-effects-1", N::Role::Configure,
            prefix, &inputs, &error), "bind explicit refusal without interpreting native configuration");
        N::Record record; record.semanticProfile = inputs.semanticProfile; record.executorPath = inputs.executorPath;
        record.executorSHA256 = inputs.executorSHA256; record.role = inputs.role; record.optionPrefix = prefix;
        Require(N::InputIdentity(inputs, Hash, &record.inputIdentity), "hash native-final refusal inputs");
        // Source force.c::parse_force resets the bit for --refuse; declaration
        // supplies that final result. Current reviewed-option admission is NOT
        // widened by this library fixture.
        record.settings.statusDescriptors = {3}; VersionTwo(f, std::vector<N::Record>{record});
        Require(f.Resolve(&authority, &error), "resolve final-refusal assertion");
        auto arguments = prefix; arguments.push_back("sample:arm64"); A::ConffilePolicyDecision decision;
        Require(A::CaptureConffilePolicy(authority, f.program, f.Capture(), N::Role::Configure, arguments, prefix.size(), &decision, &error) &&
            decision.input == D::ConffileInputPolicy::Interactive, "argv refusal supersedes cfg choice only through matched complete force settings");
        arguments.erase(arguments.begin() + 2);
        Require(A::CaptureConffilePolicy(authority, f.program, f.Capture(), N::Role::Configure, arguments, prefix.size() - 1, &decision, &error) &&
            decision.match == N::Status::InputMismatch && decision.input == D::ConffileInputPolicy::Unverified,
            "a different actual prefix cannot borrow an interactive policy");
    }
}
void EffectDeclarations() {
    {
        Fixture f; A::NativeDpkgAuthority authority; std::string error;
        Require(f.Resolve(&authority, &error) && authority.declarationVersion == 1 &&
            authority.effectRecordState == A::NativeEffectRecordState::Missing && Match(f, authority).status == N::Status::Missing,
            "v1 graph remains usable without an optional effect assertion");
        const auto record = EffectRecord(f, authority);
        VersionTwo(f, std::vector<N::Record>{record});
        Require(f.Resolve(&authority, &error) && authority.declarationVersion == 2 &&
            authority.effectRecordState == A::NativeEffectRecordState::Parsed && authority.effectRecords.size() == 1,
            "protected twelve-field v2 declaration retains typed records");
        const auto match = Match(f, authority);
        Require(match.status == N::Status::Matched && match.settings && match.inputIdentity == record.inputIdentity,
            "replacing outer declaration bytes cannot create a circular input-identity dependency");
        const CydiaSources::ReaderGroups processGroups;
        Require(authority.configurationEvidence.front().sourceReaderGroups.values == processGroups.values,
            "ordinary protected evidence retains supplementary groups, including nonempty host groups");
        auto corrupted = authority; corrupted.effectRecords.front().settings.pending = true;
        Require(Match(f, corrupted).status == N::Status::Invalid, "mutable cached record cannot replace independently retained protected bytes");
        corrupted = authority; corrupted.dpkgRoot = "/another-root";
        Require(Match(f, corrupted).status == N::Status::Invalid, "captured selected paths cannot diverge from local authority binding");
        corrupted = authority; corrupted.configurationEvidence.front().sourceReaderGroups.values.resize(129);
        Require(Match(f, corrupted).status == N::Status::Invalid, "oversized local group metadata refuses before serialization");
        N::Inputs failed;
        Require(!A::BuildNativeEffectPolicyInputs(authority, f.program, f.Capture(), "dpkg-1.23.7-effects-1", N::Role::Unpack,
            Prefix(f), &failed, &error, [] { return true; }) && failed.configuration.empty() && failed.executorPath.empty(),
            "cancelled input capture publishes no partial effect inputs");
    }
    for (unsigned variant = 0; variant != 5; ++variant) {
        Fixture f; A::NativeDpkgAuthority authority; std::string error;
        Require(f.Resolve(&authority, &error), "resolve optional policy base"); auto record = EffectRecord(f, authority);
        N::Status expected = N::Status::Missing;
        switch (variant) {
            case 0: VersionTwo(f, std::vector<N::Record>()); break;
            case 1:
                record.semanticProfile = "dpkg-future-effects-2"; record.settings = N::Settings();
                record.unsupportedSettings = "future opaque state"; VersionTwo(f, std::vector<N::Record>{record});
                expected = N::Status::Unsupported; break;
            case 2:
                record.inputIdentity.assign(64, '0'); VersionTwo(f, std::vector<N::Record>{record});
                expected = N::Status::InputMismatch; break;
            case 3:
                record.settings.unmodeledOptions = {"vendor-effect"}; VersionTwo(f, std::vector<N::Record>{record});
                expected = N::Status::Unsupported; break;
            case 4:
                VersionTwo(f, P::SerializeFields({"CYDIA-NATIVE-EFFECT-POLICIES-1", P::SerializeFields({"malformed inner record"})}));
                expected = N::Status::Invalid; break;
        }
        Require(f.Resolve(&authority, &error) && !authority.configurationIdentity.empty(),
            "unusable effect assertion does not disable an otherwise valid protected graph");
        const auto match = Match(f, authority);
        Require(match.status == expected && !match.settings && match.inputIdentity.empty(),
            "missing unsupported stale unmodeled or malformed policy never grants an assertion match");
        Require(variant != 4 || (authority.effectRecordState == A::NativeEffectRecordState::Invalid &&
            authority.effectRecords.empty() && authority.effectRecordError != N::Error::None),
            "malformed records retain an explicit typed failure without partial records");
    }
    for (unsigned variant = 0; variant != 4; ++variant) {
        Fixture f; A::NativeDpkgAuthority authority; std::string error;
        std::string container;
        Require(N::EncodeRecords({}, &container), "empty canonical container");
        if (variant == 0) container = "broken container";
        if (variant == 1) container = P::SerializeFields({"CYDIA-NATIVE-EFFECT-POLICIES-1", "broken list framing"});
        if (variant == 2) container = P::SerializeFields({"CYDIA-NATIVE-EFFECT-POLICIES-1", P::SerializeFields({"z", "a"})});
        VersionTwo(f, container);
        if (variant == 3) { f.fields[11] = "partial-effects"; f.Save(); }
        Require(!f.Resolve(&authority, &error) && error == "provider_native_configuration_invalid" && authority.configurationIdentity.empty(),
            "broken outer framing or record-container framing remains a declaration error");
    }
    {
        Fixture f; A::NativeDpkgAuthority authority; std::string error;
        Require(f.Resolve(&authority, &error), "auto-deconfigure v2 fixture base");
        VersionTwo(f, std::vector<N::Record>{EffectRecord(f, authority)});
        A::ReviewedAction unpack; unpack.identifier = 1; unpack.action = A::ExecutionAction::Unpack;
        f.review.execution.actions = {unpack}; Write(f.root + "/conf/dpkg", "auto-deconfigure\n");
        Require(!f.Resolve(&authority, &error) && error == "provider_native_auto_deconfigure_unsupported",
            "v2 assertion does not relax existing configured auto-deconfiguration refusal");
    }
}
void EffectContentAndLocalEvidence() {
    Fixture f; A::NativeDpkgAuthority authority; std::string error;
    Require(f.Resolve(&authority, &error), "content identity base");
    const auto record = EffectRecord(f, authority); VersionTwo(f, std::vector<N::Record>{record});
    Require(f.Resolve(&authority, &error) && Match(f, authority).status == N::Status::Matched, "initial v2 content matches");
    const auto localIdentity = authority.configurationIdentity;
    const auto path = f.root + "/conf/dpkg", temporary = f.root + "/conf/new-dpkg";
    Write(temporary, "no-force\n"); Require(rename(temporary.c_str(), path.c_str()) == 0, "replace native input with same bytes/new inode");
    Require(Match(f, authority).status == N::Status::Invalid, "old local inode proof must be recaptured even for identical content");
    Require(f.Resolve(&authority, &error) && authority.configurationIdentity != localIdentity &&
        Match(f, authority).status == N::Status::Matched, "fresh identical content preserves distributor lookup while local authority changes");
    Write(path, "log changed\n");
    Require(f.Resolve(&authority, &error) && Match(f, authority).status == N::Status::InputMismatch,
        "real changed native configuration content invalidates the distributor assertion");
    Write(path, "no-force\n"); Write(f.optional, "new optional policy\n");
    Require(f.Resolve(&authority, &error) && Match(f, authority).status == N::Status::InputMismatch,
        "previously absent configuration becoming present changes content input identity");
}
void CircularEffectInputs() {
    for (unsigned alias = 0; alias != 2; ++alias) {
        Fixture f; A::NativeDpkgAuthority authority; std::string error;
        const auto path = alias ? f.root + "/conf/declaration-alias" : f.primary;
        f.fields[2] = P::SerializeFields({f.root + "/conf/dpkg", path});
        VersionTwo(f, std::vector<N::Record>());
        if (alias) Require(link(f.primary.c_str(), path.c_str()) == 0, "create protected declaration alias fixture");
        Require(f.Resolve(&authority, &error), "graph capture remains separate from effect lookup admission");
        N::Inputs inputs;
        Require(!A::BuildNativeEffectPolicyInputs(authority, f.program, f.Capture(), "dpkg-1.23.7-effects-1", N::Role::Unpack,
            Prefix(f), &inputs, &error) && error == "provider_native_effect_policy_circular" && inputs.configuration.empty(),
            "native-read declaration path or inode alias cannot create a circular distributor lookup");
    }
}
void Closures() {
    for (unsigned variant = 0; variant != 9; ++variant) {
        Fixture f; A::NativeDpkgAuthority authority; A::ComponentClosureEvidence proof; std::string error;
        Require(f.Resolve(&authority, &error), "resolve closure declaration"); auto components = f.Capture();
        Require(A::CaptureNativeDpkgClosure(authority, f.program, components, &proof, &error) && proof.nodes.size() == 2,
            "actual protected Mach-O graph resolves an rpath edge without loading code");
        switch (variant) {
            case 0: components[0].file.sha256.assign(64, '0'); break;
            case 1: Write(f.library, Image(false, {}, {}, 0), 0755); components = f.Capture(); break;
            case 2: components.pop_back(); break;
            case 3: Write(f.library, "changed after component capture", 0755); break;
            case 4: authority.configurationIdentity.assign(64, 'g'); break;
            case 5: R::SetTransactionTargetForTesting({0x100000c, 0, 2, 0xf0000}); break;
            case 6: f.Put(f.program, "#!/bin/sh\nexit 0\n"); f.Declaration(); Require(f.Resolve(&authority, &error), "script generation can be declared but not prove its dynamic command closure"); components = f.Capture(); break;
            case 7: f.Put(f.program, Image(true, {}, {}, 0x20000, 0x1000007)); f.Declaration(); Require(f.Resolve(&authority, &error), "generation capture is distinct from loadability"); components = f.Capture(); break;
            case 8: break;
        }
        Require(!A::CaptureNativeDpkgClosure(authority, f.program, components, &proof, &error,
            variant == 8 ? std::function<bool()>([] { return true; }) : std::function<bool()>()) && proof.nodes.empty(),
            "changed bytes/ABI/platform, incomplete inventory, unsupported executable or cancellation cannot publish closure proof");
    }
    {
        Fixture f; const auto earlier = f.root + "/earlier"; std::filesystem::create_directory(earlier);
        f.Put(f.program, Image(true, {"@rpath/libfixture.dylib"}, {earlier, "@executable_path/../lib"})); f.Declaration();
        A::NativeDpkgAuthority authority; A::ComponentClosureEvidence proof; std::string error;
        Require(f.Resolve(&authority, &error), "rpath declaration"); Write(earlier + "/libfixture.dylib", Image(false), 0755);
        Require(!A::CaptureNativeDpkgClosure(authority, f.program, f.Capture(), &proof, &error), "present undeclared earlier rpath candidate is not skipped");
        Require(unlink((earlier + "/libfixture.dylib").c_str()) == 0 &&
            A::CaptureNativeDpkgClosure(authority, f.program, f.Capture(), &proof, &error), "absent earlier rpath correctly resolves captured later candidate");
    }
    {
        Fixture f; const auto hook = f.root + "/bin/hook";
        f.Put(hook, Image(true, {f.root + "/lib/missing.dylib"})); f.components.push_back(hook); f.commands.push_back(hook); f.Declaration();
        A::NativeDpkgAuthority authority; A::ComponentClosureEvidence proof; std::string error;
        Require(f.Resolve(&authority, &error) && !A::CaptureNativeDpkgClosure(authority, f.program, f.Capture(), &proof, &error),
            "declared native command must independently resolve its dependency closure");
    }
    {
        Fixture f; std::vector<std::string> leaves, parents;
        for (unsigned index = 0; index != 64; ++index) {
            const auto path = f.root + "/lib/leaf" + std::to_string(index); f.Put(path, Image(false)); f.components.push_back(path); leaves.push_back(path);
        }
        for (unsigned index = 0; index != 65; ++index) {
            const auto path = f.root + "/lib/parent" + std::to_string(index); f.Put(path, Image(false, leaves)); f.components.push_back(path); parents.push_back(path);
        }
        f.Put(f.program, Image(true, parents)); f.Declaration();
        A::NativeDpkgAuthority authority; A::ComponentClosureEvidence proof; std::string error;
        Require(f.Resolve(&authority, &error) && !A::CaptureNativeDpkgClosure(authority, f.program, f.Capture(), &proof, &error) && proof.nodes.empty(),
            "actual shallow dependency graph is bounded to 4096 distinct edges");
    }
}
}
int main() {
    Declarations(); ConfiguredAutomaticDeconfiguration(); EffectDeclarations(); ConffilePolicyCapture(); EffectContentAndLocalEvidence(); CircularEffectInputs(); Closures();
    std::puts("Native dpkg protected declaration and Mach-O closure tests passed");
}
